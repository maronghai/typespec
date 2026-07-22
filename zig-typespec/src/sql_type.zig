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
    smallint,
    decimal: struct { precision: usize, scale: usize },
    varchar: usize, // 0 = TEXT
    text,
    blob,
    json,
    datetime,
    date,
    timestamptz,
    boolean,
    uuid,
    serial,
    enum_values: []const []const u8,
    /// Raw SQL pass-through (custom type override).
    raw_sql: []const u8,
    /// Multi-char type pass-through (PG-specific types like "uuid", "serial").
    passthrough: []const u8,

    /// Render this SqlType to a dialect-specific SQL type string.
    /// Convenience wrapper — delegates to DialectBackend.renderType (the single source of truth).
    pub fn toSql(self: SqlType, dialect: Dialect, w: *Writer) !void {
        const backend = @import("dialect.zig").getBackend(dialect);
        try backend.renderType(w, self);
    }

    /// Render this SqlType to a JSON Schema type object (dialect-agnostic).
    pub fn toJsonSchema(self: SqlType, w: *Writer) !void {
        switch (self) {
            .int, .bigint, .smallint, .serial => try w.writeAll("{\"type\":\"integer\"}"),
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
            .datetime, .timestamptz => try w.writeAll("{\"type\":\"string\",\"format\":\"date-time\"}"),
            .date => try w.writeAll("{\"type\":\"string\",\"format\":\"date\"}"),
            .boolean => try w.writeAll("{\"type\":\"boolean\"}"),
            .uuid => try w.writeAll("{\"type\":\"string\",\"format\":\"uuid\"}"),
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
