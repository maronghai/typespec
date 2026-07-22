const std = @import("std");
const dialect = @import("dialect.zig");
const common = @import("dialect_common.zig");
const ast_mod = @import("ast.zig");
const sql_type_mod = @import("sql_type.zig");
const sqlite_hints = @import("sqlite_hints.zig");
const reverse_map_data = @import("reverse_map_data.zig");
const DialectBackend = dialect.DialectBackend;
const CommentResult = dialect.CommentResult;
const ReverseResult = dialect.ReverseResult;
const IndexDecl = ast_mod.IndexDecl;
const Writer = std.Io.Writer;
const SqlType = sql_type_mod.SqlType;

// ─── SQLite Backend ────────────────────────────────────────────

fn sqliteEmitForeignKey(w: *Writer, fk: ast_mod.FkDecl) anyerror!void {
    try common.emitForeignKeyShared(w, fk, common.quoteIdentDoubleQuote);
}

fn sqliteEmitAlterModifyColumn(w: *Writer, _: []const u8) anyerror!void {
    try w.writeAll("-- WARNING: MODIFY COLUMN not supported in SQLite; requires table recreation\n");
}

fn sqliteEmitAlterAddIndex(w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void {
    switch (idx.kind) {
        .unique => {
            try w.print("CREATE UNIQUE INDEX IF NOT EXISTS \"uk_{s}\" ON ", .{idx.name});
            try common.quoteIdentDoubleQuote(w, table_name);
            try w.writeAll(" (");
            try common.emitIndexFields(w, idx);
            try w.writeAll(")");
        },
        .regular => {
            try w.print("CREATE INDEX IF NOT EXISTS \"idx_{s}\" ON ", .{idx.name});
            try common.quoteIdentDoubleQuote(w, table_name);
            try w.writeAll(" (");
            try common.emitIndexFields(w, idx);
            try w.writeAll(")");
        },
        else => {
            try w.writeAll("-- NOTE: PRIMARY KEY/FULLTEXT cannot be added via ALTER TABLE in SQLite\n");
        },
    }
}

fn sqliteEmitAlterDropFk(w: *Writer, _: ast_mod.FkDecl) anyerror!void {
    try w.writeAll("-- WARNING: DROP FOREIGN KEY not supported via ALTER TABLE in SQLite\n");
}

fn sqliteEmitAlterTableComment(w: *Writer, _: []const u8, _: []const u8) anyerror!void {
    try w.writeAll("-- NOTE: Comment change not supported via ALTER TABLE in SQLite\n");
}

fn sqliteCommentResult() CommentResult {
    return .unsupported;
}

fn sqliteNoopAlterDropColumn(w: *Writer, _: []const u8) anyerror!void {
    try w.writeAll("-- WARNING: DROP COLUMN not supported in SQLite < 3.35; requires table recreation\n");
}

// ─── SQLite-specific helpers ──────────────────────────────────

fn sqliteEmitTableComment(w: *Writer, _: []const u8, comment: []const u8) anyerror!void {
    const ct = if (comment.len >= 1 and comment[0] == ':') comment[1..] else comment;
    const tr = std.mem.trim(u8, ct, " ");
    if (tr.len > 0) try w.print("-- {s}\n", .{tr});
}

fn sqliteEmitColumnComment(w: *Writer, table_name: []const u8, col_name: []const u8, comment: []const u8) anyerror!void {
    if (comment.len >= 1 and comment[0] == ':') {
        const ct = std.mem.trim(u8, comment[1..], " ");
        if (ct.len > 0) try w.print("-- {s}.{s}: {s}\n", .{ table_name, col_name, ct });
    }
}

fn sqliteEmitAutoIncrement(_: *Writer) anyerror!void {
    // SQLite: no standalone AUTO_INCREMENT; uses PRIMARY KEY AUTOINCREMENT instead
}

fn sqliteEmitPrimaryKey(w: *Writer, auto_increment: bool) anyerror!void {
    if (auto_increment) {
        try w.writeAll(" PRIMARY KEY AUTOINCREMENT");
    } else {
        try w.writeAll(" PRIMARY KEY");
    }
}

fn sqliteEmitTpsTypeMetadata(w: *Writer, col_name: []const u8, tps_type: []const u8) anyerror!void {
    try w.print("-- @tps {s} {s}\n", .{ col_name, tps_type });
}

fn sqliteEmitConfidenceComment(w: *Writer, confidence: []const u8) anyerror!void {
    try w.print(" -- [{s}]", .{confidence});
}

// ─── Type Rendering ────────────────────────────────────────

fn sqliteRenderType(w: *Writer, sql_type: SqlType) anyerror!void {
    switch (sql_type) {
        .int, .bigint, .smallint, .serial => try w.writeAll("INTEGER"),
        .decimal => |ds| try w.print("NUMERIC({d}, {d})", .{ ds.precision, ds.scale }),
        .varchar => |n| {
            if (n > 0) {
                try w.print("varchar({d})", .{n});
            } else {
                try w.writeAll("TEXT");
            }
        },
        .text => try w.writeAll("TEXT"),
        .blob => try w.writeAll("BLOB"),
        .json => try w.writeAll("TEXT"),
        .datetime => try w.writeAll("TEXT"),
        .date => try w.writeAll("TEXT"),
        .timestamptz => try w.writeAll("TEXT"),
        .boolean => try w.writeAll("INTEGER"),
        .uuid => try w.writeAll("TEXT"),
        .enum_values => try w.writeAll("TEXT"),
        .raw_sql => |sql| try w.writeAll(sql),
        .passthrough => |t| try w.writeAll(t),
    }
}

// ─── View ──────────────────────────────────────────────────

fn sqliteEmitCreateView(w: *Writer, name: []const u8, query: []const u8) anyerror!void {
    // SQLite does not support CREATE OR REPLACE VIEW
    try w.writeAll("CREATE VIEW ");
    try common.quoteIdentDoubleQuote(w, name);
    try w.writeAll(" AS\n");
    try w.writeAll(query);
    try w.writeAll(";\n");
}

// ─── Reverse Lookup ────────────────────────────────────────────

fn sqliteReverseLookup(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool) ?ReverseResult {
    const t = std.mem.trim(u8, sql_type, " \t");

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
            return .{ .tps = "s", .omit = dialect.canOmitType(col_name, "s", is_auto_inc, is_default_ts), .score = 100 };
        const sbuf = struct {
            var buf: [16]u8 = undefined;
        };
        sbuf.buf[0] = 's';
        for (inner, 0..) |ch, i| sbuf.buf[i + 1] = ch;
        return .{ .tps = sbuf.buf[0 .. 1 + inner.len], .omit = false, .score = 100 };
    }
    if (std.mem.startsWith(u8, upper_t, "NUMERIC(") and std.mem.endsWith(u8, upper_t, ")")) {
        return .{ .tps = t[8 .. t.len - 1], .omit = false, .score = 100 };
    }

    // Check against REVERSE_MAP SQLite entries
    var found_tps: ?[]const u8 = null;
    for (reverse_map_data.REVERSE_MAP) |m| {
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
            return .{ .tps = tps, .omit = dialect.canOmitType(col_name, tps, is_auto_inc, is_default_ts), .score = 100 };
        }

        // INTEGER group (n, N, b) — disambiguate with heuristics
        if (std.mem.eql(u8, upper_t, "INTEGER")) {
            if (is_auto_inc) return .{ .tps = "n", .omit = false, .score = 100 };
            if (col_name.len > 3 and std.mem.endsWith(u8, col_name, "_id"))
                return .{ .tps = "n", .omit = dialect.canOmitType(col_name, "n", is_auto_inc, is_default_ts), .score = 100 };
            if (sqlite_hints.isBooleanColumnName(col_name))
                return .{ .tps = "b", .omit = dialect.canOmitType(col_name, "b", is_auto_inc, is_default_ts), .score = 80 };
            return .{ .tps = "n", .omit = dialect.canOmitType(col_name, "n", is_auto_inc, is_default_ts), .score = 50 };
        }

        // NUMERIC group (m, M) — m is most common
        if (std.mem.eql(u8, upper_t, "NUMERIC")) {
            return .{ .tps = "m", .omit = dialect.canOmitType(col_name, "m", is_auto_inc, is_default_ts), .score = 100 };
        }

        // TEXT group (s, S, j, d, t) — disambiguate with heuristics
        if (std.mem.eql(u8, upper_t, "TEXT")) {
            if (col_name.len > 3 and std.mem.endsWith(u8, col_name, "_at"))
                return .{ .tps = "t", .omit = dialect.canOmitType(col_name, "t", is_auto_inc, is_default_ts), .score = 100 };
            if (col_name.len > 3 and std.mem.endsWith(u8, col_name, "_on"))
                return .{ .tps = "d", .omit = dialect.canOmitType(col_name, "d", is_auto_inc, is_default_ts), .score = 100 };
            if (is_default_ts)
                return .{ .tps = "t", .omit = dialect.canOmitType(col_name, "t", is_auto_inc, is_default_ts), .score = 100 };
            if (sqlite_hints.isJsonColumnName(col_name))
                return .{ .tps = "j", .omit = dialect.canOmitType(col_name, "j", is_auto_inc, is_default_ts), .score = 80 };
            if (sqlite_hints.isTextColumnName(col_name))
                return .{ .tps = "S", .omit = dialect.canOmitType(col_name, "S", is_auto_inc, is_default_ts), .score = 80 };
            return .{ .tps = "s", .omit = dialect.canOmitType(col_name, "s", is_auto_inc, is_default_ts), .score = 50 };
        }
    }

    // Fallback: return as-is (unknown type)
    return .{ .tps = t, .omit = false, .score = 50 };
}

// ─── Backend Instance ──────────────────────────────────────

pub const sqlite_backend = DialectBackend{
    .quoteIdent = common.quoteIdentDoubleQuote,
    .emitIndex = common.emitIndex,
    .emitTimestampModifier = common.emitTimestampModifier,
    .emitTableFooter = common.emitTableFooter,
    .emitTableComment = sqliteEmitTableComment,
    .emitColumnComment = sqliteEmitColumnComment,
    .emitPrimaryKey = sqliteEmitPrimaryKey,
    .emitInlineIndex = common.emitInlineIndexUnique,
    .emitStandaloneIndex = common.emitStandaloneIndex,
    .emitInlineColumnComment = common.noopInlineColumnCommentSQLite,
    .emitEnumTypeCheck = common.emitEnumTypeCheck,
    .emitInlineColumnStandaloneIndex = common.emitInlineColumnStandaloneIndex,
    .emitAlterDropColumn = sqliteNoopAlterDropColumn,
    .emitAlterModifyColumn = sqliteEmitAlterModifyColumn,
    .emitAlterRenameColumn = common.emitAlterRenameColumn,
    .emitAlterAddIndex = sqliteEmitAlterAddIndex,
    .emitAlterDropIndex = common.emitAlterDropIndex,
    .emitAlterDropFk = sqliteEmitAlterDropFk,
    .commentResult = sqliteCommentResult,
    .emitAlterTableComment = sqliteEmitAlterTableComment,
    .emitAlterEngine = common.emitAlterEngineWarning,
    .emitCreateView = sqliteEmitCreateView,
    .renderType = sqliteRenderType,
    .emitForeignKey = sqliteEmitForeignKey,
    // Optional: SQLite implements emitTpsTypeMetadata, emitConfidenceComment, reverseLookup
    .emitTpsTypeMetadata = sqliteEmitTpsTypeMetadata,
    .emitConfidenceComment = sqliteEmitConfidenceComment,
    .reverseLookup = sqliteReverseLookup,
    // emitCreateDatabase, emitUnsigned, emitAutoIncrement default to null (no-op)
    .rename_needs_column_def = false,
    .modify_needs_column_def = false,
    .modify_column_def_skips_name = false,
};
