const std = @import("std");
const cli = @import("cli.zig");
const compiler = @import("compiler.zig");

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
            cli.printUsage();
            std.process.exit(1);
        }
        const file_data = try compiler.readStdin(init.io, alloc);
        return compiler.handleCompile(init.io, alloc, file_data, "<stdin>", null, false, .mysql);
    }

    const parsed = cli.parseArgs(alloc, arg_list) catch |err| {
        switch (err) {
            error.UnknownDialect => {
                std.debug.print("error: unknown dialect (expected: mysql, pg, postgres, sqlite)\n", .{});
            },
            error.MissingDialectValue => {
                std.debug.print("error: --dialect requires a value (mysql, pg, postgres, sqlite)\n", .{});
            },
            error.DiffMissingArgs => {
                std.debug.print("error: diff requires <old.tps> <new.tps>\n", .{});
            },
            error.MigrateMissingArgs => {
                std.debug.print("error: migrate requires <old.tps> <new.tps>\n", .{});
            },
            else => {
                std.debug.print("error: {s}\n", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };
    return dispatch(init.io, alloc, parsed) catch |err| {
        switch (err) {
            error.DiagnosticsError, error.SemanticError, error.SqlParseError, error.ReverseDiagnosticsError => {
                // Error already printed by the compiler module
            },
            else => {
                std.debug.print("error: {s}\n", .{@errorName(err)});
            },
        }
        std.process.exit(1);
    };
}

const VERSION = "0.4.35";

// ─── Command Dispatch ──────────────────────────────────────────

fn dispatch(io: std.Io, alloc: std.mem.Allocator, parsed: cli.ParsedArgs) !void {
    switch (parsed.command) {
        .version => {
            std.debug.print("typespec {s}\n", .{VERSION});
            return;
        },
        .compile => |cmd| {
            const file_data = if (cmd.input) |path|
                try compiler.readFileOrStdin(io, alloc, path)
            else
                try compiler.readStdin(io, alloc);
            const name = cmd.input orelse "<stdin>";
            return switch (parsed.target) {
                .sql => compiler.handleCompile(io, alloc, file_data, name, cmd.output, cmd.trace, parsed.dialect),
                .json_schema => compiler.handleCompileJsonSchema(io, alloc, file_data, name, cmd.output, cmd.trace, parsed.dialect),
            };
        },
        .diff => |cmd| return compiler.handleDiff(io, alloc, cmd.old, cmd.new, parsed.dialect),
        .migrate => |cmd| return compiler.handleMigrate(io, alloc, cmd.old, cmd.new, cmd.output, parsed.dialect),
        .reverse => |cmd| {
            const file_data = if (cmd.input) |path|
                try compiler.readFileOrStdin(io, alloc, path)
            else
                try compiler.readStdin(io, alloc);
            const name = cmd.input orelse "<stdin>";
            return compiler.handleReverse(io, alloc, file_data, name, cmd.output, cmd.with_templates, parsed.dialect);
        },
    }
}
