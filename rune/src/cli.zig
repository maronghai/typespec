const std = @import("std");
const dialect_enum = @import("dialect_enum.zig");

// ─── Command Types ─────────────────────────────────────────────

pub const Target = enum { sql, json_schema };

pub const Command = union(enum) {
    compile: struct { input: ?[]const u8, output: ?[]const u8, trace: bool },
    diff: struct { old: []const u8, new: []const u8 },
    migrate: struct { old: []const u8, new: []const u8, output: ?[]const u8 },
    reverse: struct { input: ?[]const u8, output: ?[]const u8, with_templates: bool },
    version,
};

pub const ParsedArgs = struct {
    dialect: dialect_enum.Dialect,
    target: Target,
    command: Command,
};

pub const ArgError = error{
    UnknownDialect,
    MissingDialectValue,
    UnknownTarget,
    MissingTargetValue,
    DiffMissingArgs,
    MigrateMissingArgs,
};

// ─── Argument Parsing ──────────────────────────────────────────

pub fn parseArgs(alloc: std.mem.Allocator, raw_args: []const []const u8) !ParsedArgs {
    var dialect: dialect_enum.Dialect = .mysql;
    var target: Target = .sql;
    var filtered = try std.ArrayList([]const u8).initCapacity(alloc, raw_args.len);

    // Pass 1: extract --dialect / -d / --target / --version / -v from all args
    var i: usize = 1; // skip argv[0]
    var want_version = false;
    while (i < raw_args.len) : (i += 1) {
        if (std.mem.eql(u8, raw_args[i], "--version") or std.mem.eql(u8, raw_args[i], "-v")) {
            want_version = true;
        } else if (std.mem.eql(u8, raw_args[i], "--dialect") or std.mem.eql(u8, raw_args[i], "-d")) {
            if (i + 1 < raw_args.len) {
                dialect = parseDialect(raw_args[i + 1]) catch |e| {
                    if (e == error.UnknownDialect) return error.UnknownDialect;
                    return error.MissingDialectValue;
                };
                i += 1; // skip dialect value
            } else {
                return error.MissingDialectValue;
            }
        } else if (std.mem.eql(u8, raw_args[i], "--target")) {
            if (i + 1 < raw_args.len) {
                target = parseTarget(raw_args[i + 1]) catch |e| {
                    if (e == error.UnknownTarget) return error.UnknownTarget;
                    return error.MissingTargetValue;
                };
                i += 1; // skip target value
            } else {
                return error.MissingTargetValue;
            }
        } else {
            try filtered.append(alloc, raw_args[i]);
        }
    }
    const fargs = try filtered.toOwnedSlice(alloc);

    if (want_version) {
        return .{ .dialect = dialect, .target = target, .command = .version };
    }

    // Pass 2: route subcommand
    if (fargs.len < 1) {
        return .{ .dialect = dialect, .target = target, .command = .{ .compile = .{ .input = null, .output = null, .trace = false } } };
    }

    const sub = fargs[0];

    if (std.mem.eql(u8, sub, "diff")) {
        if (fargs.len < 3) return error.DiffMissingArgs;
        return .{ .dialect = dialect, .target = target, .command = .{ .diff = .{ .old = fargs[1], .new = fargs[2] } } };
    }

    if (std.mem.eql(u8, sub, "migrate")) {
        if (fargs.len < 3) return error.MigrateMissingArgs;
        var output: ?[]const u8 = null;
        var j: usize = 3;
        while (j < fargs.len) : (j += 1) {
            if (std.mem.eql(u8, fargs[j], "-o") and j + 1 < fargs.len) {
                output = fargs[j + 1];
                j += 1;
            }
        }
        return .{ .dialect = dialect, .target = target, .command = .{ .migrate = .{ .old = fargs[1], .new = fargs[2], .output = output } } };
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
        return .{ .dialect = dialect, .target = target, .command = .{ .reverse = .{ .input = input, .output = output, .with_templates = with_templates } } };
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
    return .{ .dialect = dialect, .target = target, .command = .{ .compile = .{ .input = input, .output = output, .trace = trace } } };
}

fn parseDialect(s: []const u8) !dialect_enum.Dialect {
    if (std.mem.eql(u8, s, "mysql")) return .mysql;
    if (std.mem.eql(u8, s, "pg") or std.mem.eql(u8, s, "postgres")) return .pg;
    if (std.mem.eql(u8, s, "sqlite") or std.mem.eql(u8, s, "sq")) return .sqlite;
    return error.UnknownDialect;
}

fn parseTarget(s: []const u8) !Target {
    if (std.mem.eql(u8, s, "sql")) return .sql;
    if (std.mem.eql(u8, s, "json-schema") or std.mem.eql(u8, s, "json_schema")) return .json_schema;
    return error.UnknownTarget;
}

// ─── Usage ─────────────────────────────────────────────────────

pub fn printUsage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  rune [input.ss] [-o output] [-t] [-d mysql|pg|sqlite] [--target sql|json-schema]\n", .{});
    std.debug.print("                                                       Compile .ss to SQL DDL or JSON Schema\n", .{});
    std.debug.print("  rune diff <old.ss> <new.ss> [-d mysql|pg|sqlite]         Show schema differences\n", .{});
    std.debug.print("  rune migrate <old.ss> <new.ss> [-o migration.sql] [-d mysql|pg|sqlite]\n", .{});
    std.debug.print("                                                       Generate ALTER TABLE migration SQL\n", .{});
    std.debug.print("  rune reverse [input.sql] [-o output.ss] [-t] [-d mysql|pg|sqlite]\n", .{});
    std.debug.print("                                                       Reverse SQL DDL to .ss schema\n", .{});
    std.debug.print("                                                       -t: extract shared templates\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -d, --dialect   Target SQL dialect: mysql (default), pg, postgres, sqlite\n", .{});
    std.debug.print("  --target        Output format: sql (default), json-schema\n", .{});
    std.debug.print("  -v, --version   Print version and exit\n", .{});
    std.debug.print("\nPipe mode: read from stdin when no input file is given.\n", .{});
    std.debug.print("  echo '# t\\nid n' | rune\n", .{});
    std.debug.print("  echo '# t\\nid n' | rune --target json-schema\n", .{});
    std.debug.print("  cat schema.sql | rune reverse -t\n", .{});
}
