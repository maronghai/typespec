const std = @import("std");
const ast = @import("../ast.zig");
const PassContext = @import("../semantic.zig").PassContext;
const FkDecl = ast.FkDecl;
const ResolvedTable = ast.ResolvedTable;

const VisitStatus = enum { visiting, visited };

/// Validate that FK target fields exist in the referenced table.
fn validateFkTargetFields(
    ctx: *PassContext,
    table_map: *const std.StringHashMap(*const ResolvedTable),
    table: ResolvedTable,
    fk: FkDecl,
) !void {
    if (fk.ref_table.len == 0) return;
    const target = table_map.get(fk.ref_table) orelse return;

    for (fk.ref_fields) |ref_field| {
        var found = false;
        for (target.fields) |field| {
            if (std.mem.eql(u8, field.name, ref_field)) {
                found = true;
                break;
            }
        }
        if (!found) {
            ctx.diagnostics.push(.{
                .severity = .@"error",
                .line_no = fk.line_no,
                .message = std.fmt.allocPrint(ctx.alloc, "FK references non-existent field '{s}' in table '{s}' (from table '{s}')", .{ ref_field, fk.ref_table, table.name }) catch return,
            });
        }
    }
}

/// DFS-based cycle detection in the FK dependency graph.
fn detectCycle(
    ctx: *PassContext,
    fk_graph: *const std.StringHashMap(std.ArrayList([]const u8)),
    visited: *std.StringHashMap(VisitStatus),
    stack: *std.ArrayList([]const u8),
    node: []const u8,
) !void {
    try visited.put(node, .visiting);
    try stack.append(ctx.alloc, node);

    if (fk_graph.get(node)) |refs| {
        for (refs.items) |ref_table| {
            if (visited.get(ref_table)) |status| {
                if (status == .visiting) {
                    var cycle_path = std.fmt.allocPrint(ctx.alloc, "{s}", .{ref_table}) catch return;
                    var i = stack.items.len;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, stack.items[i], ref_table)) break;
                        cycle_path = std.fmt.allocPrint(ctx.alloc, "{s} -> {s}", .{ stack.items[i], cycle_path }) catch return;
                    }
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = 0,
                        .message = std.fmt.allocPrint(ctx.alloc, "circular FK dependency detected: {s}", .{cycle_path}) catch return,
                    });
                }
            } else {
                try detectCycle(ctx, fk_graph, visited, stack, ref_table);
            }
        }
    }

    _ = stack.pop();
    try visited.put(node, .visited);
}

/// Schema-level semantic validation: circular FKs, FK target field existence,
/// self-referencing FK field count mismatch.
pub fn run(ctx: *PassContext) !void {
    var table_map = std.StringHashMap(*const ResolvedTable).init(ctx.alloc);
    for (ctx.tables.items) |*t| {
        try table_map.put(t.name, t);
    }

    var fk_graph = std.StringHashMap(std.ArrayList([]const u8)).init(ctx.alloc);
    defer {
        var git = fk_graph.iterator();
        while (git.next()) |entry| {
            entry.value_ptr.deinit(ctx.alloc);
        }
        fk_graph.deinit();
    }

    for (ctx.tables.items) |table| {
        var refs = try std.ArrayList([]const u8).initCapacity(ctx.alloc, 4);
        for (table.fks) |fk| {
            if (fk.ref_table.len > 0) {
                try refs.append(ctx.alloc, fk.ref_table);
            }
        }
        for (table.fields) |field| {
            if (field.fk) |fk| {
                if (fk.ref_table.len > 0) {
                    try refs.append(ctx.alloc, fk.ref_table);
                }
            }
        }
        try fk_graph.put(table.name, refs);
    }

    var visited = std.StringHashMap(VisitStatus).init(ctx.alloc);
    defer visited.deinit();

    var cycle_stack = try std.ArrayList([]const u8).initCapacity(ctx.alloc, 8);
    defer cycle_stack.deinit(ctx.alloc);

    for (ctx.tables.items) |table| {
        if (visited.contains(table.name)) continue;
        try detectCycle(ctx, &fk_graph, &visited, &cycle_stack, table.name);
    }

    for (ctx.tables.items) |table| {
        for (table.fks) |fk| {
            try validateFkTargetFields(ctx, &table_map, table, fk);
        }
        for (table.fields) |field| {
            if (field.fk) |fk| {
                try validateFkTargetFields(ctx, &table_map, table, fk);
            }
        }
    }

    for (ctx.tables.items) |table| {
        for (table.fks) |fk| {
            if (std.mem.eql(u8, fk.ref_table, table.name)) {
                if (fk.fields.len != fk.ref_fields.len) {
                    ctx.diagnostics.push(.{
                        .severity = .@"error",
                        .line_no = fk.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "self-referencing FK in table '{s}' has mismatched field count: {d} local vs {d} referenced", .{ table.name, fk.fields.len, fk.ref_fields.len }) catch return,
                    });
                }
            }
        }
        for (table.fields) |field| {
            if (field.fk) |fk| {
                if (std.mem.eql(u8, fk.ref_table, table.name)) {
                    if (fk.fields.len != fk.ref_fields.len) {
                        ctx.diagnostics.push(.{
                            .severity = .@"error",
                            .line_no = fk.line_no,
                            .message = std.fmt.allocPrint(ctx.alloc, "self-referencing FK in table '{s}' has mismatched field count: {d} local vs {d} referenced", .{ table.name, fk.fields.len, fk.ref_fields.len }) catch return,
                        });
                    }
                }
            }
        }
    }
}
