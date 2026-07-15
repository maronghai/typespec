const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const ast_mod = @import("ast.zig");
const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");
const typed_ast = @import("typed_ast.zig");
const json_schema = @import("json_schema.zig");
const diag = @import("diagnostic.zig");
const io_mod = @import("io.zig");
const cli = @import("cli.zig");

// ─── Forward Pipeline: .tps → SQL ─────────────────────────────

/// Intermediate results from the compilation pipeline.
/// Returned by compilePipeline so trace mode can inspect each stage
/// without re-running the pipeline.
pub const PipelineResult = struct {
    resolved: ast_mod.ResolvedAst,
    lines: []tokenizer.Line,
    tree: ast_mod.Ast,
};

/// Shared tokenizer → parser → semantic pipeline.
/// Returns PipelineResult with all intermediate IRs for trace inspection.
pub fn compilePipeline(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8) !PipelineResult {
    _ = io;
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);

    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }

    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);

    // Use DiagnosticCollector for multi-error recovery
    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var p = parser.Parser.initWithDiagnostics(alloc, &diagnostics);
    const tree = p.parse(tokenized) catch |err| {
        // Allocation errors propagate; syntax errors are collected
        if (!diagnostics.hasErrors()) {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        return err;
    };

    // Print collected diagnostics and abort if any errors
    if (diagnostics.hasErrors()) {
        diagnostics.printAll();
        diagnostics.printSummary();
        return error.DiagnosticsError;
    }

    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = sa.analyze(tree) catch |err| {
        return err;
    };

    return .{ .resolved = resolved, .lines = tokenized, .tree = tree };
}

/// Compile a .tps file path to ResolvedAst (used by diff/migrate pipelines).
pub fn compileToAst(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !ast_mod.ResolvedAst {
    const file_data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    const pipeline = try compilePipeline(io, alloc, file_data);
    return pipeline.resolved;
}

pub fn handleCompile(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, trace: bool, dialect: codegen.Dialect, target: cli.Target) !void {
    _ = input_name;

    const pipeline = try compilePipeline(io, alloc, file_data);

    var tr = typed_ast.TypeResolver.init(alloc);
    const typed = try tr.resolve(pipeline.resolved, dialect);

    const output = switch (target) {
        .json_schema => try json_schema.generate(alloc, typed),
        .sql => blk: {
            var cg = codegen.Codegen.init(alloc, dialect);
            break :blk try cg.generateFromTypedAst(typed);
        },
    };

    if (trace) {
        tokenizer.Tokenizer.diagnosticTrace(pipeline.lines);
        parser.diagnosticTrace(pipeline.tree);
        semantic.diagnosticTrace(pipeline.resolved);
        if (target == .sql) {
            codegen.diagnosticTrace(output);
        }
    }

    try io_mod.writeOutput(io, output, output_path);
}
