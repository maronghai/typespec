const std = @import("std");
const dialect_enum = @import("dialect_enum.zig");
const dialect_mod = @import("dialect.zig");
const sql_type_mod = @import("sql_type.zig");
const Dialect = dialect_enum.Dialect;

// ─── Type Registry: Single source of truth for TPS types ─────
//
// To add a new TPS type (e.g., UUID):
//   1. Add one entry to SYMBOL_MAP below
//   2. Add the SqlType variant to sql_type.zig if needed
//   3. All four pipelines (forward, reverse, diff, migrate) automatically recognize it
//
// Production code uses lookupSqlTypeDirect() which returns SqlType variants.
// lookupSqlType() is a convenience wrapper for tests that need string output.

/// Look up SqlType variant directly for a TPS symbol in a given dialect.
/// This is the primary lookup used by production code (SqlType.fromTypeInfo).
/// Avoids the stringly-typed round-trip (TPS → SQL string → SqlType).
pub fn lookupSqlTypeDirect(tps_symbol: []const u8, dialect: Dialect) ?sql_type_mod.SqlType {
    const SYMBOL_MAP = [_]struct { tps: []const u8, mysql: sql_type_mod.SqlType, pg: sql_type_mod.SqlType, sqlite: sql_type_mod.SqlType }{
        .{ .tps = "n", .mysql = .int, .pg = .int, .sqlite = .int },
        .{ .tps = "N", .mysql = .bigint, .pg = .bigint, .sqlite = .int },
        .{ .tps = "i", .mysql = .smallint, .pg = .smallint, .sqlite = .smallint },
        .{ .tps = "m", .mysql = .{ .decimal = .{ .precision = 16, .scale = 2 } }, .pg = .{ .decimal = .{ .precision = 16, .scale = 2 } }, .sqlite = .{ .decimal = .{ .precision = 16, .scale = 2 } } },
        .{ .tps = "M", .mysql = .{ .decimal = .{ .precision = 20, .scale = 6 } }, .pg = .{ .decimal = .{ .precision = 20, .scale = 6 } }, .sqlite = .{ .decimal = .{ .precision = 20, .scale = 6 } } },
        .{ .tps = "S", .mysql = .text, .pg = .text, .sqlite = .text },
        .{ .tps = "b", .mysql = .boolean, .pg = .boolean, .sqlite = .boolean },
        .{ .tps = "B", .mysql = .blob, .pg = .blob, .sqlite = .blob },
        .{ .tps = "j", .mysql = .json, .pg = .json, .sqlite = .json },
        .{ .tps = "d", .mysql = .date, .pg = .date, .sqlite = .date },
        .{ .tps = "t", .mysql = .datetime, .pg = .datetime, .sqlite = .datetime },
        .{ .tps = "T", .mysql = .timestamptz, .pg = .timestamptz, .sqlite = .timestamptz },
        .{ .tps = "s", .mysql = .{ .varchar = 0 }, .pg = .{ .varchar = 0 }, .sqlite = .{ .varchar = 0 } },
        .{ .tps = "U", .mysql = .uuid, .pg = .uuid, .sqlite = .{ .passthrough = "TEXT" } },
        .{ .tps = "p", .mysql = .serial, .pg = .serial, .sqlite = .{ .passthrough = "INTEGER" } },
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

/// Look up SQL type name for a TPS symbol in a given dialect.
/// Convenience wrapper — delegates to lookupSqlTypeDirect + SqlType.toSql.
pub fn lookupSqlType(tps_symbol: []const u8, dialect: Dialect) ?[]const u8 {
    const sql_type = lookupSqlTypeDirect(tps_symbol, dialect) orelse return null;
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    sql_type.toSql(dialect, &aw.writer) catch return null;
    return aw.toOwnedSlice(std.heap.page_allocator) catch null;
}

/// Look up TPS symbol for a SQL type in a given dialect.
/// Returns .{ .tps, .omit } where omit indicates the symbol should be omitted in reverse output.
pub const ReverseResult = dialect_mod.ReverseResult;

pub fn lookupTpsSymbol(sql_type: []const u8, dialect: Dialect) ?ReverseResult {
    // Parameterized types: check prefix matches
    if (std.mem.startsWith(u8, sql_type, "varchar(")) {
        return .{ .tps = "s", .omit = true, .is_parameterized = true };
    }
    if (std.mem.startsWith(u8, sql_type, "decimal(") or std.mem.startsWith(u8, sql_type, "numeric(")) {
        return .{ .tps = "m", .omit = false, .is_parameterized = true };
    }
    // Exact match via reverse_map
    const reverse_map = @import("reverse_map.zig");
    for (&reverse_map.REVERSE_MAP) |entry| {
        const dialect_type = switch (dialect) {
            .mysql => entry.mysql,
            .pg => entry.pg,
            .sqlite => entry.sqlite,
        };
        if (std.mem.eql(u8, sql_type, dialect_type)) {
            return .{ .tps = entry.tps, .omit = false };
        }
    }
    return null;
}

/// Check if a TPS symbol is a known core type.
pub fn isCoreType(tps_symbol: []const u8) bool {
    return lookupSqlTypeDirect(tps_symbol, .mysql) != null;
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

test "registry: lookupSqlTypeDirect for all core types" {
    const int_mysql = lookupSqlTypeDirect("n", .mysql);
    try testing.expect(int_mysql != null);
    try testing.expectEqual(sql_type_mod.SqlType.int, int_mysql.?);

    const int_pg = lookupSqlTypeDirect("n", .pg);
    try testing.expect(int_pg != null);
    try testing.expectEqual(sql_type_mod.SqlType.int, int_pg.?);

    const bigint = lookupSqlTypeDirect("N", .mysql);
    try testing.expect(bigint != null);
    try testing.expectEqual(sql_type_mod.SqlType.bigint, bigint.?);

    const text = lookupSqlTypeDirect("S", .mysql);
    try testing.expect(text != null);
    try testing.expectEqual(sql_type_mod.SqlType.text, text.?);

    const boolean = lookupSqlTypeDirect("b", .pg);
    try testing.expect(boolean != null);
    try testing.expectEqual(sql_type_mod.SqlType.boolean, boolean.?);

    const blob = lookupSqlTypeDirect("B", .mysql);
    try testing.expect(blob != null);
    try testing.expectEqual(sql_type_mod.SqlType.blob, blob.?);

    const json = lookupSqlTypeDirect("j", .mysql);
    try testing.expect(json != null);
    try testing.expectEqual(sql_type_mod.SqlType.json, json.?);

    const datetime = lookupSqlTypeDirect("t", .mysql);
    try testing.expect(datetime != null);
    try testing.expectEqual(sql_type_mod.SqlType.datetime, datetime.?);

    try testing.expect(lookupSqlTypeDirect("x", .mysql) == null);
}

test "registry: lookupSqlType renders correct strings" {
    const int_mysql = lookupSqlType("n", .mysql);
    try testing.expect(int_mysql != null);
    try testing.expectEqualStrings("int", int_mysql.?);

    const int_pg = lookupSqlType("n", .pg);
    try testing.expect(int_pg != null);
    try testing.expectEqualStrings("integer", int_pg.?);

    const int_sqlite = lookupSqlType("n", .sqlite);
    try testing.expect(int_sqlite != null);
    try testing.expectEqualStrings("INTEGER", int_sqlite.?);

    const bigint_mysql = lookupSqlType("N", .mysql);
    try testing.expect(bigint_mysql != null);
    try testing.expectEqualStrings("bigint", bigint_mysql.?);

    const text_mysql = lookupSqlType("S", .mysql);
    try testing.expect(text_mysql != null);
    try testing.expectEqualStrings("text", text_mysql.?);

    const boolean_pg = lookupSqlType("b", .pg);
    try testing.expect(boolean_pg != null);
    try testing.expectEqualStrings("boolean", boolean_pg.?);

    const blob_mysql = lookupSqlType("B", .mysql);
    try testing.expect(blob_mysql != null);
    try testing.expectEqualStrings("blob", blob_mysql.?);

    const bytea_pg = lookupSqlType("B", .pg);
    try testing.expect(bytea_pg != null);
    try testing.expectEqualStrings("bytea", bytea_pg.?);

    const json_mysql = lookupSqlType("j", .mysql);
    try testing.expect(json_mysql != null);
    try testing.expectEqualStrings("json", json_mysql.?);

    const datetime_mysql = lookupSqlType("t", .mysql);
    try testing.expect(datetime_mysql != null);
    try testing.expectEqualStrings("datetime", datetime_mysql.?);

    const timestamp_pg = lookupSqlType("t", .pg);
    try testing.expect(timestamp_pg != null);
    try testing.expectEqualStrings("timestamp", timestamp_pg.?);

    try testing.expect(lookupSqlType("x", .mysql) == null);
}

test "registry: isCoreType" {
    try testing.expect(isCoreType("n"));
    try testing.expect(isCoreType("S"));
    try testing.expect(!isCoreType("x"));
    try testing.expect(!isCoreType("uuid"));
}
