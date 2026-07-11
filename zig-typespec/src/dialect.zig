const std = @import("std");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const Writer = std.Io.Writer;
const IndexDecl = ast_mod.IndexDecl;
const CheckConstraint = ast_mod.CheckConstraint;
const Dialect = type_map.Dialect;

// ─── DialectBackend: vtable for dialect-specific SQL generation ─
//
// Adding a new dialect requires only:
//   1. Add a new enum variant to Dialect (in type_map.zig)
//   2. Create a new DialectBackend instance below
//   3. Register it in the getBackend() switch
//
// All dialect-specific rendering goes through this vtable.
// codegen.zig is fully dialect-agnostic.

pub const DialectBackend = struct {
    // ── Original 5 methods ──
    quoteIdent: *const fn (w: *Writer, name: []const u8) anyerror!void,
    emitIndex: *const fn (w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void,
    emitCreateDatabase: *const fn (w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void,
    emitUnsigned: *const fn (w: *Writer) anyerror!void,
    emitTimestampModifier: *const fn (w: *Writer, with_on_update: bool) anyerror!void,
    // ── New methods (v0.4.8) ──
    emitTableFooter: *const fn (w: *Writer, engine: ?[]const u8, charset: ?[]const u8, comment: ?[]const u8) anyerror!void,
    emitTableComment: *const fn (w: *Writer, table_name: []const u8, comment: []const u8) anyerror!void,
    emitColumnComment: *const fn (w: *Writer, table_name: []const u8, col_name: []const u8, comment: []const u8) anyerror!void,
    emitAutoIncrement: *const fn (w: *Writer) anyerror!void,
    emitPrimaryKey: *const fn (w: *Writer, auto_increment: bool) anyerror!void,
    emitInlineIndex: *const fn (w: *Writer, col_name: []const u8, is_unique: bool, needs_comma: *bool) anyerror!void,
    emitStandaloneIndex: *const fn (w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void,
    emitInlineColumnComment: *const fn (w: *Writer, comment: []const u8) anyerror!void,
    emitEnumTypeCheck: *const fn (w: *Writer, col_name: []const u8, enum_values: []const []const u8) anyerror!void,
};

pub fn getBackend(dialect: Dialect) DialectBackend {
    return switch (dialect) {
        .mysql => mysql_backend,
        .postgres => pg_backend,
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

const mysql_backend = DialectBackend{
    .quoteIdent = mysqlQuoteIdent,
    .emitIndex = mysqlEmitIndex,
    .emitCreateDatabase = mysqlEmitCreateDatabase,
    .emitUnsigned = mysqlEmitUnsigned,
    .emitTimestampModifier = mysqlEmitTimestampModifier,
    .emitTableFooter = mysqlEmitTableFooter,
    .emitTableComment = mysqlEmitTableComment,
    .emitColumnComment = mysqlEmitColumnComment,
    .emitAutoIncrement = mysqlEmitAutoIncrement,
    .emitPrimaryKey = mysqlEmitPrimaryKey,
    .emitInlineIndex = mysqlEmitInlineIndex,
    .emitStandaloneIndex = mysqlEmitStandaloneIndex,
    .emitInlineColumnComment = mysqlEmitInlineColumnComment,
    .emitEnumTypeCheck = mysqlEmitEnumTypeCheck,
};

// ─── Shared PG/SQLite Backend ──────────────────────────────────

fn pgSqliteQuoteIdent(w: *Writer, name: []const u8) anyerror!void {
    try w.print("\"{s}\"", .{name});
}

fn pgSqliteEmitIndex(w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void {
    switch (idx.kind) {
        .regular => return,
        .fulltext => return,
        .unique => {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  UNIQUE (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(")");
        },
        .primary_key => {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  PRIMARY KEY (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(")");
        },
    }
}

fn pgSqliteEmitUnsigned(_: *Writer) anyerror!void {}

fn pgSqliteEmitTimestampModifier(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
}

fn pgSqliteEmitTableFooter(w: *Writer, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8) anyerror!void {
    try w.writeAll(");\n");
}

fn pgSqliteEmitTableCommentPG(w: *Writer, table_name: []const u8, comment: []const u8) anyerror!void {
    const ct = if (comment.len >= 1 and comment[0] == ':') comment[1..] else comment;
    const tr = std.mem.trim(u8, ct, " ");
    if (tr.len > 0) try w.print("COMMENT ON TABLE \"{s}\" IS '{s}';\n", .{ table_name, tr });
}

fn pgSqliteEmitColumnCommentPG(w: *Writer, table_name: []const u8, col_name: []const u8, comment: []const u8) anyerror!void {
    if (comment.len >= 1 and comment[0] == ':') {
        const ct = std.mem.trim(u8, comment[1..], " ");
        if (ct.len > 0) try w.print("COMMENT ON COLUMN \"{s}\".\"{s}\" IS '{s}';\n", .{ table_name, col_name, ct });
    }
}

fn pgSqliteEmitTableCommentSQLite(w: *Writer, _: []const u8, comment: []const u8) anyerror!void {
    const ct = if (comment.len >= 1 and comment[0] == ':') comment[1..] else comment;
    const tr = std.mem.trim(u8, ct, " ");
    if (tr.len > 0) try w.print("-- {s}\n", .{tr});
}

fn pgSqliteEmitColumnCommentSQLite(w: *Writer, table_name: []const u8, col_name: []const u8, comment: []const u8) anyerror!void {
    if (comment.len >= 1 and comment[0] == ':') {
        const ct = std.mem.trim(u8, comment[1..], " ");
        if (ct.len > 0) try w.print("-- {s}.{s}: {s}\n", .{ table_name, col_name, ct });
    }
}

fn pgSqliteEmitAutoIncrementPG(w: *Writer) anyerror!void {
    try w.writeAll(" GENERATED ALWAYS AS IDENTITY");
}

fn pgSqliteEmitAutoIncrementSQLite(_: *Writer) anyerror!void {
    // SQLite: no standalone AUTO_INCREMENT; uses PRIMARY KEY AUTOINCREMENT instead
}

fn pgSqliteEmitPrimaryKeyNormal(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" PRIMARY KEY");
}

fn pgSqliteEmitPrimaryKeySQLite(w: *Writer, auto_increment: bool) anyerror!void {
    if (auto_increment) {
        try w.writeAll(" PRIMARY KEY AUTOINCREMENT");
    } else {
        try w.writeAll(" PRIMARY KEY");
    }
}

fn pgSqliteEmitInlineIndexUnique(w: *Writer, col_name: []const u8, is_unique: bool, needs_comma: *bool) anyerror!void {
    if (is_unique) {
        if (needs_comma.*) try w.writeAll(",\n");
        needs_comma.* = true;
        try w.print("  UNIQUE (\"{s}\")", .{col_name});
    }
    // Regular inline index: no-op for PG/SQLite
}

fn pgSqliteEmitStandaloneIndexPG(w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void {
    if (idx.kind == .primary_key or idx.kind == .unique or idx.kind == .fulltext) return;
    try w.writeAll("CREATE INDEX ");
    if (idx.name.len > 0) {
        try w.print("\"{s}\"", .{idx.name});
    } else {
        try w.print("\"idx_{s}_{s}\"", .{ table_name, idx.fields[0] });
    }
    try w.print(" ON \"{s}\" (", .{table_name});
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{f});
    }
    try w.writeAll(");\n");
}

fn pgSqliteEmitInlineColumnCommentPG(_: *Writer, _: []const u8) anyerror!void {
    // PG: column comments are standalone COMMENT ON COLUMN, not inline
}

fn pgSqliteEmitInlineColumnCommentSQLite(_: *Writer, _: []const u8) anyerror!void {
    // SQLite: column comments are standalone -- comments, not inline
}

fn pgSqliteEmitEnumTypeCheck(w: *Writer, col_name: []const u8, enum_values: []const []const u8) anyerror!void {
    try w.writeAll(" CHECK (");
    try w.print("\"{s}\" IN (", .{col_name});
    for (enum_values, 0..) |v, vi| {
        if (vi > 0) try w.writeAll(", ");
        try w.print("'{s}'", .{v});
    }
    try w.writeAll("))");
}

// ─── PostgreSQL Backend ────────────────────────────────────────

fn pgEmitCreateDatabase(w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void {
    if (charset != null) {
        try w.print("CREATE DATABASE \"{s}\" ENCODING 'UTF8';\n\n", .{name});
    } else {
        try w.print("CREATE DATABASE \"{s}\";\n\n", .{name});
    }
}

const pg_backend = DialectBackend{
    .quoteIdent = pgSqliteQuoteIdent,
    .emitIndex = pgSqliteEmitIndex,
    .emitCreateDatabase = pgEmitCreateDatabase,
    .emitUnsigned = pgSqliteEmitUnsigned,
    .emitTimestampModifier = pgSqliteEmitTimestampModifier,
    .emitTableFooter = pgSqliteEmitTableFooter,
    .emitTableComment = pgSqliteEmitTableCommentPG,
    .emitColumnComment = pgSqliteEmitColumnCommentPG,
    .emitAutoIncrement = pgSqliteEmitAutoIncrementPG,
    .emitPrimaryKey = pgSqliteEmitPrimaryKeyNormal,
    .emitInlineIndex = pgSqliteEmitInlineIndexUnique,
    .emitStandaloneIndex = pgSqliteEmitStandaloneIndexPG,
    .emitInlineColumnComment = pgSqliteEmitInlineColumnCommentPG,
    .emitEnumTypeCheck = pgSqliteEmitEnumTypeCheck,
};

// ─── SQLite Backend ────────────────────────────────────────────

fn sqliteEmitCreateDatabase(_: *Writer, _: []const u8, _: ?[]const u8) anyerror!void {}

const sqlite_backend = DialectBackend{
    .quoteIdent = pgSqliteQuoteIdent,
    .emitIndex = pgSqliteEmitIndex,
    .emitCreateDatabase = sqliteEmitCreateDatabase,
    .emitUnsigned = pgSqliteEmitUnsigned,
    .emitTimestampModifier = pgSqliteEmitTimestampModifier,
    .emitTableFooter = pgSqliteEmitTableFooter,
    .emitTableComment = pgSqliteEmitTableCommentSQLite,
    .emitColumnComment = pgSqliteEmitColumnCommentSQLite,
    .emitAutoIncrement = pgSqliteEmitAutoIncrementSQLite,
    .emitPrimaryKey = pgSqliteEmitPrimaryKeySQLite,
    .emitInlineIndex = pgSqliteEmitInlineIndexUnique,
    .emitStandaloneIndex = pgSqliteEmitStandaloneIndexPG,
    .emitInlineColumnComment = pgSqliteEmitInlineColumnCommentSQLite,
    .emitEnumTypeCheck = pgSqliteEmitEnumTypeCheck,
};

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
