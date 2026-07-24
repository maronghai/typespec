const std = @import("std");
const ast_mod = @import("../types/ast.zig");
const diff_fields = @import("../diff/fields.zig");
const diff_indexes = @import("../diff/indexes.zig");
const diff_fks = @import("../diff/fks.zig");
const diff_format = @import("../diff/format.zig");
const diff_types = @import("../diff/types.zig");
const dialect_enum = @import("../dialect/enum.zig");
const utils = @import("../utils.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const IndexDecl = ast_mod.IndexDecl;
const FkDecl = ast_mod.FkDecl;
const Dialect = dialect_enum.Dialect;

// ─── Re-export sub-module types ────────────────────────────

pub const FieldDiff = diff_types.FieldDiff;
pub const FieldAction = diff_types.FieldAction;
pub const IndexDiff = diff_types.IndexDiff;
pub const IndexAction = diff_types.IndexAction;
pub const FkDiff = diff_types.FkDiff;
pub const FkAction = diff_types.FkAction;

// ─── Re-export diff data structures ───────────────────────

pub const TableAction = diff_types.TableAction;
pub const TableMetadataDiff = diff_types.TableMetadataDiff;
pub const ViewAction = diff_types.ViewAction;
pub const ViewDiff = diff_types.ViewDiff;
pub const SchemaDiff = diff_types.SchemaDiff;
pub const TableDiff = diff_types.TableDiff;

// ─── Re-export equality helpers ────────────────────────────

pub const fieldsEqual = diff_fields.fieldsEqual;
pub const typeInfoEqual = diff_fields.typeInfoEqual;
pub const defaultValEqual = diff_fields.defaultValEqual;
pub const checkEqual = diff_fields.checkEqual;
pub const indexesEqual = diff_indexes.indexesEqual;
pub const fksEqual = diff_fks.fksEqual;
pub const semanticEquiv = @import("../reverse/map.zig").semanticEquiv;

// ─── Helpers ───────────────────────────────────────────────

const optionalStrEq = utils.optionalStrEq;

// ─── Diff Engine ───────────────────────────────────────────

pub fn diff(old: ast_mod.ResolvedAst, new: ast_mod.ResolvedAst, alloc: std.mem.Allocator, dialect: ?Dialect) !SchemaDiff {
    var table_diffs = try std.ArrayList(TableDiff).initCapacity(alloc, 8);
    var dropped_tables = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    var view_diffs = try std.ArrayList(ViewDiff).initCapacity(alloc, 4);

    // Build name→table maps
    var old_map = std.StringHashMap(usize).init(alloc);
    for (old.tables, 0..) |t, i| try old_map.put(t.name, i);
    var new_map = std.StringHashMap(usize).init(alloc);
    for (new.tables, 0..) |t, i| try new_map.put(t.name, i);

    // Tables in new but not old → create
    for (new.tables) |new_table| {
        if (!old_map.contains(new_table.name)) {
            const field_diffs = try diff_fields.createAllFieldDiffs(alloc, new_table.fields);
            const index_diffs = try diff_indexes.createAllIndexDiffs(alloc, new_table.indexes);
            const fk_diffs = try diff_fks.createAllFkDiffs(alloc, new_table.fks);
            try table_diffs.append(alloc, .{
                .name = new_table.name,
                .action = .create,
                .field_diffs = field_diffs,
                .index_diffs = index_diffs,
                .fk_diffs = fk_diffs,
            });
        }
    }

    // Tables in old but not new → dropped
    for (old.tables) |old_table| {
        if (!new_map.contains(old_table.name)) {
            try dropped_tables.append(alloc, old_table.name);
        }
    }

    // Tables in both → compare
    for (old.tables) |old_table| {
        if (new_map.get(old_table.name)) |new_idx| {
            const new_table = new.tables[new_idx];
            const td = try diffTable(alloc, old_table, new_table, dialect);
            if (td.field_diffs.len > 0 or td.index_diffs.len > 0 or td.fk_diffs.len > 0 or td.metadata_diff != null) {
                try table_diffs.append(alloc, td);
            }
        }
    }

    // Views: build name→view maps
    var old_view_map = std.StringHashMap(usize).init(alloc);
    for (old.views, 0..) |v, i| try old_view_map.put(v.name, i);
    var new_view_map = std.StringHashMap(usize).init(alloc);
    for (new.views, 0..) |v, i| try new_view_map.put(v.name, i);

    // Views in new but not old → create
    for (new.views) |new_view| {
        if (!old_view_map.contains(new_view.name)) {
            try view_diffs.append(alloc, .{ .name = new_view.name, .action = .create });
        }
    }
    // Views in old but not new → drop
    for (old.views) |old_view| {
        if (!new_view_map.contains(old_view.name)) {
            try view_diffs.append(alloc, .{ .name = old_view.name, .action = .drop });
        }
    }
    // Views in both → check for query change
    for (old.views) |old_view| {
        if (new_view_map.get(old_view.name)) |new_idx| {
            const new_view = new.views[new_idx];
            if (!std.mem.eql(u8, old_view.query, new_view.query)) {
                try view_diffs.append(alloc, .{ .name = old_view.name, .action = .modify });
            }
        }
    }

    return .{
        .table_diffs = try table_diffs.toOwnedSlice(alloc),
        .dropped_tables = try dropped_tables.toOwnedSlice(alloc),
        .view_diffs = try view_diffs.toOwnedSlice(alloc),
    };
}

fn diffTable(alloc: std.mem.Allocator, old: ast_mod.ResolvedTable, new: ast_mod.ResolvedTable, dialect: ?Dialect) !TableDiff {
    const field_diffs = try diff_fields.diffFields(alloc, old.fields, new.fields, dialect);
    const index_diffs = try diff_indexes.diffIndexes(alloc, old.indexes, new.indexes);
    const fk_diffs = try diff_fks.diffFks(alloc, old.fks, new.fks);

    // Compare metadata (comment, engine)
    const metadata_diff = TableMetadataDiff{
        .old_comment = old.comment,
        .new_comment = new.comment,
        .old_engine = old.engine,
        .new_engine = new.engine,
    };

    return .{
        .name = old.name,
        .action = .alter,
        .field_diffs = field_diffs,
        .index_diffs = index_diffs,
        .fk_diffs = fk_diffs,
        .metadata_diff = if (metadata_diff.hasChanges()) metadata_diff else null,
    };
}

// ─── Re-export formatting (moved to diff_format.zig) ─────────

pub const formatDiff = diff_format.formatDiff;
pub const printDiff = diff_format.printDiff;
