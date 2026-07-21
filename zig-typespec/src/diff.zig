const std = @import("std");
const ast_mod = @import("ast.zig");
const diff_fields = @import("diff_fields.zig");
const diff_indexes = @import("diff_indexes.zig");
const diff_fks = @import("diff_fks.zig");
const diff_format = @import("diff_format.zig");
const dialect_enum = @import("dialect_enum.zig");
const utils = @import("utils.zig");
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

pub const TableMetadataDiff = struct {
    old_comment: ?[]const u8,
    new_comment: ?[]const u8,
    old_engine: ?[]const u8,
    new_engine: ?[]const u8,
    pub fn hasChanges(self: TableMetadataDiff) bool {
        return !optionalStrEq(self.old_comment, self.new_comment) or
            !optionalStrEq(self.old_engine, self.new_engine);
    }
};

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
    metadata_diff: ?TableMetadataDiff = null,
};

// ─── Re-export equality helpers ────────────────────────────

pub const fieldsEqual = diff_fields.fieldsEqual;
pub const typeInfoEqual = diff_fields.typeInfoEqual;
pub const defaultValEqual = diff_fields.defaultValEqual;
pub const checkEqual = diff_fields.checkEqual;
pub const indexesEqual = diff_indexes.indexesEqual;
pub const fksEqual = diff_fks.fksEqual;
pub const semanticEquiv = @import("reverse_map.zig").semanticEquiv;

// ─── Helpers ───────────────────────────────────────────────

const optionalStrEq = utils.optionalStrEq;

// ─── Diff Engine ───────────────────────────────────────────

pub fn diff(old: ast_mod.ResolvedAst, new: ast_mod.ResolvedAst, alloc: std.mem.Allocator) !SchemaDiff {
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
            if (td.field_diffs.len > 0 or td.index_diffs.len > 0 or td.fk_diffs.len > 0 or td.metadata_diff != null) {
                try table_diffs.append(alloc, td);
            }
        }
    }

    return .{
        .table_diffs = try table_diffs.toOwnedSlice(alloc),
        .dropped_tables = try dropped_tables.toOwnedSlice(alloc),
    };
}

fn diffTable(alloc: std.mem.Allocator, old: ast_mod.ResolvedTable, new: ast_mod.ResolvedTable) !TableDiff {
    const field_diffs = try diff_fields.diffFields(alloc, old.fields, new.fields);
    const index_diffs = try diff_indexes.diffIndexes(alloc, old.indexes, new.indexes);
    const fk_diffs = try diff_fks.diffFks(alloc, old.fks, new.fks);

    // Compare metadata (comment, engine)
    const metadata_diff = TableMetadataDiff{
        .old_comment = old.comment,
        .new_comment = new.comment,
        .old_engine = old.engine,
        .new_engine = new.engine,
    };

    return .{
        .name = old.name,
        .action = .alter,
        .field_diffs = field_diffs,
        .index_diffs = index_diffs,
        .fk_diffs = fk_diffs,
        .metadata_diff = if (metadata_diff.hasChanges()) metadata_diff else null,
    };
}

// ─── Re-export formatting (moved to diff_format.zig) ─────────

pub const formatDiff = diff_format.formatDiff;
pub const printDiff = diff_format.printDiff;

test "diff: table engine change detected" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = null,
        .engine = "InnoDB",
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = null,
        .engine = "MyISAM",
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expect(result.table_diffs[0].metadata_diff != null);
    try testing.expectEqualStrings("InnoDB", result.table_diffs[0].metadata_diff.?.old_engine.?);
    try testing.expectEqualStrings("MyISAM", result.table_diffs[0].metadata_diff.?.new_engine.?);
}

test "diff: no metadata change produces null metadata_diff" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = "same",
        .engine = "InnoDB",
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = "same",
        .engine = "InnoDB",
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc);
    // No changes at all → table shouldn't be in diffs
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
}

test "diff: combined field and metadata change" {
    const alloc = testing.allocator;

    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = makeField(alloc, "id", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = makeField(alloc, "name", .{ .simple = "s" });

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = "old",
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = "new",
        .engine = null,
        .fields = new_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    // Both field and metadata changes
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expect(result.table_diffs[0].metadata_diff != null);
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

fn makeResolvedAst(_: std.mem.Allocator, tables: []const ast_mod.ResolvedTable) ast_mod.ResolvedAst {
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

    const t = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "users",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "stats",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = old_idx,
        .line_no = 1,
    }}));
    const new_ast = makeResolvedAst(alloc, try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const t1 = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "user",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const t2 = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = old_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "order",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = fk1,
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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

    const old_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
        .name = "t",
        .comment = "old comment",
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }});
    const new_table = try alloc.dupe(ast_mod.ResolvedTable, &.{.{
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
    // Comment change is now detected as metadata diff, not field diff
    try testing.expect(result.table_diffs[0].metadata_diff != null);
    try testing.expectEqualStrings("old comment", result.table_diffs[0].metadata_diff.?.old_comment.?);
    try testing.expectEqualStrings("new comment", result.table_diffs[0].metadata_diff.?.new_comment.?);
}
