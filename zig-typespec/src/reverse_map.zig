const std = @import("std");
const TypeInfo = @import("ast.zig").TypeInfo;
const dialect_enum = @import("dialect_enum.zig");
const sqlite_hints = @import("sqlite_hints.zig");

pub const Dialect = dialect_enum.Dialect;

// ─── Reverse Mapping: SQL → TPS ──────────────────────────────
//
// All entries that reverse codegen may encounter. Includes:
//   - Core single-char entries (for SQLite which has lossy type affinity)
//   - MySQL/PG variant types (tinyint, serial, jsonb, etc.)
//   - Passthrough types (uuid, real, float4, float8)
//
// Priority ordering: lower number = preferred when multiple SQL types
// map to the same TPS symbol. Checked top-to-bottom; first match wins.

pub const ReverseMapping = struct {
    tps: []const u8,
    mysql: []const u8,
    pg: []const u8,
    sqlite: []const u8,
    /// Reverse-match priority: lower = preferred.
    rev_priority: u32 = 0,
};

pub const REVERSE_MAP = [_]ReverseMapping{
    // ─── Core single-char symbols (used by SQLite reverse) ───
    .{ .tps = "n", .mysql = "int", .pg = "integer", .sqlite = "INTEGER", .rev_priority = 10 },
    .{ .tps = "N", .mysql = "bigint", .pg = "bigint", .sqlite = "INTEGER", .rev_priority = 10 },
    .{ .tps = "m", .mysql = "decimal(16, 2)", .pg = "numeric(16, 2)", .sqlite = "NUMERIC", .rev_priority = 10 },
    .{ .tps = "M", .mysql = "decimal(20, 6)", .pg = "numeric(20, 6)", .sqlite = "NUMERIC", .rev_priority = 10 },
    .{ .tps = "S", .mysql = "text", .pg = "text", .sqlite = "TEXT", .rev_priority = 10 },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .sqlite = "INTEGER", .rev_priority = 10 },
    .{ .tps = "B", .mysql = "blob", .pg = "bytea", .sqlite = "BLOB", .rev_priority = 10 },
    .{ .tps = "j", .mysql = "json", .pg = "json", .sqlite = "TEXT", .rev_priority = 10 },
    .{ .tps = "d", .mysql = "date", .pg = "date", .sqlite = "TEXT", .rev_priority = 10 },
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .sqlite = "TEXT", .rev_priority = 10 },

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
    .{ .tps = "m", .mysql = "numeric", .pg = "numeric", .sqlite = "NUMERIC", .rev_priority = 20 },
    .{ .tps = "s", .mysql = "varchar", .pg = "varchar", .sqlite = "TEXT", .rev_priority = 20 },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .sqlite = "INTEGER", .rev_priority = 15 },
    .{ .tps = "j", .mysql = "jsonb", .pg = "jsonb", .sqlite = "TEXT", .rev_priority = 20 },
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

// ─── Reverse Mapping: SQL → TPS ──────────────────────────────

pub const ReverseResult = struct {
    tps: []const u8,
    omit: bool,
    confidence: Confidence = .high,
};

pub const Confidence = enum {
    high, // exact match from REVERSE_MAP or parameterized type
    medium, // suffix-based inference (_id, _at, _on) or known column name pattern
    low, // heuristic guess (SQLite type ambiguity)
};

/// Reverse-lookup a SQL type string to its TPS symbol.
/// Handles exact match from REVERSE_MAP + parameterized types (int(N), decimal(P,S), varchar(N)).
pub fn reverseLookup(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool, dialect: Dialect) ReverseResult {
    const t = std.mem.trim(u8, sql_type, " \t");

    // SQLite: match against m.sqlite with case-insensitive comparison and disambiguation heuristics
    if (dialect == .sqlite) {
        return reverseLookupSqlite(t, col_name, is_auto_inc, is_default_ts);
    }

    // MySQL/PG: exact match from REVERSE_MAP
    var best_match: ?ReverseResult = null;
    var best_priority: u32 = std.math.maxInt(u32);
    for (REVERSE_MAP) |m| {
        if (std.mem.eql(u8, t, m.mysql) or std.mem.eql(u8, t, m.pg)) {
            if (m.rev_priority < best_priority) {
                best_priority = m.rev_priority;
                best_match = .{ .tps = m.tps, .omit = canOmitType(col_name, m.tps, is_auto_inc, is_default_ts) };
            }
        }
    }
    if (best_match) |bm| return bm;

    // ─── Parameterized type patterns ───

    // int(N) → N
    if (std.mem.startsWith(u8, t, "int(") and std.mem.endsWith(u8, t, ")"))
        return .{ .tps = t[4 .. t.len - 1], .omit = false };

    // decimal(P,S) or decimal(P, S) → P,S
    if (std.mem.startsWith(u8, t, "decimal(") and std.mem.endsWith(u8, t, ")"))
        return .{ .tps = t[8 .. t.len - 1], .omit = false };

    // numeric(P,S) → P,S
    if (std.mem.startsWith(u8, t, "numeric(") and std.mem.endsWith(u8, t, ")"))
        return .{ .tps = t[8 .. t.len - 1], .omit = false };

    // varchar(255) → s (with omit check)
    if (std.mem.eql(u8, t, "varchar(255)"))
        return .{ .tps = "s", .omit = canOmitType(col_name, "s", is_auto_inc, is_default_ts) };

    // character varying(N) → sN
    if (std.mem.startsWith(u8, t, "character varying(") and std.mem.endsWith(u8, t, ")")) {
        const inner = std.mem.trim(u8, t[17 .. t.len - 1], " ");
        if (std.mem.eql(u8, inner, "255"))
            return .{ .tps = "s", .omit = canOmitType(col_name, "s", is_auto_inc, is_default_ts) };
        const sbuf = struct {
            var buf: [16]u8 = undefined;
        };
        sbuf.buf[0] = 's';
        for (inner, 0..) |ch, i| sbuf.buf[i + 1] = ch;
        return .{ .tps = sbuf.buf[0 .. 1 + inner.len], .omit = false };
    }

    // varchar(N) → sN
    if (std.mem.startsWith(u8, t, "varchar(") and std.mem.endsWith(u8, t, ")")) {
        const inner = std.mem.trim(u8, t[8 .. t.len - 1], " ");
        const sbuf = struct {
            var buf: [16]u8 = undefined;
        };
        sbuf.buf[0] = 's';
        for (inner, 0..) |ch, i| sbuf.buf[i + 1] = ch;
        return .{ .tps = sbuf.buf[0 .. 1 + inner.len], .omit = false };
    }

    // ENUM(...) → pass through
    if (std.mem.startsWith(u8, t, "ENUM(") or std.mem.startsWith(u8, t, "enum("))
        return .{ .tps = t, .omit = false };

    return .{ .tps = t, .omit = false };
}

// ─── SQLite Reverse Lookup ────────────────────────────────────

fn reverseLookupSqlite(t: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool) ReverseResult {
    // Normalize to uppercase for case-insensitive comparison
    var upper_buf: [64]u8 = undefined;
    const upper_t = if (t.len <= upper_buf.len) blk: {
        for (t, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
        break :blk upper_buf[0..t.len];
    } else t;

    // Parameterized types: varchar(N) → sN, numeric(P,S) → P,S
    if (std.mem.startsWith(u8, upper_t, "VARCHAR(") and std.mem.endsWith(u8, upper_t, ")")) {
        const inner = std.mem.trim(u8, t[8 .. t.len - 1], " ");
        if (std.mem.eql(u8, inner, "255"))
            return .{ .tps = "s", .omit = canOmitType(col_name, "s", is_auto_inc, is_default_ts), .confidence = .high };
        const sbuf = struct {
            var buf: [16]u8 = undefined;
        };
        sbuf.buf[0] = 's';
        for (inner, 0..) |ch, i| sbuf.buf[i + 1] = ch;
        return .{ .tps = sbuf.buf[0 .. 1 + inner.len], .omit = false, .confidence = .high };
    }
    if (std.mem.startsWith(u8, upper_t, "NUMERIC(") and std.mem.endsWith(u8, upper_t, ")")) {
        return .{ .tps = t[8 .. t.len - 1], .omit = false, .confidence = .high };
    }

    // Check against REVERSE_MAP SQLite entries
    var found_tps: ?[]const u8 = null;
    for (REVERSE_MAP) |m| {
        if (std.mem.eql(u8, upper_t, m.sqlite)) {
            found_tps = m.tps;
            break;
        }
    }

    if (found_tps) |tps| {
        // Single-result types: BLOB, REAL — no ambiguity
        if (std.mem.eql(u8, tps, "B") or std.mem.eql(u8, tps, "real") or
            std.mem.eql(u8, tps, "float4") or std.mem.eql(u8, tps, "float8"))
        {
            return .{ .tps = tps, .omit = canOmitType(col_name, tps, is_auto_inc, is_default_ts), .confidence = .high };
        }

        // INTEGER group (n, N, b) — disambiguate with heuristics
        if (std.mem.eql(u8, upper_t, "INTEGER")) {
            if (is_auto_inc) return .{ .tps = "n", .omit = false, .confidence = .high };
            if (col_name.len > 3 and std.mem.endsWith(u8, col_name, "_id"))
                return .{ .tps = "n", .omit = canOmitType(col_name, "n", is_auto_inc, is_default_ts), .confidence = .high };
            if (isBooleanColumnName(col_name))
                return .{ .tps = "b", .omit = canOmitType(col_name, "b", is_auto_inc, is_default_ts), .confidence = .medium };
            return .{ .tps = "n", .omit = canOmitType(col_name, "n", is_auto_inc, is_default_ts), .confidence = .low };
        }

        // NUMERIC group (m, M) — m is most common
        if (std.mem.eql(u8, upper_t, "NUMERIC")) {
            return .{ .tps = "m", .omit = canOmitType(col_name, "m", is_auto_inc, is_default_ts), .confidence = .high };
        }

        // TEXT group (s, S, j, d, t) — disambiguate with heuristics
        if (std.mem.eql(u8, upper_t, "TEXT")) {
            if (col_name.len > 3 and std.mem.endsWith(u8, col_name, "_at"))
                return .{ .tps = "t", .omit = canOmitType(col_name, "t", is_auto_inc, is_default_ts), .confidence = .high };
            if (col_name.len > 3 and std.mem.endsWith(u8, col_name, "_on"))
                return .{ .tps = "d", .omit = canOmitType(col_name, "d", is_auto_inc, is_default_ts), .confidence = .high };
            if (is_default_ts)
                return .{ .tps = "t", .omit = canOmitType(col_name, "t", is_auto_inc, is_default_ts), .confidence = .high };
            if (isJsonColumnName(col_name))
                return .{ .tps = "j", .omit = canOmitType(col_name, "j", is_auto_inc, is_default_ts), .confidence = .medium };
            if (isTextColumnName(col_name))
                return .{ .tps = "S", .omit = canOmitType(col_name, "S", is_auto_inc, is_default_ts), .confidence = .medium };
            return .{ .tps = "s", .omit = canOmitType(col_name, "s", is_auto_inc, is_default_ts), .confidence = .low };
        }
    }

    // Fallback: return as-is (unknown type)
    return .{ .tps = t, .omit = false, .confidence = .low };
}

// ─── SQLite column name heuristics (re-exports from sqlite_hints) ──

const isBooleanColumnName = sqlite_hints.isBooleanColumnName;
const isJsonColumnName = sqlite_hints.isJsonColumnName;
const isTextColumnName = sqlite_hints.isTextColumnName;

// ─── Helper: can omit type symbol in .tps output ─────────────

pub fn canOmitType(col_name: []const u8, tps_symbol: []const u8, is_auto_inc: bool, is_default_ts: bool) bool {
    if (is_auto_inc or is_default_ts) return false;
    if (col_name.len > 3) {
        if (std.mem.endsWith(u8, col_name, "_id") and std.mem.eql(u8, tps_symbol, "n")) return true;
        if (std.mem.endsWith(u8, col_name, "_on") and std.mem.eql(u8, tps_symbol, "d")) return true;
        if (std.mem.endsWith(u8, col_name, "_at") and std.mem.eql(u8, tps_symbol, "t")) return true;
    }
    return std.mem.eql(u8, tps_symbol, "s");
}

// ─── Helper: classify SQL type strings (re-exports from sqlite_hints) ──

pub const isDatetimeSqlType = sqlite_hints.isDatetimeSqlType;
pub const isCurrentTimestamp = sqlite_hints.isCurrentTimestamp;

// ─── Semantic Equivalence ────────────────────────────────────
// Two SQL types are semantically equivalent if they map to the same
// TPS symbol. Used by diff to distinguish dialect noise from real changes.

pub fn semanticEquiv(a_sql_type: []const u8, a_col_name: []const u8, a_dialect: Dialect, b_sql_type: []const u8, b_col_name: []const u8, b_dialect: Dialect) bool {
    const a_tps = reverseLookup(a_sql_type, a_col_name, false, false, a_dialect).tps;
    const b_tps = reverseLookup(b_sql_type, b_col_name, false, false, b_dialect).tps;
    return std.mem.eql(u8, a_tps, b_tps);
}

// ─── Tests ────────────────────────────────────────────────────

const testing = std.testing;

test "reverse: int maps to n" {
    const r = reverseLookup("int", "col", false, false, .mysql);
    try testing.expectEqualStrings("int", r.tps);
}

test "reverse: varchar(255) maps to s" {
    const r = reverseLookup("varchar(255)", "col", false, false, .mysql);
    try testing.expectEqualStrings("s", r.tps);
}

test "reverse: varchar(128) maps to s128" {
    const r = reverseLookup("varchar(128)", "col", false, false, .mysql);
    try testing.expectEqualStrings("s128", r.tps);
}

test "reverse: decimal(16, 2) maps to 16,2" {
    const r = reverseLookup("decimal(16, 2)", "col", false, false, .mysql);
    try testing.expectEqualStrings("16,2", r.tps);
}

test "reverse: numeric(16, 2) maps to 16,2" {
    const r = reverseLookup("numeric(16, 2)", "col", false, false, .pg);
    try testing.expectEqualStrings("16,2", r.tps);
}

test "reverse: ENUM(...) passes through" {
    const r = reverseLookup("ENUM('M', 'F')", "col", false, false, .mysql);
    try testing.expectEqualStrings("ENUM('M', 'F')", r.tps);
}

test "reverse: tinyint maps to n" {
    const r = reverseLookup("tinyint", "col", false, false, .mysql);
    try testing.expectEqualStrings("n", r.tps);
}

test "canOmitType: _id suffix with n omits" {
    try testing.expect(canOmitType("user_id", "n", false, false));
}

test "canOmitType: _at suffix with t omits" {
    try testing.expect(canOmitType("created_at", "t", false, false));
}

test "canOmitType: _on suffix with d omits" {
    try testing.expect(canOmitType("deleted_on", "d", false, false));
}

test "canOmitType: s always omits" {
    try testing.expect(canOmitType("name", "s", false, false));
}

test "canOmitType: auto_inc prevents omission" {
    try testing.expect(!canOmitType("user_id", "n", true, false));
}

test "canOmitType: non-matching suffix does not omit" {
    try testing.expect(!canOmitType("user_name", "n", false, false));
}

test "isDatetimeSqlType: datetime is datetime" {
    try testing.expect(isDatetimeSqlType("datetime"));
}

test "isDatetimeSqlType: timestamp is datetime" {
    try testing.expect(isDatetimeSqlType("timestamp"));
}

test "isDatetimeSqlType: int is not datetime" {
    try testing.expect(!isDatetimeSqlType("int"));
}

test "isCurrentTimestamp: CURRENT_TIMESTAMP" {
    try testing.expect(isCurrentTimestamp("CURRENT_TIMESTAMP"));
}

test "isCurrentTimestamp: now()" {
    try testing.expect(isCurrentTimestamp("now()"));
}

test "isCurrentTimestamp: random string" {
    try testing.expect(!isCurrentTimestamp("2024-01-01"));
}

// ─── SQLite reverse tests ──────────────────────────────────────

test "reverse sqlite: INTEGER + auto_increment maps to n" {
    const r = reverseLookup("INTEGER", "id", true, false, .sqlite);
    try testing.expectEqualStrings("n", r.tps);
    try testing.expect(!r.omit);
}

test "reverse sqlite: INTEGER + _id suffix maps to n with omit" {
    const r = reverseLookup("INTEGER", "user_id", false, false, .sqlite);
    try testing.expectEqualStrings("n", r.tps);
    try testing.expect(r.omit);
}

test "reverse sqlite: INTEGER bare maps to n" {
    const r = reverseLookup("INTEGER", "count", false, false, .sqlite);
    try testing.expectEqualStrings("n", r.tps);
}

test "reverse sqlite: lowercase integer maps to n" {
    const r = reverseLookup("integer", "status", false, false, .sqlite);
    try testing.expectEqualStrings("n", r.tps);
}

test "reverse sqlite: NUMERIC maps to m" {
    const r = reverseLookup("NUMERIC", "balance", false, false, .sqlite);
    try testing.expectEqualStrings("m", r.tps);
}

test "reverse sqlite: TEXT + _at suffix maps to t with omit" {
    const r = reverseLookup("TEXT", "created_at", false, false, .sqlite);
    try testing.expectEqualStrings("t", r.tps);
    try testing.expect(r.omit);
}

test "reverse sqlite: TEXT + _on suffix maps to d with omit" {
    const r = reverseLookup("TEXT", "birth_on", false, false, .sqlite);
    try testing.expectEqualStrings("d", r.tps);
    try testing.expect(r.omit);
}

test "reverse sqlite: TEXT + is_default_ts maps to t" {
    const r = reverseLookup("TEXT", "created_at", false, true, .sqlite);
    try testing.expectEqualStrings("t", r.tps);
    try testing.expect(!r.omit);
}

test "reverse sqlite: TEXT bare maps to s with omit" {
    const r = reverseLookup("TEXT", "name", false, false, .sqlite);
    try testing.expectEqualStrings("s", r.tps);
    try testing.expect(r.omit);
}

test "reverse sqlite: BLOB maps to B" {
    const r = reverseLookup("BLOB", "data", false, false, .sqlite);
    try testing.expectEqualStrings("B", r.tps);
}

test "reverse sqlite: INTEGER + is_ prefix maps to b" {
    const r = reverseLookup("INTEGER", "is_admin", false, false, .sqlite);
    try testing.expectEqualStrings("b", r.tps);
}

test "reverse sqlite: INTEGER + has_ prefix maps to b" {
    const r = reverseLookup("INTEGER", "has_permission", false, false, .sqlite);
    try testing.expectEqualStrings("b", r.tps);
}

test "reverse sqlite: INTEGER + can_ prefix maps to b" {
    const r = reverseLookup("INTEGER", "can_edit", false, false, .sqlite);
    try testing.expectEqualStrings("b", r.tps);
}

test "reverse sqlite: TEXT + settings maps to j" {
    const r = reverseLookup("TEXT", "settings", false, false, .sqlite);
    try testing.expectEqualStrings("j", r.tps);
}

test "reverse sqlite: TEXT + metadata maps to j" {
    const r = reverseLookup("TEXT", "metadata", false, false, .sqlite);
    try testing.expectEqualStrings("j", r.tps);
}

test "reverse sqlite: TEXT + extra_data maps to j" {
    const r = reverseLookup("TEXT", "extra_data", false, false, .sqlite);
    try testing.expectEqualStrings("j", r.tps);
}

test "reverse sqlite: TEXT + description maps to S" {
    const r = reverseLookup("TEXT", "description", false, false, .sqlite);
    try testing.expectEqualStrings("S", r.tps);
}

test "reverse sqlite: TEXT + note maps to S" {
    const r = reverseLookup("TEXT", "note", false, false, .sqlite);
    try testing.expectEqualStrings("S", r.tps);
}

test "reverse sqlite: TEXT + content maps to S" {
    const r = reverseLookup("TEXT", "content", false, false, .sqlite);
    try testing.expectEqualStrings("S", r.tps);
}

// ─── semanticEquiv tests ─────────────────────────────────────

test "semanticEquiv: MySQL int ↔ PG integer → true" {
    try testing.expect(semanticEquiv("int", "id", .mysql, "integer", "id", .pg));
}

test "semanticEquiv: MySQL int ↔ PG bigint → false" {
    try testing.expect(!semanticEquiv("int", "id", .mysql, "bigint", "id", .pg));
}

test "semanticEquiv: MySQL datetime ↔ PG timestamp → true" {
    try testing.expect(semanticEquiv("datetime", "created_at", .mysql, "timestamp", "created_at", .pg));
}

test "semanticEquiv: MySQL blob ↔ PG bytea → true" {
    try testing.expect(semanticEquiv("blob", "data", .mysql, "bytea", "data", .pg));
}

test "semanticEquiv: MySQL boolean ↔ PG boolean → true (same name)" {
    try testing.expect(semanticEquiv("boolean", "flag", .mysql, "boolean", "flag", .pg));
}

test "semanticEquiv: MySQL tinyint ↔ PG smallint → true (both → n)" {
    try testing.expect(semanticEquiv("tinyint", "age", .mysql, "smallint", "age", .pg));
}

test "semanticEquiv: MySQL text ↔ PG text → true" {
    try testing.expect(semanticEquiv("text", "bio", .mysql, "text", "bio", .pg));
}

test "semanticEquiv: MySQL int ↔ SQLite INTEGER → true" {
    try testing.expect(semanticEquiv("int", "id", .mysql, "INTEGER", "id", .sqlite));
}

test "semanticEquiv: MySQL varchar(255) ↔ PG varchar → true (both → s)" {
    try testing.expect(semanticEquiv("varchar(255)", "name", .mysql, "varchar", "name", .pg));
}
