const std = @import("std");

pub const LineType = enum {
    Schema,
    Template,
    Table,
    Field,
    FK,
    Index,
    Slot,
    CompositePK,
    Engine,
    SQLComment,
    SpecComment,
    Empty,
};

pub const Line = struct {
    line_type: LineType,
    tokens: []const []const u8,
    raw: []const u8,
    trimmed: []const u8,
    line_no: usize,
};

pub const Tokenizer = struct {
    lines: []const []const u8,

    pub fn init(lines: []const []const u8) Tokenizer {
        return .{ .lines = lines };
    }

    pub fn tokenizeAll(self: Tokenizer, alloc: std.mem.Allocator) ![]Line {
        var result = try std.ArrayList(Line).initCapacity(alloc, self.lines.len);
        for (self.lines, 0..) |line, i| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) {
                try result.append(alloc, .{ .line_type = .Empty, .tokens = &.{}, .raw = line, .trimmed = line, .line_no = i + 1 });
                continue;
            }
            if (trimmed[0] == ';') {
                try result.append(alloc, .{ .line_type = .SpecComment, .tokens = &.{}, .raw = line, .trimmed = trimmed, .line_no = i + 1 });
                continue;
            }
            if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == '-') {
                try result.append(alloc, .{ .line_type = .SQLComment, .tokens = &.{}, .raw = line, .trimmed = trimmed, .line_no = i + 1 });
                continue;
            }
            const lt = classifyLine(trimmed);
            const toks = try tokenizeLine(alloc, trimmed);
            try result.append(alloc, .{ .line_type = lt, .tokens = toks, .raw = line, .trimmed = trimmed, .line_no = i + 1 });
        }
        return try result.toOwnedSlice(alloc);
    }

    fn classifyLine(line: []const u8) LineType {
        if (line[0] == '$') return .Schema;
        if (line[0] == '%') return .Template;
        if (line[0] == '#') return .Table;
        if (line[0] == '>') return .FK;
        if (line[0] == '!' and (line.len == 1 or line[1] == ' ')) return .CompositePK;
        if (line[0] == '@') return .Index;
        if (line[0] == '^') return .Engine;
        if (line.len >= 3 and line[0] == '.' and line[1] == '.' and line[2] == '.') return .Slot;
        return .Field;
    }

    fn tokenizeLine(alloc: std.mem.Allocator, line: []const u8) ![]const []const u8 {
        // First pass: split by spaces
        var raw_tokens = try std.ArrayList([]const u8).initCapacity(alloc, 8);
        var space_it = std.mem.splitScalar(u8, line, ' ');
        while (space_it.next()) |tok| {
            if (tok.len == 0) continue;
            if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') break;
            if (tok[0] == ';') break;
            if (tok[0] == ':') {
                const comment = line[tok.ptr - line.ptr ..];
                try raw_tokens.append(alloc, comment);
                break;
            }
            try raw_tokens.append(alloc, tok);
        }

        // Second pass: iteratively split tokens
        var tokens = try std.ArrayList([]const u8).initCapacity(alloc, raw_tokens.items.len * 2);
        for (raw_tokens.items) |tok| {
            try splitToken(alloc, &tokens, tok);
        }
        return try tokens.toOwnedSlice(alloc);
    }

    fn splitToken(alloc: std.mem.Allocator, tokens: *std.ArrayList([]const u8), tok: []const u8) !void {
        // Comment - keep as is
        if (tok[0] == ':') {
            try tokens.append(alloc, tok);
            return;
        }

        // Split leading structural markers: #base → #, base
        if (tok.len > 1 and (tok[0] == '#' or tok[0] == '%' or tok[0] == '$' or tok[0] == '@' or tok[0] == '^')) {
            try tokens.append(alloc, tok[0..1]);
            try splitToken(alloc, tokens, tok[1..]);
            return;
        }

        // Split leading (: (email → (, email
        if (tok.len > 1 and tok[0] == '(') {
            try tokens.append(alloc, "(");
            try splitToken(alloc, tokens, tok[1..]);
            return;
        }

        // Split enum type: e(M,F,X) → e, (, M, ,, F, ,, X, )
        if (tok.len > 2 and tok[0] == 'e' and tok[1] == '(') {
            try tokens.append(alloc, "e");
            try splitToken(alloc, tokens, tok[1..]);
            return;
        }

        // Split trailing ): email) → email, )
        if (tok.len > 1 and tok[tok.len - 1] == ')') {
            try splitToken(alloc, tokens, tok[0 .. tok.len - 1]);
            try tokens.append(alloc, ")");
            return;
        }

        // Split trailing comma: user_id, → user_id, ,
        if (tok.len > 1 and tok[tok.len - 1] == ',') {
            try splitToken(alloc, tokens, tok[0 .. tok.len - 1]);
            try tokens.append(alloc, ",");
            return;
        }

        // Split embedded (: order_item(order_id → order_item, (, order_id
        if (tok.len > 2 and tok[0] != '(' and std.mem.indexOfScalar(u8, tok, '(') != null) {
            if (std.mem.indexOfScalar(u8, tok, '(')) |paren_pos| {
                if (paren_pos > 0) try tokens.append(alloc, tok[0..paren_pos]);
                try splitToken(alloc, tokens, tok[paren_pos..]);
                return;
            }
        }

        // Split leading [: [0,1] → [, 0,1]
        if (tok.len > 1 and tok[0] == '[') {
            try tokens.append(alloc, tok[0..1]);
            try splitToken(alloc, tokens, tok[1..]);
            return;
        }

        // Split trailing ]: 0,1] → 0,1, ]
        if (tok.len > 1 and tok[tok.len - 1] == ']') {
            try splitToken(alloc, tokens, tok[0 .. tok.len - 1]);
            try tokens.append(alloc, "]");
            return;
        }

        // Split leading {: {0,1} → {, 0,1}
        if (tok.len > 1 and tok[0] == '{') {
            try tokens.append(alloc, tok[0..1]);
            try splitToken(alloc, tokens, tok[1..]);
            return;
        }

        // Split trailing }: 0,1} → 0,1, }
        if (tok.len > 1 and tok[tok.len - 1] == '}') {
            try splitToken(alloc, tokens, tok[0 .. tok.len - 1]);
            try tokens.append(alloc, "}");
            return;
        }

        // No split needed
        try tokens.append(alloc, tok);
    }

    pub fn diagnosticTrace(lines: []const Line) void {
        std.debug.print("=== [Stage 1: Tokenizer] ===\n", .{});
        std.debug.print("Input lines: {d}\n\n", .{lines.len});
        for (lines) |line| {
            if (line.line_type == .Empty or line.line_type == .SpecComment) continue;
            std.debug.print("  L{d: >4} [{s: <12}] ", .{ line.line_no, @tagName(line.line_type) });
            for (line.tokens, 0..) |tok, ti| {
                if (ti > 0) std.debug.print(" ", .{});
                std.debug.print("{s}", .{tok});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
};

// ─── Tests ────────────────────────────────────────────────────

test "classifyLine: $ is Schema" {
    try std.testing.expectEqual(LineType.Schema, Tokenizer.classifyLine("$ mydb"));
}

test "classifyLine: % is Template" {
    try std.testing.expectEqual(LineType.Template, Tokenizer.classifyLine("% base"));
}

test "classifyLine: # is Table" {
    try std.testing.expectEqual(LineType.Table, Tokenizer.classifyLine("# user"));
}

test "classifyLine: > is FK" {
    try std.testing.expectEqual(LineType.FK, Tokenizer.classifyLine("> user_id users.id"));
}

test "classifyLine: ! is CompositePK" {
    try std.testing.expectEqual(LineType.CompositePK, Tokenizer.classifyLine("!"));
}

test "classifyLine: @ is Index" {
    try std.testing.expectEqual(LineType.Index, Tokenizer.classifyLine("@ idx_name (name)"));
}

test "classifyLine: ^ is Engine" {
    try std.testing.expectEqual(LineType.Engine, Tokenizer.classifyLine("^ InnoDB"));
}

test "classifyLine: ... is Slot" {
    try std.testing.expectEqual(LineType.Slot, Tokenizer.classifyLine("..."));
}

test "classifyLine: plain text is Field" {
    try std.testing.expectEqual(LineType.Field, Tokenizer.classifyLine("name s32 *"));
}

test "tokenizeLine: simple field" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "name s32 *");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("name", toks[0]);
    try std.testing.expectEqualStrings("s32", toks[1]);
    try std.testing.expectEqualStrings("*", toks[2]);
}

test "tokenizeLine: fused type modifier" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "id n++");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("id", toks[0]);
    try std.testing.expectEqualStrings("n", toks[1]);
    try std.testing.expectEqualStrings("++", toks[2]);
}

test "tokenizeLine: table header" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "# base user");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("#", toks[0]);
    try std.testing.expectEqualStrings("base", toks[1]);
    try std.testing.expectEqualStrings("user", toks[2]);
}

test "tokenizeLine: enum type" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "status e(A,B,C)");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 7), toks.len);
    try std.testing.expectEqualStrings("status", toks[0]);
    try std.testing.expectEqualStrings("e", toks[1]);
    try std.testing.expectEqualStrings("(", toks[2]);
    try std.testing.expectEqualStrings("A", toks[3]);
    try std.testing.expectEqualStrings(",", toks[4]);
    try std.testing.expectEqualStrings("B", toks[5]);
    try std.testing.expectEqualStrings(")", toks[6]);
}

test "tokenizeLine: comment stops at --" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "name s32 -- varchar type");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("name", toks[0]);
    try std.testing.expectEqualStrings("s32", toks[1]);
}

test "tokenizeLine: inline FK" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "user_id n > users.id");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 5), toks.len);
    try std.testing.expectEqualStrings("user_id", toks[0]);
    try std.testing.expectEqualStrings("n", toks[1]);
    try std.testing.expectEqualStrings(">", toks[2]);
    try std.testing.expectEqualStrings("users.id", toks[3]);
}

test "tokenizeLine: default value" {
    const alloc = std.testing.allocator;
    const toks = try Tokenizer.tokenizeLine(alloc, "status s =active");
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqualStrings("status", toks[0]);
    try std.testing.expectEqualStrings("s", toks[1]);
    try std.testing.expectEqualStrings("=active", toks[2]);
}

test "tokenizeAll: empty lines" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "", "  ", "" };
    const tok = Tokenizer.init(&lines);
    const result = try tok.tokenizeAll(alloc);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(LineType.Empty, result[0].line_type);
    try std.testing.expectEqual(LineType.Empty, result[1].line_type);
    try std.testing.expectEqual(LineType.Empty, result[2].line_type);
}

test "tokenizeAll: mixed content" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "$ mydb", "", "# user", "name s32 *" };
    const tok = Tokenizer.init(&lines);
    const result = try tok.tokenizeAll(alloc);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqual(LineType.Schema, result[0].line_type);
    try std.testing.expectEqual(LineType.Empty, result[1].line_type);
    try std.testing.expectEqual(LineType.Table, result[2].line_type);
    try std.testing.expectEqual(LineType.Field, result[3].line_type);
}

test "tokenizeAll: spec comment" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "; this is a spec comment" };
    const tok = Tokenizer.init(&lines);
    const result = try tok.tokenizeAll(alloc);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(LineType.SpecComment, result[0].line_type);
}

test "tokenizeAll: SQL comment" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "-- CREATE TABLE foo (" };
    const tok = Tokenizer.init(&lines);
    const result = try tok.tokenizeAll(alloc);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(LineType.SQLComment, result[0].line_type);
}
