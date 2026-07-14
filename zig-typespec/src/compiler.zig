const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const ast_mod = @import("ast.zig");
const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");
const typed_ast = @import("typed_ast.zig");
const diag = @import("diagnostic.zig");
const diff = @import("diff.zig");
const migrate = @import("migrate.zig");
const sql_parser = @import("sql_parser.zig");
const reverse_codegen = @import("reverse_codegen.zig");

// ─── Shared Pipeline ──────────────────────────────────────────

/// Intermediate results from the compilation pipeline.
/// Returned by compilePipeline so trace mode can inspect each stage
/// without re-running the pipeline.
pub const PipelineResult = struct {
    resolved: semantic.ResolvedAst,
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

// ─── Command Handlers ──────────────────────────────────────────

pub fn handleCompile(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, trace: bool, dialect: codegen.Dialect) !void {
    _ = input_name;

    const pipeline = try compilePipeline(io, alloc, file_data);

    var tr = typed_ast.TypeResolver.init(alloc);
    const typed = try tr.resolve(pipeline.resolved, dialect);

    var cg = codegen.Codegen.init(alloc, dialect);
    const sql = try cg.generateFromTypedAst(typed);

    if (trace) {
        tokenizer.Tokenizer.diagnosticTrace(pipeline.lines);
        parser.diagnosticTrace(pipeline.tree);
        semantic.diagnosticTrace(pipeline.resolved);
        codegen.diagnosticTrace(sql);
    }

    try writeOutput(io, sql, output_path);
}

pub fn compileToAst(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !semantic.ResolvedAst {
    const file_data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    const pipeline = try compilePipeline(io, alloc, file_data);
    return pipeline.resolved;
}

pub fn handleDiff(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, _: codegen.Dialect) !void {
    const old_ast = try compileToAst(io, alloc, old_path);
    const new_ast = try compileToAst(io, alloc, new_path);
    const schema_diff = try diff.diff(old_ast, new_ast, alloc);
    const diff_text = try diff.formatDiff(alloc, schema_diff);
    try writeOutput(io, diff_text, null);
}

pub fn handleMigrate(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, output_path: ?[]const u8, dialect: codegen.Dialect) !void {
    const old_ast = try compileToAst(io, alloc, old_path);
    const new_ast = try compileToAst(io, alloc, new_path);
    const schema_diff = try diff.diff(old_ast, new_ast, alloc);
    const migration_sql = try migrate.generateFromDiff(alloc, schema_diff, old_ast, new_ast, dialect);
    try writeOutput(io, migration_sql, output_path);
}

/// Auto-detect SQL dialect from content patterns.
/// Returns SQLite if content has SQLite-specific patterns, otherwise MySQL.
pub fn detectSqlDialect(sql: []const u8) codegen.Dialect {
    const sqlite_patterns = [_][]const u8{
        "AUTOINCREMENT",
        "INTEGER PRIMARY KEY",
    };
    for (sqlite_patterns) |pat| {
        if (std.mem.indexOf(u8, sql, pat) != null) return .sqlite;
    }
    if (std.mem.indexOf(u8, sql, "CREATE TABLE \"") != null) return .sqlite;
    return .mysql;
}

pub fn handleReverse(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, with_templates: bool, dialect: codegen.Dialect) !void {
    // Auto-detect dialect from SQL content when not explicitly specified
    const sql_dialect: sql_parser.Dialect = if (dialect == .mysql) detectSqlDialect(file_data) else dialect;

    // Use DiagnosticCollector for consistent error handling with forward pipeline
    var diagnostics = diag.DiagnosticCollector.init(alloc);

    var sp_parser = sql_parser.SqlParser.init(alloc, file_data, sql_dialect);
    const result = sp_parser.parse() catch |err| {
        const lc = sp_parser.lineColAt(sp_parser.pos);
        const src_line = sp_parser.getSourceLine(lc.line);
        diagnostics.record(.{
            .severity = .@"error",
            .line_no = lc.line,
            .col = lc.col,
            .file = input_name,
            .message = "SQL syntax error",
            .source_line = src_line,
            .actual = @errorName(err),
        });
        diagnostics.printAll();
        diagnostics.printSummary();
        return error.SqlParseError;
    };
    const schema = result.schema;

    for (result.diagnostics) |d| {
        diagnostics.record(.{
            .severity = if (d.severity == .@"error") .@"error" else .warning,
            .line_no = d.line_no,
            .col = d.col,
            .file = input_name,
            .message = d.message,
            .source_line = d.context,
        });
    }

    if (diagnostics.hasErrors()) {
        diagnostics.printAll();
        diagnostics.printSummary();
        return error.ReverseDiagnosticsError;
    }

    if (schema.tables.len == 0) {
        std.debug.print("warning: no tables found in SQL input\n", .{});
    }

    var rcg = reverse_codegen.ReverseCodegen.init(alloc, sql_dialect);
    const tps = if (with_templates)
        try rcg.generateWithTemplates(schema)
    else
        try rcg.generate(schema);

    try writeOutput(io, tps, output_path);
}

// ─── I/O Helpers ───────────────────────────────────────────────

pub fn readStdin(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    const stdin_file = std.Io.File.stdin();
    var buf: [4096]u8 = undefined;
    var r = stdin_file.readerStreaming(io, &buf);
    var result = try std.ArrayList(u8).initCapacity(alloc, 4096);
    r.interface.appendRemainingUnlimited(alloc, &result) catch |e| {
        if (result.items.len == 0) return e;
    };
    return try result.toOwnedSlice(alloc);
}

pub fn readFileOrStdin(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        return readStdin(io, alloc);
    }
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

pub fn writeOutput(io: std.Io, data: []const u8, output_path: ?[]const u8) !void {
    if (output_path) |opath| {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = opath,
            .data = data,
        });
        std.debug.print("Written to {s}\n", .{opath});
    } else {
        var buf: [8192]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var w = stdout_file.writer(io, &buf);
        try w.interface.writeAll(data);
        try w.flush();
    }
}
