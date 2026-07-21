const std = @import("std");
const sp = @import("sql_parser.zig");
const ast_mod = @import("ast.zig");
const reverse_map = @import("reverse_map.zig");
const dialect_mod = @import("dialect.zig");
const reverse_check = @import("reverse_check.zig");
const Dialect = sp.Dialect;

// ─── Column Reverse Output ─────────────────────────────────────
// Extracted from reverse_codegen.zig for single-responsibility.
// Handles writing TPS column definitions from SQL column metadata.

pub const TypeResult = struct {
    tps: []const u8,
    omit: bool,
    /// Confidence score 0-100. Higher = more certain.
    score: u8 = 100,
};

pub fn reverseType(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool, dialect: Dialect) TypeResult {
    const r = reverse_map.reverseLookup(sql_type, col_name, is_auto_inc, is_default_ts, dialect);
    return .{ .tps = r.tps, .omit = r.omit, .score = r.score };
}

pub fn isDatetime(sql_type: []const u8) bool {
    return reverse_map.isDatetimeSqlType(sql_type);
}

pub fn isCurrentTimestamp(dv: []const u8) bool {
    return reverse_map.isCurrentTimestamp(dv);
}

pub fn reverseCheck(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?[]const u8 {
    return reverse_check.reverseCheck(alloc, sql_expr, col_name);
}

pub fn parseSqlCheckExpr(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?ast_mod.CheckConstraint {
    return reverse_check.parseSqlCheckExpr(alloc, sql_expr, col_name);
}

/// Write TPS column suffix: type + modifiers + default + check + comment + confidence
pub fn writeColumnSuffix(w: anytype, col: sp.SqlColumn, indexes: []const sp.SqlIndex, check_expr: ?[]const u8, dialect: Dialect, table_name: []const u8) !void {
    const tr = try writeColumnType(w, col, dialect);
    const has_inline_index = try writeColumnModifiers(w, col, indexes, tr, table_name);
    try writeColumnDefault(w, col, tr);
    try writeColumnCheck(w, check_expr);
    try writeColumnComment(w, col);
    try writeColumnConfidence(w, col, tr, dialect, has_inline_index);
}

/// Resolve and write the TPS type symbol. Returns TypeResult for downstream use.
fn writeColumnType(w: anytype, col: sp.SqlColumn, dialect: Dialect) !TypeResult {
    const is_ai = col.auto_increment;
    const is_ts = if (col.default_val) |dv| isCurrentTimestamp(dv) else false;
    const tr: TypeResult = if (col.tps_override) |tps|
        .{ .tps = tps, .omit = false, .score = 100 }
    else
        reverseType(col.type_sql, col.name, is_ai, is_ts, dialect);
    if (!tr.omit) {
        try w.writeAll(" ");
        try w.writeAll(tr.tps);
    }
    return tr;
}

/// Write modifier suffixes: ++ / + / ! / * / u / @u / @
/// Returns true if an inline index suffix was emitted.
fn writeColumnModifiers(w: anytype, col: sp.SqlColumn, indexes: []const sp.SqlIndex, tr: TypeResult, table_name: []const u8) !bool {
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

    // prefix: ++ / + / ! for auto_increment / primary_key
    if (col.auto_increment and is_pk) {
        try w.writeAll(" ++");
    } else if (col.auto_increment) {
        try w.writeAll(" +");
    } else if (isDatetime(col.type_sql) or std.mem.eql(u8, tr.tps, "t")) {
        if (col.default_val) |dv| {
            if (isCurrentTimestamp(dv)) {
                // Heuristic: column name contains "update"/"updated" -> on_update_current_timestamp (++)
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

    // NOT NULL
    if (!col.nullable) {
        try w.writeAll(" *");
    }

    // UNSIGNED
    if (col.unsigned) {
        try w.writeAll(" u");
    }

    // INLINE UNIQUE / INDEX from standalone indexes
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

    return has_inline_index;
}

/// Write DEFAULT value.
fn writeColumnDefault(w: anytype, col: sp.SqlColumn, tr: TypeResult) !void {
    if (col.default_val) |dv| {
        // datetime + CURRENT_TIMESTAMP/now() is already handled above (via + or ++)
        if ((isDatetime(col.type_sql) or std.mem.eql(u8, tr.tps, "t")) and isCurrentTimestamp(dv)) {
            // already emitted + or ++ above — skip
        } else if (std.mem.eql(u8, dv, "")) {
            // Empty string default — skip
        } else if (std.mem.eql(u8, dv, "NULL")) {
            // DEFAULT NULL — skip (implicit)
        } else if (std.mem.startsWith(u8, dv, "b'") and std.mem.endsWith(u8, dv, "'")) {
            // MySQL binary literal b'0' / b'1' -> strip to plain 0/1
            try w.writeAll(" =");
            try w.writeAll(dv[2 .. dv.len - 1]);
        } else if (std.mem.eql(u8, dv, "gen_random_uuid()")) {
            // PG: uuid auto-gen default — skip (implicit for uuid type)
        } else {
            try w.writeAll(" =");
            try w.writeAll(dv);
        }
    }
}

/// Write CHECK constraint (inline).
fn writeColumnCheck(w: anytype, check_expr: ?[]const u8) !void {
    if (check_expr) |ce| {
        try w.writeAll(" ");
        try w.writeAll(ce);
    }
}

/// Write field comment.
fn writeColumnComment(w: anytype, col: sp.SqlColumn) !void {
    if (col.comment) |c| {
        if (c.len > 0) {
            try w.writeAll(" : ");
            try w.writeAll(c);
        }
    }
}

/// Write confidence comment (dialect-specific, only when score < 80).
/// Suppress when an inline index suffix was added — the suffix already
/// carries meaning and the comment would clutter the same line.
fn writeColumnConfidence(w: anytype, col: sp.SqlColumn, tr: TypeResult, dialect: Dialect, has_inline_index: bool) !void {
    if (tr.score < 80 and !has_inline_index) {
        // Only emit confidence comment if there's no existing comment
        if (col.comment == null or (col.comment != null and (col.comment.?.len == 0))) {
            var score_buf: [8]u8 = undefined;
            const score_str = std.fmt.bufPrint(&score_buf, "score:{d}", .{tr.score}) catch "score:?";
            const backend = dialect_mod.getBackend(dialect);
            try backend.emitConfidenceComment(w, score_str);
        }
    }
}

// ─── Index Helpers ─────────────────────────────────────────────
// Used by both column suffix (inline detection) and standalone index output.

/// Check if an index name matches the auto-generated pattern.
/// Auto-generated: idx_field1_field2, uk_field1_field2
pub fn isAutoGeneratedName(idx: sp.SqlIndex) bool {
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

/// Check if an index should be rendered inline (as @u / @) on a column
/// rather than as a standalone index declaration.
/// Accepts "idx" / "uk" directly, or "idx_<table>" / "uk_<table>" for
/// PG/SQLite table-prefixed auto-generated names (e.g. idx_t_id).
pub fn isInlineIndex(idx: sp.SqlIndex, _: []const u8) bool {
    if (idx.fields.len != 1) return false;
    const f = idx.fields[0];
    // Must have room for at least "x_" before the field name
    if (idx.name.len <= f.len + 1) return false;
    if (!std.mem.endsWith(u8, idx.name, f)) return false;
    // The character before the field name must be '_'
    const sep_pos = idx.name.len - f.len - 1;
    if (idx.name[sep_pos] != '_') return false;
    const prefix = idx.name[0..sep_pos];
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

test "isInlineIndex multi-field -> false" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_a_b",
        .fields = &.{ "a", "b" },
        .descending = &.{},
    };
    try std.testing.expect(!isInlineIndex(idx, ""));
}

test "isInlineIndex name mismatch -> false" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_email",
        .fields = &.{"name"},
        .descending = &.{},
    };
    try std.testing.expect(!isInlineIndex(idx, ""));
}

test "isInlineIndex primary_key -> false" {
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

test "isAutoGeneratedName idx_field matches" {
    const idx = sp.SqlIndex{
        .kind = .regular,
        .name = "idx_name",
        .fields = &.{"name"},
        .descending = &.{},
    };
    try std.testing.expect(isAutoGeneratedName(idx));
}

test "isAutoGeneratedName uk_field matches" {
    const idx = sp.SqlIndex{
        .kind = .unique,
        .name = "uk_email",
        .fields = &.{"email"},
        .descending = &.{},
    };
    try std.testing.expect(isAutoGeneratedName(idx));
}

test "isAutoGeneratedName multi-field matches" {
    const idx = sp.SqlIndex{
        .kind = .regular,
        .name = "idx_a_b",
        .fields = &.{ "a", "b" },
        .descending = &.{},
    };
    try std.testing.expect(isAutoGeneratedName(idx));
}

test "isAutoGeneratedName custom name -> false" {
    const idx = sp.SqlIndex{
        .kind = .regular,
        .name = "my_index",
        .fields = &.{"name"},
        .descending = &.{},
    };
    try std.testing.expect(!isAutoGeneratedName(idx));
}

test "isAutoGeneratedName fulltext -> false" {
    const idx = sp.SqlIndex{
        .kind = .fulltext,
        .name = "ft_body",
        .fields = &.{"body"},
        .descending = &.{},
    };
    try std.testing.expect(!isAutoGeneratedName(idx));
}
