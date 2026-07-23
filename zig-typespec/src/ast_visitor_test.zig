const std = @import("std");
const visitor_mod = @import("ast_visitor.zig");
const ast_mod = @import("ast.zig");
const AstVisitor = visitor_mod.AstVisitor;
const VisitCounts = visitor_mod.VisitCounts;
const Ast = ast_mod.Ast;
const Schema = ast_mod.Schema;
const Template = ast_mod.Template;
const Table = ast_mod.Table;
const Field = ast_mod.Field;
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const ResolvedTable = ast_mod.ResolvedTable;
const SqlComment = ast_mod.SqlComment;

const testing = std.testing;
const makeTestField = @import("test_helpers.zig").makeTestField;

fn countVisitSchema(_: *VisitCounts, _: Schema) void {}
fn countVisitTemplate(_: *VisitCounts, _: Template) void {}
fn countVisitTable(ctx: *VisitCounts, _: Table) void {
    ctx.tables += 1;
}
fn countVisitField(ctx: *VisitCounts, _: Field) void {
    ctx.fields += 1;
}
fn countVisitFk(ctx: *VisitCounts, _: FkDecl) void {
    ctx.fks += 1;
}
fn countVisitIndex(ctx: *VisitCounts, _: IndexDecl) void {
    ctx.indexes += 1;
}
fn countVisitSqlComment(_: *VisitCounts, _: SqlComment) void {}

test "visitor: count all AST nodes" {
    const alloc = testing.allocator;

    const fields = try alloc.alloc(Field, 2);
    fields[0] = makeTestField("id", .{ .simple = "n" });
    fields[1] = makeTestField("name", .{ .simple = "s" });

    const table = Table{
        .name = "users",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const tables = try alloc.dupe(Table, &.{table});

    const tmpl_fields = try alloc.alloc(Field, 1);
    tmpl_fields[0] = makeTestField("created_at", .none);

    const template = Template{
        .name = "base",
        .parents = &.{},
        .fields = tmpl_fields,
        .slot_index = null,
        .line_no = 1,
    };

    const templates = try alloc.dupe(Template, &.{template});

    const schema = Schema{
        .name = "testdb",
        .charset = null,
        .autofk = false,
        .custom_types = &.{},
        .line_no = 1,
    };

    const ast = Ast{
        .schema = schema,
        .templates = templates,
        .tables = tables,
        .views = &.{},
        .sql_comments = &.{},
    };

    var counts = VisitCounts{};
    const visitor = AstVisitor(*VisitCounts){
        .context = &counts,
        .visitSchema = countVisitSchema,
        .visitTemplate = countVisitTemplate,
        .visitTable = countVisitTable,
        .visitField = countVisitField,
        .visitFk = countVisitFk,
        .visitIndex = countVisitIndex,
        .visitSqlComment = countVisitSqlComment,
    };

    visitor.walk(ast);

    try testing.expectEqual(@as(usize, 1), counts.schemas);
    try testing.expectEqual(@as(usize, 1), counts.templates);
    try testing.expectEqual(@as(usize, 1), counts.tables);
    try testing.expectEqual(@as(usize, 3), counts.fields);
    try testing.expectEqual(@as(usize, 0), counts.fks);
    try testing.expectEqual(@as(usize, 0), counts.indexes);
    try testing.expectEqual(@as(usize, 0), counts.sql_comments);
}

test "visitor: empty AST" {
    const ast = Ast{
        .schema = null,
        .templates = &.{},
        .tables = &.{},
        .views = &.{},
        .sql_comments = &.{},
    };

    var counts = VisitCounts{};
    const visitor = AstVisitor(*VisitCounts){
        .context = &counts,
        .visitSchema = countVisitSchema,
        .visitTemplate = countVisitTemplate,
        .visitTable = countVisitTable,
        .visitField = countVisitField,
        .visitFk = countVisitFk,
        .visitIndex = countVisitIndex,
        .visitSqlComment = countVisitSqlComment,
    };

    visitor.walk(ast);

    try testing.expectEqual(@as(usize, 0), counts.schemas);
    try testing.expectEqual(@as(usize, 0), counts.templates);
    try testing.expectEqual(@as(usize, 0), counts.tables);
    try testing.expectEqual(@as(usize, 0), counts.fields);
}

test "visitor: walk FKs and indexes" {
    const alloc = testing.allocator;

    const fk = FkDecl{
        .fields = &.{"user_id"},
        .ref_table = "users",
        .ref_fields = &.{"id"},
        .actions = &.{},
        .line_no = 1,
    };

    const idx = IndexDecl{
        .kind = .unique,
        .name = "uk_email",
        .fields = &.{"email"},
        .descending = &.{false},
        .line_no = 1,
    };

    const table = Table{
        .name = "orders",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = &.{makeTestField("id", .{ .simple = "n" })},
        .fks = try alloc.dupe(FkDecl, &.{fk}),
        .indexes = try alloc.dupe(IndexDecl, &.{idx}),
        .line_no = 1,
    };

    const ast = Ast{
        .schema = null,
        .templates = &.{},
        .tables = try alloc.dupe(Table, &.{table}),
        .views = &.{},
        .sql_comments = &.{},
    };

    var counts = VisitCounts{};
    const visitor = AstVisitor(*VisitCounts){
        .context = &counts,
        .visitTable = countVisitTable,
        .visitField = countVisitField,
        .visitFk = countVisitFk,
        .visitIndex = countVisitIndex,
    };

    visitor.walk(ast);

    try testing.expectEqual(@as(usize, 1), counts.tables);
    try testing.expectEqual(@as(usize, 1), counts.fields);
    try testing.expectEqual(@as(usize, 1), counts.fks);
    try testing.expectEqual(@as(usize, 1), counts.indexes);
}

test "visitor: selective callbacks" {
    const alloc = testing.allocator;

    const ast = Ast{
        .schema = .{
            .name = "test",
            .charset = null,
            .autofk = false,
            .custom_types = &.{},
            .line_no = 1,
        },
        .templates = &.{},
        .tables = try alloc.dupe(Table, &.{.{
            .name = "t",
            .template_ref = null,
            .comment = null,
            .engine = null,
            .fields = &.{makeTestField("id", .{ .simple = "n" })},
            .fks = &.{},
            .indexes = &.{},
            .line_no = 1,
        }}),
        .views = &.{},
        .sql_comments = &.{},
    };

    var table_count: usize = 0;
    const visitor = AstVisitor(*usize){
        .context = &table_count,
        .visitTable = struct {
            fn visit(ctx: *usize, _: Table) void {
                ctx.* += 1;
            }
        }.visit,
    };

    visitor.walk(ast);

    try testing.expectEqual(@as(usize, 1), table_count);
}

test "visitor: walkResolvedTables" {
    const alloc = testing.allocator;

    const table = ResolvedTable{
        .name = "users",
        .comment = null,
        .engine = null,
        .fields = try alloc.dupe(Field, &.{
            makeTestField("id", .{ .simple = "n" }),
            makeTestField("name", .{ .simple = "s" }),
        }),
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    var counts = VisitCounts{};
    const visitor = AstVisitor(*VisitCounts){
        .context = &counts,
        .visitTable = countVisitTable,
        .visitField = countVisitField,
    };

    visitor.walkResolvedTables(try alloc.dupe(ResolvedTable, &.{table}));

    try testing.expectEqual(@as(usize, 1), counts.tables);
    try testing.expectEqual(@as(usize, 2), counts.fields);
}
