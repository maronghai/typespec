const std = @import("std");
const ast_mod = @import("ast.zig");
const type_map = @import("../types/type_map.zig");
const dialect_enum = @import("../dialect/enum.zig");
const sql_type_mod = @import("../types/sql_type.zig");
const Writer = std.Io.Writer;
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;
const SqlComment = ast_mod.SqlComment;
const Dialect = dialect_enum.Dialect;

// ─── TypedAst: Dialect-agnostic IR between Semantic and Codegen ─
//
// ResolvedAst → TypedAst resolves types to structured SqlType.
// TypedAst → SQL: SqlType.toSql(dialect, writer) renders dialect-specific output.
// TypedAst → JSON/Prisma: inspect SqlType variants directly (no SQL binding).
//
// SqlType is defined in sql_type.zig and re-exported here for backward compat.

pub const ColumnFlag = enum(u16) {
    nullable = 0x0001,
    primary_key = 0x0002,
    auto_increment = 0x0004,
    unsigned = 0x0008,
    inline_unique = 0x0010,
    inline_index = 0x0020,
    is_enum = 0x0040,
    is_datetime = 0x0080,
    has_timestamp_default = 0x0100,
    on_update_current_timestamp = 0x0200,
};

pub const ColumnFlags = packed struct {
    nullable: bool = false,
    primary_key: bool = false,
    auto_increment: bool = false,
    unsigned: bool = false,
    inline_unique: bool = false,
    inline_index: bool = false,
    is_enum: bool = false,
    is_datetime: bool = false,
    has_timestamp_default: bool = false,
    on_update_current_timestamp: bool = false,

    pub fn contains(self: ColumnFlags, comptime flag: ColumnFlag) bool {
        return switch (flag) {
            .nullable => self.nullable,
            .primary_key => self.primary_key,
            .auto_increment => self.auto_increment,
            .unsigned => self.unsigned,
            .inline_unique => self.inline_unique,
            .inline_index => self.inline_index,
            .is_enum => self.is_enum,
            .is_datetime => self.is_datetime,
            .has_timestamp_default => self.has_timestamp_default,
            .on_update_current_timestamp => self.on_update_current_timestamp,
        };
    }

    pub fn set(self: *ColumnFlags, flag: ColumnFlag, value: bool) void {
        switch (flag) {
            .nullable => self.nullable = value,
            .primary_key => self.primary_key = value,
            .auto_increment => self.auto_increment = value,
            .unsigned => self.unsigned = value,
            .inline_unique => self.inline_unique = value,
            .inline_index => self.inline_index = value,
            .is_enum => self.is_enum = value,
            .is_datetime => self.is_datetime = value,
            .has_timestamp_default => self.has_timestamp_default = value,
            .on_update_current_timestamp => self.on_update_current_timestamp = value,
        }
    }
};

// ─── SqlType: Dialect-agnostic structured type representation ──
//
// Defined in sql_type.zig, re-exported here for backward compatibility.
// SqlType.toSql() is self-contained in sql_type.zig (no delegation).

pub const SqlType = sql_type_mod.SqlType;

pub const TypedAst = struct {
    schema_name: ?[]const u8,
    schema_charset: ?[]const u8,
    tables: []const TypedTable,
    views: []const TypedView,
    sql_comments: []const SqlComment,
};

pub const TypedView = struct {
    name: []const u8,
    query: []const u8,
    comment: ?[]const u8,
    line_no: usize,
};

pub const TypedTable = struct {
    name: []const u8,
    comment: ?[]const u8,
    engine: ?[]const u8,
    columns: []const TypedColumn,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
};

pub const TypedColumn = struct {
    name: []const u8,
    sql_type: SqlType,
    sym_type: ?[]const u8 = null,
    flags: ColumnFlags = .{},
    default: ?[]const u8,
    check: ?CheckConstraint,
    comment: ?[]const u8,
    enum_values: []const []const u8,
    line_no: usize,
};

// ─── Resolution: ResolvedAst → TypedAst ──────────────────────
//
// Extracted to type_resolver.zig in v0.4.54 Phase 3.
// Re-exported here for backward compatibility.

pub const TypeResolver = @import("../types/type_resolver.zig").TypeResolver;
