const std = @import("std");
const typed_ast = @import("types/typed_ast.zig");
const Writer = std.Io.Writer;

// ─── JSON Schema Generator ──────────────────────────────────
// Consumes TypedAst directly (no SQL dialect needed).
// Output: JSON Schema draft-07 document.
//
// Architecture: TypedAst → JSON Schema
//   Each table → object property
//   Each column → property with type from SqlType.toJsonSchema()
//   Non-nullable → required array
//   Comment → description
//   Enum values → enum array

pub fn generate(alloc: std.mem.Allocator, typed: typed_ast.TypedAst) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    try w.writeAll("{\n");
    try w.writeAll("  \"$schema\": \"http://json-schema.org/draft-07/schema#\",\n");

    // Title from schema name
    if (typed.schema_name) |name| {
        try w.print("  \"title\": \"{s}\",\n", .{name});
    } else {
        try w.writeAll("  \"title\": \"rune-schema\",\n");
    }

    try w.writeAll("  \"type\": \"object\",\n");
    try w.writeAll("  \"properties\": {\n");

    for (typed.tables, 0..) |table, ti| {
        if (ti > 0) try w.writeAll(",\n");
        try writeTable(alloc, w, table);
    }

    if (typed.tables.len > 0) try w.writeAll("\n");
    try w.writeAll("  }\n");
    try w.writeAll("}\n");

    try w.flush();
    var out = aw.toArrayList();
    return try out.toOwnedSlice(alloc);
}

fn writeTable(alloc: std.mem.Allocator, w: *Writer, table: typed_ast.TypedTable) !void {
    _ = alloc;
    try w.print("    \"{s}\": {{\n", .{table.name});
    try w.writeAll("      \"type\": \"object\",\n");

    // Description from comment
    if (table.comment) |c| {
        if (c.len > 0) {
            try w.print("      \"description\": \"{s}\",\n", .{c});
        }
    }

    // Properties
    try w.writeAll("      \"properties\": {\n");
    for (table.columns, 0..) |col, ci| {
        if (ci > 0) try w.writeAll(",\n");
        try w.print("        \"{s}\": ", .{col.name});
        try col.sql_type.toJsonSchema(w);
    }
    if (table.columns.len > 0) try w.writeAll("\n");
    try w.writeAll("      },\n");

    // Required: non-nullable columns
    try w.writeAll("      \"required\": [");
    var first = true;
    for (table.columns) |col| {
        if (!col.flags.nullable) {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\"", .{col.name});
        }
    }
    try w.writeAll("]\n");

    try w.writeAll("    }");
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

fn makeTestColumn(name: []const u8, sql_type: typed_ast.SqlType) typed_ast.TypedColumn {
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

test "json_schema: int column" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const col = makeTestColumn("id", .int);
    try col.sql_type.toJsonSchema(w);
    try w.flush();
    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);
    try testing.expectEqualStrings("{\"type\":\"integer\"}", result);
}

test "json_schema: varchar column" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const col = makeTestColumn("name", .{ .varchar = 64 });
    try col.sql_type.toJsonSchema(w);
    try w.flush();
    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);
    try testing.expectEqualStrings("{\"type\":\"string\",\"maxLength\":64}", result);
}

test "json_schema: boolean column" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const col = makeTestColumn("active", .boolean);
    try col.sql_type.toJsonSchema(w);
    try w.flush();
    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);
    try testing.expectEqualStrings("{\"type\":\"boolean\"}", result);
}

test "json_schema: enum column" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const vals = try alloc.dupe([]const u8, &.{ "active", "inactive", "banned" });
    const col = makeTestColumn("status", .{ .enum_values = vals });
    try col.sql_type.toJsonSchema(w);
    try w.flush();
    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);
    try testing.expect(std.mem.indexOf(u8, result, "\"enum\":[\"active\",\"inactive\",\"banned\"]") != null);
}

test "json_schema: decimal column" {
    const alloc = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const col = makeTestColumn("price", .{ .decimal = .{ .precision = 10, .scale = 2 } });
    try col.sql_type.toJsonSchema(w);
    try w.flush();
    var out = aw.toArrayList();
    const result = try out.toOwnedSlice(alloc);
    try testing.expect(std.mem.indexOf(u8, result, "\"type\":\"number\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"multipleOf\"") != null);
}
