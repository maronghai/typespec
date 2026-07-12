const std = @import("std");

// ─── Source Location ─────────────────────────────────────────

pub const SourceLocation = struct {
    line: usize, // 1-based line number
    col: usize, // 1-based column number
    offset: usize, // 0-based byte offset from start of file
};

// ─── AST Types ───────────────────────────────────────────────

pub const TypeInfo = union(enum) {
    none,
    simple: []const u8,
    int_explicit: usize,
    decimal_explicit: struct { precision: usize, scale: usize },
    varchar_explicit: usize,
    enum_type: []const []const u8,
};

pub const ModifierType = enum {
    auto_inc_pk,
    auto_inc,
    primary_key,
    not_null,
    unsigned,
    inline_unique,
    inline_index,
};

pub const Modifier = struct {
    kind: ModifierType,
    line_no: usize,
};

pub const DefaultVal = struct {
    value: []const u8,
    line_no: usize,
};

pub const CheckKind = enum {
    range, // [a,b] — BETWEEN inclusive
    range_upper_exclusive, // [a,b) — upper exclusive
    range_lower_exclusive, // (a,b] — lower exclusive
    range_both_exclusive, // (a,b) — both exclusive
    in_list, // {a,b} — IN list
    comparison, // {>0} — comparison
};

pub const CheckConstraint = struct {
    kind: CheckKind,
    expr: []const u8,
    line_no: usize,
};

pub const Field = struct {
    name: []const u8,
    type_info: TypeInfo,
    modifiers: []const Modifier,
    default_val: ?DefaultVal,
    check: ?CheckConstraint,
    fk: ?FkDecl,
    comment: ?[]const u8,
    line_no: usize,
    loc: ?SourceLocation = null,
};

pub const FkActionType = enum {
    cascade,
    set_null,
};

pub const FkActionTrigger = enum {
    on_delete,
    on_update,
};

pub const FkAction = struct {
    trigger: FkActionTrigger,
    action: FkActionType,
};

pub const FkDecl = struct {
    fields: []const []const u8,
    ref_table: []const u8,
    ref_fields: []const []const u8,
    actions: []const FkAction,
    line_no: usize,
};

pub const IndexType = enum {
    regular,
    unique,
    fulltext,
    primary_key,
};

pub const IndexDecl = struct {
    kind: IndexType,
    name: []const u8,
    fields: []const []const u8,
    descending: []const bool,
    line_no: usize,
};

pub const Template = struct {
    name: ?[]const u8,
    parents: []const []const u8,
    fields: []const Field,
    slot_index: ?usize,
    line_no: usize,
    loc: ?SourceLocation = null,
};

pub const Table = struct {
    template_ref: ?[]const u8,
    name: []const u8,
    comment: ?[]const u8,
    engine: ?[]const u8,
    fields: []const Field,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
    loc: ?SourceLocation = null,
};

pub const Schema = struct {
    name: []const u8,
    charset: ?[]const u8,
    autofk: bool,
    line_no: usize,
    loc: ?SourceLocation = null,
};

pub const SqlComment = struct {
    text: []const u8,
    line_no: usize,
};

pub const Ast = struct {
    schema: ?Schema,
    templates: []const Template,
    tables: []const Table,
    sql_comments: []const SqlComment,
};

// ─── Diagnostic helpers for AST types ────────────────────────

pub fn fmtTypeInfo(ti: TypeInfo) void {
    switch (ti) {
        .none => std.debug.print("--", .{}),
        .simple => |s| std.debug.print("{s}", .{s}),
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

pub fn fmtModifiers(mods: []const Modifier) void {
    for (mods) |mod| {
        switch (mod.kind) {
            .auto_inc_pk => std.debug.print(" ++", .{}),
            .auto_inc => std.debug.print(" +", .{}),
            .primary_key => std.debug.print(" !", .{}),
            .not_null => std.debug.print(" *", .{}),
            .unsigned => std.debug.print(" u", .{}),
            .inline_unique => std.debug.print(" @u", .{}),
            .inline_index => std.debug.print(" @", .{}),
        }
    }
}
