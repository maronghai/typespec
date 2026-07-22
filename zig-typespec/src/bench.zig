const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const ast_mod = @import("ast.zig");
const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");
const typed_ast = @import("typed_ast.zig");
const diag = @import("diagnostic.zig");

// ─── TypeSpec Benchmark ─────────────────────────────────────────
// Measures per-stage latency for the forward pipeline.
// Usage: zig build bench

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    // Parse args
    var file_path: []const u8 = "bench/small.tps";
    var iterations: usize = 10;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next(); // skip program name
    if (arg_it.next()) |path| file_path = path;
    if (arg_it.next()) |n_str| iterations = std.fmt.parseInt(usize, n_str, 10) catch 10;

    // Read file
    const file_data = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, alloc, .unlimited);
    defer alloc.free(file_data);

    // Warm up (1 iteration)
    {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        _ = try runPipeline(a, file_data);
    }

    // Benchmark
    var times = StageTimes{};

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var t = try runPipelineTimed(init.io, a, file_data);
        times.add(&t);
    }

    // Output JSON
    const avg = times.avg(iterations);
    std.debug.print(
        \\{{
        \\  "file": "{s}",
        \\  "iterations": {d},
        \\  "stages": {{
        \\    "tokenize": {d:.2},
        \\    "parse": {d:.2},
        \\    "semantic": {d:.2},
        \\    "type_resolve": {d:.2},
        \\    "codegen": {d:.2}
        \\  }},
        \\  "total_ms": {d:.2}
        \\}}
        \\
    , .{
        file_path,
        iterations,
        avg.tokenize,
        avg.parse,
        avg.semantic,
        avg.type_resolve,
        avg.codegen,
        avg.total(),
    });
}

const StageTimes = struct {
    tokenize: f64 = 0,
    parse: f64 = 0,
    semantic: f64 = 0,
    type_resolve: f64 = 0,
    codegen: f64 = 0,

    fn add(self: *StageTimes, other: *const StageTimes) void {
        self.tokenize += other.tokenize;
        self.parse += other.parse;
        self.semantic += other.semantic;
        self.type_resolve += other.type_resolve;
        self.codegen += other.codegen;
    }

    fn avg(self: StageTimes, n: usize) StageTimes {
        const f: f64 = @floatFromInt(n);
        return .{
            .tokenize = self.tokenize / f,
            .parse = self.parse / f,
            .semantic = self.semantic / f,
            .type_resolve = self.type_resolve / f,
            .codegen = self.codegen / f,
        };
    }

    fn total(self: StageTimes) f64 {
        return self.tokenize + self.parse + self.semantic + self.type_resolve + self.codegen;
    }
};

fn nsToMs(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn runPipelineTimed(io: std.Io, alloc: std.mem.Allocator, file_data: []const u8) !StageTimes {
    var times = StageTimes{};

    // Stage 1: Tokenize
    var sw_start = std.Io.Clock.Timestamp.now(io, .awake);
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);
    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }
    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);
    times.tokenize = nsToMs(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - sw_start.raw.nanoseconds);

    // Stage 2: Parse
    sw_start = std.Io.Clock.Timestamp.now(io, .awake);
    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var p = parser.Parser.initWithDiagnostics(alloc, &diagnostics);
    const tree = p.parse(tokenized) catch |err| {
        if (!diagnostics.hasErrors()) {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    times.parse = nsToMs(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - sw_start.raw.nanoseconds);

    // Stage 3: Semantic
    sw_start = std.Io.Clock.Timestamp.now(io, .awake);
    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = try sa.analyze(tree);
    times.semantic = nsToMs(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - sw_start.raw.nanoseconds);

    // Stage 4: Type Resolve
    sw_start = std.Io.Clock.Timestamp.now(io, .awake);
    var tr = typed_ast.TypeResolver.init(alloc);
    const typed = try tr.resolve(resolved, .mysql);
    times.type_resolve = nsToMs(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - sw_start.raw.nanoseconds);

    // Stage 5: Codegen
    sw_start = std.Io.Clock.Timestamp.now(io, .awake);
    var cg = codegen.Codegen.init(alloc, .mysql);
    _ = try cg.generateFromTypedAst(typed);
    times.codegen = nsToMs(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - sw_start.raw.nanoseconds);

    return times;
}

fn runPipeline(alloc: std.mem.Allocator, file_data: []const u8) ![]const u8 {
    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);
    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, std.mem.trimEnd(u8, line, "\r"));
    }
    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);

    var diagnostics = diag.DiagnosticCollector.init(alloc);
    var p = parser.Parser.initWithDiagnostics(alloc, &diagnostics);
    const tree = try p.parse(tokenized);

    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = try sa.analyze(tree);

    var tr = typed_ast.TypeResolver.init(alloc);
    const typed = try tr.resolve(resolved, .mysql);

    var cg = codegen.Codegen.init(alloc, .mysql);
    return try cg.generateFromTypedAst(typed);
}
