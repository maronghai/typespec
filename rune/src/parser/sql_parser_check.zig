const std = @import("std");
const sp = @import("sql_parser.zig");
const common = @import("sql_parser_common.zig");
const SqlCheck = common.SqlCheck;

// ─── CHECK Constraint Parsing ─────────────────────────────────

pub fn parseCheck(self: *sp.SqlParser) !SqlCheck {
    self.expectKeyword("CHECK");
    self.skipSpaces();
    self.expect('(');
    const expr = try self.parseCheckExpr();
    self.expect(')');

    return .{
        .field_name = "",
        .expr = expr,
    };
}

pub fn parseCheckExpr(self: *sp.SqlParser) ![]const u8 {
    const start = self.pos;
    var depth: usize = 1;
    while (self.pos < self.src.len and depth > 0) {
        const c = self.peek();
        if (c == '(') depth += 1 else if (c == ')') depth -= 1;
        if (depth > 0) self.advance();
    }
    return std.mem.trim(u8, self.src[start..self.pos], " \t\n\r");
}
