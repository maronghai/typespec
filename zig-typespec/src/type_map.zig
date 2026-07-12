const std = @import("std");
const ast_mod = @import("ast.zig");
const TypeInfo = ast_mod.TypeInfo;

// ─── Unified Type Mapping ────────────────────────────────────
//
// Single source of truth for tps ↔ SQL type mappings.
// Used by codegen (forward), reverse_codegen (reverse), and migrate.

pub const Dialect = enum { mysql, postgres, sqlite };

pub const TypeMapping = struct {
    tps: []const u8,
    mysql: []const u8,
    pg: []const u8,
    sqlite: []const u8,
    /// Reverse-match priority: lower = preferred when multiple SQL types map to same TPS.
    /// Higher-priority entries (lower number) are checked first.
    rev_priority: u32 = 0,
};

/// All single-char and known multi-char type mappings.
/// Single-char entries (len(tps)==1) are the primary forward mappings.
/// Multi-char entries (e.g. "tinyint", "bytea") are reverse-only (not emitted by forward path).
pub const TYPE_TABLE = [_]TypeMapping{
    // ─── Core single-char symbols (forward + reverse) ───
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
                            .sqlite => m.sqlite,
                        };
                        // For PG/SQLite integer, strip display width (PG/SQLite ignore it)
                        if (dialect != .mysql and std.mem.startsWith(u8, sql_type, "int(")) {
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
                .sqlite => "NUMERIC",
            };
            try w.print("{s}({d}, {d})", .{ type_name, ds.precision, ds.scale });
        },
        .varchar_explicit => |n| {
            if (n > 0) {
                try w.print("varchar({d})", .{n});
            } else {
                try w.writeAll("TEXT");
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
                .postgres, .sqlite => {
                    try w.writeAll("TEXT");
                },
            }
        },
    }
}

// ─── Reverse Mapping: SQL → TPS ──────────────────────────────

pub const ReverseResult = struct {
    tps: []const u8,
    omit: bool,
    confidence: Confidence = .high,
};

pub const Confidence = enum {
    high, // exact match from TYPE_TABLE or parameterized type
    medium, // suffix-based inference (_id, _at, _on) or known column name pattern
    low, // heuristic guess (SQLite type ambiguity)
};

/// Reverse-lookup a SQL type string to its TPS symbol.
/// Handles exact match from TYPE_TABLE + parameterized types (int(N), decimal(P,S), varchar(N)).
pub fn reverseLookup(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool, dialect: Dialect) ReverseResult {
    const t = std.mem.trim(u8, sql_type, " \t");

    // SQLite: match against m.sqlite with case-insensitive comparison and disambiguation heuristics
    if (dialect == .sqlite) {
        return reverseLookupSqlite(t, col_name, is_auto_inc, is_default_ts);
    }

    // MySQL/PG: exact match from TYPE_TABLE (skip single-char TPS entries — those are forward-only)
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
        var sbuf: [16]u8 = undefined;
        sbuf[0] = 's';
        for (inner, 0..) |ch, i| sbuf[i + 1] = ch;
        return .{ .tps = sbuf[0 .. 1 + inner.len], .omit = false, .confidence = .high };
    }
    if (std.mem.startsWith(u8, upper_t, "NUMERIC(") and std.mem.endsWith(u8, upper_t, ")")) {
        return .{ .tps = t[8 .. t.len - 1], .omit = false, .confidence = .high };
    }

    // Check against TYPE_TABLE SQLite entries (including single-char TPS entries)
    // Collect all matching TPS candidates
    var found_tps: ?[]const u8 = null;
    for (TYPE_TABLE) |m| {
        if (std.mem.eql(u8, upper_t, m.sqlite)) {
            found_tps = m.tps;
            break; // first match is sufficient for disambiguation below
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
            // Boolean heuristic: is_*, has_*, can_*, should_*, was_*, did_* prefixes
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
            // JSON heuristic: settings, data, metadata, config, extra, params, options, etc.
            if (isJsonColumnName(col_name))
                return .{ .tps = "j", .omit = canOmitType(col_name, "j", is_auto_inc, is_default_ts), .confidence = .medium };
            // Long text heuristic: description, content, note, bio, summary, body, etc.
            if (isTextColumnName(col_name))
                return .{ .tps = "S", .omit = canOmitType(col_name, "S", is_auto_inc, is_default_ts), .confidence = .medium };
            return .{ .tps = "s", .omit = canOmitType(col_name, "s", is_auto_inc, is_default_ts), .confidence = .low };
        }
    }

    // Fallback: return as-is (unknown type)
    return .{ .tps = t, .omit = false, .confidence = .low };
}

// ─── SQLite column name heuristics ───────────────────────────

fn isBooleanColumnName(name: []const u8) bool {
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
        std.mem.eql(u8, name, "is_valid") or
        std.mem.eql(u8, name, "is_deleted");
}

fn isJsonColumnName(name: []const u8) bool {
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

fn isTextColumnName(name: []const u8) bool {
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

// ─── Tests ────────────────────────────────────────────────────

test "forward: n maps to int in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .simple = "n" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("int", result);
}

test "forward: n maps to integer in PostgreSQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .postgres, .{ .simple = "n" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("integer", result);
}

test "forward: s maps to varchar in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .simple = "s" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(255)", result);
}

test "forward: t maps to datetime in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .simple = "t" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("datetime", result);
}

test "forward: t maps to timestamp in PostgreSQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .postgres, .{ .simple = "t" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("timestamp", result);
}

test "forward: none maps to varchar(255)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .none);
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(255)", result);
}

test "forward: int_explicit(11) maps to int(11) in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .int_explicit = 11 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("int(11)", result);
}

test "forward: int_explicit(11) maps to integer in PG" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .postgres, .{ .int_explicit = 11 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("integer", result);
}

test "forward: decimal_explicit maps correctly per dialect" {
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try toSqlType(&aw.writer, .mysql, .{ .decimal_explicit = .{ .precision = 10, .scale = 2 } });
        try aw.flush();
        const out = aw.toArrayList();
        const result = try out.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("decimal(10, 2)", result);
    }
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try toSqlType(&aw.writer, .postgres, .{ .decimal_explicit = .{ .precision = 10, .scale = 2 } });
        try aw.flush();
        const out = aw.toArrayList();
        const result = try out.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("numeric(10, 2)", result);
    }
}

test "forward: varchar_explicit(128) maps to varchar(128)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .varchar_explicit = 128 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(128)", result);
}

test "forward: varchar_explicit(0) maps to varchar(255)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .varchar_explicit = 0 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(255)", result);
}

test "forward: varchar_explicit maps to varchar(N) in SQLite" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .sqlite, .{ .varchar_explicit = 128 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(128)", result);
}

test "forward: enum_type maps to ENUM in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const vals = [_][]const u8{ "M", "F", "X" };
    try toSqlType(&aw.writer, .mysql, .{ .enum_type = &vals });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ENUM('M', 'F', 'X')", result);
}

test "forward: enum_type maps to TEXT in PostgreSQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const vals = [_][]const u8{ "M", "F" };
    try toSqlType(&aw.writer, .postgres, .{ .enum_type = &vals });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("TEXT", result);
}

test "reverse: int maps to n" {
    const r = reverseLookup("int", "col", false, false, .mysql);
    try std.testing.expectEqualStrings("int", r.tps);
    // "int" is a multi-char entry, should match
}

test "reverse: varchar(255) maps to s" {
    const r = reverseLookup("varchar(255)", "col", false, false, .mysql);
    try std.testing.expectEqualStrings("s", r.tps);
}

test "reverse: varchar(128) maps to s128" {
    const r = reverseLookup("varchar(128)", "col", false, false, .mysql);
    try std.testing.expectEqualStrings("s128", r.tps);
}

test "reverse: decimal(16, 2) maps to 16,2" {
    const r = reverseLookup("decimal(16, 2)", "col", false, false, .mysql);
    try std.testing.expectEqualStrings("16,2", r.tps);
}

test "reverse: numeric(16, 2) maps to 16,2" {
    const r = reverseLookup("numeric(16, 2)", "col", false, false, .postgres);
    try std.testing.expectEqualStrings("16,2", r.tps);
}

test "reverse: ENUM(...) passes through" {
    const r = reverseLookup("ENUM('M', 'F')", "col", false, false, .mysql);
    try std.testing.expectEqualStrings("ENUM('M', 'F')", r.tps);
}

test "reverse: tinyint maps to n" {
    const r = reverseLookup("tinyint", "col", false, false, .mysql);
    try std.testing.expectEqualStrings("n", r.tps);
}

test "canOmitType: _id suffix with n omits" {
    try std.testing.expect(canOmitType("user_id", "n", false, false));
}

test "canOmitType: _at suffix with t omits" {
    try std.testing.expect(canOmitType("created_at", "t", false, false));
}

test "canOmitType: _on suffix with d omits" {
    try std.testing.expect(canOmitType("deleted_on", "d", false, false));
}

test "canOmitType: s always omits" {
    try std.testing.expect(canOmitType("name", "s", false, false));
}

test "canOmitType: auto_inc prevents omission" {
    try std.testing.expect(!canOmitType("user_id", "n", true, false));
}

test "canOmitType: non-matching suffix does not omit" {
    try std.testing.expect(!canOmitType("user_name", "n", false, false));
}

test "isDatetimeSqlType: datetime is datetime" {
    try std.testing.expect(isDatetimeSqlType("datetime"));
}

test "isDatetimeSqlType: timestamp is datetime" {
    try std.testing.expect(isDatetimeSqlType("timestamp"));
}

test "isDatetimeSqlType: int is not datetime" {
    try std.testing.expect(!isDatetimeSqlType("int"));
}

test "isCurrentTimestamp: CURRENT_TIMESTAMP" {
    try std.testing.expect(isCurrentTimestamp("CURRENT_TIMESTAMP"));
}

test "isCurrentTimestamp: now()" {
    try std.testing.expect(isCurrentTimestamp("now()"));
}

test "isCurrentTimestamp: random string" {
    try std.testing.expect(!isCurrentTimestamp("2024-01-01"));
}

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

// ─── SQLite reverse tests ──────────────────────────────────────

test "reverse sqlite: INTEGER + auto_increment maps to n" {
    const r = reverseLookup("INTEGER", "id", true, false, .sqlite);
    try std.testing.expectEqualStrings("n", r.tps);
    try std.testing.expect(!r.omit);
}

test "reverse sqlite: INTEGER + _id suffix maps to n with omit" {
    const r = reverseLookup("INTEGER", "user_id", false, false, .sqlite);
    try std.testing.expectEqualStrings("n", r.tps);
    try std.testing.expect(r.omit);
}

test "reverse sqlite: INTEGER bare maps to n" {
    const r = reverseLookup("INTEGER", "count", false, false, .sqlite);
    try std.testing.expectEqualStrings("n", r.tps);
}

test "reverse sqlite: lowercase integer maps to n" {
    const r = reverseLookup("integer", "status", false, false, .sqlite);
    try std.testing.expectEqualStrings("n", r.tps);
}

test "reverse sqlite: NUMERIC maps to m" {
    const r = reverseLookup("NUMERIC", "balance", false, false, .sqlite);
    try std.testing.expectEqualStrings("m", r.tps);
}

test "reverse sqlite: TEXT + _at suffix maps to t with omit" {
    const r = reverseLookup("TEXT", "created_at", false, false, .sqlite);
    try std.testing.expectEqualStrings("t", r.tps);
    try std.testing.expect(r.omit);
}

test "reverse sqlite: TEXT + _on suffix maps to d with omit" {
    const r = reverseLookup("TEXT", "birth_on", false, false, .sqlite);
    try std.testing.expectEqualStrings("d", r.tps);
    try std.testing.expect(r.omit);
}

test "reverse sqlite: TEXT + is_default_ts maps to t" {
    const r = reverseLookup("TEXT", "created_at", false, true, .sqlite);
    try std.testing.expectEqualStrings("t", r.tps);
    try std.testing.expect(!r.omit); // is_default_ts prevents omission
}

test "reverse sqlite: TEXT bare maps to s with omit" {
    const r = reverseLookup("TEXT", "name", false, false, .sqlite);
    try std.testing.expectEqualStrings("s", r.tps);
    try std.testing.expect(r.omit);
}

test "reverse sqlite: BLOB maps to B" {
    const r = reverseLookup("BLOB", "data", false, false, .sqlite);
    try std.testing.expectEqualStrings("B", r.tps);
}

// ─── SQLite heuristic tests ──────────────────────────────────

test "reverse sqlite: INTEGER + is_ prefix maps to b" {
    const r = reverseLookup("INTEGER", "is_admin", false, false, .sqlite);
    try std.testing.expectEqualStrings("b", r.tps);
}

test "reverse sqlite: INTEGER + has_ prefix maps to b" {
    const r = reverseLookup("INTEGER", "has_permission", false, false, .sqlite);
    try std.testing.expectEqualStrings("b", r.tps);
}

test "reverse sqlite: INTEGER + can_ prefix maps to b" {
    const r = reverseLookup("INTEGER", "can_edit", false, false, .sqlite);
    try std.testing.expectEqualStrings("b", r.tps);
}

test "reverse sqlite: TEXT + settings maps to j" {
    const r = reverseLookup("TEXT", "settings", false, false, .sqlite);
    try std.testing.expectEqualStrings("j", r.tps);
}

test "reverse sqlite: TEXT + metadata maps to j" {
    const r = reverseLookup("TEXT", "metadata", false, false, .sqlite);
    try std.testing.expectEqualStrings("j", r.tps);
}

test "reverse sqlite: TEXT + extra_data maps to j" {
    const r = reverseLookup("TEXT", "extra_data", false, false, .sqlite);
    try std.testing.expectEqualStrings("j", r.tps);
}

test "reverse sqlite: TEXT + description maps to S" {
    const r = reverseLookup("TEXT", "description", false, false, .sqlite);
    try std.testing.expectEqualStrings("S", r.tps);
}

test "reverse sqlite: TEXT + note maps to S" {
    const r = reverseLookup("TEXT", "note", false, false, .sqlite);
    try std.testing.expectEqualStrings("S", r.tps);
}

test "reverse sqlite: TEXT + content maps to S" {
    const r = reverseLookup("TEXT", "content", false, false, .sqlite);
    try std.testing.expectEqualStrings("S", r.tps);
}
