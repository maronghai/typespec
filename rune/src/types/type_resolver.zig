const std = @import("std");
const ast_mod = @import("../types/ast.zig");
const type_map = @import("../types/type_map.zig");
const typed_ast_mod = @import("../types/typed_ast.zig");
const dialect_enum = @import("../dialect/enum.zig");
const Field = ast_mod.Field;
const Dialect = dialect_enum.Dialect;
const TypedAst = typed_ast_mod.TypedAst;
const TypedTable = typed_ast_mod.TypedTable;
const TypedView = typed_ast_mod.TypedView;
const TypedColumn = typed_ast_mod.TypedColumn;
const SqlType = typed_ast_mod.SqlType;
const FkDecl = ast_mod.FkDecl;

// ─── TypeResolver: ResolvedAst → TypedAst ──────────────────────
//
// Extracted from typed_ast.zig in v0.4.54 Phase 3 for single-responsibility.
// typed_ast.zig retains IR type definitions and re-exports this module
// for backward compatibility.

pub const TypeResolver = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TypeResolver {
        return .{ .alloc = alloc };
    }

    pub fn resolve(self: *TypeResolver, resolved: ast_mod.ResolvedAst, dialect: Dialect) !TypedAst {
        var tables = try std.ArrayList(TypedTable).initCapacity(self.alloc, resolved.tables.len);
        for (resolved.tables) |table| {
            var columns = try std.ArrayList(TypedColumn).initCapacity(self.alloc, table.fields.len);
            // Collect inline FKs from fields + standalone FKs from table
            var all_fks = try std.ArrayList(FkDecl).initCapacity(self.alloc, table.fks.len + 4);
            for (table.fks) |fk| try all_fks.append(self.alloc, fk);
            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                const col = try self.resolveColumn(field, dialect, resolved.custom_types);
                try columns.append(self.alloc, col);
                if (field.fk) |fk| try all_fks.append(self.alloc, fk);
            }
            try tables.append(self.alloc, .{
                .name = table.name,
                .comment = table.comment,
                .engine = table.engine,
                .columns = try columns.toOwnedSlice(self.alloc),
                .fks = try all_fks.toOwnedSlice(self.alloc),
                .indexes = table.indexes,
                .line_no = table.line_no,
            });
        }
        return .{
            .schema_name = resolved.schema_name,
            .schema_charset = resolved.schema_charset,
            .tables = try tables.toOwnedSlice(self.alloc),
            .views = try self.resolveViews(resolved.views),
            .sql_comments = resolved.sql_comments,
        };
    }

    fn resolveViews(self: *TypeResolver, views: []const ast_mod.View) ![]const TypedView {
        var result = try std.ArrayList(TypedView).initCapacity(self.alloc, views.len);
        for (views) |v| {
            try result.append(self.alloc, .{
                .name = v.name,
                .query = v.query,
                .comment = v.comment,
                .line_no = v.line_no,
            });
        }
        return try result.toOwnedSlice(self.alloc);
    }

    pub fn resolveColumn(self: *TypeResolver, field: Field, dialect: Dialect, custom_types: []const ast_mod.CustomType) !TypedColumn {
        return self.resolveColumnInner(field, dialect, custom_types, 0);
    }

    fn resolveColumnInner(self: *TypeResolver, field: Field, dialect: Dialect, custom_types: []const ast_mod.CustomType, depth: u8) !TypedColumn {
        // Check custom types first (multi-char names only)
        if (field.type_info == .simple and field.type_info.simple.len > 1) {
            if (type_map.lookupCustomType(custom_types, field.type_info.simple, dialect)) |ct_info| {
                // Detect circular custom type references (e.g., ~A B + ~B A)
                if (depth >= 32) {
                    return error.CircularCustomType;
                }
                // Recursively resolve the custom type's base info
                return self.resolveColumnInner(ast_mod.Field{
                    .name = field.name,
                    .type_info = ct_info,
                    .modifiers = field.modifiers,
                    .default_val = field.default_val,
                    .check = field.check,
                    .fk = field.fk,
                    .comment = field.comment,
                    .line_no = field.line_no,
                }, dialect, custom_types, depth + 1);
            }
        }
        // Resolve to structured SqlType (dialect-agnostic)
        const sql_type = SqlType.fromTypeInfo(field.type_info, dialect);

        // Classify modifiers
        var pk = false;
        var ai = false;
        var nn = false;
        var unsigned = false;
        var inline_unique = false;
        var inline_index = false;
        var on_update_ts = false;
        var has_timestamp_mod = false;
        for (field.modifiers) |mod| {
            switch (mod.kind) {
                .auto_inc_pk => {
                    if (type_map.isDatetimeSymType(field.type_info)) {
                        on_update_ts = true;
                        has_timestamp_mod = true;
                    } else {
                        pk = true;
                        ai = true;
                    }
                },
                .auto_inc => {
                    if (type_map.isDatetimeSymType(field.type_info)) {
                        has_timestamp_mod = true;
                    } else {
                        ai = true;
                    }
                },
                .primary_key => pk = true,
                .not_null => nn = true,
                .unsigned => unsigned = true,
                .inline_unique => inline_unique = true,
                .inline_index => inline_index = true,
            }
        }

        const is_dt = type_map.isDatetimeSymType(field.type_info);
        const is_enum = field.type_info == .enum_type;
        const enum_vals = if (is_enum) field.type_info.enum_type else &[_][]const u8{};

        // Compute original SS type string for roundtrip preservation
        var sym_type: ?[]const u8 = switch (field.type_info) {
            .simple => |s| if (s.len == 1) s else null,
            .varchar_explicit => |n| if (n > 0) blk: {
                var tbuf: [16]u8 = undefined;
                const result = try std.fmt.bufPrint(&tbuf, "s{d}", .{n});
                break :blk try self.alloc.dupe(u8, result);
            } else null,
            .decimal_explicit => |ds| blk: {
                var tbuf: [16]u8 = undefined;
                const result = try std.fmt.bufPrint(&tbuf, "{d},{d}", .{ ds.precision, ds.scale });
                break :blk try self.alloc.dupe(u8, result);
            },
            .none => "s",
            else => null,
        };
        // Unsigned → prepend + prefix for roundtrip (+n, +N, +i)
        if (unsigned) {
            if (sym_type) |tt| {
                if (tt.len == 1 and (tt[0] == 'n' or tt[0] == 'N' or tt[0] == 'i')) {
                    sym_type = try std.fmt.allocPrint(self.alloc, "+{s}", .{tt});
                }
            }
        }

        return .{
            .name = field.name,
            .sql_type = sql_type,
            .sym_type = sym_type,
            .flags = .{
                .nullable = !nn,
                .primary_key = pk,
                .auto_increment = ai,
                .unsigned = unsigned,
                .inline_unique = inline_unique,
                .inline_index = inline_index,
                .is_enum = is_enum,
                .is_datetime = is_dt,
                .has_timestamp_default = has_timestamp_mod,
                .on_update_current_timestamp = on_update_ts,
            },
            .default = if (field.default_val) |dv| dv.value else null,
            .check = field.check,
            .comment = field.comment,
            .enum_values = enum_vals,
            .line_no = field.line_no,
        };
    }
};
