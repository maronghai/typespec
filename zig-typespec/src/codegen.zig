const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const ModifierType = ast_mod.ModifierType;
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;
const CheckConstraint = ast_mod.CheckConstraint;
const SqlComment = ast_mod.SqlComment;

pub const Dialect = type_map.Dialect;

pub const Codegen = struct {
    alloc: std.mem.Allocator,
    dialect: Dialect,

    pub fn init(alloc: std.mem.Allocator, dialect: Dialect) Codegen {
        return .{ .alloc = alloc, .dialect = dialect };
    }

    // ─── Identifier quoting ────────────────────────────────────

    fn quoteIdent(self: Codegen, w: anytype, name: []const u8) !void {
        switch (self.dialect) {
            .mysql => try w.print("`{s}`", .{name}),
            .postgres, .sqlite => try w.print("\"{s}\"", .{name}),
        }
    }

    // ─── CREATE DATABASE ───────────────────────────────────────

    fn emitCreateDatabase(self: Codegen, w: anytype, name: []const u8, charset: ?[]const u8) !void {
        switch (self.dialect) {
            .mysql => {
                if (charset) |cs| {
                    try w.print("CREATE DATABASE `{s}` CHARACTER SET {s};\n\n", .{ name, cs });
                } else {
                    try w.print("CREATE DATABASE `{s}`;\n\n", .{name});
                }
            },
            .postgres => {
                if (charset) |_| {
                    try w.print("CREATE DATABASE \"{s}\" ENCODING 'UTF8';\n\n", .{name});
                } else {
                    try w.print("CREATE DATABASE \"{s}\";\n\n", .{name});
                }
            },
            .sqlite => {
                // SQLite has no CREATE DATABASE statement (file-based)
            },
        }
    }

    // ─── Type mapping ──────────────────────────────────────────

    fn emitType(self: Codegen, w: anytype, field: Field) !void {
        try type_map.toSqlType(w, self.dialect, field.type_info);
    }

    // ─── Field comment ─────────────────────────────────────────

    fn emitFieldComment(self: Codegen, w: anytype, comment: ?[]const u8) !void {
        if (comment) |c| {
            if (c.len >= 1 and c[0] == ':') {
                switch (self.dialect) {
                    .mysql => {
                        try w.print(" COMMENT '{s}'", .{std.mem.trim(u8, c[1..], " ")});
                    },
                    .postgres, .sqlite => {
                        // PG: COMMENT ON after table; SQLite: SQL comment after table
                    },
                }
            } else if (c.len >= 2 and c[0] == '-' and c[1] == '-') {
                try w.writeAll(" ");
                try w.writeAll(c);
            }
        }
    }

    // ─── Inline indexes (pass 1b) ─────────────────────────────

    fn emitInlineIndexes(self: Codegen, w: anytype, table: sem.ResolvedTable, needs_comma: *bool) !void {
        for (table.fields) |field| {
            // Inline unique modifier (skip if explicit index already covers this field)
            var has_inline_unique = false;
            for (field.modifiers) |mod| {
                if (mod.kind == .inline_unique) {
                    has_inline_unique = true;
                    break;
                }
            }
            if (has_inline_unique) {
                var dominated = false;
                for (table.indexes) |idx| {
                    if (idx.kind == .unique or idx.kind == .primary_key) {
                        for (idx.fields) |f| {
                            if (std.mem.eql(u8, f, field.name)) {
                                dominated = true;
                                break;
                            }
                        }
                    }
                    if (dominated) break;
                }
                if (!dominated) {
                    if (needs_comma.*) try w.writeAll(",\n");
                    needs_comma.* = true;
                    switch (self.dialect) {
                        .mysql => try w.print("  UNIQUE INDEX `uk_{s}` (`{s}`)", .{ field.name, field.name }),
                        .postgres, .sqlite => try w.print("  UNIQUE (\"{s}\")", .{field.name}),
                    }
                }
            }
            // Inline index modifier (skip if explicit index already covers this field)
            var has_inline_index = false;
            for (field.modifiers) |mod| {
                if (mod.kind == .inline_index) {
                    has_inline_index = true;
                    break;
                }
            }
            if (has_inline_index) {
                var dominated = false;
                for (table.indexes) |idx| {
                    for (idx.fields) |f| {
                        if (std.mem.eql(u8, f, field.name)) {
                            dominated = true;
                            break;
                        }
                    }
                    if (dominated) break;
                }
                if (!dominated and self.dialect == .mysql) {
                    if (needs_comma.*) try w.writeAll(",\n");
                    needs_comma.* = true;
                    try w.print("  INDEX `idx_{s}` (`{s}`)", .{ field.name, field.name });
                }
                // PG: inline INDEX not supported — skip silently (use CREATE INDEX separately)
            }
        }
    }

    // ─── Standalone indexes ────────────────────────────────────

    fn emitIndexes(self: Codegen, w: anytype, indexes: []const IndexDecl, needs_comma: *bool) !void {
        for (indexes) |idx| {
            switch (self.dialect) {
                .mysql => try self.emitMysqlIndex(w, idx, needs_comma),
                .postgres => try self.emitPostgresIndex(w, idx, needs_comma),
                .sqlite => try self.emitSqliteIndex(w, idx, needs_comma),
            }
        }
    }

    fn emitMysqlIndex(self: Codegen, w: anytype, idx: IndexDecl, needs_comma: *bool) !void {
        _ = self;
        if (needs_comma.*) try w.writeAll(",\n");
        needs_comma.* = true;
        try w.writeAll("  ");
        switch (idx.kind) {
            .regular => try w.writeAll("INDEX"),
            .unique => try w.writeAll("UNIQUE INDEX"),
            .fulltext => try w.writeAll("FULLTEXT INDEX"),
            .primary_key => try w.writeAll("PRIMARY KEY"),
        }
        if (idx.kind == .primary_key) {
            try w.writeAll(" (");
        } else {
            try w.print(" `{s}` (", .{idx.name});
        }
        for (idx.fields, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(", ");
            try w.print("`{s}`", .{f});
        }
        try w.writeAll(")");
    }

    fn emitPostgresIndex(self: Codegen, w: anytype, idx: IndexDecl, needs_comma: *bool) !void {
        _ = self;
        switch (idx.kind) {
            .regular => {
                // PG: regular INDEX not supported inline — emitted as standalone CREATE INDEX later
                return;
            },
            .fulltext => {
                // PG has no inline FULLTEXT; skip silently (no standalone equivalent in PG)
                return;
            },
            .unique => {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.writeAll("  UNIQUE (");
                for (idx.fields, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{f});
                }
                try w.writeAll(")");
            },
            .primary_key => {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.writeAll("  PRIMARY KEY (");
                for (idx.fields, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{f});
                }
                try w.writeAll(")");
            },
        }
    }

    fn emitSqliteIndex(self: Codegen, w: anytype, idx: IndexDecl, needs_comma: *bool) !void {
        _ = self;
        switch (idx.kind) {
            .regular => {
                // SQLite: regular INDEX emitted as standalone CREATE INDEX later
                return;
            },
            .fulltext => {
                // SQLite FTS is via virtual tables, not inline; skip silently
                return;
            },
            .unique => {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.writeAll("  UNIQUE (");
                for (idx.fields, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{f});
                }
                try w.writeAll(")");
            },
            .primary_key => {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.writeAll("  PRIMARY KEY (");
                for (idx.fields, 0..) |f, fi| {
                    if (fi > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{f});
                }
                try w.writeAll(")");
            },
        }
    }

    // ─── Foreign keys ──────────────────────────────────────────

    fn emitFkInline(self: Codegen, w: anytype, field: Field, needs_comma: *bool) !void {
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

    fn emitFkStandalone(self: Codegen, w: anytype, fk: FkDecl, needs_comma: *bool) !void {
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

    fn emitFkActions(self: Codegen, w: anytype, actions: []const ast_mod.FkAction) !void {
        _ = self;
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

    fn emitFieldModifiers(self: Codegen, w: anytype, field: Field, has_auto_inc: *bool, has_pk: *bool, has_not_null: *bool) !void {
        for (field.modifiers) |mod| {
            switch (mod.kind) {
                .auto_inc_pk => {
                    switch (self.dialect) {
                        .mysql, .sqlite => {
                            // Handled via has_auto_inc/has_pk flags below
                        },
                        .postgres => {
                            // GENERATED ALWAYS AS IDENTITY handled in emitPostgresFieldSuffix
                        },
                    }
                    if (self.isNumericType(field.type_info)) {
                        has_auto_inc.* = true;
                        has_pk.* = true;
                    } else if (self.isDatetimeType(field.type_info)) {
                        try self.emitTimestampModifier(w, true);
                    }
                },
                .auto_inc => {
                    if (self.isNumericType(field.type_info)) {
                        has_auto_inc.* = true;
                    } else if (self.isDatetimeType(field.type_info)) {
                        try self.emitTimestampModifier(w, false);
                    }
                },
                .primary_key => has_pk.* = true,
                .not_null => has_not_null.* = true,
                .unsigned => {
                    switch (self.dialect) {
                        .mysql => try w.writeAll(" UNSIGNED"),
                        .postgres, .sqlite => {}, // PG/SQLite have no UNSIGNED
                    }
                },
                .inline_unique => {},
                .inline_index => {},
            }
        }
    }

    fn emitTimestampModifier(self: Codegen, w: anytype, with_on_update: bool) !void {
        switch (self.dialect) {
            .mysql => {
                try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
                if (with_on_update) {
                    try w.writeAll(" ON UPDATE CURRENT_TIMESTAMP");
                }
            },
            .postgres, .sqlite => {
                try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
                // PG/SQLite have no ON UPDATE; omit it
            },
        }
    }

    fn isNumericType(self: Codegen, ti: TypeInfo) bool {
        _ = self;
        return type_map.isNumericTpsType(ti);
    }

    fn isDatetimeType(self: Codegen, ti: TypeInfo) bool {
        _ = self;
        return type_map.isDatetimeTpsType(ti);
    }

    // ─── Field suffix (post-column) ────────────────────────────

    fn emitFieldSuffix(self: Codegen, w: anytype, field: Field, has_auto_inc: bool, has_pk: bool) !void {
        switch (self.dialect) {
            .mysql => try emitMysqlFieldSuffix(w, field, has_auto_inc, has_pk),
            .postgres => try self.emitPostgresFieldSuffix(w, field, has_auto_inc, has_pk),
            .sqlite => try emitSqliteFieldSuffix(w, field, has_auto_inc, has_pk),
        }
    }

    fn emitMysqlFieldSuffix(w: anytype, field: Field, has_auto_inc: bool, has_pk: bool) !void {
        if (has_auto_inc) try w.writeAll(" AUTO_INCREMENT");
        if (has_pk) try w.writeAll(" PRIMARY KEY");
        if (field.check) |ck| {
            try w.writeAll(" CHECK (");
            try generateCheckExpr(w, field.name, ck);
            try w.writeAll(")");
        }
    }

    fn emitPostgresFieldSuffix(self: Codegen, w: anytype, field: Field, has_auto_inc: bool, has_pk: bool) !void {
        if (has_auto_inc) {
            // Check if this is a datetime field with auto_inc — PG uses DEFAULT CURRENT_TIMESTAMP
            if (self.isDatetimeType(field.type_info)) {
                // Already emitted DEFAULT CURRENT_TIMESTAMP via emitTimestampModifier
            } else {
                try w.writeAll(" GENERATED ALWAYS AS IDENTITY");
            }
        }
        if (has_pk) try w.writeAll(" PRIMARY KEY");
        if (field.check) |ck| {
            try w.writeAll(" CHECK (");
            try generateCheckExpr(w, field.name, ck);
            try w.writeAll(")");
        }
    }

    fn emitSqliteFieldSuffix(w: anytype, field: Field, has_auto_inc: bool, has_pk: bool) !void {
        // SQLite: PRIMARY KEY AUTOINCREMENT (only valid on INTEGER PRIMARY KEY)
        if (has_auto_inc and has_pk) {
            try w.writeAll(" PRIMARY KEY AUTOINCREMENT");
        } else if (has_pk) {
            try w.writeAll(" PRIMARY KEY");
        }
        if (field.check) |ck| {
            try w.writeAll(" CHECK (");
            try generateCheckExpr(w, field.name, ck);
            try w.writeAll(")");
        }
    }

    // ─── ENUM CHECK constraint for PostgreSQL/SQLite ───────────

    fn emitEnumCheck(self: Codegen, w: anytype, field: Field) !void {
        if (self.dialect != .postgres and self.dialect != .sqlite) return;
        if (field.type_info != .enum_type) return;
        const vals = field.type_info.enum_type;
        if (vals.len == 0) return;

        // We've already output "text" as the type; now emit an inline CHECK
        // but since we want it as a table-level constraint, we'll store it
        // and emit later. For simplicity, emit inline CHECK here.
        try w.writeAll(" CHECK (");
        try w.print("\"{s}\" IN (", .{field.name});
        for (vals, 0..) |v, vi| {
            if (vi > 0) try w.writeAll(", ");
            try w.print("'{s}'", .{v});
        }
        try w.writeAll("))");
    }

    // ─── Table footer (ENGINE, CHARSET, COMMENT) ───────────────

    fn emitTableFooter(self: Codegen, w: anytype, table: sem.ResolvedTable, schema_charset: ?[]const u8) !void {
        switch (self.dialect) {
            .mysql => {
                const charset = schema_charset orelse "utf8mb4";
                const engine = table.engine orelse "InnoDB";
                if (table.comment) |c| {
                    const comment_text = if (c.len >= 1 and c[0] == ':') c[1..] else c;
                    const trimmed = std.mem.trim(u8, comment_text, " ");
                    try w.print(") ENGINE={s} DEFAULT CHARSET={s} COMMENT='{s}';\n", .{ engine, charset, trimmed });
                } else {
                    try w.print(") ENGINE={s} DEFAULT CHARSET={s};\n", .{ engine, charset });
                }
            },
            .postgres => {
                try w.writeAll(");\n");
            },
            .sqlite => {
                try w.writeAll(");\n");
            },
        }
    }

    // ─── COMMENT ON for PostgreSQL ─────────────────────────────

    fn emitPostgresComments(self: Codegen, w: anytype, table: sem.ResolvedTable) !void {
        if (self.dialect != .postgres) return;
        if (table.comment) |c| {
            const comment_text = if (c.len >= 1 and c[0] == ':') c[1..] else c;
            const trimmed = std.mem.trim(u8, comment_text, " ");
            if (trimmed.len > 0) {
                try w.print("COMMENT ON TABLE \"{s}\" IS '{s}';\n", .{ table.name, trimmed });
            }
        }
        for (table.fields) |field| {
            if (std.mem.eql(u8, field.name, "...")) continue;
            if (field.comment) |c| {
                if (c.len >= 1 and c[0] == ':') {
                    const trimmed = std.mem.trim(u8, c[1..], " ");
                    if (trimmed.len > 0) {
                        try w.print("COMMENT ON COLUMN \"{s}\".\"{s}\" IS '{s}';\n", .{ table.name, field.name, trimmed });
                    }
                }
            }
        }
    }

    /// Emit SQLite column/table comments as SQL line comments after CREATE TABLE.
    fn emitSqliteComments(self: Codegen, w: anytype, table: sem.ResolvedTable) !void {
        if (self.dialect != .sqlite) return;
        // Table comment
        if (table.comment) |c| {
            const comment_text = if (c.len >= 1 and c[0] == ':') c[1..] else c;
            const trimmed = std.mem.trim(u8, comment_text, " ");
            if (trimmed.len > 0) {
                try w.print("-- {s}\n", .{trimmed});
            }
        }
        // Column comments
        for (table.fields) |field| {
            if (std.mem.eql(u8, field.name, "...")) continue;
            if (field.comment) |c| {
                if (c.len >= 1 and c[0] == ':') {
                    const trimmed = std.mem.trim(u8, c[1..], " ");
                    if (trimmed.len > 0) {
                        try w.print("-- {s}.{s}: {s}\n", .{ table.name, field.name, trimmed });
                    }
                }
            }
        }
    }

    /// Emit standalone CREATE INDEX statements for PG/SQLite (after CREATE TABLE).
    fn emitStandaloneIndexes(self: Codegen, w: anytype, table: sem.ResolvedTable) !void {
        if (self.dialect == .mysql) return; // MySQL uses inline indexes
        for (table.indexes) |idx| {
            if (idx.kind == .primary_key) continue; // PK is inline
            if (idx.kind == .unique) continue; // UNIQUE is inline in PG/SQLite
            if (idx.kind == .fulltext) continue; // FULLTEXT not supported in PG/SQLite
            try w.writeAll("CREATE INDEX ");
            if (idx.name.len > 0) {
                try w.print("\"{s}\"", .{idx.name});
            } else {
                try w.print("\"idx_{s}_{s}\"", .{ table.name, idx.fields[0] });
            }
            try w.print(" ON \"{s}\" (", .{table.name});
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(");\n");
        }
    }

    // ─── Public API ────────────────────────────────────────────

    pub fn generate(self: *Codegen, resolved: sem.ResolvedAst) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;

        // Header comment
        try w.writeAll("-- Generated by zig-typespec\n\n");

        // CREATE DATABASE
        if (resolved.schema_name) |name| {
            try self.emitCreateDatabase(w, name, resolved.schema_charset);
        }

        // CREATE TABLEs — interleaved with SQL comments by line number
        var ti: usize = 0;
        var ci: usize = 0;
        while (ti < resolved.tables.len or ci < resolved.sql_comments.len) {
            const table_line = if (ti < resolved.tables.len) resolved.tables[ti].line_no else std.math.maxInt(usize);
            const comment_line = if (ci < resolved.sql_comments.len) resolved.sql_comments[ci].line_no else std.math.maxInt(usize);

            if (comment_line < table_line) {
                // Emit SQL comment before its associated table
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

    pub fn generateTable(self: *Codegen, w: anytype, table: sem.ResolvedTable, schema_charset: ?[]const u8) !void {
        try w.writeAll("CREATE TABLE ");
        try self.quoteIdent(w, table.name);
        try w.writeAll(" (\n");

        var needs_comma = false;

        // Pass 1: emit all columns (no inline indexes yet)
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

            if (has_not_null) {
                try w.writeAll(" NOT NULL");
            }

            if (field.default_val) |dv| {
                try emitDefault(w, dv.value);
            }

            try self.emitFieldSuffix(w, field, has_auto_inc, has_pk);

            // MySQL: inline comment
            try self.emitFieldComment(w, field.comment);

            // PostgreSQL/SQLite: ENUM CHECK constraint (inline)
            if ((self.dialect == .postgres or self.dialect == .sqlite) and field.type_info == .enum_type) {
                try self.emitEnumCheck(w, field);
            }
        }

        // Pass 1b: emit inline indexes (after all columns, before standalone indexes/FKs)
        try self.emitInlineIndexes(w, table, &needs_comma);

        // Indexes (between columns and FKs)
        try self.emitIndexes(w, table.indexes, &needs_comma);

        // Pass 2: emit inline FKs
        for (table.fields) |field| {
            try self.emitFkInline(w, field, &needs_comma);
        }

        // Foreign keys
        for (table.fks) |fk| {
            try self.emitFkStandalone(w, fk, &needs_comma);
        }

        if (needs_comma) try w.writeAll("\n");

        // Table footer: ENGINE, CHARSET, COMMENT (MySQL) or close paren (PG)
        try self.emitTableFooter(w, table, schema_charset);

        // PostgreSQL: COMMENT ON statements after table
        try self.emitPostgresComments(w, table);

        // SQLite: column/table comments as SQL line comments
        try self.emitSqliteComments(w, table);

        // PostgreSQL/SQLite: standalone CREATE INDEX statements (after table + comments)
        try self.emitStandaloneIndexes(w, table);
    }

    fn emitDefault(w: anytype, value: []const u8) !void {
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
};

pub fn generateCheckExpr(w: anytype, field_name: []const u8, ck: CheckConstraint) !void {
    switch (ck.kind) {
        .range => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} BETWEEN {s} AND {s}", .{ field_name, low, high });
        },
        .range_upper_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} >= {s} AND {s} < {s}", .{ field_name, low, field_name, high });
        },
        .range_lower_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} > {s} AND {s} <= {s}", .{ field_name, low, field_name, high });
        },
        .range_both_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} > {s} AND {s} < {s}", .{ field_name, low, field_name, high });
        },
        .in_list => {
            try w.print("{s} IN (", .{field_name});
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            var first = true;
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try w.writeAll(", ");
                first = false;
                const is_num = blk: {
                    _ = std.fmt.parseFloat(f64, trimmed) catch break :blk false;
                    break :blk true;
                };
                if (is_num) {
                    try w.print("{s}", .{trimmed});
                } else {
                    // Strip existing quotes to avoid double-quoting
                    const val = if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
                        trimmed[1 .. trimmed.len - 1]
                    else
                        trimmed;
                    try w.print("'{s}'", .{val});
                }
            }
            try w.writeAll(")");
        },
        .comparison => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            var first = true;
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try w.writeAll(" AND ");
                first = false;

                if (trimmed[0] == '>' and trimmed.len > 1 and trimmed[1] == '=') {
                    try w.print("{s} >= {s}", .{ field_name, trimmed[2..] });
                } else if (trimmed[0] == '<' and trimmed.len > 1 and trimmed[1] == '=') {
                    try w.print("{s} <= {s}", .{ field_name, trimmed[2..] });
                } else if (trimmed[0] == '>') {
                    try w.print("{s} > {s}", .{ field_name, trimmed[1..] });
                } else if (trimmed[0] == '<') {
                    try w.print("{s} < {s}", .{ field_name, trimmed[1..] });
                } else if (trimmed[0] == '=') {
                    try w.print("{s} = {s}", .{ field_name, trimmed[1..] });
                } else {
                    try w.print("{s} = {s}", .{ field_name, trimmed });
                }
            }
        },
    }
}

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
            // Skip PRIMARY KEY lines (they're inside CREATE TABLE)
        } else if (std.mem.indexOf(u8, trimmed, "FOREIGN KEY") != null) {
            fk_count += 1;
        } else if (std.mem.indexOf(u8, trimmed, "INDEX") != null or std.mem.indexOf(u8, trimmed, "UNIQUE INDEX") != null or std.mem.indexOf(u8, trimmed, "FULLTEXT INDEX") != null) {
            index_count += 1;
        }
    }

    // Count columns: lines that start with backtick (column definitions)
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
