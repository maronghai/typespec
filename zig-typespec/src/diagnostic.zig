const std = @import("std");

pub const Severity = enum {
    warning,
    @"error",
    note,
};

pub const Diagnostic = struct {
    severity: Severity,
    line_no: usize,
    col: ?usize = null,
    file: []const u8 = "input.tps",
    message: []const u8,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    source_line: ?[]const u8 = null,
};

/// Compute 1-based column of `tok` within `raw_line`.
/// Since tokens are sub-slices of the trimmed line (separate allocation from raw_line),
/// we use safe string slicing instead of pointer arithmetic.
pub fn tokenColumn(tok: []const u8, raw_line: []const u8) usize {
    if (raw_line.len == 0 or tok.len == 0) return 1;
    // Find where trimmed content starts (skip leading spaces/tabs)
    var trim_start: usize = 0;
    while (trim_start < raw_line.len and (raw_line[trim_start] == ' ' or raw_line[trim_start] == '\t')) {
        trim_start += 1;
    }
    // The trimmed portion is a separate allocation whose tokens include `tok`.
    // Search for tok within the trimmed portion of raw_line.
    const trimmed_part = raw_line[trim_start..];
    if (std.mem.indexOf(u8, trimmed_part, tok)) |pos| {
        return trim_start + pos + 1;
    }
    return 1;
}

pub fn printDiagnostic(d: Diagnostic) void {
    const sev_str: []const u8 = switch (d.severity) {
        .warning => "warning",
        .@"error" => "error",
        .note => "note",
    };

    // Header: "warning: message — expected '...', got '...'"
    if (d.expected) |exp| {
        if (d.actual) |act| {
            std.debug.print("{s}: {s} — expected {s}, got '{s}'\n", .{ sev_str, d.message, exp, act });
        } else {
            std.debug.print("{s}: {s} — expected {s}\n", .{ sev_str, d.message, exp });
        }
    } else if (d.actual) |act| {
        std.debug.print("{s}: {s}, got '{s}'\n", .{ sev_str, d.message, act });
    } else {
        std.debug.print("{s}: {s}\n", .{ sev_str, d.message });
    }

    // Location: "  --> file:line:col"
    if (d.col) |col| {
        std.debug.print("  --> {s}:{d}:{d}\n", .{ d.file, d.line_no, col });
    } else {
        std.debug.print("  --> {s}:{d}\n", .{ d.file, d.line_no });
    }

    // Source context with caret pointer
    if (d.source_line) |raw| {
        std.debug.print("   |\n", .{});
        std.debug.print(" {d} | {s}\n", .{ d.line_no, raw });
        if (d.col) |col| {
            // Print spaces for indentation + column offset, then carets
            const indent = digitCount(d.line_no) + 3; // " N | " prefix width
            var j: usize = 0;
            while (j < indent + col - 1) : (j += 1) {
                std.debug.print(" ", .{});
            }
            // Determine underline width: use the actual token length if it's
            // a real token (not a descriptive phrase like "end of line")
            const width: usize = if (d.actual) |a| blk: {
                // If actual contains spaces or is longer than a typical token,
                // it's a description, not a token — use single caret
                if (std.mem.indexOfScalar(u8, a, ' ') != null or a.len > 20) break :blk 1;
                break :blk a.len;
            } else 1;
            var k: usize = 0;
            while (k < width) : (k += 1) {
                std.debug.print("^", .{});
            }
            std.debug.print("\n", .{});
        }
    }
}

fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

// ─── Diagnostic Collector (Phase 4: Error Recovery) ──────────

/// Collects diagnostics during compilation, allowing continued parsing after errors.
pub const DiagnosticCollector = struct {
    diagnostics: std.ArrayList(Diagnostic),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) DiagnosticCollector {
        return .{
            .diagnostics = std.ArrayList(Diagnostic).init(alloc),
            .alloc = alloc,
        };
    }

    /// Record a diagnostic (warning, error, or note).
    pub fn push(self: *DiagnosticCollector, d: Diagnostic) void {
        self.diagnostics.append(d) catch {};
    }

    /// Record a diagnostic using the existing printDiagnostic + store pattern.
    pub fn record(self: *DiagnosticCollector, d: Diagnostic) void {
        printDiagnostic(d);
        self.push(d);
    }

    /// Returns true if any error-severity diagnostics have been recorded.
    pub fn hasErrors(self: *const DiagnosticCollector) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    /// Returns the count of error-severity diagnostics.
    pub fn errorCount(self: *const DiagnosticCollector) usize {
        var count: usize = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") count += 1;
        }
        return count;
    }

    /// Print all collected diagnostics.
    pub fn printAll(self: *const DiagnosticCollector) void {
        for (self.diagnostics.items) |d| {
            printDiagnostic(d);
        }
    }

    /// Print a summary line after all diagnostics.
    pub fn printSummary(self: *const DiagnosticCollector) void {
        const errs = self.errorCount();
        const warns: usize = blk: {
            var w: usize = 0;
            for (self.diagnostics.items) |d| {
                if (d.severity == .warning) w += 1;
            }
            break :blk w;
        };
        if (errs > 0 or warns > 0) {
            std.debug.print("\n{d} error(s), {d} warning(s)\n", .{ errs, warns });
        }
    }
};
