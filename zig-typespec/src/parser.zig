const std = @import("std");
const tk = @import("tokenizer.zig");
const diag = @import("diagnostic.zig");
const ast_mod = @import("ast.zig");
const parse_fk = @import("parse_fk.zig");
const parse_index = @import("parse_index.zig");
const parse_check = @import("parse_check.zig");
const parse_field = @import("parse_field.zig");
const parse_typedef = @import("parse_typedef.zig");
const parse_template = @import("parse_template.zig");
const parse_table = @import("parse_table.zig");
const parse_trace = @import("parse_trace.zig");
const parse_recovery = @import("parse_recovery.zig");
const Ast = ast_mod.Ast;
const Table = ast_mod.Table;
const Field = ast_mod.Field;
const Template = ast_mod.Template;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const ModifierType = ast_mod.ModifierType;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;
const CheckKind = ast_mod.CheckKind;
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const FkActionType = ast_mod.FkActionType;
const IndexDecl = ast_mod.IndexDecl;
const IndexType = ast_mod.IndexType;
const Schema = ast_mod.Schema;
const SqlComment = ast_mod.SqlComment;
const SourceLocation = ast_mod.SourceLocation;

// ─── Parser ──────────────────────────────────────────────────

pub const Parser = struct {
    alloc: std.mem.Allocator,
    diagnostics: ?*diag.DiagnosticCollector,

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{ .alloc = alloc, .diagnostics = null };
    }

    pub fn initWithDiagnostics(alloc: std.mem.Allocator, diagnostics: *diag.DiagnosticCollector) Parser {
        return .{ .alloc = alloc, .diagnostics = diagnostics };
    }

    /// Record a parse error via DiagnosticCollector, or signal caller to propagate.
    /// Returns true if error was recorded (caller should continue), false to propagate.
    fn handleParseError(self: *Parser, err: anyerror, line: tk.Line, comptime message: []const u8) bool {
        return parse_recovery.handleParseError(self.diagnostics, err, line, message);
    }

    /// Compute SourceLocation from a tokenized line and a token within it.
    fn locFromLine(line: tk.Line, tok: []const u8) SourceLocation {
        return parse_recovery.locFromLine(line, tok);
    }

    pub fn parse(self: *Parser, lines: []const tk.Line) !Ast {
        var schema: ?Schema = null;
        var templates = try std.ArrayList(Template).initCapacity(self.alloc, 8);
        var tables = try std.ArrayList(Table).initCapacity(self.alloc, 8);
        var views = try std.ArrayList(ast_mod.View).initCapacity(self.alloc, 8);
        var sql_comments = try std.ArrayList(SqlComment).initCapacity(self.alloc, 8);
        var custom_types = try std.ArrayList(ast_mod.CustomType).initCapacity(self.alloc, 8);

        // Current block being parsed (template or table)
        var cur_name: ?[]const u8 = null;
        var cur_comment: ?[]const u8 = null;
        var cur_template_ref: ?[]const u8 = null;
        var cur_parents_buf = try self.alloc.alloc([]const u8, 4);
        var cur_parents_len: usize = 0;
        var cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
        var cur_fks = try std.ArrayList(FkDecl).initCapacity(self.alloc, 4);
        var cur_indexes = try std.ArrayList(IndexDecl).initCapacity(self.alloc, 4);
        var cur_line_no: usize = 0;
        var cur_loc: ?SourceLocation = null;
        var cur_engine: ?[]const u8 = null;
        var in_block: enum { none, template, table } = .none;

        for (lines) |line| {
            switch (line.line_type) {
                .Empty, .SpecComment => {},
                .Schema => {
                    if (line.tokens.len >= 2) {
                        var charset: ?[]const u8 = null;
                        var autofk = false;
                        var si: usize = 2;
                        while (si < line.tokens.len) : (si += 1) {
                            if (std.mem.eql(u8, line.tokens[si], "autofk")) {
                                autofk = true;
                            } else if (charset == null) {
                                charset = try self.alloc.dupe(u8, line.tokens[si]);
                            }
                        }
                        schema = .{
                            .name = try self.alloc.dupe(u8, line.tokens[1]),
                            .charset = charset,
                            .autofk = autofk,
                            .custom_types = &.{},
                            .line_no = line.line_no,
                            .loc = Parser.locFromLine(line, line.tokens[0]),
                        };
                    }
                },
                .TypeDef => {
                    if (schema != null and line.tokens.len >= 3) {
                        const ct = parse_typedef.parseTypeDef(self.alloc, line) catch |err| {
                            if (!self.handleParseError(err, line, "failed to parse ~ (custom type) directive")) return err;
                            continue;
                        };
                        try custom_types.append(self.alloc, ct);
                    }
                },
                .Template => {
                    if (in_block == .template) {
                        try self.flushCurrentTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushCurrentTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
                    }

                    // Parse new template header
                    const tmpl = parse_template.parseTemplateHeader(self.alloc, line) catch |err| {
                        if (!self.handleParseError(err, line, "failed to parse template declaration")) return err;
                        in_block = .none;
                        continue;
                    };
                    cur_name = tmpl.name;
                    cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                    cur_parents_len = 0;
                    for (tmpl.parents) |p| {
                        if (cur_parents_len < cur_parents_buf.len) {
                            cur_parents_buf[cur_parents_len] = p;
                            cur_parents_len += 1;
                        }
                    }
                    cur_template_ref = null;
                    cur_comment = null;
                    cur_line_no = tmpl.line_no;
                    cur_loc = tmpl.loc;
                    cur_fields.clearRetainingCapacity();
                    cur_fks.clearRetainingCapacity();
                    cur_indexes.clearRetainingCapacity();
                    in_block = .template;
                },
                .Table => {
                    if (in_block == .template) {
                        try self.flushCurrentTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushCurrentTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
                    }

                    const result = try parse_table.stripEngineTokens(self.alloc, line.tokens);
                    if (result.engine) |e| cur_engine = e;
                    const stripped_line = tk.Line{
                        .line_type = line.line_type,
                        .tokens = result.stripped,
                        .raw = line.raw,
                        .trimmed = line.trimmed,
                        .line_no = line.line_no,
                    };

                    const hdr = parse_table.parseTableHeader(self.alloc, stripped_line) catch |err| {
                        if (!self.handleParseError(err, line, "failed to parse table declaration")) return err;
                        in_block = .none;
                        continue;
                    };
                    cur_name = hdr.name;
                    cur_comment = hdr.comment;
                    cur_template_ref = hdr.template_ref;
                    cur_line_no = hdr.line_no;
                    cur_loc = hdr.loc;
                    cur_fields.clearRetainingCapacity();
                    cur_fks.clearRetainingCapacity();
                    cur_indexes.clearRetainingCapacity();
                    in_block = .table;
                },
                .View => {
                    if (in_block == .template) {
                        try self.flushCurrentTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushCurrentTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
                    }
                    in_block = .none;
                    if (line.tokens.len >= 2) {
                        views.append(self.alloc, parse_table.processViewLine(self.alloc, line.tokens, line.line_no) catch continue) catch continue;
                    }
                },
                .Field => {
                    if (in_block != .none) {
                        const fld = parse_field.parseField(self.alloc, line) catch |err| {
                            if (!self.handleParseError(err, line, "failed to parse field")) return err;
                            continue;
                        };
                        try cur_fields.append(self.alloc, fld);
                    } else {
                        diag.printDiagnostic(.{
                            .severity = .warning,
                            .line_no = line.line_no,
                            .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                            .message = "field declaration outside table or template — ignored",
                            .source_line = line.raw,
                        });
                    }
                },
                .Slot => {
                    if (in_block != .none) {
                        try cur_fields.append(self.alloc, .{
                            .name = "...",
                            .type_info = .none,
                            .modifiers = &.{},
                            .default_val = null,
                            .check = null,
                            .fk = null,
                            .comment = null,
                            .line_no = line.line_no,
                            .loc = if (line.tokens.len > 0) Parser.locFromLine(line, line.tokens[0]) else null,
                        });
                    } else {
                        diag.printDiagnostic(.{
                            .severity = .warning,
                            .line_no = line.line_no,
                            .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                            .message = "slot declaration outside template — ignored",
                            .source_line = line.raw,
                        });
                    }
                },
                .FK => {
                    if (in_block == .table) {
                        const fk = parse_fk.parseFk(self.alloc, line) catch |err| {
                            if (!self.handleParseError(err, line, "failed to parse foreign key")) return err;
                            continue;
                        };
                        try cur_fks.append(self.alloc, fk);
                    } else if (in_block == .template) {
                        diag.printDiagnostic(.{
                            .severity = .warning,
                            .line_no = line.line_no,
                            .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                            .message = "FOREIGN KEY ignored inside template — declare in table instead",
                            .source_line = line.raw,
                        });
                    }
                },
                .Index => {
                    if (in_block == .table) {
                        const idx = parse_index.parseIndex(self.alloc, line) catch |err| {
                            if (!self.handleParseError(err, line, "failed to parse index")) return err;
                            continue;
                        };
                        try cur_indexes.append(self.alloc, idx);
                    } else if (in_block == .template) {
                        diag.printDiagnostic(.{
                            .severity = .warning,
                            .line_no = line.line_no,
                            .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                            .message = "INDEX ignored inside template — declare in table instead",
                            .source_line = line.raw,
                        });
                    }
                },
                .CompositePK => {
                    if (in_block == .table) {
                        const idx = parse_index.parseCompositePk(self.alloc, line) catch |err| {
                            if (!self.handleParseError(err, line, "failed to parse composite primary key")) return err;
                            continue;
                        };
                        try cur_indexes.append(self.alloc, idx);
                    } else if (in_block == .template) {
                        diag.printDiagnostic(.{
                            .severity = .warning,
                            .line_no = line.line_no,
                            .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                            .message = "composite PRIMARY KEY ignored inside template — declare in table instead",
                            .source_line = line.raw,
                        });
                    }
                },
                .Engine => {
                    if (line.tokens.len >= 2) {
                        cur_engine = try self.alloc.dupe(u8, line.tokens[1]);
                    } else {
                        cur_engine = "InnoDB";
                    }
                },
                .SQLComment => {
                    if (in_block == .none) {
                        try sql_comments.append(self.alloc, .{
                            .text = line.raw,
                            .line_no = line.line_no,
                        });
                    }
                },
            }
        }

        // Flush last block — catch allocation errors gracefully
        if (in_block == .template) {
            self.flushCurrentTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc) catch |err| {
                diag.printDiagnostic(.{
                    .severity = .@"error",
                    .line_no = cur_line_no,
                    .message = "failed to flush template block",
                    .actual = @errorName(err),
                });
            };
        } else if (in_block == .table) {
            self.flushCurrentTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc) catch |err| {
                diag.printDiagnostic(.{
                    .severity = .@"error",
                    .line_no = cur_line_no,
                    .message = "failed to flush table block",
                    .actual = @errorName(err),
                });
            };
        }

        // Merge custom_types into schema
        const final_schema = if (schema) |s| blk: {
            if (custom_types.items.len > 0) {
                break :blk ast_mod.Schema{
                    .name = s.name,
                    .charset = s.charset,
                    .autofk = s.autofk,
                    .custom_types = try custom_types.toOwnedSlice(self.alloc),
                    .line_no = s.line_no,
                    .loc = s.loc,
                };
            }
            break :blk ast_mod.Schema{
                .name = s.name,
                .charset = s.charset,
                .autofk = s.autofk,
                .custom_types = &.{},
                .line_no = s.line_no,
                .loc = s.loc,
            };
        } else null;

        return .{
            .schema = final_schema,
            .templates = try templates.toOwnedSlice(self.alloc),
            .tables = try tables.toOwnedSlice(self.alloc),
            .views = try views.toOwnedSlice(self.alloc),
            .sql_comments = try sql_comments.toOwnedSlice(self.alloc),
        };
    }

    fn flushCurrentTable(
        self: *Parser,
        tables: *std.ArrayList(Table),
        name: ?[]const u8,
        comment: ?[]const u8,
        template_ref: ?[]const u8,
        engine: ?[]const u8,
        fields: *std.ArrayList(Field),
        fks: *std.ArrayList(FkDecl),
        indexes: *std.ArrayList(IndexDecl),
        line_no: usize,
        loc: ?SourceLocation,
    ) !void {
        try tables.append(self.alloc, .{
            .template_ref = template_ref,
            .name = name orelse "",
            .comment = comment,
            .engine = engine,
            .fields = try fields.toOwnedSlice(self.alloc),
            .fks = try fks.toOwnedSlice(self.alloc),
            .indexes = try indexes.toOwnedSlice(self.alloc),
            .line_no = line_no,
            .loc = loc,
        });
    }

    fn flushCurrentTemplate(
        self: *Parser,
        templates: *std.ArrayList(Template),
        name: ?[]const u8,
        parents_buf: []const []const u8,
        parents_len: usize,
        fields: *std.ArrayList(Field),
        line_no: usize,
        loc: ?SourceLocation,
    ) !void {
        try parse_template.flushTemplate(self.alloc, templates, name, parents_buf, parents_len, fields, line_no, loc);
    }

    // ─── Public API: delegated functions ────────────────────

    /// Public API: parse type token. Delegates to parse_field module.
    pub fn tryParseType(tok: []const u8) ?TypeInfo {
        return parse_field.tryParseType(tok);
    }

    /// Public API: classify CHECK constraint. Delegates to parse_check module.
    pub fn classifyCheck(expr: []const u8, open_bracket: u8, close_bracket: u8) CheckKind {
        return parse_check.classifyCheck(expr, open_bracket, close_bracket);
    }
};

// ─── Diagnostic Trace ────────────────────────────────────────

pub const diagnosticTrace = parse_trace.diagnosticTrace;

// ─── Unit Tests ──────────────────────────────────────────────

test "tryParseType: single-char types" {
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "n" }), Parser.tryParseType("n"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "N" }), Parser.tryParseType("N"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "s" }), Parser.tryParseType("s"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .varchar_explicit = 0 }), Parser.tryParseType("s"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "d" }), Parser.tryParseType("d"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "t" }), Parser.tryParseType("t"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "b" }), Parser.tryParseType("b"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "j" }), Parser.tryParseType("j"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .simple = "m" }), Parser.tryParseType("m"));
}

test "tryParseType: explicit types" {
    try std.testing.expectEqual(@as(?TypeInfo, .{ .varchar_explicit = 128 }), Parser.tryParseType("s128"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .varchar_explicit = 255 }), Parser.tryParseType("s255"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .int_explicit = 11 }), Parser.tryParseType("11"));
    try std.testing.expectEqual(@as(?TypeInfo, .{ .decimal_explicit = .{ .precision = 10, .scale = 2 } }), Parser.tryParseType("10,2"));
}

test "tryParseType: invalid" {
    try std.testing.expectEqual(@as(?TypeInfo, null), Parser.tryParseType(""));
    try std.testing.expectEqual(@as(?TypeInfo, null), Parser.tryParseType("x"));
    try std.testing.expectEqual(@as(?TypeInfo, null), Parser.tryParseType("abc"));
}

test "classifyCheck: range" {
    try std.testing.expectEqual(CheckKind.range, Parser.classifyCheck("1, 100", '[', ']'));
    try std.testing.expectEqual(CheckKind.range_upper_exclusive, Parser.classifyCheck("1, 100", '[', ')'));
    try std.testing.expectEqual(CheckKind.range_lower_exclusive, Parser.classifyCheck("1, 100", '(', ']'));
    try std.testing.expectEqual(CheckKind.range_both_exclusive, Parser.classifyCheck("1, 100", '(', ')'));
}

test "classifyCheck: in_list" {
    try std.testing.expectEqual(CheckKind.in_list, Parser.classifyCheck("active inactive", '{', '}'));
}

test "classifyCheck: comparison" {
    try std.testing.expectEqual(CheckKind.comparison, Parser.classifyCheck("price > 0", '{', '}'));
    try std.testing.expectEqual(CheckKind.comparison, Parser.classifyCheck("price > 0 AND price < 10000", '[', ']'));
}
