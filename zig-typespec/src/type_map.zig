const std = @import("std");
const ast_mod = @import("ast.zig");
const TypeInfo = ast_mod.TypeInfo;
const dialect_enum = @import("dialect_enum.zig");
const type_registry = @import("type_registry.zig");

// ─── Unified Type Mapping (Forward Only) ─────────────────────
//
// Single source of truth for TPS → SQL type mappings.
// Used by codegen (forward) and typed_ast (type resolution).
//
// For reverse mappings (SQL → TPS), see reverse_map.zig.

pub const Dialect = dialect_enum.Dialect;

// ─── Forward Mapping: TPS → SQL ──────────────────────────────
//
// Only single-char TPS symbols. These are the core type vocabulary
// that users write in .tps files.

pub const ForwardMapping = struct {
    tps: []const u8,
    mysql: []const u8,
    pg: []const u8,
    sqlite: []const u8,
};

pub const FORWARD_MAP = [_]ForwardMapping{
    .{ .tps = "n", .mysql = "int", .pg = "integer", .sqlite = "INTEGER" },
    .{ .tps = "N", .mysql = "bigint", .pg = "bigint", .sqlite = "INTEGER" },
    .{ .tps = "m", .mysql = "decimal(16, 2)", .pg = "numeric(16, 2)", .sqlite = "NUMERIC" },
    .{ .tps = "M", .mysql = "decimal(20, 6)", .pg = "numeric(20, 6)", .sqlite = "NUMERIC" },
    .{ .tps = "S", .mysql = "text", .pg = "text", .sqlite = "TEXT" },
    .{ .tps = "b", .mysql = "boolean", .pg = "boolean", .sqlite = "INTEGER" },
    .{ .tps = "B", .mysql = "blob", .pg = "bytea", .sqlite = "BLOB" },
    .{ .tps = "j", .mysql = "json", .pg = "json", .sqlite = "TEXT" },
    .{ .tps = "d", .mysql = "date", .pg = "date", .sqlite = "TEXT" },
    .{ .tps = "t", .mysql = "datetime", .pg = "timestamp", .sqlite = "TEXT" },
};

// ─── Forward Mapping: TPS → SQL ──────────────────────────────

pub fn toSqlType(w: anytype, dialect: Dialect, type_info: TypeInfo) !void {
    switch (type_info) {
        .none => try w.writeAll("varchar(255)"),
        .simple => {
            const s = type_info.simple;
            if (s.len == 1) {
                // Single-char: lookup in FORWARD_MAP
                for (FORWARD_MAP) |m| {
                    if (m.tps[0] == s[0]) {
                        const sql_type = switch (dialect) {
                            .mysql => m.mysql,
                            .pg => m.pg,
                            .sqlite => m.sqlite,
                        };
                        // For PG/SQLite integer, strip display width (PG/SQLite ignore it)
                        if (dialect != .mysql and std.mem.startsWith(u8, sql_type, "int(")) {
                            try w.writeAll("integer");
                        } else {
                            try w.writeAll(sql_type);
                        }
                        return;
                    }
                }
                try w.writeAll(s);
            } else {
                // Multi-char: pass through (used for PG-specific types in forward path)
                try w.writeAll(s);
            }
        },
        .int_explicit => |n| {
            if (dialect == .mysql) {
                try w.print("int({d})", .{n});
            } else {
                try w.writeAll("integer");
            }
        },
        .decimal_explicit => |ds| {
            const type_name: []const u8 = switch (dialect) {
                .mysql => "decimal",
                .pg => "numeric",
                .sqlite => "NUMERIC",
            };
            try w.print("{s}({d}, {d})", .{ type_name, ds.precision, ds.scale });
        },
        .varchar_explicit => |n| {
            if (n > 0) {
                try w.print("varchar({d})", .{n});
            } else {
                try w.writeAll("TEXT");
            }
        },
        .raw_sql => |sql| try w.writeAll(sql),
        .enum_type => |vals| {
            switch (dialect) {
                .mysql => {
                    try w.writeAll("ENUM(");
                    for (vals, 0..) |v, vi| {
                        if (vi > 0) try w.writeAll(", ");
                        try w.print("'{s}'", .{v});
                    }
                    try w.writeAll(")");
                },
                .pg, .sqlite => {
                    try w.writeAll("TEXT");
                },
            }
        },
    }
}

/// Allocating version of toSqlType — returns a heap-allocated SQL type string.
/// Used by typed_ast.zig resolveColumn to avoid duplicating the type mapping logic.
pub fn toSqlTypeAlloc(alloc: std.mem.Allocator, dialect: Dialect, type_info: TypeInfo) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    try toSqlType(&aw.writer, dialect, type_info);
    var out = aw.toArrayList();
    return try out.toOwnedSlice(alloc);
}

// ─── Helper: classify TPS type symbols ───────────────────────

pub fn isNumericTpsType(ti: TypeInfo) bool {
    switch (ti) {
        .simple => |s| return std.mem.eql(u8, s, "n") or std.mem.eql(u8, s, "N"),
        .int_explicit, .decimal_explicit => return true,
        else => return false,
    }
}

pub fn isDatetimeTpsType(ti: TypeInfo) bool {
    switch (ti) {
        .simple => |s| return std.mem.eql(u8, s, "t") or std.mem.eql(u8, s, "d"),
        else => return false,
    }
}

// ─── Custom Type Lookup ──────────────────────────────────────

/// Look up a custom type by name in the schema's custom_types list.
/// Returns the resolved TypeInfo for the given dialect, checking dialect-specific
/// overrides first, then falling back to the base type.
pub fn lookupCustomType(
    custom_types: []const ast_mod.CustomType,
    type_name: []const u8,
    dialect: Dialect,
) ?TypeInfo {
    for (custom_types) |ct| {
        if (std.mem.eql(u8, ct.name, type_name)) {
            // Check dialect-specific overrides first
            for (ct.dialect_overrides) |ov| {
                const dname = switch (dialect) {
                    .mysql => "mysql",
                    .pg => "postgres",
                    .sqlite => "sqlite",
                };
                if (std.mem.eql(u8, ov.dialect, dname)) {
                    return ov.type_info;
                }
            }
            // Fall back to base type
            return ct.base;
        }
    }
    return null;
}

// ─── Tests ────────────────────────────────────────────────────

test "forward: n maps to int in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .simple = "n" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("int", result);
}

test "forward: n maps to integer in PostgreSQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .pg, .{ .simple = "n" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("integer", result);
}

test "forward: s maps to varchar in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .simple = "s" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(255)", result);
}

test "forward: t maps to datetime in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .simple = "t" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("datetime", result);
}

test "forward: t maps to timestamp in PostgreSQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .pg, .{ .simple = "t" });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("timestamp", result);
}

test "forward: none maps to varchar(255)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .none);
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(255)", result);
}

test "forward: int_explicit(11) maps to int(11) in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .int_explicit = 11 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("int(11)", result);
}

test "forward: int_explicit(11) maps to integer in PG" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .pg, .{ .int_explicit = 11 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("integer", result);
}

test "forward: decimal_explicit maps correctly per dialect" {
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try toSqlType(&aw.writer, .mysql, .{ .decimal_explicit = .{ .precision = 10, .scale = 2 } });
        try aw.flush();
        const out = aw.toArrayList();
        const result = try out.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("decimal(10, 2)", result);
    }
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try toSqlType(&aw.writer, .pg, .{ .decimal_explicit = .{ .precision = 10, .scale = 2 } });
        try aw.flush();
        const out = aw.toArrayList();
        const result = try out.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings("numeric(10, 2)", result);
    }
}

test "forward: varchar_explicit(128) maps to varchar(128)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .varchar_explicit = 128 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(128)", result);
}

test "forward: varchar_explicit(0) maps to varchar(255)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .mysql, .{ .varchar_explicit = 0 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(255)", result);
}

test "forward: varchar_explicit maps to varchar(N) in SQLite" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try toSqlType(&aw.writer, .sqlite, .{ .varchar_explicit = 128 });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("varchar(128)", result);
}

test "forward: enum_type maps to ENUM in MySQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const vals = [_][]const u8{ "M", "F", "X" };
    try toSqlType(&aw.writer, .mysql, .{ .enum_type = &vals });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ENUM('M', 'F', 'X')", result);
}

test "forward: enum_type maps to TEXT in PostgreSQL" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const vals = [_][]const u8{ "M", "F" };
    try toSqlType(&aw.writer, .pg, .{ .enum_type = &vals });
    try aw.flush();
    const out = aw.toArrayList();
    const result = try out.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("TEXT", result);
}

test "isDatetimeTpsType: t is datetime" {
    try std.testing.expect(isDatetimeTpsType(.{ .simple = "t" }));
}

test "isDatetimeTpsType: d is datetime" {
    try std.testing.expect(isDatetimeTpsType(.{ .simple = "d" }));
}

test "isDatetimeTpsType: n is not datetime" {
    try std.testing.expect(!isDatetimeTpsType(.{ .simple = "n" }));
}

test "isNumericTpsType: n is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .simple = "n" }));
}

test "isNumericTpsType: N is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .simple = "N" }));
}

test "isNumericTpsType: s is not numeric" {
    try std.testing.expect(!isNumericTpsType(.{ .simple = "s" }));
}

test "isNumericTpsType: int_explicit is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .int_explicit = 11 }));
}

test "isNumericTpsType: decimal_explicit is numeric" {
    try std.testing.expect(isNumericTpsType(.{ .decimal_explicit = .{ .precision = 10, .scale = 2 } }));
}
