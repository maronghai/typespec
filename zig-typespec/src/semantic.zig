const std = @import("std");
const ast_mod = @import("ast.zig");
const diag = @import("diagnostic.zig");
const Ast = ast_mod.Ast;
const Template = ast_mod.Template;
const Table = ast_mod.Table;
const Field = ast_mod.Field;
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;
const SqlComment = ast_mod.SqlComment;

pub const ResolvedTable = struct {
    name: []const u8,
    comment: ?[]const u8,
    engine: ?[]const u8,
    fields: []const Field,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
};

pub const ResolvedAst = struct {
    schema_name: ?[]const u8,
    schema_charset: ?[]const u8,
    tables: []const ResolvedTable,
    sql_comments: []const SqlComment,
};

// ─── Pass Manager ──────────────────────────────────────────────

/// Shared mutable context passed to each semantic pass.
pub const PassContext = struct {
    alloc: std.mem.Allocator,
    tables: *std.ArrayList(ResolvedTable),
    schema: ?ast_mod.Schema,
    templates: std.StringHashMap(*const Template) = undefined, // set by analyze()
    diagnostics: *diag.DiagnosticCollector = undefined, // set by analyze()
};

/// A semantic analysis pass that transforms the tables in PassContext.
pub const SemanticPass = struct {
    name: []const u8,
    run: *const fn (ctx: *PassContext) anyerror!void,
};

/// Default pass pipeline — order matters!
pub const DEFAULT_PASSES = [_]SemanticPass{
    .{ .name = "autofk", .run = runAutoFk },
    .{ .name = "suffix_inference", .run = runSuffixInference },
    .{ .name = "validate", .run = runValidate },
};

// ─── SemanticAnalyzer ──────────────────────────────────────────

pub const SemanticAnalyzer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SemanticAnalyzer {
        return .{ .alloc = alloc };
    }

    pub fn analyze(self: *SemanticAnalyzer, tree: Ast) !ResolvedAst {
        // Build template map
        var tmpl_map = std.StringHashMap(*const Template).init(self.alloc);
        for (tree.templates) |*t| {
            try tmpl_map.put(t.name orelse "", t);
        }
        var default_tmpl: ?*const Template = null;
        for (tree.templates) |*t| {
            if (t.name == null) default_tmpl = t;
        }

        // Template resolution (needs tree access, done inline)
        var resolved = std.StringHashMap([]const Field).init(self.alloc);
        var resolving = std.StringHashMap(bool).init(self.alloc);
        for (tree.templates) |*t| {
            const tname = t.name orelse "";
            if (!resolved.contains(tname)) {
                _ = try self.resolveTemplate(t, &tmpl_map, &resolved, &resolving);
            }
        }

        // Build initial tables with templates applied
        var tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, 8);
        for (tree.tables) |*t| {
            var fields: []const Field = t.fields;
            var tmpl_slot: ?usize = null;
            if (t.template_ref) |tref| {
                if (resolved.get(tref)) |parent_fields| {
                    for (tree.templates) |*tmpl| {
                        if (tmpl.name) |tn| {
                            if (std.mem.eql(u8, tn, tref)) {
                                tmpl_slot = tmpl.slot_index;
                                break;
                            }
                        }
                    }
                    fields = try self.applyTemplate(t, parent_fields, tmpl_slot);
                }
            } else if (default_tmpl) |dt| {
                const dname = dt.name orelse "";
                if (resolved.get(dname)) |parent_fields| {
                    fields = try self.applyTemplate(t, parent_fields, dt.slot_index);
                }
            }
            try tables.append(self.alloc, .{
                .name = t.name,
                .comment = t.comment,
                .engine = t.engine,
                .fields = fields,
                .fks = t.fks,
                .indexes = t.indexes,
                .line_no = t.line_no,
            });
        }

        // Run registered passes (autofk, suffix_inference, validate, ...)
        var diagnostics = diag.DiagnosticCollector.init(self.alloc);
        var ctx = PassContext{
            .alloc = self.alloc,
            .tables = &tables,
            .schema = tree.schema,
            .templates = tmpl_map,
            .diagnostics = &diagnostics,
        };
        for (DEFAULT_PASSES) |pass| {
            try pass.run(&ctx);
        }

        // Print collected diagnostics (warnings + errors from validation pass)
        diagnostics.printAll();

        return .{
            .schema_name = if (tree.schema) |s| s.name else null,
            .schema_charset = if (tree.schema) |s| s.charset orelse "utf8mb4" else null,
            .tables = try tables.toOwnedSlice(self.alloc),
            .sql_comments = tree.sql_comments,
        };
    }

    fn resolveTemplate(
        self: *SemanticAnalyzer,
        tmpl: *const Template,
        tmpl_map: *const std.StringHashMap(*const Template),
        resolved: *std.StringHashMap([]const Field),
        resolving: *std.StringHashMap(bool),
    ) ![]const Field {
        const tname = tmpl.name orelse "";
        if (resolved.get(tname)) |f| return f;

        if (resolving.contains(tname)) return error.CircularTemplateInheritance;
        try resolving.put(tname, true);
        defer _ = resolving.remove(tname);

        var base_fields: []const Field = &.{};
        for (tmpl.parents) |parent_name| {
            if (tmpl_map.get(parent_name)) |parent| {
                const parent_fields = try self.resolveTemplate(parent, tmpl_map, resolved, resolving);
                base_fields = try self.mergeFields(base_fields, parent_fields, &.{}, null);
            }
        }

        const result = try self.mergeFields(base_fields, tmpl.fields, &.{}, tmpl.slot_index);
        try resolved.put(tname, result);
        return result;
    }

    fn mergeFields(
        self: *SemanticAnalyzer,
        parent_fields: []const Field,
        child_fields: []const Field,
        concrete_fields: []const Field,
        child_slot: ?usize,
    ) ![]const Field {
        if (parent_fields.len == 0) return child_fields;

        var parent_slot: ?usize = null;
        for (parent_fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "...")) {
                parent_slot = i;
                break;
            }
        }

        const pslot = parent_slot orelse parent_fields.len;
        const cslot_raw = child_slot orelse pslot;
        const cslot = if (cslot_raw > child_fields.len) child_fields.len else cslot_raw;

        const parent_before = parent_fields[0..pslot];
        const parent_after = if (pslot < parent_fields.len) parent_fields[pslot + 1 ..] else &[_]Field{};
        const child_before = child_fields[0..cslot];
        const child_after = if (cslot < child_fields.len) child_fields[cslot + 1 ..] else &[_]Field{};

        var override_names = std.StringHashMap(void).init(self.alloc);
        for (child_before) |f| try override_names.put(f.name, {});
        for (child_after) |f| try override_names.put(f.name, {});
        for (concrete_fields) |f| try override_names.put(f.name, {});

        var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);

        for (parent_before) |f| {
            if (!override_names.contains(f.name)) try result.append(self.alloc, f);
        }
        for (child_before) |f| try result.append(self.alloc, f);
        for (concrete_fields) |f| try result.append(self.alloc, f);
        for (child_after) |f| try result.append(self.alloc, f);
        for (parent_after) |f| {
            if (!override_names.contains(f.name)) try result.append(self.alloc, f);
        }

        return try result.toOwnedSlice(self.alloc);
    }

    fn applyTemplate(
        self: *SemanticAnalyzer,
        table: *const Table,
        template_fields: []const Field,
        template_slot: ?usize,
    ) ![]const Field {
        if (table.fields.len == 0) return template_fields;

        var table_slot: ?usize = null;
        for (table.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "...")) {
                table_slot = i;
                break;
            }
        }

        var table_names = std.StringHashMap(void).init(self.alloc);
        for (table.fields) |f| try table_names.put(f.name, {});

        if (table_slot) |slot| {
            const table_before = table.fields[0..slot];
            const table_after = table.fields[slot + 1 ..];

            var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);
            for (table_before) |f| try result.append(self.alloc, f);
            for (template_fields) |f| {
                if (!table_names.contains(f.name)) try result.append(self.alloc, f);
            }
            for (table_after) |f| try result.append(self.alloc, f);
            return try result.toOwnedSlice(self.alloc);
        } else {
            const insert_pos = template_slot orelse template_fields.len;
            var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);
            for (template_fields[0..insert_pos]) |f| {
                if (!table_names.contains(f.name)) try result.append(self.alloc, f);
            }
            for (table.fields) |f| try result.append(self.alloc, f);
            if (insert_pos < template_fields.len) {
                for (template_fields[insert_pos..]) |f| {
                    if (!table_names.contains(f.name)) try result.append(self.alloc, f);
                }
            }
            return try result.toOwnedSlice(self.alloc);
        }
    }
};

// ─── Pass Implementations ─────────────────────────────────────

/// Auto FK inference: _id suffix → foreign key to matching table.
fn runAutoFk(ctx: *PassContext) !void {
    if (ctx.schema == null or !ctx.schema.?.autofk) return;

    var table_map = std.StringHashMap(void).init(ctx.alloc);
    for (ctx.tables.items) |t| {
        try table_map.put(t.name, {});
    }

    var new_tables = try std.ArrayList(ResolvedTable).initCapacity(ctx.alloc, ctx.tables.items.len);
    for (ctx.tables.items) |table| {
        var new_fields = try std.ArrayList(Field).initCapacity(ctx.alloc, table.fields.len);
        var new_indexes = try std.ArrayList(IndexDecl).initCapacity(ctx.alloc, table.indexes.len + 4);
        for (table.indexes) |idx| {
            try new_indexes.append(ctx.alloc, idx);
        }
        for (table.fields) |field| {
            var f = field;
            if (f.fk == null and f.name.len > 3 and std.mem.endsWith(u8, f.name, "_id")) {
                const prefix = f.name[0 .. f.name.len - 3];
                if (prefix.len > 0 and table_map.contains(prefix)) {
                    var local_fields = try ctx.alloc.alloc([]const u8, 1);
                    local_fields[0] = f.name;
                    var ref_fields = try ctx.alloc.alloc([]const u8, 1);
                    ref_fields[0] = "id";
                    f.fk = FkDecl{
                        .fields = local_fields,
                        .ref_table = try ctx.alloc.dupe(u8, prefix),
                        .ref_fields = ref_fields,
                        .actions = &.{},
                        .line_no = f.line_no,
                    };
                    var already_indexed = false;
                    for (table.indexes) |idx| {
                        for (idx.fields) |idx_f| {
                            if (std.mem.eql(u8, idx_f, f.name)) {
                                already_indexed = true;
                                break;
                            }
                        }
                        if (already_indexed) break;
                    }
                    if (!already_indexed) {
                        var idx_fields = try ctx.alloc.alloc([]const u8, 1);
                        idx_fields[0] = f.name;
                        const idx_name = try std.fmt.allocPrint(ctx.alloc, "idx_{s}", .{f.name});
                        try new_indexes.append(ctx.alloc, .{
                            .kind = .regular,
                            .name = idx_name,
                            .fields = idx_fields,
                            .descending = &.{false},
                            .line_no = f.line_no,
                        });
                    }
                }
            }
            try new_fields.append(ctx.alloc, f);
        }
        try new_tables.append(ctx.alloc, .{
            .name = table.name,
            .comment = table.comment,
            .engine = table.engine,
            .fields = try new_fields.toOwnedSlice(ctx.alloc),
            .fks = table.fks,
            .indexes = try new_indexes.toOwnedSlice(ctx.alloc),
            .line_no = table.line_no,
        });
    }
    ctx.tables.* = new_tables;
}

/// Suffix-based type inference: _id → int, _on → date, _at → datetime.
fn runSuffixInference(ctx: *PassContext) !void {
    var ti_tables = try std.ArrayList(ResolvedTable).initCapacity(ctx.alloc, ctx.tables.items.len);
    for (ctx.tables.items) |table| {
        var ti_fields = try std.ArrayList(Field).initCapacity(ctx.alloc, table.fields.len);
        for (table.fields) |field| {
            var f = field;
            if (f.type_info == .none) {
                if (f.name.len > 3 and std.mem.endsWith(u8, f.name, "_id")) {
                    f.type_info = .{ .simple = "n" };
                } else if (f.name.len > 3 and std.mem.endsWith(u8, f.name, "_on")) {
                    f.type_info = .{ .simple = "d" };
                } else if (f.name.len > 3 and std.mem.endsWith(u8, f.name, "_at")) {
                    f.type_info = .{ .simple = "t" };
                } else {
                    f.type_info = .{ .varchar_explicit = 0 };
                }
            }
            try ti_fields.append(ctx.alloc, f);
        }
        try ti_tables.append(ctx.alloc, .{
            .name = table.name,
            .comment = table.comment,
            .engine = table.engine,
            .fields = try ti_fields.toOwnedSlice(ctx.alloc),
            .fks = table.fks,
            .indexes = table.indexes,
            .line_no = table.line_no,
        });
    }
    ctx.tables.* = ti_tables;
}

// ─── Validation Pass ───────────────────────────────────────

/// Semantic validation: FK reference checks, template name existence,
/// field name duplicates, circular inheritance detection.
fn runValidate(ctx: *PassContext) !void {
    // 1. Collect all table names for FK reference checking
    var table_names = std.StringHashMap(void).init(ctx.alloc);
    for (ctx.tables.items) |t| {
        try table_names.put(t.name, {});
    }

    // 2. Validate each table
    for (ctx.tables.items) |table| {
        // Check for duplicate field names
        var field_names = std.StringHashMap(usize).init(ctx.alloc);
        defer field_names.deinit();
        for (table.fields, 0..) |field, fi| {
            if (std.mem.eql(u8, field.name, "...")) continue;
            if (field_names.get(field.name)) |_| {
                ctx.diagnostics.push(.{
                    .severity = .warning,
                    .line_no = field.line_no,
                    .message = try std.fmt.allocPrint(ctx.alloc, "duplicate field '{s}' in table '{s}'", .{ field.name, table.name }),
                });
            }
            try field_names.put(field.name, fi);
        }

        // Validate FK references
        for (table.fks) |fk| {
            for (fk.fields) |fk_field| {
                var found = false;
                for (table.fields) |field| {
                    if (std.mem.eql(u8, field.name, fk_field)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    ctx.diagnostics.push(.{
                        .severity = .@"error",
                        .line_no = table.line_no,
                        .message = try std.fmt.allocPrint(ctx.alloc, "FK field '{s}' not found in table '{s}'", .{ fk_field, table.name }),
                    });
                }
            }
            if (fk.ref_table.len > 0 and !table_names.contains(fk.ref_table)) {
                ctx.diagnostics.push(.{
                    .severity = .@"error",
                    .line_no = table.line_no,
                    .message = try std.fmt.allocPrint(ctx.alloc, "FK references non-existent table '{s}' in table '{s}'", .{ fk.ref_table, table.name }),
                });
            }
        }

        // Validate inline FK references
        for (table.fields) |field| {
            if (field.fk) |fk| {
                for (fk.fields) |fk_field| {
                    if (!std.mem.eql(u8, fk_field, field.name)) continue;
                    var found = false;
                    for (table.fields) |f| {
                        if (std.mem.eql(u8, f.name, fk_field)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        ctx.diagnostics.push(.{
                            .severity = .@"error",
                            .line_no = table.line_no,
                            .message = try std.fmt.allocPrint(ctx.alloc, "inline FK field '{s}' not found in table '{s}'", .{ fk_field, table.name }),
                        });
                    }
                }
                if (fk.ref_table.len > 0 and !table_names.contains(fk.ref_table)) {
                    ctx.diagnostics.push(.{
                        .severity = .@"error",
                        .line_no = table.line_no,
                        .message = try std.fmt.allocPrint(ctx.alloc, "inline FK references non-existent table '{s}' in table '{s}'", .{ fk.ref_table, table.name }),
                    });
                }
            }
        }
    }
}

// ─── Diagnostic ──────────────────────────────────────────────

pub fn diagnosticTrace(resolved: ResolvedAst) void {
    std.debug.print("=== [Stage 3: Semantic] ===\n\n", .{});

    std.debug.print("Suffix inference:\n", .{});
    std.debug.print("  _id -> int, _on -> date, _at -> datetime, (none) -> varchar(255)\n", .{});
    if (resolved.schema_name != null) {
        std.debug.print("  autofk: ", .{});
        var has_autofk = false;
        for (resolved.tables) |table| {
            for (table.fields) |field| {
                if (field.fk) |fk| {
                    if (fk.fields.len > 0 and fk.fields[0].len > 3 and std.mem.endsWith(u8, fk.fields[0], "_id")) {
                        has_autofk = true;
                        break;
                    }
                }
            }
            if (has_autofk) break;
        }
        if (has_autofk) {
            std.debug.print("yes\n", .{});
        } else {
            std.debug.print("no\n", .{});
        }
    }
    std.debug.print("\n", .{});

    if (resolved.tables.len > 0) {
        std.debug.print("Resolved tables ({d}):\n", .{resolved.tables.len});
        for (resolved.tables) |table| {
            std.debug.print("  # {s}", .{table.name});
            if (table.comment) |c| std.debug.print(" {s}", .{c});
            std.debug.print("\n", .{});

            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                std.debug.print("    {s: <24} ", .{field.name});
                ast_mod.fmtTypeInfo(field.type_info);
                ast_mod.fmtModifiers(field.modifiers);
                if (field.default_val) |dv| std.debug.print(" DEFAULT {s}", .{dv.value});
                if (field.check) |ck| std.debug.print(" CHECK({s})", .{ck.expr});
                if (field.fk) |fk| {
                    std.debug.print(" -> {s}(", .{fk.ref_table});
                    for (fk.ref_fields, 0..) |f, fi| {
                        if (fi > 0) std.debug.print(",", .{});
                        std.debug.print("{s}", .{f});
                    }
                    std.debug.print(")", .{});
                    for (fk.actions) |action| {
                        std.debug.print(" ", .{});
                        switch (action.trigger) {
                            .on_delete => std.debug.print("ON DELETE ", .{}),
                            .on_update => std.debug.print("ON UPDATE ", .{}),
                        }
                        switch (action.action) {
                            .cascade => std.debug.print("CASCADE", .{}),
                            .set_null => std.debug.print("SET NULL", .{}),
                        }
                    }
                }
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
            for (table.indexes) |idx| {
                std.debug.print("    INDEX ", .{});
                switch (idx.kind) {
                    .regular => std.debug.print("idx", .{}),
                    .unique => std.debug.print("UNIQUE", .{}),
                    .fulltext => std.debug.print("FULLTEXT", .{}),
                    .primary_key => std.debug.print("PRIMARY KEY", .{}),
                }
                std.debug.print(" {s}(", .{idx.name});
                for (idx.fields, 0..) |f, fi| {
                    if (fi > 0) std.debug.print(",", .{});
                    std.debug.print("{s}", .{f});
                }
                std.debug.print(")\n", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    if (resolved.sql_comments.len > 0) {
        std.debug.print("SQL Comments ({d}):\n", .{resolved.sql_comments.len});
        for (resolved.sql_comments) |sc| {
            std.debug.print("  L{d}: {s}\n", .{ sc.line_no, sc.text });
        }
        std.debug.print("\n", .{});
    }
}

// ─── Unit Tests ─────────────────────────────────────────────

const testing = std.testing;

fn makeTestField(name: []const u8, type_info: ast_mod.TypeInfo) Field {
    return .{
        .name = name,
        .type_info = type_info,
        .modifiers = &.{},
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 1,
    };
}

fn makeTestAst(_: std.mem.Allocator, tables: []const ast_mod.Table, templates: []const ast_mod.Template) Ast {
    return .{
        .schema = null,
        .templates = templates,
        .tables = tables,
        .sql_comments = &.{},
    };
}

test "suffix inference: _id → int" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestField("user_id", .none);

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
        .name = "order",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    try testing.expectEqual(@as(usize, 1), result.tables.len);
    try testing.expectEqual(@as(usize, 1), result.tables[0].fields.len);
    try testing.expectEqualStrings("n", result.tables[0].fields[0].type_info.simple);
}

test "suffix inference: _at → datetime" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestField("created_at", .none);

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
        .name = "log",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    try testing.expectEqualStrings("t", result.tables[0].fields[0].type_info.simple);
}

test "suffix inference: _on → date" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestField("paid_on", .none);

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
        .name = "payment",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    try testing.expectEqualStrings("d", result.tables[0].fields[0].type_info.simple);
}

test "suffix inference: explicit type wins over suffix" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestField("point_id", .{ .varchar_explicit = 32 });

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
        .name = "points",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // Explicit varchar(32) should win over _id → int inference
    const fi = result.tables[0].fields[0].type_info;
    try testing.expect(std.meta.activeTag(fi) == .varchar_explicit);
}

test "template application: fields merged in order" {
    const alloc = testing.allocator;

    // Template: id n++, ..., status 1 =0
    const tmpl_fields = try alloc.alloc(Field, 3);
    tmpl_fields[0] = makeTestField("id", .{ .simple = "n" });
    tmpl_fields[1] = makeTestField("...", .none); // slot
    tmpl_fields[2] = makeTestField("status", .{ .simple = "1" });

    const tmpl = ast_mod.Template{
        .name = "base",
        .parents = &.{},
        .fields = tmpl_fields,
        .slot_index = 1,
    };

    // Table: #base user, fields: name s32
    const table_fields = try alloc.alloc(Field, 1);
    table_fields[0] = makeTestField("name", .{ .varchar_explicit = 32 });

    const table = ast_mod.Table{
        .name = "user",
        .template_ref = "base",
        .comment = null,
        .engine = null,
        .fields = table_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{tmpl}));

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // Expected: id (from template before slot), name (concrete), status (from template after slot)
    try testing.expectEqual(@as(usize, 3), result.tables[0].fields.len);
    try testing.expectEqualStrings("id", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("name", result.tables[0].fields[1].name);
    try testing.expectEqualStrings("status", result.tables[0].fields[2].name);
}

// ─── Additional template/semantic tests ──────────────────────

test "template: slot at start" {
    const alloc = testing.allocator;

    // Template: ... (slot at 0), then id, status
    const tmpl_fields = try alloc.alloc(Field, 3);
    tmpl_fields[0] = makeTestField("...", .none);
    tmpl_fields[1] = makeTestField("id", .{ .simple = "n" });
    tmpl_fields[2] = makeTestField("status", .{ .simple = "1" });

    const tmpl = ast_mod.Template{
        .name = "base",
        .parents = &.{},
        .fields = tmpl_fields,
        .slot_index = 0,
    };

    const table_fields = try alloc.alloc(Field, 1);
    table_fields[0] = makeTestField("name", .{ .varchar_explicit = 32 });

    const table = ast_mod.Table{
        .name = "user",
        .template_ref = "base",
        .comment = null,
        .engine = null,
        .fields = table_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{tmpl}));
    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // Concrete fields come first (slot at 0), then template fields after slot
    try testing.expectEqual(@as(usize, 3), result.tables[0].fields.len);
    try testing.expectEqualStrings("name", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("id", result.tables[0].fields[1].name);
    try testing.expectEqualStrings("status", result.tables[0].fields[2].name);
}

test "template: slot at end" {
    const alloc = testing.allocator;

    // Template: id, status, ...
    const tmpl_fields = try alloc.alloc(Field, 3);
    tmpl_fields[0] = makeTestField("id", .{ .simple = "n" });
    tmpl_fields[1] = makeTestField("status", .{ .simple = "1" });
    tmpl_fields[2] = makeTestField("...", .none);

    const tmpl = ast_mod.Template{
        .name = "base",
        .parents = &.{},
        .fields = tmpl_fields,
        .slot_index = 2,
    };

    const table_fields = try alloc.alloc(Field, 1);
    table_fields[0] = makeTestField("name", .{ .varchar_explicit = 32 });

    const table = ast_mod.Table{
        .name = "user",
        .template_ref = "base",
        .comment = null,
        .engine = null,
        .fields = table_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{tmpl}));
    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // Template fields before slot, then concrete, then nothing after
    try testing.expectEqual(@as(usize, 3), result.tables[0].fields.len);
    try testing.expectEqualStrings("id", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("status", result.tables[0].fields[1].name);
    try testing.expectEqualStrings("name", result.tables[0].fields[2].name);
}

test "template: child overrides parent field with same name" {
    const alloc = testing.allocator;

    // Parent template: id, status
    const parent_fields = try alloc.alloc(Field, 2);
    parent_fields[0] = makeTestField("id", .{ .simple = "n" });
    parent_fields[1] = makeTestField("status", .{ .simple = "1" });

    const parent_tmpl = ast_mod.Template{
        .name = "base",
        .parents = &.{},
        .fields = parent_fields,
        .slot_index = null,
    };

    // Child template inherits base, overrides status
    const child_fields = try alloc.alloc(Field, 2);
    child_fields[0] = makeTestField("status", .{ .simple = "2" });
    child_fields[1] = makeTestField("name", .{ .simple = "s" });

    const child_tmpl = ast_mod.Template{
        .name = "audit",
        .parents = &.{ "base" },
        .fields = child_fields,
        .slot_index = null,
    };

    const table = ast_mod.Table{
        .name = "user",
        .template_ref = "audit",
        .comment = null,
        .engine = null,
        .fields = &.{},
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{ parent_tmpl, child_tmpl }));
    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // id from parent, status from child (override), name from child
    try testing.expectEqual(@as(usize, 3), result.tables[0].fields.len);
    try testing.expectEqualStrings("id", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("status", result.tables[0].fields[1].name);
    try testing.expectEqualStrings("2", result.tables[0].fields[1].type_info.simple);
    try testing.expectEqualStrings("name", result.tables[0].fields[2].name);
}

test "template: 3-level inheritance" {
    const alloc = testing.allocator;

    // grandparent: id
    const gp_fields = try alloc.alloc(Field, 1);
    gp_fields[0] = makeTestField("id", .{ .simple = "n" });

    const gp_tmpl = ast_mod.Template{
        .name = "gp",
        .parents = &.{},
        .fields = gp_fields,
        .slot_index = null,
    };

    // parent: inherits gp, adds status
    const p_fields = try alloc.alloc(Field, 1);
    p_fields[0] = makeTestField("status", .{ .simple = "1" });

    const p_tmpl = ast_mod.Template{
        .name = "p",
        .parents = &.{ "gp" },
        .fields = p_fields,
        .slot_index = null,
    };

    // child: inherits p, adds name
    const c_fields = try alloc.alloc(Field, 1);
    c_fields[0] = makeTestField("name", .{ .simple = "s" });

    const c_tmpl = ast_mod.Template{
        .name = "c",
        .parents = &.{ "p" },
        .fields = c_fields,
        .slot_index = null,
    };

    const table = ast_mod.Table{
        .name = "t",
        .template_ref = "c",
        .comment = null,
        .engine = null,
        .fields = &.{},
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{ gp_tmpl, p_tmpl, c_tmpl }));
    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // id from grandparent, status from parent, name from child
    try testing.expectEqual(@as(usize, 3), result.tables[0].fields.len);
    try testing.expectEqualStrings("id", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("status", result.tables[0].fields[1].name);
    try testing.expectEqualStrings("name", result.tables[0].fields[2].name);
}

test "template: empty fields template" {
    const alloc = testing.allocator;

    const tmpl = ast_mod.Template{
        .name = "empty",
        .parents = &.{},
        .fields = &.{},
        .slot_index = null,
    };

    const table_fields = try alloc.alloc(Field, 2);
    table_fields[0] = makeTestField("id", .{ .simple = "n" });
    table_fields[1] = makeTestField("name", .{ .simple = "s" });

    const table = ast_mod.Table{
        .name = "t",
        .template_ref = "empty",
        .comment = null,
        .engine = null,
        .fields = table_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{tmpl}));
    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // Table keeps its own fields even with empty template
    try testing.expectEqual(@as(usize, 2), result.tables[0].fields.len);
    try testing.expectEqualStrings("id", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("name", result.tables[0].fields[1].name);
}

test "template: multiple mixins" {
    const alloc = testing.allocator;

    // mixin1: created_at
    const m1_fields = try alloc.alloc(Field, 1);
    m1_fields[0] = makeTestField("created_at", .none);
    const m1 = ast_mod.Template{
        .name = "timestamps",
        .parents = &.{},
        .fields = m1_fields,
        .slot_index = null,
    };

    // mixin2: deleted_at
    const m2_fields = try alloc.alloc(Field, 1);
    m2_fields[0] = makeTestField("deleted_at", .none);
    const m2 = ast_mod.Template{
        .name = "softdel",
        .parents = &.{},
        .fields = m2_fields,
        .slot_index = null,
    };

    // audit inherits both mixins
    const audit_fields = try alloc.alloc(Field, 0);
    const audit = ast_mod.Template{
        .name = "audit",
        .parents = &.{ "timestamps", "softdel" },
        .fields = audit_fields,
        .slot_index = null,
    };

    const table = ast_mod.Table{
        .name = "t",
        .template_ref = "audit",
        .comment = null,
        .engine = null,
        .fields = &.{},
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{ m1, m2, audit }));
    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(ast);

    // Both mixin fields should be present
    try testing.expectEqual(@as(usize, 2), result.tables[0].fields.len);
    try testing.expectEqualStrings("created_at", result.tables[0].fields[0].name);
    try testing.expectEqualStrings("deleted_at", result.tables[0].fields[1].name);
}
