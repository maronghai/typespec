const std = @import("std");
const ast_mod = @import("ast.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;

/// Format a TypeInfo to stderr (debug output).
pub fn fmtTypeInfo(ti: TypeInfo) void {
    switch (ti) {
        .none => std.debug.print("--", .{}),
        .simple => |s| std.debug.print("{s}", .{s}),
        .raw_sql => |s| std.debug.print("{s}", .{s}),
        .int_explicit => |n| std.debug.print("int({d})", .{n}),
        .decimal_explicit => |ds| std.debug.print("decimal({d},{d})", .{ ds.precision, ds.scale }),
        .varchar_explicit => |n| {
            if (n > 0) {
                std.debug.print("s{d}", .{n});
            } else {
                std.debug.print("s", .{});
            }
        },
        .enum_type => |vals| {
            std.debug.print("e(", .{});
            for (vals, 0..) |v, vi| {
                if (vi > 0) std.debug.print(",", .{});
                std.debug.print("{s}", .{v});
            }
            std.debug.print(")", .{});
        },
    }
}

/// Format modifiers to stderr (debug output).
pub fn fmtModifiers(mods: []const Modifier) void {
    for (mods) |mod| {
        switch (mod.kind) {
            .auto_inc_pk => std.debug.print(" ++", .{}),
            .auto_inc => std.debug.print(" +", .{}),
            .primary_key => std.debug.print(" !", .{}),
            .not_null => std.debug.print(" *", .{}),
            .unsigned => std.debug.print(" +unsigned", .{}),
            .inline_unique => std.debug.print(" @u", .{}),
            .inline_index => std.debug.print(" @", .{}),
        }
    }
}

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
