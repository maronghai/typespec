const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const diff_fields = @import("diff_fields.zig");
const diff_indexes = @import("diff_indexes.zig");
const diff_fks = @import("diff_fks.zig");
const dialect_enum = @import("dialect_enum.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const IndexDecl = ast_mod.IndexDecl;
const FkDecl = ast_mod.FkDecl;
const Dialect = dialect_enum.Dialect;

// ─── Re-export sub-module types ────────────────────────────

pub const FieldDiff = diff_fields.FieldDiff;
pub const FieldAction = diff_fields.FieldAction;
pub const IndexDiff = diff_indexes.IndexDiff;
pub const IndexAction = diff_indexes.IndexAction;
pub const FkDiff = diff_fks.FkDiff;
pub const FkAction = diff_fks.FkAction;

// ─── Diff Data Structures ──────────────────────────────────

pub const TableAction = enum { create, alter };

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

// ─── Re-export equality helpers ────────────────────────────

pub const fieldsEqual = diff_fields.fieldsEqual;
pub const typeInfoEqual = diff_fields.typeInfoEqual;
pub const defaultValEqual = diff_fields.defaultValEqual;
pub const checkEqual = diff_fields.checkEqual;
pub const indexesEqual = diff_indexes.indexesEqual;
pub const fksEqual = diff_fks.fksEqual;

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
            const field_diffs = try diff_fields.createAllFieldDiffs(alloc, new_table.fields);
            const index_diffs = try diff_indexes.createAllIndexDiffs(alloc, new_table.indexes);
            const fk_diffs = try diff_fks.createAllFkDiffs(alloc, new_table.fks);
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
    const field_diffs = try diff_fields.diffFields(alloc, old.fields, new.fields);
    const index_diffs = try diff_indexes.diffIndexes(alloc, old.indexes, new.indexes);
    const fk_diffs = try diff_fks.diffFks(alloc, old.fks, new.fks);

    return .{
        .name = old.name,
        .action = .alter,
        .field_diffs = field_diffs,
        .index_diffs = index_diffs,
        .fk_diffs = fk_diffs,
    };
}

// ─── Diff Printer (for `typespec diff` command) ────────────

/// Return the identifier quote character for the given dialect.
fn quoteChar(dialect: Dialect) u8 {
    return switch (dialect) {
        .mysql => '`',
        .pg, .sqlite => '"',
    };
}

pub fn formatDiff(alloc: std.mem.Allocator, d: SchemaDiff, dialect: Dialect) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const q = quoteChar(dialect);

    var has_changes = false;

    for (d.dropped_tables) |tname| {
        try w.print("-- DROP TABLE {c}{s}{c}\n", .{ q, tname, q });
        has_changes = true;
    }

    for (d.table_diffs) |td| {
        if (td.action == .create) {
            try w.print("-- CREATE TABLE {c}{s}{c}\n", .{ q, td.name, q });
            has_changes = true;
            for (td.field_diffs) |fd| {
                try w.print("  + {s}\n", .{fd.name});
            }
            for (td.index_diffs) |idx| {
                try w.print("  + @{s}\n", .{idx.name});
            }
            for (td.fk_diffs) |fk| {
                if (fk.new_fk) |nfk| {
                    try w.print("  + FK → {s}\n", .{nfk.ref_table});
                }
            }
            continue;
        }

        // alter
        var table_has_changes = false;
        for (td.field_diffs) |fd| {
            if (!table_has_changes) {
                try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                table_has_changes = true;
            }
            switch (fd.action) {
                .add => try w.print("  + {s} (add)\n", .{fd.name}),
                .drop => try w.print("  - {s} (drop)\n", .{fd.name}),
                .modify => try w.print("  ~ {s} (modify)\n", .{fd.name}),
                .rename => try w.print("  ~ {s} → {s} (rename)\n", .{ fd.rename_from.?, fd.name }),
            }
        }
        for (td.index_diffs) |idx| {
            if (!table_has_changes) {
                try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                table_has_changes = true;
            }
            switch (idx.action) {
                .add => try w.print("  + @{s} (add index)\n", .{idx.name}),
                .drop => try w.print("  - @{s} (drop index)\n", .{idx.name}),
                .modify => try w.print("  ~ @{s} (modify index)\n", .{idx.name}),
            }
        }
        for (td.fk_diffs) |fk| {
            if (!table_has_changes) {
                try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                table_has_changes = true;
            }
            switch (fk.action) {
                .add => {
                    if (fk.new_fk) |nfk| {
                        try w.print("  + FK → {s} (add)\n", .{nfk.ref_table});
                    }
                },
                .drop => {
                    if (fk.old_fk) |ofk| {
                        try w.print("  - FK → {s} (drop)\n", .{ofk.ref_table});
                    }
                },
            }
        }
        if (table_has_changes) has_changes = true;
    }

    if (!has_changes) {
        // Empty output for no differences
    }

    try w.flush();
    var out = aw.toArrayList();
    return try out.toOwnedSlice(alloc);
}

pub fn printDiff(d: SchemaDiff, dialect: Dialect) void {
    var has_changes = false;
    const q = quoteChar(dialect);

    for (d.dropped_tables) |tname| {
        std.debug.print("-- DROP TABLE {c}{s}{c}\n", .{ q, tname, q });
        has_changes = true;
    }

    for (d.table_diffs) |td| {
        if (td.action == .create) {
            std.debug.print("-- CREATE TABLE {c}{s}{c}\n", .{ q, td.name, q });
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

        var table_has_changes = false;
        for (td.field_diffs) |fd| {
            if (!table_has_changes) {
                std.debug.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
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
                std.debug.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
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
                std.debug.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
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
        .custom_types = &.{},
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
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = new_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
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
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = new_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expectEqual(FieldAction.rename, result.table_diffs[0].field_diffs[0].action);
    try testing.expectEqualStrings("full_name", result.table_diffs[0].field_diffs[0].name);
    try testing.expect(result.table_diffs[0].field_diffs[0].rename_from != null);
    try testing.expectEqualStrings("name", result.table_diffs[0].field_diffs[0].rename_from.?);
}

test "diff: two empty schemas produce no diff" {
    const alloc = testing.allocator;
    const old = makeResolvedAst(alloc, &.{});
    const new = makeResolvedAst(alloc, &.{});

    const result = try diff(old, new, alloc);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 0), result.dropped_tables.len);
}

test "diff: table created and dropped simultaneously" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 1);
    new_fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "users",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "accounts",
        .comment = null,
        .engine = null,
        .fields = new_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.dropped_tables.len);
    try testing.expectEqualStrings("users", result.dropped_tables[0]);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(TableAction.create, result.table_diffs[0].action);
    try testing.expectEqualStrings("accounts", result.table_diffs[0].name);
}

test "diff: field type change detected" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = makeField(alloc, "count", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 1);
    new_fields[0] = makeField(alloc, "count", .{ .simple = "N" });

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "stats",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "stats",
        .comment = null,
        .engine = null,
        .fields = new_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expectEqual(FieldAction.modify, result.table_diffs[0].field_diffs[0].action);
}

test "diff: index added and dropped" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 2);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    fields[1] = makeField(alloc, "email", .{ .simple = "s" });

    const old_idx = try alloc.alloc(IndexDecl, 1);
    old_idx[0] = .{ .kind = .unique, .name = "uk_email", .fields = &.{"email"}, .descending = &.{false}, .line_no = 1 };

    const new_idx = try alloc.alloc(IndexDecl, 1);
    new_idx[0] = .{ .kind = .regular, .name = "idx_email", .fields = &.{"email"}, .descending = &.{false}, .line_no = 1 };

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = old_idx,
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = new_idx,
        .line_no = 1,
    }}));

    const result = try diff(old_ast, new_ast, alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].index_diffs.len);
    try testing.expectEqual(IndexAction.modify, result.table_diffs[0].index_diffs[0].action);
}

test "diff: no changes on identical tables" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 2);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    fields[1] = makeField(alloc, "name", .{ .simple = "s" });

    const t1 = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const t2 = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, t1), makeResolvedAst(alloc, t2), alloc);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 0), result.dropped_tables.len);
}

test "diff: field added and dropped simultaneously" {
    const alloc = testing.allocator;

    const old_fields = try alloc.alloc(Field, 2);
    old_fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    old_fields[1] = makeField(alloc, "old_col", .{ .simple = "s" });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = makeField(alloc, "new_col", .{ .simple = "n" });

    const old_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = new_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 2), result.table_diffs[0].field_diffs.len);
}

test "diff: FK change detected" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const fk1 = try alloc.dupe(ast_mod.FkDecl, &.{.{
        .fields = &.{"user_id"},
        .ref_table = "users",
        .ref_fields = &.{"id"},
        .actions = &.{.{ .trigger = .on_delete, .action = .cascade }},
        .line_no = 1,
    }});
    const fk2 = try alloc.dupe(ast_mod.FkDecl, &.{.{
        .fields = &.{"user_id"},
        .ref_table = "users",
        .ref_fields = &.{"id"},
        .actions = &.{.{ .trigger = .on_delete, .action = .set_null }},
        .line_no = 1,
    }});

    const old_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "order",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = fk1,
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "order",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = fk2,
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].fk_diffs.len);
}

test "diff: table comment change detected" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const old_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "t",
        .comment = "old comment",
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(sem.ResolvedTable, &.{.{
        .name = "t",
        .comment = "new comment",
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
}
