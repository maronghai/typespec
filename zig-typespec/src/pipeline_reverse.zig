const std = @import("std");
const diag = @import("diagnostic.zig");
const sql_parser = @import("sql_parser.zig");
const reverse_codegen = @import("reverse_codegen.zig");
const codegen = @import("codegen.zig");
const io_mod = @import("io.zig");

// ─── Reverse Pipeline: SQL → .tps ─────────────────────────────

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

    try io_mod.writeOutput(io, tps, output_path);
}
