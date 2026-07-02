const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");

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

    if (arg_list.len < 2) {
        std.debug.print("Usage: typespec <input.tps> [-o output.sql]\n", .{});
        std.debug.print("\nTypeSpec to SQL DDL compiler\n", .{});
        std.debug.print("\nOptions:\n", .{});
        std.debug.print("  -o <file>   Output file (default: stdout)\n", .{});
        std.process.exit(1);
    }

    const input_path = arg_list[1];
    var output_path: ?[]const u8 = null;

    var i: usize = 2;
    while (i < arg_list.len) : (i += 1) {
        if (std.mem.eql(u8, arg_list[i], "-o") and i + 1 < arg_list.len) {
            output_path = arg_list[i + 1];
            i += 1;
        }
    }

    const file_data = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, alloc, .unlimited);
    defer alloc.free(file_data);

    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 256);
    defer lines.deinit(alloc);

    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        try lines.append(alloc, line);
    }

    const tok = tokenizer.Tokenizer.init(try lines.toOwnedSlice(alloc));
    const tokenized = try tok.tokenizeAll(alloc);

    var p = parser.Parser.init(alloc);
    const tree = try p.parse(tokenized);

    var sa = semantic.SemanticAnalyzer.init(alloc);
    const resolved = try sa.analyze(tree);

    var cg = codegen.Codegen.init(alloc);
    const sql = try cg.generate(resolved);

    if (output_path) |opath| {
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = opath,
            .data = sql,
        });
        std.debug.print("Written to {s}\n", .{opath});
    } else {
        // Write to stdout using the Io system
        var buf: [8192]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var w = stdout_file.writer(init.io, &buf);
        try w.interface.writeAll(sql);
        try w.flush();
    }
}
