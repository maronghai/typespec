const std = @import("std");
pub const ast_mod = @import("ast.zig");
const diag = @import("diagnostic.zig");
const template_mod = @import("template.zig");
const symbol_table_mod = @import("symbol_table.zig");
const ast = ast_mod.Ast;
const Ast = ast_mod.Ast;
const Template = ast_mod.Template;
const ResolvedTable = ast_mod.ResolvedTable;
const ResolvedAst = ast_mod.ResolvedAst;

// ─── Pass Manager ──────────────────────────────────────────────

/// Shared mutable context passed to each semantic pass.
pub const PassContext = struct {
    alloc: std.mem.Allocator,
    tables: *std.ArrayList(ResolvedTable),
    schema: ?ast_mod.Schema,
    templates: std.StringHashMap(*const Template) = undefined,
    diagnostics: *diag.DiagnosticCollector = undefined,
    symbol_table: symbol_table_mod.SymbolTable = undefined,
};

/// A semantic analysis pass that transforms the tables in PassContext.
pub const SemanticPass = struct {
    name: []const u8,
    run: *const fn (ctx: *PassContext) anyerror!void,
    depends_on: []const []const u8 = &.{},
};

/// Default pass pipeline — order matters!
pub const DEFAULT_PASSES = [_]SemanticPass{
    .{ .name = "validate_template_types", .run = @import("pass/validate_template_types.zig").run, .depends_on = &.{} },
    .{ .name = "resolve_names", .run = @import("pass/resolve_names.zig").run, .depends_on = &.{"validate_template_types"} },
    .{ .name = "autofk", .run = @import("pass/autofk.zig").run, .depends_on = &.{} },
    .{ .name = "suffix_inference", .run = @import("pass/suffix_inference.zig").run, .depends_on = &.{"autofk"} },
    .{ .name = "validate", .run = @import("pass/validate.zig").run, .depends_on = &.{ "autofk", "suffix_inference" } },
    .{ .name = "validate_type_modifiers", .run = @import("pass/validate_type_modifiers.zig").run, .depends_on = &.{"suffix_inference"} },
    .{ .name = "validate_indexes", .run = @import("pass/validate_indexes.zig").run, .depends_on = &.{"autofk"} },
    .{ .name = "validate_schema", .run = @import("pass/validate_schema.zig").run, .depends_on = &.{ "validate", "resolve_names" } },
};

// ─── SemanticAnalyzer ──────────────────────────────────────────

pub const SemanticAnalyzer = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SemanticAnalyzer {
        return .{ .alloc = alloc };
    }

    pub fn analyze(self: *SemanticAnalyzer, tree: Ast) !ResolvedAst {
        const resolved_tables = try template_mod.resolveAndApply(self.alloc, tree);

        var tables = try std.ArrayList(ResolvedTable).initCapacity(self.alloc, resolved_tables.len);
        for (resolved_tables) |t| {
            try tables.append(self.alloc, t);
        }

        const tmpl_map = try template_mod.buildTemplateMap(self.alloc, tree.templates);

        if (comptime std.debug.runtime_safety) {
            var seen_names = std.StringHashMap(void).init(self.alloc);
            defer seen_names.deinit();
            for (DEFAULT_PASSES) |pass| {
                for (pass.depends_on) |dep| {
                    if (!seen_names.contains(dep)) {
                        std.debug.panic("SemanticPass '{s}' depends on '{s}' which has not run yet", .{ pass.name, dep });
                    }
                }
                try seen_names.put(pass.name, {});
            }
        }
        var diagnostics = try diag.DiagnosticCollector.init(self.alloc);
        var ctx = PassContext{
            .alloc = self.alloc,
            .tables = &tables,
            .schema = tree.schema,
            .templates = tmpl_map,
            .diagnostics = &diagnostics,
        };
        for (DEFAULT_PASSES) |pass| {
            try pass.run(&ctx);
        }

        diagnostics.printAll();

        if (diagnostics.hasErrors()) {
            return error.SemanticError;
        }

        return .{
            .schema_name = if (tree.schema) |s| s.name else null,
            .schema_charset = if (tree.schema) |s| s.charset orelse "utf8mb4" else null,
            .custom_types = if (tree.schema) |s| s.custom_types else &.{},
            .tables = try tables.toOwnedSlice(self.alloc),
            .views = tree.views,
            .sql_comments = tree.sql_comments,
        };
    }
};

// ─── Diagnostic ──────────────────────────────────────────────

const trace = @import("trace.zig");

pub fn diagnosticTrace(resolved: ResolvedAst) void {
    std.debug.print("=== [Stage 3: Semantic] ===\n\n", .{});

    std.debug.print("Suffix inference:\n", .{});
    std.debug.print("  _id -> int, _on -> date, _at -> datetime, (none) -> varchar(255)\n", .{});
    if (resolved.schema_name != null) {
        std.debug.print("  autofk: ", .{});
        var has_autofk = false;
        for (resolved.tables) |table| {
            for (table.fields) |field| {
                if (field.fk) |fk| {
                    if (fk.fields.len > 0 and fk.fields[0].len > 3 and std.mem.endsWith(u8, fk.fields[0], "_id")) {
                        has_autofk = true;
                        break;
                    }
                }
            }
            if (has_autofk) break;
        }
        if (has_autofk) {
            std.debug.print("yes\n", .{});
        } else {
            std.debug.print("no\n", .{});
        }
    }
    std.debug.print("\n", .{});

    if (resolved.tables.len > 0) {
        std.debug.print("Resolved tables ({d}):\n", .{resolved.tables.len});
        for (resolved.tables) |table| {
            std.debug.print("  # {s}", .{table.name});
            if (table.comment) |c| std.debug.print(" {s}", .{c});
            std.debug.print("\n", .{});

            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                std.debug.print("    {s: <24} ", .{field.name});
                trace.fmtTypeInfo(field.type_info);
                trace.fmtModifiers(field.modifiers);
                if (field.default_val) |dv| std.debug.print(" DEFAULT {s}", .{dv.value});
                if (field.check) |ck| std.debug.print(" CHECK({s})", .{ck.expr});
                if (field.fk) |fk| {
                    std.debug.print(" -> {s}(", .{fk.ref_table});
                    for (fk.ref_fields, 0..) |f, fi| {
                        if (fi > 0) std.debug.print(",", .{});
                        std.debug.print("{s}", .{f});
                    }
                    std.debug.print(")", .{});
                    for (fk.actions) |action| {
                        trace.formatFkAction(action);
                    }
                }
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
            for (table.indexes) |idx| {
                trace.formatResolvedIndex(idx);
            }
        }
        std.debug.print("\n", .{});
    }

    if (resolved.sql_comments.len > 0) {
        std.debug.print("SQL Comments ({d}):\n", .{resolved.sql_comments.len});
        for (resolved.sql_comments) |sc| {
            std.debug.print("  L{d}: {s}\n", .{ sc.line_no, sc.text });
        }
        std.debug.print("\n", .{});
    }
}

// ─── Unit Tests ─────────────────────────────────────────────

const testing = std.testing;
const ast_mod_test = ast_mod;
const Field = ast_mod_test.Field;
const Modifier = ast_mod_test.Modifier;
const test_helpers = struct {
    const makeTestField = @import("test_helpers.zig").makeTestField;
    const makeTestAst = @import("test_helpers.zig").makeTestAst;
};

test "suffix inference: _id → int" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("user_id", .none);

    const a = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod_test.Table, &.{.{
        .name = "order",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(a);

    try testing.expectEqual(@as(usize, 1), result.tables.len);
    try testing.expectEqual(@as(usize, 1), result.tables[0].fields.len);
    try testing.expectEqualStrings("n", result.tables[0].fields[0].type_info.simple);
}

test "suffix inference: _at → datetime" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("created_at", .none);

    const a = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod_test.Table, &.{.{
        .name = "log",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(a);

    try testing.expectEqualStrings("t", result.tables[0].fields[0].type_info.simple);
}

test "suffix inference: _on → date" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("paid_on", .none);

    const a = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod_test.Table, &.{.{
        .name = "payment",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(a);

    try testing.expectEqualStrings("d", result.tables[0].fields[0].type_info.simple);
}

test "suffix inference: explicit type wins over suffix" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("point_id", .{ .varchar_explicit = 32 });

    const a = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod_test.Table, &.{.{
        .name = "points",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(a);

    const fi = result.tables[0].fields[0].type_info;
    try testing.expect(std.meta.activeTag(fi) == .varchar_explicit);
}

test "suffix inference: no suffix keeps explicit type" {
    const alloc = testing.allocator;
    const fields = try alloc.alloc(Field, 1);
    fields[0] = test_helpers.makeTestField("data", .{ .simple = "b" });

    const a = test_helpers.makeTestAst(alloc, try alloc.dupe(ast_mod_test.Table, &.{.{
        .name = "t",
        .template_ref = null,
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    }}), &.{});

    var sa = SemanticAnalyzer.init(alloc);
    const result = try sa.analyze(a);

    try testing.expectEqualStrings("b", result.tables[0].fields[0].type_info.simple);
}

// ─── Type Modifier Validation Tests ─────────────────────────

fn makeTestFieldWithMods(name: []const u8, type_info: ast_mod_test.TypeInfo, mods: []const Modifier) Field {
    return .{
        .name = name,
        .type_info = type_info,
        .modifiers = mods,
        .default_val = null,
        .check = null,
        .fk = null,
        .comment = null,
        .line_no = 1,
    };
}

test "validate_type_modifiers: ++ on varchar produces warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .auto_inc_pk, .line_no = 3 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("name", .{ .simple = "s" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = try diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try @import("pass/validate_type_modifiers.zig").run(&ctx);
    try testing.expect(diagnostics.diagnostics.items.len > 0);
}

test "validate_type_modifiers: u on varchar produces warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .unsigned, .line_no = 2 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("tag", .{ .simple = "s" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = try diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try @import("pass/validate_type_modifiers.zig").run(&ctx);
    try testing.expect(diagnostics.diagnostics.items.len > 0);
}

test "validate_type_modifiers: ++ on n produces no warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .auto_inc_pk, .line_no = 1 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("id", .{ .simple = "n" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = try diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try @import("pass/validate_type_modifiers.zig").run(&ctx);
    try testing.expectEqual(@as(usize, 0), diagnostics.diagnostics.items.len);
}

test "validate_type_modifiers: + on t produces no warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .auto_inc, .line_no = 1 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("created_at", .{ .simple = "t" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = try diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try @import("pass/validate_type_modifiers.zig").run(&ctx);
    try testing.expectEqual(@as(usize, 0), diagnostics.diagnostics.items.len);
}

test "validate_type_modifiers: u on n produces no warning" {
    const alloc = testing.allocator;
    const mods = try alloc.alloc(Modifier, 1);
    mods[0] = .{ .kind = .unsigned, .line_no = 1 };
    const fields = try alloc.alloc(Field, 1);
    fields[0] = makeTestFieldWithMods("count", .{ .simple = "n" }, mods);

    var tables = try std.ArrayList(ResolvedTable).initCapacity(alloc, 1);
    try tables.append(alloc, .{
        .name = "t",
        .comment = null,
        .engine = null,
        .fields = fields,
        .fks = &.{},
        .indexes = &.{},
        .line_no = 1,
    });

    var diagnostics = try diag.DiagnosticCollector.init(alloc);
    var ctx = PassContext{
        .alloc = alloc,
        .tables = &tables,
        .schema = null,
        .diagnostics = &diagnostics,
    };
    try @import("pass/validate_type_modifiers.zig").run(&ctx);
    try testing.expectEqual(@as(usize, 0), diagnostics.diagnostics.items.len);
}
