const std = @import("std");
const sp = @import("sql_parser.zig");
const reverse_map = @import("reverse_map.zig");
const dialect_mod = @import("dialect.zig");
const Dialect = sp.Dialect;
const template_ext = @import("template_extraction.zig");
const rc = @import("reverse_column.zig");
const rf = @import("reverse_fk.zig");

// ─── Reverse Codegen ─────────────────────────────────────────────
// Orchestrates SQL → TPS generation. Column-level logic is delegated
// to reverse_column.zig, CHECK parsing to reverse_check.zig (via
// reverse_column.zig), and FK classification to reverse_fk.zig.

pub const ReverseCodegen = struct {
    alloc: std.mem.Allocator,
    dialect: Dialect,

    pub fn init(alloc: std.mem.Allocator, dialect: Dialect) ReverseCodegen {
        return .{ .alloc = alloc, .dialect = dialect };
    }

    pub fn generate(self: *ReverseCodegen, schema: sp.SqlSchema) ![]const u8 {
        return self.generateInner(schema, false);
    }

    pub fn generateWithTemplates(self: *ReverseCodegen, schema: sp.SqlSchema) ![]const u8 {
        return self.generateInner(schema, true);
    }

    fn generateInner(self: *ReverseCodegen, schema: sp.SqlSchema, extract_templates: bool) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;

        try emitSchemaHeader(self, w, schema);

        var tmpl_list: []template_ext.TemplateCandidate = &.{};
        if (extract_templates) {
            tmpl_list = try template_ext.findTemplates(self.alloc, schema);
        }

        try emitTemplates(self, w, schema, tmpl_list);
        try emitTables(self, w, schema, tmpl_list);

        try w.flush();
        var out = aw.toArrayList();
        return try out.toOwnedSlice(self.alloc);
    }
};

// ─── Sub-functions ──────────────────────────────────────────────

fn emitSchemaHeader(self: *ReverseCodegen, w: anytype, schema: sp.SqlSchema) !void {
    _ = self;
    if (schema.name) |name| {
        try w.print("$ {s}", .{name});
        if (schema.charset) |cs| {
            if (std.mem.eql(u8, cs, "utf8mb4") or std.mem.eql(u8, cs, "UTF8") or std.mem.eql(u8, cs, "utf8")) {
                // default charset — omit
            } else {
                try w.print(" {s}", .{cs});
            }
        }
        try w.writeAll("\n\n");
    }
}

fn emitTemplates(self: *ReverseCodegen, w: anytype, schema: sp.SqlSchema, tmpl_list: []template_ext.TemplateCandidate) !void {
    for (tmpl_list, 0..) |t, ti| {
        var ref_indexes: []const sp.SqlIndex = &.{};
        if (t.table_indices.len > 0) {
            ref_indexes = schema.tables[t.table_indices[0]].indexes;
        }

        // Find parent template (earlier template whose fields are a subset)
        var parent_name: ?[]const u8 = null;
        if (ti > 0) {
            var best_parent: usize = 0;
            var best_overlap: usize = 0;
            for (tmpl_list[0..ti], 0..) |prev, pi| {
                var overlap: usize = 0;
                for (prev.fields) |pf| {
                    for (t.fields) |tf| {
                        if (std.mem.eql(u8, pf.name, tf.name)) {
                            overlap += 1;
                            break;
                        }
                    }
                }
                if (overlap > best_overlap) {
                    best_overlap = overlap;
                    best_parent = pi;
                }
            }
            if (best_overlap > 0) {
                parent_name = tmpl_list[best_parent].name;
            }
        }

        // Output: % name [> parent] \n ...
        if (parent_name) |pn| {
            try w.print("% {s} > {s}\n...\n", .{ t.name, pn });
        } else {
            try w.print("% {s}\n...\n", .{t.name});
        }

        // Output only NEW fields (not in parent)
        for (t.fields) |col| {
            var in_parent = false;
            if (parent_name) |pn| {
                for (tmpl_list) |tl| {
                    if (std.mem.eql(u8, tl.name, pn)) {
                        for (tl.fields) |pf| {
                            if (std.mem.eql(u8, col.name, pf.name)) {
                                in_parent = true;
                                break;
                            }
                        }
                        break;
                    }
                }
            }
            if (in_parent) continue;
            try w.writeAll(col.name);
            const tbl_name = if (t.table_indices.len > 0) schema.tables[t.table_indices[0]].name else "";
            try rc.writeColumnSuffix(w, col, ref_indexes, null, self.dialect, tbl_name);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }
}

fn emitTables(self: *ReverseCodegen, w: anytype, schema: sp.SqlSchema, tmpl_list: []template_ext.TemplateCandidate) !void {
    for (schema.tables, 0..) |table, ti| {
        // CHECK map
        var check_map = std.StringHashMap([]const u8).init(self.alloc);
        defer check_map.deinit();
        for (table.checks) |ck| {
            if (ck.field_name.len > 0) {
                if (rc.reverseCheck(self.alloc, ck.expr, ck.field_name)) |tps_expr| {
                    try check_map.put(ck.field_name, tps_expr);
                }
            }
        }

        // Find which template this table belongs to (if any)
        var table_template: ?[]const u8 = null;
        var table_template_fields: []const sp.SqlColumn = &.{};
        for (tmpl_list) |t| {
            for (t.table_indices) |ti2| {
                if (ti2 == ti) {
                    table_template = t.name;
                    table_template_fields = t.fields;
                    break;
                }
            }
            if (table_template != null) break;
        }

        // # [template_ref] table_name : comment
        try w.writeAll("# ");
        if (table_template) |tn| {
            try w.print("{s} ", .{tn});
        }
        try w.writeAll(table.name);
        if (table.comment) |c| {
            try w.print(" : {s}", .{c});
        }
        try w.writeAll("\n");

        if (table_template != null) {
            // Output fields not in template
            for (table.columns) |col| {
                var in_template = false;
                for (table_template_fields) |tcol| {
                    if (std.mem.eql(u8, col.name, tcol.name)) {
                        in_template = true;
                        break;
                    }
                }
                if (in_template) continue;
                try w.writeAll(col.name);
                const ck = if (col.check_expr) |ce| rc.reverseCheck(self.alloc, ce, col.name) else check_map.get(col.name);
                try rc.writeColumnSuffix(w, col, table.indexes, ck, self.dialect, table.name);
                try w.writeAll("\n");
            }
        } else {
            // No template — output all columns
            for (table.columns) |col| {
                try w.writeAll(col.name);
                const ck = if (col.check_expr) |ce| rc.reverseCheck(self.alloc, ce, col.name) else check_map.get(col.name);
                try rc.writeColumnSuffix(w, col, table.indexes, ck, self.dialect, table.name);
                try w.writeAll("\n");
            }
        }

        try emitStandaloneIndexes(self, w, table);
        try emitForeignKeys(self, w, table);

        if (ti < schema.tables.len - 1) try w.writeAll("\n");
    }
}

fn emitStandaloneIndexes(self: *ReverseCodegen, w: anytype, table: sp.SqlTable) !void {
    _ = self;
    for (table.indexes) |idx| {
        if (idx.kind == .primary_key) continue;
        if (rc.isInlineIndex(idx, table.name)) continue;

        try w.writeAll("\n");
        const is_auto = rc.isAutoGeneratedName(idx);
        switch (idx.kind) {
            .regular => {
                if (is_auto) {
                    try w.writeAll("@ ");
                    for (idx.fields, 0..) |f, fi| {
                        if (fi > 0) try w.writeAll(" ");
                        try w.writeAll(f);
                        if (fi < idx.descending.len and idx.descending[fi]) try w.writeAll("-");
                    }
                } else {
                    try w.print("@ {s} (", .{idx.name});
                    for (idx.fields, 0..) |f, fi| {
                        if (fi > 0) try w.writeAll(", ");
                        try w.writeAll(f);
                    }
                    try w.writeAll(")");
                }
            },
            .unique => {
                if (is_auto) {
                    try w.writeAll("@u ");
                    for (idx.fields, 0..) |f, fi| {
                        if (fi > 0) try w.writeAll(" ");
                        try w.writeAll(f);
                        if (fi < idx.descending.len and idx.descending[fi]) try w.writeAll("-");
                    }
                } else {
                    try w.print("@u {s} (", .{idx.name});
                    for (idx.fields, 0..) |f, fi| {
                        if (fi > 0) try w.writeAll(", ");
                        try w.writeAll(f);
                    }
                    try w.writeAll(")");
                }
            },
            .fulltext => try w.print("@f {s}", .{idx.name}),
            .primary_key => unreachable,
        }
    }
}

fn emitForeignKeys(self: *ReverseCodegen, w: anytype, table: sp.SqlTable) !void {
    for (table.foreign_keys) |fk| {
        const cls = rf.classifyFk(self.alloc, fk);
        if (cls.form == .ultra) continue;
        try w.writeAll("\n");
        if (cls.text) |txt| try w.writeAll(txt);
    }
}

// ─── Inline Tests ──────────────────────────────────────────────
// CHECK/FK/index tests live in their respective extracted modules:
// reverse_check.zig, reverse_fk.zig, reverse_column.zig.

test "ReverseCodegen basic generate" {
    const alloc = std.testing.allocator;
    const schema = sp.SqlSchema{
        .name = "testdb",
        .charset = "utf8mb4",
        .tables = &.{
            .{
                .name = "users",
                .engine = null,
                .charset = null,
                .comment = null,
                .columns = &.{
                    .{ .name = "id", .type_sql = "INTEGER", .nullable = false, .unsigned = false, .auto_increment = true, .primary_key = true, .on_update_current_timestamp = false, .default_val = null, .check_expr = null, .comment = null, .tps_override = "n" },
                    .{ .name = "name", .type_sql = "TEXT", .nullable = false, .unsigned = false, .auto_increment = false, .primary_key = false, .on_update_current_timestamp = false, .default_val = null, .check_expr = null, .comment = null, .tps_override = "s32" },
                },
                .indexes = &.{},
                .foreign_keys = &.{},
                .checks = &.{},
            },
        },
    };
    var rgen = ReverseCodegen.init(alloc, .sqlite);
    const output = try rgen.generate(schema);
    defer alloc.free(output);

    // Should contain schema name
    try std.testing.expect(std.mem.indexOf(u8, output, "$ testdb") != null);
    // Should contain table definition
    try std.testing.expect(std.mem.indexOf(u8, output, "# users") != null);
    // Should contain fields with TPS types from override
    try std.testing.expect(std.mem.indexOf(u8, output, "id n++") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name s32") != null);
}
