const std = @import("std");
const codegen_mod = @import("codegen.zig");
const typed_ast_mod = @import("typed_ast.zig");
const Codegen = codegen_mod.Codegen;

const testing = std.testing;

fn makeTestColumn(name: []const u8, sql_type: typed_ast_mod.SqlType) typed_ast_mod.TypedColumn {
    return .{
        .name = name,
        .sql_type = sql_type,
        .flags = .{},
        .default = null,
        .check = null,
        .comment = null,
        .enum_values = &.{},
        .line_no = 1,
    };
}

test "codegen: simple MySQL table" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 2);
    cols[0] = makeTestColumn("id", "int");
    cols[0].flags.primary_key = true;
    cols[0].flags.auto_increment = true;
    cols[1] = makeTestColumn("name", "varchar(32)");
    cols[1].flags.nullable = false;

    const table = typed_ast_mod.TypedTable{
        .name = "user",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .mysql);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE `user`") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "`id` int") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "AUTO_INCREMENT") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "`name` varchar(32)") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "NOT NULL") != null);
}

test "codegen: PostgreSQL table uses double quotes" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "integer");
    cols[0].flags.primary_key = true;
    cols[0].flags.auto_increment = true;

    const table = typed_ast_mod.TypedTable{
        .name = "user",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .pg);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE \"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "GENERATED ALWAYS AS IDENTITY") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "`") == null);
}

test "codegen: SQLite AUTOINCREMENT in PRIMARY KEY" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "INTEGER");
    cols[0].flags.primary_key = true;
    cols[0].flags.auto_increment = true;

    const table = typed_ast_mod.TypedTable{
        .name = "item",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .sqlite);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY AUTOINCREMENT") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "\"item\"") != null);
}

test "codegen: PG standalone COMMENT ON TABLE" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "integer");
    cols[0].flags.primary_key = true;

    const table = typed_ast_mod.TypedTable{
        .name = "users",
        .comment = "User accounts",
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .pg);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "COMMENT ON TABLE") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "'User accounts'") != null);
}

test "codegen: SQLite COMMENT uses -- style" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "INTEGER");
    cols[0].flags.primary_key = true;

    const table = typed_ast_mod.TypedTable{
        .name = "logs",
        .comment = "Log entries",
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .sqlite);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "-- Log entries") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "COMMENT ON") == null);
}

test "codegen: check expression BETWEEN" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    var cg = Codegen.init(alloc, .mysql);
    try cg.emitCheckExpr(w, "age", .{ .kind = .range, .expr = "0,150", .line_no = 1 });
    try w.flush();

    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);

    try testing.expect(std.mem.indexOf(u8, result, "age BETWEEN 0 AND 150") != null);
}

test "codegen: check expression IN list" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    var cg = Codegen.init(alloc, .mysql);
    try cg.emitCheckExpr(w, "status", .{ .kind = .in_list, .expr = "'active','inactive','banned'", .line_no = 1 });
    try w.flush();

    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);

    try testing.expect(std.mem.indexOf(u8, result, "status IN (") != null);
    try testing.expect(std.mem.indexOf(u8, result, "'active'") != null);
}

test "codegen: PG uses double quotes, no backticks" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 2);
    cols[0] = makeTestColumn("id", "serial");
    cols[0].flags.primary_key = true;
    cols[1] = makeTestColumn("order", "text");

    const table = typed_ast_mod.TypedTable{
        .name = "items",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .pg);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "\"items\"") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "\"order\"") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "`") == null);
}

test "codegen: MySQL ENGINE in table footer" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "int");
    cols[0].flags.primary_key = true;

    const table = typed_ast_mod.TypedTable{
        .name = "t",
        .comment = null,
        .engine = "MyISAM",
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .mysql);
    const sql = try cg.generateFromTypedAst(typed);

    try testing.expect(std.mem.indexOf(u8, sql, "ENGINE=MyISAM") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "DEFAULT CHARSET=utf8mb4") != null);
}

test "codegen: MySQL UNSIGNED column" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("amount", "int");
    cols[0].flags.unsigned = true;

    const table = typed_ast_mod.TypedTable{
        .name = "t",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .mysql);
    const sql = try cg.generateFromTypedAst(typed);
    try testing.expect(std.mem.indexOf(u8, sql, "UNSIGNED") != null);

    var cg_pg = Codegen.init(alloc, .pg);
    const sql_pg = try cg_pg.generateFromTypedAst(typed);
    try testing.expect(std.mem.indexOf(u8, sql_pg, "UNSIGNED") == null);
}

test "codegen: PG COMMENT ON TABLE and COLUMN" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "integer");
    cols[0].comment = "primary identifier";

    const table = typed_ast_mod.TypedTable{
        .name = "items",
        .comment = "all items",
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .pg);
    const sql = try cg.generateFromTypedAst(typed);
    try testing.expect(std.mem.indexOf(u8, sql, "COMMENT ON TABLE") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "COMMENT ON COLUMN") != null);
}

test "codegen: SQLite uses -- comments" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "INTEGER");
    cols[0].flags.primary_key = true;

    const table = typed_ast_mod.TypedTable{
        .name = "t",
        .comment = "test table",
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{table});
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .sqlite);
    const sql = try cg.generateFromTypedAst(typed);
    try testing.expect(std.mem.indexOf(u8, sql, "-- test table") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "ENGINE") == null);
    try testing.expect(std.mem.indexOf(u8, sql, "CHARSET") == null);
}

test "codegen: multiple tables separated by blank line" {
    const alloc = testing.allocator;
    const cols = try alloc.alloc(typed_ast_mod.TypedColumn, 1);
    cols[0] = makeTestColumn("id", "int");
    cols[0].flags.primary_key = true;

    const t1 = typed_ast_mod.TypedTable{
        .name = "a",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };
    const t2 = typed_ast_mod.TypedTable{
        .name = "b",
        .comment = null,
        .engine = null,
        .columns = cols,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 5,
    };

    const tables = try alloc.dupe(typed_ast_mod.TypedTable, &.{ t1, t2 });
    const typed = typed_ast_mod.TypedAst{
        .schema_name = null,
        .schema_charset = null,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var cg = Codegen.init(alloc, .mysql);
    const sql = try cg.generateFromTypedAst(typed);
    try testing.expect(std.mem.indexOf(u8, sql, "`a`") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "`b`") != null);
    const pos_a = std.mem.indexOf(u8, sql, "`a`").?;
    const pos_b = std.mem.indexOf(u8, sql, "`b`").?;
    try testing.expect(pos_b > pos_a);
}
