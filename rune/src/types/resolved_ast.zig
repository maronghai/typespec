const ast_mod = @import("ast.zig");
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const CustomType = ast_mod.CustomType;
const View = ast_mod.View;
const SqlComment = ast_mod.SqlComment;

// ─── Resolved AST: Semantic analysis output ─────────────────
// These types represent the output of template resolution + semantic passes.
// They live here (not in ast.zig) to separate parser output from semantic output.

pub const ResolvedTable = struct {
    name: []const u8,
    comment: ?[]const u8,
    engine: ?[]const u8,
    fields: []ast_mod.Field,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
};

pub const ResolvedAst = struct {
    schema_name: ?[]const u8,
    schema_charset: ?[]const u8,
    /// Custom type definitions from ~ directives
    custom_types: []const CustomType,
    tables: []const ResolvedTable,
    views: []const View,
    sql_comments: []const SqlComment,
};
