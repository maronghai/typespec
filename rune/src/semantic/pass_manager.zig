const std = @import("std");
pub const ast_mod = @import("../types/ast.zig");
const diag = @import("../semantic/diagnostic.zig");
const symbol_table_mod = @import("../types/symbol_table.zig");
const ResolvedTable = ast_mod.ResolvedTable;
const Template = ast_mod.Template;

// ─── Pass Manager ──────────────────────────────────────────────
// Extracted from semantic.zig (was analyzer.zig) for single-responsibility.

/// Shared mutable context passed to each semantic pass.
pub const PassContext = struct {
    alloc: std.mem.Allocator,
    tables: *std.ArrayList(ResolvedTable),
    schema: ?ast_mod.Schema,
    templates: std.StringHashMap(*const Template) = undefined,
    diagnostics: *diag.DiagnosticCollector = undefined,
    symbol_table: symbol_table_mod.SymbolTable = undefined,
};

/// A semantic analysis pass that transforms the tables in PassContext.
pub const SemanticPass = struct {
    name: []const u8,
    run: *const fn (ctx: *PassContext) anyerror!void,
    depends_on: []const []const u8 = &.{},
};

/// Default pass pipeline — order matters!
pub const DEFAULT_PASSES = [_]SemanticPass{
    .{ .name = "validate_template_types", .run = @import("pass/validate_template_types.zig").run, .depends_on = &.{} },
    .{ .name = "resolve_names", .run = @import("pass/resolve_names.zig").run, .depends_on = &.{"validate_template_types"} },
    .{ .name = "autofk", .run = @import("pass/autofk.zig").run, .depends_on = &.{} },
    .{ .name = "suffix_inference", .run = @import("pass/suffix_inference.zig").run, .depends_on = &.{"autofk"} },
    .{ .name = "validate", .run = @import("pass/validate.zig").run, .depends_on = &.{ "autofk", "suffix_inference" } },
    .{ .name = "validate_type_modifiers", .run = @import("pass/validate_type_modifiers.zig").run, .depends_on = &.{"suffix_inference"} },
    .{ .name = "validate_indexes", .run = @import("pass/validate_indexes.zig").run, .depends_on = &.{"autofk"} },
    .{ .name = "validate_schema", .run = @import("pass/validate_schema.zig").run, .depends_on = &.{ "validate", "resolve_names" } },
};

/// Validate dependency ordering at runtime (comptime safety check).
pub fn validateDependencyOrder() void {
    if (comptime std.debug.runtime_safety) {
        var seen_names = std.StringHashMap(void).init(std.heap.page_allocator);
        defer seen_names.deinit();
        for (DEFAULT_PASSES) |pass| {
            for (pass.depends_on) |dep| {
                if (!seen_names.contains(dep)) {
                    std.debug.panic("SemanticPass '{s}' depends on '{s}' which has not run yet", .{ pass.name, dep });
                }
            }
            seen_names.put(pass.name, {}) catch unreachable;
        }
    }
}
