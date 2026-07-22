const std = @import("std");
const common = @import("sql_parser_common.zig");
const ast_mod = @import("ast.zig");
const sql_parser_create = @import("sql_parser_create.zig");
const sql_parser_fk = @import("sql_parser_fk.zig");
const sql_parser_index = @import("sql_parser_index.zig");
const sql_parser_check = @import("sql_parser_check.zig");

// Re-export common types for backward compatibility
pub const Dialect = common.Dialect;
pub const IndexKind = common.IndexKind;
pub const FkActionType = common.FkActionType;
pub const FkActionTrigger = common.FkActionTrigger;
pub const FkAction = common.FkAction;
pub const SqlColumn = common.SqlColumn;
pub const SqlIndex = common.SqlIndex;
pub const SqlForeignKey = common.SqlForeignKey;
pub const SqlCheck = common.SqlCheck;
pub const SqlTable = common.SqlTable;
pub const SqlSchema = common.SqlSchema;
pub const SqlDiagnostic = common.SqlDiagnostic;
pub const SqlParseResult = common.SqlParseResult;

// ─── SQL DDL Parser ──────────────────────────────────────────────

pub const SqlParser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    diagnostics: std.ArrayList(SqlDiagnostic),
    dialect: Dialect,

    pub fn init(alloc: std.mem.Allocator, src: []const u8, dialect: Dialect) SqlParser {
        return .{
            .alloc = alloc,
            .src = src,
            .pos = 0,
            .diagnostics = std.ArrayList(SqlDiagnostic).initCapacity(alloc, 8) catch unreachable,
            .dialect = dialect,
        };
    }

    pub fn lineColAt(self: *SqlParser, pos: usize) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        var i: usize = 0;
        while (i < pos and i < self.src.len) : (i += 1) {
            if (self.src[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    pub fn getSourceLine(self: *SqlParser, line_no: usize) ?[]const u8 {
        var line: usize = 1;
        var start: usize = 0;
        var i: usize = 0;
        while (i < self.src.len) : (i += 1) {
            if (line == line_no) {
                var end = i;
                while (end < self.src.len and self.src[end] != '\n') end += 1;
                var trimmed_end = end;
                while (trimmed_end > start and self.src[trimmed_end - 1] == '\r') trimmed_end -= 1;
                return self.src[start..trimmed_end];
            }
            if (self.src[i] == '\n') {
                line += 1;
                start = i + 1;
            }
        }
        return null;
    }

    pub fn reportError(self: *SqlParser, comptime fmt: []const u8, args: anytype) void {
        const pos = if (self.pos < self.src.len) self.pos else self.src.len;
        const lc = self.lineColAt(pos);
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        const src_line = self.getSourceLine(lc.line);
        self.diagnostics.append(self.alloc, .{
            .severity = .@"error",
            .line_no = lc.line,
            .col = lc.col,
            .message = msg,
            .context = src_line,
        }) catch {};
    }

    pub fn reportErrorAt(self: *SqlParser, at_pos: usize, comptime fmt: []const u8, args: anytype) void {
        const lc = self.lineColAt(at_pos);
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        const src_line = self.getSourceLine(lc.line);
        self.diagnostics.append(self.alloc, .{
            .severity = .@"error",
            .line_no = lc.line,
            .col = lc.col,
            .message = msg,
            .context = src_line,
        }) catch {};
    }

    pub fn reportWarning(self: *SqlParser, comptime fmt: []const u8, args: anytype) void {
        const pos = if (self.pos < self.src.len) self.pos else self.src.len;
        const lc = self.lineColAt(pos);
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        const src_line = self.getSourceLine(lc.line);
        self.diagnostics.append(self.alloc, .{
            .severity = .warning,
            .line_no = lc.line,
            .col = lc.col,
            .message = msg,
            .context = src_line,
        }) catch {};
    }

    pub fn parse(self: *SqlParser) !SqlParseResult {
        var schema_name: ?[]const u8 = null;
        var schema_charset: ?[]const u8 = null;
        var tables = try std.ArrayList(SqlTable).initCapacity(self.alloc, 8);
        var saw_create = false;

        while (self.pos < self.src.len) {
            self.skipSpacesAndNewlines();
            if (self.pos >= self.src.len) break;

            // Capture -- comments before skipping them (for SQLite column/table comments)
            self.captureTrailingComments(tables.items);

            // Now skip -- comments
            self.skipWhitespaceAndComments();
            if (self.pos >= self.src.len) break;

            if (self.matchKeyword("CREATE")) {
                saw_create = true;
                self.skipSpacesAndNewlines();
                if (self.matchKeyword("DATABASE")) {
                    const result = try self.parseCreateDatabase();
                    if (result.name) |n| schema_name = n;
                    if (result.charset) |c| schema_charset = c;
                } else if (self.matchKeyword("TABLE")) {
                    const table = try self.parseCreateTable();
                    try tables.append(self.alloc, table);
                } else if (self.matchKeyword("INDEX") or self.matchKeyword("UNIQUE")) {
                    // PG: CREATE [UNIQUE] INDEX idx_name ON table (cols)
                    // matchKeyword consumed either INDEX or UNIQUE.
                    // If UNIQUE was consumed, INDEX follows. If INDEX was consumed, no UNIQUE.
                    self.skipSpaces();
                    var is_unique = false;
                    if (std.mem.eql(u8, self.peekWord(), "INDEX")) {
                        // UNIQUE was consumed above, INDEX is next → consume it
                        is_unique = true;
                        self.skipWord();
                        self.skipSpaces();
                    }
                    _ = self.matchKeyword("IF");
                    _ = self.matchKeyword("NOT");
                    _ = self.matchKeyword("EXISTS");
                    self.skipSpaces();
                    const idx_name = try self.parseIdentifier();
                    self.skipSpaces();
                    _ = self.matchKeyword("ON");
                    self.skipSpaces();
                    const tbl_ident = try self.parseIdentifier();
                    const tbl_name = blk: {
                        if (std.mem.lastIndexOfScalar(u8, tbl_ident, '.')) |dot_pos|
                            break :blk tbl_ident[dot_pos + 1 ..];
                        break :blk tbl_ident;
                    };
                    self.skipSpaces();
                    if (self.peek() == '(') {
                        self.advance(); // skip (
                        var fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 4);
                        while (self.peek() != ')' and self.pos < self.src.len) {
                            self.skipSpaces();
                            if (self.peek() == ')') break;
                            const field = try self.parseIdentifier();
                            try fields.append(self.alloc, field);
                            self.skipSpaces();
                            if (self.peek() == ',') self.advance();
                        }
                        if (self.peek() == ')') self.advance(); // skip )
                        const kind: IndexKind = if (is_unique) .unique else .regular;
                        const idx = SqlIndex{
                            .kind = kind,
                            .name = idx_name,
                            .fields = try fields.toOwnedSlice(self.alloc),
                            .descending = &.{},
                        };
                        for (tables.items) |*tbl| {
                            if (std.mem.eql(u8, tbl.name, tbl_name)) {
                                const old = tbl.indexes;
                                const new = try self.alloc.alloc(SqlIndex, old.len + 1);
                                for (old, 0..) |o, i| new[i] = o;
                                new[old.len] = idx;
                                tbl.indexes = new;
                                break;
                            }
                        }
                    }
                    self.skipToSemicolon();
                } else if (self.matchKeyword("EXTENSION") or self.matchKeyword("SCHEMA") or self.matchKeyword("TYPE") or self.matchKeyword("FUNCTION") or self.matchKeyword("TRIGGER") or self.matchKeyword("VIEW") or self.matchKeyword("SEQUENCE")) {
                    // PG: CREATE EXTENSION/SCHEMA/TYPE/FUNCTION/TRIGGER/VIEW/SEQUENCE — skip
                    self.skipToSemicolon();
                } else {
                    self.reportError("expected DATABASE, TABLE, or INDEX after CREATE, skipping statement", .{});
                    self.skipToSemicolon();
                }
            } else if (self.matchKeyword("ALTER")) {
                // ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ...
                self.skipSpacesAndNewlines();
                if (self.matchKeyword("TABLE")) {
                    self.skipSpaces();
                    const tbl_name = try self.parseIdentifier();
                    self.skipSpaces();
                    if (self.matchKeyword("ADD")) {
                        self.skipSpaces();
                        // Optional: CONSTRAINT constraint_name
                        if (self.matchKeyword("CONSTRAINT")) {
                            self.skipSpaces();
                            _ = try self.parseIdentifier(); // constraint name
                            self.skipSpaces();
                        }
                        if (self.matchKeyword("FOREIGN")) {
                            // ALTER TABLE t ADD [CONSTRAINT fk] FOREIGN KEY (cols) REFERENCES ref (cols) [actions]
                            self.skipSpaces();
                            const fk = try self.parseForeignKey();
                            // Find the table and append the FK by creating a new slice
                            for (tables.items) |*tbl| {
                                if (std.mem.eql(u8, tbl.name, tbl_name)) {
                                    const new_len = tbl.foreign_keys.len + 1;
                                    var new_fks = try self.alloc.alloc(SqlForeignKey, new_len);
                                    for (tbl.foreign_keys, 0..) |old_fk, i| new_fks[i] = old_fk;
                                    new_fks[new_len - 1] = fk;
                                    tbl.foreign_keys = new_fks;
                                    break;
                                }
                            }
                        } else {
                            // Other ALTER TABLE ADD (column, index, etc.) — skip
                            self.skipToSemicolon();
                        }
                    } else {
                        // ALTER TABLE ... (non-ADD) — skip
                        self.skipToSemicolon();
                    }
                } else {
                    self.skipToSemicolon();
                }
            } else if (self.matchKeyword("COMMENT")) {
                // PG: COMMENT ON TABLE/COLUMN ... IS 'text'
                self.skipSpacesAndNewlines();
                if (self.matchKeyword("ON")) {
                    self.skipSpacesAndNewlines();
                    if (self.matchKeyword("TABLE")) {
                        self.skipSpaces();
                        const full_ident = try self.parseDottedIdentifier();
                        // Match against full table name (may include schema prefix)
                        self.skipSpaces();
                        if (self.matchKeyword("IS")) {
                            self.skipSpaces();
                            const cmt = try self.parseStringLiteral();
                            for (tables.items) |*tbl| {
                                if (std.mem.eql(u8, tbl.name, full_ident)) {
                                    tbl.comment = cmt;
                                    break;
                                }
                            }
                        }
                    } else if (self.matchKeyword("COLUMN")) {
                        self.skipSpaces();
                        // PG: "schema"."table"."column" or "table"."column"
                        const full_ident = try self.parseDottedIdentifier();
                        // Split at last dot: tbl=everything_before, col=last_part
                        var tbl_name: []const u8 = full_ident;
                        var col_name: []const u8 = "";
                        if (std.mem.lastIndexOfScalar(u8, full_ident, '.')) |dot_pos| {
                            tbl_name = full_ident[0..dot_pos];
                            col_name = full_ident[dot_pos + 1 ..];
                        }
                        self.skipSpaces();
                        if (self.matchKeyword("IS")) {
                            self.skipSpaces();
                            const cmt = try self.parseStringLiteral();
                            for (tables.items) |*tbl| {
                                if (std.mem.eql(u8, tbl.name, tbl_name)) {
                                    for (tbl.columns) |*col| {
                                        if (col_name.len > 0 and std.mem.eql(u8, col.name, col_name)) {
                                            col.comment = cmt;
                                            break;
                                        }
                                    }
                                    break;
                                }
                            }
                        } else {
                            self.skipToSemicolon();
                        }
                    } else {
                        self.skipToSemicolon();
                    }
                } else {
                    self.skipToSemicolon();
                }
            } else {
                // Not a CREATE or COMMENT statement — silently skip (DML, transactions, etc.)
                self.skipToSemicolon();
            }
        }

        if (!saw_create) {
            self.reportError("no CREATE statement found in input", .{});
        }

        const table_slice = try tables.toOwnedSlice(self.alloc);
        if (table_slice.len == 0 and saw_create) {
            self.reportWarning("parsed schema but found no tables", .{});
        }

        return .{
            .schema = .{
                .name = schema_name,
                .charset = schema_charset,
                .tables = table_slice,
            },
            .diagnostics = try self.diagnostics.toOwnedSlice(self.alloc),
        };
    }

    // ─── CREATE DATABASE ──────────────────────────────────────────

    pub fn parseCreateDatabase(self: *SqlParser) !common.CreateDbResult {
        return sql_parser_create.parseCreateDatabase(self);
    }

    // ─── CREATE TABLE ─────────────────────────────────────────────

    pub fn parseCreateTable(self: *SqlParser) !SqlTable {
        return sql_parser_create.parseCreateTable(self);
    }

    // ─── Column Definition ────────────────────────────────────────

    pub fn parseColumn(self: *SqlParser) !SqlColumn {
        return sql_parser_create.parseColumn(self);
    }

    pub fn parseColumnType(self: *SqlParser) ![]const u8 {
        return sql_parser_create.parseColumnType(self);
    }

    // ─── FOREIGN KEY ──────────────────────────────────────────────

    pub fn parseForeignKey(self: *SqlParser) !SqlForeignKey {
        return sql_parser_fk.parseForeignKey(self);
    }

    // ─── INDEX declarations ───────────────────────────────────────

    pub fn parsePrimaryKey(self: *SqlParser) !SqlIndex {
        return sql_parser_index.parsePrimaryKey(self);
    }

    pub fn parseUniqueIndex(self: *SqlParser) !SqlIndex {
        return sql_parser_index.parseUniqueIndex(self);
    }

    pub fn parseFulltextIndex(self: *SqlParser) !SqlIndex {
        return sql_parser_index.parseFulltextIndex(self);
    }

    pub fn parseIndex(self: *SqlParser) !SqlIndex {
        return sql_parser_index.parseIndex(self);
    }

    // ─── CHECK constraint ─────────────────────────────────────────

    pub fn parseCheck(self: *SqlParser) !SqlCheck {
        return sql_parser_check.parseCheck(self);
    }

    pub fn parseCheckExpr(self: *SqlParser) ![]const u8 {
        return sql_parser_check.parseCheckExpr(self);
    }

    // ─── Helpers ──────────────────────────────────────────────────

    pub fn parseIdentifier(self: *SqlParser) ![]const u8 {
        self.skipSpaces();
        if (self.peek() == '`') {
            return self.parseBacktickIdent();
        }
        if (self.peek() == '"') {
            return self.parseDoubleQuoteIdent();
        }
        return self.parseUnquotedWord();
    }

    /// Read a potentially schema-qualified identifier: "schema"."table"."col"
    /// Returns the full raw string including dots and quotes.
    pub fn parseDottedIdentifier(self: *SqlParser) ![]const u8 {
        self.skipSpaces();
        const start = self.pos;
        _ = try self.parseIdentifier();
        // Check for dot-separated parts
        while (self.pos < self.src.len) {
            self.skipSpaces();
            if (self.peek() != '.') break;
            self.advance(); // skip dot
            _ = try self.parseIdentifier();
        }
        // Find the actual end of the identifier (before any trailing whitespace)
        var end = self.pos;
        while (end > start and (self.src[end - 1] == ' ' or self.src[end - 1] == '\t')) {
            end -= 1;
        }
        // Strip double-quote and backtick characters from the raw result
        const raw = self.src[start..end];
        var stripped = try std.ArrayList(u8).initCapacity(self.alloc, raw.len);
        for (raw) |c| {
            if (c != '"' and c != '`') {
                stripped.appendAssumeCapacity(c);
            }
        }
        return try stripped.toOwnedSlice(self.alloc);
    }

    pub fn parseBacktickIdent(self: *SqlParser) ![]const u8 {
        self.advance(); // skip opening `
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '`') {
            if (self.src[self.pos] == '`' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '`') {
                self.pos += 2; // escaped backtick
            } else {
                self.pos += 1;
            }
        }
        const result = self.src[start..self.pos];
        if (self.pos < self.src.len) self.advance(); // skip closing `
        return result;
    }

    pub fn parseDoubleQuoteIdent(self: *SqlParser) ![]const u8 {
        self.advance(); // skip opening "
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '"') {
            if (self.src[self.pos] == '"' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
                self.pos += 2; // escaped double-quote ""
            } else {
                self.pos += 1;
            }
        }
        const result = self.src[start..self.pos];
        if (self.pos < self.src.len) self.advance(); // skip closing "
        return result;
    }

    pub fn parseUnquotedWord(self: *SqlParser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',' or c == ')' or c == '(' or c == ';' or c == '\'' or c == '`' or c == '"') break;
            self.pos += 1;
        }
        if (self.pos == start) {
            self.reportError("expected identifier or keyword, got '{c}'", .{self.peek()});
            return error.ExpectedWord;
        }
        return self.src[start..self.pos];
    }

    pub fn parseStringLiteral(self: *SqlParser) ![]const u8 {
        self.skipSpaces();
        if (self.peek() != '\'') {
            self.reportError("expected string literal (single-quoted), got '{c}'", .{self.peek()});
            return error.ExpectedString;
        }
        self.advance(); // skip opening '
        const start = self.pos;
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '\'') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                    self.pos += 2; // escaped quote ''
                } else {
                    break;
                }
            } else {
                self.pos += 1;
            }
        }
        const result = self.src[start..self.pos];
        if (self.pos < self.src.len) self.advance(); // skip closing '
        return result;
    }

    pub fn parseDefaultValue(self: *SqlParser) ![]const u8 {
        // MySQL binary literal: b'0', b'1'
        if (self.peek() == 'b' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
            const start = self.pos;
            self.advance(); // skip b
            _ = try self.parseStringLiteral();
            return self.src[start..self.pos];
        }
        if (self.peek() == '\'') {
            return self.parseStringLiteral();
        }
        // Unquoted default value: number, NULL, CURRENT_TIMESTAMP, NOW(), gen_random_uuid(), etc.
        const start = self.pos;
        self.skipWord();
        // Handle decimal numbers: 0.00, 1.5, etc.
        if (self.peek() == '.' and self.pos + 1 < self.src.len) {
            const next = self.src[self.pos + 1];
            if (next >= '0' and next <= '9') {
                self.advance(); // skip .
                while (self.pos < self.src.len) {
                    const c = self.src[self.pos];
                    if (c >= '0' and c <= '9') {
                        self.pos += 1;
                    } else break;
                }
            }
        }
        // Handle function calls: now(), gen_random_uuid(), etc.
        self.skipSpaces();
        if (self.peek() == '(') {
            self.advance(); // (
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

    pub const FieldList = struct {
        fields: std.ArrayList([]const u8),
        descending: std.ArrayList(bool),
    };

    pub fn parseParenFieldList(self: *SqlParser) !FieldList {
        self.expect('(');
        var fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 4);
        var descending = try std.ArrayList(bool).initCapacity(self.alloc, 4);
        while (self.pos < self.src.len) {
            self.skipSpaces();
            if (self.peek() == ')') break;
            const f = try self.parseIdentifier();
            try fields.append(self.alloc, f);
            self.skipSpaces();
            // Capture ASC/DESC after field name
            const is_desc = self.matchKeyword("DESC");
            _ = self.matchKeyword("ASC");
            try descending.append(self.alloc, is_desc);
            self.skipSpaces();
            if (self.peek() == ',') self.advance();
        }
        self.expect(')');
        // Skip USING BTREE / HASH after the field list
        self.skipSpaces();
        if (self.matchKeyword("USING")) {
            self.skipSpaces();
            self.skipWord(); // BTREE, HASH, etc.
        }
        // Skip COMMENT '...' after index definition
        self.skipSpaces();
        if (self.matchKeyword("COMMENT")) {
            self.skipSpaces();
            _ = self.parseStringLiteral() catch {};
        }
        return .{ .fields = fields, .descending = descending };
    }

    pub fn parseParenExpr(self: *SqlParser) ![]const u8 {
        self.expect('(');
        const start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.src.len and depth > 0) {
            const c = self.peek();
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
            if (depth > 0) self.pos += 1;
        }
        const result = self.src[start..self.pos];
        if (self.peek() == ')') self.pos += 1;
        return result;
    }

    pub fn parseWord(self: *SqlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z' or c >= '0' and c <= '9' or c == '_') {
                self.pos += 1;
            } else break;
        }
        return self.src[start..self.pos];
    }

    pub fn skipWord(self: *SqlParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z' or c >= '0' and c <= '9' or c == '_') {
                self.pos += 1;
            } else break;
        }
    }

    pub fn matchKeyword(self: *SqlParser, kw: []const u8) bool {
        const saved = self.pos;
        self.skipSpacesAndNewlines();
        const word = self.parseWord();
        if (std.mem.eql(u8, word, kw)) return true;
        self.pos = saved;
        return false;
    }

    pub fn expectKeyword(self: *SqlParser, kw: []const u8) void {
        self.skipSpaces();
        const word = self.parseWord();
        if (!std.mem.eql(u8, word, kw)) {
            // Don't hard-fail during parsing — just stop gracefully
        }
    }

    pub fn expect(self: *SqlParser, ch: u8) void {
        self.skipSpacesAndNewlines();
        if (self.pos < self.src.len and self.src[self.pos] == ch) {
            self.pos += 1;
        } else {
            self.reportError("expected '{c}', got '{c}'", .{ ch, self.peek() });
        }
    }

    pub fn lookaheadIs(self: *SqlParser, kw: []const u8) bool {
        const saved = self.pos;
        self.skipSpacesAndNewlines();
        const word = self.parseWord();
        const result = std.mem.eql(u8, word, kw);
        self.pos = saved;
        return result;
    }

    pub fn peekWord(self: *SqlParser) []const u8 {
        const saved = self.pos;
        self.skipSpaces();
        const word = self.parseWord();
        self.pos = saved;
        return word;
    }

    pub fn peek(self: *SqlParser) u8 {
        if (self.pos < self.src.len) return self.src[self.pos];
        return 0;
    }

    pub fn advance(self: *SqlParser) void {
        if (self.pos < self.src.len) self.pos += 1;
    }

    pub fn skipSpaces(self: *SqlParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t') self.pos += 1 else break;
        }
    }

    pub fn skipSpacesAndNewlines(self: *SqlParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.pos += 1 else break;
        }
    }

    pub fn skipWhitespaceAndComments(self: *SqlParser) void {
        while (self.pos < self.src.len) {
            // Skip all whitespace including newlines
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                    self.pos += 1;
                } else break;
            }
            if (self.pos >= self.src.len) break;
            // Skip -- line comments
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] == '-') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            // Skip /* block comments */
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.src.len) {
                    if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }

    pub fn skipWhitespaceAndCommentsNoSemicolon(self: *SqlParser) void {
        while (self.pos < self.src.len) {
            self.skipSpacesAndNewlines();
            if (self.pos >= self.src.len) break;
            // Skip -- line comments
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] == '-') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            // Skip /* block comments */
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.src.len) {
                    if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }

    pub fn skipToSemicolon(self: *SqlParser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ';' => {
                    self.pos += 1;
                    return;
                },
                '\'' => {
                    // Skip single-quoted string
                    self.pos += 1;
                    while (self.pos < self.src.len) {
                        if (self.src[self.pos] == '\'') {
                            if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                                self.pos += 2; // escaped ''
                            } else {
                                self.pos += 1; // closing '
                                break;
                            }
                        } else {
                            self.pos += 1;
                        }
                    }
                },
                '"' => {
                    // Skip double-quoted identifier
                    self.pos += 1;
                    while (self.pos < self.src.len and self.src[self.pos] != '"') {
                        if (self.src[self.pos] == '"' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '"') {
                            self.pos += 2; // escaped ""
                        } else {
                            self.pos += 1;
                        }
                    }
                    if (self.pos < self.src.len) self.pos += 1; // closing "
                },
                '`' => {
                    // Skip backtick-quoted identifier
                    self.pos += 1;
                    while (self.pos < self.src.len and self.src[self.pos] != '`') {
                        if (self.src[self.pos] == '`' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '`') {
                            self.pos += 2; // escaped ``
                        } else {
                            self.pos += 1;
                        }
                    }
                    if (self.pos < self.src.len) self.pos += 1; // closing `
                },
                '-' => {
                    // Skip -- line comment
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                    } else {
                        self.pos += 1;
                    }
                },
                '/' => {
                    // Skip /* block comment */
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                        self.pos += 2;
                        while (self.pos + 1 < self.src.len) {
                            if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                                self.pos += 2;
                                break;
                            }
                            self.pos += 1;
                        }
                    } else {
                        self.pos += 1;
                    }
                },
                else => self.pos += 1,
            }
        }
    }

    /// Read a -- comment (without advancing past whitespace before it).
    /// Returns the comment text after "--", or null if no comment found.
    pub fn readLineComment(self: *SqlParser) ?[]const u8 {
        // Skip whitespace including newlines to find next -- comment
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else break;
        }
        if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] == '-') {
            const start = self.pos + 2;
            while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            return std.mem.trim(u8, self.src[start..self.pos], " \t");
        }
        return null;
    }

    /// Capture trailing -- comments after a statement and attach to tables/columns.
    /// SQLite format: "-- table.col: comment" or "-- comment" (table-level).
    /// Also handles "-- @tps col_name type" for roundtrip metadata.
    pub fn captureTrailingComments(self: *SqlParser, tables: []SqlTable) void {
        while (self.readLineComment()) |cmt| {
            if (cmt.len == 0) continue;
            // Check for @tps metadata comment: "-- @tps col_name type"
            if (std.mem.startsWith(u8, cmt, "@tps ")) {
                const rest = std.mem.trim(u8, cmt[5..], " \t");
                if (std.mem.indexOfScalar(u8, rest, ' ')) |space_pos| {
                    const col_name = std.mem.trim(u8, rest[0..space_pos], " \t");
                    const tps_type = std.mem.trim(u8, rest[space_pos + 1 ..], " \t");
                    if (col_name.len > 0 and tps_type.len > 0) {
                        // Attach to the most recently added table
                        if (tables.len > 0) {
                            const last = &tables[tables.len - 1];
                            for (last.columns) |*col| {
                                if (std.mem.eql(u8, col.name, col_name)) {
                                    col.tps_override = tps_type;
                                    break;
                                }
                            }
                        }
                    }
                }
                continue;
            }
            // Try to match "-- table.column: text" pattern
            if (std.mem.indexOfScalar(u8, cmt, '.')) |dot_pos| {
                const tbl_part = std.mem.trim(u8, cmt[0..dot_pos], " \t");
                const rest = std.mem.trim(u8, cmt[dot_pos + 1 ..], " \t");
                if (std.mem.indexOfScalar(u8, rest, ':')) |colon_pos| {
                    const col_part = std.mem.trim(u8, rest[0..colon_pos], " \t");
                    const text = std.mem.trim(u8, rest[colon_pos + 1 ..], " \t");
                    if (text.len > 0) {
                        for (tables) |*tbl| {
                            if (std.mem.eql(u8, tbl.name, tbl_part)) {
                                for (tbl.columns) |*col| {
                                    if (std.mem.eql(u8, col.name, col_part)) {
                                        col.comment = text;
                                        break;
                                    }
                                }
                                break;
                            }
                        }
                    }
                }
            } else {
                // No dot — could be a table comment: "-- text"
                // Attach to the most recently added table
                if (tables.len > 0) {
                    const last = &tables[tables.len - 1];
                    if (last.comment == null) {
                        last.comment = cmt;
                    }
                }
            }
        }
    }
};

