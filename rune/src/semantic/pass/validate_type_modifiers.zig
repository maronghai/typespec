const std = @import("std");
const ast = @import("../../types/ast.zig");
const diag = @import("../diagnostic.zig");
const type_map = @import("../../types/type_map.zig");
const ast_visitor = @import("../../ast_visitor.zig");
const PassContext = @import("../analyzer.zig").PassContext;
const Field = ast.Field;
const Modifier = ast.Modifier;

const ModifierValidationCtx = struct {
    alloc: std.mem.Allocator,
    diagnostics: *diag.DiagnosticCollector,
};

fn visitFieldCheckModifiers(ctx: *ModifierValidationCtx, field: *const Field, _: ?[]const u8) void {
    for (field.modifiers) |mod| {
        switch (mod.kind) {
            .auto_inc_pk, .auto_inc => {
                if (!type_map.isNumericSymType(field.type_info) and !type_map.isDatetimeSymType(field.type_info)) {
                    const mod_name = if (mod.kind == .auto_inc_pk) "auto_increment" else "auto_increment";
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = mod.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "'{s}' modifier has no effect on non-numeric/non-datetime type in field '{s}'", .{ mod_name, field.name }) catch return,
                    });
                }
            },
            .primary_key => {},
            .not_null => {},
            .unsigned => {
                if (!type_map.isNumericSymType(field.type_info)) {
                    ctx.diagnostics.push(.{
                        .severity = .warning,
                        .line_no = mod.line_no,
                        .message = std.fmt.allocPrint(ctx.alloc, "'unsigned' modifier has no effect on non-numeric type in field '{s}'", .{field.name}) catch return,
                    });
                }
            },
            .inline_unique => {},
            .inline_index => {},
        }
    }
}

/// Validates that modifiers are used with compatible types.
pub fn run(ctx: *PassContext) !void {
    var vctx = ModifierValidationCtx{
        .alloc = ctx.alloc,
        .diagnostics = ctx.diagnostics,
    };

    const visitor = ast_visitor.AstVisitor(*ModifierValidationCtx){
        .context = &vctx,
        .visitField = visitFieldCheckModifiers,
    };

    visitor.walkResolvedTables(ctx.tables.items);
}
