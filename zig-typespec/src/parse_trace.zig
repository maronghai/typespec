const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const trace = @import("trace.zig");

// ─── Diagnostic Trace ────────────────────────────────────────
// Debug output for parser results. Extracted from parser.zig for
// single-responsibility. Only used in trace mode.

pub fn diagnosticTrace(tree: Ast) void {
    std.debug.print("=== [Stage 2: Parser] ===\n\n", .{});

    if (tree.schema) |schema| {
        std.debug.print("Schema: {s}", .{schema.name});
        if (schema.charset) |cs| std.debug.print(" charset={s}", .{cs});
        if (schema.autofk) std.debug.print(" [autofk]", .{});
        std.debug.print("\n\n", .{});
    }

    if (tree.templates.len > 0) {
        std.debug.print("Templates ({d}):\n", .{tree.templates.len});
        for (tree.templates) |tmpl| {
            std.debug.print("  %% {s}", .{tmpl.name orelse "(default)"});
            if (tmpl.parents.len > 0) {
                std.debug.print(" > ", .{});
                for (tmpl.parents, 0..) |p, pi| {
                    if (pi > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{p});
                }
            }
            std.debug.print("  [{d} field(s)]\n", .{tmpl.fields.len});
            for (tmpl.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) {
                    std.debug.print("    ...\n", .{});
                    continue;
                }
                std.debug.print("    {s: <20} ", .{field.name});
                trace.fmtTypeInfo(field.type_info);
                trace.fmtModifiers(field.modifiers);
                if (field.default_val) |dv| std.debug.print(" ={s}", .{dv.value});
                if (field.check) |ck| std.debug.print(" [{s}]", .{ck.expr});
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    if (tree.tables.len > 0) {
        std.debug.print("Tables ({d}):\n", .{tree.tables.len});
        for (tree.tables) |table| {
            std.debug.print("  # {s}", .{table.name});
            if (table.template_ref) |tr| std.debug.print(" (ref={s})", .{tr});
            if (table.comment) |c| std.debug.print(" {s}", .{c});
            std.debug.print("\n", .{});
            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                std.debug.print("    {s: <20} ", .{field.name});
                trace.fmtTypeInfo(field.type_info);
                trace.fmtModifiers(field.modifiers);
                if (field.default_val) |dv| std.debug.print(" ={s}", .{dv.value});
                if (field.check) |ck| std.debug.print(" [{s}]", .{ck.expr});
                if (field.fk) |fk| {
                    trace.formatFk(fk);
                }
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
            for (table.fks) |fk| {
                trace.formatResolvedFk(fk);
            }
            for (table.indexes) |idx| {
                trace.formatIndex(idx);
            }
        }
        std.debug.print("\n", .{});
    }

    if (tree.sql_comments.len > 0) {
        std.debug.print("SQL Comments ({d}):\n", .{tree.sql_comments.len});
        for (tree.sql_comments) |sc| {
            std.debug.print("  L{d}: {s}\n", .{ sc.line_no, sc.text });
        }
        std.debug.print("\n", .{});
    }
}
