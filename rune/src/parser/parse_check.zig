const std = @import("std");
const diag = @import("../semantic/diagnostic.zig");
const ast_mod = @import("../types/ast.zig");
const CheckConstraint = ast_mod.CheckConstraint;
const CheckKind = ast_mod.CheckKind;

pub const CheckParseResult = struct {
    check: CheckConstraint,
    end_idx: usize,
};

/// Parse CHECK constraint: `[...]`, `(..)`, or `{..}`.
/// Returns null if token is not a bracket opener.
pub fn parseCheckConstraint(alloc: std.mem.Allocator, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize) !?CheckParseResult {
    const tok = tokens[idx];
    if (tok[0] == '[') {
        return try parseCheckBody(alloc, tokens, idx, raw, line_no, '[', ']');
    }
    if (tok[0] == '(') {
        return try parseCheckBody(alloc, tokens, idx, raw, line_no, '(', ')');
    }
    if (tok[0] == '{') {
        return try parseCheckBody(alloc, tokens, idx, raw, line_no, '{', '}');
    }
    return null;
}

fn parseCheckBody(alloc: std.mem.Allocator, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize, open_bracket: u8, close_bracket: u8) !CheckParseResult {
    const bracket_col = diag.tokenColumn(tokens[idx], raw);
    var check_str = try std.ArrayList(u8).initCapacity(alloc, 32);
    var needs_comma = false;
    var i = idx + 1;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if ((close_bracket == ']' and std.mem.eql(u8, t, "]")) or
            (close_bracket == ')' and std.mem.eql(u8, t, ")")) or
            (close_bracket == '}' and std.mem.eql(u8, t, "}")))
        {
            break;
        }
        // Also stop at mismatched closers (e.g., ] when expecting ))
        if (close_bracket != ']' and std.mem.eql(u8, t, "]")) break;
        if (close_bracket != ')' and std.mem.eql(u8, t, ")")) break;
        if (std.mem.eql(u8, t, ",")) {
            needs_comma = true;
            continue;
        }
        if (needs_comma) try check_str.append(alloc, ',');
        try check_str.appendSlice(alloc, t);
        needs_comma = true;
    }
    if (i >= tokens.len) {
        const expected: []const u8 = switch (close_bracket) {
            ']' => "']'",
            ')' => "')' or ']'",
            else => "'}'",
        };
        diag.printDiagnostic(.{
            .severity = .@"error",
            .line_no = line_no,
            .col = bracket_col,
            .message = "unclosed bracket",
            .expected = expected,
            .actual = "end of line",
            .source_line = raw,
        });
    }
    // Determine actual close bracket for classification
    const actual_close: u8 = if (i < tokens.len) blk: {
        const t = tokens[i];
        if (t.len == 1) break :blk t[0];
        break :blk close_bracket;
    } else close_bracket;
    const check_expr = try check_str.toOwnedSlice(alloc);
    return .{
        .check = .{ .kind = classifyCheck(check_expr, open_bracket, actual_close), .expr = check_expr, .line_no = line_no },
        .end_idx = i + 1, // +1 to skip past closing bracket
    };
}

/// Classify CHECK constraint based on expression content and bracket type.
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
        const third = parts.next();
        // Range: exactly 2 parts, both numeric (no quotes)
        if (third == null and first.len > 0 and second.len > 0) {
            if (first[0] != '\'' and second[0] != '\'') {
                if (open_bracket == '(' and close_bracket == ')') return .range_both_exclusive;
                if (close_bracket == ')') return .range_upper_exclusive;
                if (open_bracket == '(') return .range_lower_exclusive;
                return .range;
            }
        }
        return .in_list;
    }
    return .comparison;
}
