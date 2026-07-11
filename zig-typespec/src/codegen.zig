const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const dialect_mod = @import("dialect.zig");
const typed_ast_mod = @import("typed_ast.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const IndexDecl = ast_mod.IndexDecl;
const CheckConstraint = ast_mod.CheckConstraint;
const SqlComment = ast_mod.SqlComment;
const Writer = std.Io.Writer;

pub const Dialect = type_map.Dialect;

pub const Codegen = struct {
    alloc: std.mem.Allocator,
    dialect: Dialect,
    backend: dialect_mod.DialectBackend,

    pub fn init(alloc: std.mem.Allocator, dialect: Dialect) Codegen {
        return .{
            .alloc = alloc,
            .dialect = dialect,
            .backend = dialect_mod.getBackend(dialect),
        };
    }

    // ─── Delegated backend calls ───────────────────────────────

    fn quoteIdent(self: Codegen, w: *Writer, name: []const u8) !void {
        try self.backend.quoteIdent(w, name);
    }

    fn emitCreateDatabase(self: Codegen, w: *Writer, name: []const u8, charset: ?[]const u8) !void {
        try self.backend.emitCreateDatabase(w, name, charset);
    }

    fn emitType(self: Codegen, w: *Writer, field: Field) !void {
        try type_map.toSqlType(w, self.dialect, field.type_info);
    }

    fn emitFieldComment(self: Codegen, w: *Writer, comment: ?[]const u8) !void {
        try self.backend.emitFieldComment(w, comment);
    }

    fn emitInlineIndexes(self: Codegen, w: *Writer, table: sem.ResolvedTable, needs_comma: *bool) !void {
        try self.backend.emitInlineIndexes(w, table, needs_comma);
    }

    fn emitIndexes(self: Codegen, w: *Writer, indexes: []const IndexDecl, needs_comma: *bool) !void {
        for (indexes) |idx| {
            try self.backend.emitIndex(w, idx, needs_comma);
        }
    }

    // ─── Foreign keys (dialect-independent) ────────────────────

    fn emitFkInline(self: Codegen, w: *Writer, field: Field, needs_comma: *bool) !void {
        if (field.fk) |fk| {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  FOREIGN KEY (");
            for (fk.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try self.quoteIdent(w, f);
            }
            try w.writeAll(") REFERENCES ");
            try self.quoteIdent(w, fk.ref_table);
            try w.writeAll("(");
            for (fk.ref_fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try self.quoteIdent(w, f);
            }
            try w.writeAll(")");
            try self.emitFkActions(w, fk.actions);
        }
    }

    fn emitFkStandalone(self: Codegen, w: *Writer, fk: FkDecl, needs_comma: *bool) !void {
        if (needs_comma.*) try w.writeAll(",\n");
        needs_comma.* = true;
        try w.writeAll("  FOREIGN KEY (");
        for (fk.fields, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(", ");
            try self.quoteIdent(w, f);
        }
        try w.writeAll(") REFERENCES ");
        try self.quoteIdent(w, fk.ref_table);
        try w.writeAll("(");
        for (fk.ref_fields, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(", ");
            try self.quoteIdent(w, f);
        }
        try w.writeAll(")");
        try self.emitFkActions(w, fk.actions);
    }

    fn emitFkActions(_: Codegen, w: *Writer, actions: []const FkAction) !void {
        for (actions) |action| {
            try w.writeAll(" ");
            switch (action.trigger) {
                .on_delete => try w.writeAll("ON DELETE"),
                .on_update => try w.writeAll("ON UPDATE"),
            }
            try w.writeAll(" ");
            switch (action.action) {
                .cascade => try w.writeAll("CASCADE"),
                .set_null => try w.writeAll("SET NULL"),
            }
        }
    }

    // ─── Field modifiers ───────────────────────────────────────

    fn emitFieldModifiers(self: Codegen, w: *Writer, field: Field, has_auto_inc: *bool, has_pk: *bool, has_not_null: *bool) !void {
        for (field.modifiers) |mod| {
            switch (mod.kind) {
                .auto_inc_pk => {
                    if (type_map.isNumericTpsType(field.type_info)) {
                        has_auto_inc.* = true;
                        has_pk.* = true;
                    } else if (type_map.isDatetimeTpsType(field.type_info)) {
                        try self.backend.emitTimestampModifier(w, true);
                    }
                },
                .auto_inc => {
                    if (type_map.isNumericTpsType(field.type_info)) {
                        has_auto_inc.* = true;
                    } else if (type_map.isDatetimeTpsType(field.type_info)) {
                        try self.backend.emitTimestampModifier(w, false);
                    }
                },
                .primary_key => has_pk.* = true,
                .not_null => has_not_null.* = true,
                .unsigned => try self.backend.emitUnsigned(w),
                .inline_unique => {},
                .inline_index => {},
            }
        }
    }

    // ─── Field suffix (post-column) ────────────────────────────

    fn emitFieldSuffix(self: Codegen, w: *Writer, field: Field, has_auto_inc: bool, has_pk: bool) !void {
        const is_datetime = type_map.isDatetimeTpsType(field.type_info);
        try self.backend.emitFieldSuffix(w, field, has_auto_inc, has_pk, is_datetime);
    }

    // ─── ENUM CHECK constraint for PostgreSQL/SQLite ───────────

    fn emitEnumCheck(self: Codegen, w: *Writer, field: Field) !void {
        if (self.dialect != .postgres and self.dialect != .sqlite) return;
        if (field.type_info != .enum_type) return;
        const vals = field.type_info.enum_type;
        if (vals.len == 0) return;
        try w.writeAll(" CHECK (");
        try w.print("\"{s}\" IN (", .{field.name});
        for (vals, 0..) |v, vi| {
            if (vi > 0) try w.writeAll(", ");
            try w.print("'{s}'", .{v});
        }
        try w.writeAll("))");
    }

    // ─── Table footer + post-table emissions ───────────────────

    fn emitTableFooter(self: Codegen, w: *Writer, table: sem.ResolvedTable, schema_charset: ?[]const u8) !void {
        try self.backend.emitFooter(w, table, schema_charset);
    }

    fn emitPostComments(self: Codegen, w: *Writer, table: sem.ResolvedTable) !void {
        try self.backend.emitComments(w, table);
    }

    fn emitStandaloneIndexes(self: Codegen, w: *Writer, table: sem.ResolvedTable) !void {
        try self.backend.emitStandaloneIndexes(w, table);
    }

    // ─── Public API ────────────────────────────────────────────

    pub fn generate(self: *Codegen, resolved: sem.ResolvedAst) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;

        try w.writeAll("-- Generated by zig-typespec\n\n");

        if (resolved.schema_name) |name| {
            try self.emitCreateDatabase(w, name, resolved.schema_charset);
        }

        var ti: usize = 0;
        var ci: usize = 0;
        while (ti < resolved.tables.len or ci < resolved.sql_comments.len) {
            const table_line = if (ti < resolved.tables.len) resolved.tables[ti].line_no else std.math.maxInt(usize);
            const comment_line = if (ci < resolved.sql_comments.len) resolved.sql_comments[ci].line_no else std.math.maxInt(usize);

            if (comment_line < table_line) {
                try w.writeAll(resolved.sql_comments[ci].text);
                try w.writeAll("\n");
                ci += 1;
            } else if (ti < resolved.tables.len) {
                try self.generateTable(w, resolved.tables[ti], resolved.schema_charset);
                ti += 1;
                if (ti < resolved.tables.len or ci < resolved.sql_comments.len) {
                    try w.writeAll("\n");
                }
            }
        }

        try w.flush();
        var out = aw.toArrayList();
        return try out.toOwnedSlice(self.alloc);
    }

    pub fn generateSingleTable(self: *Codegen, table: sem.ResolvedTable, schema_charset: ?[]const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;
        try self.generateTable(w, table, schema_charset);
        try w.flush();
        var out = aw.toArrayList();
        return try out.toOwnedSlice(self.alloc);
    }

    // ─── TypedAst API ──────────────────────────────────────────

    pub fn generateFromTypedAst(self: *Codegen, typed: typed_ast_mod.TypedAst) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;

        try w.writeAll("-- Generated by zig-typespec\n\n");

        if (typed.schema_name) |name| {
            try self.backend.emitCreateDatabase(w, name, typed.schema_charset);
        }

        var ti: usize = 0;
        while (ti < typed.tables.len) {
            try self.generateTypedTable(w, typed.tables[ti]);
            ti += 1;
            if (ti < typed.tables.len) {
                try w.writeAll("\n");
            }
        }

        try w.flush();
        var out = aw.toArrayList();
        return try out.toOwnedSlice(self.alloc);
    }

    fn generateTypedTable(self: Codegen, w: *Writer, table: typed_ast_mod.TypedTable) !void {
        try w.writeAll("CREATE TABLE ");
        try self.quoteIdent(w, table.name);
        try w.writeAll(" (\n");

        var needs_comma = false;

        // Columns
        for (table.columns) |col| {
            if (needs_comma) try w.writeAll(",\n");
            needs_comma = true;
            try w.writeAll("  ");
            try self.quoteIdent(w, col.name);
            try w.print(" {s}", .{col.sql_type});

            if (col.unsigned) try self.backend.emitUnsigned(w);
            if (col.auto_increment and self.dialect == .mysql) try w.writeAll(" AUTO_INCREMENT");
            if (col.auto_increment and self.dialect == .postgres and !col.is_datetime) try w.writeAll(" GENERATED ALWAYS AS IDENTITY");
            if (col.primary_key and !(col.auto_increment and self.dialect == .sqlite)) {
                try w.writeAll(" PRIMARY KEY");
            }
            if (col.auto_increment and col.primary_key and self.dialect == .sqlite) {
                try w.writeAll(" PRIMARY KEY AUTOINCREMENT");
            }
            if (col.default) |dv| try emitDefault(w, dv);
            if (col.check) |ck| {
                try w.writeAll(" CHECK (");
                try dialect_mod.emitCheckExpr(w, col.name, ck);
                try w.writeAll(")");
            }
            if (col.comment) |c| {
                if (c.len >= 1 and c[0] == ':' and self.dialect == .mysql) {
                    try w.print(" COMMENT '{s}'", .{std.mem.trim(u8, c[1..], " ")});
                }
            }
            if (col.is_enum and (self.dialect == .postgres or self.dialect == .sqlite)) {
                try w.writeAll(" CHECK (");
                try w.print("\"{s}\" IN (", .{col.name});
                for (col.enum_values, 0..) |v, vi| {
                    if (vi > 0) try w.writeAll(", ");
                    try w.print("'{s}'", .{v});
                }
                try w.writeAll("))");
            }
        }

        // Inline indexes
        for (table.columns) |col| {
            if (col.inline_unique) {
                var dominated = false;
                for (table.indexes) |idx| {
                    if (idx.kind == .unique or idx.kind == .primary_key) {
                        for (idx.fields) |f| { if (std.mem.eql(u8, f, col.name)) { dominated = true; break; } }
                    }
                    if (dominated) break;
                }
                if (!dominated) {
                    if (needs_comma) try w.writeAll(",\n");
                    needs_comma = true;
                    switch (self.dialect) {
                        .mysql => try w.print("  UNIQUE INDEX `uk_{s}` (`{s}`)", .{ col.name, col.name }),
                        .postgres, .sqlite => try w.print("  UNIQUE (\"{s}\")", .{col.name}),
                    }
                }
            }
            if (col.inline_index and self.dialect == .mysql) {
                var dominated = false;
                for (table.indexes) |idx| {
                    for (idx.fields) |f| { if (std.mem.eql(u8, f, col.name)) { dominated = true; break; } }
                    if (dominated) break;
                }
                if (!dominated) {
                    if (needs_comma) try w.writeAll(",\n");
                    needs_comma = true;
                    try w.print("  INDEX `idx_{s}` (`{s}`)", .{ col.name, col.name });
                }
            }
        }

        // Standalone indexes
        for (table.indexes) |idx| {
            try self.backend.emitIndex(w, idx, &needs_comma);
        }

        // FKs
        for (table.fks) |fk| {
            if (needs_comma) try w.writeAll(",\n");
            needs_comma = true;
            try w.writeAll("  FOREIGN KEY (");
            for (fk.fields, 0..) |f, fi| { if (fi > 0) try w.writeAll(", "); try self.quoteIdent(w, f); }
            try w.writeAll(") REFERENCES ");
            try self.quoteIdent(w, fk.ref_table);
            try w.writeAll("(");
            for (fk.ref_fields, 0..) |f, fi| { if (fi > 0) try w.writeAll(", "); try self.quoteIdent(w, f); }
            try w.writeAll(")");
            for (fk.actions) |action| {
                try w.writeAll(" ");
                switch (action.trigger) { .on_delete => try w.writeAll("ON DELETE"), .on_update => try w.writeAll("ON UPDATE") }
                try w.writeAll(" ");
                switch (action.action) { .cascade => try w.writeAll("CASCADE"), .set_null => try w.writeAll("SET NULL") }
            }
        }

        if (needs_comma) try w.writeAll("\n");

        // Footer (dialect-specific)
        switch (self.dialect) {
            .mysql => {
                const charset = table.comment; // unused for footer
                _ = charset;
                const cs = "utf8mb4";
                const engine = table.engine orelse "InnoDB";
                if (table.comment) |c| {
                    const ct = if (c.len >= 1 and c[0] == ':') c[1..] else c;
                    const tr = std.mem.trim(u8, ct, " ");
                    try w.print(") ENGINE={s} DEFAULT CHARSET={s} COMMENT='{s}';\n", .{ engine, cs, tr });
                } else {
                    try w.print(") ENGINE={s} DEFAULT CHARSET={s};\n", .{ engine, cs });
                }
            },
            .postgres, .sqlite => try w.writeAll(");\n"),
        }

        // Comments
        switch (self.dialect) {
            .mysql => {},
            .postgres => {
                if (table.comment) |c| {
                    const ct = if (c.len >= 1 and c[0] == ':') c[1..] else c;
                    const tr = std.mem.trim(u8, ct, " ");
                    if (tr.len > 0) try w.print("COMMENT ON TABLE \"{s}\" IS '{s}';\n", .{ table.name, tr });
                }
            },
            .sqlite => {
                if (table.comment) |c| {
                    const ct = if (c.len >= 1 and c[0] == ':') c[1..] else c;
                    const tr = std.mem.trim(u8, ct, " ");
                    if (tr.len > 0) try w.print("-- {s}\n", .{tr});
                }
            },
        }

        // Standalone CREATE INDEX (PG/SQLite)
        if (self.dialect != .mysql) {
            for (table.indexes) |idx| {
                if (idx.kind == .primary_key or idx.kind == .unique or idx.kind == .fulltext) continue;
                try w.writeAll("CREATE INDEX ");
                if (idx.name.len > 0) {
                    try w.print("\"{s}\"", .{idx.name});
                } else {
                    try w.print("\"idx_{s}_{s}\"", .{ table.name, idx.fields[0] });
                }
                try w.print(" ON \"{s}\" (", .{table.name});
                for (idx.fields, 0..) |f, fi| { if (fi > 0) try w.writeAll(", "); try w.print("\"{s}\"", .{f}); }
                try w.writeAll(");\n");
            }
        }
    }

    pub fn generateTable(self: *Codegen, w: *Writer, table: sem.ResolvedTable, schema_charset: ?[]const u8) !void {
        try w.writeAll("CREATE TABLE ");
        try self.quoteIdent(w, table.name);
        try w.writeAll(" (\n");

        var needs_comma = false;

        // Pass 1: emit all columns
        for (table.fields) |field| {
            if (std.mem.eql(u8, field.name, "...")) continue;
            if (needs_comma) try w.writeAll(",\n");
            needs_comma = true;
            try w.writeAll("  ");
            try self.quoteIdent(w, field.name);
            try w.writeAll(" ");
            try self.emitType(w, field);

            var has_auto_inc = false;
            var has_pk = false;
            var has_not_null = false;

            try self.emitFieldModifiers(w, field, &has_auto_inc, &has_pk, &has_not_null);

            if (has_not_null) try w.writeAll(" NOT NULL");
            if (field.default_val) |dv| try emitDefault(w, dv.value);
            try self.emitFieldSuffix(w, field, has_auto_inc, has_pk);
            try self.emitFieldComment(w, field.comment);

            if ((self.dialect == .postgres or self.dialect == .sqlite) and field.type_info == .enum_type) {
                try self.emitEnumCheck(w, field);
            }
        }

        // Pass 1b: inline indexes
        try self.emitInlineIndexes(w, table, &needs_comma);

        // Standalone indexes
        try self.emitIndexes(w, table.indexes, &needs_comma);

        // Pass 2: inline FKs
        for (table.fields) |field| {
            try self.emitFkInline(w, field, &needs_comma);
        }

        // Standalone FKs
        for (table.fks) |fk| {
            try self.emitFkStandalone(w, fk, &needs_comma);
        }

        if (needs_comma) try w.writeAll("\n");

        // Table footer
        try self.emitTableFooter(w, table, schema_charset);

        // Post-table comments (PG: COMMENT ON, SQLite: -- comments)
        try self.emitPostComments(w, table);

        // Post-table CREATE INDEX (PG/SQLite)
        try self.emitStandaloneIndexes(w, table);
    }

    fn emitDefault(w: *Writer, value: []const u8) !void {
        const is_num_val = blk: {
            _ = std.fmt.parseFloat(f64, value) catch break :blk false;
            break :blk true;
        };
        const is_sql_keyword = std.mem.eql(u8, value, "CURRENT_TIMESTAMP") or
            std.mem.eql(u8, value, "NULL") or
            std.mem.eql(u8, value, "NOW()");
        if (is_num_val or is_sql_keyword) {
            try w.print(" DEFAULT {s}", .{value});
        } else {
            try w.print(" DEFAULT '{s}'", .{value});
        }
    }

    pub fn generateCheckExpr(self: Codegen, w: *Writer, field_name: []const u8, ck: CheckConstraint) !void {
        _ = self;
        try dialect_mod.emitCheckExpr(w, field_name, ck);
    }
};

// ─── Diagnostic ──────────────────────────────────────────────

pub fn diagnosticTrace(sql: []const u8) void {
    std.debug.print("=== [Stage 4: Codegen] ===\n\n", .{});

    var table_count: usize = 0;
    var field_count: usize = 0;
    var fk_count: usize = 0;
    var index_count: usize = 0;

    var line_it = std.mem.splitScalar(u8, sql, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "CREATE TABLE ")) {
            table_count += 1;
        } else if (trimmed.len > 0 and trimmed[0] == '`' and std.mem.indexOf(u8, trimmed, "PRIMARY KEY") != null) {
            // Skip PRIMARY KEY lines
        } else if (std.mem.indexOf(u8, trimmed, "FOREIGN KEY") != null) {
            fk_count += 1;
        } else if (std.mem.indexOf(u8, trimmed, "INDEX") != null or std.mem.indexOf(u8, trimmed, "UNIQUE INDEX") != null or std.mem.indexOf(u8, trimmed, "FULLTEXT INDEX") != null) {
            index_count += 1;
        }
    }

    var col_it = std.mem.splitScalar(u8, sql, '\n');
    while (col_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '`') {
            field_count += 1;
        }
    }

    std.debug.print("Tables:    {d}\n", .{table_count});
    std.debug.print("Columns:   {d}\n", .{field_count});
    std.debug.print("FKs:       {d}\n", .{fk_count});
    std.debug.print("Indexes:   {d}\n", .{index_count});
    std.debug.print("SQL lines: {d}\n", .{std.mem.count(u8, sql, "\n") + 1});
    std.debug.print("SQL bytes: {d}\n\n", .{sql.len});
}
