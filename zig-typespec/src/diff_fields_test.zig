const std = @import("std");
const diff_fields_mod = @import("diff_fields.zig");
const ast_mod = @import("ast.zig");
const diffFields = diff_fields_mod.diffFields;
const typeInfoEqual = diff_fields_mod.typeInfoEqual;
const defaultValEqual = diff_fields_mod.defaultValEqual;
const FieldAction = diff_fields_mod.FieldAction;
const TypeInfo = ast_mod.TypeInfo;
const Field = ast_mod.Field;
const Modifier = ast_mod.Modifier;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;

fn makeField(name: []const u8, ti: TypeInfo) Field {
    return .{
        .name = name,
        .type_info = ti,
        .modifiers = &.{},
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 0,
    };
}

fn makeFieldFull(name: []const u8, ti: TypeInfo, mods: []const Modifier, dv: ?DefaultVal, ck: ?CheckConstraint) Field {
    return .{
        .name = name,
        .type_info = ti,
        .modifiers = mods,
        .default_val = dv,
        .check = ck,
        .fk = null,
        .comment = null,
        .line_no = 0,
    };
}

test "diffFields identical — no diffs" {
    const alloc = std.testing.allocator;
    const old = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("name", .{ .simple = "s" }) };
    const new_ = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("name", .{ .simple = "s" }) };
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "diffFields added field" {
    const alloc = std.testing.allocator;
    const old = [_]Field{makeField("id", .{ .simple = "n" })};
    const new_ = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("email", .{ .simple = "s" }) };
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(FieldAction.add, diffs[0].action);
    try std.testing.expectEqualStrings("email", diffs[0].name);
}

test "diffFields dropped field" {
    const alloc = std.testing.allocator;
    const old = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("name", .{ .simple = "s" }) };
    const new_ = [_]Field{makeField("id", .{ .simple = "n" })};
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(FieldAction.drop, diffs[0].action);
    try std.testing.expectEqualStrings("name", diffs[0].name);
}

test "diffFields modified field" {
    const alloc = std.testing.allocator;
    const old = [_]Field{makeField("id", .{ .simple = "n" })};
    const new_ = [_]Field{makeField("id", .{ .simple = "N" })};
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(FieldAction.modify, diffs[0].action);
}

test "diffFields rename detection" {
    const alloc = std.testing.allocator;
    const old = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("old_name", .{ .simple = "s" }) };
    const new_ = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("new_name", .{ .simple = "s" }) };
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expectEqual(FieldAction.rename, diffs[0].action);
    try std.testing.expectEqualStrings("new_name", diffs[0].name);
    try std.testing.expectEqualStrings("old_name", diffs[0].rename_from.?);
}

test "diffFields rename not detected when type changes" {
    const alloc = std.testing.allocator;
    const old = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("a", .{ .simple = "n" }) };
    const new_ = [_]Field{ makeField("id", .{ .simple = "n" }), makeField("b", .{ .simple = "s" }) };
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    var has_drop = false;
    var has_add = false;
    for (diffs) |d| {
        if (d.action == .drop and std.mem.eql(u8, d.name, "a")) has_drop = true;
        if (d.action == .add and std.mem.eql(u8, d.name, "b")) has_add = true;
    }
    try std.testing.expect(has_drop);
    try std.testing.expect(has_add);
}

test "diffFields slot markers ignored" {
    const alloc = std.testing.allocator;
    const old = [_]Field{ makeField("...", .none), makeField("id", .{ .simple = "n" }) };
    const new_ = [_]Field{ makeField("...", .none), makeField("id", .{ .simple = "n" }) };
    const diffs = try diffFields(alloc, &old, &new_, null);
    defer alloc.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "typeInfoEqual covers all variants" {
    try std.testing.expect(typeInfoEqual(.none, .none));
    try std.testing.expect(typeInfoEqual(.{ .simple = "n" }, .{ .simple = "n" }));
    try std.testing.expect(!typeInfoEqual(.{ .simple = "n" }, .{ .simple = "s" }));
    try std.testing.expect(typeInfoEqual(.{ .int_explicit = 11 }, .{ .int_explicit = 11 }));
    try std.testing.expect(!typeInfoEqual(.{ .int_explicit = 11 }, .{ .int_explicit = 16 }));
    try std.testing.expect(typeInfoEqual(.{ .varchar_explicit = 255 }, .{ .varchar_explicit = 255 }));
    try std.testing.expect(!typeInfoEqual(.{ .varchar_explicit = 255 }, .none));
    try std.testing.expect(typeInfoEqual(.{ .decimal_explicit = .{ .precision = 10, .scale = 2 } }, .{ .decimal_explicit = .{ .precision = 10, .scale = 2 } }));
    try std.testing.expect(!typeInfoEqual(.{ .decimal_explicit = .{ .precision = 10, .scale = 2 } }, .{ .decimal_explicit = .{ .precision = 16, .scale = 4 } }));
}

test "defaultValEqual" {
    try std.testing.expect(defaultValEqual(null, null));
    try std.testing.expect(!defaultValEqual(null, .{ .value = "0", .line_no = 1 }));
    try std.testing.expect(!defaultValEqual(.{ .value = "0", .line_no = 1 }, null));
    try std.testing.expect(defaultValEqual(.{ .value = "0", .line_no = 1 }, .{ .value = "0", .line_no = 2 }));
    try std.testing.expect(!defaultValEqual(.{ .value = "0", .line_no = 1 }, .{ .value = "1", .line_no = 1 }));
}
