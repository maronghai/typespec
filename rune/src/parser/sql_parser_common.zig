const ast_mod = @import("../types/ast.zig");
const dialect_enum = @import("../dialect/enum.zig");
const diag = @import("../semantic/diagnostic.zig");

pub const Dialect = dialect_enum.Dialect;
pub const IndexKind = ast_mod.IndexType;
pub const FkActionType = ast_mod.FkActionType;
pub const FkActionTrigger = ast_mod.FkActionTrigger;
pub const FkAction = ast_mod.FkAction;

// ─── SQL IR Types ────────────────────────────────────────────────

pub const SqlColumn = struct {
    name: []const u8,
    type_sql: []const u8,
    nullable: bool,
    unsigned: bool,
    auto_increment: bool,
    primary_key: bool,
    on_update_current_timestamp: bool,
    default_val: ?[]const u8,
    check_expr: ?[]const u8,
    comment: ?[]const u8,
    sym_override: ?[]const u8 = null,
};

pub const SqlIndex = struct {
    kind: IndexKind,
    name: []const u8,
    fields: []const []const u8,
    descending: []const bool,
};

pub const SqlForeignKey = struct {
    fields: []const []const u8,
    ref_table: []const u8,
    ref_fields: []const []const u8,
    actions: []const FkAction,
};

pub const SqlCheck = struct {
    field_name: []const u8,
    expr: []const u8,
};

pub const SqlTable = struct {
    name: []const u8,
    engine: ?[]const u8,
    charset: ?[]const u8,
    comment: ?[]const u8,
    columns: []SqlColumn,
    indexes: []const SqlIndex,
    foreign_keys: []const SqlForeignKey,
    checks: []const SqlCheck,
};

pub const SqlSchema = struct {
    name: ?[]const u8,
    charset: ?[]const u8,
    tables: []const SqlTable,
};

pub const SqlDiagnostic = struct {
    severity: enum { warning, @"error" },
    line_no: usize,
    col: usize,
    message: []const u8,
    context: ?[]const u8 = null,
};

pub const SqlParseResult = struct {
    schema: SqlSchema,
    diagnostics: []const diag.Diagnostic,
};

pub const CreateDbResult = struct {
    name: ?[]const u8,
    charset: ?[]const u8,
};
