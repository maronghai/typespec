const std = @import("std");
const sp = @import("sql_parser.zig");
const common = @import("sql_parser_common.zig");
const SqlIndex = common.SqlIndex;
const SqlForeignKey = common.SqlForeignKey;

// ─── Identifier Parsing ────────────────────────────────────────

pub fn parseIdentifier(self: *sp.SqlParser) ![]const u8 {
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
pub fn parseDottedIdentifier(self: *sp.SqlParser) ![]const u8 {
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

pub fn parseBacktickIdent(self: *sp.SqlParser) ![]const u8 {
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

pub fn parseDoubleQuoteIdent(self: *sp.SqlParser) ![]const u8 {
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

pub fn parseUnquotedWord(self: *sp.SqlParser) ![]const u8 {
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

// ─── Literal Parsing ───────────────────────────────────────────

pub fn parseStringLiteral(self: *sp.SqlParser) ![]const u8 {
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

pub fn parseDefaultValue(self: *sp.SqlParser) ![]const u8 {
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
    // Parenthesized expression: (1 + 2), (NOW()), etc.
    if (self.peek() == '(') {
        const start = self.pos;
        self.advance(); // (
        var depth: usize = 1;
        while (self.pos < self.src.len and depth > 0) {
            const c = self.peek();
            if (c == '(') depth += 1 else if (c == ')') depth -= 1;
            if (depth > 0) self.advance();
        }
        if (self.peek() == ')') self.advance();
        return self.src[start..self.pos];
    }
    // Unquoted default value: -1, number, NULL, CURRENT_TIMESTAMP, NOW(), gen_random_uuid(), TRUE, FALSE, etc.
    const start = self.pos;
    // Handle leading sign: -1, +1
    if (self.peek() == '-' or self.peek() == '+') {
        self.advance();
    }
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

/// Parse a general SQL expression — captures everything up to the given delimiter
/// (comma, closing paren, or end of input). Handles balanced parentheses and
/// quoted strings. Returns the raw expression text.
pub fn parseExpression(self: *sp.SqlParser) []const u8 {
    const start = self.pos;
    var depth: usize = 0;
    while (self.pos < self.src.len) {
        const c = self.peek();
        if (c == '(') {
            depth += 1;
            self.advance();
        } else if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
            self.advance();
        } else if (c == '\'') {
            // Skip quoted string
            self.advance();
            while (self.pos < self.src.len and self.peek() != '\'') {
                if (self.peek() == '\\' and self.pos + 1 < self.src.len) {
                    self.advance(); // skip backslash
                }
                self.advance();
            }
            if (self.peek() == '\'') self.advance();
        } else if (c == ',' and depth == 0) {
            break;
        } else {
            self.advance();
        }
    }
    return std.mem.trim(u8, self.src[start..self.pos], " \t\r\n");
}

// ─── Expression Parsing ────────────────────────────────────────

pub const FieldList = struct {
    fields: std.ArrayList([]const u8),
    descending: std.ArrayList(bool),
};

pub fn parseParenFieldList(self: *sp.SqlParser) !FieldList {
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

pub fn parseParenExpr(self: *sp.SqlParser) ![]const u8 {
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

// ─── Word Parsing ──────────────────────────────────────────────

pub fn parseWord(self: *sp.SqlParser) []const u8 {
    const start = self.pos;
    while (self.pos < self.src.len) {
        const c = self.src[self.pos];
        if (c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z' or c >= '0' and c <= '9' or c == '_') {
            self.pos += 1;
        } else break;
    }
    return self.src[start..self.pos];
}

pub fn skipWord(self: *sp.SqlParser) void {
    while (self.pos < self.src.len) {
        const c = self.src[self.pos];
        if (c >= 'a' and c <= 'z' or c >= 'A' and c <= 'Z' or c >= '0' and c <= '9' or c == '_') {
            self.pos += 1;
        } else break;
    }
}

// ─── Keyword Matching ──────────────────────────────────────────

pub fn matchKeyword(self: *sp.SqlParser, kw: []const u8) bool {
    const saved = self.pos;
    self.skipSpacesAndNewlines();
    const word = self.parseWord();
    if (std.mem.eql(u8, word, kw)) return true;
    self.pos = saved;
    return false;
}

pub fn expectKeyword(self: *sp.SqlParser, kw: []const u8) void {
    self.skipSpaces();
    const word = self.parseWord();
    if (!std.mem.eql(u8, word, kw)) {
        // Don't hard-fail during parsing — just stop gracefully
    }
}

pub fn expect(self: *sp.SqlParser, ch: u8) void {
    self.skipSpacesAndNewlines();
    if (self.pos < self.src.len and self.src[self.pos] == ch) {
        self.pos += 1;
    } else {
        self.reportError("expected '{c}', got '{c}'", .{ ch, self.peek() });
    }
}

pub fn lookaheadIs(self: *sp.SqlParser, kw: []const u8) bool {
    const saved = self.pos;
    self.skipSpacesAndNewlines();
    const word = self.parseWord();
    const result = std.mem.eql(u8, word, kw);
    self.pos = saved;
    return result;
}

pub fn peekWord(self: *sp.SqlParser) []const u8 {
    const saved = self.pos;
    self.skipSpaces();
    const word = self.parseWord();
    self.pos = saved;
    return word;
}

// ─── Character Navigation ──────────────────────────────────────

pub fn peek(self: *sp.SqlParser) u8 {
    if (self.pos < self.src.len) return self.src[self.pos];
    return 0;
}

pub fn advance(self: *sp.SqlParser) void {
    if (self.pos < self.src.len) self.pos += 1;
}

// ─── Whitespace & Comment Skipping ─────────────────────────────

pub fn skipSpaces(self: *sp.SqlParser) void {
    while (self.pos < self.src.len) {
        const c = self.src[self.pos];
        if (c == ' ' or c == '\t') self.pos += 1 else break;
    }
}

pub fn skipSpacesAndNewlines(self: *sp.SqlParser) void {
    while (self.pos < self.src.len) {
        const c = self.src[self.pos];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.pos += 1 else break;
    }
}

pub fn skipWhitespaceAndComments(self: *sp.SqlParser) void {
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

pub fn skipWhitespaceAndCommentsNoSemicolon(self: *sp.SqlParser) void {
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

pub fn skipToSemicolon(self: *sp.SqlParser) void {
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

// ─── Comment Reading & Capture ─────────────────────────────────

/// Read a -- comment (without advancing past whitespace before it).
/// Returns the comment text after "--", or null if no comment found.
pub fn readLineComment(self: *sp.SqlParser) ?[]const u8 {
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
pub fn captureTrailingComments(self: *sp.SqlParser, tables: []common.SqlTable) void {
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
