const std = @import("std");
const common = @import("sql_parser_common.zig");
const ast_mod = @import("ast.zig");
const diag = @import("diagnostic.zig");
const sql_parser_create = @import("sql_parser_create.zig");
const sql_parser_fk = @import("sql_parser_fk.zig");
const sql_parser_index = @import("sql_parser_index.zig");
const sql_parser_check = @import("sql_parser_check.zig");
const sql_parser_alter = @import("sql_parser_alter.zig");
const sql_parser_comment = @import("sql_parser_comment.zig");
const sql_parser_helpers = @import("sql_parser_helpers.zig");

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
pub const SqlDiagnostic = diag.Diagnostic;
pub const SqlParseResult = common.SqlParseResult;

// ─── SQL DDL Parser ──────────────────────────────────────────────

pub const SqlParser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    diagnostics: diag.DiagnosticCollector,
    dialect: Dialect,

    pub fn init(alloc: std.mem.Allocator, src: []const u8, dialect: Dialect) !SqlParser {
        return .{
            .alloc = alloc,
            .src = src,
            .pos = 0,
            .diagnostics = try diag.DiagnosticCollector.init(alloc),
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
        self.diagnostics.record(.{
            .severity = .@"error",
            .line_no = lc.line,
            .col = lc.col,
            .message = msg,
            .source_line = src_line,
        });
    }

    pub fn reportErrorAt(self: *SqlParser, at_pos: usize, comptime fmt: []const u8, args: anytype) void {
        const lc = self.lineColAt(at_pos);
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        const src_line = self.getSourceLine(lc.line);
        self.diagnostics.record(.{
            .severity = .@"error",
            .line_no = lc.line,
            .col = lc.col,
            .message = msg,
            .source_line = src_line,
        });
    }

    pub fn reportWarning(self: *SqlParser, comptime fmt: []const u8, args: anytype) void {
        const pos = if (self.pos < self.src.len) self.pos else self.src.len;
        const lc = self.lineColAt(pos);
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        const src_line = self.getSourceLine(lc.line);
        self.diagnostics.record(.{
            .severity = .warning,
            .line_no = lc.line,
            .col = lc.col,
            .message = msg,
            .source_line = src_line,
        });
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
                    try self.parseCreateStandaloneIndex(&tables);
                } else if (self.matchKeyword("EXTENSION") or self.matchKeyword("SCHEMA") or self.matchKeyword("TYPE") or self.matchKeyword("FUNCTION") or self.matchKeyword("TRIGGER") or self.matchKeyword("VIEW") or self.matchKeyword("SEQUENCE")) {
                    // PG: CREATE EXTENSION/SCHEMA/TYPE/FUNCTION/TRIGGER/VIEW/SEQUENCE — skip
                    self.skipToSemicolon();
                } else {
                    self.reportError("expected DATABASE, TABLE, or INDEX after CREATE, skipping statement", .{});
                    self.skipToSemicolon();
                }
            } else if (self.matchKeyword("ALTER")) {
                try self.parseAlterTable(tables.items);
            } else if (self.matchKeyword("COMMENT")) {
                try self.parseCommentOn(tables.items);
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

    // ─── CREATE [UNIQUE] INDEX (standalone, PG syntax) ────────────

    fn parseCreateStandaloneIndex(self: *SqlParser, tables: *std.ArrayList(SqlTable)) !void {
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
    }

    // ─── Delegated sub-module methods ──────────────────────────────

    pub fn parseAlterTable(self: *SqlParser, tables: []SqlTable) !void {
        return sql_parser_alter.parseAlterTable(self, tables);
    }

    pub fn parseCommentOn(self: *SqlParser, tables: []SqlTable) !void {
        return sql_parser_comment.parseCommentOn(self, tables);
    }

    // ─── CREATE DATABASE / TABLE / Column ──────────────────────────

    pub fn parseCreateDatabase(self: *SqlParser) !common.CreateDbResult {
        return sql_parser_create.parseCreateDatabase(self);
    }

    pub fn parseCreateTable(self: *SqlParser) !SqlTable {
        return sql_parser_create.parseCreateTable(self);
    }

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

    // ─── Helpers (delegated to sql_parser_helpers.zig) ─────────────

    pub fn parseIdentifier(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseIdentifier(self);
    }

    pub fn parseDottedIdentifier(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseDottedIdentifier(self);
    }

    pub fn parseBacktickIdent(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseBacktickIdent(self);
    }

    pub fn parseDoubleQuoteIdent(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseDoubleQuoteIdent(self);
    }

    pub fn parseUnquotedWord(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseUnquotedWord(self);
    }

    pub fn parseStringLiteral(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseStringLiteral(self);
    }

    pub fn parseDefaultValue(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseDefaultValue(self);
    }

    pub const FieldList = sql_parser_helpers.FieldList;

    pub fn parseParenFieldList(self: *SqlParser) !FieldList {
        return sql_parser_helpers.parseParenFieldList(self);
    }

    pub fn parseParenExpr(self: *SqlParser) ![]const u8 {
        return sql_parser_helpers.parseParenExpr(self);
    }

    pub fn parseWord(self: *SqlParser) []const u8 {
        return sql_parser_helpers.parseWord(self);
    }

    pub fn skipWord(self: *SqlParser) void {
        sql_parser_helpers.skipWord(self);
    }

    pub fn matchKeyword(self: *SqlParser, kw: []const u8) bool {
        return sql_parser_helpers.matchKeyword(self, kw);
    }

    pub fn expectKeyword(self: *SqlParser, kw: []const u8) void {
        sql_parser_helpers.expectKeyword(self, kw);
    }

    pub fn expect(self: *SqlParser, ch: u8) void {
        sql_parser_helpers.expect(self, ch);
    }

    pub fn lookaheadIs(self: *SqlParser, kw: []const u8) bool {
        return sql_parser_helpers.lookaheadIs(self, kw);
    }

    pub fn peekWord(self: *SqlParser) []const u8 {
        return sql_parser_helpers.peekWord(self);
    }

    pub fn peek(self: *SqlParser) u8 {
        return sql_parser_helpers.peek(self);
    }

    pub fn advance(self: *SqlParser) void {
        sql_parser_helpers.advance(self);
    }

    pub fn skipSpaces(self: *SqlParser) void {
        sql_parser_helpers.skipSpaces(self);
    }

    pub fn skipSpacesAndNewlines(self: *SqlParser) void {
        sql_parser_helpers.skipSpacesAndNewlines(self);
    }

    pub fn skipWhitespaceAndComments(self: *SqlParser) void {
        sql_parser_helpers.skipWhitespaceAndComments(self);
    }

    pub fn skipWhitespaceAndCommentsNoSemicolon(self: *SqlParser) void {
        sql_parser_helpers.skipWhitespaceAndCommentsNoSemicolon(self);
    }

    pub fn skipToSemicolon(self: *SqlParser) void {
        sql_parser_helpers.skipToSemicolon(self);
    }

    pub fn readLineComment(self: *SqlParser) ?[]const u8 {
        return sql_parser_helpers.readLineComment(self);
    }

    pub fn captureTrailingComments(self: *SqlParser, tables: []SqlTable) void {
        sql_parser_helpers.captureTrailingComments(self, tables);
    }
};
