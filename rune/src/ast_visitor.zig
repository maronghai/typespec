const std = @import("std");
const ast_mod = @import("types/ast.zig");
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

        /// Walk resolved tables with mutable field access — for semantic passes that
        /// modify fields (autofk, suffix_inference, etc.). Only visitField receives
        /// a mutable pointer; other callbacks remain read-only.
        pub fn walkResolvedTablesMut(self: Self, tables: []ResolvedTable) void {
            for (tables) |*table| {
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

