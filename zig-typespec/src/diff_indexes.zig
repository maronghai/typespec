const std = @import("std");
const ast_mod = @import("ast.zig");
const IndexDecl = ast_mod.IndexDecl;

// ─── Index Diff ────────────────────────────────────────────
// Extracted from diff.zig for single-responsibility.

pub const IndexDiff = struct {
    name: []const u8,
    action: IndexAction,
    old_idx: ?IndexDecl,
    new_idx: ?IndexDecl,
};

pub const IndexAction = enum { add, drop, modify };

pub fn diffIndexes(alloc: std.mem.Allocator, old_idxs: []const IndexDecl, new_idxs: []const IndexDecl) ![]const IndexDiff {
    var diffs = try std.ArrayList(IndexDiff).initCapacity(alloc, 4);

    var old_by_name = std.StringHashMap(usize).init(alloc);
    for (old_idxs, 0..) |idx, i| try old_by_name.put(idx.name, i);
    var new_by_name = std.StringHashMap(usize).init(alloc);
    for (new_idxs, 0..) |idx, i| try new_by_name.put(idx.name, i);

    for (old_idxs) |old_idx| {
        if (new_by_name.get(old_idx.name)) |new_i| {
            const new_idx = new_idxs[new_i];
            if (!indexesEqual(old_idx, new_idx)) {
                try diffs.append(alloc, .{
                    .name = old_idx.name,
                    .action = .modify,
                    .old_idx = old_idx,
                    .new_idx = new_idx,
                });
            }
        } else {
            try diffs.append(alloc, .{
                .name = old_idx.name,
                .action = .drop,
                .old_idx = old_idx,
                .new_idx = null,
            });
        }
    }

    for (new_idxs) |new_idx| {
        if (!old_by_name.contains(new_idx.name)) {
            try diffs.append(alloc, .{
                .name = new_idx.name,
                .action = .add,
                .old_idx = null,
                .new_idx = new_idx,
            });
        }
    }

    return try diffs.toOwnedSlice(alloc);
}

/// Create add-diffs for all indexes of a new table.
pub fn createAllIndexDiffs(alloc: std.mem.Allocator, new_idxs: []const IndexDecl) ![]const IndexDiff {
    var diffs = try std.ArrayList(IndexDiff).initCapacity(alloc, new_idxs.len);
    for (new_idxs) |idx| {
        try diffs.append(alloc, .{
            .name = idx.name,
            .action = .add,
            .old_idx = null,
            .new_idx = idx,
        });
    }
    return try diffs.toOwnedSlice(alloc);
}

pub fn indexesEqual(a: IndexDecl, b: IndexDecl) bool {
    if (a.kind != b.kind) return false;
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f, b.fields[i])) return false;
    }
    return true;
}

// ─── Inline Tests ─────────────────────────────────────────────

fn makeIdx(kind: IndexDecl.IndexType, name: []const u8, fields: []const []const u8) IndexDecl {
    return .{
        .kind = kind,
        .name = name,
        .fields = fields,
        .descending = &.{},
        .line_no = 0,
    };
}

test "diffIndexes identical — no diffs" {
    const alloc = std.testing.allocator;
    const old = [_]IndexDecl{makeIdx(.regular, "idx_a", &.{ "a", "b" })};
    const new_ = [_]IndexDecl{makeIdx(.regular, "idx_a", &.{ "a", "b" })};
    const diffs = try diffIndexes(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "diffIndexes added index" {
    const alloc = std.testing.allocator;
    const old = [_]IndexDecl{};
    const new_ = [_]IndexDecl{makeIdx(.unique, "uk_email", &.{"email"})};
    const diffs = try diffIndexes(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(IndexAction.add, diffs[0].action);
    try std.testing.expectEqualStrings("uk_email", diffs[0].name);
}

test "diffIndexes dropped index" {
    const alloc = std.testing.allocator;
    const old = [_]IndexDecl{makeIdx(.regular, "idx_a", &.{"a"})};
    const new_ = [_]IndexDecl{};
    const diffs = try diffIndexes(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(IndexAction.drop, diffs[0].action);
}

test "diffIndexes modified index (kind change)" {
    const alloc = std.testing.allocator;
    const old = [_]IndexDecl{makeIdx(.regular, "idx_a", &.{"a"})};
    const new_ = [_]IndexDecl{makeIdx(.unique, "idx_a", &.{"a"})};
    const diffs = try diffIndexes(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(IndexAction.modify, diffs[0].action);
}

test "diffIndexes modified index (field change)" {
    const alloc = std.testing.allocator;
    const old = [_]IndexDecl{makeIdx(.regular, "idx_ab", &.{ "a", "b" })};
    const new_ = [_]IndexDecl{makeIdx(.regular, "idx_ab", &.{ "a", "c" })};
    const diffs = try diffIndexes(alloc, &old, &new_);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(IndexAction.modify, diffs[0].action);
}

test "indexesEqual same kind and fields" {
    const a = makeIdx(.unique, "uk", &.{ "a", "b" });
    const b = makeIdx(.unique, "uk", &.{ "a", "b" });
    try std.testing.expect(indexesEqual(a, b));
}

test "indexesEqual different kind" {
    const a = makeIdx(.regular, "idx", &.{"a"});
    const b = makeIdx(.unique, "idx", &.{"a"});
    try std.testing.expect(!indexesEqual(a, b));
}

test "indexesEqual different field count" {
    const a = makeIdx(.regular, "idx", &.{"a"});
    const b = makeIdx(.regular, "idx", &.{ "a", "b" });
    try std.testing.expect(!indexesEqual(a, b));
}
