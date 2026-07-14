const std = @import("std");
const ast_mod = @import("ast.zig");
const FkDecl = ast_mod.FkDecl;

// ─── FK Diff ───────────────────────────────────────────────
// Extracted from diff.zig for single-responsibility.

pub const FkDiff = struct {
    action: FkAction,
    old_fk: ?FkDecl,
    new_fk: ?FkDecl,
};

pub const FkAction = enum { add, drop };

pub fn diffFks(alloc: std.mem.Allocator, old_fks: []const FkDecl, new_fks: []const FkDecl) ![]const FkDiff {
    var diffs = try std.ArrayList(FkDiff).initCapacity(alloc, 4);

    var old_matched = try std.ArrayList(bool).initCapacity(alloc, old_fks.len);
    for (old_fks) |_| try old_matched.append(alloc, false);
    var new_matched = try std.ArrayList(bool).initCapacity(alloc, new_fks.len);
    for (new_fks) |_| try new_matched.append(alloc, false);

    for (old_fks, 0..) |old_fk, oi| {
        for (new_fks, 0..) |new_fk, ni| {
            if (!new_matched.items[ni] and fksEqual(old_fk, new_fk)) {
                old_matched.items[oi] = true;
                new_matched.items[ni] = true;
                break;
            }
        }
    }

    for (old_fks, 0..) |old_fk, oi| {
        if (!old_matched.items[oi]) {
            try diffs.append(alloc, .{
                .action = .drop,
                .old_fk = old_fk,
                .new_fk = null,
            });
        }
    }

    for (new_fks, 0..) |new_fk, ni| {
        if (!new_matched.items[ni]) {
            try diffs.append(alloc, .{
                .action = .add,
                .old_fk = null,
                .new_fk = new_fk,
            });
        }
    }

    return try diffs.toOwnedSlice(alloc);
}

/// Create add-diffs for all FKs of a new table.
pub fn createAllFkDiffs(alloc: std.mem.Allocator, new_fks: []const FkDecl) ![]const FkDiff {
    var diffs = try std.ArrayList(FkDiff).initCapacity(alloc, new_fks.len);
    for (new_fks) |fk| {
        try diffs.append(alloc, .{
            .action = .add,
            .old_fk = null,
            .new_fk = fk,
        });
    }
    return try diffs.toOwnedSlice(alloc);
}

pub fn fksEqual(a: FkDecl, b: FkDecl) bool {
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f, b.fields[i])) return false;
    }
    if (!std.mem.eql(u8, a.ref_table, b.ref_table)) return false;
    if (a.ref_fields.len != b.ref_fields.len) return false;
    for (a.ref_fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f, b.ref_fields[i])) return false;
    }
    if (a.actions.len != b.actions.len) return false;
    for (a.actions, 0..) |act, i| {
        if (act.trigger != b.actions[i].trigger or act.action != b.actions[i].action) return false;
    }
    return true;
}

// ─── Inline Tests ─────────────────────────────────────────────

fn makeFk(fields: []const []const u8, ref_table: []const u8, ref_fields: []const []const u8, actions: []const ast_mod.FkAction) FkDecl {
    return .{
        .fields = fields,
        .ref_table = ref_table,
        .ref_fields = ref_fields,
        .actions = actions,
        .line_no = 0,
    };
}

test "diffFks identical — no diffs" {
    const alloc = std.testing.allocator;
    const old = [_]FkDecl{makeFk(&.{"user_id"}, "user", &.{"id"}, &.{})};
    const new_ = [_]FkDecl{makeFk(&.{"user_id"}, "user", &.{"id"}, &.{})};
    const diffs = try diffFks(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "diffFks added FK" {
    const alloc = std.testing.allocator;
    const old = [_]FkDecl{};
    const new_ = [_]FkDecl{makeFk(&.{"user_id"}, "user", &.{"id"}, &.{})};
    const diffs = try diffFks(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(FkAction.add, diffs[0].action);
    try std.testing.expect(diffs[0].new_fk != null);
    try std.testing.expect(diffs[0].old_fk == null);
}

test "diffFks dropped FK" {
    const alloc = std.testing.allocator;
    const old = [_]FkDecl{makeFk(&.{"user_id"}, "user", &.{"id"}, &.{})};
    const new_ = [_]FkDecl{};
    const diffs = try diffFks(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(FkAction.drop, diffs[0].action);
    try std.testing.expect(diffs[0].old_fk != null);
    try std.testing.expect(diffs[0].new_fk == null);
}

test "diffFks changed FK — drop + add" {
    const alloc = std.testing.allocator;
    // Changed ref_fields from (id) to (uuid) — this is a drop + add, not modify
    const old = [_]FkDecl{makeFk(&.{"user_id"}, "user", &.{"id"}, &.{})};
    const new_ = [_]FkDecl{makeFk(&.{"user_id"}, "user", &.{"uuid"}, &.{})};
    const diffs = try diffFks(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 2), diffs.len);
    // One drop and one add
    var has_add = false;
    var has_drop = false;
    for (diffs) |d| {
        if (d.action == .add) has_add = true;
        if (d.action == .drop) has_drop = true;
    }
    try std.testing.expect(has_add);
    try std.testing.expect(has_drop);
}

test "diffFks empty lists" {
    const alloc = std.testing.allocator;
    const old = [_]FkDecl{};
    const new_ = [_]FkDecl{};
    const diffs = try diffFks(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "diffFks multi-match bipartite" {
    const alloc = std.testing.allocator;
    // Two old FKs and two new FKs — both match → no diffs
    const old = [_]FkDecl{
        makeFk(&.{"a_id"}, "a", &.{"id"}, &.{}),
        makeFk(&.{"b_id"}, "b", &.{"id"}, &.{}),
    };
    const new_ = [_]FkDecl{
        makeFk(&.{"a_id"}, "a", &.{"id"}, &.{}),
        makeFk(&.{"b_id"}, "b", &.{"id"}, &.{}),
    };
    const diffs = try diffFks(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "fksEqual basic" {
    const a = makeFk(&.{"user_id"}, "user", &.{"id"}, &.{});
    const b = makeFk(&.{"user_id"}, "user", &.{"id"}, &.{});
    try std.testing.expect(fksEqual(a, b));
}

test "fksEqual different ref_table" {
    const a = makeFk(&.{"user_id"}, "user", &.{"id"}, &.{});
    const b = makeFk(&.{"user_id"}, "admin", &.{"id"}, &.{});
    try std.testing.expect(!fksEqual(a, b));
}

test "fksEqual different fields" {
    const a = makeFk(&.{"user_id"}, "user", &.{"id"}, &.{});
    const b = makeFk(&.{"admin_id"}, "user", &.{"id"}, &.{});
    try std.testing.expect(!fksEqual(a, b));
}
