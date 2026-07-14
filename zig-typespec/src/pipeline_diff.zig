const std = @import("std");
const codegen = @import("codegen.zig");
const diff = @import("diff.zig");
const migrate = @import("migrate.zig");
const pipeline_forward = @import("pipeline_forward.zig");

// ─── Diff/Migrate Pipeline ────────────────────────────────────

pub fn handleDiff(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, dialect: codegen.Dialect) !void {
    const old_ast = try pipeline_forward.compileToAst(io, alloc, old_path);
    const new_ast = try pipeline_forward.compileToAst(io, alloc, new_path);
    const schema_diff = try diff.diff(old_ast, new_ast, alloc);
    const diff_text = try diff.formatDiff(alloc, schema_diff, dialect);
    try @import("io.zig").writeOutput(io, diff_text, null);
}

pub fn handleMigrate(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, output_path: ?[]const u8, dialect: codegen.Dialect) !void {
    const old_ast = try pipeline_forward.compileToAst(io, alloc, old_path);
    const new_ast = try pipeline_forward.compileToAst(io, alloc, new_path);
    const schema_diff = try diff.diff(old_ast, new_ast, alloc);
    const migration_sql = try migrate.generateFromDiff(alloc, schema_diff, old_ast, new_ast, dialect);
    try @import("io.zig").writeOutput(io, migration_sql, output_path);
}
