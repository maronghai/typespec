const std = @import("std");
const ast = @import("../ast.zig");
const PassContext = @import("../semantic.zig").PassContext;
const TypeInfo = ast.TypeInfo;

/// Check if two TypeInfo values represent the same TPS type.
fn tpsTypeSame(a: TypeInfo, b: TypeInfo) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .simple => |s| std.mem.eql(u8, s, b.simple),
        .raw_sql => |s| std.mem.eql(u8, s, b.raw_sql),
        .int_explicit => |n| n == b.int_explicit,
        .decimal_explicit => |ds| ds.precision == b.decimal_explicit.precision and ds.scale == b.decimal_explicit.scale,
        .varchar_explicit => |n| n == b.varchar_explicit,
        .enum_type => |vals| {
            if (vals.len != b.enum_type.len) return false;
            for (vals, 0..) |v, i| {
                if (!std.mem.eql(u8, v, b.enum_type[i])) return false;
            }
            return true;
        },
    };
}

/// Template type consistency: warn when child template overrides parent field with different type.
pub fn run(ctx: *PassContext) !void {
    var it = ctx.templates.iterator();
    while (it.next()) |entry| {
        const tmpl = entry.value_ptr.*;
        for (tmpl.parents) |parent_name| {
            if (ctx.templates.get(parent_name)) |parent_tmpl| {
                var parent_fields = std.StringHashMap(TypeInfo).init(ctx.alloc);
                defer parent_fields.deinit();
                for (parent_tmpl.fields) |f| {
                    if (std.mem.eql(u8, f.name, "...")) continue;
                    try parent_fields.put(f.name, f.type_info);
                }
                for (tmpl.fields) |f| {
                    if (std.mem.eql(u8, f.name, "...")) continue;
                    if (parent_fields.get(f.name)) |parent_ti| {
                        if (!tpsTypeSame(f.type_info, parent_ti)) {
                            const tname = tmpl.name orelse "";
                            ctx.diagnostics.push(.{
                                .severity = .warning,
                                .line_no = f.line_no,
                                .message = try std.fmt.allocPrint(ctx.alloc, "template '{s}' overrides field '{s}' with different type (parent: {s}, child: {s})", .{ tname, f.name, @tagName(std.meta.activeTag(parent_ti)), @tagName(std.meta.activeTag(f.type_info)) }),
                            });
                        }
                    }
                }
            }
        }
    }
}
