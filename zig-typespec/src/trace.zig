const std = @import("std");
const ast_mod = @import("ast.zig");
const Field = ast_mod.Field;
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;

/// Format a single FK action (ON DELETE/UPDATE CASCADE/SET NULL/etc.).
pub fn formatFkAction(action: ast_mod.FkAction) void {
    std.debug.print(" ", .{});
    switch (action.trigger) {
        .on_delete => std.debug.print("ON DELETE ", .{}),
        .on_update => std.debug.print("ON UPDATE ", .{}),
    }
    switch (action.action) {
        .cascade => std.debug.print("CASCADE", .{}),
        .set_null => std.debug.print("SET NULL", .{}),
        .set_default => std.debug.print("SET DEFAULT", .{}),
        .restrict => std.debug.print("RESTRICT", .{}),
        .no_action => std.debug.print("NO ACTION", .{}),
    }
}

/// Format an FK declaration (inline or table-level).
pub fn formatFk(fk: FkDecl) void {
    std.debug.print(" >", .{});
    for (fk.fields, 0..) |f, fi| {
        if (fi > 0) std.debug.print(",", .{});
        std.debug.print("{s}", .{f});
    }
    std.debug.print(" {s}(", .{fk.ref_table});
    for (fk.ref_fields, 0..) |f, fi| {
        if (fi > 0) std.debug.print(",", .{});
        std.debug.print("{s}", .{f});
    }
    std.debug.print(")", .{});
    for (fk.actions) |action| {
        formatFkAction(action);
    }
}

/// Format an index declaration.
pub fn formatIndex(idx: IndexDecl) void {
    std.debug.print("    @ ", .{});
    switch (idx.kind) {
        .regular => std.debug.print("idx", .{}),
        .unique => std.debug.print("uk", .{}),
        .fulltext => std.debug.print("ft", .{}),
        .primary_key => std.debug.print("pk", .{}),
    }
    std.debug.print(" {s}(", .{idx.name});
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) std.debug.print(",", .{});
        std.debug.print("{s}", .{f});
    }
    std.debug.print(")\n", .{});
}

/// Format a resolved/index-level FK declaration.
pub fn formatResolvedFk(fk: FkDecl) void {
    std.debug.print("    > ", .{});
    for (fk.fields, 0..) |f, fi| {
        if (fi > 0) std.debug.print(",", .{});
        std.debug.print("{s}", .{f});
    }
    std.debug.print(" {s}(", .{fk.ref_table});
    for (fk.ref_fields, 0..) |f, fi| {
        if (fi > 0) std.debug.print(",", .{});
        std.debug.print("{s}", .{f});
    }
    std.debug.print(")", .{});
    for (fk.actions) |action| {
        formatFkAction(action);
    }
    std.debug.print("\n", .{});
}

/// Format a resolved/index-level index declaration.
pub fn formatResolvedIndex(idx: IndexDecl) void {
    std.debug.print("    INDEX ", .{});
    switch (idx.kind) {
        .regular => std.debug.print("idx", .{}),
        .unique => std.debug.print("UNIQUE", .{}),
        .fulltext => std.debug.print("FULLTEXT", .{}),
        .primary_key => std.debug.print("PRIMARY KEY", .{}),
    }
    std.debug.print(" {s}(", .{idx.name});
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) std.debug.print(",", .{});
        std.debug.print("{s}", .{f});
    }
    std.debug.print(")\n", .{});
}
