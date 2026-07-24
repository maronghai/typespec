const std = @import("std");
const tokenizer_mod = @import("src/tokenizer.zig");
const parser_mod = @import("src/parser.zig");
const semantic_mod = @import("src/semantic.zig");
const typed_ast = @import("src/typed_ast.zig");
const sql_parser_mod = @import("src/sql_parser.zig");
const diag = @import("src/diagnostic.zig");
const reverse_codegen_mod = @import("src/reverse_codegen.zig");

// ─── Fuzz Targets ───────────────────────────────────────────────

fn fuzzForwardPipeline(alloc: std.mem.Allocator, input: []const u8) void {
    var lines = std.ArrayList([]const u8).initCapacity(alloc, 256) catch return;
    defer lines.deinit(alloc);

    var line_it = std.mem.splitScalar(u8, input, '\n');
    while (line_it.next()) |line| {
        lines.append(alloc, std.mem.trimEnd(u8, line, "\r")) catch return;
    }

    const owned_lines = lines.toOwnedSlice(alloc) catch return;
    defer alloc.free(owned_lines);

    const tok = tokenizer_mod.Tokenizer.init(owned_lines);
    const tokenized = tok.tokenizeAll(alloc) catch return;
    defer alloc.free(tokenized);

    var diagnostics = diag.DiagnosticCollector.init(alloc) catch return;
    var p = parser_mod.Parser.initWithDiagnostics(alloc, &diagnostics);
    const tree = p.parse(tokenized) catch return;

    var sa = semantic_mod.SemanticAnalyzer.init(alloc);
    const resolved = sa.analyze(tree) catch return;

    var tr = typed_ast.TypeResolver.init(alloc);
    _ = tr.resolve(resolved, .mysql) catch return;
}

fn fuzzReversePipeline(alloc: std.mem.Allocator, input: []const u8) void {
    var sp_parser = sql_parser_mod.SqlParser.init(alloc, input, .mysql) catch return;
    const result = sp_parser.parse() catch return;
    if (result.schema.tables.len == 0) return;

    var rcg = reverse_codegen_mod.ReverseCodegen.init(alloc, .mysql);
    _ = rcg.generate(result.schema) catch return;
}

fn fuzzTokenizer(alloc: std.mem.Allocator, input: []const u8) void {
    var lines = std.ArrayList([]const u8).initCapacity(alloc, 256) catch return;
    defer lines.deinit(alloc);

    var line_it = std.mem.splitScalar(u8, input, '\n');
    while (line_it.next()) |line| {
        lines.append(alloc, std.mem.trimEnd(u8, line, "\r")) catch return;
    }

    const owned_lines = lines.toOwnedSlice(alloc) catch return;
    defer alloc.free(owned_lines);

    const tok = tokenizer_mod.Tokenizer.init(owned_lines);
    const tokenized = tok.tokenizeAll(alloc) catch return;
    defer alloc.free(tokenized);
}

// ─── Entry Point ────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next(); // skip program name

    var target_name: []const u8 = "";
    var file_paths = std.ArrayList([]const u8).initCapacity(alloc, 16) catch return;

    while (arg_it.next()) |arg| {
        if (target_name.len == 0) {
            target_name = arg;
        } else {
            file_paths.append(alloc, arg) catch return;
        }
    }

    if (target_name.len == 0) {
        std.debug.print("Usage: fuzz <target> <file1.ss> [file2.ss ...]\n", .{});
        std.debug.print("Targets: forward, reverse, tokenizer\n", .{});
        std.process.exit(1);
    }

    const FuzzFn = *const fn (std.mem.Allocator, []const u8) void;
    const fuzz_fn: FuzzFn = if (std.mem.eql(u8, target_name, "forward"))
        fuzzForwardPipeline
    else if (std.mem.eql(u8, target_name, "reverse"))
        fuzzReversePipeline
    else if (std.mem.eql(u8, target_name, "tokenizer"))
        fuzzTokenizer
    else {
        std.debug.print("Unknown target: {s}\n", .{target_name});
        std.process.exit(1);
    };

    std.debug.print("Fuzzing target: {s} with {d} seed files\n", .{ target_name, file_paths.items.len });

    // Read all seed files into memory
    var seeds = std.ArrayList([]const u8).initCapacity(alloc, file_paths.items.len) catch return;
    for (file_paths.items) |fp| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, fp, alloc, .unlimited) catch continue;
        seeds.append(alloc, data) catch continue;
    }

    var iterations: u64 = 0;
    const max_iterations: u64 = 10000;

    while (iterations < max_iterations) : (iterations += 1) {
        if (seeds.items.len > 0) {
            const idx = iterations % seeds.items.len;
            const data = seeds.items[idx];

            // Make a mutable copy and mutate deterministically
            var mutated = alloc.dupe(u8, data) catch continue;
            const num_mutations: usize = @min(3, @max(1, iterations % 4));
            for (0..num_mutations) |m| {
                if (mutated.len == 0) break;
                const pos = (iterations * 7 + m * 13) % mutated.len;
                mutated[pos] = @intCast((@as(u16, mutated[pos]) +% @as(u16, @intCast(iterations + m))) & 0xFF);
            }

            fuzz_fn(alloc, mutated);
        } else {
            // No seed files — generate random bytes
            const len: usize = @intCast(iterations % 256);
            const data = alloc.alloc(u8, len) catch continue;
            for (data, 0..) |*b, i| {
                b.* = @intCast((@as(u16, @intCast(i + iterations)) & 0xFF));
            }
            fuzz_fn(alloc, data);
        }

        if (iterations % 2000 == 0) {
            std.debug.print("  iterations: {d}\n", .{iterations});
        }
    }

    std.debug.print("Fuzzing complete: {d} iterations, no crashes\n", .{iterations});
}
