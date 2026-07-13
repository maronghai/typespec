const std = @import("std");
const tk = @import("tokenizer.zig");
const ast_mod = @import("ast.zig");
const parse_field = @import("parse_field.zig");
const TypeInfo = ast_mod.TypeInfo;

// ─── TypeDef Parsing ───────────────────────────────────────
// Extracted from parser.zig for single-responsibility.
// Handles: @type name = base_type  OR  @type name dialect1=type1 dialect2=type2

pub fn parseTypeDef(alloc: std.mem.Allocator, line: tk.Line) !ast_mod.CustomType {
    // tokens: ["@", "type", "name", ...]
    const name = try alloc.dupe(u8, line.tokens[2]);

    var base: TypeInfo = .none;
    var overrides = try std.ArrayList(ast_mod.DialectOverride).initCapacity(alloc, 4);

    var i: usize = 3;
    // Skip = if present
    if (i < line.tokens.len and std.mem.eql(u8, line.tokens[i], "=")) {
        i += 1;
    }
    // Parse base type (first non-dialect token after =)
    if (i < line.tokens.len) {
        const tok = line.tokens[i];
        if (std.mem.indexOfScalar(u8, tok, '=') != null) {
            // dialect=type format — no base type, only overrides
        } else {
            base = parse_field.tryParseType(tok) orelse .{ .simple = try alloc.dupe(u8, tok) };
            i += 1;
        }
    }
    // Parse dialect overrides: dialect=type pairs
    while (i < line.tokens.len) : (i += 1) {
        const tok = line.tokens[i];
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq_pos| {
            const dialect = try alloc.dupe(u8, tok[0..eq_pos]);
            const type_str = try alloc.dupe(u8, tok[eq_pos + 1 ..]);
            const type_info: TypeInfo = parse_field.tryParseType(type_str) orelse .{ .raw_sql = type_str };
            try overrides.append(alloc, .{ .dialect = dialect, .type_info = type_info });
        }
    }

    return .{
        .name = name,
        .base = base,
        .dialect_overrides = try overrides.toOwnedSlice(alloc),
        .line_no = line.line_no,
    };
}
