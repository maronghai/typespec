const std = @import("std");
const diff_fields = @import("../diff/fields.zig");
const diff_indexes = @import("../diff/indexes.zig");
const diff_fks = @import("../diff/fks.zig");
const utils = @import("../utils.zig");

pub const FieldDiff = diff_fields.FieldDiff;
pub const FieldAction = diff_fields.FieldAction;
pub const IndexDiff = diff_indexes.IndexDiff;
pub const IndexAction = diff_indexes.IndexAction;
pub const FkDiff = diff_fks.FkDiff;
pub const FkAction = diff_fks.FkAction;

pub const TableAction = enum { create, alter };

pub const TableMetadataDiff = struct {
    old_comment: ?[]const u8,
    new_comment: ?[]const u8,
    old_engine: ?[]const u8,
    new_engine: ?[]const u8,
    pub fn hasChanges(self: TableMetadataDiff) bool {
        return !utils.optionalStrEq(self.old_comment, self.new_comment) or
            !utils.optionalStrEq(self.old_engine, self.new_engine);
    }
};

pub const ViewAction = enum { create, drop, modify };

pub const ViewDiff = struct {
    name: []const u8,
    action: ViewAction,
};

pub const SchemaDiff = struct {
    table_diffs: []const TableDiff,
    dropped_tables: [][]const u8,
    view_diffs: []const ViewDiff,
};

pub const TableDiff = struct {
    name: []const u8,
    action: TableAction,
    field_diffs: []const FieldDiff,
    index_diffs: []const IndexDiff,
    fk_diffs: []const FkDiff,
    metadata_diff: ?TableMetadataDiff = null,
};
