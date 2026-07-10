const std = @import("std");
const ast_mod = @import("ast.zig");
const TypeInfo = ast_mod.TypeInfo;

// ─── Unified Type Mapping ────────────────────────────────────
//
// Single source of truth for tps ↔ SQL type mappings.
// Used by codegen (forward), reverse_codegen (reverse), and migrate.

pub const Dialect = enum { mysql, postgres };

pub const TypeMapping = struct {
    tps: []const u8,
    mysql: []const u8,
    pg: []const u8,
    /// Reverse-match priority: lower = preferred when multiple SQL types map to same TPS.
    /// Higher-priority entries (lower number) are checked first.
    rev_priority: u32 = 0,
};

/// All single-char and known multi-char type mappings.
/// Single-char entries (len(tps)==1) are the primary forward mappings.
/// Multi-char entries (e.g. "tinyint", "bytea") are reverse-only (not emitted by forward path).
pub const TYPE_TABLE = [_]TypeMapping{
    // ─── Core single-char symbols (forward + reverse) ───
    .{ .tps = "n", .mysql = "int", .pg = "integer", .rev_priority = 10 },
    .{ .tps = "N", .mysql = "bigint", .pg = "bigint", .rev_priority = 10 },
    .{ .tps = "m", .mysql = "decimal(16, 2)", .pg = "numeric(16, 2)", .rev_priority = 10 },
    .{ .tps = "M", .mysql = "decimal(20, 6)", .pg = "numeric(20, 6)", .rev_priority = 10 },
    .{ .tps = "S", .mysql = "text", .pg = "text", .rev_priority = 10 },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .rev_priority = 10 },
    .{ .tps = "B", .mysql = "blob", .pg = "bytea", .rev_priority = 10 },
    .{ .tps = "j", .mysql = "json", .pg = "json", .rev_priority = 10 },
    .{ .tps = "d", .mysql = "date", .pg = "date", .rev_priority = 10 },
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .rev_priority = 10 },

    // ─── MySQL integer variants → reverse to "n" ───
    .{ .tps = "n", .mysql = "tinyint", .pg = "smallint", .rev_priority = 20 },
    .{ .tps = "n", .mysql = "smallint", .pg = "smallint", .rev_priority = 20 },
    .{ .tps = "n", .mysql = "mediumint", .pg = "integer", .rev_priority = 20 },

    // ─── MySQL BLOB/TEXT variants ───
    .{ .tps = "B", .mysql = "tinyblob", .pg = "bytea", .rev_priority = 20 },
    .{ .tps = "B", .mysql = "mediumblob", .pg = "bytea", .rev_priority = 20 },
    .{ .tps = "B", .mysql = "longblob", .pg = "bytea", .rev_priority = 20 },
    .{ .tps = "s", .mysql = "tinytext", .pg = "varchar(255)", .rev_priority = 20 },
    .{ .tps = "S", .mysql = "mediumtext", .pg = "text", .rev_priority = 20 },
    .{ .tps = "S", .mysql = "longtext", .pg = "text", .rev_priority = 20 },

    // ─── MySQL datetime → reverse to "t" ───
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .rev_priority = 15 },

    // ─── MySQL-specific → reverse to core types ───
    .{ .tps = "b", .mysql = "bit(1)", .pg = "boolean", .rev_priority = 15 },
    .{ .tps = "m", .mysql = "decimal(16,2)", .pg = "numeric(16, 2)", .rev_priority = 15 },
    .{ .tps = "M", .mysql = "decimal(20,6)", .pg = "numeric(20, 6)", .rev_priority = 15 },

    // ─── PostgreSQL types → reverse to core types ───
    .{ .tps = "n", .mysql = "serial", .pg = "serial", .rev_priority = 20 },
    .{ .tps = "N", .mysql = "bigserial", .pg = "bigserial", .rev_priority = 20 },
    .{ .tps = "m", .mysql = "numeric", .pg = "numeric", .rev_priority = 20 },
    .{ .tps = "s", .mysql = "varchar", .pg = "varchar", .rev_priority = 20 },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .rev_priority = 15 },
    .{ .tps = "j", .mysql = "jsonb", .pg = "jsonb", .rev_priority = 20 },
    .{ .tps = "t", .mysql = "timestamp", .pg = "timestamp", .rev_priority = 15 },
    .{ .tps = "t", .mysql = "timestamp without time zone", .pg = "timestamp without time zone", .rev_priority = 25 },
    .{ .tps = "t", .mysql = "timestamp with time zone", .pg = "timestamp with time zone", .rev_priority = 25 },

    // ─── Passthrough types (not in TypeSpec DSL, emitted as-is) ───
    .{ .tps = "uuid", .mysql = "uuid", .pg = "uuid" },
    .{ .tps = "real", .mysql = "real", .pg = "real" },
    .{ .tps = "float4", .mysql = "float4", .pg = "float4" },
    .{ .tps = "float8", .mysql = "float8", .pg = "float8" },
    .{ .tps = "float8", .mysql = "double precision", .pg = "double precision" },
    .{ .tps = "s", .mysql = "character", .pg = "character" },
};

// ─── Forward Mapping: TPS → SQL ──────────────────────────────

pub fn toSqlType(w: anytype, dialect: Dialect, type_info: TypeInfo) !void {
    switch (type_info) {
        .none => try w.writeAll("varchar(255)"),
        .simple => {
            const s = type_info.simple;
            if (s.len == 1) {
                // Single-char: lookup in TYPE_TABLE
                for (TYPE_TABLE) |m| {
                    if (m.tps.len == 1 and m.tps[0] == s[0]) {
                        const sql_type = switch (dialect) {
                            .mysql => m.mysql,
                            .postgres => m.pg,
                        };
                        // For PG integer, strip display width (PG ignores it)
                        if (dialect == .postgres and std.mem.startsWith(u8, sql_type, "int(")) {
                            try w.writeAll("integer");
                        } else {
                            try w.writeAll(sql_type);
                        }
                        return;
                    }
                }
                try w.writeAll(s);
            } else {
                // Multi-char: pass through (used for PG-specific types in forward path)
                try w.writeAll(s);
            }
        },
        .int_explicit => |n| {
            if (dialect == .mysql) {
                try w.print("int({d})", .{n});
            } else {
                try w.writeAll("integer");
            }
        },
        .decimal_explicit => |ds| {
            const type_name: []const u8 = switch (dialect) {
                .mysql => "decimal",
                .postgres => "numeric",
            };
            try w.print("{s}({d}, {d})", .{ type_name, ds.precision, ds.scale });
        },
        .varchar_explicit => |n| {
            if (n > 0) {
                try w.print("varchar({d})", .{n});
            } else {
                try w.writeAll("varchar(255)");
            }
        },
        .enum_type => |vals| {
            switch (dialect) {
                .mysql => {
                    try w.writeAll("ENUM(");
                    for (vals, 0..) |v, vi| {
                        if (vi > 0) try w.writeAll(", ");
                        try w.print("'{s}'", .{v});
                    }
                    try w.writeAll(")");
                },
                .postgres => {
                    try w.writeAll("text");
                },
            }
        },
    }
}

// ─── Reverse Mapping: SQL → TPS ──────────────────────────────

pub const ReverseResult = struct {
    tps: []const u8,
    omit: bool,
};

/// Reverse-lookup a SQL type string to its TPS symbol.
/// Handles exact match from TYPE_TABLE + parameterized types (int(N), decimal(P,S), varchar(N)).
pub fn reverseLookup(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool) ReverseResult {
    const t = std.mem.trim(u8, sql_type, " \t");

    // Exact match from TYPE_TABLE (skip single-char TPS entries — those are forward-only)
    var best_match: ?ReverseResult = null;
    var best_priority: u32 = std.math.maxInt(u32);
    for (TYPE_TABLE) |m| {
        if (m.tps.len <= 1) continue; // skip single-char forward entries (handled by parameterized below)
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

// ─── Helper: classify SQL type strings ───────────────────────

pub fn isDatetimeSqlType(sql_type: []const u8) bool {
    const t = std.mem.trim(u8, sql_type, " \t");
    return std.mem.eql(u8, t, "datetime") or std.mem.eql(u8, t, "timestamp") or
        std.mem.eql(u8, t, "timestamp without time zone") or
        std.mem.eql(u8, t, "timestamp with time zone");
}

pub fn isCurrentTimestamp(dv: []const u8) bool {
    return std.mem.eql(u8, dv, "CURRENT_TIMESTAMP") or std.mem.eql(u8, dv, "now()");
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
