const std = @import("std");
const ast = @import("ast.zig");

// ─── Schema Symbol Table ────────────────────────────────────────
// Unified name resolution for templates, tables, and fields.
// Built once by the resolve_names pass, then queried by downstream passes.

pub const TableEntry = struct {
    table: *const ast.ResolvedTable,
};

pub const FieldEntry = struct {
    field: *const ast.Field,
    table_name: []const u8,
};

pub const SymbolTable = struct {
    tables: std.StringHashMap(TableEntry),
    templates: std.StringHashMap(void),

    pub fn init(alloc: std.mem.Allocator) SymbolTable {
        return .{
            .tables = std.StringHashMap(TableEntry).init(alloc),
            .templates = std.StringHashMap(void).init(alloc),
        };
    }

    /// Register a table. Returns false if the name is already taken.
    pub fn registerTable(self: *SymbolTable, name: []const u8, table: *const ast.ResolvedTable) !bool {
        if (self.tables.contains(name) or self.templates.contains(name)) return false;
        try self.tables.put(name, .{ .table = table });
        return true;
    }

    /// Register a template name. Returns false if the name is already taken.
    pub fn registerTemplate(self: *SymbolTable, name: []const u8) !bool {
        if (self.tables.contains(name) or self.templates.contains(name)) return false;
        try self.templates.put(name, {});
        return true;
    }

    /// Look up a table by name.
    pub fn lookupTable(self: *const SymbolTable, name: []const u8) ?*const ast.ResolvedTable {
        if (self.tables.get(name)) |entry| return entry.table;
        return null;
    }

    /// Look up a field by table name and field name.
    pub fn lookupField(self: *const SymbolTable, table_name: []const u8, field_name: []const u8) ?FieldEntry {
        const table = self.lookupTable(table_name) orelse return null;
        for (table.fields) |*field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return .{ .field = field, .table_name = table_name };
            }
        }
        return null;
    }

    /// Check if a table name exists (either as table or template).
    pub fn contains(self: *const SymbolTable, name: []const u8) bool {
        return self.tables.contains(name) or self.templates.contains(name);
    }
};
