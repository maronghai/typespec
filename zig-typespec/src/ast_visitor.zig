const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Schema = ast_mod.Schema;
const Template = ast_mod.Template;
const Table = ast_mod.Table;
const Field = ast_mod.Field;
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const SqlComment = ast_mod.SqlComment;
const ResolvedTable = ast_mod.ResolvedTable;

// ─── AST Visitor Pattern ───────────────────────────────────────
// Provides generic traversal for the AST without manual traversal
// code in each pass. Visitors implement specific callbacks.
//
// Note: visitField receives *const Field (read-only). For semantic passes
// that need mutable field access (autofk, suffix_inference), use manual
// iteration over PassContext.tables — the walker pattern is designed for
// read-only analysis passes like validate_type_modifiers.

pub fn AstVisitor(comptime Context: type) type {
    return struct {
        const Self = @This();

        context: Context,

        // Optional callbacks (default no-op)
        visitSchema: ?*const fn (ctx: Context, schema: Schema) void = null,
        visitTemplate: ?*const fn (ctx: Context, template: Template) void = null,
        visitTable: ?*const fn (ctx: Context, table: Table) void = null,
        visitField: ?*const fn (ctx: Context, field: *const Field, table_name: ?[]const u8) void = null,
        visitFk: ?*const fn (ctx: Context, fk: FkDecl, table_name: ?[]const u8) void = null,
        visitIndex: ?*const fn (ctx: Context, index: IndexDecl, table_name: ?[]const u8) void = null,
        visitSqlComment: ?*const fn (ctx: Context, comment: SqlComment) void = null,

        /// Walk the entire AST, calling registered visitors.
        pub fn walk(self: Self, ast: Ast) void {
            // Schema
            if (ast.schema) |schema| {
                if (self.visitSchema) |visit| {
                    visit(self.context, schema);
                }
            }

            // Templates
            for (ast.templates) |template| {
                if (self.visitTemplate) |visit| {
                    visit(self.context, template);
                }
                // Walk template fields
                for (template.fields) |*field| {
                    if (self.visitField) |visit| {
                        visit(self.context, field, template.name);
                    }
                }
            }

            // Tables
            for (ast.tables) |table| {
                if (self.visitTable) |visit| {
                    visit(self.context, table);
                }
                // Walk table fields
                for (table.fields) |*field| {
                    if (self.visitField) |visit| {
                        visit(self.context, field, table.name);
                    }
                    // Walk inline FKs
                    if (field.fk) |fk| {
                        if (self.visitFk) |visit| {
                            visit(self.context, fk, table.name);
                        }
                    }
                }
                // Walk table FKs
                for (table.fks) |fk| {
                    if (self.visitFk) |visit| {
                        visit(self.context, fk, table.name);
                    }
                }
                // Walk table indexes
                for (table.indexes) |index| {
                    if (self.visitIndex) |visit| {
                        visit(self.context, index, table.name);
                    }
                }
            }

            // SQL comments
            for (ast.sql_comments) |comment| {
                if (self.visitSqlComment) |visit| {
                    visit(self.context, comment);
                }
            }
        }

        /// Walk resolved tables (post-template-resolution) — skips schema/templates.
        /// Uses ResolvedTable which has the same field/fk/index structure as Table.
        pub fn walkResolvedTables(self: Self, tables: []const ResolvedTable) void {
            for (tables) |table| {
                if (self.visitTable) |visit| {
                    visit(self.context, .{
                        .name = table.name,
                        .template_ref = null,
                        .comment = table.comment,
                        .engine = table.engine,
                        .fields = table.fields,
                        .fks = table.fks,
                        .indexes = table.indexes,
                        .line_no = table.line_no,
                    });
                }
                for (table.fields) |*field| {
                    if (self.visitField) |visit| {
                        visit(self.context, field, table.name);
                    }
                    if (field.fk) |fk| {
                        if (self.visitFk) |visit| {
                            visit(self.context, fk, table.name);
                        }
                    }
                }
                for (table.fks) |fk| {
                    if (self.visitFk) |visit| {
                        visit(self.context, fk, table.name);
                    }
                }
                for (table.indexes) |index| {
                    if (self.visitIndex) |visit| {
                        visit(self.context, index, table.name);
                    }
                }
            }
        }
    };
}

// ─── Simple Counter Visitor (for testing) ──────────────────────

pub const VisitCounts = struct {
    schemas: usize = 0,
    templates: usize = 0,
    tables: usize = 0,
    fields: usize = 0,
    fks: usize = 0,
    indexes: usize = 0,
    sql_comments: usize = 0,
};

fn countVisitSchema(ctx: *VisitCounts, _: Schema) void {
    ctx.schemas += 1;
}

fn countVisitTemplate(ctx: *VisitCounts, _: Template) void {
    ctx.templates += 1;
}

fn countVisitTable(ctx: *VisitCounts, _: Table) void {
    ctx.tables += 1;
}

fn countVisitField(ctx: *VisitCounts, _: *const Field, _: ?[]const u8) void {
    ctx.fields += 1;
}

fn countVisitFk(ctx: *VisitCounts, _: FkDecl, _: ?[]const u8) void {
    ctx.fks += 1;
}

fn countVisitIndex(ctx: *VisitCounts, _: IndexDecl, _: ?[]const u8) void {
    ctx.indexes += 1;
}

fn countVisitSqlComment(ctx: *VisitCounts, _: SqlComment) void {
    ctx.sql_comments += 1;
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;
const makeTestField = @import("test_helpers.zig").makeTestField;

test "visitor: count all AST nodes" {
    const alloc = testing.allocator;

    // Create a simple AST
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

    // Create visitor
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
    // 2 table fields + 1 template field = 3
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

    // Only count tables, ignore everything else
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
        .fields = &.{
            makeTestField("id", .{ .simple = "n" }),
            makeTestField("name", .{ .simple = "s" }),
        },
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
