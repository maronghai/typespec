const std = @import("std");
const sem = @import("semantic.zig");
const ast_mod = @import("ast.zig");
const type_map = @import("type_map.zig");
const Writer = std.Io.Writer;
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const IndexDecl = ast_mod.IndexDecl;
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const CheckConstraint = ast_mod.CheckConstraint;
const Dialect = type_map.Dialect;

// ─── DialectBackend: vtable for dialect-specific SQL generation ─
//
// Adding a new dialect requires only:
//   1. Add a new enum variant to Dialect (in type_map.zig)
//   2. Create a new DialectBackend instance below
//   3. Register it in the getBackend() switch
//
// No changes needed in Codegen struct methods.

pub const DialectBackend = struct {
    quoteIdent: *const fn (w: *Writer, name: []const u8) anyerror!void,
    emitIndex: *const fn (w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void,
    emitFooter: *const fn (w: *Writer, table: sem.ResolvedTable, charset: ?[]const u8) anyerror!void,
    emitComments: *const fn (w: *Writer, table: sem.ResolvedTable) anyerror!void,
    emitStandaloneIndexes: *const fn (w: *Writer, table: sem.ResolvedTable) anyerror!void,
    emitFieldSuffix: *const fn (w: *Writer, field: Field, has_auto_inc: bool, has_pk: bool, is_datetime: bool) anyerror!void,
    emitFieldComment: *const fn (w: *Writer, comment: ?[]const u8) anyerror!void,
    emitInlineIndexes: *const fn (w: *Writer, table: sem.ResolvedTable, needs_comma: *bool) anyerror!void,
    emitCreateDatabase: *const fn (w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void,
    emitUnsigned: *const fn (w: *Writer) anyerror!void,
    emitTimestampModifier: *const fn (w: *Writer, with_on_update: bool) anyerror!void,
};

pub fn getBackend(dialect: Dialect) DialectBackend {
    return switch (dialect) {
        .mysql => mysql_backend,
        .postgres => pg_backend,
        .sqlite => sqlite_backend,
    };
}

// ─── MySQL Backend ─────────────────────────────────────────────

fn mysqlQuoteIdent(w: *Writer, name: []const u8) anyerror!void {
    try w.print("`{s}`", .{name});
}

fn mysqlEmitIndex(w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void {
    if (needs_comma.*) try w.writeAll(",\n");
    needs_comma.* = true;
    try w.writeAll("  ");
    switch (idx.kind) {
        .regular => try w.writeAll("INDEX"),
        .unique => try w.writeAll("UNIQUE INDEX"),
        .fulltext => try w.writeAll("FULLTEXT INDEX"),
        .primary_key => try w.writeAll("PRIMARY KEY"),
    }
    if (idx.kind == .primary_key) {
        try w.writeAll(" (");
    } else {
        try w.print(" `{s}` (", .{idx.name});
    }
    for (idx.fields, 0..) |f, fi| {
        if (fi > 0) try w.writeAll(", ");
        try w.print("`{s}`", .{f});
    }
    try w.writeAll(")");
}

fn mysqlEmitFooter(w: *Writer, table: sem.ResolvedTable, schema_charset: ?[]const u8) anyerror!void {
    const charset = schema_charset orelse "utf8mb4";
    const engine = table.engine orelse "InnoDB";
    if (table.comment) |c| {
        const comment_text = if (c.len >= 1 and c[0] == ':') c[1..] else c;
        const trimmed = std.mem.trim(u8, comment_text, " ");
        try w.print(") ENGINE={s} DEFAULT CHARSET={s} COMMENT='{s}';\n", .{ engine, charset, trimmed });
    } else {
        try w.print(") ENGINE={s} DEFAULT CHARSET={s};\n", .{ engine, charset });
    }
}

fn mysqlEmitComments(_: *Writer, _: sem.ResolvedTable) anyerror!void {
    // MySQL uses inline COMMENT, not standalone COMMENT ON
}

fn mysqlEmitStandaloneIndexes(_: *Writer, _: sem.ResolvedTable) anyerror!void {
    // MySQL uses inline indexes
}

fn mysqlEmitFieldSuffix(w: *Writer, field: Field, has_auto_inc: bool, has_pk: bool, _: bool) anyerror!void {
    if (has_auto_inc) try w.writeAll(" AUTO_INCREMENT");
    if (has_pk) try w.writeAll(" PRIMARY KEY");
    if (field.check) |ck| {
        try w.writeAll(" CHECK (");
        try emitCheckExpr(w, field.name, ck);
        try w.writeAll(")");
    }
}

fn mysqlEmitFieldComment(w: *Writer, comment: ?[]const u8) anyerror!void {
    if (comment) |c| {
        if (c.len >= 1 and c[0] == ':') {
            try w.print(" COMMENT '{s}'", .{std.mem.trim(u8, c[1..], " ")});
        } else if (c.len >= 2 and c[0] == '-' and c[1] == '-') {
            try w.writeAll(" ");
            try w.writeAll(c);
        }
    }
}

fn mysqlEmitInlineIndexes(w: *Writer, table: sem.ResolvedTable, needs_comma: *bool) anyerror!void {
    for (table.fields) |field| {
        var has_inline_unique = false;
        for (field.modifiers) |mod| {
            if (mod.kind == .inline_unique) {
                has_inline_unique = true;
                break;
            }
        }
        if (has_inline_unique) {
            var dominated = false;
            for (table.indexes) |idx| {
                if (idx.kind == .unique or idx.kind == .primary_key) {
                    for (idx.fields) |f| {
                        if (std.mem.eql(u8, f, field.name)) {
                            dominated = true;
                            break;
                        }
                    }
                }
                if (dominated) break;
            }
            if (!dominated) {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.print("  UNIQUE INDEX `uk_{s}` (`{s}`)", .{ field.name, field.name });
            }
        }
        var has_inline_index = false;
        for (field.modifiers) |mod| {
            if (mod.kind == .inline_index) {
                has_inline_index = true;
                break;
            }
        }
        if (has_inline_index) {
            var dominated = false;
            for (table.indexes) |idx| {
                for (idx.fields) |f| {
                    if (std.mem.eql(u8, f, field.name)) {
                        dominated = true;
                        break;
                    }
                }
                if (dominated) break;
            }
            if (!dominated) {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.print("  INDEX `idx_{s}` (`{s}`)", .{ field.name, field.name });
            }
        }
    }
}

fn mysqlEmitCreateDatabase(w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void {
    if (charset) |cs| {
        try w.print("CREATE DATABASE `{s}` CHARACTER SET {s};\n\n", .{ name, cs });
    } else {
        try w.print("CREATE DATABASE `{s}`;\n\n", .{name});
    }
}

fn mysqlEmitUnsigned(w: *Writer) anyerror!void {
    try w.writeAll(" UNSIGNED");
}

fn mysqlEmitTimestampModifier(w: *Writer, with_on_update: bool) anyerror!void {
    try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
    if (with_on_update) {
        try w.writeAll(" ON UPDATE CURRENT_TIMESTAMP");
    }
}

const mysql_backend = DialectBackend{
    .quoteIdent = mysqlQuoteIdent,
    .emitIndex = mysqlEmitIndex,
    .emitFooter = mysqlEmitFooter,
    .emitComments = mysqlEmitComments,
    .emitStandaloneIndexes = mysqlEmitStandaloneIndexes,
    .emitFieldSuffix = mysqlEmitFieldSuffix,
    .emitFieldComment = mysqlEmitFieldComment,
    .emitInlineIndexes = mysqlEmitInlineIndexes,
    .emitCreateDatabase = mysqlEmitCreateDatabase,
    .emitUnsigned = mysqlEmitUnsigned,
    .emitTimestampModifier = mysqlEmitTimestampModifier,
};

// ─── PostgreSQL Backend ────────────────────────────────────────

fn pgQuoteIdent(w: *Writer, name: []const u8) anyerror!void {
    try w.print("\"{s}\"", .{name});
}

fn pgEmitIndex(w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void {
    switch (idx.kind) {
        .regular => return,
        .fulltext => return,
        .unique => {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  UNIQUE (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(")");
        },
        .primary_key => {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  PRIMARY KEY (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(")");
        },
    }
}

fn pgEmitFooter(w: *Writer, _: sem.ResolvedTable, _: ?[]const u8) anyerror!void {
    try w.writeAll(");\n");
}

fn pgEmitComments(w: *Writer, table: sem.ResolvedTable) anyerror!void {
    if (table.comment) |c| {
        const comment_text = if (c.len >= 1 and c[0] == ':') c[1..] else c;
        const trimmed = std.mem.trim(u8, comment_text, " ");
        if (trimmed.len > 0) {
            try w.print("COMMENT ON TABLE \"{s}\" IS '{s}';\n", .{ table.name, trimmed });
        }
    }
    for (table.fields) |field| {
        if (std.mem.eql(u8, field.name, "...")) continue;
        if (field.comment) |c| {
            if (c.len >= 1 and c[0] == ':') {
                const trimmed = std.mem.trim(u8, c[1..], " ");
                if (trimmed.len > 0) {
                    try w.print("COMMENT ON COLUMN \"{s}\".\"{s}\" IS '{s}';\n", .{ table.name, field.name, trimmed });
                }
            }
        }
    }
}

fn pgEmitStandaloneIndexes(w: *Writer, table: sem.ResolvedTable) anyerror!void {
    for (table.indexes) |idx| {
        if (idx.kind == .primary_key) continue;
        if (idx.kind == .unique) continue;
        if (idx.kind == .fulltext) continue;
        try w.writeAll("CREATE INDEX ");
        if (idx.name.len > 0) {
            try w.print("\"{s}\"", .{idx.name});
        } else {
            try w.print("\"idx_{s}_{s}\"", .{ table.name, idx.fields[0] });
        }
        try w.print(" ON \"{s}\" (", .{table.name});
        for (idx.fields, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{f});
        }
        try w.writeAll(");\n");
    }
}

fn pgEmitFieldSuffix(w: *Writer, field: Field, has_auto_inc: bool, has_pk: bool, is_datetime: bool) anyerror!void {
    if (has_auto_inc) {
        if (!is_datetime) {
            try w.writeAll(" GENERATED ALWAYS AS IDENTITY");
        }
    }
    if (has_pk) try w.writeAll(" PRIMARY KEY");
    if (field.check) |ck| {
        try w.writeAll(" CHECK (");
        try emitCheckExpr(w, field.name, ck);
        try w.writeAll(")");
    }
}

fn pgEmitFieldComment(_: *Writer, _: ?[]const u8) anyerror!void {
    // PG uses COMMENT ON after table
}

fn pgEmitInlineIndexes(w: *Writer, table: sem.ResolvedTable, needs_comma: *bool) anyerror!void {
    for (table.fields) |field| {
        var has_inline_unique = false;
        for (field.modifiers) |mod| {
            if (mod.kind == .inline_unique) {
                has_inline_unique = true;
                break;
            }
        }
        if (has_inline_unique) {
            var dominated = false;
            for (table.indexes) |idx| {
                if (idx.kind == .unique or idx.kind == .primary_key) {
                    for (idx.fields) |f| {
                        if (std.mem.eql(u8, f, field.name)) {
                            dominated = true;
                            break;
                        }
                    }
                }
                if (dominated) break;
            }
            if (!dominated) {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.print("  UNIQUE (\"{s}\")", .{field.name});
            }
        }
        // PG: inline INDEX not supported
    }
}

fn pgEmitCreateDatabase(w: *Writer, name: []const u8, charset: ?[]const u8) anyerror!void {
    if (charset != null) {
        try w.print("CREATE DATABASE \"{s}\" ENCODING 'UTF8';\n\n", .{name});
    } else {
        try w.print("CREATE DATABASE \"{s}\";\n\n", .{name});
    }
}

fn pgEmitUnsigned(_: *Writer) anyerror!void {
    // PG has no UNSIGNED
}

fn pgEmitTimestampModifier(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
}

const pg_backend = DialectBackend{
    .quoteIdent = pgQuoteIdent,
    .emitIndex = pgEmitIndex,
    .emitFooter = pgEmitFooter,
    .emitComments = pgEmitComments,
    .emitStandaloneIndexes = pgEmitStandaloneIndexes,
    .emitFieldSuffix = pgEmitFieldSuffix,
    .emitFieldComment = pgEmitFieldComment,
    .emitInlineIndexes = pgEmitInlineIndexes,
    .emitCreateDatabase = pgEmitCreateDatabase,
    .emitUnsigned = pgEmitUnsigned,
    .emitTimestampModifier = pgEmitTimestampModifier,
};

// ─── SQLite Backend ────────────────────────────────────────────

fn sqliteQuoteIdent(w: *Writer, name: []const u8) anyerror!void {
    try w.print("\"{s}\"", .{name});
}

fn sqliteEmitIndex(w: *Writer, idx: IndexDecl, needs_comma: *bool) anyerror!void {
    switch (idx.kind) {
        .regular => return,
        .fulltext => return,
        .unique => {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  UNIQUE (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(")");
        },
        .primary_key => {
            if (needs_comma.*) try w.writeAll(",\n");
            needs_comma.* = true;
            try w.writeAll("  PRIMARY KEY (");
            for (idx.fields, 0..) |f, fi| {
                if (fi > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{f});
            }
            try w.writeAll(")");
        },
    }
}

fn sqliteEmitFooter(w: *Writer, _: sem.ResolvedTable, _: ?[]const u8) anyerror!void {
    try w.writeAll(");\n");
}

fn sqliteEmitComments(w: *Writer, table: sem.ResolvedTable) anyerror!void {
    if (table.comment) |c| {
        const comment_text = if (c.len >= 1 and c[0] == ':') c[1..] else c;
        const trimmed = std.mem.trim(u8, comment_text, " ");
        if (trimmed.len > 0) {
            try w.print("-- {s}\n", .{trimmed});
        }
    }
    for (table.fields) |field| {
        if (std.mem.eql(u8, field.name, "...")) continue;
        if (field.comment) |c| {
            if (c.len >= 1 and c[0] == ':') {
                const trimmed = std.mem.trim(u8, c[1..], " ");
                if (trimmed.len > 0) {
                    try w.print("-- {s}.{s}: {s}\n", .{ table.name, field.name, trimmed });
                }
            }
        }
    }
}

fn sqliteEmitStandaloneIndexes(w: *Writer, table: sem.ResolvedTable) anyerror!void {
    for (table.indexes) |idx| {
        if (idx.kind == .primary_key) continue;
        if (idx.kind == .unique) continue;
        if (idx.kind == .fulltext) continue;
        try w.writeAll("CREATE INDEX ");
        if (idx.name.len > 0) {
            try w.print("\"{s}\"", .{idx.name});
        } else {
            try w.print("\"idx_{s}_{s}\"", .{ table.name, idx.fields[0] });
        }
        try w.print(" ON \"{s}\" (", .{table.name});
        for (idx.fields, 0..) |f, fi| {
            if (fi > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{f});
        }
        try w.writeAll(");\n");
    }
}

fn sqliteEmitFieldSuffix(w: *Writer, field: Field, has_auto_inc: bool, has_pk: bool, _: bool) anyerror!void {
    if (has_auto_inc and has_pk) {
        try w.writeAll(" PRIMARY KEY AUTOINCREMENT");
    } else if (has_pk) {
        try w.writeAll(" PRIMARY KEY");
    }
    if (field.check) |ck| {
        try w.writeAll(" CHECK (");
        try emitCheckExpr(w, field.name, ck);
        try w.writeAll(")");
    }
}

fn sqliteEmitFieldComment(w: *Writer, comment: ?[]const u8) anyerror!void {
    // SQLite uses SQL line comments — emitted separately after CREATE TABLE
    if (comment) |c| {
        if (c.len >= 2 and c[0] == '-' and c[1] == '-') {
            try w.writeAll(" ");
            try w.writeAll(c);
        }
    }
}

fn sqliteEmitInlineIndexes(w: *Writer, table: sem.ResolvedTable, needs_comma: *bool) anyerror!void {
    for (table.fields) |field| {
        var has_inline_unique = false;
        for (field.modifiers) |mod| {
            if (mod.kind == .inline_unique) {
                has_inline_unique = true;
                break;
            }
        }
        if (has_inline_unique) {
            var dominated = false;
            for (table.indexes) |idx| {
                if (idx.kind == .unique or idx.kind == .primary_key) {
                    for (idx.fields) |f| {
                        if (std.mem.eql(u8, f, field.name)) {
                            dominated = true;
                            break;
                        }
                    }
                }
                if (dominated) break;
            }
            if (!dominated) {
                if (needs_comma.*) try w.writeAll(",\n");
                needs_comma.* = true;
                try w.print("  UNIQUE (\"{s}\")", .{field.name});
            }
        }
        // SQLite: inline INDEX not supported
    }
}

fn sqliteEmitCreateDatabase(_: *Writer, _: []const u8, _: ?[]const u8) anyerror!void {
    // SQLite has no CREATE DATABASE (file-based)
}

fn sqliteEmitUnsigned(_: *Writer) anyerror!void {
    // SQLite has no UNSIGNED
}

fn sqliteEmitTimestampModifier(w: *Writer, _: bool) anyerror!void {
    try w.writeAll(" DEFAULT CURRENT_TIMESTAMP");
}

const sqlite_backend = DialectBackend{
    .quoteIdent = sqliteQuoteIdent,
    .emitIndex = sqliteEmitIndex,
    .emitFooter = sqliteEmitFooter,
    .emitComments = sqliteEmitComments,
    .emitStandaloneIndexes = sqliteEmitStandaloneIndexes,
    .emitFieldSuffix = sqliteEmitFieldSuffix,
    .emitFieldComment = sqliteEmitFieldComment,
    .emitInlineIndexes = sqliteEmitInlineIndexes,
    .emitCreateDatabase = sqliteEmitCreateDatabase,
    .emitUnsigned = sqliteEmitUnsigned,
    .emitTimestampModifier = sqliteEmitTimestampModifier,
};

// ─── Shared helpers (dialect-independent) ──────────────────────

pub fn emitCheckExpr(w: *Writer, field_name: []const u8, ck: CheckConstraint) !void {
    switch (ck.kind) {
        .range => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} BETWEEN {s} AND {s}", .{ field_name, low, high });
        },
        .range_upper_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} >= {s} AND {s} < {s}", .{ field_name, low, field_name, high });
        },
        .range_lower_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} > {s} AND {s} <= {s}", .{ field_name, low, field_name, high });
        },
        .range_both_exclusive => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            const low = std.mem.trim(u8, parts.next() orelse "", " ");
            const high = std.mem.trim(u8, parts.next() orelse "", " ");
            try w.print("{s} > {s} AND {s} < {s}", .{ field_name, low, field_name, high });
        },
        .in_list => {
            try w.print("{s} IN (", .{field_name});
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            var first = true;
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try w.writeAll(", ");
                first = false;
                const is_num = blk: {
                    _ = std.fmt.parseFloat(f64, trimmed) catch break :blk false;
                    break :blk true;
                };
                if (is_num) {
                    try w.print("{s}", .{trimmed});
                } else {
                    const val = if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')
                        trimmed[1 .. trimmed.len - 1]
                    else
                        trimmed;
                    try w.print("'{s}'", .{val});
                }
            }
            try w.writeAll(")");
        },
        .comparison => {
            var parts = std.mem.splitScalar(u8, ck.expr, ',');
            var first = true;
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try w.writeAll(" AND ");
                first = false;
                if (trimmed[0] == '>' and trimmed.len > 1 and trimmed[1] == '=') {
                    try w.print("{s} >= {s}", .{ field_name, trimmed[2..] });
                } else if (trimmed[0] == '<' and trimmed.len > 1 and trimmed[1] == '=') {
                    try w.print("{s} <= {s}", .{ field_name, trimmed[2..] });
                } else if (trimmed[0] == '>') {
                    try w.print("{s} > {s}", .{ field_name, trimmed[1..] });
                } else if (trimmed[0] == '<') {
                    try w.print("{s} < {s}", .{ field_name, trimmed[1..] });
                } else if (trimmed[0] == '=') {
                    try w.print("{s} = {s}", .{ field_name, trimmed[1..] });
                } else {
                    try w.print("{s} = {s}", .{ field_name, trimmed });
                }
            }
        },
    }
}
