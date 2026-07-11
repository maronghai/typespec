const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const ModifierType = ast_mod.ModifierType;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;
const FkDecl = ast_mod.FkDecl;

// ─── Diff Data Structures ──────────────────────────────────

pub const TableAction = enum { create, alter };

pub const FieldAction = enum { add, modify, drop, rename };

pub const IndexAction = enum { add, drop, modify };

pub const FkAction = enum { add, drop };

pub const SchemaDiff = struct {
    table_diffs: []const TableDiff,
    dropped_tables: [][]const u8,
};

pub const TableDiff = struct {
    name: []const u8,
    action: TableAction,
    field_diffs: []const FieldDiff,
    index_diffs: []const IndexDiff,
    fk_diffs: []const FkDiff,
};

pub const FieldDiff = struct {
    name: []const u8,
    action: FieldAction,
    old_field: ?Field,
    new_field: ?Field,
    rename_from: ?[]const u8,
};

pub const IndexDiff = struct {
    name: []const u8,
    action: IndexAction,
    old_idx: ?IndexDecl,
    new_idx: ?IndexDecl,
};

pub const FkDiff = struct {
    action: FkAction,
    old_fk: ?FkDecl,
    new_fk: ?FkDecl,
};

// ─── Diff Engine ───────────────────────────────────────────

pub fn diff(old: sem.ResolvedAst, new: sem.ResolvedAst, alloc: std.mem.Allocator) !SchemaDiff {
    var table_diffs = try std.ArrayList(TableDiff).initCapacity(alloc, 8);
    var dropped_tables = try std.ArrayList([]const u8).initCapacity(alloc, 4);

    // Build name→table maps
    var old_map = std.StringHashMap(usize).init(alloc);
    for (old.tables, 0..) |t, i| try old_map.put(t.name, i);
    var new_map = std.StringHashMap(usize).init(alloc);
    for (new.tables, 0..) |t, i| try new_map.put(t.name, i);

    // Tables in new but not old → create
    for (new.tables) |new_table| {
        if (!old_map.contains(new_table.name)) {
            const field_diffs = try createAllFieldDiffs(alloc, &.{}, new_table.fields);
            const index_diffs = try createAllIndexDiffs(alloc, &.{}, new_table.indexes);
            const fk_diffs = try createAllFkDiffs(alloc, &.{}, new_table.fks);
            try table_diffs.append(alloc, .{
                .name = new_table.name,
                .action = .create,
                .field_diffs = field_diffs,
                .index_diffs = index_diffs,
                .fk_diffs = fk_diffs,
            });
        }
    }

    // Tables in old but not new → dropped
    for (old.tables) |old_table| {
        if (!new_map.contains(old_table.name)) {
            try dropped_tables.append(alloc, old_table.name);
        }
    }

    // Tables in both → compare
    for (old.tables) |old_table| {
        if (new_map.get(old_table.name)) |new_idx| {
            const new_table = new.tables[new_idx];
            const td = try diffTable(alloc, old_table, new_table);
            if (td.field_diffs.len > 0 or td.index_diffs.len > 0 or td.fk_diffs.len > 0) {
                try table_diffs.append(alloc, td);
            }
        }
    }

    return .{
        .table_diffs = try table_diffs.toOwnedSlice(alloc),
        .dropped_tables = try dropped_tables.toOwnedSlice(alloc),
    };
}

fn diffTable(alloc: std.mem.Allocator, old: sem.ResolvedTable, new: sem.ResolvedTable) !TableDiff {
    // Build name→field maps (skip slot markers)
    var old_fmap = std.StringHashMap(usize).init(alloc);
    for (old.fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, "..."))
            try old_fmap.put(f.name, i);
    }
    var new_fmap = std.StringHashMap(usize).init(alloc);
    for (new.fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, "..."))
            try new_fmap.put(f.name, i);
    }

    var field_diffs = try std.ArrayList(FieldDiff).initCapacity(alloc, 8);
    var dropped_field_names = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    var dropped_field_indices = try std.ArrayList(usize).initCapacity(alloc, 4);
    var added_fields = try std.ArrayList(Field).initCapacity(alloc, 4);

    // Fields in both → compare
    for (old.fields) |old_field| {
        if (std.mem.eql(u8, old_field.name, "...")) continue;
        if (new_fmap.get(old_field.name)) |new_idx| {
            const new_field = new.fields[new_idx];
            if (!fieldsEqual(old_field, new_field)) {
                try field_diffs.append(alloc, .{
                    .name = old_field.name,
                    .action = .modify,
                    .old_field = old_field,
                    .new_field = new_field,
                    .rename_from = null,
                });
            }
        } else {
            // Field in old but not new → potential rename
            try dropped_field_names.append(alloc, old_field.name);
            try dropped_field_indices.append(alloc, if (old_fmap.get(old_field.name)) |idx| idx else 0);
        }
    }

    // Fields in new but not old → add or rename target
    for (new.fields) |new_field| {
        if (std.mem.eql(u8, new_field.name, "...")) continue;
        if (!old_fmap.contains(new_field.name)) {
            try added_fields.append(alloc, new_field);
        }
    }

    // Rename detection: try to match dropped ↔ added by (type_info, modifiers, default, check)
    const renames = try detectRenames(alloc, old.fields, new.fields, &dropped_field_names);

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
            try field_diffs.append(alloc, .{
                .name = af.name,
                .action = .add,
                .old_field = null,
                .new_field = af,
                .rename_from = null,
            });
        }
    }

    // Emit drop for unmatched dropped fields + rename entries
    for (renames) |r| {
        try field_diffs.append(alloc, .{
            .name = r.new_name,
            .action = .rename,
            .old_field = r.old_field,
            .new_field = r.new_field,
            .rename_from = r.old_name,
        });
    }

    for (dropped_field_names.items) |dfn| {
        var was_renamed = false;
        for (renames) |r| {
            if (std.mem.eql(u8, r.old_name, dfn)) {
                was_renamed = true;
                break;
            }
        }
        if (!was_renamed) {
            // Find the old field
            const old_field = if (old_fmap.get(dfn)) |idx| old.fields[idx] else null;
            try field_diffs.append(alloc, .{
                .name = dfn,
                .action = .drop,
                .old_field = old_field,
                .new_field = null,
                .rename_from = null,
            });
        }
    }

    // Index comparison
    const index_diffs = try diffIndexes(alloc, old.indexes, new.indexes);

    // FK comparison
    const fk_diffs = try diffFks(alloc, old.fks, new.fks);

    return .{
        .name = old.name,
        .action = .alter,
        .field_diffs = try field_diffs.toOwnedSlice(alloc),
        .index_diffs = index_diffs,
        .fk_diffs = fk_diffs,
    };
}

// ─── Rename Detection ──────────────────────────────────────

const RenamePair = struct {
    old_name: []const u8,
    new_name: []const u8,
    old_field: ?Field,
    new_field: ?Field,
};

fn detectRenames(
    alloc: std.mem.Allocator,
    old_fields: []const Field,
    new_fields: []const Field,
    dropped_names: *const std.ArrayList([]const u8),
) ![]const RenamePair {
    var renames = try std.ArrayList(RenamePair).initCapacity(alloc, 4);

    // Build field maps
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

    // For each dropped field, find candidate added fields with same signature
    for (dropped_names.items) |old_name| {
        const old_idx = old_fmap.get(old_name) orelse continue;
        const old_f = old_fields[old_idx];

        // Find matching added field
        var match_name: ?[]const u8 = null;
        var match_count: usize = 0;

        for (new_fields) |new_f| {
            if (std.mem.eql(u8, new_f.name, "...")) continue;
            if (new_fmap.contains(new_f.name) and old_fmap.contains(new_f.name)) continue; // not an added field
            if (!new_fmap.contains(new_f.name)) continue; // skip fields in old (shouldn't happen in this loop)

            if (fieldSignatureMatch(old_f, new_f)) {
                match_name = new_f.name;
                match_count += 1;
            }
        }

        // Only emit rename if exactly 1 match (unambiguous)
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

fn fieldSignatureMatch(a: Field, b: Field) bool {
    // Same type
    if (!typeInfoEqual(a.type_info, b.type_info)) return false;
    // Same modifiers (ignoring line_no)
    if (a.modifiers.len != b.modifiers.len) return false;
    for (a.modifiers, 0..) |am, i| {
        if (am.kind != b.modifiers[i].kind) return false;
    }
    // Same default
    if (!defaultValEqual(a.default_val, b.default_val)) return false;
    // Same check
    if (!checkEqual(a.check, b.check)) return false;
    return true;
}

// ─── Equality Helpers ──────────────────────────────────────

pub fn fieldsEqual(a: Field, b: Field) bool {
    if (!typeInfoEqual(a.type_info, b.type_info)) return false;
    if (a.modifiers.len != b.modifiers.len) return false;
    for (a.modifiers, 0..) |am, i| {
        if (am.kind != b.modifiers[i].kind) return false;
    }
    if (!defaultValEqual(a.default_val, b.default_val)) return false;
    if (!checkEqual(a.check, b.check)) return false;
    // Comments are not compared (they don't affect DDL semantics)
    return true;
}

pub fn typeInfoEqual(a: TypeInfo, b: TypeInfo) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .simple => |s| std.mem.eql(u8, s, b.simple),
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

pub fn indexesEqual(a: IndexDecl, b: IndexDecl) bool {
    if (a.kind != b.kind) return false;
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f, b.fields[i])) return false;
    }
    return true;
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

// ─── Index Diff ────────────────────────────────────────────

fn diffIndexes(alloc: std.mem.Allocator, old_idxs: []const IndexDecl, new_idxs: []const IndexDecl) ![]const IndexDiff {
    var diffs = try std.ArrayList(IndexDiff).initCapacity(alloc, 4);

    // Build name→index maps (for named indexes) and a list for unnamed
    var old_by_name = std.StringHashMap(usize).init(alloc);
    for (old_idxs, 0..) |idx, i| try old_by_name.put(idx.name, i);
    var new_by_name = std.StringHashMap(usize).init(alloc);
    for (new_idxs, 0..) |idx, i| try new_by_name.put(idx.name, i);

    // Indexes in both → compare
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

    // Indexes in new but not old → add
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

// ─── FK Diff ───────────────────────────────────────────────

fn diffFks(alloc: std.mem.Allocator, old_fks: []const FkDecl, new_fks: []const FkDecl) ![]const FkDiff {
    var diffs = try std.ArrayList(FkDiff).initCapacity(alloc, 4);

    // Match FKs by (local_fields, ref_table) identity
    var old_matched = try std.ArrayList(bool).initCapacity(alloc, old_fks.len);
    for (old_fks) |_| try old_matched.append(alloc, false);
    var new_matched = try std.ArrayList(bool).initCapacity(alloc, new_fks.len);
    for (new_fks) |_| try new_matched.append(alloc, false);

    // Find matching FKs
    for (old_fks, 0..) |old_fk, oi| {
        for (new_fks, 0..) |new_fk, ni| {
            if (!new_matched.items[ni] and fksEqual(old_fk, new_fk)) {
                old_matched.items[oi] = true;
                new_matched.items[ni] = true;
                break;
            }
        }
    }

    // Unmatched old FKs → drop
    for (old_fks, 0..) |old_fk, oi| {
        if (!old_matched.items[oi]) {
            try diffs.append(alloc, .{
                .action = .drop,
                .old_fk = old_fk,
                .new_fk = null,
            });
        }
    }

    // Unmatched new FKs → add
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

// ─── Helpers for Create (new tables) ───────────────────────

fn createAllFieldDiffs(alloc: std.mem.Allocator, old_fields: []const Field, new_fields: []const Field) ![]const FieldDiff {
    _ = old_fields;
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

fn createAllIndexDiffs(alloc: std.mem.Allocator, old_idxs: []const IndexDecl, new_idxs: []const IndexDecl) ![]const IndexDiff {
    _ = old_idxs;
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

fn createAllFkDiffs(alloc: std.mem.Allocator, old_fks: []const FkDecl, new_fks: []const FkDecl) ![]const FkDiff {
    _ = old_fks;
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

// ─── Diff Printer (for `typespec diff` command) ────────────

pub fn printDiff(d: SchemaDiff) void {
    var has_changes = false;

    for (d.dropped_tables) |tname| {
        std.debug.print("-- DROP TABLE `{s}`\n", .{tname});
        has_changes = true;
    }

    for (d.table_diffs) |td| {
        if (td.action == .create) {
            std.debug.print("-- CREATE TABLE `{s}`\n", .{td.name});
            has_changes = true;
            for (td.field_diffs) |fd| {
                std.debug.print("  + {s}\n", .{fd.name});
            }
            for (td.index_diffs) |idx| {
                std.debug.print("  + @{s}\n", .{idx.name});
            }
            for (td.fk_diffs) |fk| {
                if (fk.new_fk) |nfk| {
                    std.debug.print("  + FK → {s}\n", .{nfk.ref_table});
                }
            }
            continue;
        }

        // alter
        var table_has_changes = false;
        for (td.field_diffs) |fd| {
            if (!table_has_changes) {
                std.debug.print("-- ALTER TABLE `{s}`\n", .{td.name});
                table_has_changes = true;
            }
            switch (fd.action) {
                .add => std.debug.print("  + {s} (add)\n", .{fd.name}),
                .drop => std.debug.print("  - {s} (drop)\n", .{fd.name}),
                .modify => std.debug.print("  ~ {s} (modify)\n", .{fd.name}),
                .rename => std.debug.print("  ~ {s} → {s} (rename)\n", .{ fd.rename_from.?, fd.name }),
            }
        }
        for (td.index_diffs) |idx| {
            if (!table_has_changes) {
                std.debug.print("-- ALTER TABLE `{s}`\n", .{td.name});
                table_has_changes = true;
            }
            switch (idx.action) {
                .add => std.debug.print("  + @{s} (add index)\n", .{idx.name}),
                .drop => std.debug.print("  - @{s} (drop index)\n", .{idx.name}),
                .modify => std.debug.print("  ~ @{s} (modify index)\n", .{idx.name}),
            }
        }
        for (td.fk_diffs) |fk| {
            if (!table_has_changes) {
                std.debug.print("-- ALTER TABLE `{s}`\n", .{td.name});
                table_has_changes = true;
            }
            switch (fk.action) {
                .add => {
                    if (fk.new_fk) |nfk| {
                        std.debug.print("  + FK → {s} (add)\n", .{nfk.ref_table});
                    }
                },
                .drop => {
                    if (fk.old_fk) |ofk| {
                        std.debug.print("  - FK → {s} (drop)\n", .{ofk.ref_table});
                    }
                },
            }
        }
        if (table_has_changes) has_changes = true;
    }

    if (!has_changes) {
        std.debug.print("No differences found.\n", .{});
    }
}

// ─── Unit Tests ─────────────────────────────────────────────

const testing = std.testing;

fn makeField(alloc: std.mem.Allocator, name: []const u8, type_info: TypeInfo) Field {
    return .{
        .name = alloc.dupe(u8, name) catch unreachable,
        .type_info = type_info,
        .modifiers = &.{},
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 1,
    };
}

fn makeResolvedAst(_: std.mem.Allocator, tables: []const sem.ResolvedTable) sem.ResolvedAst {
    return .{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .sql_comments = &.{},
    };
}

test "diff: no changes produces empty diff" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const t = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const old_ast = makeResolvedAst(alloc, t);
    const new_ast = makeResolvedAst(alloc, t);

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 0), result.dropped_tables.len);
}

test "diff: new table detected as create" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const old_ast = makeResolvedAst(alloc, &.{});
    const new_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_ast = makeResolvedAst(alloc, new_table);

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(TableAction.create, result.table_diffs[0].action);
    try testing.expectEqualStrings("user", result.table_diffs[0].name);
}

test "diff: dropped table detected" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const old_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const old_ast = makeResolvedAst(alloc, old_table);
    const new_ast = makeResolvedAst(alloc, &.{});

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.dropped_tables.len);
    try testing.expectEqualStrings("user", result.dropped_tables[0]);
}

test "diff: added field detected" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = makeField(alloc, "name", .{ .varchar_explicit = 32 });

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user", .comment = null, .engine = null,
        .fields = old_fields, .fks = &.{}, .indexes = &.{}, .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user", .comment = null, .engine = null,
        .fields = new_fields, .fks = &.{}, .indexes = &.{}, .line_no = 1,
    }}));

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(TableAction.alter, result.table_diffs[0].action);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expectEqual(FieldAction.add, result.table_diffs[0].field_diffs[0].action);
    try testing.expectEqualStrings("name", result.table_diffs[0].field_diffs[0].name);
}

test "diff: renamed field detected by signature match" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 2);
    old_fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    old_fields[1] = makeField(alloc, "name", .{ .varchar_explicit = 32 });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = makeField(alloc, "full_name", .{ .varchar_explicit = 32 });

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user", .comment = null, .engine = null,
        .fields = old_fields, .fks = &.{}, .indexes = &.{}, .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user", .comment = null, .engine = null,
        .fields = new_fields, .fks = &.{}, .indexes = &.{}, .line_no = 1,
    }}));

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expectEqual(FieldAction.rename, result.table_diffs[0].field_diffs[0].action);
    try testing.expectEqualStrings("full_name", result.table_diffs[0].field_diffs[0].name);
    try testing.expect(result.table_diffs[0].field_diffs[0].rename_from != null);
    try testing.expectEqualStrings("name", result.table_diffs[0].field_diffs[0].rename_from.?);
}
