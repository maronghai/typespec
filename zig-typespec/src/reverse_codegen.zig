const std = @import("std");
const sp = @import("sql_parser.zig");
const type_map = @import("type_map.zig");
const Dialect = sp.Dialect;

// ─── Type Reverse Mapping ────────────────────────────────────────

fn reverseType(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool) TypeResult {
    const r = type_map.reverseLookup(sql_type, col_name, is_auto_inc, is_default_ts);
    return .{ .tps = r.tps, .omit = r.omit };
}

const TypeResult = struct { tps: []const u8, omit: bool };

fn isDatetime(sql_type: []const u8) bool {
    return type_map.isDatetimeSqlType(sql_type);
}

fn isCurrentTimestamp(dv: []const u8) bool {
    return type_map.isCurrentTimestamp(dv);
}

// ─── Write Modifier + CHECK inline ──────────────────────────────

fn writeColumnSuffix(w: anytype, col: sp.SqlColumn, indexes: []const sp.SqlIndex, check_expr: ?[]const u8) !void {
    // ---- type ----
    const is_ai = col.auto_increment;
    const is_ts = if (col.default_val) |dv| isCurrentTimestamp(dv) else false;
    const tr = reverseType(col.type_sql, col.name, is_ai, is_ts);
    if (!tr.omit) {
        try w.writeAll(" ");
        try w.writeAll(tr.tps);
    }

    // ---- modifiers ----
    // Detect PRIMARY KEY from table-level indexes (single-field PK)
    var has_table_pk = false;
    if (!col.primary_key) {
        for (indexes) |idx| {
            if (idx.kind == .primary_key and idx.fields.len == 1 and std.mem.eql(u8, idx.fields[0], col.name)) {
                has_table_pk = true;
                break;
            }
        }
    }
    const is_pk = col.primary_key or has_table_pk;

    // 1. prefix: ++ / + / ! for auto_increment / primary_key
    if (col.auto_increment and is_pk) {
        try w.writeAll(" ++");
    } else if (col.auto_increment) {
        try w.writeAll(" +");
    } else if (isDatetime(col.type_sql)) {
        // datetime without auto_increment — check DEFAULT for +/++
        if (col.default_val) |dv| {
            if (isCurrentTimestamp(dv)) {
                if (col.on_update_current_timestamp) {
                    try w.writeAll(" ++");
                } else {
                    try w.writeAll(" +");
                }
            } else if (col.primary_key) {
                try w.writeAll(" !");
            }
        } else if (is_pk) {
            try w.writeAll(" !");
        }
    } else if (is_pk) {
        try w.writeAll(" !");
    }

    // 2. NOT NULL — emit * only when NOT NULL is explicit in the SQL
    if (!col.nullable) {
        try w.writeAll(" *");
    }

    // 3. UNSIGNED
    if (col.unsigned) {
        try w.writeAll(" u");
    }

    // 4. INLINE UNIQUE / INDEX from standalone indexes
    for (indexes) |idx| {
        if (idx.fields.len == 1 and std.mem.eql(u8, idx.fields[0], col.name)) {
            if (idx.kind == .unique and idx.name.len > 3 and std.mem.startsWith(u8, idx.name, "uk_")) {
                try w.writeAll(" @u");
            } else if (idx.kind == .regular and idx.name.len > 4 and std.mem.startsWith(u8, idx.name, "idx_")) {
                try w.writeAll(" @");
            }
        }
    }

    // 5. DEFAULT value
    if (col.default_val) |dv| {
        // datetime + CURRENT_TIMESTAMP/now() is already handled above (via + or ++)
        if (isDatetime(col.type_sql) and isCurrentTimestamp(dv)) {
            // already emitted + or ++ above — skip
        } else if (std.mem.eql(u8, dv, "")) {
            // Empty string default (DEFAULT '') — skip, equivalent to no default
        } else if (std.mem.eql(u8, dv, "NULL")) {
            // DEFAULT NULL — only meaningful for nullable columns, skip (implicit)
        } else if (std.mem.startsWith(u8, dv, "b'") and std.mem.endsWith(u8, dv, "'")) {
            // MySQL binary literal b'0' / b'1' → strip to plain 0/1 for bit(1) / boolean
            try w.writeAll(" =");
            try w.writeAll(dv[2 .. dv.len - 1]);
        } else if (std.mem.eql(u8, dv, "gen_random_uuid()")) {
            // PG: uuid auto-gen default — skip (implicit for uuid type)
        } else {
            try w.writeAll(" =");
            try w.writeAll(dv);
        }
    }

    // 6. CHECK constraint (inline)
    if (check_expr) |ce| {
        try w.writeAll(" ");
        try w.writeAll(ce);
    }

    // 7. Field comment
    if (col.comment) |c| {
        if (c.len > 0) {
            try w.writeAll(" : ");
            try w.writeAll(c);
        }
    }
}

// ─── CHECK Reverse ───────────────────────────────────────────────

fn reverseCheck(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?[]const u8 {
    const e = std.mem.trim(u8, sql_expr, " \t");
    if (parseBetween(alloc, e, col_name)) |r| return r;
    if (parseUpperExcl(alloc, e, col_name)) |r| return r;
    if (parseLowerExcl(alloc, e, col_name)) |r| return r;
    if (parseBothExcl(alloc, e, col_name)) |r| return r;
    if (parseInList(alloc, e, col_name)) |r| return r;
    if (parseCompoundCmp(alloc, e, col_name)) |r| return r;
    if (parseSingleCmp(alloc, e, col_name)) |r| return r;
    return null;
}

fn parseBetween(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const bp = std.mem.indexOf(u8, e, " BETWEEN ") orelse return null;
    if (!fieldMatches(e[0..bp], cn)) return null;
    const rest = e[bp + 9 ..];
    const ap = std.mem.indexOf(u8, rest, " AND ") orelse return null;
    return fmtCheck(alloc, "[{s},{s}]", .{ std.mem.trim(u8, rest[0..ap], " "), std.mem.trim(u8, rest[ap + 5 ..], " ") });
}

fn parseUpperExcl(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lp = std.mem.indexOf(u8, l, " >= ") orelse return null;
    const rp = std.mem.indexOf(u8, r, " < ") orelse return null;
    if (!fieldMatches(l[0..lp], cn) or !fieldMatches(r[0..rp], cn)) return null;
    const high = r[rp + 3 ..];
    if (high.len > 0 and high[0] == '=') return null;
    return fmtCheck(alloc, "[{s},{s})", .{ l[lp + 4 ..], high });
}

fn parseLowerExcl(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lp = std.mem.indexOf(u8, l, " > ") orelse return null;
    const rp = std.mem.indexOf(u8, r, " <= ") orelse return null;
    if (!fieldMatches(l[0..lp], cn) or !fieldMatches(r[0..rp], cn)) return null;
    const low = l[lp + 3 ..];
    if (low.len > 0 and low[0] == '=') return null;
    return fmtCheck(alloc, "({s},{s}]", .{ low, r[rp + 4 ..] });
}

fn parseBothExcl(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lp = std.mem.indexOf(u8, l, " > ") orelse return null;
    const rp = std.mem.indexOf(u8, r, " < ") orelse return null;
    if (!fieldMatches(l[0..lp], cn) or !fieldMatches(r[0..rp], cn)) return null;
    const low = l[lp + 3 ..];
    const high = r[rp + 3 ..];
    if ((low.len > 0 and low[0] == '=') or (high.len > 0 and high[0] == '=')) return null;
    return fmtCheck(alloc, "({s},{s})", .{ low, high });
}

fn parseInList(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ip = std.mem.indexOf(u8, e, " IN ") orelse return null;
    if (!fieldMatches(e[0..ip], cn)) return null;
    const rest = e[ip + 4 ..];
    if (rest.len == 0 or rest[0] != '(') return null;
    // Parse: {val1,val2,...}
    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return null;
    buf.append(alloc, '{') catch return null;
    var i: usize = 1;
    var first = true;
    while (i < rest.len and rest[i] != ')') {
        if (rest[i] == '\'') {
            i += 1;
            const s = i;
            while (i < rest.len and rest[i] != '\'') i += 1;
            const val = rest[s..i];
            if (i < rest.len) i += 1;
            if (!first) buf.append(alloc, ',') catch return null;
            first = false;
            buf.appendSlice(alloc, val) catch return null;
        } else if (rest[i] == ' ' or rest[i] == ',' or rest[i] == '\t') {
            i += 1;
        } else {
            const s = i;
            while (i < rest.len and rest[i] != ')' and rest[i] != ',' and rest[i] != ' ') i += 1;
            const v = std.mem.trim(u8, rest[s..i], " ");
            if (v.len > 0) {
                if (!first) buf.append(alloc, ',') catch return null;
                first = false;
                buf.appendSlice(alloc, v) catch return null;
            }
        }
    }
    buf.append(alloc, '}') catch return null;
    return buf.toOwnedSlice(alloc) catch null;
}

fn parseCompoundCmp(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ap = std.mem.indexOf(u8, e, " AND ") orelse return null;
    const l = std.mem.trim(u8, e[0..ap], " \t`");
    const r = std.mem.trim(u8, e[ap + 5 ..], " \t`");
    const lo = oneCmp(alloc, l, cn) orelse return null;
    const ro = oneCmp(alloc, r, cn) orelse return null;
    return fmtCheck(alloc, "{{{s},{s}}}", .{ lo, ro });
}

fn parseSingleCmp(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, e, " AND ") != null) return null;
    const cmp = oneCmp(alloc, e, cn) orelse return null;
    return fmtCheck(alloc, "{{{s}}}", .{cmp});
}

fn oneCmp(alloc: std.mem.Allocator, e: []const u8, cn: []const u8) ?[]const u8 {
    const ops = [_][]const u8{ ">=", "<=", ">", "<", "=" };
    for (ops) |op| {
        const pp = std.mem.indexOf(u8, e, op) orelse continue;
        if (!fieldMatches(e[0..pp], cn)) continue;
        const v = std.mem.trim(u8, e[pp + op.len ..], " ");
        return fmtCheck(alloc, "{s}{s}", .{ op, v });
    }
    return null;
}

fn fieldMatches(raw: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t`"), expected);
}

fn fmtCheck(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch null;
}

// ─── FK Reverse ──────────────────────────────────────────────────

const FkForm = enum { ultra, shorthand, full };

fn classifyFk(alloc: std.mem.Allocator, fk: sp.SqlForeignKey) struct { form: FkForm, text: ?[]const u8 } {
    const single = fk.fields.len == 1 and fk.ref_fields.len == 1;
    const ref_is_id = fk.ref_fields.len == 1 and std.mem.eql(u8, fk.ref_fields[0], "id");

    if (single and ref_is_id) return .{ .form = .shorthand, .text = fmtCheck(alloc, "> {s} {s}.id", .{ fk.fields[0], fk.ref_table }) };

    // Full form — use ArrayList for dynamic sizing
    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return .{ .form = .full, .text = null };
    buf.appendSlice(alloc, "> ") catch return .{ .form = .full, .text = null };
    if (single) {
        buf.appendSlice(alloc, fk.fields[0]) catch return .{ .form = .full, .text = null };
    } else {
        buf.append(alloc, '(') catch return .{ .form = .full, .text = null };
        for (fk.fields, 0..) |f, i| {
            if (i > 0) buf.appendSlice(alloc, ", ") catch return .{ .form = .full, .text = null };
            buf.appendSlice(alloc, f) catch return .{ .form = .full, .text = null };
        }
        buf.append(alloc, ')') catch return .{ .form = .full, .text = null };
    }
    buf.append(alloc, ' ') catch return .{ .form = .full, .text = null };
    buf.appendSlice(alloc, fk.ref_table) catch return .{ .form = .full, .text = null };
    buf.append(alloc, '(') catch return .{ .form = .full, .text = null };
    for (fk.ref_fields, 0..) |f, i| {
        if (i > 0) buf.appendSlice(alloc, ", ") catch return .{ .form = .full, .text = null };
        buf.appendSlice(alloc, f) catch return .{ .form = .full, .text = null };
    }
    buf.append(alloc, ')') catch return .{ .form = .full, .text = null };

    for (fk.actions) |a| {
        buf.append(alloc, ' ') catch return .{ .form = .full, .text = null };
        switch (a.trigger) {
            .on_delete => if (a.action == .cascade) buf.appendSlice(alloc, "-C") catch {} else buf.appendSlice(alloc, "-N") catch {},
            .on_update => if (a.action == .cascade) buf.appendSlice(alloc, " C") catch {} else buf.appendSlice(alloc, " N") catch {},
        }
    }

    return .{ .form = .full, .text = buf.toOwnedSlice(alloc) catch null };
}

// ─── Template Extraction ─────────────────────────────────────────

const TemplateCandidate = struct {
    name: []const u8,
    fields: []const sp.SqlColumn,
    table_indices: []const usize,
};

fn findTemplates(alloc: std.mem.Allocator, schema: sp.SqlSchema) ![]TemplateCandidate {
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
                                !std.mem.eql(u8, col.type_sql, other.columns[os + ci].type_sql)) {
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

const BestResult = struct {
    fields: []const sp.SqlColumn,
    table_indices: []const usize,
};

// ─── Reverse Codegen ─────────────────────────────────────────────

pub const ReverseCodegen = struct {
    alloc: std.mem.Allocator,
    dialect: Dialect,

    pub fn init(alloc: std.mem.Allocator, dialect: Dialect) ReverseCodegen {
        return .{ .alloc = alloc, .dialect = dialect };
    }

    pub fn generate(self: *ReverseCodegen, schema: sp.SqlSchema) ![]const u8 {
        return self.generateInner(schema, false);
    }

    pub fn generateWithTemplates(self: *ReverseCodegen, schema: sp.SqlSchema) ![]const u8 {
        return self.generateInner(schema, true);
    }

    fn generateInner(self: *ReverseCodegen, schema: sp.SqlSchema, extract_templates: bool) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(self.alloc);
        const w = &aw.writer;

        // $ schema
        if (schema.name) |name| {
            try w.print("$ {s}", .{name});
            if (schema.charset) |cs| {
                // MySQL: omit utf8mb4 (default); PG: omit UTF8/utf8 (default)
                if (std.mem.eql(u8, cs, "utf8mb4") or std.mem.eql(u8, cs, "UTF8") or std.mem.eql(u8, cs, "utf8")) {
                    // default charset — omit
                } else {
                    try w.print(" {s}", .{cs});
                }
            }
            try w.writeAll("\n\n");
        }

        // Template extraction
        var tmpl_list: []TemplateCandidate = &.{};
        if (extract_templates) {
            tmpl_list = try findTemplates(self.alloc, schema);
        }

        // Output all template definitions with > inheritance
        for (tmpl_list, 0..) |t, ti| {
            var ref_indexes: []const sp.SqlIndex = &.{};
            if (t.table_indices.len > 0) {
                ref_indexes = schema.tables[t.table_indices[0]].indexes;
            }

            // Find parent template (earlier template whose fields are a subset)
            var parent_name: ?[]const u8 = null;
            if (ti > 0) {
                var best_parent: usize = 0;
                var best_overlap: usize = 0;
                for (tmpl_list[0..ti], 0..) |prev, pi| {
                    var overlap: usize = 0;
                    for (prev.fields) |pf| {
                        for (t.fields) |tf| {
                            if (std.mem.eql(u8, pf.name, tf.name)) {
                                overlap += 1;
                                break;
                            }
                        }
                    }
                    if (overlap > best_overlap) {
                        best_overlap = overlap;
                        best_parent = pi;
                    }
                }
                if (best_overlap > 0) {
                    parent_name = tmpl_list[best_parent].name;
                }
            }

            // Output: % name [> parent] \n ...
            if (parent_name) |pn| {
                try w.print("% {s} > {s}\n...\n", .{ t.name, pn });
            } else {
                try w.print("% {s}\n...\n", .{t.name});
            }

            // Output only NEW fields (not in parent)
            for (t.fields) |col| {
                var in_parent = false;
                if (parent_name) |pn| {
                    for (tmpl_list) |tl| {
                        if (std.mem.eql(u8, tl.name, pn)) {
                            for (tl.fields) |pf| {
                                if (std.mem.eql(u8, col.name, pf.name)) {
                                    in_parent = true;
                                    break;
                                }
                            }
                            break;
                        }
                    }
                }
                if (in_parent) continue;
                try w.writeAll(col.name);
                try writeColumnSuffix(w, col, ref_indexes, null);
                try w.writeAll("\n");
            }
            try w.writeAll("\n");
        }

        for (schema.tables, 0..) |table, ti| {
            // CHECK map
            var check_map = std.StringHashMap([]const u8).init(self.alloc);
            defer check_map.deinit();
            for (table.checks) |ck| {
                if (ck.field_name.len > 0) {
                    if (reverseCheck(self.alloc, ck.expr, ck.field_name)) |tps_expr| {
                        try check_map.put(ck.field_name, tps_expr);
                    }
                }
            }

            // Find which template this table belongs to (if any)
            var table_template: ?[]const u8 = null;
            var table_template_fields: []const sp.SqlColumn = &.{};
            for (tmpl_list) |t| {
                for (t.table_indices) |ti2| {
                    if (ti2 == ti) {
                        table_template = t.name;
                        table_template_fields = t.fields;
                        break;
                    }
                }
                if (table_template != null) break;
            }

            // # [template_ref] table_name : comment
            try w.writeAll("# ");
            if (table_template) |tn| {
                try w.print("{s} ", .{tn});
            }
            try w.writeAll(table.name);
            if (table.comment) |c| {
                try w.print("  : {s}", .{c});
            }
            try w.writeAll("\n");

            if (table_template != null) {
                // Output fields not in template
                for (table.columns) |col| {
                    var in_template = false;
                    for (table_template_fields) |tcol| {
                        if (std.mem.eql(u8, col.name, tcol.name)) {
                            in_template = true;
                            break;
                        }
                    }
                    if (in_template) continue;
                    try w.writeAll(col.name);
                    const ck = if (col.check_expr) |ce| reverseCheck(self.alloc, ce, col.name) else check_map.get(col.name);
                    try writeColumnSuffix(w, col, table.indexes, ck);
                    try w.writeAll("\n");
                }
            } else {
                // No template — output all columns
                for (table.columns) |col| {
                    try w.writeAll(col.name);
                    const ck = if (col.check_expr) |ce| reverseCheck(self.alloc, ce, col.name) else check_map.get(col.name);
                    try writeColumnSuffix(w, col, table.indexes, ck);
                    try w.writeAll("\n");
                }
            }

            // Standalone indexes
            for (table.indexes) |idx| {
                if (idx.kind == .primary_key) continue;
                if (isInlineIndex(idx)) continue;

                try w.writeAll("\n");
                switch (idx.kind) {
                    .regular => {
                        try w.writeAll("@ ");
                        for (idx.fields, 0..) |f, fi| {
                            if (fi > 0) try w.writeAll(" ");
                            try w.writeAll(f);
                            if (fi < idx.descending.len and idx.descending[fi]) try w.writeAll("-");
                        }
                    },
                    .unique => {
                        try w.writeAll("@u ");
                        for (idx.fields, 0..) |f, fi| {
                            if (fi > 0) try w.writeAll(" ");
                            try w.writeAll(f);
                            if (fi < idx.descending.len and idx.descending[fi]) try w.writeAll("-");
                        }
                    },
                    .fulltext => try w.print("@f {s}", .{idx.name}),
                    .primary_key => unreachable,
                }
            }

            // Foreign keys
            for (table.foreign_keys) |fk| {
                const cls = classifyFk(self.alloc, fk);
                if (cls.form == .ultra) continue;
                try w.writeAll("\n");
                if (cls.text) |txt| try w.writeAll(txt);
            }

            if (ti < schema.tables.len - 1) try w.writeAll("\n");
        }

        try w.flush();
        var out = aw.toArrayList();
        return try out.toOwnedSlice(self.alloc);
    }
};

fn isInlineIndex(idx: sp.SqlIndex) bool {
    if (idx.fields.len != 1) return false;
    const f = idx.fields[0];
    switch (idx.kind) {
        .unique => return idx.name.len > 3 and std.mem.startsWith(u8, idx.name, "uk_") and std.mem.eql(u8, idx.name[3..], f),
        .regular => return idx.name.len > 4 and std.mem.startsWith(u8, idx.name, "idx_") and std.mem.eql(u8, idx.name[4..], f),
        else => return false,
    }
}
