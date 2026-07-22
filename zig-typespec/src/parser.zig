const std = @import("std");
const tk = @import("tokenizer.zig");
const diag = @import("diagnostic.zig");
const ast_mod = @import("ast.zig");
const parse_fk = @import("parse_fk.zig");
const parse_index = @import("parse_index.zig");
const parse_check = @import("parse_check.zig");
const parse_field = @import("parse_field.zig");
const parse_typedef = @import("parse_typedef.zig");
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
        if (self.diagnostics) |dc| {
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
    fn locFromLine(line: tk.Line, tok: []const u8) SourceLocation {
        const col = diag.tokenColumn(tok, line.raw);
        return .{
            .line = line.line_no,
            .col = col,
            .offset = line.offset + col - 1,
        };
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
                        // Parse additional tokens: charset or flags
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
                        const ct = self.parseTypeDef(line) catch |err| {
                            if (!self.handleParseError(err, line, "failed to parse ~ (custom type) directive")) return err;
                            continue;
                        };
                        try custom_types.append(self.alloc, ct);
                    }
                },
                .Template => {
                    if (in_block == .template) {
                        try self.flushAndResetTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
                    }

                    // Parse new template header
                    const tmpl = self.parseTemplate(line) catch |err| {
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
                        try self.flushAndResetTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
                    }

                    const result = try self.stripEngineTokens(line.tokens);
                    if (result.engine) |e| cur_engine = e;
                    const stripped_line = tk.Line{
                        .line_type = line.line_type,
                        .tokens = result.stripped,
                        .raw = line.raw,
                        .trimmed = line.trimmed,
                        .line_no = line.line_no,
                    };

                    const hdr = self.parseTableHeader(stripped_line) catch |err| {
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
                        try self.flushAndResetTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
                    }
                    in_block = .none;
                    if (line.tokens.len >= 2) {
                        views.append(self.alloc, self.processViewLine(line.tokens, line.line_no) catch continue) catch continue;
                    }
                },
                .Field => {
                    if (in_block != .none) {
                        try self.processFieldLine(line, &cur_fields);
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
                    // Standalone engine declaration: ^ or ^EngineName
                    if (line.tokens.len >= 2) {
                        cur_engine = try self.alloc.dupe(u8, line.tokens[1]);
                    } else {
                        cur_engine = "InnoDB";
                    }
                },
                .SQLComment => {
                    // Only collect top-level SQL comments (not inside template/table blocks)
                    if (in_block == .none) {
                        try sql_comments.append(self.alloc, .{
                            .text = line.raw,
                            .line_no = line.line_no,
                        });
                    }
                },
            }
        }

        // Flush last block
        if (in_block == .template) {
            try self.flushTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no, cur_loc);
        } else if (in_block == .table) {
            try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no, cur_loc);
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

    fn flushTable(
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

    fn findSlot(fields: []const Field) ?usize {
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "...")) return i;
        }
        return null;
    }

    fn flushTemplate(
        self: *Parser,
        templates: *std.ArrayList(Template),
        name: ?[]const u8,
        parents_buf: []const []const u8,
        parents_len: usize,
        fields: *std.ArrayList(Field),
        line_no: usize,
        loc: ?SourceLocation,
    ) !void {
        const slot_idx = findSlot(fields.items);
        try templates.append(self.alloc, .{
            .name = name,
            .parents = parents_buf[0..parents_len],
            .fields = try fields.toOwnedSlice(self.alloc),
            .slot_index = slot_idx,
            .line_no = line_no,
            .loc = loc,
        });
    }

    fn parseTemplate(self: *Parser, line: tk.Line) !Template {
        var name: ?[]const u8 = null;
        const parents_buf = try self.alloc.alloc([]const u8, 4);
        var parents_len: usize = 0;
        if (line.tokens.len >= 2) {
            if (!std.mem.eql(u8, line.tokens[1], ">") and !std.mem.eql(u8, line.tokens[1], "+")) {
                name = try self.alloc.dupe(u8, line.tokens[1]);
            }
        }
        // Collect parents: after name or after > keyword
        var start_idx: usize = 0;
        var found_keyword = false;
        for (line.tokens, 0..) |tok, i| {
            if (std.mem.eql(u8, tok, ">")) {
                start_idx = i + 1;
                found_keyword = true;
                break;
            }
        }
        // If no > found, parents start after the % and name tokens
        if (!found_keyword) {
            start_idx = if (name != null) 2 else 1;
        }
        var i: usize = start_idx;
        while (i < line.tokens.len) : (i += 1) {
            if (!std.mem.eql(u8, line.tokens[i], "+")) {
                if (parents_len < parents_buf.len) {
                    parents_buf[parents_len] = try self.alloc.dupe(u8, line.tokens[i]);
                    parents_len += 1;
                }
            }
        }
        const result_parents = parents_buf[0..parents_len];
        return .{
            .name = name,
            .parents = result_parents,
            .fields = &.{},
            .slot_index = null,
            .line_no = line.line_no,
            .loc = Parser.locFromLine(line, line.tokens[0]),
        };
    }

    const TableHeader = struct {
        template_ref: ?[]const u8,
        name: []const u8,
        comment: ?[]const u8,
        line_no: usize,
        loc: ?SourceLocation,
    };

    fn parseTableHeader(self: *Parser, line: tk.Line) !TableHeader {
        var template_ref: ?[]const u8 = null;
        var table_name: []const u8 = "";
        var comment: ?[]const u8 = null;

        const tokens = line.tokens;
        if (tokens.len == 2) {
            // # table_name  (no template ref)
            table_name = try self.alloc.dupe(u8, tokens[1]);
        } else if (tokens.len >= 3) {
            // Check if tokens[2] is a comment
            if (tokens[2].len >= 1 and tokens[2][0] == ':') {
                // # table_name : comment
                table_name = try self.alloc.dupe(u8, tokens[1]);
                comment = try self.alloc.dupe(u8, tokens[2]);
            } else {
                // # template_ref table_name [: comment]
                template_ref = try self.alloc.dupe(u8, tokens[1]);
                table_name = try self.alloc.dupe(u8, tokens[2]);
                if (tokens.len >= 4) {
                    comment = try self.alloc.dupe(u8, tokens[3]);
                }
            }
        }

        return .{
            .template_ref = template_ref,
            .name = table_name,
            .comment = comment,
            .line_no = line.line_no,
            .loc = Parser.locFromLine(line, line.tokens[0]),
        };
    }

    fn parseTypeDef(self: *Parser, line: tk.Line) !ast_mod.CustomType {
        return parse_typedef.parseTypeDef(self.alloc, line);
    }

    // ─── Parse helpers ─────────────────────────────────────────

    /// Flush the current template block.
    fn flushAndResetTemplate(
        self: *Parser,
        templates: *std.ArrayList(Template),
        name: ?[]const u8,
        parents_buf: []const []const u8,
        parents_len: usize,
        fields: *std.ArrayList(Field),
        line_no: usize,
        loc: ?SourceLocation,
    ) !void {
        try self.flushTemplate(templates, name, parents_buf, parents_len, fields, line_no, loc);
    }

    /// Strip engine tokens (^ or ^EngineName) from a table line's tokens.
    fn stripEngineTokens(self: *Parser, tokens: []const []const u8) !struct { stripped: []const []const u8, engine: ?[]const u8 } {
        var engine: ?[]const u8 = null;
        var stripped = try std.ArrayList([]const u8).initCapacity(self.alloc, tokens.len);
        var ti: usize = 0;
        while (ti < tokens.len) : (ti += 1) {
            const tok = tokens[ti];
            if (std.mem.eql(u8, tok, "^")) {
                if (ti + 1 < tokens.len and !std.mem.eql(u8, tokens[ti + 1], ":")) {
                    engine = try self.alloc.dupe(u8, tokens[ti + 1]);
                    ti += 1;
                } else {
                    engine = "InnoDB";
                }
                continue;
            }
            if (tok.len > 1 and tok[0] == '^') {
                engine = try self.alloc.dupe(u8, tok[1..]);
                continue;
            }
            try stripped.append(self.alloc, tok);
        }
        return .{ .stripped = try stripped.toOwnedSlice(self.alloc), .engine = engine };
    }

    /// Parse a view line into a View AST node.
    fn processViewLine(self: *Parser, tokens: []const []const u8, line_no: usize) !ast_mod.View {
        if (tokens.len >= 4) {
            const view_name = try self.alloc.dupe(u8, tokens[1]);
            var query: []const u8 = "";
            for (tokens, 0..) |tok, ti| {
                if (std.mem.eql(u8, tok, "=") and ti + 1 < tokens.len) {
                    query = try self.alloc.dupe(u8, tokens[ti + 1]);
                    break;
                }
            }
            return .{
                .name = view_name,
                .query = query,
                .comment = null,
                .line_no = line_no,
                .loc = Parser.locFromLine(.{ .line_no = line_no, .raw = "", .trimmed = "", .tokens = tokens, .line_type = .View, .offset = 0 }, tokens[0]),
            };
        } else if (tokens.len == 2) {
            return .{
                .name = try self.alloc.dupe(u8, tokens[1]),
                .query = "",
                .comment = null,
                .line_no = line_no,
                .loc = Parser.locFromLine(.{ .line_no = line_no, .raw = "", .trimmed = "", .tokens = tokens, .line_type = .View, .offset = 0 }, tokens[0]),
            };
        }
        return error.InvalidView;
    }

    /// Process a field line: parse and append to cur_fields.
    fn processFieldLine(self: *Parser, line: tk.Line, cur_fields: *std.ArrayList(Field)) !void {
        const fld = parse_field.parseField(self.alloc, line) catch |err| {
            if (!self.handleParseError(err, line, "failed to parse field")) return err;
            return;
        };
        try cur_fields.append(self.alloc, fld);
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

const trace = @import("trace.zig");

pub fn diagnosticTrace(tree: Ast) void {
    std.debug.print("=== [Stage 2: Parser] ===\n\n", .{});

    if (tree.schema) |schema| {
        std.debug.print("Schema: {s}", .{schema.name});
        if (schema.charset) |cs| std.debug.print(" charset={s}", .{cs});
        if (schema.autofk) std.debug.print(" [autofk]", .{});
        std.debug.print("\n\n", .{});
    }

    if (tree.templates.len > 0) {
        std.debug.print("Templates ({d}):\n", .{tree.templates.len});
        for (tree.templates) |tmpl| {
            std.debug.print("  %% {s}", .{tmpl.name orelse "(default)"});
            if (tmpl.parents.len > 0) {
                std.debug.print(" > ", .{});
                for (tmpl.parents, 0..) |p, pi| {
                    if (pi > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{p});
                }
            }
            std.debug.print("  [{d} field(s)]\n", .{tmpl.fields.len});
            for (tmpl.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) {
                    std.debug.print("    ...\n", .{});
                    continue;
                }
                std.debug.print("    {s: <20} ", .{field.name});
                ast_mod.fmtTypeInfo(field.type_info);
                ast_mod.fmtModifiers(field.modifiers);
                if (field.default_val) |dv| std.debug.print(" ={s}", .{dv.value});
                if (field.check) |ck| std.debug.print(" [{s}]", .{ck.expr});
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    if (tree.tables.len > 0) {
        std.debug.print("Tables ({d}):\n", .{tree.tables.len});
        for (tree.tables) |table| {
            std.debug.print("  # {s}", .{table.name});
            if (table.template_ref) |tr| std.debug.print(" (ref={s})", .{tr});
            if (table.comment) |c| std.debug.print(" {s}", .{c});
            std.debug.print("\n", .{});
            for (table.fields) |field| {
                if (std.mem.eql(u8, field.name, "...")) continue;
                std.debug.print("    {s: <20} ", .{field.name});
                ast_mod.fmtTypeInfo(field.type_info);
                ast_mod.fmtModifiers(field.modifiers);
                if (field.default_val) |dv| std.debug.print(" ={s}", .{dv.value});
                if (field.check) |ck| std.debug.print(" [{s}]", .{ck.expr});
                if (field.fk) |fk| {
                    trace.formatFk(fk);
                }
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
            for (table.fks) |fk| {
                trace.formatResolvedFk(fk);
            }
            for (table.indexes) |idx| {
                trace.formatIndex(idx);
            }
        }
        std.debug.print("\n", .{});
    }

    if (tree.sql_comments.len > 0) {
        std.debug.print("SQL Comments ({d}):\n", .{tree.sql_comments.len});
        for (tree.sql_comments) |sc| {
            std.debug.print("  L{d}: {s}\n", .{ sc.line_no, sc.text });
        }
        std.debug.print("\n", .{});
    }
}

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
