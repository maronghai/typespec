// ─── CHECK Constraint Parsing ─────────────────────────────────
// Extracted from parser.zig for modularity.

const std = @import("std");
const ast_mod = @import("ast.zig");
const diag = @import("diagnostic.zig");
const CheckConstraint = ast_mod.CheckConstraint;
const CheckKind = ast_mod.CheckKind;

pub const CheckResult = struct {
    check: CheckConstraint,
    end_idx: usize,
};

pub fn parseCheckConstraint(
    alloc: std.mem.Allocator,
    tokens: []const []const u8,
    idx: usize,
    raw: []const u8,
    line_no: usize,
) !?CheckResult {
    if (idx >= tokens.len) return null;
    const tok = tokens[idx];
    if (tok.len != 1) return null;
    const bracket = tok[0];
    if (bracket != '[' and bracket != '{' and bracket != '(') return null;
    const close: u8 = switch (bracket) {
        '[' => ']',
        '{' => '}',
        '(' => ')',
        else => return null,
    };
    return try parseCheckBody(alloc, tokens, idx + 1, raw, line_no, bracket, close);
}

fn parseCheckBody(
    alloc: std.mem.Allocator,
    tokens: []const []const u8,
    idx: usize,
    raw: []const u8,
    line_no: usize,
    open_bracket: u8,
    close_bracket: u8,
) !CheckResult {
    // Collect expression tokens between brackets
    var expr_buf = try std.ArrayList(u8).initCapacity(alloc, 64);
    var i = idx;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].len == 1 and tokens[i][0] == close_bracket) break;
        if (expr_buf.items.len > 0) try expr_buf.append(alloc, ' ');
        try expr_buf.appendSlice(alloc, tokens[i]);
    }
    if (i >= tokens.len) {
        const col = diag.tokenColumn(tokens[idx - 1], raw);
        diag.printDiagnostic(.{
            .severity = .@"error",
            .line_no = line_no,
            .col = col,
            .message = "unterminated CHECK constraint",
            .expected = "')'",
            .source_line = raw,
        });
        return error.ParseError;
    }
    const expr = try expr_buf.toOwnedSlice(alloc);
    const kind = classifyCheck(expr, open_bracket, close_bracket);
    return .{
        .check = .{ .kind = kind, .expr = expr, .line_no = line_no },
        .end_idx = i + 1,
    };
}

pub fn classifyCheck(expr: []const u8, open_bracket: u8, close_bracket: u8) CheckKind {
    // Handle comparison (contains > < =)
    if (std.mem.indexOfScalar(u8, expr, '>') != null or std.mem.indexOfScalar(u8, expr, '<') != null) {
        // {braces} → always comparison
        if (open_bracket == '{') return .comparison;
        // [] with comparison operators → not supported, use {}
        if (open_bracket == '[' and close_bracket == ']') return .range;
        // [a,b) or (a,b] or (a,b) form → exclusive range
        if (open_bracket == '(' and close_bracket == ')') return .range_both_exclusive;
        if (close_bracket == ')') return .range_upper_exclusive;
        if (open_bracket == '(') return .range_lower_exclusive;
        return .range_both_exclusive;
    }
    // Handle IN list (always {braces})
    if (open_bracket == '{') return .in_list;
    // Handle range
    if (std.mem.indexOfScalar(u8, expr, ',') != null) {
        var parts = std.mem.splitScalar(u8, expr, ',');
        const first = std.mem.trim(u8, parts.next() orelse "", " ");
        const second = std.mem.trim(u8, parts.next() orelse "", " ");
        // Check for comparison operators in range parts
        if (std.mem.indexOfScalar(u8, first, '>') != null or std.mem.indexOfScalar(u8, first, '<') != null or
            std.mem.indexOfScalar(u8, second, '>') != null or std.mem.indexOfScalar(u8, second, '<') != null)
        {
            if (open_bracket == '(' and close_bracket == ')') return .range_both_exclusive;
            if (close_bracket == ')') return .range_upper_exclusive;
            if (open_bracket == '(') return .range_lower_exclusive;
            return .range;
        }
        // Pure numeric range
        if (open_bracket == '(' and close_bracket == ')') return .range_both_exclusive;
        if (close_bracket == ')') return .range_upper_exclusive;
        if (open_bracket == '(') return .range_lower_exclusive;
        return .range;
    }
    // Single value with = or comparison → comparison
    if (std.mem.indexOfScalar(u8, expr, '=') != null) return .comparison;
    // Default: range for [], comparison for {}
    return if (open_bracket == '{') .comparison else .range;
}
