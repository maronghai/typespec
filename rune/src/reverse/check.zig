const std = @import("std");
const ast_mod = @import("../types/ast.zig");
const CheckConstraint = ast_mod.CheckConstraint;
const CheckKind = ast_mod.CheckKind;

// ─── CHECK Constraint Reverse ─────────────────────────────────
// Parses SQL CHECK expressions back to structured CheckConstraint.
// Used by reverse pipeline to convert SQL DDL back to SS IR.

/// Parse a SQL CHECK expression into a structured CheckConstraint.
/// Returns null if the expression doesn't match any known pattern.
pub fn parseSqlCheckExpr(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?CheckConstraint {
    const e = std.mem.trim(u8, sql_expr, " \t");
    if (parseBetweenExpr(alloc, e, col_name)) |r| return r;
    if (parseUpperExclExpr(alloc, e, col_name)) |r| return r;
    if (parseLowerExclExpr(alloc, e, col_name)) |r| return r;
    if (parseBothExclExpr(alloc, e, col_name)) |r| return r;
    if (parseInListExpr(alloc, e, col_name)) |r| return r;
    if (parseCompoundCmpExpr(alloc, e, col_name)) |r| return r;
    if (parseSingleCmpExpr(alloc, e, col_name)) |r| return r;
    return null;
}

/// Legacy: parse SQL CHECK expression and return SS bracket/brace syntax string.
pub fn reverseCheck(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?[]const u8 {
    if (parseSqlCheckExpr(alloc, sql_expr, col_name)) |cc| {
        return checkConstraintToSym(alloc, cc);
    }
    return null;
}

/// Convert a CheckConstraint to SS bracket/brace syntax string.
fn checkConstraintToSym(alloc: std.mem.Allocator, cc: CheckConstraint) ?[]const u8 {
    return switch (cc.kind) {
        .range => std.fmt.allocPrint(alloc, "[{s}]", .{cc.expr}) catch null,
        .range_upper_exclusive => std.fmt.allocPrint(alloc, "[{s})", .{cc.expr}) catch null,
        .range_lower_exclusive => std.fmt.allocPrint(alloc, "({s}]", .{cc.expr}) catch null,
        .range_both_exclusive => std.fmt.allocPrint(alloc, "({s})", .{cc.expr}) catch null,
        .in_list => std.fmt.allocPrint(alloc, "{{{s}}}", .{cc.expr}) catch null,
        .comparison => std.fmt.allocPrint(alloc, "{{{s}}}", .{cc.expr}) catch null,
    };
}

fn parseBetweenExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    const bp = std.mem.indexOf(u8, e, " BETWEEN ") orelse return null;
    if (!fieldMatches(e[0..bp], cn)) return null;
    const rest = e[bp + 9 ..];
    const ap = std.mem.indexOf(u8, rest, " AND ") orelse return null;
    const low = std.mem.trim(u8, rest[0..ap], " ");
    const high = std.mem.trim(u8, rest[ap + 5 ..], " ");
    const expr = std.fmt.allocPrint(alloc, "{s},{s}", .{ low, high }) catch return null;
    return .{ .kind = .range, .expr = expr, .line_no = 0 };
}

fn parseUpperExclExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lp = std.mem.indexOf(u8, l, " >= ") orelse return null;
    const rp = std.mem.indexOf(u8, r, " < ") orelse return null;
    if (!fieldMatches(l[0..lp], cn) or !fieldMatches(r[0..rp], cn)) return null;
    const high = r[rp + 3 ..];
    if (high.len > 0 and high[0] == '=') return null;
    const low = l[lp + 4 ..];
    const expr = std.fmt.allocPrint(alloc, "{s},{s}", .{ low, high }) catch return null;
    return .{ .kind = .range_upper_exclusive, .expr = expr, .line_no = 0 };
}

fn parseLowerExclExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lp = std.mem.indexOf(u8, l, " > ") orelse return null;
    const rp = std.mem.indexOf(u8, r, " <= ") orelse return null;
    if (!fieldMatches(l[0..lp], cn) or !fieldMatches(r[0..rp], cn)) return null;
    const low = l[lp + 3 ..];
    if (low.len > 0 and low[0] == '=') return null;
    const high = r[rp + 4 ..];
    const expr = std.fmt.allocPrint(alloc, "{s},{s}", .{ low, high }) catch return null;
    return .{ .kind = .range_lower_exclusive, .expr = expr, .line_no = 0 };
}

fn parseBothExclExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lp = std.mem.indexOf(u8, l, " > ") orelse return null;
    const rp = std.mem.indexOf(u8, r, " < ") orelse return null;
    if (!fieldMatches(l[0..lp], cn) or !fieldMatches(r[0..rp], cn)) return null;
    const low = l[lp + 3 ..];
    const high = r[rp + 3 ..];
    if ((low.len > 0 and low[0] == '=') or (high.len > 0 and high[0] == '=')) return null;
    const expr = std.fmt.allocPrint(alloc, "{s},{s}", .{ low, high }) catch return null;
    return .{ .kind = .range_both_exclusive, .expr = expr, .line_no = 0 };
}

fn parseInListExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    const ip = std.mem.indexOf(u8, e, " IN ") orelse return null;
    if (!fieldMatches(e[0..ip], cn)) return null;
    const rest = e[ip + 4 ..];
    if (rest.len == 0 or rest[0] != '(') return null;
    // Parse: (val1,val2,...) → expr = val1,val2,...
    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return null;
    var i: usize = 1;
    var first = true;
    while (i < rest.len and rest[i] != ')') {
        if (rest[i] == '\'') {
            i += 1;
            const s = i;
            while (i < rest.len and rest[i] != '\'') i += 1;
            const val = rest[s..i];
            if (i < rest.len) i += 1;
            if (!first) buf.append(alloc, ',') catch return null;
            first = false;
            buf.appendSlice(alloc, val) catch return null;
        } else if (rest[i] == ' ' or rest[i] == ',' or rest[i] == '\t') {
            i += 1;
        } else {
            const s = i;
            while (i < rest.len and rest[i] != ')' and rest[i] != ',' and rest[i] != ' ') i += 1;
            const v = std.mem.trim(u8, rest[s..i], " ");
            if (v.len > 0) {
                if (!first) buf.append(alloc, ',') catch return null;
                first = false;
                buf.appendSlice(alloc, v) catch return null;
            }
        }
    }
    const expr = buf.toOwnedSlice(alloc) catch return null;
    return .{ .kind = .in_list, .expr = expr, .line_no = 0 };
}

fn parseCompoundCmpExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lo = oneCmpStr(alloc, l, cn) orelse return null;
    const ro = oneCmpStr(alloc, r, cn) orelse return null;
    const expr = std.fmt.allocPrint(alloc, "{s},{s}", .{ lo, ro }) catch return null;
    return .{ .kind = .comparison, .expr = expr, .line_no = 0 };
}

fn parseSingleCmpExpr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?CheckConstraint {
    if (std.mem.indexOf(u8, e, " AND ") != null) return null;
    const cmp = oneCmpStr(alloc, e, cn) orelse return null;
    return .{ .kind = .comparison, .expr = cmp, .line_no = 0 };
}

fn oneCmpStr(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ops = [_][]const u8{ ">=", "<=", ">", "<", "=" };
    for (ops) |op| {
        const pp = std.mem.indexOf(u8, e, op) orelse continue;
        if (!fieldMatches(e[0..pp], cn)) continue;
        const v = std.mem.trim(u8, e[pp + op.len ..], " ");
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ op, v }) catch null;
    }
    return null;
}

fn fieldMatches(raw: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t`"), expected);
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

test "reverseCheck BETWEEN" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "age BETWEEN 0 AND 150", "age");
    try testing.expect(result != null);
    try testing.expectEqualStrings("[0,150]", result.?);
}

test "reverseCheck IN list" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "status IN ('active', 'pending')", "status");
    try testing.expect(result != null);
    try testing.expectEqualStrings("{active,pending}", result.?);
}

test "reverseCheck >= comparison" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "age >= 18", "age");
    try testing.expect(result != null);
    try testing.expectEqualStrings("{>=18}", result.?);
}

test "reverseCheck upper exclusive range" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "price >= 10 AND price < 100", "price");
    try testing.expect(result != null);
    try testing.expectEqualStrings("[10,100)", result.?);
}

test "reverseCheck lower exclusive range" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "score > 0 AND score <= 100", "score");
    try testing.expect(result != null);
    try testing.expectEqualStrings("(0,100]", result.?);
}

test "reverseCheck no match → null" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "x = 1", "y");
    try testing.expect(result == null);
}

test "reverseCheck both exclusive range" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "score > 0 AND score < 100", "score");
    try testing.expect(result != null);
    try testing.expectEqualStrings("(0,100)", result.?);
}

test "reverseCheck compound comparison >= AND <=" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "age >= 18 AND age <= 65", "age");
    try testing.expect(result != null);
    try testing.expectEqualStrings("{>=18,<=65}", result.?);
}

test "reverseCheck single comparison =" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "status = 1", "status");
    try testing.expect(result != null);
    try testing.expectEqualStrings("{=1}", result.?);
}

test "reverseCheck single comparison <" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "count < 10", "count");
    try testing.expect(result != null);
    try testing.expectEqualStrings("{<10}", result.?);
}

test "reverseCheck backtick-quoted column" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "`age` BETWEEN 0 AND 150", "age");
    try testing.expect(result != null);
    try testing.expectEqualStrings("[0,150]", result.?);
}

test "reverseCheck double-quote-quoted column" {
    const alloc = testing.allocator;
    const result = reverseCheck(alloc, "\"age\" BETWEEN 0 AND 150", "age");
    try testing.expect(result != null);
    try testing.expectEqualStrings("[0,150]", result.?);
}
