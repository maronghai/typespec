const std = @import("std");
const tk = @import("tokenizer.zig");
const diag = @import("../semantic/diagnostic.zig");
const ast_mod = @import("../types/ast.zig");
const SourceLocation = ast_mod.SourceLocation;

// ─── Parse Recovery: error handling + sync point detection ────
//
// Extracted from parser.zig in v0.4.74 Phase 1.
// Provides error recording and error-recovery sync point detection
// for the forward parser. The parser calls findNextSyncPoint after
// recording an error to skip damaged tokens and continue parsing.

/// Classification of sync points used by error-recovery.
/// The parser skips forward until it reaches one of these, then
/// resumes normal parsing from that point.
pub const SyncPoint = enum {
    /// Top-level block boundary: schema, template, table, view, engine, sql_comment.
    block_start,
    /// End of file — nothing more to parse.
    eof,
};

/// Record a parse error via DiagnosticCollector.
/// Returns true if error was recorded (caller should continue),
/// false to propagate the error to the caller.
pub fn handleParseError(
    diagnostics: ?*diag.DiagnosticCollector,
    err: anyerror,
    line: tk.Line,
    comptime message: []const u8,
) bool {
    if (diagnostics) |dc| {
        dc.record(.{
            .severity = .@"error",
            .line_no = line.line_no,
            .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
            .message = message,
            .actual = @errorName(err),
            .source_line = line.raw,
        });
        return true;
    }
    return false;
}

/// Compute SourceLocation from a tokenized line and a token within it.
pub fn locFromLine(line: tk.Line, tok: []const u8) SourceLocation {
    const col = diag.tokenColumn(tok, line.raw);
    return .{
        .line = line.line_no,
        .col = col,
        .offset = line.offset + col - 1,
    };
}

/// Find the next sync point in the token stream starting from `start_idx`.
/// Returns the index of the line where parsing should resume, and the type
/// of sync point found.
///
/// Sync point detection rules (in priority order):
///   1. Schema, Template, Table, View, Engine, SQLComment lines — a new
///      top-level block always starts a fresh parse context.
///   2. EOF — end of input.
///
/// Field, FK, Index, CompositePK, Slot lines inside a block are NOT sync
/// points — they require a valid enclosing block and would be meaningless
/// without one.
pub fn findNextSyncPoint(lines: []const tk.Line, start_idx: usize) struct { index: usize, point: SyncPoint } {
    var i = start_idx;
    while (i < lines.len) : (i += 1) {
        switch (lines[i].line_type) {
            .Schema, .Template, .Table, .View, .Engine, .SQLComment => {
                return .{ .index = i, .point = .block_start };
            },
            else => {},
        }
    }
    return .{ .index = lines.len, .point = .eof };
}

// ─── Unit Tests ──────────────────────────────────────────────

test "findNextSyncPoint: finds next block start" {
    const lines = [_]tk.Line{
        .{ .line_type = .Field, .tokens = &.{"x"}, .raw = "x n", .trimmed = "x n", .line_no = 1, .offset = 0 },
        .{ .line_type = .Field, .tokens = &.{"y"}, .raw = "y s", .trimmed = "y s", .line_no = 2, .offset = 0 },
        .{ .line_type = .Table, .tokens = &.{ ".", "users" }, .raw = ".users", .trimmed = ".users", .line_no = 3, .offset = 0 },
        .{ .line_type = .Field, .tokens = &.{"z"}, .raw = "z n", .trimmed = "z n", .line_no = 4, .offset = 0 },
    };
    const result = findNextSyncPoint(&lines, 0);
    try std.testing.expectEqual(@as(usize, 2), result.index);
    try std.testing.expectEqual(SyncPoint.block_start, result.point);
}

test "findNextSyncPoint: returns EOF when no block start found" {
    const lines = [_]tk.Line{
        .{ .line_type = .Field, .tokens = &.{"x"}, .raw = "x n", .trimmed = "x n", .line_no = 1, .offset = 0 },
        .{ .line_type = .Slot, .tokens = &.{"..."}, .raw = "...", .trimmed = "...", .line_no = 2, .offset = 0 },
    };
    const result = findNextSyncPoint(&lines, 0);
    try std.testing.expectEqual(@as(usize, 2), result.index);
    try std.testing.expectEqual(SyncPoint.eof, result.point);
}

test "findNextSyncPoint: skips Empty and SpecComment" {
    const lines = [_]tk.Line{
        .{ .line_type = .Empty, .tokens = &.{}, .raw = "", .trimmed = "", .line_no = 1, .offset = 0 },
        .{ .line_type = .SpecComment, .tokens = &.{"#"}, .raw = "# comment", .trimmed = "# comment", .line_no = 2, .offset = 0 },
        .{ .line_type = .View, .tokens = &.{ ".", "v1" }, .raw = ".v1", .trimmed = ".v1", .line_no = 3, .offset = 0 },
    };
    const result = findNextSyncPoint(&lines, 0);
    try std.testing.expectEqual(@as(usize, 2), result.index);
    try std.testing.expectEqual(SyncPoint.block_start, result.point);
}
