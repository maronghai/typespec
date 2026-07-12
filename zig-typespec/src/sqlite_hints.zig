// ─── SQLite Column Name Heuristics ──────────────────────────────
// Used by type_map.zig reverseLookupSqlite and reverse_codegen.zig
// to disambiguate SQLite's lossy type affinity system.

/// Boolean column name patterns: is_*, has_*, can_*, etc.
pub fn isBooleanColumnName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "is_") or
        std.mem.startsWith(u8, name, "has_") or
        std.mem.startsWith(u8, name, "can_") or
        std.mem.startsWith(u8, name, "should_") or
        std.mem.startsWith(u8, name, "was_") or
        std.mem.startsWith(u8, name, "did_") or
        std.mem.startsWith(u8, name, "enable") or
        std.mem.startsWith(u8, name, "active") or
        std.mem.eql(u8, name, "deleted") or
        std.mem.eql(u8, name, "is_deleted") or
        std.mem.eql(u8, name, "is_removed") or
        std.mem.eql(u8, name, "is_enabled") or
        std.mem.eql(u8, name, "is_active") or
        std.mem.eql(u8, name, "is_valid");
}

/// JSON column name patterns: settings, data, metadata, etc.
pub fn isJsonColumnName(name: []const u8) bool {
    return std.mem.eql(u8, name, "settings") or
        std.mem.eql(u8, name, "data") or
        std.mem.eql(u8, name, "metadata") or
        std.mem.eql(u8, name, "config") or
        std.mem.eql(u8, name, "extra") or
        std.mem.eql(u8, name, "params") or
        std.mem.eql(u8, name, "options") or
        std.mem.eql(u8, name, "json") or
        std.mem.eql(u8, name, "props") or
        std.mem.eql(u8, name, "attrs") or
        std.mem.eql(u8, name, "properties") or
        std.mem.endsWith(u8, name, "_json") or
        std.mem.endsWith(u8, name, "_data") or
        std.mem.endsWith(u8, name, "_meta") or
        std.mem.endsWith(u8, name, "_config") or
        std.mem.endsWith(u8, name, "_settings") or
        std.mem.endsWith(u8, name, "_extra") or
        std.mem.endsWith(u8, name, "_options");
}

/// Long text column name patterns: description, content, note, etc.
pub fn isTextColumnName(name: []const u8) bool {
    return std.mem.eql(u8, name, "description") or
        std.mem.eql(u8, name, "content") or
        std.mem.eql(u8, name, "note") or
        std.mem.eql(u8, name, "notes") or
        std.mem.eql(u8, name, "bio") or
        std.mem.eql(u8, name, "summary") or
        std.mem.eql(u8, name, "body") or
        std.mem.eql(u8, name, "text") or
        std.mem.eql(u8, name, "detail") or
        std.mem.eql(u8, name, "remark") or
        std.mem.eql(u8, name, "remarks") or
        std.mem.eql(u8, name, "message") or
        std.mem.eql(u8, name, "memo") or
        std.mem.eql(u8, name, "address") or
        std.mem.endsWith(u8, name, "_desc") or
        std.mem.endsWith(u8, name, "_text") or
        std.mem.endsWith(u8, name, "_content") or
        std.mem.endsWith(u8, name, "_note") or
        std.mem.endsWith(u8, name, "_body") or
        std.mem.endsWith(u8, name, "_remark");
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

const std = @import("std");
