const std = @import("std");
const sp = @import("sql_parser.zig");

// ─── Template Extraction (Greedy Algorithm) ────────────────────
// Extracted from reverse_codegen.zig for single-responsibility.
// Finds common field patterns across tables and extracts them as templates.

pub const TemplateCandidate = struct {
    name: []const u8,
    fields: []const sp.SqlColumn,
    table_indices: []const usize,
};

pub fn findTemplates(alloc: std.mem.Allocator, schema: sp.SqlSchema) ![]TemplateCandidate {
    if (schema.tables.len < 2) return &.{};

    var max_cols: usize = 0;
    for (schema.tables) |t| {
        if (t.columns.len > max_cols) max_cols = t.columns.len;
    }
    if (max_cols < 2) return &.{};

    var candidates = try std.ArrayList(TemplateCandidate).initCapacity(alloc, 4);
    var covered_fields = try std.ArrayList([]const u8).initCapacity(alloc, 32);

    // Find templates greedily, each must introduce at least one new field
    var template_idx: usize = 0;
    const max_templates = @max(1, schema.tables.len / 3);
    while (template_idx < max_templates) {
        const result = findBestWithNewFields(alloc, covered_fields.items, schema, max_cols) orelse break;
        template_idx += 1;
        const name = if (template_idx == 1) "base" else try std.fmt.allocPrint(alloc, "base{d}", .{template_idx});
        // Track newly covered fields
        for (result.fields) |col| {
            var already = false;
            for (covered_fields.items) |cf| {
                if (std.mem.eql(u8, col.name, cf)) {
                    already = true;
                    break;
                }
            }
            if (!already) try covered_fields.append(alloc, col.name);
        }
        try candidates.append(alloc, .{
            .name = name,
            .fields = result.fields,
            .table_indices = result.table_indices,
        });
    }

    // Assign each table to the template covering the most of its fields
    var table_template_idx = try std.ArrayList(usize).initCapacity(alloc, schema.tables.len);
    for (0..schema.tables.len) |_| try table_template_idx.append(alloc, std.math.maxInt(usize));

    for (schema.tables, 0..) |table, ti| {
        var best_tmpl: usize = std.math.maxInt(usize);
        var best_fields: usize = 0;
        for (candidates.items, 0..) |cand, ci| {
            // Table must have ALL template fields to use this template
            var has_all = true;
            for (cand.fields) |f| {
                var found = false;
                for (table.columns) |col| {
                    if (std.mem.eql(u8, col.name, f.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    has_all = false;
                    break;
                }
            }
            if (!has_all) continue;
            // Pick template with most fields (longest match)
            if (cand.fields.len > best_fields or (cand.fields.len == best_fields and ci < best_tmpl)) {
                best_fields = cand.fields.len;
                best_tmpl = ci;
            }
        }
        if (best_tmpl != std.math.maxInt(usize)) {
            table_template_idx.items[ti] = best_tmpl;
        }
    }

    // Build final templates with assigned tables, renumber sequentially
    var result = try std.ArrayList(TemplateCandidate).initCapacity(alloc, candidates.items.len);
    var final_idx: usize = 0;
    for (candidates.items, 0..) |cand, ci| {
        var assigned = try std.ArrayList(usize).initCapacity(alloc, 8);
        for (table_template_idx.items, 0..) |tti, ti| {
            if (tti == ci) try assigned.append(alloc, ti);
        }
        if (assigned.items.len >= 2) {
            final_idx += 1;
            const name = if (final_idx == 1) "base" else try std.fmt.allocPrint(alloc, "base{d}", .{final_idx});
            try result.append(alloc, .{
                .name = name,
                .fields = cand.fields,
                .table_indices = try assigned.toOwnedSlice(alloc),
            });
        }
    }
    return try result.toOwnedSlice(alloc);
}

// ─── Internal Helpers ──────────────────────────────────────────

const BestResult = struct {
    fields: []const sp.SqlColumn,
    table_indices: []const usize,
};

fn findBestWithNewFields(alloc: std.mem.Allocator, covered: []const []const u8, schema: sp.SqlSchema, max_cols: usize) ?BestResult {
    var best: ?BestResult = null;
    var best_match_count: usize = 0;
    var best_score: f64 = 0.0;

    var L = max_cols;
    while (L >= 2) : (L -= 1) {
        if (best != null and L < 3) break;

        for (schema.tables) |table| {
            if (table.columns.len < L) continue;
            var start: usize = 0;
            while (start <= table.columns.len - L) : (start += 1) {
                const candidate_slice = table.columns[start .. start + L];

                // Must contain at least 2 fields not in covered set
                var new_count: usize = 0;
                for (candidate_slice) |col| {
                    var found_new = true;
                    for (covered) |cf| {
                        if (std.mem.eql(u8, col.name, cf)) {
                            found_new = false;
                            break;
                        }
                    }
                    if (found_new) new_count += 1;
                }
                if (new_count < 2) continue;

                // Find matching tables
                var matching = std.ArrayList(usize).initCapacity(alloc, 8) catch continue;
                for (schema.tables, 0..) |other, oi| {
                    if (other.columns.len < L) continue;
                    var found = false;
                    var os: usize = 0;
                    while (os <= other.columns.len - L) : (os += 1) {
                        var match = true;
                        for (candidate_slice, 0..) |col, ci| {
                            if (!std.mem.eql(u8, col.name, other.columns[os + ci].name) or
                                !std.mem.eql(u8, col.type_sql, other.columns[os + ci].type_sql))
                            {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            found = true;
                            break;
                        }
                    }
                    if (found) matching.append(alloc, oi) catch {};
                }

                if (matching.items.len >= 2) {
                    // Score = shared_tables * field_count * log2(field_count)
                    // Favors templates that cover many fields across many tables
                    const score = @as(f64, @floatFromInt(matching.items.len)) *
                        @as(f64, @floatFromInt(L)) *
                        std.math.log2(@as(f64, @floatFromInt(L)));
                    const is_better = if (best == null)
                        true
                    else
                        score > best_score;

                    if (is_better) {
                        best_match_count = matching.items.len;
                        best_score = score;
                        best = .{
                            .fields = candidate_slice,
                            .table_indices = matching.toOwnedSlice(alloc) catch return null,
                        };
                    }
                }
            }
        }
    }
    return best;
}

// ─── Unit Tests ──────────────────────────────────────────────

const testing = std.testing;

fn makeSqlCol(name: []const u8, type_sql: []const u8) sp.SqlColumn {
    return .{
        .name = name,
        .type_sql = type_sql,
        .nullable = true,
        .unsigned = false,
        .auto_increment = false,
        .primary_key = false,
        .on_update_current_timestamp = false,
        .default_val = null,
        .check_expr = null,
        .comment = null,
    };
}

fn makeSqlTable(name: []const u8, columns: []const sp.SqlColumn) sp.SqlTable {
    return .{
        .name = name,
        .engine = null,
        .charset = null,
        .comment = null,
        .columns = columns,
        .indexes = &.{},
        .foreign_keys = &.{},
        .checks = &.{},
    };
}

test "findTemplates: single table → no templates" {
    const alloc = testing.allocator;
    const schema = sp.SqlSchema{
        .name = null,
        .charset = null,
        .tables = &.{makeSqlTable("t1", &.{
            makeSqlCol("id", "INTEGER"),
            makeSqlCol("name", "TEXT"),
        })},
    };
    const result = try findTemplates(alloc, schema);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "findTemplates: two tables sharing fields → finds template" {
    const alloc = testing.allocator;
    const schema = sp.SqlSchema{
        .name = null,
        .charset = null,
        .tables = &.{
            makeSqlTable("users", &.{
                makeSqlCol("id", "INTEGER"),
                makeSqlCol("name", "TEXT"),
                makeSqlCol("email", "TEXT"),
            }),
            makeSqlTable("orders", &.{
                makeSqlCol("id", "INTEGER"),
                makeSqlCol("name", "TEXT"),
                makeSqlCol("total", "REAL"),
            }),
        },
    };
    const result = try findTemplates(alloc, schema);
    try testing.expect(result.len >= 1);
    // Template should cover id and name (shared by both tables)
    try testing.expectEqualStrings("base", result[0].name);
    try testing.expect(result[0].fields.len >= 2);
    try testing.expect(result[0].table_indices.len >= 2);
}

test "findTemplates: no shared fields → no templates" {
    const alloc = testing.allocator;
    const schema = sp.SqlSchema{
        .name = null,
        .charset = null,
        .tables = &.{
            makeSqlTable("t1", &.{
                makeSqlCol("a", "INTEGER"),
                makeSqlCol("b", "TEXT"),
            }),
            makeSqlTable("t2", &.{
                makeSqlCol("x", "REAL"),
                makeSqlCol("y", "TEXT"),
            }),
        },
    };
    const result = try findTemplates(alloc, schema);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "findTemplates: three tables, two share template" {
    const alloc = testing.allocator;
    const schema = sp.SqlSchema{
        .name = null,
        .charset = null,
        .tables = &.{
            makeSqlTable("t1", &.{
                makeSqlCol("id", "INTEGER"),
                makeSqlCol("created_at", "TIMESTAMP"),
                makeSqlCol("extra1", "TEXT"),
            }),
            makeSqlTable("t2", &.{
                makeSqlCol("id", "INTEGER"),
                makeSqlCol("created_at", "TIMESTAMP"),
                makeSqlCol("extra2", "TEXT"),
            }),
            makeSqlTable("t3", &.{
                makeSqlCol("foo", "INTEGER"),
                makeSqlCol("bar", "TEXT"),
            }),
        },
    };
    const result = try findTemplates(alloc, schema);
    // t1 and t2 share id+created_at, t3 has nothing in common
    if (result.len > 0) {
        try testing.expectEqualStrings("base", result[0].name);
        try testing.expect(result[0].table_indices.len >= 2);
    }
}

test "findTemplates: empty schema → no templates" {
    const alloc = testing.allocator;
    const schema = sp.SqlSchema{
        .name = null,
        .charset = null,
        .tables = &.{},
    };
    const result = try findTemplates(alloc, schema);
    try testing.expectEqual(@as(usize, 0), result.len);
}
