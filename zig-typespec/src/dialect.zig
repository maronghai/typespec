const std = @import("std");
const ast_mod = @import("ast.zig");
const dialect_enum = @import("dialect_enum.zig");
const sql_type_mod = @import("sql_type.zig");
const Writer = std.Io.Writer;
const IndexDecl = ast_mod.IndexDecl;
const CheckConstraint = ast_mod.CheckConstraint;
const Dialect = dialect_enum.Dialect;
const SqlType = sql_type_mod.SqlType;

// ─── Reverse Result (shared by reverse_map.zig + dialect backends) ──

pub const ReverseResult = struct {
    tps: []const u8,
    omit: bool,
    /// Confidence score 0-100. Higher = more certain.
    score: u8 = 100,
    /// Whether this entry is a parameterized type (varchar, decimal) that
    /// requires special handling in reverse lookup.
    is_parameterized: bool = false,
};

// ─── canOmitType: shared helper for reverse lookup ────────────

pub fn canOmitType(col_name: []const u8, tps_symbol: []const u8, is_auto_inc: bool, is_default_ts: bool) bool {
    if (is_auto_inc or is_default_ts) return false;
    if (col_name.len > 3) {
        if (std.mem.endsWith(u8, col_name, "_id") and std.mem.eql(u8, tps_symbol, "n")) return true;
        if (std.mem.endsWith(u8, col_name, "_on") and std.mem.eql(u8, tps_symbol, "d")) return true;
        if (std.mem.endsWith(u8, col_name, "_at") and std.mem.eql(u8, tps_symbol, "t")) return true;
    }
    return std.mem.eql(u8, tps_symbol, "s");
}

// ─── DialectBackend: vtable for dialect-specific SQL generation ─
//
// Adding a new dialect requires only:
//   1. Add a new enum variant to Dialect (in dialect_enum.zig)
//   2. Create a new DialectBackend instance (in dialect_<name>.zig)
//   3. Register it in the getBackend() switch below
//
// All dialect-specific rendering goes through this vtable.
// codegen.zig is fully dialect-agnostic.

/// Result of emitAlterTableComment — tells the caller how to update state.
pub const CommentResult = enum {
    added_to_alter, // MySQL: comment emitted inline in ALTER TABLE
    standalone_emitted, // PG: standalone COMMENT ON TABLE emitted; caller should close ALTER
    unsupported, // SQLite: warning comment emitted; no state change needed
};

pub const DialectBackend = struct {
    // ── Core methods (all dialects must implement) ──
    quoteIdent: *const fn (w: *Writer, name: []const u8) anyerror!void,
    emitIndex: *const fn (w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void,
    emitTimestampModifier: *const fn (w: *Writer, with_on_update: bool) anyerror!void,
    emitTableFooter: *const fn (w: *Writer, engine: ?[]const u8, charset: ?[]const u8, comment: ?[]const u8) anyerror!void,
    emitTableComment: *const fn (w: *Writer, table_name: []const u8, comment: []const u8) anyerror!void,
    emitColumnComment: *const fn (w: *Writer, table_name: []const u8, col_name: []const u8, comment: []const u8) anyerror!void,
    emitPrimaryKey: *const fn (w: *Writer, auto_increment: bool) anyerror!void,
    emitInlineIndex: *const fn (w: *Writer, col_name: []const u8, is_unique: bool, needs_comma: *bool) anyerror!void,
    emitStandaloneIndex: *const fn (w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void,
    emitInlineColumnComment: *const fn (w: *Writer, comment: []const u8) anyerror!void,
    emitEnumTypeCheck: *const fn (w: *Writer, col_name: []const u8, enum_values: []const []const u8) anyerror!void,
    emitInlineColumnStandaloneIndex: *const fn (w: *Writer, table_name: []const u8, col_name: []const u8) anyerror!void,
    emitAlterDropColumn: *const fn (w: *Writer, col_name: []const u8) anyerror!void,
    emitAlterModifyColumn: *const fn (w: *Writer, col_name: []const u8) anyerror!void,
    emitAlterRenameColumn: *const fn (w: *Writer, old_name: []const u8, new_name: []const u8) anyerror!void,
    emitAlterAddIndex: *const fn (w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void,
    emitAlterDropIndex: *const fn (w: *Writer, idx: IndexDecl) anyerror!void,
    emitAlterDropFk: *const fn (w: *Writer, fk: ast_mod.FkDecl) anyerror!void,
    commentResult: *const fn () CommentResult,
    emitAlterTableComment: *const fn (w: *Writer, table_name: []const u8, comment: []const u8) anyerror!void,
    emitAlterEngine: *const fn (w: *Writer, engine: ?[]const u8) anyerror!void,
    emitCreateView: *const fn (w: *Writer, name: []const u8, query: []const u8) anyerror!void,
    /// Render a SqlType to dialect-specific SQL type string. Single source of truth for type rendering.
    renderType: *const fn (w: *Writer, sql_type: SqlType) anyerror!void,

    // ── Optional methods (null = no-op for this dialect) ──
    /// CREATE DATABASE — only MySQL/PG implement; SQLite has no concept of databases.
    emitCreateDatabase: ?*const fn (w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void = null,
    /// UNSIGNED modifier — only MySQL uses; PG/SQLite have no UNSIGNED.
    emitUnsigned: ?*const fn (w: *Writer) anyerror!void = null,
    /// AUTO_INCREMENT keyword — only MySQL uses; PG uses GENERATED AS IDENTITY, SQLite uses PRIMARY KEY AUTOINCREMENT.
    emitAutoIncrement: ?*const fn (w: *Writer) anyerror!void = null,
    /// SQLite-specific TPS type metadata comment (e.g. `-- @tps col_type`).
    emitTpsTypeMetadata: ?*const fn (w: *Writer, col_name: []const u8, tps_type: []const u8) anyerror!void = null,
    /// SQLite-specific confidence comment (e.g. ` -- [score:42]`).
    emitConfidenceComment: ?*const fn (w: *Writer, confidence: []const u8) anyerror!void = null,
    /// Dialect-specific reverse lookup. Returns null to fall back to general logic.
    reverseLookup: ?*const fn (sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool) ?ReverseResult = null,

    // ── Behavioral flags (eliminate dialect checks in caller) ──
    /// MySQL CHANGE COLUMN requires the full column definition after the rename.
    rename_needs_column_def: bool,
    /// MODIFY COLUMN: MySQL/PG need column def, SQLite just emits a warning.
    modify_needs_column_def: bool,
    /// PG ALTER COLUMN TYPE skips the column name (it's in the ALTER prefix).
    modify_column_def_skips_name: bool,
};

pub fn getBackend(dialect: Dialect) DialectBackend {
    return switch (dialect) {
        .mysql => @import("dialect_mysql.zig").mysql_backend,
        .pg => @import("dialect_pg.zig").pg_backend,
        .sqlite => @import("dialect_sqlite.zig").sqlite_backend,
    };
}

// ─── Shared helpers (dialect-independent) ──────────────────────

pub fn emitCheckExpr(w: *Writer, field_name: []const u8, ck: CheckConstraint) !void {
    switch (ck.kind) {
        .range => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} BETWEEN {s} AND {s}", .{ field_name, low, high });
        },
        .range_upper_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} >= {s} AND {s} < {s}", .{ field_name, low, field_name, high });
        },
        .range_lower_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} > {s} AND {s} <= {s}", .{ field_name, low, field_name, high });
        },
        .range_both_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} > {s} AND {s} < {s}", .{ field_name, low, field_name, high });
        },
        .in_list => {
            try w.print("{s} IN (", .{field_name});
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            var first = true;
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try w.writeAll(", ");
                first = false;
                const is_num = blk: {
                    _ = std.fmt.parseFloat(f64, trimmed) catch break :blk false;
                    break :blk true;
                };
                if (is_num) {
                    try w.print("{s}", .{trimmed});
                } else {
                    const val = if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
                        trimmed[1 .. trimmed.len - 1]
                    else
                        trimmed;
                    try w.print("'{s}'", .{val});
                }
            }
            try w.writeAll(")");
        },
        .comparison => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            var first = true;
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try w.writeAll(" AND ");
                first = false;
                if (trimmed[0] == '>' and trimmed.len > 1 and trimmed[1] == '=') {
                    try w.print("{s} >= {s}", .{ field_name, trimmed[2..] });
                } else if (trimmed[0] == '<' and trimmed.len > 1 and trimmed[1] == '=') {
                    try w.print("{s} <= {s}", .{ field_name, trimmed[2..] });
                } else if (trimmed[0] == '>') {
                    try w.print("{s} > {s}", .{ field_name, trimmed[1..] });
                } else if (trimmed[0] == '<') {
                    try w.print("{s} < {s}", .{ field_name, trimmed[1..] });
                } else if (trimmed[0] == '=') {
                    try w.print("{s} = {s}", .{ field_name, trimmed[1..] });
                } else {
                    try w.print("{s} = {s}", .{ field_name, trimmed });
                }
            }
        },
    }
}
