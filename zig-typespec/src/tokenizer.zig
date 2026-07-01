const std = @import("std");

pub const LineType = enum {
    Schema,
    Template,
    Table,
    Field,
    FK,
    Index,
    Slot,
    SQLComment,
    SpecComment,
    Empty,
};

pub const Line = struct {
    line_type: LineType,
    tokens: []const []const u8,
    raw: []const u8,
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
                try result.append(alloc, .{ .line_type = .Empty, .tokens = &.{}, .raw = line, .line_no = i + 1 });
                continue;
            }
            if (trimmed[0] == ';') {
                try result.append(alloc, .{ .line_type = .SpecComment, .tokens = &.{}, .raw = line, .line_no = i + 1 });
                continue;
            }
            if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == '-') {
                try result.append(alloc, .{ .line_type = .SQLComment, .tokens = &.{}, .raw = line, .line_no = i + 1 });
                continue;
            }
            const lt = classifyLine(trimmed);
            const toks = try tokenizeLine(alloc, trimmed);
            try result.append(alloc, .{ .line_type = lt, .tokens = toks, .raw = line, .line_no = i + 1 });
        }
        return try result.toOwnedSlice(alloc);
    }

    fn classifyLine(line: []const u8) LineType {
        if (line[0] == '$') return .Schema;
        if (line[0] == '%') return .Template;
        if (line[0] == '#') return .Table;
        if (line.len >= 2 and line[0] == '-' and line[1] == '>') return .FK;
        if (line[0] == '@') return .Index;
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
            if (tok[0] == '/') {
                if (tok.len >= 2 and tok[1] == '/') {
                    const comment = line[tok.ptr - line.ptr ..];
                    try raw_tokens.append(alloc, comment);
                    break;
                }
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
        if (tok[0] == '/' and tok.len >= 2 and tok[1] == '/') {
            try tokens.append(alloc, tok);
            return;
        }

        // Split leading structural markers: #base → #, base
        if (tok.len > 1 and (tok[0] == '#' or tok[0] == '%' or tok[0] == '$' or tok[0] == '@')) {
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

        // Split leading [: [CASCADE → [, CASCADE
        if (tok.len > 1 and tok[0] == '[') {
            try tokens.append(alloc, tok[0..1]);
            try splitToken(alloc, tokens, tok[1..]);
            return;
        }

        // Split trailing ]: CASCADE] → CASCADE, ]
        if (tok.len > 1 and tok[tok.len - 1] == ']') {
            try splitToken(alloc, tokens, tok[0 .. tok.len - 1]);
            try tokens.append(alloc, "]");
            return;
        }

        // No split needed
        try tokens.append(alloc, tok);
    }
};
