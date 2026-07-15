const std = @import("std");
const sp = @import("sql_parser.zig");
const reverse_map = @import("reverse_map.zig");
const dialect_mod = @import("dialect.zig");
const Dialect = sp.Dialect;
const template_ext = @import("template_extraction.zig");

// ─── Type Reverse Mapping ────────────────────────────────────────

fn reverseType(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool, dialect: Dialect) TypeResult {
    const r = reverse_map.reverseLookup(sql_type, col_name, is_auto_inc, is_default_ts, dialect);
    return .{ .tps = r.tps, .omit = r.omit, .confidence = r.confidence };
}

const TypeResult = struct {
    tps: []const u8,
    omit: bool,
    confidence: reverse_map.Confidence = .high,
};

fn isDatetime(sql_type: []const u8) bool {
    return reverse_map.isDatetimeSqlType(sql_type);
}

fn isCurrentTimestamp(dv: []const u8) bool {
    return reverse_map.isCurrentTimestamp(dv);
}

// ─── Write Modifier + CHECK inline ──────────────────────────────

fn writeColumnSuffix(w: anytype, col: sp.SqlColumn, indexes: []const sp.SqlIndex, check_expr: ?[]const u8, dialect: Dialect, table_name: []const u8) !void {
    // ---- type ----
    const is_ai = col.auto_increment;
    const is_ts = if (col.default_val) |dv| isCurrentTimestamp(dv) else false;
    const tr: TypeResult = if (col.tps_override) |tps|
        .{ .tps = tps, .omit = false, .confidence = .high }
    else
        reverseType(col.type_sql, col.name, is_ai, is_ts, dialect);
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
    } else if (isDatetime(col.type_sql) or std.mem.eql(u8, tr.tps, "t")) {
        // datetime without auto_increment — check DEFAULT for +/++
        if (col.default_val) |dv| {
            if (isCurrentTimestamp(dv)) {
                // Heuristic: column name contains "update"/"updated" → on_update_current_timestamp (++)
                const is_update_col = std.mem.indexOf(u8, col.name, "update") != null or
                    std.mem.indexOf(u8, col.name, "updated") != null;
                if (col.on_update_current_timestamp or is_update_col) {
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
    //    Use isInlineIndex (table-prefixed aware) to decide inline vs standalone.
    var has_inline_index = false;
    for (indexes) |idx| {
        if (idx.fields.len == 1 and std.mem.eql(u8, idx.fields[0], col.name)) {
            if (idx.kind == .unique and isInlineIndex(idx, table_name)) {
                try w.writeAll(" @u");
                has_inline_index = true;
            } else if (idx.kind == .regular and isInlineIndex(idx, table_name)) {
                try w.writeAll(" @");
                has_inline_index = true;
            }
        }
    }

    // 5. DEFAULT value
    if (col.default_val) |dv| {
        // datetime + CURRENT_TIMESTAMP/now() is already handled above (via + or ++)
        if ((isDatetime(col.type_sql) or std.mem.eql(u8, tr.tps, "t")) and isCurrentTimestamp(dv)) {
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

    // 8. Confidence comment (dialect-specific, only when not high)
    //    Suppress when an inline index suffix was added — the suffix already
    //    carries meaning and the comment would clutter the same line.
    if (tr.confidence != .high and !has_inline_index) {
        // Only emit confidence comment if there's no existing comment
        if (col.comment == null or (col.comment != null and (col.comment.?.len == 0))) {
            const conf_str: []const u8 = switch (tr.confidence) {
                .high => unreachable,
                .medium => "MEDIUM",
                .low => "LOW",
            };
            const backend = dialect_mod.getBackend(dialect);
            try backend.emitConfidenceComment(w, conf_str);
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
// Delegated to template_extraction.zig (single-responsibility).

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
        var tmpl_list: []template_ext.TemplateCandidate = &.{};
        if (extract_templates) {
            tmpl_list = try template_ext.findTemplates(self.alloc, schema);
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
                const tbl_name = if (t.table_indices.len > 0) schema.tables[t.table_indices[0]].name else "";
                try writeColumnSuffix(w, col, ref_indexes, null, self.dialect, tbl_name);
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
                try w.print(" : {s}", .{c});
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
                    try writeColumnSuffix(w, col, table.indexes, ck, self.dialect, table.name);
                    try w.writeAll("\n");
                }
            } else {
                // No template — output all columns
                for (table.columns) |col| {
                    try w.writeAll(col.name);
                    const ck = if (col.check_expr) |ce| reverseCheck(self.alloc, ce, col.name) else check_map.get(col.name);
                    try writeColumnSuffix(w, col, table.indexes, ck, self.dialect, table.name);
                    try w.writeAll("\n");
                }
            }

            // Standalone indexes
            for (table.indexes) |idx| {
                if (idx.kind == .primary_key) continue;
                if (isInlineIndex(idx, table.name)) continue;

                try w.writeAll("\n");
                // Check if index name matches auto-generated pattern.
                // If not, use full form to preserve the explicit name.
                const is_auto = isAutoGeneratedName(idx);
                switch (idx.kind) {
                    .regular => {
                        if (is_auto) {
                            try w.writeAll("@ ");
                            for (idx.fields, 0..) |f, fi| {
                                if (fi > 0) try w.writeAll(" ");
                                try w.writeAll(f);
                                if (fi < idx.descending.len and idx.descending[fi]) try w.writeAll("-");
                            }
                        } else {
                            try w.print("@ {s} (", .{idx.name});
                            for (idx.fields, 0..) |f, fi| {
                                if (fi > 0) try w.writeAll(", ");
                                try w.writeAll(f);
                            }
                            try w.writeAll(")");
                        }
                    },
                    .unique => {
                        if (is_auto) {
                            try w.writeAll("@u ");
                            for (idx.fields, 0..) |f, fi| {
                                if (fi > 0) try w.writeAll(" ");
                                try w.writeAll(f);
                                if (fi < idx.descending.len and idx.descending[fi]) try w.writeAll("-");
                            }
                        } else {
                            try w.print("@u {s} (", .{idx.name});
                            for (idx.fields, 0..) |f, fi| {
                                if (fi > 0) try w.writeAll(", ");
                                try w.writeAll(f);
                            }
                            try w.writeAll(")");
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

/// Check if an index name matches the auto-generated pattern.
/// Auto-generated: idx_field1_field2, uk_field1_field2
fn isAutoGeneratedName(idx: sp.SqlIndex) bool {
    if (idx.fields.len == 0) return false;
    const prefix: []const u8 = switch (idx.kind) {
        .regular => "idx_",
        .unique => "uk_",
        else => return false,
    };
    if (idx.name.len <= prefix.len) return false;
    if (!std.mem.startsWith(u8, idx.name, prefix)) return false;
    // Build expected name: prefix + fields joined by '_'
    var expected_len = prefix.len;
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) expected_len += 1;
        expected_len += f.len;
    }
    if (idx.name.len != expected_len) return false;
    var pos: usize = prefix.len;
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) {
            if (pos >= idx.name.len or idx.name[pos] != '_') return false;
            pos += 1;
        }
        if (!std.mem.eql(u8, idx.name[pos .. pos + f.len], f)) return false;
        pos += f.len;
    }
    return true;
}

fn isInlineIndex(idx: sp.SqlIndex, _: []const u8) bool {
    if (idx.fields.len != 1) return false;
    const f = idx.fields[0];
    // Must have room for at least "x_" before the field name
    if (idx.name.len <= f.len + 1) return false;
    if (!std.mem.endsWith(u8, idx.name, f)) return false;
    // The character before the field name must be '_'
    const sep_pos = idx.name.len - f.len - 1;
    if (idx.name[sep_pos] != '_') return false;
    const prefix = idx.name[0..sep_pos];
    // Accept "idx" / "uk" directly, or "idx_<table>" / "uk_<table>" for
    // PG/SQLite table-prefixed auto-generated names (e.g. idx_t_id).
    switch (idx.kind) {
        .unique => return std.mem.eql(u8, prefix, "uk") or
            (std.mem.startsWith(u8, prefix, "uk_") and prefix.len > 3),
        .regular => return std.mem.eql(u8, prefix, "idx") or
            (std.mem.startsWith(u8, prefix, "idx_") and prefix.len > 4),
        else => return false,
    }
}

// ─── Inline Tests ──────────────────────────────────────────────

test "isInlineIndex uk_* matches" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_email",
        .fields = &.{"email"},
        .descending = &.{},
    };
    try std.testing.expect(isInlineIndex(idx, ""));
}

test "isInlineIndex idx_* matches" {
    const idx = sp.SqlIndex{
        .kind = .regular,
        .name = "idx_name",
        .fields = &.{"name"},
        .descending = &.{},
    };
    try std.testing.expect(isInlineIndex(idx, ""));
}

test "isInlineIndex multi-field → false" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_a_b",
        .fields = &.{ "a", "b" },
        .descending = &.{},
    };
    try std.testing.expect(!isInlineIndex(idx, ""));
}

test "isInlineIndex name mismatch → false" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_email",
        .fields = &.{"name"},
        .descending = &.{},
    };
    try std.testing.expect(!isInlineIndex(idx, ""));
}

test "isInlineIndex primary_key → false" {
    const idx = sp.SqlIndex{
        .kind = .primary_key,
        .name = "",
        .fields = &.{"id"},
        .descending = &.{},
    };
    try std.testing.expect(!isInlineIndex(idx, ""));
}

test "isInlineIndex PG table-prefixed uk matches" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_user_email",
        .fields = &.{"email"},
        .descending = &.{},
    };
    try std.testing.expect(isInlineIndex(idx, "user"));
}

test "isInlineIndex PG table-prefixed idx matches" {
    const idx = sp.SqlIndex{
        .kind = .regular,
        .name = "idx_t_name",
        .fields = &.{"name"},
        .descending = &.{},
    };
    try std.testing.expect(isInlineIndex(idx, "t"));
}

test "reverseCheck BETWEEN" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "age BETWEEN 0 AND 150", "age");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("[0,150]", result.?);
}

test "reverseCheck IN list" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "status IN ('active', 'pending')", "status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{active,pending}", result.?);
}

test "reverseCheck >= comparison" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "age >= 18", "age");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{>=18}", result.?);
}

test "reverseCheck upper exclusive range" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "price >= 10 AND price < 100", "price");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("[10,100)", result.?);
}

test "reverseCheck lower exclusive range" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "score > 0 AND score <= 100", "score");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("(0,100]", result.?);
}

test "reverseCheck no match → null" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "x = 1", "y");
    try std.testing.expect(result == null);
}

test "reverseCheck both exclusive range" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "score > 0 AND score < 100", "score");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("(0,100)", result.?);
}

test "reverseCheck compound comparison >= AND <=" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "age >= 18 AND age <= 65", "age");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{>=18,<=65}", result.?);
}

test "reverseCheck single comparison =" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "status = 1", "status");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{=1}", result.?);
}

test "reverseCheck single comparison <" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "count < 10", "count");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{<10}", result.?);
}

test "reverseCheck backtick-quoted column" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "`age` BETWEEN 0 AND 150", "age");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("[0,150]", result.?);
}

test "reverseCheck double-quote-quoted column" {
    const alloc = std.testing.allocator;
    const result = reverseCheck(alloc, "\"age\" BETWEEN 0 AND 150", "age");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("[0,150]", result.?);
}

test "classifyFk shorthand single→id" {
    const alloc = std.testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"user_id"},
        .ref_table = "user",
        .ref_fields = &.{"id"},
        .actions = &.{},
    };
    const result = classifyFk(alloc, fk);
    try std.testing.expectEqual(FkForm.shorthand, result.form);
    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("> user_id user.id", result.text.?);
}

test "classifyFk full multi-field" {
    const alloc = std.testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{ "a_id", "b_id" },
        .ref_table = "ab",
        .ref_fields = &.{ "a", "b" },
        .actions = &.{},
    };
    const result = classifyFk(alloc, fk);
    try std.testing.expectEqual(FkForm.full, result.form);
}

test "classifyFk full with actions" {
    const alloc = std.testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"order_id"},
        .ref_table = "orders",
        .ref_fields = &.{"id"},
        .actions = &.{
            .{ .trigger = .on_delete, .action = .cascade },
        },
    };
    const result = classifyFk(alloc, fk);
    try std.testing.expectEqual(FkForm.full, result.form);
    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("> order_id orders.id -C", result.text.?);
}

test "classifyFk full with multiple actions" {
    const alloc = std.testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"order_id"},
        .ref_table = "orders",
        .ref_fields = &.{"id"},
        .actions = &.{
            .{ .trigger = .on_delete, .action = .cascade },
            .{ .trigger = .on_update, .action = .set_null },
        },
    };
    const result = classifyFk(alloc, fk);
    try std.testing.expectEqual(FkForm.full, result.form);
    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("> order_id orders.id -C N", result.text.?);
}

test "classifyFk shorthand with non-id reference" {
    const alloc = std.testing.allocator;
    const fk = sp.SqlForeignKey{
        .fields = &.{"email"},
        .ref_table = "auth",
        .ref_fields = &.{"email"},
        .actions = &.{},
    };
    const result = classifyFk(alloc, fk);
    try std.testing.expectEqual(FkForm.full, result.form);
    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("> email auth(email)", result.text.?);
}

test "ReverseCodegen basic generate" {
    const alloc = std.testing.allocator;
    const schema = sp.SqlSchema{
        .name = "testdb",
        .charset = "utf8mb4",
        .tables = &.{
            .{
                .name = "users",
                .engine = null,
                .charset = null,
                .comment = null,
                .columns = &.{
                    .{ .name = "id", .type_sql = "INTEGER", .nullable = false, .unsigned = false, .auto_increment = true, .primary_key = true, .on_update_current_timestamp = false, .default_val = null, .check_expr = null, .comment = null, .tps_override = "n" },
                    .{ .name = "name", .type_sql = "TEXT", .nullable = false, .unsigned = false, .auto_increment = false, .primary_key = false, .on_update_current_timestamp = false, .default_val = null, .check_expr = null, .comment = null, .tps_override = "s32" },
                },
                .indexes = &.{},
                .foreign_keys = &.{},
                .checks = &.{},
            },
        },
    };
    var rc = ReverseCodegen.init(alloc, .sqlite);
    const output = try rc.generate(schema);
    defer alloc.free(output);

    // Should contain schema name
    try std.testing.expect(std.mem.indexOf(u8, output, "$ testdb") != null);
    // Should contain table definition
    try std.testing.expect(std.mem.indexOf(u8, output, "# users") != null);
    // Should contain fields with TPS types from override
    try std.testing.expect(std.mem.indexOf(u8, output, "id n++") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "name s32") != null);
}

// ─── Template Extraction Tests ──────────────────────────────
// Template extraction tests live in template_extraction.zig.
