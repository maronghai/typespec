const std = @import("std");
const tokenizer = @import("parser/tokenizer.zig");
const parser = @import("parser/parser.zig");
const ast_mod = @import("types/ast.zig");
const semantic = @import("semantic/analyzer.zig");
const codegen = @import("codegen/codegen.zig");
const typed_ast = @import("types/typed_ast.zig");
const diag = @import("semantic/diagnostic.zig");

// ─── Rune Benchmark ─────────────────────────────────────────
// Measures per-stage latency for the forward pipeline.
// Usage:
//   zig build bench                          — run benchmark, output JSON
//   zig build bench -- --save                — run & save as baseline
//   zig build bench -- --check               — run & compare against baseline
//   zig build bench -- <file> [iterations]   — custom file/iterations

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    // Parse args
    var file_path: []const u8 = "bench/small.ss";
    var iterations: usize = 10;
    var mode: enum { run, save, check } = .run;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next(); // skip program name
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--save")) {
            mode = .save;
        } else if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: bench [--save|--check] [file] [iterations]\n", .{});
            return;
        } else {
            file_path = arg;
            if (arg_it.next()) |n_str| iterations = std.fmt.parseInt(usize, n_str, 10) catch 10;
        }
    }

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

    const avg = times.avg(iterations);

    switch (mode) {
        .run => {
            printJson(file_path, iterations, avg);
        },
        .save => {
            printJson(file_path, iterations, avg);
            try saveBaseline(init.io, alloc, file_path, avg);
            std.debug.print("\nBaseline saved to bench/baseline.json\n", .{});
        },
        .check => {
            const baseline = loadBaseline(init.io, alloc) catch |err| {
                std.debug.print("error: cannot load bench/baseline.json: {s}\n", .{@errorName(err)});
                std.debug.print("Run 'zig build bench -- --save' first to create baseline.\n", .{});
                return error.BaselineNotFound;
            };
            const regressions = checkRegressions(avg, baseline);
            if (regressions > 0) {
                std.debug.print("\nBENCHMARK REGRESSION DETECTED ({d} stage(s))\n", .{regressions});
                printRegressionDetails(avg, baseline);
                std.process.exit(1);
            } else {
                std.debug.print("Benchmark OK — no regressions (threshold: 20%)\n", .{});
            }
        },
    }
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

fn printJson(file_path: []const u8, iterations: usize, avg: StageTimes) void {
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

const Baseline = struct {
    tokenize: f64,
    parse: f64,
    semantic: f64,
    type_resolve: f64,
    codegen: f64,
};

fn saveBaseline(io: std.Io, alloc: std.mem.Allocator, file_path: []const u8, avg: StageTimes) !void {
    const json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "file": "{s}",
        \\  "stages": {{
        \\    "tokenize": {d:.2},
        \\    "parse": {d:.2},
        \\    "semantic": {d:.2},
        \\    "type_resolve": {d:.2},
        \\    "codegen": {d:.2}
        \\  }}
        \\}}
        \\
    , .{
        file_path,
        avg.tokenize,
        avg.parse,
        avg.semantic,
        avg.type_resolve,
        avg.codegen,
    });
    defer alloc.free(json);

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "bench/baseline.json",
        .data = json,
    }) catch |err| {
        std.debug.print("error: cannot write bench/baseline.json: {s}\n", .{@errorName(err)});
        std.debug.print("Make sure the bench/ directory exists: mkdir -p bench\n", .{});
        return err;
    };
}

fn loadBaseline(io: std.Io, alloc: std.mem.Allocator) !Baseline {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, "bench/baseline.json", alloc, .unlimited);
    defer alloc.free(data);

    // Simple JSON parsing — extract stage values
    var baseline: Baseline = .{
        .tokenize = 0,
        .parse = 0,
        .semantic = 0,
        .type_resolve = 0,
        .codegen = 0,
    };

    const fields = [_]struct { name: []const u8, ptr: *f64 }{
        .{ .name = "\"tokenize\":", .ptr = &baseline.tokenize },
        .{ .name = "\"parse\":", .ptr = &baseline.parse },
        .{ .name = "\"semantic\":", .ptr = &baseline.semantic },
        .{ .name = "\"type_resolve\":", .ptr = &baseline.type_resolve },
        .{ .name = "\"codegen\":", .ptr = &baseline.codegen },
    };

    for (fields) |f| {
        if (std.mem.indexOf(u8, data, f.name)) |pos| {
            const start = pos + f.name.len;
            // Skip whitespace
            var i = start;
            while (i < data.len and data[i] == ' ') i += 1;
            // Parse number
            const num_start = i;
            while (i < data.len and (data[i] >= '0' and data[i] <= '9' or data[i] == '.')) i += 1;
            f.ptr.* = std.fmt.parseFloat(f64, data[num_start..i]) catch 0;
        }
    }

    return baseline;
}

fn checkRegressions(current: StageTimes, baseline: Baseline) usize {
    const threshold = 1.20; // 20% regression threshold
    var count: usize = 0;
    if (current.tokenize / baseline.tokenize > threshold) count += 1;
    if (current.parse / baseline.parse > threshold) count += 1;
    if (current.semantic / baseline.semantic > threshold) count += 1;
    if (current.type_resolve / baseline.type_resolve > threshold) count += 1;
    if (current.codegen / baseline.codegen > threshold) count += 1;
    return count;
}

fn printRegressionDetails(current: StageTimes, baseline: Baseline) void {
    const threshold = 1.20;
    const stages = [_]struct { name: []const u8, current: f64, baseline: f64 }{
        .{ .name = "tokenize", .current = current.tokenize, .baseline = baseline.tokenize },
        .{ .name = "parse", .current = current.parse, .baseline = baseline.parse },
        .{ .name = "semantic", .current = current.semantic, .baseline = baseline.semantic },
        .{ .name = "type_resolve", .current = current.type_resolve, .baseline = baseline.type_resolve },
        .{ .name = "codegen", .current = current.codegen, .baseline = baseline.codegen },
    };

    for (stages) |s| {
        if (s.baseline > 0 and s.current / s.baseline > threshold) {
            const change = ((s.current - s.baseline) / s.baseline) * 100.0;
            std.debug.print("  {s}: {d:.2}ms → {d:.2}ms (+{d:.1}%)\n", .{ s.name, s.baseline, s.current, change });
        }
    }

    const cur_total = current.total();
    const bas_total = baseline.tokenize + baseline.parse + baseline.semantic + baseline.type_resolve + baseline.codegen;
    if (bas_total > 0) {
        const change = ((cur_total - bas_total) / bas_total) * 100.0;
        std.debug.print("  total: {d:.2}ms → {d:.2}ms ({d:.1}% change)\n", .{ bas_total, cur_total, change });
    }
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
    var diagnostics = try diag.DiagnosticCollector.init(alloc);
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

    var diagnostics = try diag.DiagnosticCollector.init(alloc);
    var p = parser.Parser.initWithDiagnostics(alloc, &diagnostics);
    const tree = try p.parse(tokenized);

    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = try sa.analyze(tree);

    var tr = typed_ast.TypeResolver.init(alloc);
    const typed = try tr.resolve(resolved, .mysql);

    var cg = codegen.Codegen.init(alloc, .mysql);
    return try cg.generateFromTypedAst(typed);
}
