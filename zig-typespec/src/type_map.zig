const std = @import("std");
const ast_mod = @import("ast.zig");
const TypeInfo = ast_mod.TypeInfo;
const dialect_enum = @import("dialect_enum.zig");
const sql_type_mod = @import("sql_type.zig");

// ─── Unified Type Mapping ────────────────────────────────────
//
// Single source of truth for TPS ↔ SQL type mappings.
// Forward: sqlTypeName() — renders SqlType → dialect-specific SQL name.
// Custom type lookup: lookupCustomType() — resolves user-defined type aliases.
// Helper: isNumericTpsType() / isDatetimeTpsType() — classify TPS type symbols.
//
// For reverse mappings (SQL → TPS), see reverse_map.zig.

pub const Dialect = dialect_enum.Dialect;

// ─── SqlType → SQL name (single source of truth) ────────────────
//
// Renders a SqlType variant to a dialect-specific SQL type name string.
// This is the canonical location for all SqlType-to-SQL rendering logic.
// SqlType.toSql() in sql_type.zig delegates here.

pub fn sqlTypeName(w: anytype, dialect: Dialect, sql_type: sql_type_mod.SqlType) !void {
    switch (sql_type) {
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

// ─── sqlTypeName tests ──────────────────────────────────────────

fn sqlTypeNameAlloc(dialect: Dialect, sql_type: sql_type_mod.SqlType) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    try sqlTypeName(&aw.writer, dialect, sql_type);
    return try aw.toOwnedSlice(std.testing.allocator);
}

test "sqlTypeName: int in all dialects" {
    const mysql = try sqlTypeNameAlloc(.mysql, .int);
    defer std.testing.allocator.free(mysql);
    try std.testing.expectEqualStrings("int", mysql);

    const pg = try sqlTypeNameAlloc(.pg, .int);
    defer std.testing.allocator.free(pg);
    try std.testing.expectEqualStrings("integer", pg);

    const sqlite = try sqlTypeNameAlloc(.sqlite, .int);
    defer std.testing.allocator.free(sqlite);
    try std.testing.expectEqualStrings("INTEGER", sqlite);
}

test "sqlTypeName: decimal with precision" {
    const mysql = try sqlTypeNameAlloc(.mysql, .{ .decimal = .{ .precision = 10, .scale = 2 } });
    defer std.testing.allocator.free(mysql);
    try std.testing.expectEqualStrings("decimal(10, 2)", mysql);

    const pg = try sqlTypeNameAlloc(.pg, .{ .decimal = .{ .precision = 10, .scale = 2 } });
    defer std.testing.allocator.free(pg);
    try std.testing.expectEqualStrings("numeric(10, 2)", pg);
}

test "sqlTypeName: varchar(0) renders default per dialect" {
    const mysql = try sqlTypeNameAlloc(.mysql, .{ .varchar = 0 });
    defer std.testing.allocator.free(mysql);
    try std.testing.expectEqualStrings("varchar(255)", mysql);

    const sqlite = try sqlTypeNameAlloc(.sqlite, .{ .varchar = 0 });
    defer std.testing.allocator.free(sqlite);
    try std.testing.expectEqualStrings("TEXT", sqlite);
}

test "sqlTypeName: passthrough passes through" {
    const pg = try sqlTypeNameAlloc(.pg, .{ .passthrough = "uuid" });
    defer std.testing.allocator.free(pg);
    try std.testing.expectEqualStrings("uuid", pg);
}

// ─── Forward/Reverse Consistency Test ──────────────────────────
// Verifies that REVERSE_MAP canonical entries (sql_type != null)
// agree with sqlTypeName() for the base type in all dialects.
// When adding a new type, update BOTH sqlTypeName() and REVERSE_MAP.

const reverse_map = @import("reverse_map.zig");

fn forwardNameAlloc(dialect: Dialect, sql_type: sql_type_mod.SqlType) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    try sqlTypeName(&aw.writer, dialect, sql_type);
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

test "consistency: REVERSE_MAP canonical entries match sqlTypeName" {
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
