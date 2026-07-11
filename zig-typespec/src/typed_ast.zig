const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
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
const Dialect = type_map.Dialect;

// ─── TypedAst: Dialect-agnostic IR between Semantic and Codegen ─
//
// ResolvedAst → TypedAst resolves types to concrete SQL strings.
// TypedAst → SQL is pure output (no type inference logic).
//
// Adding a new dialect only requires changes in the SQL output layer,
// not in type resolution.

pub const TypedAst = struct {
    schema_name: ?[]const u8,
    schema_charset: ?[]const u8,
    tables: []const TypedTable,
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
    sql_type: []const u8,
    nullable: bool,
    primary_key: bool,
    auto_increment: bool,
    unsigned: bool,
    default: ?[]const u8,
    check: ?CheckConstraint,
    comment: ?[]const u8,
    inline_unique: bool,
    inline_index: bool,
    is_enum: bool,
    enum_values: []const []const u8,
    is_datetime: bool,
    line_no: usize,
};

// ─── Resolution: ResolvedAst → TypedAst ──────────────────────

pub const TypeResolver = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TypeResolver {
        return .{ .alloc = alloc };
    }

    pub fn resolve(self: *TypeResolver, resolved: sem.ResolvedAst, dialect: Dialect) !TypedAst {
        var tables = try std.ArrayList(TypedTable).initCapacity(self.alloc, resolved.tables.len);
        for (resolved.tables) |table| {
            var columns = try std.ArrayList(TypedColumn).initCapacity(self.alloc, table.fields.len);
            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                try columns.append(self.alloc, try self.resolveColumn(field, dialect));
            }
            try tables.append(self.alloc, .{
                .name = table.name,
                .comment = table.comment,
                .engine = table.engine,
                .columns = try columns.toOwnedSlice(self.alloc),
                .fks = table.fks,
                .indexes = table.indexes,
                .line_no = table.line_no,
            });
        }
        return .{
            .schema_name = resolved.schema_name,
            .schema_charset = resolved.schema_charset,
            .tables = try tables.toOwnedSlice(self.alloc),
        };
    }

    fn resolveColumn(self: *TypeResolver, field: Field, dialect: Dialect) !TypedColumn {
        // Resolve SQL type string
        var type_buf = std.ArrayList(u8).init(self.alloc);
        const type_writer = &type_buf.writer;
        try type_map.toSqlType(type_writer, dialect, field.type_info);
        const sql_type = try type_buf.toOwnedSlice();

        // Classify modifiers
        var pk = false;
        var ai = false;
        var unsigned = false;
        var inline_unique = false;
        var inline_index = false;
        for (field.modifiers) |mod| {
            switch (mod.kind) {
                .auto_inc_pk => { pk = true; ai = true; },
                .auto_inc => ai = true,
                .primary_key => pk = true,
                .not_null => {},
                .unsigned => unsigned = true,
                .inline_unique => inline_unique = true,
                .inline_index => inline_index = true,
            }
        }

        const is_dt = type_map.isDatetimeTpsType(field.type_info);
        const is_enum = field.type_info == .enum_type;
        const enum_vals = if (is_enum) field.type_info.enum_type else &[_][]const u8{};

        return .{
            .name = field.name,
            .sql_type = sql_type,
            .nullable = false,
            .primary_key = pk,
            .auto_increment = ai,
            .unsigned = unsigned,
            .default = if (field.default_val) |dv| dv.value else null,
            .check = field.check,
            .comment = field.comment,
            .inline_unique = inline_unique,
            .inline_index = inline_index,
            .is_enum = is_enum,
            .enum_values = enum_vals,
            .is_datetime = is_dt,
            .line_no = field.line_no,
        };
    }
};
