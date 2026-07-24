const std = @import("std");
const ast = @import("../../types/ast.zig");
const PassContext = @import("../analyzer.zig").PassContext;
const symbol_table = @import("../../types/symbol_table.zig");

// ─── resolve_names pass ─────────────────────────────────────────
// Builds a SymbolTable and validates name uniqueness.
// Runs after validate_template_types (templates are resolved).
// Provides the SymbolTable on PassContext for downstream passes.

/// Build the symbol table from resolved tables and templates.
/// Validates that no two tables share the same name, and no table
/// name conflicts with a template name.
pub fn run(ctx: *PassContext) !void {
    var st = symbol_table.SymbolTable.init(ctx.alloc);

    // Register templates
    var templ_it = ctx.templates.iterator();
    while (templ_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (st.contains(name)) {
            ctx.diagnostics.push(.{
                .severity = .@"error",
                .line_no = 0,
                .message = std.fmt.allocPrint(ctx.alloc, "name conflict: '{s}' is used as both a template and a table", .{name}) catch return,
            });
            continue;
        }
        _ = try st.registerTemplate(name);
    }

    // Register tables (skip empty names or parser artifacts like ">")
    for (ctx.tables.items) |*table| {
        if (table.name.len == 0 or std.mem.eql(u8, table.name, ">") or std.mem.eql(u8, table.name, "+")) continue;
        if (st.contains(table.name)) {
            ctx.diagnostics.push(.{
                .severity = .@"error",
                .line_no = table.line_no,
                .message = std.fmt.allocPrint(ctx.alloc, "duplicate name: '{s}' is defined more than once", .{table.name}) catch return,
            });
            continue;
        }
        _ = try st.registerTable(table.name, table);
    }

    // Store the symbol table in PassContext for downstream passes
    ctx.symbol_table = st;
}
