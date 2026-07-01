const std = @import("std");
const ast_mod = @import("parser.zig");
const Parser = ast_mod.Parser;
const Ast = ast_mod.Ast;
const Template = ast_mod.Template;
const Table = ast_mod.Table;
const Field = ast_mod.Field;
const FkDecl = ast_mod.FkDecl;
const IndexDecl = ast_mod.IndexDecl;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;

pub const ResolvedTable = struct {
    name: []const u8,
    comment: ?[]const u8,
    fields: []const Field,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
};

pub const ResolvedAst = struct {
    schema_name: ?[]const u8,
    tables: []const ResolvedTable,
};

pub const SemanticAnalyzer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SemanticAnalyzer {
        return .{ .alloc = alloc };
    }

    pub fn analyze(self: *SemanticAnalyzer, tree: Ast) !ResolvedAst {
        var tmpl_map = std.StringHashMap(*const Template).init(self.alloc);
        for (tree.templates) |*t| {
            try tmpl_map.put(t.name orelse "", t);
        }

        var default_tmpl: ?*const Template = null;
        for (tree.templates) |*t| {
            if (t.name == null) default_tmpl = t;
        }

        var resolved = std.StringHashMap([]const Field).init(self.alloc);
        var resolving = std.StringHashMap(bool).init(self.alloc);

        for (tree.templates) |*t| {
            const tname = t.name orelse "";
            if (!resolved.contains(tname)) {
                _ = try self.resolveTemplate(t, &tmpl_map, &resolved, &resolving);
            }
        }

        var tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, 8);
        for (tree.tables) |*t| {
            var fields: []const Field = t.fields;
            if (t.template_ref) |tref| {
                if (resolved.get(tref)) |parent_fields| {
                    fields = try self.applyTemplate(t, parent_fields);
                }
            } else if (default_tmpl) |dt| {
                const dname = dt.name orelse "";
                if (resolved.get(dname)) |parent_fields| {
                    fields = try self.applyTemplate(t, parent_fields);
                }
            }

            try tables.append(self.alloc, .{
                .name = t.name,
                .comment = t.comment,
                .fields = fields,
                .fks = t.fks,
                .indexes = t.indexes,
                .line_no = t.line_no,
            });
        }

        return .{
            .schema_name = if (tree.schema) |s| s.name else null,
            .tables = try tables.toOwnedSlice(self.alloc),
        };
    }

    fn resolveTemplate(
        self: *SemanticAnalyzer,
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
        if (tmpl.extends) |parent_name| {
            if (tmpl_map.get(parent_name)) |parent| {
                base_fields = try self.resolveTemplate(parent, tmpl_map, resolved, resolving);
            }
        }

        const result = try self.mergeFields(base_fields, tmpl.fields, &.{}, tmpl.slot_index);
        try resolved.put(tname, result);
        return result;
    }

    fn mergeFields(
        self: *SemanticAnalyzer,
        parent_fields: []const Field,
        child_fields: []const Field,
        concrete_fields: []const Field,
        child_slot: ?usize,
    ) ![]const Field {
        if (parent_fields.len == 0) return child_fields;

        // Find slot in parent
        var parent_slot: ?usize = null;
        for (parent_fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "...")) {
                parent_slot = i;
                break;
            }
        }

        const pslot = parent_slot orelse parent_fields.len;
        const cslot = child_slot orelse pslot; // If child doesn't redefine slot, use parent's

        const parent_before = parent_fields[0..pslot];
        const parent_after = if (pslot < parent_fields.len) parent_fields[pslot + 1 ..] else &[_]Field{};
        const child_before = child_fields[0..cslot];
        const child_after = if (cslot < child_fields.len) child_fields[cslot + 1 ..] else &[_]Field{};

        // Collect all names that override parent fields
        var override_names = std.StringHashMap(void).init(self.alloc);
        for (child_before) |f| try override_names.put(f.name, {});
        for (child_after) |f| try override_names.put(f.name, {});
        for (concrete_fields) |f| try override_names.put(f.name, {});

        var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);

        // parent_before (skip overrides)
        for (parent_before) |f| {
            if (!override_names.contains(f.name)) {
                try result.append(self.alloc, f);
            }
        }

        // child_before
        for (child_before) |f| {
            try result.append(self.alloc, f);
        }

        // concrete fields (inserted at child's slot position)
        for (concrete_fields) |f| {
            try result.append(self.alloc, f);
        }

        // child_after
        for (child_after) |f| {
            try result.append(self.alloc, f);
        }

        // parent_after (skip overrides)
        for (parent_after) |f| {
            if (!override_names.contains(f.name)) {
                try result.append(self.alloc, f);
            }
        }

        return try result.toOwnedSlice(self.alloc);
    }

    fn applyTemplate(
        self: *SemanticAnalyzer,
        table: *const Table,
        template_fields: []const Field,
    ) ![]const Field {
        if (table.fields.len == 0) return template_fields;

        // The resolved template has no ... marker. Insert concrete fields at the end.
        // Template fields come first, then concrete fields.
        // Conflicts: concrete fields override template fields.

        var table_names = std.StringHashMap(void).init(self.alloc);
        for (table.fields) |f| try table_names.put(f.name, {});

        var result = try std.ArrayList(Field).initCapacity(self.alloc, 8);

        // Template fields (skip conflicts)
        for (template_fields) |f| {
            if (!table_names.contains(f.name)) {
                try result.append(self.alloc, f);
            }
        }

        // Table's concrete fields
        for (table.fields) |f| {
            try result.append(self.alloc, f);
        }

        return try result.toOwnedSlice(self.alloc);
    }
};
