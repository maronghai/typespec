const std = @import("std");
const ast = @import("../../types/ast.zig");
const PassContext = @import("../analyzer.zig").PassContext;
const FkDecl = ast.FkDecl;
const ResolvedTable = ast.ResolvedTable;

/// Helper: validate a single FK declaration against the table and schema.
fn validateFk(ctx: *PassContext, table_names: *const std.StringHashMap(void), table: ResolvedTable, fk: FkDecl) !void {
    for (fk.fields) |fk_field| {
        var found = false;
        for (table.fields) |field| {
            if (std.mem.eql(u8, field.name, fk_field)) {
                found = true;
                break;
            }
        }
        if (!found) {
            ctx.diagnostics.push(.{
                .severity = .warning,
                .line_no = table.line_no,
                .message = try std.fmt.allocPrint(ctx.alloc, "FK field '{s}' not found in table '{s}' — may be an implicit field from ultra shorthand", .{ fk_field, table.name }),
            });
        }
    }
    if (fk.ref_table.len > 0 and !table_names.contains(fk.ref_table)) {
        ctx.diagnostics.push(.{
            .severity = .warning,
            .line_no = table.line_no,
            .message = try std.fmt.allocPrint(ctx.alloc, "FK references non-existent table '{s}' in table '{s}'", .{ fk.ref_table, table.name }),
        });
    }
}

/// Semantic validation: FK reference checks, field name duplicates.
pub fn run(ctx: *PassContext) !void {
    var table_names = std.StringHashMap(void).init(ctx.alloc);
    for (ctx.tables.items) |t| {
        try table_names.put(t.name, {});
    }

    for (ctx.tables.items) |table| {
        var field_names = std.StringHashMap(usize).init(ctx.alloc);
        defer field_names.deinit();
        for (table.fields, 0..) |field, fi| {
            if (std.mem.eql(u8, field.name, "...")) continue;
            if (field_names.get(field.name)) |_| {
                ctx.diagnostics.push(.{
                    .severity = .warning,
                    .line_no = field.line_no,
                    .message = try std.fmt.allocPrint(ctx.alloc, "duplicate field '{s}' in table '{s}'", .{ field.name, table.name }),
                });
            }
            try field_names.put(field.name, fi);
        }

        for (table.fks) |fk| {
            try validateFk(ctx, &table_names, table, fk);
        }
        for (table.fields) |field| {
            if (field.fk) |fk| {
                try validateFk(ctx, &table_names, table, fk);
            }
        }
    }
}
