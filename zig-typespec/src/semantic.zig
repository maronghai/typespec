const std = @import("std");
const ast_mod = @import("ast.zig");
const Parser = @import("parser.zig").Parser;
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

pub const SemanticAnalyzer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SemanticAnalyzer {
        return .{ .alloc = alloc };
    }

    pub fn analyze(self: *SemanticAnalyzer, tree: Ast) !ResolvedAst {
        var tmpl_map = std.StringHashMap(*const Template).init(self.alloc);
        for (tree.templates) |*t| {
            try tmpl_map.put(t.name orelse "", t);
        }

        var default_tmpl: ?*const Template = null;
        for (tree.templates) |*t| {
            if (t.name == null) default_tmpl = t;
        }

        var resolved = std.StringHashMap([]const Field).init(self.alloc);
        var resolving = std.StringHashMap(bool).init(self.alloc);

        for (tree.templates) |*t| {
            const tname = t.name orelse "";
            if (!resolved.contains(tname)) {
                _ = try self.resolveTemplate(t, &tmpl_map, &resolved, &resolving);
            }
        }

        var tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, 8);
        for (tree.tables) |*t| {
            var fields: []const Field = t.fields;
            var tmpl_slot: ?usize = null;
            if (t.template_ref) |tref| {
                if (resolved.get(tref)) |parent_fields| {
                    // Find the template to get its slot position
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

        // Auto FK inference from _id suffix (when autofk flag is set)
        if (tree.schema != null and tree.schema.?.autofk) {
            // Build table name index
            var table_map = std.StringHashMap(void).init(self.alloc);
            for (tables.items) |t| {
                try table_map.put(t.name, {});
            }
            // Rebuild tables with auto FKs and auto indexes added
            var new_tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, tables.items.len);
            for (tables.items) |table| {
                var new_fields = try std.ArrayList(Field).initCapacity(self.alloc, table.fields.len);
                var new_indexes = try std.ArrayList(IndexDecl).initCapacity(self.alloc, table.indexes.len + 4);
                // Copy existing indexes
                for (table.indexes) |idx| {
                    try new_indexes.append(self.alloc, idx);
                }
                for (table.fields) |field| {
                    var f = field;
                    if (f.fk == null and f.name.len > 3 and std.mem.endsWith(u8, f.name, "_id")) {
                        const prefix = f.name[0 .. f.name.len - 3];
                        if (prefix.len > 0 and table_map.contains(prefix)) {
                            // Auto FK
                            var local_fields = try self.alloc.alloc([]const u8, 1);
                            local_fields[0] = f.name;
                            var ref_fields = try self.alloc.alloc([]const u8, 1);
                            ref_fields[0] = "id";
                            f.fk = FkDecl{
                                .fields = local_fields,
                                .ref_table = try self.alloc.dupe(u8, prefix),
                                .ref_fields = ref_fields,
                                .actions = &.{},
                                .line_no = f.line_no,
                            };
                            // Auto index for FK column (if not already indexed)
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
                                var idx_fields = try self.alloc.alloc([]const u8, 1);
                                idx_fields[0] = f.name;
                                const idx_name = try std.fmt.allocPrint(self.alloc, "idx_{s}", .{f.name});
                                try new_indexes.append(self.alloc, .{
                                    .kind = .regular,
                                    .name = idx_name,
                                    .fields = idx_fields,
                                    .descending = &.{false},
                                    .line_no = f.line_no,
                                });
                            }
                        }
                    }
                    try new_fields.append(self.alloc, f);
                }
                try new_tables.append(self.alloc, .{
                    .name = table.name,
                    .comment = table.comment,
                    .engine = table.engine,
                    .fields = try new_fields.toOwnedSlice(self.alloc),
                    .fks = table.fks,
                    .indexes = try new_indexes.toOwnedSlice(self.alloc),
                    .line_no = table.line_no,
                });
            }
            tables = new_tables;
        }

        // Suffix-based type inference: _id → int, _on → date, _at → datetime
        var ti_tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, tables.items.len);
        for (tables.items) |table| {
            var ti_fields = try std.ArrayList(Field).initCapacity(self.alloc, table.fields.len);
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
                try ti_fields.append(self.alloc, f);
            }
            try ti_tables.append(self.alloc, .{
                .name = table.name,
                .comment = table.comment,
                .engine = table.engine,
                .fields = try ti_fields.toOwnedSlice(self.alloc),
                .fks = table.fks,
                .indexes = table.indexes,
                .line_no = table.line_no,
            });
        }
        tables = ti_tables;

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

        // Find slot in parent
        var parent_slot: ?usize = null;
        for (parent_fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "...")) {
                parent_slot = i;
                break;
            }
        }

        const pslot = parent_slot orelse parent_fields.len;
        const cslot_raw = child_slot orelse pslot; // If child doesn't redefine slot, use parent's
        const cslot = if (cslot_raw > child_fields.len) child_fields.len else cslot_raw;

        const parent_before = parent_fields[0..pslot];
        const parent_after = if (pslot < parent_fields.len) parent_fields[pslot + 1 ..] else &[_]Field{};
        const child_before = child_fields[0..cslot];
        const child_after = if (cslot < child_fields.len) child_fields[cslot + 1 ..] else &[_]Field{};

        // Collect all names that override parent fields
        var override_names = std.StringHashMap(void).init(self.alloc);
        for (child_before) |f| try override_names.put(f.name, {});
        for (child_after) |f| try override_names.put(f.name, {});
        for (concrete_fields) |f| try override_names.put(f.name, {});

        var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);

        // parent_before (skip overrides)
        for (parent_before) |f| {
            if (!override_names.contains(f.name)) {
                try result.append(self.alloc, f);
            }
        }

        // child_before
        for (child_before) |f| {
            try result.append(self.alloc, f);
        }

        // concrete fields (inserted at child's slot position)
        for (concrete_fields) |f| {
            try result.append(self.alloc, f);
        }

        // child_after
        for (child_after) |f| {
            try result.append(self.alloc, f);
        }

        // parent_after (skip overrides)
        for (parent_after) |f| {
            if (!override_names.contains(f.name)) {
                try result.append(self.alloc, f);
            }
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

        // Find slot in table's fields (... defines where template content is inserted)
        var table_slot: ?usize = null;
        for (table.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "...")) {
                table_slot = i;
                break;
            }
        }

        // All table field names that override template fields
        var table_names = std.StringHashMap(void).init(self.alloc);
        for (table.fields) |f| try table_names.put(f.name, {});

        if (table_slot) |slot| {
            // Slot found: insert template fields at slot position
            const table_before = table.fields[0..slot];
            const table_after = table.fields[slot + 1 ..];

            var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);

            // Table fields before slot
            for (table_before) |f| {
                try result.append(self.alloc, f);
            }

            // Template fields (skip conflicts with any concrete field)
            for (template_fields) |f| {
                if (!table_names.contains(f.name)) {
                    try result.append(self.alloc, f);
                }
            }

            // Table fields after slot
            for (table_after) |f| {
                try result.append(self.alloc, f);
            }

            return try result.toOwnedSlice(self.alloc);
        } else {
            // No slot: use template's ... position to determine where table fields go
            const insert_pos = template_slot orelse template_fields.len;
            var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);

            // Template fields before insert position (skip overrides)
            for (template_fields[0..insert_pos]) |f| {
                if (!table_names.contains(f.name)) {
                    try result.append(self.alloc, f);
                }
            }

            // Table fields
            for (table.fields) |f| {
                try result.append(self.alloc, f);
            }

            // Template fields after insert position (skip overrides)
            if (insert_pos < template_fields.len) {
                for (template_fields[insert_pos..]) |f| {
                    if (!table_names.contains(f.name)) {
                        try result.append(self.alloc, f);
                    }
                }
            }

            return try result.toOwnedSlice(self.alloc);
        }
    }
};

// ─── Diagnostic ──────────────────────────────────────────────

pub fn diagnosticTrace(resolved: ResolvedAst) void {
    std.debug.print("=== [Stage 3: Semantic] ===\n\n", .{});

    // Suffix inference summary
    std.debug.print("Suffix inference:\n", .{});
    std.debug.print("  _id -> int, _on -> date, _at -> datetime, (none) -> varchar(255)\n", .{});
    if (resolved.schema_name != null) {
        std.debug.print("  autofk: ", .{});
        // Check if any table has auto-generated FKs (heuristic: check for _id fields with FKs)
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
