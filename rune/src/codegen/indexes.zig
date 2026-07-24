const std = @import("std");
const dialect_mod = @import("../dialect/dialect.zig");
const typed_ast_mod = @import("../types/typed_ast.zig");
const columns_mod = @import("columns.zig");
const Writer = std.Io.Writer;

pub fn emitInlineIndexes(backend: dialect_mod.DialectBackend, w: *Writer, table: typed_ast_mod.TypedTable, needs_comma: *bool) !void {
    for (table.columns) |col| {
        if (col.flags.inline_unique) {
            if (!columns_mod.isDominatedByExplicitIndex(col.name, table.indexes, true)) {
                try backend.emitInlineIndex(w, col.name, true, needs_comma);
            }
        }
        if (col.flags.inline_index) {
            if (!columns_mod.isDominatedByExplicitIndex(col.name, table.indexes, false)) {
                try backend.emitInlineIndex(w, col.name, false, needs_comma);
            }
        }
    }
}

pub fn emitStandaloneIndexes(backend: dialect_mod.DialectBackend, w: *Writer, table: typed_ast_mod.TypedTable) !void {
    for (table.indexes) |idx| {
        try backend.emitStandaloneIndex(w, table.name, idx);
    }
}

pub fn emitInlineColumnStandaloneIndexes(backend: dialect_mod.DialectBackend, w: *Writer, table: typed_ast_mod.TypedTable) !void {
    for (table.columns) |col| {
        if (col.flags.inline_index) {
            if (!columns_mod.isDominatedByExplicitIndex(col.name, table.indexes, false)) {
                try backend.emitInlineColumnStandaloneIndex(w, table.name, col.name);
            }
        }
    }
}
