const std = @import("std");
const diff_mod = @import("diff.zig");
const dialect_enum = @import("dialect_enum.zig");
const utils = @import("utils.zig");
const SchemaDiff = diff_mod.SchemaDiff;
const TableDiff = diff_mod.TableDiff;
const Dialect = dialect_enum.Dialect;

const optionalStrEq = utils.optionalStrEq;

// ─── Diff Formatter ──────────────────────────────────────────
//
// Renders SchemaDiff as human-readable text for `typespec diff`.
// Separated from diff.zig to allow alternative output formats
// (JSON, machine-readable) without modifying the diff engine.

fn quoteChar(dialect: Dialect) u8 {
    return switch (dialect) {
        .mysql => '`',
        .pg, .sqlite => '"',
    };
}

/// Core diff formatting logic — writes to any std.io.Writer.
fn writeDiffTo(w: anytype, d: SchemaDiff, q: u8) !void {
    var has_changes = false;

    for (d.dropped_tables) |tname| {
        try w.print("-- DROP TABLE {c}{s}{c}\n", .{ q, tname, q });
        has_changes = true;
    }

    for (d.view_diffs) |vd| {
        switch (vd.action) {
            .create => {
                try w.print("-- CREATE VIEW {c}{s}{c}\n", .{ q, vd.name, q });
                has_changes = true;
            },
            .drop => {
                try w.print("-- DROP VIEW {c}{s}{c}\n", .{ q, vd.name, q });
                has_changes = true;
            },
            .modify => {
                try w.print("-- ALTER VIEW {c}{s}{c} (query changed)\n", .{ q, vd.name, q });
                has_changes = true;
            },
        }
    }

    for (d.table_diffs) |td| {
        if (td.action == .create) {
            try w.print("-- CREATE TABLE {c}{s}{c}\n", .{ q, td.name, q });
            has_changes = true;
            for (td.field_diffs) |fd| {
                try w.print("  + {s}\n", .{fd.name});
            }
            for (td.index_diffs) |idx| {
                try w.print("  + @{s}\n", .{idx.name});
            }
            for (td.fk_diffs) |fk| {
                if (fk.new_fk) |nfk| {
                    try w.print("  + FK → {s}\n", .{nfk.ref_table});
                }
            }
            continue;
        }

        // alter
        var table_has_changes = false;
        for (td.field_diffs) |fd| {
            if (!table_has_changes) {
                try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                table_has_changes = true;
            }
            switch (fd.action) {
                .add => try w.print("  + {s} (add)\n", .{fd.name}),
                .drop => try w.print("  - {s} (drop)\n", .{fd.name}),
                .modify => try w.print("  ~ {s} (modify)\n", .{fd.name}),
                .rename => try w.print("  ~ {s} → {s} (rename)\n", .{ fd.rename_from.?, fd.name }),
            }
        }
        // Metadata diffs (comment, engine)
        if (td.metadata_diff) |md| {
            if (!optionalStrEq(md.old_comment, md.new_comment)) {
                if (!table_has_changes) {
                    try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                    table_has_changes = true;
                }
                if (md.new_comment) |nc| {
                    try w.print("  ~ comment → '{s}'\n", .{nc});
                } else {
                    try w.print("  - comment (removed)\n", .{});
                }
            }
            if (!optionalStrEq(md.old_engine, md.new_engine)) {
                if (!table_has_changes) {
                    try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                    table_has_changes = true;
                }
                if (md.new_engine) |ne| {
                    try w.print("  ~ engine → '{s}'\n", .{ne});
                } else {
                    try w.print("  - engine (removed)\n", .{});
                }
            }
        }
        for (td.index_diffs) |idx| {
            if (!table_has_changes) {
                try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                table_has_changes = true;
            }
            switch (idx.action) {
                .add => try w.print("  + @{s} (add index)\n", .{idx.name}),
                .drop => try w.print("  - @{s} (drop index)\n", .{idx.name}),
                .modify => try w.print("  ~ @{s} (modify index)\n", .{idx.name}),
            }
        }
        for (td.fk_diffs) |fk| {
            if (!table_has_changes) {
                try w.print("-- ALTER TABLE {c}{s}{c}\n", .{ q, td.name, q });
                table_has_changes = true;
            }
            switch (fk.action) {
                .add => {
                    if (fk.new_fk) |nfk| {
                        try w.print("  + FK → {s} (add)\n", .{nfk.ref_table});
                    }
                },
                .drop => {
                    if (fk.old_fk) |ofk| {
                        try w.print("  - FK → {s} (drop)\n", .{ofk.ref_table});
                    }
                },
            }
        }
        if (table_has_changes) has_changes = true;
    }

    if (!has_changes) {
        // Empty output for no differences
    }
}

pub fn formatDiff(alloc: std.mem.Allocator, d: SchemaDiff, dialect: Dialect) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;
    const q = quoteChar(dialect);
    try writeDiffTo(w, d, q);
    try w.flush();
    var out = aw.toArrayList();
    return try out.toOwnedSlice(alloc);
}

pub fn printDiff(d: SchemaDiff, dialect: Dialect) void {
    const text = formatDiff(std.heap.page_allocator, d, dialect) catch return;
    std.debug.print("{s}", .{text});
}
