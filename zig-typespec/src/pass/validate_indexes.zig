const std = @import("std");
const ast = @import("../ast.zig");
const PassContext = @import("../semantic.zig").PassContext;

/// Validate index declarations: duplicate names, non-existent column references.
pub fn run(ctx: *PassContext) !void {
    for (ctx.tables.items) |*table| {
        for (table.indexes, 0..) |idx, i| {
            if (idx.name.len == 0) continue;
            for (table.indexes[i + 1 ..]) |other| {
                if (std.mem.eql(u8, idx.name, other.name)) {
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = other.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "duplicate index name '{s}' in table '{s}'", .{ idx.name, table.name }) catch return,
                    });
                }
            }
        }
        for (table.indexes) |idx| {
            for (idx.fields) |field_name| {
                var found = false;
                for (table.fields) |col| {
                    if (std.mem.eql(u8, col.name, field_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = idx.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "index '{s}' references non-existent column '{s}' in table '{s}'", .{ idx.name, field_name, table.name }) catch return,
                    });
                }
            }
        }
    }
}
