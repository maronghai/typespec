const std = @import("std");
const data = @import("reverse_map_data.zig");
const dialect_mod = @import("dialect.zig");
const dialect_enum = @import("dialect_enum.zig");
const sqlite_hints = @import("sqlite_hints.zig");

pub const Dialect = dialect_enum.Dialect;
pub const ReverseMapping = data.ReverseMapping;
pub const REVERSE_MAP = data.REVERSE_MAP;
pub const ReverseResult = dialect_mod.ReverseResult;
pub const canOmitType = dialect_mod.canOmitType;

/// Reverse-lookup a SQL type string to its TPS symbol.
/// Handles exact match from REVERSE_MAP + parameterized types (int(N), decimal(P,S), varchar(N)).
/// For dialects with a vtable reverseLookup (e.g. SQLite), delegates to the backend.
pub fn reverseLookup(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool, dialect: Dialect) ReverseResult {
    const t = std.mem.trim(u8, sql_type, " \t");

    // Check if dialect has a custom reverse lookup (e.g. SQLite)
    const backend = dialect_mod.getBackend(dialect);
    if (backend.reverseLookup) |customLookup| {
        if (customLookup(t, col_name, is_auto_inc, is_default_ts)) |result| {
            return result;
        }
    }

    // General path: MySQL/PG exact match from REVERSE_MAP + parameterized types
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

// ─── Helper: classify SQL type strings (re-exports from sqlite_hints) ──

pub const isDatetimeSqlType = sqlite_hints.isDatetimeSqlType;
pub const isCurrentTimestamp = sqlite_hints.isCurrentTimestamp;

// ─── Semantic Equivalence ────────────────────────────────────

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

// ─── Score tests ────────────────────────────────────────────────

test "score: MySQL exact match returns 100" {
    const r = reverseLookup("int", "id", false, false, .mysql);
    try testing.expectEqual(@as(u8, 100), r.score);
}

test "score: parameterized type returns 100" {
    const r = reverseLookup("varchar(128)", "col", false, false, .mysql);
    try testing.expectEqual(@as(u8, 100), r.score);
}

test "score: SQLite INTEGER with _id suffix returns 100" {
    const r = reverseLookup("INTEGER", "user_id", false, false, .sqlite);
    try testing.expectEqual(@as(u8, 100), r.score);
}

test "score: SQLite INTEGER with boolean column name returns 80" {
    const r = reverseLookup("INTEGER", "is_active", false, false, .sqlite);
    try testing.expectEqual(@as(u8, 80), r.score);
}

test "score: SQLite INTEGER fallback returns 50" {
    const r = reverseLookup("INTEGER", "some_col", false, false, .sqlite);
    try testing.expectEqual(@as(u8, 50), r.score);
}

test "score: SQLite TEXT with _at suffix returns 100" {
    const r = reverseLookup("TEXT", "created_at", false, false, .sqlite);
    try testing.expectEqual(@as(u8, 100), r.score);
}

test "score: SQLite TEXT with json column name returns 80" {
    const r = reverseLookup("TEXT", "settings", false, false, .sqlite);
    try testing.expectEqual(@as(u8, 80), r.score);
}

test "score: SQLite TEXT fallback returns 50" {
    const r = reverseLookup("TEXT", "some_col", false, false, .sqlite);
    try testing.expectEqual(@as(u8, 50), r.score);
}
