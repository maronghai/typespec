const std = @import("std");
const ast_mod = @import("ast.zig");
const TypeInfo = ast_mod.TypeInfo;
const dialect_enum = @import("dialect_enum.zig");
const sql_type_mod = @import("sql_type.zig");

// ─── Unified Type Mapping ────────────────────────────────────
//
// Helper functions for type classification and custom type lookup.
// SqlType → SQL rendering is self-contained in sql_type.zig:SqlType.toSql().
// SqlType is re-exported here for backward compatibility.

pub const Dialect = dialect_enum.Dialect;
pub const SqlType = sql_type_mod.SqlType;

// ─── Helper: classify TPS type symbols ───────────────────────

pub fn isNumericTpsType(ti: TypeInfo) bool {
    switch (ti) {
        .simple => |s| return std.mem.eql(u8, s, "n") or std.mem.eql(u8, s, "N"),
        .int_explicit, .decimal_explicit => return true,
        else => return false,
    }
}

pub fn isDatetimeTpsType(ti: TypeInfo) bool {
    switch (ti) {
        .simple => |s| return std.mem.eql(u8, s, "t") or std.mem.eql(u8, s, "d"),
        else => return false,
    }
}

// ─── Custom Type Lookup ──────────────────────────────────────

/// Look up a custom type by name in the schema's custom_types list.
/// Returns the resolved TypeInfo for the given dialect, checking dialect-specific
/// overrides first, then falling back to the base type.
pub fn lookupCustomType(
    custom_types: []const ast_mod.CustomType,
    type_name: []const u8,
    dialect: Dialect,
) ?TypeInfo {
    for (custom_types) |ct| {
        if (std.mem.eql(u8, ct.name, type_name)) {
            // Check dialect-specific overrides first
            for (ct.dialect_overrides) |ov| {
                const dname = switch (dialect) {
                    .mysql => "mysql",
                    .pg => "postgres",
                    .sqlite => "sqlite",
                };
                if (std.mem.eql(u8, ov.dialect, dname)) {
                    return ov.type_info;
                }
            }
            // Fall back to base type
            return ct.base;
        }
    }
    return null;
}

// ─── Tests ────────────────────────────────────────────────────

test "isDatetimeTpsType: t is datetime" {
    try std.testing.expect(isDatetimeTpsType(.{ .simple = "t" }));
}

test "isDatetimeTpsType: d is datetime" {
    try std.testing.expect(isDatetimeTpsType(.{ .simple = "d" }));
}

test "isDatetimeTpsType: n is not datetime" {
    try std.testing.expect(!isDatetimeTpsType(.{ .simple = "n" }));
}

test "isNumericTpsType: n is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .simple = "n" }));
}

test "isNumericTpsType: N is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .simple = "N" }));
}

test "isNumericTpsType: s is not numeric" {
    try std.testing.expect(!isNumericTpsType(.{ .simple = "s" }));
}

test "isNumericTpsType: int_explicit is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .int_explicit = 11 }));
}

test "isNumericTpsType: decimal_explicit is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .decimal_explicit = .{ .precision = 10, .scale = 2 } }));
}

// ─── SqlType.toSql tests (moved from old sqlTypeName tests) ─────

fn toSqlAlloc(dialect: Dialect, sql_type: sql_type_mod.SqlType) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    try sql_type.toSql(dialect, &aw.writer);
    return try aw.toOwnedSlice(std.testing.allocator);
}

test "SqlType.toSql: int in all dialects" {
    const mysql = try toSqlAlloc(.mysql, .int);
    defer std.testing.allocator.free(mysql);
    try std.testing.expectEqualStrings("int", mysql);

    const pg = try toSqlAlloc(.pg, .int);
    defer std.testing.allocator.free(pg);
    try std.testing.expectEqualStrings("integer", pg);

    const sqlite = try toSqlAlloc(.sqlite, .int);
    defer std.testing.allocator.free(sqlite);
    try std.testing.expectEqualStrings("INTEGER", sqlite);
}

test "SqlType.toSql: decimal with precision" {
    const mysql = try toSqlAlloc(.mysql, .{ .decimal = .{ .precision = 10, .scale = 2 } });
    defer std.testing.allocator.free(mysql);
    try std.testing.expectEqualStrings("decimal(10, 2)", mysql);

    const pg = try toSqlAlloc(.pg, .{ .decimal = .{ .precision = 10, .scale = 2 } });
    defer std.testing.allocator.free(pg);
    try std.testing.expectEqualStrings("numeric(10, 2)", pg);
}

test "SqlType.toSql: varchar(0) renders default per dialect" {
    const mysql = try toSqlAlloc(.mysql, .{ .varchar = 0 });
    defer std.testing.allocator.free(mysql);
    try std.testing.expectEqualStrings("varchar(255)", mysql);

    const sqlite = try toSqlAlloc(.sqlite, .{ .varchar = 0 });
    defer std.testing.allocator.free(sqlite);
    try std.testing.expectEqualStrings("TEXT", sqlite);
}

test "SqlType.toSql: passthrough passes through" {
    const pg = try toSqlAlloc(.pg, .{ .passthrough = "uuid" });
    defer std.testing.allocator.free(pg);
    try std.testing.expectEqualStrings("uuid", pg);
}

// ─── Forward/Reverse Consistency Test ──────────────────────────
// Verifies that REVERSE_MAP canonical entries (sql_type != null)
// agree with SqlType.toSql() for the base type in all dialects.
// When adding a new type, update BOTH SqlType.toSql() and REVERSE_MAP.

const reverse_map = @import("reverse_map.zig");

fn forwardNameAlloc(dialect: Dialect, sql_type: sql_type_mod.SqlType) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    try sql_type.toSql(dialect, &aw.writer);
    return try aw.toOwnedSlice(std.testing.allocator);
}

fn expectForwardMatchesReverse(dialect: Dialect, forward_sql: []const u8, rev_entry: reverse_map.ReverseMapping) !void {
    const rev_sql = switch (dialect) {
        .mysql => rev_entry.mysql,
        .pg => rev_entry.pg,
        .sqlite => rev_entry.sqlite,
    };
    try std.testing.expectEqualStrings(rev_sql, forward_sql);
}

test "consistency: REVERSE_MAP canonical entries match SqlType.toSql" {
    for (reverse_map.REVERSE_MAP) |entry| {
        if (entry.sql_type) |sql_type| {
            // Skip parameterized types — their forward names include dynamic values
            // that can't be compared to the static REVERSE_MAP entries.
            switch (sql_type) {
                .varchar, .decimal, .enum_values, .raw_sql, .passthrough => continue,
                else => {},
            }
            const mysql = try forwardNameAlloc(.mysql, sql_type);
            defer std.testing.allocator.free(mysql);
            try expectForwardMatchesReverse(.mysql, mysql, entry);

            const pg = try forwardNameAlloc(.pg, sql_type);
            defer std.testing.allocator.free(pg);
            try expectForwardMatchesReverse(.pg, pg, entry);

            const sqlite = try forwardNameAlloc(.sqlite, sql_type);
            defer std.testing.allocator.free(sqlite);
            try expectForwardMatchesReverse(.sqlite, sqlite, entry);
        }
    }
}
