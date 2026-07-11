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
// Column-level rendering is handled inline in Codegen.generateTypedTable().
// Only table-level and dialect-wide operations go through this vtable.

pub const DialectBackend = struct {
    quoteIdent: *const fn (w: *Writer, name: []const u8) anyerror!void,
    emitIndex: *const fn (w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void,
    emitCreateDatabase: *const fn (w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void,
    emitUnsigned: *const fn (w: *Writer) anyerror!void,
    emitTimestampModifier: *const fn (w: *Writer, with_on_update: bool) anyerror!void,
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

const mysql_backend = DialectBackend{
    .quoteIdent = mysqlQuoteIdent,
    .emitIndex = mysqlEmitIndex,
    .emitCreateDatabase = mysqlEmitCreateDatabase,
    .emitUnsigned = mysqlEmitUnsigned,
    .emitTimestampModifier = mysqlEmitTimestampModifier,
};

// ─── Shared PG/SQLite Backend ──────────────────────────────────
// PostgreSQL and SQLite share identical implementations for quoting,
// index emission, unsigned (no-op), and timestamp modifier.

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
};

// ─── SQLite Backend ────────────────────────────────────────────

fn sqliteEmitCreateDatabase(_: *Writer, _: []const u8, _: ?[]const u8) anyerror!void {}

const sqlite_backend = DialectBackend{
    .quoteIdent = pgSqliteQuoteIdent,
    .emitIndex = pgSqliteEmitIndex,
    .emitCreateDatabase = sqliteEmitCreateDatabase,
    .emitUnsigned = pgSqliteEmitUnsigned,
    .emitTimestampModifier = pgSqliteEmitTimestampModifier,
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
