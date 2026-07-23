const std = @import("std");
const ast_mod = @import("ast.zig");
const dialect_mod = @import("dialect.zig");
const typed_ast_mod = @import("typed_ast.zig");
const Writer = std.Io.Writer;

pub fn isDominatedByExplicitIndex(col_name: []const u8, explicit_indexes: []const ast_mod.IndexDecl, require_unique: bool) bool {
    for (explicit_indexes) |idx| {
        if (require_unique and idx.kind != .unique and idx.kind != .primary_key) continue;
        for (idx.fields) |f| {
            if (std.mem.eql(u8, f, col_name)) return true;
        }
    }
    return false;
}

pub fn emitDefault(w: *Writer, value: []const u8) !void {
    const is_num_val = blk: {
        _ = std.fmt.parseFloat(f64, value) catch break :blk false;
        break :blk true;
    };
    const is_sql_keyword = std.mem.eql(u8, value, "CURRENT_TIMESTAMP") or
        std.mem.eql(u8, value, "NULL") or
        std.mem.eql(u8, value, "NOW()");
    if (is_num_val or is_sql_keyword) {
        try w.print(" DEFAULT {s}", .{value});
    } else {
        try w.print(" DEFAULT '{s}'", .{value});
    }
}

pub fn emitColumnDef(backend: dialect_mod.DialectBackend, w: *Writer, col: typed_ast_mod.TypedColumn) !void {
    return emitColumnDefEx(backend, w, col, false);
}

pub fn emitColumnDefEx(backend: dialect_mod.DialectBackend, w: *Writer, col: typed_ast_mod.TypedColumn, skip_name: bool) !void {
    if (!skip_name) {
        try backend.quoteIdent(w, col.name);
        try w.writeAll(" ");
    }
    try backend.renderType(w, col.sql_type);

    if (col.flags.unsigned) {
        if (backend.emitUnsigned) |emit| try emit(w);
    }

    if (!col.flags.nullable) try w.writeAll(" NOT NULL");

    if (col.flags.auto_increment) {
        if (backend.emitAutoIncrement) |emit| try emit(w);
    }

    if (col.flags.has_timestamp_default) {
        try backend.emitTimestampModifier(w, col.flags.on_update_current_timestamp);
    }

    if (col.flags.primary_key) {
        try backend.emitPrimaryKey(w, col.flags.auto_increment);
    }

    if (col.default) |dv| try emitDefault(w, dv);
    if (col.check) |ck| {
        try w.writeAll(" CHECK (");
        try dialect_mod.emitCheckExpr(w, col.name, ck);
        try w.writeAll(")");
    }
    if (col.comment) |c| {
        try backend.emitInlineColumnComment(w, c);
    }
    if (col.flags.is_enum) {
        try backend.emitEnumTypeCheck(w, col.name, col.enum_values);
    }
}

// ─── Unit Tests ─────────────────────────────────────────────

const testing = std.testing;

fn makeTestColumn(name: []const u8, sql_type: typed_ast_mod.SqlType) typed_ast_mod.TypedColumn {
    return .{
        .name = name,
        .sql_type = sql_type,
        .flags = .{},
        .default = null,
        .check = null,
        .comment = null,
        .enum_values = &.{},
        .line_no = 1,
    };
}

test "emitColumnDef: MySQL table" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    const col = makeTestColumn("balance", "decimal(16, 2)");
    col.flags.nullable = false;
    col.flags.unsigned = true;
    col.default = "0";

    const backend = dialect_mod.getBackend(.mysql);
    try emitColumnDef(backend, w, col);
    try w.flush();

    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);

    try testing.expect(std.mem.indexOf(u8, result, "`balance`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "decimal(16, 2)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "UNSIGNED") != null);
    try testing.expect(std.mem.indexOf(u8, result, "NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, result, "DEFAULT 0") != null);
}

test "emitColumnDef: PG omits UNSIGNED" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    const col = makeTestColumn("count", "integer");
    col.flags.unsigned = true;

    const backend = dialect_mod.getBackend(.pg);
    try emitColumnDef(backend, w, col);
    try w.flush();

    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);

    try testing.expect(std.mem.indexOf(u8, result, "UNSIGNED") == null);
    try testing.expect(std.mem.indexOf(u8, result, "\"count\"") != null);
}
