const std = @import("std");
const sp = @import("sql_parser.zig");

// ─── FK Reverse Classification ─────────────────────────────────
// Extracted from reverse_codegen.zig for single-responsibility.
// Classifies SQL foreign keys into SS shorthand/full forms.

pub const FkForm = enum { ultra, shorthand, full };

pub const FkClassification = struct {
    form: FkForm,
    text: ?[]const u8,
};

pub fn classifyFk(alloc: std.mem.Allocator, fk: sp.SqlForeignKey) FkClassification {
    const single = fk.fields.len == 1 and fk.ref_fields.len == 1;
    const ref_is_id = fk.ref_fields.len == 1 and std.mem.eql(u8, fk.ref_fields[0], "id");

    if (single and ref_is_id) return .{ .form = .shorthand, .text = fmtFk(alloc, "> {s} {s}.id", .{ fk.fields[0], fk.ref_table }) };

    // Full form — use ArrayList for dynamic sizing
    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return .{ .form = .full, .text = null };
    buf.appendSlice(alloc, "> ") catch return .{ .form = .full, .text = null };
    if (single) {
        buf.appendSlice(alloc, fk.fields[0]) catch return .{ .form = .full, .text = null };
    } else {
        buf.append(alloc, '(') catch return .{ .form = .full, .text = null };
        for (fk.fields, 0..) |f, i| {
            if (i > 0) buf.appendSlice(alloc, ", ") catch return .{ .form = .full, .text = null };
            buf.appendSlice(alloc, f) catch return .{ .form = .full, .text = null };
        }
        buf.append(alloc, ')') catch return .{ .form = .full, .text = null };
    }
    buf.append(alloc, ' ') catch return .{ .form = .full, .text = null };
    buf.appendSlice(alloc, fk.ref_table) catch return .{ .form = .full, .text = null };
    buf.append(alloc, '(') catch return .{ .form = .full, .text = null };
    for (fk.ref_fields, 0..) |f, i| {
        if (i > 0) buf.appendSlice(alloc, ", ") catch return .{ .form = .full, .text = null };
        buf.appendSlice(alloc, f) catch return .{ .form = .full, .text = null };
    }
    buf.append(alloc, ')') catch return .{ .form = .full, .text = null };

    for (fk.actions) |a| {
        buf.append(alloc, ' ') catch return .{ .form = .full, .text = null };
        switch (a.trigger) {
            .on_delete => switch (a.action) {
                .cascade => buf.appendSlice(alloc, "-C") catch {},
                .set_null => buf.appendSlice(alloc, "-N") catch {},
                else => buf.appendSlice(alloc, "-?") catch {},
            },
            .on_update => switch (a.action) {
                .cascade => buf.appendSlice(alloc, " C") catch {},
                .set_null => buf.appendSlice(alloc, " N") catch {},
                else => buf.appendSlice(alloc, " ?") catch {},
            },
        }
    }

    return .{ .form = .full, .text = buf.toOwnedSlice(alloc) catch null };
}

fn fmtFk(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch null;
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

test "classifyFk shorthand single->id" {
    const alloc = testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"user_id"},
        .ref_table = "user",
        .ref_fields = &.{"id"},
        .actions = &.{},
    };
    const result = classifyFk(alloc, fk);
    try testing.expectEqual(FkForm.shorthand, result.form);
    try testing.expect(result.text != null);
    try testing.expectEqualStrings("> user_id user.id", result.text.?);
}

test "classifyFk full multi-field" {
    const alloc = testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{ "a_id", "b_id" },
        .ref_table = "ab",
        .ref_fields = &.{ "a", "b" },
        .actions = &.{},
    };
    const result = classifyFk(alloc, fk);
    try testing.expectEqual(FkForm.full, result.form);
}

test "classifyFk full with actions" {
    const alloc = testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"order_id"},
        .ref_table = "orders",
        .ref_fields = &.{"id"},
        .actions = &.{
            .{ .trigger = .on_delete, .action = .cascade },
        },
    };
    const result = classifyFk(alloc, fk);
    try testing.expectEqual(FkForm.full, result.form);
    try testing.expect(result.text != null);
    try testing.expectEqualStrings("> order_id orders.id -C", result.text.?);
}

test "classifyFk full with multiple actions" {
    const alloc = testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"order_id"},
        .ref_table = "orders",
        .ref_fields = &.{"id"},
        .actions = &.{
            .{ .trigger = .on_delete, .action = .cascade },
            .{ .trigger = .on_update, .action = .set_null },
        },
    };
    const result = classifyFk(alloc, fk);
    try testing.expectEqual(FkForm.full, result.form);
    try testing.expect(result.text != null);
    try testing.expectEqualStrings("> order_id orders.id -C N", result.text.?);
}

test "classifyFk shorthand with non-id reference" {
    const alloc = testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"email"},
        .ref_table = "auth",
        .ref_fields = &.{"email"},
        .actions = &.{},
    };
    const result = classifyFk(alloc, fk);
    try testing.expectEqual(FkForm.full, result.form);
    try testing.expect(result.text != null);
    try testing.expectEqualStrings("> email auth(email)", result.text.?);
}
