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

// ─── Command Types ─────────────────────────────────────────────

const Command = union(enum) {
    compile: struct { input: ?[]const u8, output: ?[]const u8, trace: bool },
    diff: struct { old: []const u8, new: []const u8 },
    migrate: struct { old: []const u8, new: []const u8, output: ?[]const u8 },
    reverse: struct { input: ?[]const u8, output: ?[]const u8, with_templates: bool },
};

const ParsedArgs = struct {
    dialect: codegen.Dialect,
    command: Command,
};

// ─── Entry Point ───────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var args = try std.ArrayList([]const u8).initCapacity(alloc, 8);
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args.append(alloc, arg);
    }
    const arg_list = try args.toOwnedSlice(alloc);

    // No args: check stdin pipe vs interactive terminal
    if (arg_list.len < 2) {
        const is_tty = std.Io.File.stdin().isTty(init.io) catch true;
        if (is_tty) {
            printUsage();
            std.process.exit(1);
        }
        const file_data = try readStdin(init.io, alloc);
        return handleCompile(init.io, alloc, file_data, "<stdin>", null, false, .mysql);
    }

    const parsed = try parseArgs(alloc, arg_list);
    return dispatch(init.io, alloc, parsed);
}

// ─── Argument Parsing ──────────────────────────────────────────

fn parseArgs(alloc: std.mem.Allocator, raw_args: []const []const u8) !ParsedArgs {
    var dialect: codegen.Dialect = .mysql;
    var filtered = try std.ArrayList([]const u8).initCapacity(alloc, raw_args.len);

    // Pass 1: extract --dialect / -d from all args
    var i: usize = 1; // skip argv[0]
    while (i < raw_args.len) : (i += 1) {
        if (std.mem.eql(u8, raw_args[i], "--dialect") or std.mem.eql(u8, raw_args[i], "-d")) {
            if (i + 1 < raw_args.len) {
                dialect = parseDialect(raw_args[i + 1]) catch |e| {
                    if (e == error.UnknownDialect) {
                        std.debug.print("error: unknown dialect '{s}' (expected: mysql, pg, postgres, sqlite)\n", .{raw_args[i + 1]});
                        std.process.exit(1);
                    }
                    std.debug.print("error: --dialect requires a value (mysql, pg, postgres, sqlite)\n", .{});
                    std.process.exit(1);
                };
                i += 1; // skip dialect value
            } else {
                std.debug.print("error: --dialect requires a value (mysql, pg, postgres, sqlite)\n", .{});
                std.process.exit(1);
            }
        } else {
            try filtered.append(alloc, raw_args[i]);
        }
    }
    const fargs = try filtered.toOwnedSlice(alloc);

    // Pass 2: route subcommand
    if (fargs.len < 1) {
        return .{ .dialect = dialect, .command = .{ .compile = .{ .input = null, .output = null, .trace = false } } };
    }

    const sub = fargs[0];

    if (std.mem.eql(u8, sub, "diff")) {
        if (fargs.len < 3) {
            std.debug.print("error: diff requires <old.tps> <new.tps>\n", .{});
            std.process.exit(1);
        }
        return .{ .dialect = dialect, .command = .{ .diff = .{ .old = fargs[1], .new = fargs[2] } } };
    }

    if (std.mem.eql(u8, sub, "migrate")) {
        if (fargs.len < 3) {
            std.debug.print("error: migrate requires <old.tps> <new.tps>\n", .{});
            std.process.exit(1);
        }
        var output: ?[]const u8 = null;
        var j: usize = 3;
        while (j < fargs.len) : (j += 1) {
            if (std.mem.eql(u8, fargs[j], "-o") and j + 1 < fargs.len) {
                output = fargs[j + 1];
                j += 1;
            }
        }
        return .{ .dialect = dialect, .command = .{ .migrate = .{ .old = fargs[1], .new = fargs[2], .output = output } } };
    }

    if (std.mem.eql(u8, sub, "reverse")) {
        var output: ?[]const u8 = null;
        var with_templates = false;
        var input: ?[]const u8 = null;
        var j: usize = 1;
        while (j < fargs.len) : (j += 1) {
            if (std.mem.eql(u8, fargs[j], "-o") and j + 1 < fargs.len) {
                output = fargs[j + 1];
                j += 1;
            } else if (std.mem.eql(u8, fargs[j], "-t")) {
                with_templates = true;
            } else if (input == null) {
                input = fargs[j];
            }
        }
        return .{ .dialect = dialect, .command = .{ .reverse = .{ .input = input, .output = output, .with_templates = with_templates } } };
    }

    // Default: compile
    var output: ?[]const u8 = null;
    var trace = false;
    var j: usize = 1;
    while (j < fargs.len) : (j += 1) {
        if (std.mem.eql(u8, fargs[j], "-o") and j + 1 < fargs.len) {
            output = fargs[j + 1];
            j += 1;
        } else if (std.mem.eql(u8, fargs[j], "-t")) {
            trace = true;
        }
    }
    const input = if (fargs.len > 0) fargs[0] else null;
    return .{ .dialect = dialect, .command = .{ .compile = .{ .input = input, .output = output, .trace = trace } } };
}

fn parseDialect(s: []const u8) !codegen.Dialect {
    if (std.mem.eql(u8, s, "mysql")) return .mysql;
    if (std.mem.eql(u8, s, "pg") or std.mem.eql(u8, s, "postgres")) return .postgres;
    if (std.mem.eql(u8, s, "sqlite") or std.mem.eql(u8, s, "sq")) return .sqlite;
    return error.UnknownDialect;
}

// ─── Command Dispatch ──────────────────────────────────────────

fn dispatch(io: std.Io, alloc: std.mem.Allocator, parsed: ParsedArgs) !void {
    switch (parsed.command) {
        .compile => |cmd| {
            const file_data = if (cmd.input) |path|
                try readFileOrStdin(io, alloc, path)
            else
                try readStdin(io, alloc);
            const name = cmd.input orelse "<stdin>";
            return handleCompile(io, alloc, file_data, name, cmd.output, cmd.trace, parsed.dialect);
        },
        .diff => |cmd| return handleDiff(io, alloc, cmd.old, cmd.new, parsed.dialect),
        .migrate => |cmd| return handleMigrate(io, alloc, cmd.old, cmd.new, cmd.output, parsed.dialect),
        .reverse => |cmd| {
            const file_data = if (cmd.input) |path|
                try readFileOrStdin(io, alloc, path)
            else
                try readStdin(io, alloc);
            const name = cmd.input orelse "<stdin>";
            return handleReverse(io, alloc, file_data, name, cmd.output, cmd.with_templates, parsed.dialect);
        },
    }
}

// ─── Usage ─────────────────────────────────────────────────────

fn printUsage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  typespec [input.tps] [-o output.sql] [-t] [-d mysql|pg|sqlite]  Compile .tps to SQL DDL\n", .{});
    std.debug.print("  typespec diff <old.tps> <new.tps> [-d mysql|pg|sqlite]         Show schema differences\n", .{});
    std.debug.print("  typespec migrate <old.tps> <new.tps> [-o migration.sql] [-d mysql|pg|sqlite]\n", .{});
    std.debug.print("                                                           Generate ALTER TABLE migration SQL\n", .{});
    std.debug.print("  typespec reverse [input.sql] [-o output.tps] [-t] [-d mysql|pg|sqlite]\n", .{});
    std.debug.print("                                                           Reverse SQL DDL to .tps schema\n", .{});
    std.debug.print("                                                           -t: extract shared templates\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -d, --dialect  Target SQL dialect: mysql (default), pg, postgres, sqlite\n", .{});
    std.debug.print("\nPipe mode: read from stdin when no input file is given.\n", .{});
    std.debug.print("  echo '# t\\nid n' | typespec\n", .{});
    std.debug.print("  cat schema.sql | typespec reverse -t\n", .{});
}

// ─── I/O Helpers ───────────────────────────────────────────────

fn readStdin(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    const stdin_file = std.Io.File.stdin();
    var buf: [4096]u8 = undefined;
    var r = stdin_file.readerStreaming(io, &buf);
    var result = try std.ArrayList(u8).initCapacity(alloc, 4096);
    r.interface.appendRemainingUnlimited(alloc, &result) catch |e| {
        if (result.items.len == 0) return e;
    };
    return try result.toOwnedSlice(alloc);
}

fn readFileOrStdin(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        return readStdin(io, alloc);
    }
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

fn writeOutput(io: std.Io, data: []const u8, output_path: ?[]const u8) !void {
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

// ─── Shared Pipeline ──────────────────────────────────────────

/// Shared tokenizer → parser → semantic pipeline.
/// Returns ResolvedAst; callers decide what to do with it.
fn compilePipeline(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8) !semantic.ResolvedAst {
    _ = io;
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);

    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }

    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);

    var p = parser.Parser.init(alloc);
    const tree = try p.parse(tokenized);

    var sa = semantic.SemanticAnalyzer.init(alloc);
    return try sa.analyze(tree);
}

// ─── Command Handlers ──────────────────────────────────────────

fn handleCompile(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, trace: bool, dialect: codegen.Dialect) !void {
    _ = input_name;

    // For trace mode, run pipeline stages individually to emit diagnostics
    if (trace) {
        var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);
        var line_it = std.mem.splitScalar(u8, file_data, '\n');
        while (line_it.next()) |line| {
            try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
        }
        const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
        const tokenized = try tok.tokenizeAll(alloc);
        tokenizer.Tokenizer.diagnosticTrace(tokenized);

        var p = parser.Parser.init(alloc);
        const tree = p.parse(tokenized) catch |err| {
            if (err == error.EmptyField) {
                diag.printDiagnostic(.{
                    .severity = .@"error",
                    .line_no = 0,
                    .message = "empty field declaration inside block",
                    .expected = "field name followed by optional type and modifiers",
                    .actual = "(empty line)",
                });
            }
            return err;
        };
        parser.diagnosticTrace(tree);

        var sa = semantic.SemanticAnalyzer.init(alloc);
        const resolved = try sa.analyze(tree);
        semantic.diagnosticTrace(resolved);

        var tr = typed_ast.TypeResolver.init(alloc);
        const typed = try tr.resolve(resolved, dialect);

        var cg = codegen.Codegen.init(alloc, dialect);
        const sql = try cg.generateFromTypedAst(typed);
        codegen.diagnosticTrace(sql);

        try writeOutput(io, sql, output_path);
    } else {
        const resolved = try compilePipeline(io, alloc, file_data);

        var tr = typed_ast.TypeResolver.init(alloc);
        const typed = try tr.resolve(resolved, dialect);

        var cg = codegen.Codegen.init(alloc, dialect);
        const sql = try cg.generateFromTypedAst(typed);

        try writeOutput(io, sql, output_path);
    }
}

fn compileToAst(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !semantic.ResolvedAst {
    const file_data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    return compilePipeline(io, alloc, file_data);
}

fn handleDiff(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, _: codegen.Dialect) !void {
    const old_ast = try compileToAst(io, alloc, old_path);
    const new_ast = try compileToAst(io, alloc, new_path);
    const schema_diff = try diff.diff(old_ast, new_ast, alloc);
    diff.printDiff(schema_diff);
}

fn handleMigrate(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, output_path: ?[]const u8, dialect: codegen.Dialect) !void {
    const old_ast = try compileToAst(io, alloc, old_path);
    const new_ast = try compileToAst(io, alloc, new_path);
    const schema_diff = try diff.diff(old_ast, new_ast, alloc);
    const migration_sql = try migrate.generateFromDiff(alloc, schema_diff, old_ast, new_ast, dialect);
    try writeOutput(io, migration_sql, output_path);
}

/// Auto-detect SQL dialect from content patterns.
/// Returns SQLite if content has SQLite-specific patterns, otherwise MySQL.
fn detectSqlDialect(sql: []const u8) codegen.Dialect {
    // SQLite-specific patterns that distinguish it from MySQL
    const sqlite_patterns = [_][]const u8{
        "AUTOINCREMENT",
        "INTEGER PRIMARY KEY",
    };
    for (sqlite_patterns) |pat| {
        if (std.mem.indexOf(u8, sql, pat) != null) return .sqlite;
    }
    // Check for double-quoted identifiers (SQLite/PG) vs backtick (MySQL)
    // If we see CREATE TABLE " (double-quote), it's likely SQLite or PG, not MySQL
    if (std.mem.indexOf(u8, sql, "CREATE TABLE \"") != null) return .sqlite;
    return .mysql;
}

fn handleReverse(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, with_templates: bool, dialect: codegen.Dialect) !void {
    // Auto-detect dialect from SQL content when not explicitly specified
    const sql_dialect: sql_parser.Dialect = if (dialect == .mysql) detectSqlDialect(file_data) else dialect;
    var sp_parser = sql_parser.SqlParser.init(alloc, file_data, sql_dialect);
    const result = sp_parser.parse() catch |err| {
        const lc = sp_parser.lineColAt(sp_parser.pos);
        const src_line = sp_parser.getSourceLine(lc.line);
        diag.printDiagnostic(.{
            .severity = .@"error",
            .line_no = lc.line,
            .col = lc.col,
            .file = input_name,
            .message = "SQL syntax error",
            .source_line = src_line,
            .actual = @errorName(err),
        });
        std.process.exit(1);
    };
    const schema = result.schema;

    var has_errors = false;
    for (result.diagnostics) |d| {
        diag.printDiagnostic(.{
            .severity = if (d.severity == .@"error") .@"error" else .warning,
            .line_no = d.line_no,
            .col = d.col,
            .file = input_name,
            .message = d.message,
            .source_line = d.context,
        });
        if (d.severity == .@"error") has_errors = true;
    }

    if (has_errors) {
        std.debug.print("aborting due to previous error(s)\n", .{});
        std.process.exit(1);
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
