const std = @import("std");
const ast_mod = @import("ast.zig");
const Writer = std.Io.Writer;
const IndexDecl = ast_mod.IndexDecl;

// ─── Shared PG/SQLite Dialect Logic ──────────────────────────
//
// Functions shared between PostgreSQL and SQLite backends.
// Extracted from dialect.zig for single-responsibility.
//
// MySQL uses backtick quoting and inline comments;
// PG/SQLite both use double-quote quoting and standalone comments.
// These functions capture the common PG/SQLite behavior.

// ─── Identifier Quoting ──────────────────────────────────────

pub fn quoteIdentDoubleQuote(w: *Writer, name: []const u8) anyerror!void {
    try w.print("\"{s}\"", .{name});
}

// ─── Inline Index Emission ───────────────────────────────────

pub fn emitIndex(w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void {
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

pub fn emitInlineIndexUnique(w: *Writer, col_name: []const u8, is_unique: bool, needs_comma: *bool) anyerror!void {
    if (is_unique) {
        if (needs_comma.*) try w.writeAll(",\n");
        needs_comma.* = true;
        try w.print("  UNIQUE (\"{s}\")", .{col_name});
    }
    // Regular inline index: no-op for PG/SQLite
}

// ─── Standalone Index Emission ───────────────────────────────

pub fn emitStandaloneIndex(w: *Writer, table_name: []const u8, idx: IndexDecl) anyerror!void {
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

pub fn emitInlineColumnStandaloneIndex(w: *Writer, table_name: []const u8, col_name: []const u8) anyerror!void {
    try w.writeAll("CREATE INDEX ");
    try w.print("\"idx_{s}_{s}\"", .{ table_name, col_name });
    try w.writeAll(" ON ");
    try quoteIdentDoubleQuote(w, table_name);
    try w.writeAll(" (");
    try quoteIdentDoubleQuote(w, col_name);
    try w.writeAll(");\n");
}

// ─── Type Modifiers ──────────────────────────────────────────

pub fn emitUnsigned(_: *Writer) anyerror!void {}

pub fn emitTimestampModifier(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
}

// ─── Table Structure ─────────────────────────────────────────

pub fn emitTableFooter(w: *Writer, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8) anyerror!void {
    try w.writeAll(");\n");
}

pub fn emitPrimaryKeyNormal(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" PRIMARY KEY");
}

// ─── Enum Type Check ─────────────────────────────────────────

pub fn emitEnumTypeCheck(w: *Writer, col_name: []const u8, enum_values: []const []const u8) anyerror!void {
    try w.writeAll(" CHECK (");
    try w.print("\"{s}\" IN (", .{col_name});
    for (enum_values, 0..) |v, vi| {
        if (vi > 0) try w.writeAll(", ");
        try w.print("'{s}'", .{v});
    }
    try w.writeAll("))");
}

// ─── ALTER TABLE Methods ─────────────────────────────────────

pub fn emitAlterDropColumn(w: *Writer, col_name: []const u8) anyerror!void {
    try w.writeAll("DROP COLUMN \"");
    try w.writeAll(col_name);
    try w.writeAll("\"");
}

pub fn emitAlterRenameColumn(w: *Writer, old_name: []const u8, new_name: []const u8) anyerror!void {
    try w.print("RENAME COLUMN \"{s}\" TO \"{s}\"", .{ old_name, new_name });
}

pub fn emitAlterDropIndex(w: *Writer, idx: IndexDecl) anyerror!void {
    switch (idx.kind) {
        .primary_key => try w.writeAll("DROP PRIMARY KEY"),
        else => try w.print("DROP INDEX IF EXISTS \"{s}\"", .{idx.name}),
    }
}

pub fn emitAlterEngineWarning(w: *Writer, _: ?[]const u8) anyerror!void {
    try w.writeAll("-- NOTE: ENGINE change is MySQL-only, ignored for this dialect\n");
}

// ─── Index Field Helper ──────────────────────────────────────

pub fn emitIndexFields(w: *Writer, idx: IndexDecl) !void {
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{f});
    }
}

// ─── Inline Column Comment No-ops ────────────────────────────
// Both PG and SQLite handle column comments via standalone statements,
// not inline in column definitions.

pub fn noopInlineColumnCommentPG(_: *Writer, _: []const u8) anyerror!void {}

pub fn noopInlineColumnCommentSQLite(_: *Writer, _: []const u8) anyerror!void {}

// ─── Tests ───────────────────────────────────────────────────

const testing = std.testing;

test "quoteIdentDoubleQuote: basic" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try quoteIdentDoubleQuote(w, "users");
    try w.flush();
    const out = try aw.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"users\"", out);
}

test "emitIndex: unique" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    var needs_comma = false;
    try emitIndex(w, .{ .kind = .unique, .name = "uk_email", .fields = &.{"email"} }, &needs_comma);
    try w.flush();
    const out = try aw.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "UNIQUE") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"email\"") != null);
}

test "emitIndex: regular is no-op" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    var needs_comma = false;
    try emitIndex(w, .{ .kind = .regular, .name = "idx_foo", .fields = &.{"col"} }, &needs_comma);
    try w.flush();
    const out = try aw.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "emitAlterDropColumn: double-quoted" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try emitAlterDropColumn(w, "age");
    try w.flush();
    const out = try aw.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("DROP COLUMN \"age\"", out);
}

test "emitAlterRenameColumn: double-quoted" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try emitAlterRenameColumn(w, "old_name", "new_name");
    try w.flush();
    const out = try aw.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("RENAME COLUMN \"old_name\" TO \"new_name\"", out);
}
