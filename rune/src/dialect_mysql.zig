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

// ─── MySQL Backend ─────────────────────────────────────────────

fn mysqlEmitForeignKey(w: *Writer, fk: ast_mod.FkDecl) anyerror!void {
    try common.emitForeignKeyShared(w, fk, mysqlQuoteIdent);
}

fn mysqlQuoteIdent(w: *Writer, name: []const u8) anyerror!void {
    try w.print("`{s}`", .{name});
}

fn mysqlEmitIndex(w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void {
    if (needs_comma.*) try w.writeAll(",\n");
    needs_comma.* = true;
    try w.writeAll("  ");
    switch (idx.kind) {
        .regular => try w.writeAll("INDEX"),
        .unique => try w.writeAll("UNIQUE INDEX"),
        .fulltext => try w.writeAll("FULLTEXT INDEX"),
        .primary_key => try w.writeAll("PRIMARY KEY"),
    }
    if (idx.kind == .primary_key) {
        try w.writeAll(" (");
    } else {
        try w.print(" `{s}` (", .{idx.name});
    }
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) try w.writeAll(", ");
        try w.print("`{s}`", .{f});
    }
    try w.writeAll(")");
}

fn mysqlEmitCreateDatabase(w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void {
    if (charset) |cs| {
        try w.print("CREATE DATABASE `{s}` CHARACTER SET {s};\n\n", .{ name, cs });
    } else {
        try w.print("CREATE DATABASE `{s}`;\n\n", .{name});
    }
}

fn mysqlEmitUnsigned(w: *Writer) anyerror!void {
    try w.writeAll(" UNSIGNED");
}

fn mysqlEmitTimestampModifier(w: *Writer, with_on_update: bool) anyerror!void {
    try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
    if (with_on_update) {
        try w.writeAll(" ON UPDATE CURRENT_TIMESTAMP");
    }
}

fn mysqlEmitTableFooter(w: *Writer, engine: ?[]const u8, _: ?[]const u8, comment: ?[]const u8) anyerror!void {
    const eng = engine orelse "InnoDB";
    const cs = "utf8mb4";
    if (comment) |c| {
        const ct = if (c.len >= 1 and c[0] == ':') c[1..] else c;
        const tr = std.mem.trim(u8, ct, " ");
        try w.print(") ENGINE={s} DEFAULT CHARSET={s} COMMENT='{s}';\n", .{ eng, cs, tr });
    } else {
        try w.print(") ENGINE={s} DEFAULT CHARSET={s};\n", .{ eng, cs });
    }
}

fn mysqlEmitTableComment(_: *Writer, _: []const u8, _: []const u8) anyerror!void {
    // MySQL: comment is in table footer (COMMENT='...'), no standalone statement
}

fn mysqlEmitColumnComment(_: *Writer, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
    // MySQL: column comments are inline in emitColumnDef (COMMENT '...'), not standalone
}

fn mysqlEmitAutoIncrement(w: *Writer) anyerror!void {
    try w.writeAll(" AUTO_INCREMENT");
}

fn mysqlEmitPrimaryKey(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" PRIMARY KEY");
}

fn mysqlEmitInlineIndex(w: *Writer, col_name: []const u8, is_unique: bool, needs_comma: *bool) anyerror!void {
    if (needs_comma.*) try w.writeAll(",\n");
    needs_comma.* = true;
    if (is_unique) {
        try w.print("  UNIQUE INDEX `uk_{s}` (`{s}`)", .{ col_name, col_name });
    } else {
        try w.print("  INDEX `idx_{s}` (`{s}`)", .{ col_name, col_name });
    }
}

fn mysqlEmitStandaloneIndex(_: *Writer, _: []const u8, _: IndexDecl) anyerror!void {
    // MySQL: indexes are inline in CREATE TABLE, no standalone CREATE INDEX
}

fn mysqlEmitInlineColumnComment(w: *Writer, comment: []const u8) anyerror!void {
    const ct = if (comment.len >= 1 and comment[0] == ':') comment[1..] else comment;
    const tr = std.mem.trim(u8, ct, " ");
    if (tr.len > 0) try w.print(" COMMENT '{s}'", .{tr});
}

fn mysqlEmitEnumTypeCheck(_: *Writer, _: []const u8, _: []const []const u8) anyerror!void {
    // MySQL: native ENUM type, no CHECK constraint needed
}

fn mysqlNoopInlineColumnIndex(_: *Writer, _: []const u8, _: []const u8) anyerror!void {
    // MySQL handles inline indexes via emitInlineIndex — no standalone needed
}

// ─── MySQL ALTER TABLE migration methods ────────────────────

fn mysqlEmitAlterDropColumn(w: *Writer, col_name: []const u8) anyerror!void {
    try w.writeAll("DROP COLUMN ");
    try w.print("`{s}`", .{col_name});
}

fn mysqlEmitAlterModifyColumn(w: *Writer, _: []const u8) anyerror!void {
    try w.writeAll("MODIFY COLUMN ");
}

fn mysqlEmitAlterRenameColumn(w: *Writer, old_name: []const u8, _: []const u8) anyerror!void {
    try w.writeAll("CHANGE COLUMN ");
    try w.print("`{s}`", .{old_name});
}

fn mysqlEmitAlterAddIndex(w: *Writer, _: []const u8, idx: IndexDecl) anyerror!void {
    switch (idx.kind) {
        .regular => {
            try w.print("ADD INDEX `{s}` (", .{idx.name});
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{f});
            }
            try w.writeAll(")");
        },
        .unique => {
            try w.print("ADD UNIQUE INDEX `{s}` (", .{idx.name});
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{f});
            }
            try w.writeAll(")");
        },
        .fulltext => {
            try w.print("ADD FULLTEXT INDEX `{s}` (", .{idx.name});
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{f});
            }
            try w.writeAll(")");
        },
        .primary_key => {
            try w.writeAll("ADD PRIMARY KEY (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{f});
            }
            try w.writeAll(")");
        },
    }
}

fn mysqlEmitAlterDropIndex(w: *Writer, idx: IndexDecl) anyerror!void {
    switch (idx.kind) {
        .primary_key => try w.writeAll("DROP PRIMARY KEY"),
        else => try w.print("DROP INDEX `{s}`", .{idx.name}),
    }
}

fn mysqlEmitAlterDropFk(w: *Writer, fk: ast_mod.FkDecl) anyerror!void {
    try w.writeAll("DROP FOREIGN KEY fk_");
    for (fk.fields) |f| {
        try w.writeAll(f);
    }
}

fn mysqlEmitAlterTableComment(w: *Writer, _: []const u8, comment: []const u8) anyerror!void {
    try w.print("COMMENT='{s}'", .{comment});
}

fn mysqlCommentResult() CommentResult {
    return .added_to_alter;
}

fn mysqlEmitAlterEngine(w: *Writer, engine: ?[]const u8) anyerror!void {
    try w.print("ENGINE={s}", .{engine orelse "InnoDB"});
}

// ─── Type Rendering ────────────────────────────────────────

fn mysqlRenderType(w: *Writer, sql_type: SqlType) anyerror!void {
    switch (sql_type) {
        .int => try w.writeAll("int"),
        .bigint => try w.writeAll("bigint"),
        .smallint => try w.writeAll("smallint"),
        .decimal => |ds| try w.print("decimal({d}, {d})", .{ ds.precision, ds.scale }),
        .varchar => |n| {
            if (n > 0) {
                try w.print("varchar({d})", .{n});
            } else {
                try w.writeAll("varchar(255)");
            }
        },
        .text => try w.writeAll("text"),
        .blob => try w.writeAll("blob"),
        .json => try w.writeAll("json"),
        .jsonb => try w.writeAll("json"),
        .datetime => try w.writeAll("datetime"),
        .date => try w.writeAll("date"),
        .timestamptz => try w.writeAll("timestamp"),
        .boolean => try w.writeAll("boolean"),
        .uuid => try w.writeAll("char(36)"),
        .inet => try w.writeAll("varchar(45)"),
        .serial => try w.writeAll("int"),
        .enum_values => |vals| {
            try w.writeAll("ENUM(");
            for (vals, 0..) |v, vi| {
                if (vi > 0) try w.writeAll(", ");
                try w.print("'{s}'", .{v});
            }
            try w.writeAll(")");
        },
        .raw_sql => |sql| try w.writeAll(sql),
        .passthrough => |t| try w.writeAll(t),
    }
}

// ─── View ──────────────────────────────────────────────────

fn mysqlEmitCreateView(w: *Writer, name: []const u8, query: []const u8) anyerror!void {
    try w.writeAll("CREATE OR REPLACE VIEW ");
    try mysqlQuoteIdent(w, name);
    try w.writeAll(" AS\n");
    try w.writeAll(query);
    try w.writeAll(";\n");
}

// ─── Backend Instance ──────────────────────────────────────

pub const mysql_backend = DialectBackend{
    .quoteIdent = mysqlQuoteIdent,
    .emitIndex = mysqlEmitIndex,
    .emitTimestampModifier = mysqlEmitTimestampModifier,
    .emitTableFooter = mysqlEmitTableFooter,
    .emitTableComment = mysqlEmitTableComment,
    .emitColumnComment = mysqlEmitColumnComment,
    .emitPrimaryKey = mysqlEmitPrimaryKey,
    .emitInlineIndex = mysqlEmitInlineIndex,
    .emitStandaloneIndex = mysqlEmitStandaloneIndex,
    .emitInlineColumnComment = mysqlEmitInlineColumnComment,
    .emitEnumTypeCheck = mysqlEmitEnumTypeCheck,
    .emitInlineColumnStandaloneIndex = mysqlNoopInlineColumnIndex,
    .emitAlterDropColumn = mysqlEmitAlterDropColumn,
    .emitAlterModifyColumn = mysqlEmitAlterModifyColumn,
    .emitAlterRenameColumn = mysqlEmitAlterRenameColumn,
    .emitAlterAddIndex = mysqlEmitAlterAddIndex,
    .emitAlterDropIndex = mysqlEmitAlterDropIndex,
    .emitAlterDropFk = mysqlEmitAlterDropFk,
    .commentResult = mysqlCommentResult,
    .emitAlterTableComment = mysqlEmitAlterTableComment,
    .emitAlterEngine = mysqlEmitAlterEngine,
    .emitCreateView = mysqlEmitCreateView,
    .renderType = mysqlRenderType,
    .emitForeignKey = mysqlEmitForeignKey,
    // Optional: MySQL implements emitCreateDatabase, emitUnsigned, emitAutoIncrement
    .emitCreateDatabase = mysqlEmitCreateDatabase,
    .emitUnsigned = mysqlEmitUnsigned,
    .emitAutoIncrement = mysqlEmitAutoIncrement,
    // emitTpsTypeMetadata and emitConfidenceComment default to null (no-op)
    .rename_needs_column_def = true,
    .modify_needs_column_def = true,
    .modify_column_def_skips_name = false,
};
