const std = @import("std");
const ast_mod = @import("ast.zig");

/// Shared test helper: create a minimal Field with default values.
pub fn makeTestField(name: []const u8, type_info: ast_mod.TypeInfo) ast_mod.Field {
    return .{
        .name = name,
        .type_info = type_info,
        .modifiers = &.{},
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 1,
    };
}

/// Shared test helper: create a minimal Ast with no schema or comments.
pub fn makeTestAst(_: std.mem.Allocator, tables: []const ast_mod.Table, templates: []const ast_mod.Template) ast_mod.Ast {
    return .{
        .schema = null,
        .templates = templates,
        .tables = tables,
        .sql_comments = &.{},
    };
}
