const std = @import("std");

// ─── SQLite Column Name Heuristics ──────────────────────────────
// Used by type_map.zig reverseLookupSqlite and reverse_codegen.zig
// to disambiguate SQLite's lossy type affinity system.
//
// All rules are data-driven via COLUMN_RULES table.
// To add a new hint: add one rule entry to COLUMN_RULES.

pub const SqlHintType = enum { boolean, json, text };

pub const MatchKind = enum { prefix, suffix, exact };

pub const ColumnRule = struct {
    pattern: []const u8,
    kind: MatchKind,
    hint: SqlHintType,
};

/// Canonical rule table. Add new hints here — no code changes needed.
pub const COLUMN_RULES = [_]ColumnRule{
    // Boolean patterns
    .{ .pattern = "is_", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "has_", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "can_", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "should_", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "was_", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "did_", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "enable", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "active", .kind = .prefix, .hint = .boolean },
    .{ .pattern = "deleted", .kind = .exact, .hint = .boolean },
    .{ .pattern = "is_deleted", .kind = .exact, .hint = .boolean },
    .{ .pattern = "is_removed", .kind = .exact, .hint = .boolean },
    .{ .pattern = "is_enabled", .kind = .exact, .hint = .boolean },
    .{ .pattern = "is_active", .kind = .exact, .hint = .boolean },
    .{ .pattern = "is_valid", .kind = .exact, .hint = .boolean },
    // JSON patterns
    .{ .pattern = "settings", .kind = .exact, .hint = .json },
    .{ .pattern = "data", .kind = .exact, .hint = .json },
    .{ .pattern = "metadata", .kind = .exact, .hint = .json },
    .{ .pattern = "config", .kind = .exact, .hint = .json },
    .{ .pattern = "extra", .kind = .exact, .hint = .json },
    .{ .pattern = "params", .kind = .exact, .hint = .json },
    .{ .pattern = "options", .kind = .exact, .hint = .json },
    .{ .pattern = "json", .kind = .exact, .hint = .json },
    .{ .pattern = "props", .kind = .exact, .hint = .json },
    .{ .pattern = "attrs", .kind = .exact, .hint = .json },
    .{ .pattern = "properties", .kind = .exact, .hint = .json },
    .{ .pattern = "_json", .kind = .suffix, .hint = .json },
    .{ .pattern = "_data", .kind = .suffix, .hint = .json },
    .{ .pattern = "_meta", .kind = .suffix, .hint = .json },
    .{ .pattern = "_config", .kind = .suffix, .hint = .json },
    .{ .pattern = "_settings", .kind = .suffix, .hint = .json },
    .{ .pattern = "_extra", .kind = .suffix, .hint = .json },
    .{ .pattern = "_options", .kind = .suffix, .hint = .json },
    // Text patterns
    .{ .pattern = "description", .kind = .exact, .hint = .text },
    .{ .pattern = "content", .kind = .exact, .hint = .text },
    .{ .pattern = "note", .kind = .exact, .hint = .text },
    .{ .pattern = "notes", .kind = .exact, .hint = .text },
    .{ .pattern = "bio", .kind = .exact, .hint = .text },
    .{ .pattern = "summary", .kind = .exact, .hint = .text },
    .{ .pattern = "body", .kind = .exact, .hint = .text },
    .{ .pattern = "text", .kind = .exact, .hint = .text },
    .{ .pattern = "detail", .kind = .exact, .hint = .text },
    .{ .pattern = "remark", .kind = .exact, .hint = .text },
    .{ .pattern = "remarks", .kind = .exact, .hint = .text },
    .{ .pattern = "message", .kind = .exact, .hint = .text },
    .{ .pattern = "memo", .kind = .exact, .hint = .text },
    .{ .pattern = "address", .kind = .exact, .hint = .text },
    .{ .pattern = "_desc", .kind = .suffix, .hint = .text },
    .{ .pattern = "_text", .kind = .suffix, .hint = .text },
    .{ .pattern = "_content", .kind = .suffix, .hint = .text },
    .{ .pattern = "_note", .kind = .suffix, .hint = .text },
    .{ .pattern = "_body", .kind = .suffix, .hint = .text },
    .{ .pattern = "_remark", .kind = .suffix, .hint = .text },
};

/// Match a column name against a single rule.
fn matchRule(name: []const u8, rule: ColumnRule) bool {
    return switch (rule.kind) {
        .prefix => std.mem.startsWith(u8, name, rule.pattern),
        .suffix => std.mem.endsWith(u8, name, rule.pattern),
        .exact => std.mem.eql(u8, name, rule.pattern),
    };
}

/// Look up the SQLite hint type for a column name.
/// Returns null if no rule matches.
pub fn lookupHint(name: []const u8) ?SqlHintType {
    for (&COLUMN_RULES) |rule| {
        if (matchRule(name, rule)) return rule.hint;
    }
    return null;
}

/// Score a column name against SQLite hint rules.
/// Returns the hint type and a confidence score (0-100).
/// Higher score = more certain match. Exact matches score higher than prefix/suffix.
pub fn scoreColumnName(name: []const u8) ?struct { hint: SqlHintType, score: u8 } {
    for (&COLUMN_RULES) |rule| {
        if (matchRule(name, rule)) {
            const score: u8 = switch (rule.kind) {
                .exact => 90,
                .prefix => 85,
                .suffix => 85,
            };
            return .{ .hint = rule.hint, .score = score };
        }
    }
    return null;
}

/// Boolean column name patterns (delegates to lookup table).
pub fn isBooleanColumnName(name: []const u8) bool {
    return lookupHint(name) == .boolean;
}

/// JSON column name patterns (delegates to lookup table).
pub fn isJsonColumnName(name: []const u8) bool {
    return lookupHint(name) == .json;
}

/// Long text column name patterns (delegates to lookup table).
pub fn isTextColumnName(name: []const u8) bool {
    return lookupHint(name) == .text;
}

/// Check if a SQL type string is a datetime/timestamp type.
pub fn isDatetimeSqlType(sql_type: []const u8) bool {
    const t = std.mem.trim(u8, sql_type, " \t");
    return std.mem.eql(u8, t, "datetime") or std.mem.eql(u8, t, "timestamp") or
        std.mem.eql(u8, t, "timestamp without time zone") or
        std.mem.eql(u8, t, "timestamp with time zone");
}

/// Check if a default value represents CURRENT_TIMESTAMP.
pub fn isCurrentTimestamp(dv: []const u8) bool {
    return std.mem.eql(u8, dv, "CURRENT_TIMESTAMP") or std.mem.eql(u8, dv, "now()");
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

test "hints: boolean column names" {
    try testing.expect(isBooleanColumnName("is_active"));
    try testing.expect(isBooleanColumnName("has_data"));
    try testing.expect(isBooleanColumnName("can_edit"));
    try testing.expect(isBooleanColumnName("should_notify"));
    try testing.expect(isBooleanColumnName("was_deleted"));
    try testing.expect(isBooleanColumnName("did_migrate"));
    try testing.expect(isBooleanColumnName("enabled"));
    try testing.expect(isBooleanColumnName("active"));
    try testing.expect(isBooleanColumnName("deleted"));
    try testing.expect(!isBooleanColumnName("name"));
    try testing.expect(!isBooleanColumnName("description"));
}

test "hints: json column names" {
    try testing.expect(isJsonColumnName("settings"));
    try testing.expect(isJsonColumnName("data"));
    try testing.expect(isJsonColumnName("metadata"));
    try testing.expect(isJsonColumnName("config_json"));
    try testing.expect(isJsonColumnName("user_settings"));
    try testing.expect(isJsonColumnName("extra_options"));
    try testing.expect(!isJsonColumnName("name"));
    try testing.expect(!isJsonColumnName("is_active"));
}

test "hints: text column names" {
    try testing.expect(isTextColumnName("description"));
    try testing.expect(isTextColumnName("content"));
    try testing.expect(isTextColumnName("bio"));
    try testing.expect(isTextColumnName("long_text"));
    try testing.expect(isTextColumnName("body_content"));
    try testing.expect(!isTextColumnName("name"));
    try testing.expect(!isTextColumnName("is_active"));
}

test "hints: lookupHint returns correct type" {
    try testing.expectEqual(SqlHintType.boolean, lookupHint("is_active").?);
    try testing.expectEqual(SqlHintType.json, lookupHint("settings").?);
    try testing.expectEqual(SqlHintType.text, lookupHint("description").?);
    try testing.expect(lookupHint("name") == null);
}

test "hints: datetime and timestamp" {
    try testing.expect(isDatetimeSqlType("datetime"));
    try testing.expect(isDatetimeSqlType("timestamp"));
    try testing.expect(isDatetimeSqlType("timestamp without time zone"));
    try testing.expect(isDatetimeSqlType(" timestamp "));
    try testing.expect(!isDatetimeSqlType("date"));
    try testing.expect(!isDatetimeSqlType("text"));
}

test "hints: current timestamp" {
    try testing.expect(isCurrentTimestamp("CURRENT_TIMESTAMP"));
    try testing.expect(isCurrentTimestamp("now()"));
    try testing.expect(!isCurrentTimestamp("2024-01-01"));
    try testing.expect(!isCurrentTimestamp("NULL"));
}

test "scoreColumnName: exact match scores higher than prefix" {
    const exact = scoreColumnName("is_active").?;
    try testing.expectEqual(SqlHintType.boolean, exact.hint);
    try testing.expect(exact.score >= 90);

    const prefix = scoreColumnName("is_verified").?;
    try testing.expectEqual(SqlHintType.boolean, prefix.hint);
    try testing.expect(prefix.score >= 85);
    try testing.expect(prefix.score < exact.score);
}

test "scoreColumnName: unknown column returns null" {
    try testing.expect(scoreColumnName("some_random_col") == null);
}
