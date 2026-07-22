const std = @import("std");
const ast_mod = @import("ast.zig");
const dialect_enum = @import("dialect_enum.zig");
const common = @import("dialect_common.zig");
const sql_type_mod = @import("sql_type.zig");
const Writer = std.Io.Writer;
const IndexDecl = ast_mod.IndexDecl;
const CheckConstraint = ast_mod.CheckConstraint;
const Dialect = dialect_enum.Dialect;
const SqlType = sql_type_mod.SqlType;

// ─── DialectBackend: vtable for dialect-specific SQL generation ─
//
// Adding a new dialect requires only:
//   1. Add a new enum variant to Dialect (in dialect_enum.zig)
//   2. Create a new DialectBackend instance below
//   3. Register it in the getBackend() switch
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
    /// AUTO_INCREMENT keyword — only MySQL uses; PG uses GENERATED AS IDENTITY (via emitAutoIncrement is not called for PG), SQLite uses PRIMARY KEY AUTOINCREMENT.
    emitAutoIncrement: ?*const fn (w: *Writer) anyerror!void = null,
    /// SQLite-specific TPS type metadata comment (e.g. `-- @tps col_type`).
    emitTpsTypeMetadata: ?*const fn (w: *Writer, col_name: []const u8, tps_type: []const u8) anyerror!void = null,
    /// SQLite-specific confidence comment (e.g. ` -- [score:42]`).
    emitConfidenceComment: ?*const fn (w: *Writer, confidence: []const u8) anyerror!void = null,

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
        .mysql => mysql_backend,
        .pg => pg_backend,
        .sqlite => sqlite_backend,
    };
}

// ─── MySQL Backend ─────────────────────────────────────────────

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

// ─── MySQL ALTER TABLE migration methods ────────────────────

fn mysqlEmitAlterDropColumn(w: *Writer, col_name: []const u8) anyerror!void {
    try w.writeAll("DROP COLUMN ");
    try w.print("`{s}`", .{col_name});
}

fn mysqlEmitAlterModifyColumn(w: *Writer, _: []const u8) anyerror!void {
    try w.writeAll("MODIFY COLUMN ");
}

// ─── Unified MySQL ALTER methods ──────────────────────────

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

// ─── Type Rendering (SqlType → dialect-specific SQL string) ───

fn mysqlRenderType(w: *Writer, sql_type: SqlType) anyerror!void {
    switch (sql_type) {
        .int => try w.writeAll("int"),
        .bigint => try w.writeAll("bigint"),
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
        .datetime => try w.writeAll("datetime"),
        .date => try w.writeAll("date"),
        .boolean => try w.writeAll("boolean"),
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

fn pgRenderType(w: *Writer, sql_type: SqlType) anyerror!void {
    switch (sql_type) {
        .int => try w.writeAll("integer"),
        .bigint => try w.writeAll("bigint"),
        .decimal => |ds| try w.print("numeric({d}, {d})", .{ ds.precision, ds.scale }),
        .varchar => |n| {
            if (n > 0) {
                try w.print("varchar({d})", .{n});
            } else {
                try w.writeAll("varchar(255)");
            }
        },
        .text => try w.writeAll("text"),
        .blob => try w.writeAll("bytea"),
        .json => try w.writeAll("json"),
        .datetime => try w.writeAll("timestamp"),
        .date => try w.writeAll("date"),
        .boolean => try w.writeAll("boolean"),
        .enum_values => try w.writeAll("TEXT"),
        .raw_sql => |sql| try w.writeAll(sql),
        .passthrough => |t| try w.writeAll(t),
    }
}

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

const mysql_backend = DialectBackend{
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
    // Optional: MySQL implements emitCreateDatabase, emitUnsigned, emitAutoIncrement
    .emitCreateDatabase = mysqlEmitCreateDatabase,
    .emitUnsigned = mysqlEmitUnsigned,
    .emitAutoIncrement = mysqlEmitAutoIncrement,
    // emitTpsTypeMetadata and emitConfidenceComment default to null (no-op)
    .rename_needs_column_def = true,
    .modify_needs_column_def = true,
    .modify_column_def_skips_name = false,
};

// ─── PostgreSQL Backend ────────────────────────────────────────

fn pgEmitCreateDatabase(w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void {
    if (charset != null) {
        try w.print("CREATE DATABASE \"{s}\" ENCODING 'UTF8';\n\n", .{name});
    } else {
        try w.print("CREATE DATABASE \"{s}\";\n\n", .{name});
    }
}

// ─── PG/SQLite ALTER methods ─────────────────────

fn pgEmitAlterModifyColumn(w: *Writer, col_name: []const u8) anyerror!void {
    try w.print("ALTER COLUMN \"{s}\" TYPE ", .{col_name});
}

fn sqliteEmitAlterModifyColumn(w: *Writer, _: []const u8) anyerror!void {
    try w.writeAll("-- WARNING: MODIFY COLUMN not supported in SQLite; requires table recreation\n");
}

fn emitPgIndexFields(w: *Writer, idx: IndexDecl) !void {
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{f});
    }
}

fn pgEmitAlterAddIndex(w: *Writer, _: []const u8, idx: IndexDecl) anyerror!void {
    switch (idx.kind) {
        .unique => {
            try w.writeAll("ADD UNIQUE (");
            try emitPgIndexFields(w, idx);
            try w.writeAll(")");
        },
        .primary_key => {
            try w.writeAll("ADD PRIMARY KEY (");
            try emitPgIndexFields(w, idx);
            try w.writeAll(")");
        },
        else => {
            try w.print("-- NOTE: CREATE INDEX needed for '{s}' (not supported via ALTER TABLE in PG)\n", .{idx.name});
        },
    }
}

fn sqliteEmitAlterAddIndex(w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void {
    switch (idx.kind) {
        .unique => {
            try w.print("CREATE UNIQUE INDEX IF NOT EXISTS \"uk_{s}\" ON ", .{idx.name});
            try common.quoteIdentDoubleQuote(w, table_name);
            try w.writeAll(" (");
            try emitPgIndexFields(w, idx);
            try w.writeAll(")");
        },
        .regular => {
            try w.print("CREATE INDEX IF NOT EXISTS \"idx_{s}\" ON ", .{idx.name});
            try common.quoteIdentDoubleQuote(w, table_name);
            try w.writeAll(" (");
            try emitPgIndexFields(w, idx);
            try w.writeAll(")");
        },
        else => {
            try w.writeAll("-- NOTE: PRIMARY KEY/FULLTEXT cannot be added via ALTER TABLE in SQLite\n");
        },
    }
}

fn pgEmitAlterDropFk(w: *Writer, fk: ast_mod.FkDecl) anyerror!void {
    try w.writeAll("DROP CONSTRAINT \"fk_");
    for (fk.fields) |f| {
        try w.writeAll(f);
    }
    try w.writeAll("\"");
}

fn sqliteEmitAlterDropFk(w: *Writer, _: ast_mod.FkDecl) anyerror!void {
    try w.writeAll("-- WARNING: DROP FOREIGN KEY not supported via ALTER TABLE in SQLite\n");
}

fn pgEmitAlterTableComment(w: *Writer, table_name: []const u8, comment: []const u8) anyerror!void {
    try w.print("COMMENT ON TABLE \"{s}\" IS '{s}';\n\n", .{ table_name, comment });
}

fn pgCommentResult() CommentResult {
    return .standalone_emitted;
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

// ─── PG-specific helpers ──────────────────────────────────────

fn pgEmitTableComment(w: *Writer, table_name: []const u8, comment: []const u8) anyerror!void {
    const ct = if (comment.len >= 1 and comment[0] == ':') comment[1..] else comment;
    const tr = std.mem.trim(u8, ct, " ");
    if (tr.len > 0) try w.print("COMMENT ON TABLE \"{s}\" IS '{s}';\n", .{ table_name, tr });
}

fn pgEmitColumnComment(w: *Writer, table_name: []const u8, col_name: []const u8, comment: []const u8) anyerror!void {
    if (comment.len >= 1 and comment[0] == ':') {
        const ct = std.mem.trim(u8, comment[1..], " ");
        if (ct.len > 0) try w.print("COMMENT ON COLUMN \"{s}\".\"{s}\" IS '{s}';\n", .{ table_name, col_name, ct });
    }
}

fn pgEmitAutoIncrement(w: *Writer) anyerror!void {
    try w.writeAll(" GENERATED ALWAYS AS IDENTITY");
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

const pg_backend = DialectBackend{
    .quoteIdent = common.quoteIdentDoubleQuote,
    .emitIndex = common.emitIndex,
    .emitTimestampModifier = common.emitTimestampModifier,
    .emitTableFooter = common.emitTableFooter,
    .emitTableComment = pgEmitTableComment,
    .emitColumnComment = pgEmitColumnComment,
    .emitPrimaryKey = common.emitPrimaryKeyNormal,
    .emitInlineIndex = common.emitInlineIndexUnique,
    .emitStandaloneIndex = common.emitStandaloneIndex,
    .emitInlineColumnComment = common.noopInlineColumnCommentPG,
    .emitEnumTypeCheck = common.emitEnumTypeCheck,
    .emitInlineColumnStandaloneIndex = common.emitInlineColumnStandaloneIndex,
    .emitAlterDropColumn = common.emitAlterDropColumn,
    .emitAlterModifyColumn = pgEmitAlterModifyColumn,
    .emitAlterRenameColumn = common.emitAlterRenameColumn,
    .emitAlterAddIndex = pgEmitAlterAddIndex,
    .emitAlterDropIndex = common.emitAlterDropIndex,
    .emitAlterDropFk = pgEmitAlterDropFk,
    .commentResult = pgCommentResult,
    .emitAlterTableComment = pgEmitAlterTableComment,
    .emitAlterEngine = common.emitAlterEngineWarning,
    .emitCreateView = pgEmitCreateView,
    .renderType = pgRenderType,
    // Optional: PG implements emitCreateDatabase, emitAutoIncrement
    .emitCreateDatabase = pgEmitCreateDatabase,
    .emitAutoIncrement = pgEmitAutoIncrement,
    // emitUnsigned, emitTpsTypeMetadata, emitConfidenceComment default to null (no-op)
    .rename_needs_column_def = false,
    .modify_needs_column_def = true,
    .modify_column_def_skips_name = true,
};

// ─── SQLite Backend ────────────────────────────────────────────

const sqlite_backend = DialectBackend{
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

// ─── Inline column standalone index (PG/SQLite vs MySQL) ─────

fn mysqlNoopInlineColumnIndex(_: *Writer, _: []const u8, _: []const u8) anyerror!void {
    // MySQL handles inline indexes via emitInlineIndex — no standalone needed
}

fn sqliteEmitTpsTypeMetadata(w: *Writer, col_name: []const u8, tps_type: []const u8) anyerror!void {
    try w.print("-- @tps {s} {s}\n", .{ col_name, tps_type });
}

fn sqliteEmitConfidenceComment(w: *Writer, confidence: []const u8) anyerror!void {
    try w.print(" -- [{s}]", .{confidence});
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

// ─── View backends ─────────────────────────────────────────────

fn mysqlEmitCreateView(w: *Writer, name: []const u8, query: []const u8) anyerror!void {
    try w.writeAll("CREATE OR REPLACE VIEW ");
    try mysqlQuoteIdent(w, name);
    try w.writeAll(" AS\n");
    try w.writeAll(query);
    try w.writeAll(";\n");
}

fn pgEmitCreateView(w: *Writer, name: []const u8, query: []const u8) anyerror!void {
    try w.writeAll("CREATE OR REPLACE VIEW ");
    try common.quoteIdentDoubleQuote(w, name);
    try w.writeAll(" AS\n");
    try w.writeAll(query);
    try w.writeAll(";\n");
}

fn sqliteEmitCreateView(w: *Writer, name: []const u8, query: []const u8) anyerror!void {
    // SQLite does not support CREATE OR REPLACE VIEW
    try w.writeAll("CREATE VIEW ");
    try common.quoteIdentDoubleQuote(w, name);
    try w.writeAll(" AS\n");
    try w.writeAll(query);
    try w.writeAll(";\n");
}
