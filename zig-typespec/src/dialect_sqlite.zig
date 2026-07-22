const std = @import("std");
const dialect = @import("dialect.zig");
const common = @import("dialect_common.zig");
const ast_mod = @import("ast.zig");
const sql_type_mod = @import("sql_type.zig");
const DialectBackend = dialect.DialectBackend;
const CommentResult = dialect.CommentResult;
const IndexDecl = ast_mod.IndexDecl;
const Writer = std.Io.Writer;
const SqlType = sql_type_mod.SqlType;

// ─── SQLite Backend ────────────────────────────────────────────

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
        .int, .bigint => try w.writeAll("INTEGER"),
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
        .boolean => try w.writeAll("INTEGER"),
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
    // Optional: SQLite implements emitTpsTypeMetadata, emitConfidenceComment
    .emitTpsTypeMetadata = sqliteEmitTpsTypeMetadata,
    .emitConfidenceComment = sqliteEmitConfidenceComment,
    // emitCreateDatabase, emitUnsigned, emitAutoIncrement default to null (no-op)
    .rename_needs_column_def = false,
    .modify_needs_column_def = false,
    .modify_column_def_skips_name = false,
};
