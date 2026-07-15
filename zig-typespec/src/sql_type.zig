const std = @import("std");
const type_map = @import("type_map.zig");
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
// Rendering: SqlType.toSql() delegates to type_map.sqlTypeName()
// which is the single source of truth for dialect-specific type names.

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
    /// Delegates to type_map.sqlTypeName() — the single source of truth.
    pub fn toSql(self: SqlType, dialect: Dialect, w: *Writer) !void {
        return type_map.sqlTypeName(w, dialect, self);
    }

    /// Render this SqlType to a JSON Schema type object (dialect-agnostic).
    pub fn toJsonSchema(self: SqlType, w: *Writer) !void {
        switch (self) {
            .int, .bigint => try w.writeAll("{\"type\":\"integer\"}"),
            .decimal => |ds| {
                // multipleOf = 10^(-scale), e.g. scale=2 → 0.01
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

// ─── Tests ──────────────────────────────────────────────────────

test "SqlType basic roundtrip" {
    const int_type = SqlType{ .int };
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try int_type.toSql(.mysql, &aw.writer);
    const result = try aw.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("int", result);
}
