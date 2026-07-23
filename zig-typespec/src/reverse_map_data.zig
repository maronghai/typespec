const sql_type_mod = @import("sql_type.zig");
const SqlType = sql_type_mod.SqlType;

// ─── Reverse Mapping Data: SQL → TPS ─────────────────────────
//
// All entries that reverse codegen may encounter. Includes:
//   - Core single-char entries (for SQLite which has lossy type affinity)
//   - MySQL/PG variant types (tinyint, serial, jsonb, etc.)
//   - Passthrough types (uuid, real, float4, float8)
//
// Priority ordering: lower number = preferred when multiple SQL types
// map to the same TPS symbol. Checked top-to-bottom; first match wins.
//
// Canonical entries (rev_priority=10) carry a sql_type tag that links
// to the SqlType union. The consistency test in type_map.zig verifies
// that these match the forward mapping in sqlTypeName().

pub const ReverseMapping = struct {
    tps: []const u8,
    mysql: []const u8,
    pg: []const u8,
    sqlite: []const u8,
    /// Reverse-match priority: lower = preferred.
    rev_priority: u32 = 0,
    /// SqlType tag for canonical entries (null for non-canonical variants).
    /// Used by the consistency test to verify forward/reverse mapping agreement.
    sql_type: ?SqlType = null,
};

pub const REVERSE_MAP = [_]ReverseMapping{
    // ─── Core single-char symbols (used by SQLite reverse) ───
    .{ .tps = "n", .mysql = "int", .pg = "integer", .sqlite = "INTEGER", .rev_priority = 10, .sql_type = .int },
    .{ .tps = "N", .mysql = "bigint", .pg = "bigint", .sqlite = "INTEGER", .rev_priority = 10, .sql_type = .bigint },
    .{ .tps = "m", .mysql = "decimal(16, 2)", .pg = "numeric(16, 2)", .sqlite = "NUMERIC", .rev_priority = 10, .sql_type = .{ .decimal = .{ .precision = 16, .scale = 2 } } },
    .{ .tps = "M", .mysql = "decimal(20, 6)", .pg = "numeric(20, 6)", .sqlite = "NUMERIC", .rev_priority = 10, .sql_type = .{ .decimal = .{ .precision = 20, .scale = 6 } } },
    .{ .tps = "S", .mysql = "text", .pg = "text", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .text },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .sqlite = "INTEGER", .rev_priority = 10, .sql_type = .boolean },
    .{ .tps = "B", .mysql = "blob", .pg = "bytea", .sqlite = "BLOB", .rev_priority = 10, .sql_type = .blob },
    .{ .tps = "j", .mysql = "json", .pg = "json", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .json },
    .{ .tps = "d", .mysql = "date", .pg = "date", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .date },
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .datetime },

    // ─── MySQL integer variants → reverse to "n" ───
    .{ .tps = "n", .mysql = "tinyint", .pg = "smallint", .sqlite = "INTEGER", .rev_priority = 20 },
    .{ .tps = "n", .mysql = "smallint", .pg = "smallint", .sqlite = "INTEGER", .rev_priority = 20 },
    .{ .tps = "n", .mysql = "mediumint", .pg = "integer", .sqlite = "INTEGER", .rev_priority = 20 },

    // ─── MySQL BLOB/TEXT variants ───
    .{ .tps = "B", .mysql = "tinyblob", .pg = "bytea", .sqlite = "BLOB", .rev_priority = 20 },
    .{ .tps = "B", .mysql = "mediumblob", .pg = "bytea", .sqlite = "BLOB", .rev_priority = 20 },
    .{ .tps = "B", .mysql = "longblob", .pg = "bytea", .sqlite = "BLOB", .rev_priority = 20 },
    .{ .tps = "s", .mysql = "tinytext", .pg = "varchar(255)", .sqlite = "TEXT", .rev_priority = 20 },
    .{ .tps = "S", .mysql = "mediumtext", .pg = "text", .sqlite = "TEXT", .rev_priority = 20 },
    .{ .tps = "S", .mysql = "longtext", .pg = "text", .sqlite = "TEXT", .rev_priority = 20 },

    // ─── MySQL datetime → reverse to "t" ───
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .sqlite = "TEXT", .rev_priority = 15 },

    // ─── MySQL-specific → reverse to core types ───
    .{ .tps = "b", .mysql = "bit(1)", .pg = "boolean", .sqlite = "INTEGER", .rev_priority = 15 },
    .{ .tps = "m", .mysql = "decimal(16,2)", .pg = "numeric(16, 2)", .sqlite = "NUMERIC", .rev_priority = 15 },
    .{ .tps = "M", .mysql = "decimal(20,6)", .pg = "numeric(20, 6)", .sqlite = "NUMERIC", .rev_priority = 15 },

    // ─── PostgreSQL types → reverse to core types ───
    .{ .tps = "n", .mysql = "serial", .pg = "serial", .sqlite = "INTEGER", .rev_priority = 20 },
    .{ .tps = "N", .mysql = "bigserial", .pg = "bigserial", .sqlite = "INTEGER", .rev_priority = 20 },
    .{ .tps = "i", .mysql = "smallint", .pg = "smallint", .sqlite = "INTEGER", .rev_priority = 10, .sql_type = .smallint },
    .{ .tps = "T", .mysql = "timestamp with time zone", .pg = "timestamptz", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .timestamptz },
    .{ .tps = "U", .mysql = "uuid", .pg = "uuid", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .uuid },
    .{ .tps = "p", .mysql = "serial", .pg = "serial", .sqlite = "INTEGER", .rev_priority = 10, .sql_type = .serial },
    .{ .tps = "J", .mysql = "jsonb", .pg = "jsonb", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .jsonb },
    .{ .tps = "I", .mysql = "inet", .pg = "inet", .sqlite = "TEXT", .rev_priority = 10, .sql_type = .inet },
    .{ .tps = "m", .mysql = "numeric", .pg = "numeric", .sqlite = "NUMERIC", .rev_priority = 20 },
    .{ .tps = "s", .mysql = "varchar", .pg = "varchar", .sqlite = "TEXT", .rev_priority = 20 },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .sqlite = "INTEGER", .rev_priority = 15 },
    .{ .tps = "j", .mysql = "json", .pg = "json", .sqlite = "TEXT", .rev_priority = 20 },
    .{ .tps = "t", .mysql = "timestamp", .pg = "timestamp", .sqlite = "TEXT", .rev_priority = 15 },
    .{ .tps = "t", .mysql = "timestamp without time zone", .pg = "timestamp without time zone", .sqlite = "TEXT", .rev_priority = 25 },
    .{ .tps = "t", .mysql = "timestamp with time zone", .pg = "timestamp with time zone", .sqlite = "TEXT", .rev_priority = 25 },

    // ─── Passthrough types (not in TypeSpec DSL, emitted as-is) ───
    .{ .tps = "uuid", .mysql = "uuid", .pg = "uuid", .sqlite = "TEXT" },
    .{ .tps = "real", .mysql = "real", .pg = "real", .sqlite = "REAL" },
    .{ .tps = "float4", .mysql = "float4", .pg = "float4", .sqlite = "REAL" },
    .{ .tps = "float8", .mysql = "float8", .pg = "float8", .sqlite = "REAL" },
    .{ .tps = "float8", .mysql = "double precision", .pg = "double precision", .sqlite = "REAL" },
    .{ .tps = "s", .mysql = "character", .pg = "character", .sqlite = "TEXT" },
};
