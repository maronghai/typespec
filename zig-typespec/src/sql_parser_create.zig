const std = @import("std");
const sp = @import("sql_parser.zig");
const common = @import("sql_parser_common.zig");
const Dialect = common.Dialect;
const SqlColumn = common.SqlColumn;
const SqlTable = common.SqlTable;
const SqlIndex = common.SqlIndex;
const SqlForeignKey = common.SqlForeignKey;
const SqlCheck = common.SqlCheck;

// ─── CREATE DATABASE / TABLE / Column Parsing ────────────────

pub fn parseCreateDatabase(self: *sp.SqlParser) !common.CreateDbResult {
    self.skipSpaces();
    if (self.matchKeyword("IF")) {
        _ = self.matchKeyword("NOT");
        _ = self.matchKeyword("EXISTS");
    }
    const name = try self.parseIdentifier();
    var charset: ?[]const u8 = null;

    self.skipSpaces();
    while (self.peek() != ';' and self.pos < self.src.len) {
        if (self.matchKeyword("CHARACTER")) {
            self.skipSpaces();
            if (self.matchKeyword("SET")) {
                self.skipSpaces();
                charset = try self.parseUnquotedWord();
            }
        } else if (self.matchKeyword("CHARSET")) {
            self.skipSpaces();
            charset = try self.parseUnquotedWord();
        } else if (self.matchKeyword("ENCODING")) {
            self.skipSpaces();
            if (self.peek() == '\'') {
                charset = try self.parseStringLiteral();
            } else {
                charset = try self.parseUnquotedWord();
            }
        } else if (self.matchKeyword("LC_COLLATE") or self.matchKeyword("LC_CTYPE") or self.matchKeyword("TEMPLATE") or self.matchKeyword("CONNECTION") or self.matchKeyword("IS_TEMPLATE")) {
            self.skipSpaces();
            if (self.peek() == '\'') {
                _ = self.parseStringLiteral() catch {};
            } else {
                self.skipWord();
            }
        } else {
            self.advance();
        }
    }
    self.expect(';');
    return .{ .name = name, .charset = charset };
}

pub fn parseCreateTable(self: *sp.SqlParser) !SqlTable {
    self.skipSpaces();
    if (self.matchKeyword("IF")) {
        _ = self.matchKeyword("NOT");
        _ = self.matchKeyword("EXISTS");
    }
    self.skipSpaces();
    const name = try self.parseDottedIdentifier();
    self.skipSpaces();
    self.expect('(');

    var columns = try std.ArrayList(SqlColumn).initCapacity(self.alloc, 16);
    var indexes = try std.ArrayList(SqlIndex).initCapacity(self.alloc, 4);
    var foreign_keys = try std.ArrayList(SqlForeignKey).initCapacity(self.alloc, 4);
    var checks = try std.ArrayList(SqlCheck).initCapacity(self.alloc, 4);

    while (self.pos < self.src.len) {
        self.skipSpacesAndNewlines();
        if (self.peek() == ')') break;

        const save = self.pos;
        self.skipWhitespaceAndCommentsNoSemicolon();
        if (self.peek() == ')') break;
        self.pos = save;

        self.skipSpacesAndNewlines();
        if (self.peek() == ')') break;
        if (self.peek() == ',') {
            self.advance();
            continue;
        }

        if (self.lookaheadIs("CONSTRAINT")) {
            self.skipSpacesAndNewlines();
            self.advance();
            self.skipSpaces();
            _ = try self.parseIdentifier();
            self.skipSpaces();
            if (self.lookaheadIs("PRIMARY")) {
                const idx = try self.parsePrimaryKey();
                try indexes.append(self.alloc, idx);
            } else if (self.lookaheadIs("UNIQUE")) {
                const idx = try self.parseUniqueIndex();
                try indexes.append(self.alloc, idx);
            } else if (self.lookaheadIs("CHECK")) {
                const ck = try self.parseCheck();
                try checks.append(self.alloc, ck);
            } else if (self.lookaheadIs("FOREIGN")) {
                const fk = try self.parseForeignKey();
                try foreign_keys.append(self.alloc, fk);
            }
        } else if (self.lookaheadIs("FOREIGN")) {
            const fk = try self.parseForeignKey();
            try foreign_keys.append(self.alloc, fk);
        } else if (self.lookaheadIs("PRIMARY")) {
            const idx = try self.parsePrimaryKey();
            try indexes.append(self.alloc, idx);
        } else if (self.lookaheadIs("UNIQUE")) {
            const idx = try self.parseUniqueIndex();
            try indexes.append(self.alloc, idx);
        } else if (self.lookaheadIs("FULLTEXT")) {
            if (self.dialect == .pg or self.dialect == .sqlite) {
                self.reportWarning("FULLTEXT index not supported inline in this dialect, skipping", .{});
                self.skipToSemicolon();
            } else {
                const idx = try self.parseFulltextIndex();
                try indexes.append(self.alloc, idx);
            }
        } else if (self.lookaheadIs("INDEX") or self.lookaheadIs("KEY")) {
            if (self.dialect == .pg) {
                self.reportWarning("inline INDEX/KEY not supported in PostgreSQL, skipping", .{});
                self.skipToSemicolon();
            } else if (self.dialect == .sqlite) {
                self.reportWarning("inline INDEX not supported in SQLite, skipping", .{});
                self.skipToSemicolon();
            } else {
                const idx = try self.parseIndex();
                try indexes.append(self.alloc, idx);
            }
        } else if (self.lookaheadIs("CHECK")) {
            const ck = try self.parseCheck();
            try checks.append(self.alloc, ck);
        } else {
            const col = try parseColumn(self);
            try columns.append(self.alloc, col);
        }

        self.skipSpacesAndNewlines();
        if (self.peek() == ',') self.advance();
    }

    self.expect(')');

    const table_columns = try columns.toOwnedSlice(self.alloc);

    {
        var resolved_checks = try std.ArrayList(SqlCheck).initCapacity(self.alloc, checks.items.len);
        for (checks.items) |*ck| {
            var resolved_field: []const u8 = "";
            for (table_columns) |col| {
                if (ck.expr.len >= col.name.len and std.mem.eql(u8, ck.expr[0..col.name.len], col.name)) {
                    resolved_field = col.name;
                    break;
                }
            }
            try resolved_checks.append(self.alloc, .{
                .field_name = resolved_field,
                .expr = ck.expr,
            });
        }
        checks.deinit(self.alloc);
        checks = resolved_checks;
    }

    var engine: ?[]const u8 = null;
    var charset: ?[]const u8 = null;
    var comment: ?[]const u8 = null;

    while (self.pos < self.src.len) {
        self.skipSpacesAndNewlines();
        if (self.pos >= self.src.len or self.peek() == ';') break;

        if (self.matchKeyword("ENGINE")) {
            self.skipSpaces();
            if (self.peek() == '=') self.advance();
            self.skipSpaces();
            engine = try self.parseUnquotedWord();
        } else if (self.matchKeyword("DEFAULT")) {
            self.skipSpaces();
            if (self.matchKeyword("CHARSET")) {
                self.skipSpaces();
                if (self.peek() == '=') self.advance();
                self.skipSpaces();
                charset = try self.parseUnquotedWord();
            }
        } else if (self.matchKeyword("CHARSET")) {
            self.skipSpaces();
            if (self.peek() == '=') self.advance();
            self.skipSpaces();
            charset = try self.parseUnquotedWord();
        } else if (self.matchKeyword("COMMENT")) {
            self.skipSpaces();
            if (self.peek() == '=') self.advance();
            self.skipSpaces();
            comment = try self.parseStringLiteral();
        } else {
            self.skipWord();
            self.skipSpaces();
            if (self.peek() == '=') {
                self.advance();
                self.skipSpaces();
                if (self.peek() == '\'') {
                    _ = self.parseStringLiteral() catch {};
                } else {
                    self.skipWord();
                }
            }
        }
    }
    self.expect(';');

    return .{
        .name = name,
        .engine = engine,
        .charset = charset,
        .comment = comment,
        .columns = table_columns,
        .indexes = try indexes.toOwnedSlice(self.alloc),
        .foreign_keys = try foreign_keys.toOwnedSlice(self.alloc),
        .checks = try checks.toOwnedSlice(self.alloc),
    };
}

pub fn parseColumn(self: *sp.SqlParser) !SqlColumn {
    const name = try self.parseIdentifier();
    self.skipSpaces();

    var type_sql = try self.parseColumnType();

    var pg_serial_auto_inc = false;
    if (self.dialect == .pg) {
        const trimmed = std.mem.trim(u8, type_sql, " \t");
        if (std.mem.eql(u8, trimmed, "serial")) {
            type_sql = "integer";
            pg_serial_auto_inc = true;
        } else if (std.mem.eql(u8, trimmed, "bigserial")) {
            type_sql = "bigint";
            pg_serial_auto_inc = true;
        }
    }

    var nullable = true;
    var unsigned = false;
    var auto_increment = pg_serial_auto_inc;
    var primary_key = false;
    var on_update = false;
    var default_val: ?[]const u8 = null;
    var check_expr: ?[]const u8 = null;
    var comment: ?[]const u8 = null;

    self.skipSpaces();
    while (self.pos < self.src.len) {
        const ch = self.peek();
        if (ch == ',' or ch == ')' or ch == '\n' or ch == '\r') break;
        if (ch == ' ' or ch == '\t') {
            self.skipSpaces();
            continue;
        }

        if (self.matchKeyword("NOT")) {
            self.skipSpaces();
            if (self.matchKeyword("NULL")) {
                nullable = false;
            }
        } else if (self.matchKeyword("NULL")) {
            nullable = true;
        } else if (self.matchKeyword("CHARACTER")) {
            self.skipSpaces();
            if (self.matchKeyword("SET")) {
                self.skipSpaces();
                self.skipWord();
                self.skipSpaces();
                if (self.matchKeyword("COLLATE")) {
                    self.skipSpaces();
                    self.skipWord();
                }
            }
        } else if (self.matchKeyword("COLLATE")) {
            self.skipSpaces();
            self.skipWord();
        } else if (self.matchKeyword("UNSIGNED")) {
            if (self.dialect == .mysql) unsigned = true;
        } else if (self.matchKeyword("AUTO_INCREMENT") or self.matchKeyword("AUTOINCREMENT")) {
            auto_increment = true;
        } else if (self.matchKeyword("GENERATED")) {
            self.skipSpaces();
            _ = self.matchKeyword("ALWAYS");
            _ = self.matchKeyword("BY");
            _ = self.matchKeyword("DEFAULT");
            self.skipSpaces();
            if (self.matchKeyword("AS")) {
                self.skipSpaces();
                if (self.matchKeyword("IDENTITY")) {
                    auto_increment = true;
                } else if (self.peek() == '(') {
                    self.advance();
                    var depth: usize = 1;
                    while (self.pos < self.src.len and depth > 0) {
                        const c = self.peek();
                        if (c == '(') depth += 1 else if (c == ')') depth -= 1;
                        if (depth > 0) self.advance();
                    }
                    if (self.peek() == ')') self.advance();
                    self.skipSpaces();
                    _ = self.matchKeyword("STORED");
                    _ = self.matchKeyword("VIRTUAL");
                }
            }
        } else if (self.matchKeyword("PRIMARY")) {
            self.skipSpaces();
            if (self.matchKeyword("KEY")) {
                primary_key = true;
            }
        } else if (self.matchKeyword("UNIQUE")) {
            // Column-level UNIQUE — skip
        } else if (self.matchKeyword("DEFAULT")) {
            self.skipSpaces();
            default_val = try self.parseDefaultValue();
        } else if (self.matchKeyword("COMMENT")) {
            self.skipSpaces();
            comment = try self.parseStringLiteral();
        } else if (self.matchKeyword("ON")) {
            self.skipSpaces();
            if (self.matchKeyword("UPDATE")) {
                on_update = true;
                self.skipSpaces();
                self.skipWord();
            }
        } else if (self.matchKeyword("CHECK")) {
            self.skipSpaces();
            if (self.peek() == '(') {
                check_expr = try self.parseParenExpr();
            }
        } else if (self.matchKeyword("references") or self.matchKeyword("REFERENCES")) {
            self.skipSpaces();
            _ = try self.parseIdentifier();
            self.skipSpaces();
            if (self.peek() == '(') {
                self.advance();
                while (self.peek() != ')' and self.pos < self.src.len) self.advance();
                if (self.peek() == ')') self.advance();
            }
        } else {
            break;
        }
        self.skipSpaces();
    }

    return .{
        .name = name,
        .type_sql = type_sql,
        .nullable = nullable,
        .unsigned = unsigned,
        .auto_increment = auto_increment,
        .primary_key = primary_key,
        .on_update_current_timestamp = on_update,
        .default_val = default_val,
        .check_expr = check_expr,
        .comment = comment,
    };
}

pub fn parseColumnType(self: *sp.SqlParser) ![]const u8 {
    const start = self.pos;
    self.skipWord();
    if (self.pos < self.src.len and self.peek() == '(') {
        self.advance();
        var depth: usize = 1;
        while (self.pos < self.src.len and depth > 0) {
            const c = self.peek();
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
            if (depth > 0) self.advance();
        }
        if (self.peek() == ')') self.advance();
    }
    return self.src[start..self.pos];
}
