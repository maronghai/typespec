const std = @import("std");
const sp = @import("sql_parser.zig");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const dialect_mod = @import("dialect.zig");
const reverse_check = @import("reverse_check.zig");
const Dialect = sp.Dialect;

// ─── Column Reverse Output ─────────────────────────────────────
// Extracted from reverse_codegen.zig for single-responsibility.
// Handles writing TPS column definitions from SQL column metadata.

pub const TypeResult = struct {
    tps: []const u8,
    omit: bool,
    confidence: type_map.Confidence = .high,
};

pub fn reverseType(sql_type: []const u8, col_name: []const u8, is_auto_inc: bool, is_default_ts: bool, dialect: Dialect) TypeResult {
    const r = type_map.reverseLookup(sql_type, col_name, is_auto_inc, is_default_ts, dialect);
    return .{ .tps = r.tps, .omit = r.omit, .confidence = r.confidence };
}

pub fn isDatetime(sql_type: []const u8) bool {
    return type_map.isDatetimeSqlType(sql_type);
}

pub fn isCurrentTimestamp(dv: []const u8) bool {
    return type_map.isCurrentTimestamp(dv);
}

pub fn reverseCheck(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?[]const u8 {
    return reverse_check.reverseCheck(alloc, sql_expr, col_name);
}

pub fn parseSqlCheckExpr(alloc: std.mem.Allocator, sql_expr: []const u8, col_name: []const u8) ?ast_mod.CheckConstraint {
    return reverse_check.parseSqlCheckExpr(alloc, sql_expr, col_name);
}

/// Write TPS column suffix: type + modifiers + default + check + comment
pub fn writeColumnSuffix(w: anytype, col: sp.SqlColumn, indexes: []const sp.SqlIndex, check_expr: ?[]const u8, dialect: Dialect) !void {
    const tr = try writeColumnType(w, col, dialect);
    try writeColumnModifiers(w, col, indexes, tr);
    try writeColumnDefault(w, col, tr);
    try writeColumnCheck(w, check_expr);
    try writeColumnComment(w, col);
    try writeColumnConfidence(w, col, tr, dialect);
}

/// Resolve and write the TPS type symbol. Returns TypeResult for downstream use.
fn writeColumnType(w: anytype, col: sp.SqlColumn, dialect: Dialect) !TypeResult {
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
    return tr;
}

/// Write modifier suffixes: ++ / + / ! / * / u / @u / @
fn writeColumnModifiers(w: anytype, col: sp.SqlColumn, indexes: []const sp.SqlIndex, tr: TypeResult) !void {
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
    for (indexes) |idx| {
        if (idx.fields.len == 1 and std.mem.eql(u8, idx.fields[0], col.name)) {
            if (idx.kind == .unique and idx.name.len > 3 and std.mem.startsWith(u8, idx.name, "uk_")) {
                try w.writeAll(" @u");
            } else if (idx.kind == .regular and idx.name.len > 4 and std.mem.startsWith(u8, idx.name, "idx_")) {
                try w.writeAll(" @");
            }
        }
    }
}

/// Write DEFAULT value.
fn writeColumnDefault(w: anytype, col: sp.SqlColumn, tr: TypeResult) !void {
    if (col.default_val) |dv| {
        if ((isDatetime(col.type_sql) or std.mem.eql(u8, tr.tps, "t")) and isCurrentTimestamp(dv)) {
            // already emitted + or ++ above — skip
        } else if (std.mem.eql(u8, dv, "")) {
            // Empty string default — skip
        } else if (std.mem.eql(u8, dv, "NULL")) {
            // DEFAULT NULL — skip (implicit)
        } else if (std.mem.startsWith(u8, dv, "b'") and std.mem.endsWith(u8, dv, "'")) {
            // MySQL binary literal b'0' / b'1' → strip to plain 0/1
            try w.writeAll(" =");
            try w.writeAll(dv[2 .. dv.len - 1]);
        } else if (std.mem.eql(u8, dv, "gen_random_uuid()")) {
            // PG: uuid auto-gen default — skip
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

/// Write confidence comment (dialect-specific, only when not high).
fn writeColumnConfidence(w: anytype, col: sp.SqlColumn, tr: TypeResult, dialect: Dialect) !void {
    if (tr.confidence != .high) {
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
