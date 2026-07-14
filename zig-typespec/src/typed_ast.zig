const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const dialect_enum = @import("dialect_enum.zig");
const Writer = std.Io.Writer;
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;
const SqlComment = ast_mod.SqlComment;
const Dialect = dialect_enum.Dialect;

// ─── TypedAst: Dialect-agnostic IR between Semantic and Codegen ─
//
// ResolvedAst → TypedAst resolves types to concrete SQL strings.
// TypedAst → SQL is pure output (no type inference logic).
//
// Adding a new dialect only requires changes in the SQL output layer,
// not in type resolution.

pub const TypedAst = struct {
    schema_name: ?[]const u8,
    schema_charset: ?[]const u8,
    tables: []const TypedTable,
    sql_comments: []const SqlComment,
};

pub const TypedTable = struct {
    name: []const u8,
    comment: ?[]const u8,
    engine: ?[]const u8,
    columns: []const TypedColumn,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
};

pub const TypedColumn = struct {
    name: []const u8,
    sql_type: []const u8,
    tps_type: ?[]const u8 = null,
    nullable: bool,
    primary_key: bool,
    auto_increment: bool,
    unsigned: bool,
    default: ?[]const u8,
    check: ?CheckConstraint,
    comment: ?[]const u8,
    inline_unique: bool,
    inline_index: bool,
    is_enum: bool,
    enum_values: []const []const u8,
    is_datetime: bool,
    has_timestamp_default: bool,
    on_update_current_timestamp: bool,
    line_no: usize,
};

// ─── Resolution: ResolvedAst → TypedAst ──────────────────────

pub const TypeResolver = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TypeResolver {
        return .{ .alloc = alloc };
    }

    pub fn resolve(self: *TypeResolver, resolved: sem.ResolvedAst, dialect: Dialect) !TypedAst {
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
            .sql_comments = resolved.sql_comments,
        };
    }

    pub fn resolveColumn(self: *TypeResolver, field: Field, dialect: Dialect, custom_types: []const ast_mod.CustomType) !TypedColumn {
        // Check custom types first (multi-char names only)
        if (field.type_info == .simple and field.type_info.simple.len > 1) {
            if (type_map.lookupCustomType(custom_types, field.type_info.simple, dialect)) |ct_info| {
                // Recursively resolve the custom type's base info
                return self.resolveColumn(ast_mod.Field{
                    .name = field.name,
                    .type_info = ct_info,
                    .modifiers = field.modifiers,
                    .default_val = field.default_val,
                    .check = field.check,
                    .fk = field.fk,
                    .comment = field.comment,
                    .line_no = field.line_no,
                }, dialect, custom_types);
            }
        }
        // Delegate type-to-SQL resolution to type_map (single source of truth)
        const sql_type = try type_map.toSqlTypeAlloc(self.alloc, dialect, field.type_info);

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
                    if (type_map.isDatetimeTpsType(field.type_info)) {
                        on_update_ts = true;
                        has_timestamp_mod = true;
                    } else {
                        pk = true;
                        ai = true;
                    }
                },
                .auto_inc => {
                    if (type_map.isDatetimeTpsType(field.type_info)) {
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

        const is_dt = type_map.isDatetimeTpsType(field.type_info);
        const is_enum = field.type_info == .enum_type;
        const enum_vals = if (is_enum) field.type_info.enum_type else &[_][]const u8{};

        // Compute original TPS type string for roundtrip preservation
        const tps_type: ?[]const u8 = switch (field.type_info) {
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

        return .{
            .name = field.name,
            .sql_type = sql_type,
            .tps_type = tps_type,
            .nullable = !nn,
            .primary_key = pk,
            .auto_increment = ai,
            .unsigned = unsigned,
            .default = if (field.default_val) |dv| dv.value else null,
            .check = field.check,
            .comment = field.comment,
            .inline_unique = inline_unique,
            .inline_index = inline_index,
            .is_enum = is_enum,
            .enum_values = enum_vals,
            .is_datetime = is_dt,
            .has_timestamp_default = has_timestamp_mod,
            .on_update_current_timestamp = on_update_ts,
            .line_no = field.line_no,
        };
    }
};
