const std = @import("std");
const ast_mod = @import("ast.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;

// ─── Field Diff + Rename Detection ─────────────────────────
// Extracted from diff.zig for single-responsibility.

pub const RenamePair = struct {
    old_name: []const u8,
    new_name: []const u8,
    old_field: ?Field,
    new_field: ?Field,
};

/// Compute field-level diffs between two tables, including rename detection.
pub fn diffFields(
    alloc: std.mem.Allocator,
    old_fields: []const Field,
    new_fields: []const Field,
) ![]const FieldDiff {
    // Build name→field maps (skip slot markers)
    var old_fmap = std.StringHashMap(usize).init(alloc);
    for (old_fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, "..."))
            try old_fmap.put(f.name, i);
    }
    var new_fmap = std.StringHashMap(usize).init(alloc);
    for (new_fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, "..."))
            try new_fmap.put(f.name, i);
    }

    var diffs = try std.ArrayList(FieldDiff).initCapacity(alloc, 8);
    var dropped_names = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    var added_fields = try std.ArrayList(Field).initCapacity(alloc, 4);

    // Fields in both → compare
    for (old_fields) |old_field| {
        if (std.mem.eql(u8, old_field.name, "...")) continue;
        if (new_fmap.get(old_field.name)) |new_idx| {
            const new_field = new_fields[new_idx];
            if (!fieldsEqual(old_field, new_field)) {
                try diffs.append(alloc, .{
                    .name = old_field.name,
                    .action = .modify,
                    .old_field = old_field,
                    .new_field = new_field,
                    .rename_from = null,
                });
            }
        } else {
            try dropped_names.append(alloc, old_field.name);
        }
    }

    // Fields in new but not old → add or rename target
    for (new_fields) |new_field| {
        if (std.mem.eql(u8, new_field.name, "...")) continue;
        if (!old_fmap.contains(new_field.name)) {
            try added_fields.append(alloc, new_field);
        }
    }

    // Rename detection: match dropped ↔ added by (type_info, modifiers, default, check)
    const renames = try detectRenames(old_fields, new_fields, &dropped_names, alloc);

    // Emit add for unmatched added fields
    for (added_fields.items) |af| {
        var was_renamed = false;
        for (renames) |r| {
            if (std.mem.eql(u8, r.new_name, af.name)) {
                was_renamed = true;
                break;
            }
        }
        if (!was_renamed) {
            try diffs.append(alloc, .{
                .name = af.name,
                .action = .add,
                .old_field = null,
                .new_field = af,
                .rename_from = null,
            });
        }
    }

    // Emit rename entries
    for (renames) |r| {
        try diffs.append(alloc, .{
            .name = r.new_name,
            .action = .rename,
            .old_field = r.old_field,
            .new_field = r.new_field,
            .rename_from = r.old_name,
        });
    }

    // Emit drop for unmatched dropped fields
    for (dropped_names.items) |dfn| {
        var was_renamed = false;
        for (renames) |r| {
            if (std.mem.eql(u8, r.old_name, dfn)) {
                was_renamed = true;
                break;
            }
        }
        if (!was_renamed) {
            const old_field = if (old_fmap.get(dfn)) |idx| old_fields[idx] else null;
            try diffs.append(alloc, .{
                .name = dfn,
                .action = .drop,
                .old_field = old_field,
                .new_field = null,
                .rename_from = null,
            });
        }
    }

    return try diffs.toOwnedSlice(alloc);
}

/// Create add-diffs for all fields of a new table.
pub fn createAllFieldDiffs(alloc: std.mem.Allocator, new_fields: []const Field) ![]const FieldDiff {
    var diffs = try std.ArrayList(FieldDiff).initCapacity(alloc, new_fields.len);
    for (new_fields) |f| {
        if (std.mem.eql(u8, f.name, "...")) continue;
        try diffs.append(alloc, .{
            .name = f.name,
            .action = .add,
            .old_field = null,
            .new_field = f,
            .rename_from = null,
        });
    }
    return try diffs.toOwnedSlice(alloc);
}

// ─── Rename Detection ──────────────────────────────────────

fn detectRenames(
    old_fields: []const Field,
    new_fields: []const Field,
    dropped_names: *const std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
) ![]const RenamePair {
    var renames = try std.ArrayList(RenamePair).initCapacity(alloc, 4);

    var old_fmap = std.StringHashMap(usize).init(alloc);
    for (old_fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, "..."))
            try old_fmap.put(f.name, i);
    }
    var new_fmap = std.StringHashMap(usize).init(alloc);
    for (new_fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, "..."))
            try new_fmap.put(f.name, i);
    }

    for (dropped_names.items) |old_name| {
        const old_idx = old_fmap.get(old_name) orelse continue;
        const old_f = old_fields[old_idx];

        var match_name: ?[]const u8 = null;
        var match_count: usize = 0;

        for (new_fields) |new_f| {
            if (std.mem.eql(u8, new_f.name, "...")) continue;
            if (new_fmap.contains(new_f.name) and old_fmap.contains(new_f.name)) continue;
            if (!new_fmap.contains(new_f.name)) continue;

            if (fieldSignatureMatch(old_f, new_f)) {
                match_name = new_f.name;
                match_count += 1;
            }
        }

        if (match_count == 1 and match_name != null) {
            const new_name = match_name.?;
            const new_idx = new_fmap.get(new_name) orelse continue;
            try renames.append(alloc, .{
                .old_name = old_name,
                .new_name = new_name,
                .old_field = old_f,
                .new_field = new_fields[new_idx],
            });
        }
    }

    return try renames.toOwnedSlice(alloc);
}

// ─── Equality Helpers ──────────────────────────────────────

pub fn fieldSignatureMatch(a: Field, b: Field) bool {
    if (!typeInfoEqual(a.type_info, b.type_info)) return false;
    if (a.modifiers.len != b.modifiers.len) return false;
    for (a.modifiers, 0..) |am, i| {
        if (am.kind != b.modifiers[i].kind) return false;
    }
    if (!defaultValEqual(a.default_val, b.default_val)) return false;
    if (!checkEqual(a.check, b.check)) return false;
    return true;
}

pub fn fieldsEqual(a: Field, b: Field) bool {
    if (!typeInfoEqual(a.type_info, b.type_info)) return false;
    if (a.modifiers.len != b.modifiers.len) return false;
    for (a.modifiers, 0..) |am, i| {
        if (am.kind != b.modifiers[i].kind) return false;
    }
    if (!defaultValEqual(a.default_val, b.default_val)) return false;
    if (!checkEqual(a.check, b.check)) return false;
    return true;
}

pub fn typeInfoEqual(a: TypeInfo, b: TypeInfo) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .simple => |s| std.mem.eql(u8, s, b.simple),
        .raw_sql => |s| std.mem.eql(u8, s, b.raw_sql),
        .int_explicit => |n| n == b.int_explicit,
        .decimal_explicit => |ds| ds.precision == b.decimal_explicit.precision and ds.scale == b.decimal_explicit.scale,
        .varchar_explicit => |n| n == b.varchar_explicit,
        .enum_type => |vals| {
            if (vals.len != b.enum_type.len) return false;
            for (vals, 0..) |v, i| {
                if (!std.mem.eql(u8, v, b.enum_type[i])) return false;
            }
            return true;
        },
    };
}

pub fn defaultValEqual(a: ?DefaultVal, b: ?DefaultVal) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?.value, b.?.value);
}

pub fn checkEqual(a: ?CheckConstraint, b: ?CheckConstraint) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.kind == b.?.kind and std.mem.eql(u8, a.?.expr, b.?.expr);
}

// ─── FieldDiff (re-export for convenience) ─────────────────

pub const FieldDiff = struct {
    name: []const u8,
    action: FieldAction,
    old_field: ?Field,
    new_field: ?Field,
    rename_from: ?[]const u8,
};

pub const FieldAction = enum { add, modify, drop, rename };
