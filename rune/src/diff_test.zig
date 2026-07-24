const std = @import("std");
const diff_mod = @import("diff/engine.zig");
const ast_mod = @import("types/ast.zig");
const diff = diff_mod.diff;
const TableAction = diff_mod.TableAction;
const FieldAction = diff_mod.FieldAction;
const IndexAction = diff_mod.IndexAction;
const TypeInfo = ast_mod.TypeInfo;
const Field = ast_mod.Field;
const IndexDecl = ast_mod.IndexDecl;

const testing = std.testing;

fn makeField(alloc: std.mem.Allocator, name: []const u8, type_info: TypeInfo) !Field {
    return .{
        .name = try alloc.dupe(u8, name),
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
        .views = &.{},
        .sql_comments = &.{},
    };
}

test "diff: table engine change detected" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expect(result.table_diffs[0].metadata_diff != null);
    try testing.expectEqualStrings("InnoDB", result.table_diffs[0].metadata_diff.?.old_engine.?);
    try testing.expectEqualStrings("MyISAM", result.table_diffs[0].metadata_diff.?.new_engine.?);
}

test "diff: no metadata change produces null metadata_diff" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc, null);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
}

test "diff: combined field and metadata change" {
    const alloc = testing.allocator;

    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = try makeField(alloc, "name", .{ .simple = "s" });

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

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expect(result.table_diffs[0].metadata_diff != null);
}

test "diff: no changes produces empty diff" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 0), result.dropped_tables.len);
}

test "diff: new table detected as create" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(TableAction.create, result.table_diffs[0].action);
    try testing.expectEqualStrings("user", result.table_diffs[0].name);
}

test "diff: dropped table detected" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.dropped_tables.len);
    try testing.expectEqualStrings("user", result.dropped_tables[0]);
}

test "diff: added field detected" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = try makeField(alloc, "name", .{ .varchar_explicit = 32 });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(TableAction.alter, result.table_diffs[0].action);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expectEqual(FieldAction.add, result.table_diffs[0].field_diffs[0].action);
    try testing.expectEqualStrings("name", result.table_diffs[0].field_diffs[0].name);
}

test "diff: renamed field detected by signature match" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 2);
    old_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    old_fields[1] = try makeField(alloc, "name", .{ .varchar_explicit = 32 });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = try makeField(alloc, "full_name", .{ .varchar_explicit = 32 });

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

    const result = try diff(old_ast, new_ast, alloc, null);
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

    const result = try diff(old, new, alloc, null);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 0), result.dropped_tables.len);
}

test "diff: table created and dropped simultaneously" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 1);
    new_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 1), result.dropped_tables.len);
    try testing.expectEqualStrings("users", result.dropped_tables[0]);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(TableAction.create, result.table_diffs[0].action);
    try testing.expectEqualStrings("accounts", result.table_diffs[0].name);
}

test "diff: field type change detected" {
    const alloc = testing.allocator;
    const old_fields = try alloc.alloc(Field, 1);
    old_fields[0] = try makeField(alloc, "count", .{ .simple = "n" });

    const new_fields = try alloc.alloc(Field, 1);
    new_fields[0] = try makeField(alloc, "count", .{ .simple = "N" });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].field_diffs.len);
    try testing.expectEqual(FieldAction.modify, result.table_diffs[0].field_diffs[0].action);
}

test "diff: index added and dropped" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 2);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    fields[1] = try makeField(alloc, "email", .{ .simple = "s" });

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

    const result = try diff(old_ast, new_ast, alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].index_diffs.len);
    try testing.expectEqual(IndexAction.modify, result.table_diffs[0].index_diffs[0].action);
}

test "diff: no changes on identical tables" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 2);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    fields[1] = try makeField(alloc, "name", .{ .simple = "s" });

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

    const result = try diff(makeResolvedAst(alloc, t1), makeResolvedAst(alloc, t2), alloc, null);
    try testing.expectEqual(@as(usize, 0), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 0), result.dropped_tables.len);
}

test "diff: field added and dropped simultaneously" {
    const alloc = testing.allocator;

    const old_fields = try alloc.alloc(Field, 2);
    old_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    old_fields[1] = try makeField(alloc, "old_col", .{ .simple = "s" });

    const new_fields = try alloc.alloc(Field, 2);
    new_fields[0] = try makeField(alloc, "id", .{ .simple = "n" });
    new_fields[1] = try makeField(alloc, "new_col", .{ .simple = "n" });

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

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 2), result.table_diffs[0].field_diffs.len);
}

test "diff: FK change detected" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expectEqual(@as(usize, 1), result.table_diffs[0].fk_diffs.len);
}

test "diff: table comment change detected" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 1);
    fields[0] = try makeField(alloc, "id", .{ .simple = "n" });

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

    const result = try diff(makeResolvedAst(alloc, old_table), makeResolvedAst(alloc, new_table), alloc, null);
    try testing.expectEqual(@as(usize, 1), result.table_diffs.len);
    try testing.expect(result.table_diffs[0].metadata_diff != null);
    try testing.expectEqualStrings("old comment", result.table_diffs[0].metadata_diff.?.old_comment.?);
    try testing.expectEqualStrings("new comment", result.table_diffs[0].metadata_diff.?.new_comment.?);
}
