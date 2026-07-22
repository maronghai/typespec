const std = @import("std");
const ast_mod = @import("ast.zig");
const diag = @import("diagnostic.zig");
const template_mod = @import("template.zig");
const type_map = @import("type_map.zig");
const ast_visitor = @import("ast_visitor.zig");
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
const ResolvedTable = ast_mod.ResolvedTable;
const ResolvedAst = ast_mod.ResolvedAst;

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
    /// Pass names that must run before this pass. Debug mode validates ordering.
    depends_on: []const []const u8 = &.{},
};

/// Default pass pipeline — order matters!
pub const DEFAULT_PASSES = [_]SemanticPass{
    .{ .name = "validate_template_types", .run = runValidateTemplateTypes, .depends_on = &.{} },
    .{ .name = "autofk", .run = runAutoFk, .depends_on = &.{} },
    .{ .name = "suffix_inference", .run = runSuffixInference, .depends_on = &.{"autofk"} },
    .{ .name = "validate", .run = runValidate, .depends_on = &.{ "autofk", "suffix_inference" } },
    .{ .name = "validate_type_modifiers", .run = runValidateTypeModifiers, .depends_on = &.{"suffix_inference"} },
};

// ─── SemanticAnalyzer ──────────────────────────────────────────

pub const SemanticAnalyzer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SemanticAnalyzer {
        return .{ .alloc = alloc };
    }

    pub fn analyze(self: *SemanticAnalyzer, tree: Ast) !ResolvedAst {
        // Template resolution + application (delegated to template.zig)
        const resolved_tables = try template_mod.resolveAndApply(self.alloc, tree);

        // Build template map for passes that need it
        var tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, resolved_tables.len);
        for (resolved_tables) |t| {
            try tables.append(self.alloc, t);
        }

        const tmpl_map = try template_mod.buildTemplateMap(self.alloc, tree.templates);

        // Run registered passes (autofk, suffix_inference, validate, ...)
        // Debug: validate dependency ordering
        if (comptime std.debug.runtime_safety) {
            var seen_names = std.StringHashMap(void).init(self.alloc);
            defer seen_names.deinit();
            for (DEFAULT_PASSES) |pass| {
                for (pass.depends_on) |dep| {
                    if (!seen_names.contains(dep)) {
                        std.debug.panic("SemanticPass '{s}' depends on '{s}' which has not run yet", .{ pass.name, dep });
                    }
                }
                try seen_names.put(pass.name, {});
            }
        }
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

        // Abort on errors — don't proceed to codegen with invalid semantics
        if (diagnostics.hasErrors()) {
            return error.SemanticError;
        }

        return .{
            .schema_name = if (tree.schema) |s| s.name else null,
            .schema_charset = if (tree.schema) |s| s.charset orelse "utf8mb4" else null,
            .custom_types = if (tree.schema) |s| s.custom_types else &.{},
            .tables = try tables.toOwnedSlice(self.alloc),
            .views = tree.views,
            .sql_comments = tree.sql_comments,
        };
    }
};

// ─── Pass Implementations ─────────────────────────────────────

/// Check if two TypeInfo values represent the same TPS type.
fn tpsTypeSame(a: TypeInfo, b: TypeInfo) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .simple => |s| std.mem.eql(u8, s, b.simple),
        .raw_sql => |s| std.mem.eql(u8, s, b.raw_sql),
        .int_explicit => |n| n == b.int_explicit,
        .decimal_explicit => |ds| ds.precision == b.decimal_explicit.precision and ds.scale == b.decimal_explicit.scale,
        .varchar_explicit => |n| n == b.varchar_explicit,
        .enum_type => |vals| {
            if (vals.len != b.enum_type.len) return false;
            for (vals, 0..) |v, i| {
                if (!std.mem.eql(u8, v, b.enum_type[i])) return false;
            }
            return true;
        },
    };
}

/// Template type consistency: warn when child template overrides parent field with different type.
fn runValidateTemplateTypes(ctx: *PassContext) !void {
    var it = ctx.templates.iterator();
    while (it.next()) |entry| {
        const tmpl = entry.value_ptr.*;
        for (tmpl.parents) |parent_name| {
            if (ctx.templates.get(parent_name)) |parent_tmpl| {
                // Build parent field name→type map
                var parent_fields = std.StringHashMap(TypeInfo).init(ctx.alloc);
                defer parent_fields.deinit();
                for (parent_tmpl.fields) |f| {
                    if (std.mem.eql(u8, f.name, "...")) continue;
                    try parent_fields.put(f.name, f.type_info);
                }
                // Check child fields against parent
                for (tmpl.fields) |f| {
                    if (std.mem.eql(u8, f.name, "...")) continue;
                    if (parent_fields.get(f.name)) |parent_ti| {
                        if (!tpsTypeSame(f.type_info, parent_ti)) {
                            const tname = tmpl.name orelse "";
                            ctx.diagnostics.push(.{
                                .severity = .warning,
                                .line_no = f.line_no,
                                .message = try std.fmt.allocPrint(ctx.alloc, "template '{s}' overrides field '{s}' with different type (parent: {s}, child: {s})", .{ tname, f.name, @tagName(std.meta.activeTag(parent_ti)), @tagName(std.meta.activeTag(f.type_info)) }),
                            });
                        }
                    }
                }
            }
        }
    }
}

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

/// Semantic validation: FK reference checks, field name duplicates.
/// Uses AstVisitor for traversal where possible.
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

        // Validate FK references (table-level + inline)
        for (table.fks) |fk| {
            try validateFk(ctx, &table_names, table, fk);
        }
        for (table.fields) |field| {
            if (field.fk) |fk| {
                try validateFk(ctx, &table_names, table, fk);
            }
        }
    }
}

/// Helper: validate a single FK declaration against the table and schema.
fn validateFk(ctx: *PassContext, table_names: *const std.StringHashMap(void), table: ResolvedTable, fk: FkDecl) !void {
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
                .severity = .warning,
                .line_no = table.line_no,
                .message = try std.fmt.allocPrint(ctx.alloc, "FK field '{s}' not found in table '{s}' — may be an implicit field from ultra shorthand", .{ fk_field, table.name }),
            });
        }
    }
    if (fk.ref_table.len > 0 and !table_names.contains(fk.ref_table)) {
        ctx.diagnostics.push(.{
            .severity = .warning,
            .line_no = table.line_no,
            .message = try std.fmt.allocPrint(ctx.alloc, "FK references non-existent table '{s}' in table '{s}'", .{ fk.ref_table, table.name }),
        });
    }
}

// ─── Type Modifier Validation (visitor-based) ────────────────

/// Validates that modifiers are used with compatible types.
/// Uses AstVisitor.walkResolvedTables for traversal.
fn runValidateTypeModifiers(ctx: *PassContext) !void {
    var vctx = ModifierValidationCtx{
        .alloc = ctx.alloc,
        .diagnostics = ctx.diagnostics,
    };

    const visitor = ast_visitor.AstVisitor(*ModifierValidationCtx){
        .context = &vctx,
        .visitField = visitFieldCheckModifiers,
    };

    visitor.walkResolvedTables(ctx.tables.items);
}

const ModifierValidationCtx = struct {
    alloc: std.mem.Allocator,
    diagnostics: *diag.DiagnosticCollector,
};

fn visitFieldCheckModifiers(ctx: *ModifierValidationCtx, field: *const Field, _: ?[]const u8) void {
    for (field.modifiers) |mod| {
        switch (mod.kind) {
            .auto_inc_pk, .auto_inc => {
                if (!type_map.isNumericTpsType(field.type_info) and !type_map.isDatetimeTpsType(field.type_info)) {
                    const mod_name = if (mod.kind == .auto_inc_pk) "auto_increment" else "auto_increment";
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = mod.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "'{s}' modifier has no effect on non-numeric/non-datetime type in field '{s}'", .{ mod_name, field.name }) catch return,
                    });
                }
            },
            .primary_key => {},
            .not_null => {},
            .unsigned => {
                if (!type_map.isNumericTpsType(field.type_info)) {
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = mod.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "'unsigned' modifier has no effect on non-numeric type in field '{s}'", .{field.name}) catch return,
                    });
                }
            },
            .inline_unique => {},
            .inline_index => {},
        }
    }
}

// ─── Diagnostic ──────────────────────────────────────────────

const trace = @import("trace.zig");

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
                        trace.formatFkAction(action);
                    }
                }
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
            for (table.indexes) |idx| {
                trace.formatResolvedIndex(idx);
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
const test_helpers = struct {
    const makeTestField = @import("test_helpers.zig").makeTestField;
    const makeTestAst = @import("test_helpers.zig").makeTestAst;
};

test "suffix inference: _id → int" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("user_id", .none);

    const ast = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
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
    fields[0] = test_helpers.makeTestField("created_at", .none);

    const ast = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
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
    fields[0] = test_helpers.makeTestField("paid_on", .none);

    const ast = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
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
    fields[0] = test_helpers.makeTestField("point_id", .{ .varchar_explicit = 32 });

    const ast = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
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

    const fi = result.tables[0].fields[0].type_info;
    try testing.expect(std.meta.activeTag(fi) == .varchar_explicit);
}

test "suffix inference: no suffix keeps explicit type" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("data", .{ .simple = "b" });

    const ast = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{.{
        .name = "t",
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

    try testing.expectEqualStrings("b", result.tables[0].fields[0].type_info.simple);
}

// ─── Type Modifier Validation Tests ─────────────────────────

fn makeTestFieldWithMods(name: []const u8, type_info: ast_mod.TypeInfo, mods: []const Modifier) Field {
    return .{
        .name = name,
        .type_info = type_info,
        .modifiers = mods,
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 1,
    };
}

test "validate_type_modifiers: ++ on varchar produces warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .auto_inc_pk, .line_no = 3 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("name", .{ .simple = "s" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try runValidateTypeModifiers(&ctx);
    try testing.expect(diagnostics.diagnostics.items.len > 0);
}

test "validate_type_modifiers: u on varchar produces warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .unsigned, .line_no = 2 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("tag", .{ .simple = "s" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try runValidateTypeModifiers(&ctx);
    try testing.expect(diagnostics.diagnostics.items.len > 0);
}

test "validate_type_modifiers: ++ on n produces no warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .auto_inc_pk, .line_no = 1 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("id", .{ .simple = "n" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try runValidateTypeModifiers(&ctx);
    try testing.expectEqual(@as(usize, 0), diagnostics.diagnostics.items.len);
}

test "validate_type_modifiers: + on t produces no warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .auto_inc, .line_no = 1 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("created_at", .{ .simple = "t" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try runValidateTypeModifiers(&ctx);
    try testing.expectEqual(@as(usize, 0), diagnostics.diagnostics.items.len);
}

test "validate_type_modifiers: u on n produces no warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .unsigned, .line_no = 1 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("count", .{ .simple = "n" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try runValidateTypeModifiers(&ctx);
    try testing.expectEqual(@as(usize, 0), diagnostics.diagnostics.items.len);
}
