const std = @import("std");
const codegen = @import("codegen.zig");

// ─── Command Types ─────────────────────────────────────────────

pub const Command = union(enum) {
    compile: struct { input: ?[]const u8, output: ?[]const u8, trace: bool },
    diff: struct { old: []const u8, new: []const u8 },
    migrate: struct { old: []const u8, new: []const u8, output: ?[]const u8 },
    reverse: struct { input: ?[]const u8, output: ?[]const u8, with_templates: bool },
};

pub const ParsedArgs = struct {
    dialect: codegen.Dialect,
    command: Command,
};

// ─── Argument Parsing ──────────────────────────────────────────

pub fn parseArgs(alloc: std.mem.Allocator, raw_args: []const []const u8) !ParsedArgs {
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

// ─── Usage ─────────────────────────────────────────────────────

pub fn printUsage() void {
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
