const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Template = ast_mod.Template;
const Table = ast_mod.Table;
const Field = ast_mod.Field;
const ResolvedTable = ast_mod.ResolvedTable;

// ─── Template Resolution & Application ──────────────────────────
//
// Extracted from semantic.zig for single-responsibility.
// Handles: template map building, circular inheritance detection,
// slot-based field merging, multi-parent (mixin) inheritance.

/// Resolve all templates in the AST and apply them to tables.
/// Returns the resolved tables with template fields merged.
pub fn resolveAndApply(
    alloc: std.mem.Allocator,
    tree: Ast,
) ![]const ResolvedTable {
    // Build template map
    var tmpl_map = std.StringHashMap(*const Template).init(alloc);
    for (tree.templates) |*t| {
        try tmpl_map.put(t.name orelse "", t);
    }
    var default_tmpl: ?*const Template = null;
    for (tree.templates) |*t| {
        if (t.name == null) default_tmpl = t;
    }

    // Template resolution (needs tree access)
    var resolved = std.StringHashMap([]const Field).init(alloc);
    var resolving = std.StringHashMap(bool).init(alloc);
    for (tree.templates) |*t| {
        const tname = t.name orelse "";
        if (!resolved.contains(tname)) {
            _ = try resolveTemplate(t, &tmpl_map, &resolved, &resolving);
        }
    }

    // Build initial tables with templates applied
    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 8);
    for (tree.tables) |*t| {
        var fields: []const Field = t.fields;
        var tmpl_slot: ?usize = null;
        if (t.template_ref) |tref| {
            if (resolved.get(tref)) |parent_fields| {
                for (tree.templates) |*tmpl| {
                    if (tmpl.name) |tn| {
                        if (std.mem.eql(u8, tn, tref)) {
                            tmpl_slot = tmpl.slot_index;
                            break;
                        }
                    }
                }
                fields = try applyTemplate(alloc, t, parent_fields, tmpl_slot);
            }
        } else if (default_tmpl) |dt| {
            const dname = dt.name orelse "";
            if (resolved.get(dname)) |parent_fields| {
                fields = try applyTemplate(alloc, t, parent_fields, dt.slot_index);
            }
        }
        try tables.append(alloc, .{
            .name = t.name,
            .comment = t.comment,
            .engine = t.engine,
            .fields = fields,
            .fks = t.fks,
            .indexes = t.indexes,
            .line_no = t.line_no,
        });
    }

    return try tables.toOwnedSlice(alloc);
}

/// Build the template name→pointer map for external use (e.g. validation pass).
pub fn buildTemplateMap(
    alloc: std.mem.Allocator,
    templates: []const Template,
) !std.StringHashMap(*const Template) {
    var tmpl_map = std.StringHashMap(*const Template).init(alloc);
    for (templates) |*t| {
        try tmpl_map.put(t.name orelse "", t);
    }
    return tmpl_map;
}

// ─── Internal Helpers ──────────────────────────────────────────

fn resolveTemplate(
    tmpl: *const Template,
    tmpl_map: *const std.StringHashMap(*const Template),
    resolved: *std.StringHashMap([]const Field),
    resolving: *std.StringHashMap(bool),
) ![]const Field {
    const tname = tmpl.name orelse "";
    if (resolved.get(tname)) |f| return f;

    if (resolving.contains(tname)) return error.CircularTemplateInheritance;
    try resolving.put(tname, true);
    defer _ = resolving.remove(tname);

    var base_fields: []const Field = &.{};
    for (tmpl.parents) |parent_name| {
        if (tmpl_map.get(parent_name)) |parent| {
            const parent_fields = try resolveTemplate(parent, tmpl_map, resolved, resolving);
            base_fields = try mergeFields(resolved.allocator, base_fields, parent_fields, &.{}, null);
        }
    }

    const result = try mergeFields(resolved.allocator, base_fields, tmpl.fields, &.{}, tmpl.slot_index);
    try resolved.put(tname, result);
    return result;
}

fn mergeFields(
    alloc: std.mem.Allocator,
    parent_fields: []const Field,
    child_fields: []const Field,
    concrete_fields: []const Field,
    child_slot: ?usize,
) ![]const Field {
    if (parent_fields.len == 0) return child_fields;

    var parent_slot: ?usize = null;
    for (parent_fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "...")) {
            parent_slot = i;
            break;
        }
    }

    const pslot = parent_slot orelse parent_fields.len;
    const cslot_raw = child_slot orelse pslot;
    const cslot = if (cslot_raw > child_fields.len) child_fields.len else cslot_raw;

    const parent_before = parent_fields[0..pslot];
    const parent_after = if (pslot < parent_fields.len) parent_fields[pslot + 1 ..] else &[_]Field{};
    const child_before = child_fields[0..cslot];
    const child_after = if (cslot < child_fields.len) child_fields[cslot + 1 ..] else &[_]Field{};

    var override_names = std.StringHashMap(void).init(alloc);
    for (child_before) |f| try override_names.put(f.name, {});
    for (child_after) |f| try override_names.put(f.name, {});
    for (concrete_fields) |f| try override_names.put(f.name, {});

    var result = try std.ArrayList(Field).initCapacity(alloc, 8);

    for (parent_before) |f| {
        if (!override_names.contains(f.name)) try result.append(alloc, f);
    }
    for (child_before) |f| try result.append(alloc, f);
    for (concrete_fields) |f| try result.append(alloc, f);
    for (child_after) |f| try result.append(alloc, f);
    for (parent_after) |f| {
        if (!override_names.contains(f.name)) try result.append(alloc, f);
    }

    return try result.toOwnedSlice(alloc);
}

fn applyTemplate(
    alloc: std.mem.Allocator,
    table: *const Table,
    template_fields: []const Field,
    template_slot: ?usize,
) ![]const Field {
    if (table.fields.len == 0) return template_fields;

    var table_slot: ?usize = null;
    for (table.fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "...")) {
            table_slot = i;
            break;
        }
    }

    var table_names = std.StringHashMap(void).init(alloc);
    for (table.fields) |f| try table_names.put(f.name, {});

    if (table_slot) |slot| {
        const table_before = table.fields[0..slot];
        const table_after = table.fields[slot + 1 ..];

        var result = try std.ArrayList(Field).initCapacity(alloc, 8);
        for (table_before) |f| try result.append(alloc, f);
        for (template_fields) |f| {
            if (!table_names.contains(f.name)) try result.append(alloc, f);
        }
        for (table_after) |f| try result.append(alloc, f);
        return try result.toOwnedSlice(alloc);
    } else {
        const insert_pos = template_slot orelse template_fields.len;
        var result = try std.ArrayList(Field).initCapacity(alloc, 8);
        for (template_fields[0..insert_pos]) |f| {
            if (!table_names.contains(f.name)) try result.append(alloc, f);
        }
        for (table.fields) |f| try result.append(alloc, f);
        if (insert_pos < template_fields.len) {
            for (template_fields[insert_pos..]) |f| {
                if (!table_names.contains(f.name)) try result.append(alloc, f);
            }
        }
        return try result.toOwnedSlice(alloc);
    }
}

// ─── Unit Tests ─────────────────────────────────────────────

const testing = std.testing;

fn makeTestField(name: []const u8, type_info: ast_mod.TypeInfo) Field {
    return .{
        .name = name,
        .type_info = type_info,
        .modifiers = &.{},
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 1,
    };
}

fn makeTestAst(_: std.mem.Allocator, tables: []const ast_mod.Table, templates: []const ast_mod.Template) Ast {
    return .{
        .schema = null,
        .templates = templates,
        .tables = tables,
        .sql_comments = &.{},
    };
}

test "template application: fields merged in order" {
    const alloc = testing.allocator;

    const tmpl_fields = try alloc.alloc(Field, 3);
    tmpl_fields[0] = makeTestField("id", .{ .simple = "n" });
    tmpl_fields[1] = makeTestField("...", .none);
    tmpl_fields[2] = makeTestField("status", .{ .simple = "1" });

    const tmpl = ast_mod.Template{
        .name = "base",
        .parents = &.{},
        .fields = tmpl_fields,
        .slot_index = 1,
    };

    const table_fields = try alloc.alloc(Field, 1);
    table_fields[0] = makeTestField("name", .{ .varchar_explicit = 32 });

    const table = ast_mod.Table{
        .name = "user",
        .template_ref = "base",
        .comment = null,
        .engine = null,
        .fields = table_fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{tmpl}));
    const tables = try resolveAndApply(alloc, ast);

    try testing.expectEqual(@as(usize, 3), tables[0].fields.len);
    try testing.expectEqualStrings("id", tables[0].fields[0].name);
    try testing.expectEqualStrings("name", tables[0].fields[1].name);
    try testing.expectEqualStrings("status", tables[0].fields[2].name);
}

test "template: 3-level inheritance" {
    const alloc = testing.allocator;

    const gp_fields = try alloc.alloc(Field, 1);
    gp_fields[0] = makeTestField("id", .{ .simple = "n" });
    const gp_tmpl = ast_mod.Template{ .name = "gp", .parents = &.{}, .fields = gp_fields, .slot_index = null };

    const p_fields = try alloc.alloc(Field, 1);
    p_fields[0] = makeTestField("status", .{ .simple = "1" });
    const p_tmpl = ast_mod.Template{ .name = "p", .parents = &.{"gp"}, .fields = p_fields, .slot_index = null };

    const c_fields = try alloc.alloc(Field, 1);
    c_fields[0] = makeTestField("name", .{ .simple = "s" });
    const c_tmpl = ast_mod.Template{ .name = "c", .parents = &.{"p"}, .fields = c_fields, .slot_index = null };

    const table = ast_mod.Table{
        .name = "t",
        .template_ref = "c",
        .comment = null,
        .engine = null,
        .fields = &.{},
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{ gp_tmpl, p_tmpl, c_tmpl }));
    const tables = try resolveAndApply(alloc, ast);

    try testing.expectEqual(@as(usize, 3), tables[0].fields.len);
    try testing.expectEqualStrings("id", tables[0].fields[0].name);
    try testing.expectEqualStrings("status", tables[0].fields[1].name);
    try testing.expectEqualStrings("name", tables[0].fields[2].name);
}

test "template: multiple mixins" {
    const alloc = testing.allocator;

    const m1_fields = try alloc.alloc(Field, 1);
    m1_fields[0] = makeTestField("created_at", .none);
    const m1 = ast_mod.Template{ .name = "timestamps", .parents = &.{}, .fields = m1_fields, .slot_index = null };

    const m2_fields = try alloc.alloc(Field, 1);
    m2_fields[0] = makeTestField("deleted_at", .none);
    const m2 = ast_mod.Template{ .name = "softdel", .parents = &.{}, .fields = m2_fields, .slot_index = null };

    const audit_fields = try alloc.alloc(Field, 0);
    const audit = ast_mod.Template{ .name = "audit", .parents = &.{ "timestamps", "softdel" }, .fields = audit_fields, .slot_index = null };

    const table = ast_mod.Table{
        .name = "t",
        .template_ref = "audit",
        .comment = null,
        .engine = null,
        .fields = &.{},
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{ m1, m2, audit }));
    const tables = try resolveAndApply(alloc, ast);

    try testing.expectEqual(@as(usize, 2), tables[0].fields.len);
    try testing.expectEqualStrings("created_at", tables[0].fields[0].name);
    try testing.expectEqualStrings("deleted_at", tables[0].fields[1].name);
}

test "template: child field type overrides parent" {
    const alloc = testing.allocator;

    const parent_fields = try alloc.alloc(Field, 1);
    parent_fields[0] = makeTestField("id", .{ .simple = "n" });
    const parent = ast_mod.Template{ .name = "base", .parents = &.{}, .fields = parent_fields, .slot_index = null };

    const child_fields = try alloc.alloc(Field, 1);
    child_fields[0] = makeTestField("id", .{ .simple = "N" });
    const child = ast_mod.Template{ .name = "big_base", .parents = &.{"base"}, .fields = child_fields, .slot_index = null };

    const table = ast_mod.Table{
        .name = "t",
        .template_ref = "big_base",
        .comment = null,
        .engine = null,
        .fields = &.{},
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    };

    const ast = makeTestAst(alloc, try alloc.dupe(ast_mod.Table, &.{table}), try alloc.dupe(ast_mod.Template, &.{ parent, child }));
    const tables = try resolveAndApply(alloc, ast);

    try testing.expectEqual(@as(usize, 1), tables[0].fields.len);
    try testing.expectEqualStrings("N", tables[0].fields[0].type_info.simple);
}
