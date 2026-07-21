const std = @import("std");
const dialect_enum = @import("dialect_enum.zig");
const sql_type_mod = @import("sql_type.zig");
const Dialect = dialect_enum.Dialect;

// ─── Type Registry: Single source of truth for TPS types ─────
//
// To add a new TPS type (e.g., UUID):
//   1. Add one TypeEntry to CORE_TYPES below
//   2. All four pipelines (forward, reverse, diff, migrate) automatically recognize it
//
// TypeEntry defines:
//   - tps: the single-char TPS symbol
//   - mysql/pg/sqlite: the SQL type string for each dialect
//   - omit_in_reverse: if true, the type symbol is omitted in reverse output
//     (e.g., 's' (varchar) is the default and doesn't need explicit notation)

pub const TypeEntry = struct {
    tps: []const u8,
    mysql: []const u8,
    pg: []const u8,
    sqlite: []const u8,
    /// When true, reverse codegen omits this type symbol (it's the default).
    omit_in_reverse: bool = false,
};

/// Core single-char TPS types. This is the canonical type vocabulary.
/// Order matters: index is used for consistency tests.
pub const CORE_TYPES = [_]TypeEntry{
    .{ .tps = "n", .mysql = "int", .pg = "integer", .sqlite = "INTEGER" },
    .{ .tps = "N", .mysql = "bigint", .pg = "bigint", .sqlite = "INTEGER" },
    .{ .tps = "m", .mysql = "decimal(16, 2)", .pg = "numeric(16, 2)", .sqlite = "NUMERIC(16, 2)" },
    .{ .tps = "M", .mysql = "decimal(20, 6)", .pg = "numeric(20, 6)", .sqlite = "NUMERIC(20, 6)" },
    .{ .tps = "S", .mysql = "text", .pg = "text", .sqlite = "TEXT" },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .sqlite = "INTEGER" },
    .{ .tps = "B", .mysql = "blob", .pg = "bytea", .sqlite = "BLOB" },
    .{ .tps = "j", .mysql = "json", .pg = "json", .sqlite = "TEXT" },
    .{ .tps = "d", .mysql = "date", .pg = "date", .sqlite = "TEXT" },
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .sqlite = "TEXT" },
    .{ .tps = "s", .mysql = "varchar(255)", .pg = "varchar(255)", .sqlite = "TEXT", .omit_in_reverse = true },
};

/// Look up SQL type name for a TPS symbol in a given dialect.
pub fn lookupSqlType(tps_symbol: []const u8, dialect: Dialect) ?[]const u8 {
    for (&CORE_TYPES) |entry| {
        if (std.mem.eql(u8, entry.tps, tps_symbol)) {
            return switch (dialect) {
                .mysql => entry.mysql,
                .pg => entry.pg,
                .sqlite => entry.sqlite,
            };
        }
    }
    return null;
}

/// Look up SqlType variant directly for a TPS symbol in a given dialect.
/// Avoids the stringly-typed round-trip (TPS → SQL string → SqlType).
pub fn lookupSqlTypeDirect(tps_symbol: []const u8, dialect: Dialect) ?sql_type_mod.SqlType {
    const SYMBOL_MAP = [_]struct { tps: []const u8, mysql: sql_type_mod.SqlType, pg: sql_type_mod.SqlType, sqlite: sql_type_mod.SqlType }{
        .{ .tps = "n", .mysql = .int, .pg = .int, .sqlite = .int },
        .{ .tps = "N", .mysql = .bigint, .pg = .bigint, .sqlite = .int },
        .{ .tps = "m", .mysql = .{ .decimal = .{ .precision = 16, .scale = 2 } }, .pg = .{ .decimal = .{ .precision = 16, .scale = 2 } }, .sqlite = .{ .decimal = .{ .precision = 16, .scale = 2 } } },
        .{ .tps = "M", .mysql = .{ .decimal = .{ .precision = 20, .scale = 6 } }, .pg = .{ .decimal = .{ .precision = 20, .scale = 6 } }, .sqlite = .{ .decimal = .{ .precision = 20, .scale = 6 } } },
        .{ .tps = "S", .mysql = .text, .pg = .text, .sqlite = .text },
        .{ .tps = "b", .mysql = .boolean, .pg = .boolean, .sqlite = .boolean },
        .{ .tps = "B", .mysql = .blob, .pg = .blob, .sqlite = .blob },
        .{ .tps = "j", .mysql = .json, .pg = .json, .sqlite = .json },
        .{ .tps = "d", .mysql = .date, .pg = .date, .sqlite = .date },
        .{ .tps = "t", .mysql = .datetime, .pg = .datetime, .sqlite = .datetime },
        .{ .tps = "s", .mysql = .{ .varchar = 0 }, .pg = .{ .varchar = 0 }, .sqlite = .{ .varchar = 0 } },
    };
    for (&SYMBOL_MAP) |entry| {
        if (std.mem.eql(u8, entry.tps, tps_symbol)) {
            return switch (dialect) {
                .mysql => entry.mysql,
                .pg => entry.pg,
                .sqlite => entry.sqlite,
            };
        }
    }
    return null;
}

/// Look up TPS symbol for a SQL type in a given dialect.
/// Returns .{ .tps, .omit } where omit indicates the symbol should be omitted in reverse output.
pub const ReverseResult = struct {
    tps: []const u8,
    omit: bool,
};

pub fn lookupTpsSymbol(sql_type: []const u8, dialect: Dialect) ?ReverseResult {
    // Priority: exact match first, then dialect-specific fallbacks
    for (&CORE_TYPES) |entry| {
        const dialect_type = switch (dialect) {
            .mysql => entry.mysql,
            .pg => entry.pg,
            .sqlite => entry.sqlite,
        };
        if (std.mem.eql(u8, sql_type, dialect_type)) {
            return .{ .tps = entry.tps, .omit = entry.omit_in_reverse };
        }
    }
    return null;
}

/// Check if a TPS symbol is a known core type.
pub fn isCoreType(tps_symbol: []const u8) bool {
    for (&CORE_TYPES) |entry| {
        if (std.mem.eql(u8, entry.tps, tps_symbol)) return true;
    }
    return false;
}

/// Get all core types (for iteration by type_map.zig).
pub fn getAllCoreTypes() []const TypeEntry {
    return &CORE_TYPES;
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

test "registry: lookupSqlType for all core types" {
    try testing.expectEqualStrings("int", lookupSqlType("n", .mysql).?);
    try testing.expectEqualStrings("integer", lookupSqlType("n", .pg).?);
    try testing.expectEqualStrings("INTEGER", lookupSqlType("n", .sqlite).?);
    try testing.expectEqualStrings("bigint", lookupSqlType("N", .mysql).?);
    try testing.expectEqualStrings("text", lookupSqlType("S", .mysql).?);
    try testing.expectEqualStrings("boolean", lookupSqlType("b", .pg).?);
    try testing.expectEqualStrings("blob", lookupSqlType("B", .mysql).?);
    try testing.expectEqualStrings("bytea", lookupSqlType("B", .pg).?);
    try testing.expectEqualStrings("json", lookupSqlType("j", .mysql).?);
    try testing.expectEqualStrings("datetime", lookupSqlType("t", .mysql).?);
    try testing.expectEqualStrings("timestamp", lookupSqlType("t", .pg).?);
    try testing.expect(lookupSqlType("x", .mysql) == null);
}

test "registry: lookupTpsSymbol for common SQL types" {
    const r_int = lookupTpsSymbol("int", .mysql);
    try testing.expect(r_int != null);
    try testing.expectEqualStrings("n", r_int.?.tps);
    try testing.expect(!r_int.?.omit);

    const r_varchar = lookupTpsSymbol("varchar(255)", .mysql);
    try testing.expect(r_varchar != null);
    try testing.expectEqualStrings("s", r_varchar.?.tps);
    try testing.expect(r_varchar.?.omit);
}

test "registry: isCoreType" {
    try testing.expect(isCoreType("n"));
    try testing.expect(isCoreType("S"));
    try testing.expect(!isCoreType("x"));
    try testing.expect(!isCoreType("uuid"));
}

test "registry: CORE_TYPES count" {
    try testing.expectEqual(@as(usize, 11), CORE_TYPES.len);
}
