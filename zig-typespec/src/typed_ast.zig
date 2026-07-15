const std = @import("std");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const type_registry = @import("type_registry.zig");
const dialect_enum = @import("dialect_enum.zig");
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
// Replaces the raw SQL string in TypedColumn.sql_type.
// Each variant carries enough information to render to any SQL dialect
// or to non-SQL formats (JSON Schema, Prisma, etc.).

pub const SqlType = union(enum) {
    int,
    bigint,
    decimal: struct { precision: usize, scale: usize },
    varchar: usize, // 0 = TEXT
    text,
    blob,
    json,
    datetime,
    date,
    boolean,
    enum_values: []const []const u8,
    /// Raw SQL pass-through (custom type override).
    raw_sql: []const u8,
    /// Multi-char type pass-through (PG-specific types like "uuid", "serial").
    passthrough: []const u8,

    /// Render this SqlType to a dialect-specific SQL type string.
    pub fn toSql(self: SqlType, dialect: Dialect, w: *Writer) !void {
        switch (self) {
            .int => {
                try w.writeAll(switch (dialect) {
                    .mysql => "int",
                    .pg => "integer",
                    .sqlite => "INTEGER",
                });
            },
            .bigint => {
                try w.writeAll(switch (dialect) {
                    .mysql => "bigint",
                    .pg => "bigint",
                    .sqlite => "INTEGER",
                });
            },
            .decimal => |ds| {
                const name = switch (dialect) {
                    .mysql => "decimal",
                    .pg => "numeric",
                    .sqlite => "NUMERIC",
                };
                try w.print("{s}({d}, {d})", .{ name, ds.precision, ds.scale });
            },
            .varchar => |n| {
                if (n > 0) {
                    try w.print("varchar({d})", .{n});
                } else {
                    try w.writeAll(switch (dialect) {
                        .mysql => "varchar(255)",
                        .pg => "varchar(255)",
                        .sqlite => "TEXT",
                    });
                }
            },
            .text => {
                try w.writeAll(switch (dialect) {
                    .mysql => "text",
                    .pg => "text",
                    .sqlite => "TEXT",
                });
            },
            .blob => {
                try w.writeAll(switch (dialect) {
                    .mysql => "blob",
                    .pg => "bytea",
                    .sqlite => "BLOB",
                });
            },
            .json => {
                try w.writeAll(switch (dialect) {
                    .mysql => "json",
                    .pg => "json",
                    .sqlite => "TEXT",
                });
            },
            .datetime => {
                try w.writeAll(switch (dialect) {
                    .mysql => "datetime",
                    .pg => "timestamp",
                    .sqlite => "TEXT",
                });
            },
            .date => {
                try w.writeAll(switch (dialect) {
                    .mysql => "date",
                    .pg => "date",
                    .sqlite => "TEXT",
                });
            },
            .boolean => {
                try w.writeAll(switch (dialect) {
                    .mysql => "boolean",
                    .pg => "boolean",
                    .sqlite => "INTEGER",
                });
            },
            .enum_values => |vals| {
                switch (dialect) {
                    .mysql => {
                        try w.writeAll("ENUM(");
                        for (vals, 0..) |v, vi| {
                            if (vi > 0) try w.writeAll(", ");
                            try w.print("'{s}'", .{v});
                        }
                        try w.writeAll(")");
                    },
                    .pg, .sqlite => {
                        try w.writeAll("TEXT");
                    },
                }
            },
            .raw_sql => |sql| try w.writeAll(sql),
            .passthrough => |t| try w.writeAll(t),
        }
    }

    /// Build a SqlType from a TypeInfo + dialect (resolves single-char TPS symbols).
    pub fn fromTypeInfo(type_info: TypeInfo, dialect: Dialect) SqlType {
        return switch (type_info) {
            .none => .{ .varchar = 0 },
            .simple => |s| {
                if (s.len == 1) {
                    // Use type_registry for single-char types
                    if (type_registry.lookupSqlType(s, dialect)) |sql_type_name| {
                        return inferSqlTypeFromName(sql_type_name);
                    }
                    return .{ .passthrough = s };
                } else {
                    return .{ .passthrough = s };
                }
            },
            .int_explicit => |n| {
                _ = n;
                return .int;
            },
            .decimal_explicit => |ds| .{ .decimal = .{ .precision = ds.precision, .scale = ds.scale } },
            .varchar_explicit => |n| .{ .varchar = n },
            .enum_type => |vals| .{ .enum_values = vals },
            .raw_sql => |sql| .{ .raw_sql = sql },
        };
    }

    /// Infer SqlType variant from a SQL type name string (used by registry lookup).
    fn inferSqlTypeFromName(sql_name: []const u8) SqlType {
        // Handle precision-bearing types first: decimal(...)/numeric(...)  /NUMERIC(...)
        if (std.mem.indexOf(u8, sql_name, "(")) |open| {
            if (std.mem.endsWith(u8, sql_name, ")")) {
                const close = sql_name.len - 1;
                const type_prefix = sql_name[0..open];
                const interior = sql_name[open + 1 .. close];
                var parts = std.mem.splitScalar(u8, interior, ',');
                const p_str = std.mem.trim(u8, parts.next() orelse "16", " ");
                const s_str = std.mem.trim(u8, parts.next() orelse "2", " ");
                const precision = std.fmt.parseInt(usize, p_str, 10) catch 16;
                const scale = std.fmt.parseInt(usize, s_str, 10) catch 2;
                // Check if it's a decimal/numeric type
                if (std.mem.eql(u8, type_prefix, "decimal") or
                    std.mem.eql(u8, type_prefix, "numeric") or
                    std.mem.eql(u8, type_prefix, "NUMERIC"))
                {
                    return .{ .decimal = .{ .precision = precision, .scale = scale } };
                }
                // Check if it's a varchar type
                if (std.mem.eql(u8, type_prefix, "varchar") or
                    std.mem.eql(u8, type_prefix, "VARCHAR"))
                {
                    return .{ .varchar = precision };
                }
            }
        }
        // Handle simple types (case-insensitive for common names)
        const lower = blk: {
            var buf: [32]u8 = undefined;
            const len = @min(sql_name.len, 32);
            for (sql_name[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..len];
        };
        if (std.mem.eql(u8, lower, "int") or std.mem.eql(u8, lower, "integer")) return .int;
        if (std.mem.eql(u8, lower, "bigint")) return .bigint;
        if (std.mem.eql(u8, lower, "text")) return .text;
        if (std.mem.eql(u8, lower, "boolean")) return .boolean;
        if (std.mem.eql(u8, lower, "blob") or std.mem.eql(u8, lower, "bytea")) return .blob;
        if (std.mem.eql(u8, lower, "json")) return .json;
        if (std.mem.eql(u8, lower, "date")) return .date;
        if (std.mem.eql(u8, lower, "datetime") or std.mem.eql(u8, lower, "timestamp")) return .datetime;
        if (std.mem.eql(u8, lower, "varchar")) return .{ .varchar = 0 };
        return .{ .passthrough = sql_name };
    }
};

pub const TypedAst = struct {
    schema_name: ?[]const u8,
    schema_charset: ?[]const u8,
    tables: []const TypedTable,
    sql_comments: []const SqlComment,
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
    tps_type: ?[]const u8 = null,
    flags: ColumnFlags = .{},
    default: ?[]const u8,
    check: ?CheckConstraint,
    comment: ?[]const u8,
    enum_values: []const []const u8,
    line_no: usize,
};

// ─── Resolution: ResolvedAst → TypedAst ──────────────────────

pub const TypeResolver = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TypeResolver {
        return .{ .alloc = alloc };
    }

    pub fn resolve(self: *TypeResolver, resolved: ast_mod.ResolvedAst, dialect: Dialect) !TypedAst {
        var tables = try std.ArrayList(TypedTable).initCapacity(self.alloc, resolved.tables.len);
        for (resolved.tables) |table| {
            var columns = try std.ArrayList(TypedColumn).initCapacity(self.alloc, table.fields.len);
            // Collect inline FKs from fields + standalone FKs from table
            var all_fks = try std.ArrayList(FkDecl).initCapacity(self.alloc, table.fks.len + 4);
            for (table.fks) |fk| try all_fks.append(self.alloc, fk);
            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                const col = try self.resolveColumn(field, dialect, resolved.custom_types);
                try columns.append(self.alloc, col);
                if (field.fk) |fk| try all_fks.append(self.alloc, fk);
            }
            try tables.append(self.alloc, .{
                .name = table.name,
                .comment = table.comment,
                .engine = table.engine,
                .columns = try columns.toOwnedSlice(self.alloc),
                .fks = try all_fks.toOwnedSlice(self.alloc),
                .indexes = table.indexes,
                .line_no = table.line_no,
            });
        }
        return .{
            .schema_name = resolved.schema_name,
            .schema_charset = resolved.schema_charset,
            .tables = try tables.toOwnedSlice(self.alloc),
            .sql_comments = resolved.sql_comments,
        };
    }

    pub fn resolveColumn(self: *TypeResolver, field: Field, dialect: Dialect, custom_types: []const ast_mod.CustomType) !TypedColumn {
        return self.resolveColumnInner(field, dialect, custom_types, 0);
    }

    fn resolveColumnInner(self: *TypeResolver, field: Field, dialect: Dialect, custom_types: []const ast_mod.CustomType, depth: u8) !TypedColumn {
        // Check custom types first (multi-char names only)
        if (field.type_info == .simple and field.type_info.simple.len > 1) {
            if (type_map.lookupCustomType(custom_types, field.type_info.simple, dialect)) |ct_info| {
                // Detect circular custom type references (e.g., ~A B + ~B A)
                if (depth >= 32) {
                    return error.CircularCustomType;
                }
                // Recursively resolve the custom type's base info
                return self.resolveColumnInner(ast_mod.Field{
                    .name = field.name,
                    .type_info = ct_info,
                    .modifiers = field.modifiers,
                    .default_val = field.default_val,
                    .check = field.check,
                    .fk = field.fk,
                    .comment = field.comment,
                    .line_no = field.line_no,
                }, dialect, custom_types, depth + 1);
            }
        }
        // Resolve to structured SqlType (dialect-agnostic)
        const sql_type = SqlType.fromTypeInfo(field.type_info, dialect);

        // Classify modifiers
        var pk = false;
        var ai = false;
        var nn = false;
        var unsigned = false;
        var inline_unique = false;
        var inline_index = false;
        var on_update_ts = false;
        var has_timestamp_mod = false;
        for (field.modifiers) |mod| {
            switch (mod.kind) {
                .auto_inc_pk => {
                    if (type_map.isDatetimeTpsType(field.type_info)) {
                        on_update_ts = true;
                        has_timestamp_mod = true;
                    } else {
                        pk = true;
                        ai = true;
                    }
                },
                .auto_inc => {
                    if (type_map.isDatetimeTpsType(field.type_info)) {
                        has_timestamp_mod = true;
                    } else {
                        ai = true;
                    }
                },
                .primary_key => pk = true,
                .not_null => nn = true,
                .unsigned => unsigned = true,
                .inline_unique => inline_unique = true,
                .inline_index => inline_index = true,
            }
        }

        const is_dt = type_map.isDatetimeTpsType(field.type_info);
        const is_enum = field.type_info == .enum_type;
        const enum_vals = if (is_enum) field.type_info.enum_type else &[_][]const u8{};

        // Compute original TPS type string for roundtrip preservation
        const tps_type: ?[]const u8 = switch (field.type_info) {
            .simple => |s| if (s.len == 1) s else null,
            .varchar_explicit => |n| if (n > 0) blk: {
                var tbuf: [16]u8 = undefined;
                const result = try std.fmt.bufPrint(&tbuf, "s{d}", .{n});
                break :blk try self.alloc.dupe(u8, result);
            } else null,
            .decimal_explicit => |ds| blk: {
                var tbuf: [16]u8 = undefined;
                const result = try std.fmt.bufPrint(&tbuf, "{d},{d}", .{ ds.precision, ds.scale });
                break :blk try self.alloc.dupe(u8, result);
            },
            .none => "s",
            else => null,
        };

        return .{
            .name = field.name,
            .sql_type = sql_type,
            .tps_type = tps_type,
            .flags = .{
                .nullable = !nn,
                .primary_key = pk,
                .auto_increment = ai,
                .unsigned = unsigned,
                .inline_unique = inline_unique,
                .inline_index = inline_index,
                .is_enum = is_enum,
                .is_datetime = is_dt,
                .has_timestamp_default = has_timestamp_mod,
                .on_update_current_timestamp = on_update_ts,
            },
            .default = if (field.default_val) |dv| dv.value else null,
            .check = field.check,
            .comment = field.comment,
            .enum_values = enum_vals,
            .line_no = field.line_no,
        };
    }
};
