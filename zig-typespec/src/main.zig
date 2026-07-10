const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");
const diag = @import("diagnostic.zig");
const migrate = @import("migrate.zig");
const sql_parser = @import("sql_parser.zig");
const reverse_codegen = @import("reverse_codegen.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    // Collect args from iterator
    var args = try std.ArrayList([]const u8).initCapacity(alloc, 8);
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args.append(alloc, arg);
    }
    const arg_list = try args.toOwnedSlice(alloc);

    // No args: check if stdin is a pipe or terminal
    if (arg_list.len < 2) {
        const is_tty = std.Io.File.stdin().isTty(init.io) catch true;
        if (is_tty) {
            // Interactive terminal — show usage
            printUsage();
            std.process.exit(1);
        }
        // Pipe mode — read from stdin
        const file_data = try readStdin(init.io, alloc);
        return handleCompile(init.io, alloc, file_data, "<stdin>", null, false, .mysql);
    }

    // Parse global --dialect flag from all args
    var dialect: codegen.Dialect = .mysql;
    var filtered_args = try std.ArrayList([]const u8).initCapacity(alloc, arg_list.len);
    var ai: usize = 0;
    while (ai < arg_list.len) : (ai += 1) {
        if (std.mem.eql(u8, arg_list[ai], "--dialect") or std.mem.eql(u8, arg_list[ai], "-d")) {
            if (ai + 1 < arg_list.len) {
                const d = arg_list[ai + 1];
                if (std.mem.eql(u8, d, "pg") or std.mem.eql(u8, d, "postgres")) {
                    dialect = .postgres;
                } else if (std.mem.eql(u8, d, "mysql")) {
                    dialect = .mysql;
                } else {
                    std.debug.print("error: unknown dialect '{s}' (expected: mysql, pg, postgres)\n", .{d});
                    std.process.exit(1);
                }
                ai += 1; // skip dialect value
            } else {
                std.debug.print("error: --dialect requires a value (mysql, pg, postgres)\n", .{});
                std.process.exit(1);
            }
        } else {
            try filtered_args.append(alloc, arg_list[ai]);
        }
    }
    const fargs = try filtered_args.toOwnedSlice(alloc);

    // Subcommand routing
    if (fargs.len < 2) {
        const is_tty = std.Io.File.stdin().isTty(init.io) catch true;
        if (is_tty) {
            printUsage();
            std.process.exit(1);
        }
        const file_data = try readStdin(init.io, alloc);
        return handleCompile(init.io, alloc, file_data, "<stdin>", null, false, dialect);
    }

    if (std.mem.eql(u8, fargs[1], "diff") and fargs.len >= 4) {
        return handleDiff(init.io, alloc, fargs[2], fargs[3], dialect);
    } else if (std.mem.eql(u8, fargs[1], "migrate") and fargs.len >= 4) {
        var output_path: ?[]const u8 = null;
        var i: usize = 4;
        while (i < fargs.len) : (i += 1) {
            if (std.mem.eql(u8, fargs[i], "-o") and i + 1 < fargs.len) {
                output_path = fargs[i + 1];
                i += 1;
            }
        }
        return handleMigrate(init.io, alloc, fargs[2], fargs[3], output_path, dialect);
    } else if (std.mem.eql(u8, fargs[1], "reverse")) {
        var output_path: ?[]const u8 = null;
        var with_templates = false;
        var input_path: ?[]const u8 = null;
        var i: usize = 2;
        while (i < fargs.len) : (i += 1) {
            if (std.mem.eql(u8, fargs[i], "-o") and i + 1 < fargs.len) {
                output_path = fargs[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, fargs[i], "-t")) {
                with_templates = true;
            } else if (input_path == null) {
                input_path = fargs[i];
            }
        }
        const file_data = if (input_path) |path|
            try readFileOrStdin(init.io, alloc, path)
        else
            try readStdin(init.io, alloc);
        const name = input_path orelse "<stdin>";
        return handleReverse(init.io, alloc, file_data, name, output_path, with_templates, dialect);
    }

    // Default: typespec <input.tps> [-o output.sql] [-t]
    const input_path = fargs[1];
    var output_path: ?[]const u8 = null;
    var trace: bool = false;

    var i: usize = 2;
    while (i < fargs.len) : (i += 1) {
        if (std.mem.eql(u8, fargs[i], "-o") and i + 1 < fargs.len) {
            output_path = fargs[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, fargs[i], "-t")) {
            trace = true;
        }
    }

    const file_data = try readFileOrStdin(init.io, alloc, input_path);
    return handleCompile(init.io, alloc, file_data, input_path, output_path, trace, dialect);
}

fn printUsage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  typespec [input.tps] [-o output.sql] [-t] [-d mysql|pg]  Compile .tps to SQL DDL\n", .{});
    std.debug.print("  typespec diff <old.tps> <new.tps> [-d mysql|pg]         Show schema differences\n", .{});
    std.debug.print("  typespec migrate <old.tps> <new.tps> [-o migration.sql] [-d mysql|pg]\n", .{});
    std.debug.print("                                                           Generate ALTER TABLE migration SQL\n", .{});
    std.debug.print("  typespec reverse [input.sql] [-o output.tps] [-t] [-d mysql|pg]\n", .{});
    std.debug.print("                                                           Reverse SQL DDL to .tps schema\n", .{});
    std.debug.print("                                                           -t: extract shared templates\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -d, --dialect  Target SQL dialect: mysql (default), pg, postgres\n", .{});
    std.debug.print("\nPipe mode: read from stdin when no input file is given.\n", .{});
    std.debug.print("  echo '# t\\nid n' | typespec\n", .{});
    std.debug.print("  cat schema.sql | typespec reverse -t\n", .{});
}

fn readStdin(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    const stdin_file = std.Io.File.stdin();
    var buf: [4096]u8 = undefined;
    var r = stdin_file.readerStreaming(io, &buf);
    var result = try std.ArrayList(u8).initCapacity(alloc, 4096);
    r.interface.appendRemainingUnlimited(alloc, &result) catch {};
    return try result.toOwnedSlice(alloc);
}

fn readFileOrStdin(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        return readStdin(io, alloc);
    }
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

fn handleCompile(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, trace: bool, dialect: codegen.Dialect) !void {
    _ = input_name;
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);
    defer lines.deinit(alloc);

    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }

    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);
    if (trace) tokenizer.Tokenizer.diagnosticTrace(tokenized);

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
    if (trace) parser.diagnosticTrace(tree);

    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = try sa.analyze(tree);
    if (trace) semantic.diagnosticTrace(resolved);

    var cg = codegen.Codegen.init(alloc, dialect);
    const sql = try cg.generate(resolved);
    if (trace) codegen.diagnosticTrace(sql);

    if (output_path) |opath| {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = opath,
            .data = sql,
        });
        std.debug.print("Written to {s}\n", .{opath});
    } else {
        var buf: [8192]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var w = stdout_file.writer(io, &buf);
        try w.interface.writeAll(sql);
        try w.flush();
    }
}

fn handleDiff(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, dialect: codegen.Dialect) !void {
    const old_sql = try compileToSql(io, alloc, old_path, dialect);
    const new_sql = try compileToSql(io, alloc, new_path, dialect);
    try migrate.printDiff(old_sql, new_sql, alloc);
}

fn handleMigrate(io: std.Io, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, output_path: ?[]const u8, dialect: codegen.Dialect) !void {
    const old_sql = try compileToSql(io, alloc, old_path, dialect);
    const new_sql = try compileToSql(io, alloc, new_path, dialect);
    const migration_sql = try migrate.generateMigration(alloc, old_sql, new_sql);

    if (output_path) |opath| {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = opath,
            .data = migration_sql,
        });
        std.debug.print("Written to {s}\n", .{opath});
    } else {
        var buf: [8192]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var w = stdout_file.writer(io, &buf);
        try w.interface.writeAll(migration_sql);
        try w.flush();
    }
}

fn compileToSql(io: std.Io, alloc: std.mem.Allocator, path: []const u8, dialect: codegen.Dialect) ![]const u8 {
    const file_data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(file_data);

    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);
    defer lines.deinit(alloc);

    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }

    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);

    var p = parser.Parser.init(alloc);
    const tree = try p.parse(tokenized);

    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = try sa.analyze(tree);

    var cg = codegen.Codegen.init(alloc, dialect);
    return try cg.generate(resolved);
}

fn handleReverse(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8, input_name: []const u8, output_path: ?[]const u8, with_templates: bool, dialect: codegen.Dialect) !void {
    const sql_dialect: sql_parser.Dialect = if (dialect == .postgres) .postgres else .mysql;
    var sp_parser = sql_parser.SqlParser.init(alloc, file_data, sql_dialect);
    const result = sp_parser.parse() catch |err| {
        const lc = sp_parser.lineColAt(sp_parser.pos);
        const src_line = sp_parser.getSourceLine(lc.line);
        std.debug.print("error: SQL syntax error: {}\n", .{err});
        std.debug.print("  --> {s}:{d}:{d}\n", .{ input_name, lc.line, lc.col });
        if (src_line) |ctx| {
            std.debug.print("   |\n", .{});
            std.debug.print(" {d} | {s}\n", .{ lc.line, ctx });
            var j: usize = 0;
            const indent = blk: {
                var v = lc.line;
                var cnt: usize = 0;
                while (v > 0) : (v /= 10) cnt += 1;
                break :blk cnt + 3;
            };
            while (j < indent + lc.col - 1) : (j += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("^\n", .{});
        }
        std.process.exit(1);
    };
    const schema = result.schema;

    // Print diagnostics
    var has_errors = false;
    for (result.diagnostics) |d| {
        const sev: []const u8 = if (d.severity == .@"error") "error" else "warning";
        std.debug.print("{s}: {s}\n", .{ sev, d.message });
        std.debug.print("  --> {s}:{d}:{d}\n", .{ input_name, d.line_no, d.col });
        if (d.context) |ctx| {
            std.debug.print("   |\n", .{});
            std.debug.print(" {d} | {s}\n", .{ d.line_no, ctx });
            var j: usize = 0;
            const indent = blk: {
                var v = d.line_no;
                var cnt: usize = 0;
                while (v > 0) : (v /= 10) cnt += 1;
                break :blk cnt + 3;
            };
            while (j < indent + d.col - 1) : (j += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("^\n", .{});
        }
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

    if (output_path) |opath| {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = opath,
            .data = tps,
        });
        std.debug.print("Written to {s}\n", .{opath});
    } else {
        var buf: [8192]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var w = stdout_file.writer(io, &buf);
        try w.interface.writeAll(tps);
        try w.flush();
    }
}
