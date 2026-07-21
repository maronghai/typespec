const std = @import("std");
const type_registry = @import("type_registry.zig");
const dialect_enum = @import("dialect_enum.zig");
const ast_mod = @import("ast.zig");
const TypeInfo = ast_mod.TypeInfo;
const Writer = std.Io.Writer;
const Dialect = dialect_enum.Dialect;

// ─── SqlType: Dialect-agnostic structured type representation ──
//
// Replaces the raw SQL string in TypedColumn.sql_type.
// Each variant carries enough information to render to any SQL dialect
// or to non-SQL formats (JSON Schema, Prisma, etc.).
//
// toSql() is self-contained — no delegation to type_map.zig.
// type_map.zig re-exports SqlType for backward compatibility and
// provides helper functions (lookupCustomType, isNumericTpsType, etc.).

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
    /// Self-contained — the single source of truth for SqlType → SQL rendering.
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

    /// Render this SqlType to a JSON Schema type object (dialect-agnostic).
    pub fn toJsonSchema(self: SqlType, w: *Writer) !void {
        switch (self) {
            .int, .bigint => try w.writeAll("{\"type\":\"integer\"}"),
            .decimal => |ds| {
                var multiple_of: f64 = 1.0;
                var i: usize = 0;
                while (i < ds.scale) : (i += 1) {
                    multiple_of /= 10.0;
                }
                if (ds.scale == 0) {
                    try w.writeAll("{\"type\":\"integer\"}");
                } else {
                    try w.print("{{\"type\":\"number\",\"multipleOf\":{d}}}", .{multiple_of});
                }
            },
            .varchar => |n| {
                if (n > 0) {
                    try w.print("{{\"type\":\"string\",\"maxLength\":{d}}}", .{n});
                } else {
                    try w.writeAll("{\"type\":\"string\"}");
                }
            },
            .text => try w.writeAll("{\"type\":\"string\"}"),
            .blob => try w.writeAll("{\"type\":\"string\",\"contentEncoding\":\"base64\"}"),
            .json => try w.writeAll("{\"type\":\"object\"}"),
            .datetime => try w.writeAll("{\"type\":\"string\",\"format\":\"date-time\"}"),
            .date => try w.writeAll("{\"type\":\"string\",\"format\":\"date\"}"),
            .boolean => try w.writeAll("{\"type\":\"boolean\"}"),
            .enum_values => |vals| {
                try w.writeAll("{\"type\":\"string\",\"enum\":[");
                for (vals, 0..) |v, vi| {
                    if (vi > 0) try w.writeAll(",");
                    try w.print("\"{s}\"", .{v});
                }
                try w.writeAll("]}");
            },
            .raw_sql, .passthrough => try w.writeAll("{\"type\":\"string\"}"),
        }
    }

    /// Build a SqlType from a TypeInfo + dialect (resolves single-char TPS symbols).
    /// Uses lookupSqlTypeDirect to avoid the stringly-typed round-trip.
    pub fn fromTypeInfo(type_info: TypeInfo, dialect: Dialect) SqlType {
        return switch (type_info) {
            .none => .{ .varchar = 0 },
            .simple => |s| {
                if (s.len == 1) {
                    if (type_registry.lookupSqlTypeDirect(s, dialect)) |sql_type| {
                        return sql_type;
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
};

// ─── Tests ──────────────────────────────────────────────────────

test "SqlType basic roundtrip" {
    const int_type = SqlType{.int};
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try int_type.toSql(.mysql, &aw.writer);
    const result = try aw.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("int", result);
}
