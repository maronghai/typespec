const std = @import("std");
const tk = @import("tokenizer.zig");
const diag = @import("diagnostic.zig");
const ast_mod = @import("ast.zig");
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

    pub fn parse(self: *Parser, lines: []const tk.Line) !Ast {
        var schema: ?Schema = null;
        var templates = try std.ArrayList(Template).initCapacity(self.alloc, 8);
        var tables = try std.ArrayList(Table).initCapacity(self.alloc, 8);
        var sql_comments = try std.ArrayList(SqlComment).initCapacity(self.alloc, 8);

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
                            .line_no = line.line_no,
                        };
                    }
                },
                .Template => {
                    // Flush previous template
                    if (in_block == .template) {
                        try self.flushTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no);
                        // Re-init for next template
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no);
                    }

                    // Parse new template header
                    const tmpl = try self.parseTemplate(line);
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
                    cur_fields.clearRetainingCapacity();
                    cur_fks.clearRetainingCapacity();
                    cur_indexes.clearRetainingCapacity();
                    in_block = .template;
                },
                .Table => {
                    // Flush previous block
                    if (in_block == .template) {
                        try self.flushTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no);
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                        cur_parents_buf = try self.alloc.alloc([]const u8, 4);
                        cur_parents_len = 0;
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no);
                    }

                    // Strip ^ tokens from line before parsing header
                    var stripped_tokens = try std.ArrayList([]const u8).initCapacity(self.alloc, line.tokens.len);
                    var ti: usize = 0;
                    while (ti < line.tokens.len) : (ti += 1) {
                        const tok = line.tokens[ti];
                        if (std.mem.eql(u8, tok, "^")) {
                            // Skip ^ and the engine name that follows
                            if (ti + 1 < line.tokens.len and !std.mem.eql(u8, line.tokens[ti + 1], ":")) {
                                cur_engine = try self.alloc.dupe(u8, line.tokens[ti + 1]);
                                ti += 1;
                            } else {
                                // Standalone ^ without engine name — default InnoDB
                                cur_engine = "InnoDB";
                            }
                            continue;
                        }
                        if (tok.len > 1 and tok[0] == '^') {
                            cur_engine = try self.alloc.dupe(u8, tok[1..]);
                            continue;
                        }
                        try stripped_tokens.append(self.alloc, tok);
                    }
                    const stripped_line = tk.Line{
                        .line_type = line.line_type,
                        .tokens = try stripped_tokens.toOwnedSlice(self.alloc),
                        .raw = line.raw,
                        .trimmed = line.trimmed,
                        .line_no = line.line_no,
                    };

                    // Parse new table header
                    const hdr = try self.parseTableHeader(stripped_line);
                    cur_name = hdr.name;
                    cur_comment = hdr.comment;
                    cur_template_ref = hdr.template_ref;
                    cur_line_no = hdr.line_no;
                    cur_fields.clearRetainingCapacity();
                    cur_fks.clearRetainingCapacity();
                    cur_indexes.clearRetainingCapacity();
                    in_block = .table;
                },
                .Field => {
                    if (in_block != .none) {
                        const fld = self.parseField(line) catch |err| {
                            if (self.diagnostics) |dc| {
                                dc.record(.{
                                    .severity = .@"error",
                                    .line_no = line.line_no,
                                    .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                                    .message = "failed to parse field",
                                    .actual = @errorName(err),
                                    .source_line = line.raw,
                                });
                            } else {
                                return err;
                            }
                            continue;
                        };
                        try cur_fields.append(self.alloc, fld);
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
                        });
                    }
                },
                .FK => {
                    if (in_block == .table) {
                        const fk = self.parseFK(line) catch |err| {
                            if (self.diagnostics) |dc| {
                                dc.record(.{
                                    .severity = .@"error",
                                    .line_no = line.line_no,
                                    .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                                    .message = "failed to parse foreign key",
                                    .actual = @errorName(err),
                                    .source_line = line.raw,
                                });
                            } else {
                                return err;
                            }
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
                        const idx = self.parseIndex(line) catch |err| {
                            if (self.diagnostics) |dc| {
                                dc.record(.{
                                    .severity = .@"error",
                                    .line_no = line.line_no,
                                    .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                                    .message = "failed to parse index",
                                    .actual = @errorName(err),
                                    .source_line = line.raw,
                                });
                            } else {
                                return err;
                            }
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
                        const idx = self.parseCompositePK(line) catch |err| {
                            if (self.diagnostics) |dc| {
                                dc.record(.{
                                    .severity = .@"error",
                                    .line_no = line.line_no,
                                    .col = if (line.tokens.len > 0) diag.tokenColumn(line.tokens[0], line.raw) else null,
                                    .message = "failed to parse composite primary key",
                                    .actual = @errorName(err),
                                    .source_line = line.raw,
                                });
                            } else {
                                return err;
                            }
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
            try self.flushTemplate(&templates, cur_name, cur_parents_buf, cur_parents_len, &cur_fields, cur_line_no);
        } else if (in_block == .table) {
            try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, cur_engine, &cur_fields, &cur_fks, &cur_indexes, cur_line_no);
        }

        return .{
            .schema = schema,
            .templates = try templates.toOwnedSlice(self.alloc),
            .tables = try tables.toOwnedSlice(self.alloc),
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
    ) !void {
        const slot_idx = findSlot(fields.items);
        try templates.append(self.alloc, .{
            .name = name,
            .parents = parents_buf[0..parents_len],
            .fields = try fields.toOwnedSlice(self.alloc),
            .slot_index = slot_idx,
            .line_no = line_no,
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
        };
    }

    const TableHeader = struct {
        template_ref: ?[]const u8,
        name: []const u8,
        comment: ?[]const u8,
        line_no: usize,
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
        };
    }

    // ─── Fused type+modifier parsing ─────────────────────────

    const FusedTypeResult = struct {
        type_info: ?TypeInfo = null,
        modifier: ?Modifier = null,
        default_val: ?DefaultVal = null,
    };

    /// Parse fused tokens like `n++`, `s128*`, `nu`, `*=0`, `t+`.
    /// Returns null if the token is not a fused type+modifier form.
    pub fn parseFusedTypeModifier(_: *Parser, tok: []const u8, line_no: usize) ?FusedTypeResult {
        if (tok.len < 2) return null;

        // *=value (NOT NULL + DEFAULT)
        if (tok[0] == '*' and tok[1] == '=') {
            return .{
                .modifier = .{ .kind = .not_null, .line_no = line_no },
                .default_val = .{ .value = tok[2..], .line_no = line_no },
            };
        }

        // Check all suffix patterns: ++, +, !, *, u
        const last = tok[tok.len - 1];
        if (last == '+' and tok.len >= 3 and tok[tok.len - 2] == '+') {
            const prefix = tok[0 .. tok.len - 2];
            if (tryParseType(prefix)) |ti| {
                return .{ .type_info = ti, .modifier = .{ .kind = .auto_inc_pk, .line_no = line_no } };
            }
        }
        if (last == '+' and tok.len >= 2 and tok[tok.len - 2] != '+') {
            const prefix = tok[0 .. tok.len - 1];
            if (tryParseType(prefix)) |ti| {
                return .{ .type_info = ti, .modifier = .{ .kind = .auto_inc, .line_no = line_no } };
            }
        }
        if (last == '!' and tok.len >= 2) {
            const prefix = tok[0 .. tok.len - 1];
            if (tryParseType(prefix)) |ti| {
                return .{ .type_info = ti, .modifier = .{ .kind = .primary_key, .line_no = line_no } };
            }
        }
        if (last == '*' and tok.len >= 2) {
            const prefix = tok[0 .. tok.len - 1];
            if (tryParseType(prefix)) |ti| {
                return .{ .type_info = ti, .modifier = .{ .kind = .not_null, .line_no = line_no } };
            }
        }
        if (last == 'u' and tok[tok.len - 2] != '+') {
            const prefix = tok[0 .. tok.len - 1];
            if (tryParseType(prefix)) |ti| {
                const is_numeric = switch (ti) {
                    .simple => |s| (std.mem.eql(u8, s, "n") or std.mem.eql(u8, s, "N")),
                    .int_explicit => true,
                    else => false,
                };
                if (is_numeric) {
                    return .{ .type_info = ti, .modifier = .{ .kind = .unsigned, .line_no = line_no } };
                }
            }
        }

        return null;
    }

    // ─── Enum type parsing ──────────────────────────────────

    /// Parse `e(M,F,X)` or `e('a','b')` enum types.
    /// `tok` must be `"e"` and `idx` must point to it.
    fn parseEnumType(self: *Parser, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize) !struct { type_info: TypeInfo, end_idx: usize } {
        const paren_col = diag.tokenColumn(tokens[idx + 1], raw);
        var i = idx + 2; // skip e and (
        var enum_vals = try std.ArrayList([]const u8).initCapacity(self.alloc, 8);
        while (i < tokens.len) : (i += 1) {
            if (std.mem.eql(u8, tokens[i], ")")) break;
            const val_tok = tokens[i];
            if (std.mem.eql(u8, val_tok, ",")) continue;
            // Handle comma-separated values in single token
            if (std.mem.indexOfScalar(u8, val_tok, ',')) |_| {
                var rest = val_tok;
                while (rest.len > 0) {
                    if (std.mem.indexOfScalar(u8, rest, ',')) |cp| {
                        if (cp > 0) {
                            var val = rest[0..cp];
                            if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
                                val = val[1 .. val.len - 1];
                            }
                            try enum_vals.append(self.alloc, try self.alloc.dupe(u8, val));
                        }
                        rest = rest[cp + 1 ..];
                    } else {
                        if (rest.len > 0) {
                            var val = rest;
                            if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
                                val = val[1 .. val.len - 1];
                            }
                            try enum_vals.append(self.alloc, try self.alloc.dupe(u8, val));
                        }
                        break;
                    }
                }
            } else {
                var val = val_tok;
                if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
                    val = val[1 .. val.len - 1];
                }
                try enum_vals.append(self.alloc, try self.alloc.dupe(u8, val));
            }
        }
        if (i >= tokens.len) {
            diag.printDiagnostic(.{
                .severity = .@"error",
                .line_no = line_no,
                .col = paren_col,
                .message = "expected ')' to close enum type",
                .expected = "')'",
                .actual = "end of line",
                .source_line = raw,
            });
        }
        return .{
            .type_info = .{ .enum_type = try enum_vals.toOwnedSlice(self.alloc) },
            .end_idx = i + 1, // +1 to skip past ')'
        };
    }

    // ─── Inline FK parsing ──────────────────────────────────

    /// Detect inline FK: `> table.field` or `table.field`.
    /// Returns the FK and the index after all consumed tokens.
    fn parseInlineFK(self: *Parser, tokens: []const []const u8, idx: usize, field_name: []const u8, raw: []const u8, trimmed: []const u8, line_no: usize) !struct { fk: FkDecl, end_idx: usize } {
        var fk_tokens = try std.ArrayList([]const u8).initCapacity(self.alloc, 8);
        try fk_tokens.append(self.alloc, field_name);
        var j: usize = idx;
        if (std.mem.eql(u8, tokens[idx], ">")) {
            j = idx + 1;
            if (j < tokens.len) {
                const after_gt = tokens[j];
                if (std.mem.indexOfScalar(u8, after_gt, '.') == null) {
                    j += 1; // skip type token
                }
            }
        }
        while (j < tokens.len) : (j += 1) {
            const rt = tokens[j];
            if (rt.len >= 1 and rt[0] == ':') break;
            if (rt.len >= 2 and rt[0] == '-' and rt[1] == '-') break;
            if (rt.len > 0 and rt[0] == ';') break;
            try fk_tokens.append(self.alloc, rt);
        }
        const fk_slice = try fk_tokens.toOwnedSlice(self.alloc);
        const fk_line = tk.Line{
            .line_type = .FK,
            .tokens = fk_slice,
            .raw = raw,
            .trimmed = trimmed,
            .line_no = line_no,
        };
        const fk = try self.parseFK(fk_line);
        // Skip FK action tokens that were already collected
        while (j < tokens.len) {
            const at = tokens[j];
            if (at.len == 2 and at[0] == '-' and (at[1] == 'C' or at[1] == 'N')) {
                j += 1;
                if (j < tokens.len and tokens[j].len == 1 and
                    (tokens[j][0] == 'C' or tokens[j][0] == 'N'))
                {
                    j += 1;
                }
            } else if (at.len == 1 and (at[0] == 'C' or at[0] == 'N')) {
                j += 1;
            } else if (at.len == 1 and at[0] == '-' and j + 1 < tokens.len) {
                const nxt = tokens[j + 1];
                if (nxt.len == 1 and (nxt[0] == 'C' or nxt[0] == 'N')) {
                    j += 2;
                } else break;
            } else break;
        }
        return .{ .fk = fk, .end_idx = j };
    }

    // ─── Standalone modifier parsing ────────────────────────

    const ModifierResult = struct {
        modifier: Modifier,
        end_idx: usize,
    };

    /// Parse standalone modifiers: `++`, `+`, `*`, `!`, `@`, `@u`.
    pub fn parseStandaloneModifier(_: *Parser, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize) ?ModifierResult {
        const tok = tokens[idx];
        if (std.mem.eql(u8, tok, "++")) {
            return .{ .modifier = .{ .kind = .auto_inc_pk, .line_no = line_no }, .end_idx = idx + 1 };
        }
        if (std.mem.eql(u8, tok, "+")) {
            return .{ .modifier = .{ .kind = .auto_inc, .line_no = line_no }, .end_idx = idx + 1 };
        }
        if (std.mem.eql(u8, tok, "*")) {
            return .{ .modifier = .{ .kind = .not_null, .line_no = line_no }, .end_idx = idx + 1 };
        }
        if (std.mem.eql(u8, tok, "!")) {
            return .{ .modifier = .{ .kind = .primary_key, .line_no = line_no }, .end_idx = idx + 1 };
        }
        // @u inline unique (tokenizer may split @ and u)
        if (std.mem.eql(u8, tok, "@") and idx + 1 < tokens.len and std.mem.eql(u8, tokens[idx + 1], "u")) {
            return .{ .modifier = .{ .kind = .inline_unique, .line_no = line_no }, .end_idx = idx + 2 };
        }
        if (std.mem.eql(u8, tok, "@u")) {
            return .{ .modifier = .{ .kind = .inline_unique, .line_no = line_no }, .end_idx = idx + 1 };
        }
        // @ followed by f (inline fulltext — not supported)
        if (std.mem.eql(u8, tok, "@") and idx + 1 < tokens.len and std.mem.eql(u8, tokens[idx + 1], "f")) {
            diag.printDiagnostic(.{
                .severity = .warning,
                .line_no = line_no,
                .col = diag.tokenColumn(tokens[idx], raw),
                .message = "inline @f not supported on field",
                .expected = "standalone '@f' declaration instead",
                .actual = tok,
                .source_line = raw,
            });
            return .{ .modifier = .{ .kind = .inline_index, .line_no = line_no }, .end_idx = idx + 2 };
        }
        // @ alone or @ followed by non-u/f = inline regular index
        if (std.mem.eql(u8, tok, "@")) {
            return .{ .modifier = .{ .kind = .inline_index, .line_no = line_no }, .end_idx = idx + 1 };
        }
        return null;
    }

    // ─── CHECK constraint parsing ───────────────────────────

    const CheckResult = struct {
        check: CheckConstraint,
        end_idx: usize,
    };

    /// Parse CHECK constraint: `[...]`, `(..)`, or `{..}`.
    fn parseCheckConstraint(self: *Parser, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize) !?CheckResult {
        const tok = tokens[idx];
        if (tok[0] == '[') {
            return try self.parseCheckBody(tokens, idx, raw, line_no, '[', ']');
        }
        if (tok[0] == '(') {
            return try self.parseCheckBody(tokens, idx, raw, line_no, '(', ')');
        }
        if (tok[0] == '{') {
            return try self.parseCheckBody(tokens, idx, raw, line_no, '{', '}');
        }
        return null;
    }

    fn parseCheckBody(self: *Parser, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize, open_bracket: u8, close_bracket: u8) !CheckResult {
        const bracket_col = diag.tokenColumn(tokens[idx], raw);
        var check_str = try std.ArrayList(u8).initCapacity(self.alloc, 32);
        var needs_comma = false;
        var i = idx + 1;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if ((close_bracket == ']' and std.mem.eql(u8, t, "]")) or
                (close_bracket == ')' and std.mem.eql(u8, t, ")")) or
                (close_bracket == '}' and std.mem.eql(u8, t, "}")))
            {
                break;
            }
            // Also stop at mismatched closers (e.g., ] when expecting ))
            if (close_bracket != ']' and std.mem.eql(u8, t, "]")) break;
            if (close_bracket != ')' and std.mem.eql(u8, t, ")")) break;
            if (std.mem.eql(u8, t, ",")) {
                needs_comma = true;
                continue;
            }
            if (needs_comma) try check_str.append(self.alloc, ',');
            try check_str.appendSlice(self.alloc, t);
            needs_comma = true;
        }
        if (i >= tokens.len) {
            const expected: []const u8 = switch (close_bracket) {
                ']' => "']'",
                ')' => "')' or ']'",
                else => "'}'",
            };
            diag.printDiagnostic(.{
                .severity = .@"error",
                .line_no = line_no,
                .col = bracket_col,
                .message = "unclosed bracket",
                .expected = expected,
                .actual = "end of line",
                .source_line = raw,
            });
        }
        // Determine actual close bracket for classification
        const actual_close: u8 = if (i < tokens.len) blk: {
            const t = tokens[i];
            if (t.len == 1) break :blk t[0];
            break :blk close_bracket;
        } else close_bracket;
        const check_expr = try check_str.toOwnedSlice(self.alloc);
        return .{
            .check = .{ .kind = classifyCheck(check_expr, open_bracket, actual_close), .expr = check_expr, .line_no = line_no },
            .end_idx = i + 1, // +1 to skip past closing bracket
        };
    }

    // ─── Field parsing (orchestrator) ───────────────────────

    fn parseField(self: *Parser, line: tk.Line) !Field {
        if (line.tokens.len == 0) return error.EmptyField;

        const name = try self.alloc.dupe(u8, line.tokens[0]);
        var type_info: TypeInfo = .none;
        var modifiers = try std.ArrayList(Modifier).initCapacity(self.alloc, 8);
        var default_val: ?DefaultVal = null;
        var check: ?CheckConstraint = null;
        var inline_fk: ?FkDecl = null;
        var comment: ?[]const u8 = null;

        var i: usize = 1;
        while (i < line.tokens.len) {
            const tok = line.tokens[i];

            // 1. Fused type+modifier: n++, s128*, *=0, nu, t+
            if (self.parseFusedTypeModifier(tok, line.line_no)) |result| {
                if (result.type_info) |ti| {
                    // Only set type and add modifier if type wasn't already set
                    if (type_info == .none) {
                        type_info = ti;
                        if (result.modifier) |mod| try modifiers.append(self.alloc, mod);
                    }
                } else {
                    // No type (e.g. *=0) — always apply modifier + default
                    if (result.modifier) |mod| try modifiers.append(self.alloc, mod);
                    if (result.default_val) |dv| default_val = dv;
                }
                i += 1;
                continue;
            }

            // 2. Plain type: n, s, 16,2, s128
            if (type_info == .none) {
                if (tryParseType(tok)) |ti| {
                    type_info = ti;
                    i += 1;
                    continue;
                }
            }

            // 2b. Standalone u modifier (unsigned on any preceding numeric type)
            if (std.mem.eql(u8, tok, "u") and type_info != .none) {
                const is_numeric = switch (type_info) {
                    .simple => |s| (std.mem.eql(u8, s, "n") or std.mem.eql(u8, s, "N")),
                    .int_explicit => true,
                    else => false,
                };
                if (is_numeric) {
                    try modifiers.append(self.alloc, .{ .kind = .unsigned, .line_no = line.line_no });
                    i += 1;
                    continue;
                }
            }

            // 3. Enum type: e(M,F,X) or e('admin','user')
            if (type_info == .none and std.mem.eql(u8, tok, "e") and i + 1 < line.tokens.len and std.mem.eql(u8, line.tokens[i + 1], "(")) {
                const result = try self.parseEnumType(line.tokens, i, line.raw, line.line_no);
                type_info = result.type_info;
                i = result.end_idx;
                continue;
            }

            // 4. Comments: : (column), -- (SQL), ; (spec)
            if (tok.len >= 1 and tok[0] == ':') { comment = tok; break; }
            if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') { comment = tok; break; }
            if (tok[0] == ';') break;

            // 5. Standalone modifiers: ++, +, *, !, @, @u
            if (self.parseStandaloneModifier(line.tokens, i, line.raw, line.line_no)) |result| {
                try modifiers.append(self.alloc, result.modifier);
                i = result.end_idx;
                continue;
            }

            // 6. Inline FK: > table.field or table.field
            if (std.mem.eql(u8, tok, ">") or
                (std.mem.indexOfScalar(u8, tok, '.') != null and tok[0] != '[' and tok[0] != '=' and tok[0] != '/' and tok[0] != '-' and tok[0] != ';'))
            {
                const result = try self.parseInlineFK(line.tokens, i, name, line.raw, line.trimmed, line.line_no);
                inline_fk = result.fk;
                i = result.end_idx;
                break;
            }

            // 7. Default value: =value
            if (tok[0] == '=' and tok.len > 1) {
                default_val = .{ .value = tok[1..], .line_no = line.line_no };
                i += 1;
                continue;
            }

            // 8. CHECK constraints: [...] (...)  {..}
            if (tok[0] == '[' or tok[0] == '(' or tok[0] == '{') {
                if (try self.parseCheckConstraint(line.tokens, i, line.raw, line.line_no)) |result| {
                    check = result.check;
                    i = result.end_idx;
                    continue;
                }
            }

            // 9. Skip stray closing brackets
            if (std.mem.eql(u8, tok, "]") or std.mem.eql(u8, tok, "}")) { i += 1; continue; }

            // 10. Unrecognized token warning
            diag.printDiagnostic(.{
                .severity = .warning,
                .line_no = line.line_no,
                .col = diag.tokenColumn(tok, line.raw),
                .message = "unrecognized token in field",
                .expected = "type symbol (n, N, s, S, m, M, b, B, j, d, t, int, decimal, e(...)) or modifier (+, ++, *, !, u, @, @u, =, [], {}, ())",
                .actual = tok,
                .source_line = line.raw,
            });
            i += 1;
        }

        // Validate ++ and + modifiers against type
        for (modifiers.items) |mod| {
            if (mod.kind == .auto_inc_pk or mod.kind == .auto_inc) {
                if (type_info == .none) continue;
                const is_valid = switch (type_info) {
                    .simple => |s| (s.len == 1 and (s[0] == 'n' or s[0] == 'N' or s[0] == 't' or s[0] == 'd')),
                    .int_explicit => true,
                    else => false,
                };
                if (!is_valid) {
                    diag.printDiagnostic(.{
                        .severity = .warning,
                        .line_no = line.line_no,
                        .col = diag.tokenColumn(name, line.raw),
                        .message = "modifier invalid for this type",
                        .expected = "n, N, integer types, t, d for this modifier",
                        .actual = name,
                        .source_line = line.raw,
                    });
                }
            }
        }

        return .{
            .name = name,
            .type_info = type_info,
            .modifiers = try modifiers.toOwnedSlice(self.alloc),
            .default_val = default_val,
            .check = check,
            .fk = inline_fk,
            .comment = comment,
            .line_no = line.line_no,
        };
    }

    pub fn tryParseType(tok: []const u8) ?TypeInfo {
        if (tok.len == 0) return null;
        const c = tok[0];
        switch (c) {
            'n', 'N', 'm', 'M', 's', 'S', 'b', 'B', 'j', 'd', 't' => {
                if (tok.len == 1) {
                    if (c == 's') return .{ .varchar_explicit = 0 };
                    return .{ .simple = tok };
                }
                if (c == 's') {
                    const num_part = tok[1..];
                    const n = std.fmt.parseInt(usize, num_part, 10) catch return null;
                    return .{ .varchar_explicit = n };
                }
                return null;
            },
            '0'...'9' => {
                if (std.mem.indexOfScalar(u8, tok, ',')) |comma_pos| {
                    const p = std.fmt.parseInt(usize, tok[0..comma_pos], 10) catch return null;
                    const s = std.fmt.parseInt(usize, tok[comma_pos + 1 ..], 10) catch return null;
                    return .{ .decimal_explicit = .{ .precision = p, .scale = s } };
                } else {
                    const n = std.fmt.parseInt(usize, tok, 10) catch return null;
                    return .{ .int_explicit = n };
                }
            },
            else => return null,
        }
    }

    pub fn classifyCheck(expr: []const u8, open_bracket: u8, close_bracket: u8) CheckKind {
        // Handle comparison (contains > < =)
        if (std.mem.indexOfScalar(u8, expr, '>') != null or std.mem.indexOfScalar(u8, expr, '<') != null) {
            // {braces} → always comparison
            if (open_bracket == '{') return .comparison;
            // [] with comparison operators → not supported, use {}
            if (open_bracket == '[' and close_bracket == ']') return .range;
            // [a,b) or (a,b] or (a,b) form → exclusive range
            if (open_bracket == '(' and close_bracket == ')') return .range_both_exclusive;
            if (close_bracket == ')') return .range_upper_exclusive;
            if (open_bracket == '(') return .range_lower_exclusive;
            return .range_both_exclusive;
        }
        // Handle IN list (always {braces})
        if (open_bracket == '{') return .in_list;
        // Handle range
        if (std.mem.indexOfScalar(u8, expr, ',') != null) {
            var parts = std.mem.splitScalar(u8, expr, ',');
            const first = std.mem.trim(u8, parts.next() orelse "", " ");
            const second = std.mem.trim(u8, parts.next() orelse "", " ");
            const third = parts.next();
            // Range: exactly 2 parts, both numeric (no quotes)
            if (third == null and first.len > 0 and second.len > 0) {
                if (first[0] != '\'' and second[0] != '\'') {
                    if (open_bracket == '(' and close_bracket == ')') return .range_both_exclusive;
                    if (close_bracket == ')') return .range_upper_exclusive;
                    if (open_bracket == '(') return .range_lower_exclusive;
                    return .range;
                }
            }
            return .in_list;
        }
        return .comparison;
    }

    fn parseFK(self: *Parser, line: tk.Line) !FkDecl {
        var local_fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 4);
        var ref_table: []const u8 = "";
        var ref_fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 4);

        const tokens = line.tokens;

        // Standard FK forms
        // Standalone FK (from tokenizer): [>, field_name, ref]  fi=1
        // Inline FK (reconstructed):     [field_name, >, ref]  fi=0, off=1
        const has_prefix = tokens.len >= 2 and std.mem.eql(u8, tokens[0], ">");
        const fi: usize = if (has_prefix) 1 else 0; // field index
        // Inline FK has `>` separator at fi+1, shifting ref by +1
        const has_sep = !has_prefix and tokens.len >= 2 and std.mem.eql(u8, tokens[1], ">");
        const off: usize = if (has_sep) 1 else 0; // offset for ref due to > separator
        const next_idx = fi + 1 + off;

        // Local field name: always at fi (0 for inline, 1 for standalone)
        const local_field_name = if (fi < tokens.len) line.tokens[fi] else "";

        // Reference index: skip > separator when present, also skip type token if present
        var ref_idx = if (has_sep) fi + 2 else next_idx;
        // When there's a separator and the token after > is a type (not a ref), skip it
        if (has_sep and ref_idx < tokens.len) {
            const candidate = tokens[ref_idx];
            const looks_like_ref = std.mem.indexOfScalar(u8, candidate, '.') != null or
                std.mem.eql(u8, candidate, "(") or
                candidate.len == 0;
            if (!looks_like_ref) {
                ref_idx += 1; // skip type token
            }
        }

        // When tokens[fi] contains a dot, it's the reference (ultra shorthand).
        const ref_is_at_fi = !has_sep and fi < tokens.len and
            std.mem.indexOfScalar(u8, tokens[fi], '.') != null;

        // For "> table" (no dot, no bracket, exactly 2 tokens), reference is at fi
        const ultra_no_dot = has_prefix and !has_sep and !ref_is_at_fi and tokens.len == 2;
        const ref_effective = if (ref_is_at_fi or ultra_no_dot) fi else ref_idx;

        const ref_has_dot = tokens.len > ref_effective and std.mem.indexOfScalar(u8, tokens[ref_effective], '.') != null;

        if (ref_has_dot) {
            // field table.field  or  table.field (inline ultra)
            if (ref_is_at_fi) {
                // Inline ultra: table.field — no local field
                const ref = line.tokens[ref_effective];
                if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
                    ref_table = try self.alloc.dupe(u8, ref[0..dot]);
                    try ref_fields.append(self.alloc, try self.alloc.dupe(u8, ref[dot + 1 ..]));
                    const inferred = try std.fmt.allocPrint(self.alloc, "{s}_id", .{ref_table});
                    try local_fields.append(self.alloc, inferred);
                }
            } else {
                // Standard: field table.field
                try local_fields.append(self.alloc, local_field_name);
                const ref = line.tokens[ref_effective];
                if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
                    ref_table = try self.alloc.dupe(u8, ref[0..dot]);
                    if (dot + 1 < ref.len) {
                        try ref_fields.append(self.alloc, try self.alloc.dupe(u8, ref[dot + 1 ..]));
                    } else {
                        // trailing dot: infer ref_field from local field name
                        try ref_fields.append(self.alloc, local_field_name);
                    }
                }
            }
        } else if (ultra_no_dot) {
            // > table — ultra shorthand without dot (infer field = table_id, ref_field = id)
            ref_table = try self.alloc.dupe(u8, line.tokens[fi]);
            try ref_fields.append(self.alloc, try self.alloc.dupe(u8, "id"));
            const inferred = try std.fmt.allocPrint(self.alloc, "{s}_id", .{ref_table});
            try local_fields.append(self.alloc, inferred);
        } else if (tokens.len > ref_effective) {
            // field_name ref_table (shorthand-no-dot)
            try local_fields.append(self.alloc, local_field_name);
            const ref = line.tokens[ref_effective];
            if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
                ref_table = try self.alloc.dupe(u8, ref[0..dot]);
                try ref_fields.append(self.alloc, try self.alloc.dupe(u8, ref[dot + 1 ..]));
            } else {
                ref_table = try self.alloc.dupe(u8, ref);
                try ref_fields.append(self.alloc, try self.alloc.dupe(u8, "id"));
            }
        }

        // Warn if FK form was unrecognized (empty fields/ref_table)
        if (local_fields.items.len == 0 and ref_table.len == 0) {
            diag.printDiagnostic(.{
                .severity = .warning,
                .line_no = line.line_no,
                .col = if (tokens.len > 0) diag.tokenColumn(tokens[0], line.raw) else null,
                .message = "unrecognized foreign key form",
                .expected = "> field_name table.field or > table.field",
                .source_line = line.raw,
            });
        }

        // Parse FK actions after reference (-S, -N, S, N)
        const actions = try self.parseFKActions(tokens, ref_effective + 1);

        return .{
            .fields = try local_fields.toOwnedSlice(self.alloc),
            .ref_table = ref_table,
            .ref_fields = try ref_fields.toOwnedSlice(self.alloc),
            .actions = actions,
            .line_no = line.line_no,
        };
    }

    fn parseFKActions(self: *Parser, tokens: []const []const u8, start: usize) ![]const FkAction {
        var actions = try std.ArrayList(FkAction).initCapacity(self.alloc, 4);
        var i = start;
        while (i < tokens.len) : (i += 1) {
            const tok = tokens[i];
            // Combined token: -C, -N (no whitespace)
            if (tok.len == 2 and tok[0] == '-' and (tok[1] == 'C' or tok[1] == 'N')) {
                const act: FkActionType = if (tok[1] == 'C') .cascade else .set_null;
                try actions.append(self.alloc, .{ .trigger = .on_delete, .action = act });
                continue;
            }
            // Split tokens: - C, - N (space-separated)
            if (tok.len == 1 and tok[0] == '-' and i + 1 < tokens.len) {
                const act_tok = tokens[i + 1];
                if (act_tok.len == 1 and (act_tok[0] == 'C' or act_tok[0] == 'N')) {
                    const act: FkActionType = if (act_tok[0] == 'C') .cascade else .set_null;
                    try actions.append(self.alloc, .{ .trigger = .on_delete, .action = act });
                    i += 1;
                    continue;
                }
            }
            // ON UPDATE: standalone C or N
            if (tok.len == 1 and (tok[0] == 'C' or tok[0] == 'N')) {
                const act: FkActionType = if (tok[0] == 'C') .cascade else .set_null;
                try actions.append(self.alloc, .{ .trigger = .on_update, .action = act });
                continue;
            }
            break; // not an action token, stop
        }
        return try actions.toOwnedSlice(self.alloc);
    }
    fn parseIndex(self: *Parser, line: tk.Line) !IndexDecl {
        var kind: IndexType = .regular;
        var name: []const u8 = "";
        var fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 8);
        var descending = try std.ArrayList(bool).initCapacity(self.alloc, 8);

        const tokens = line.tokens;
        var idx: usize = 1;

        if (idx < tokens.len) {
            if (std.mem.eql(u8, tokens[idx], "u")) {
                kind = .unique;
                idx += 1;
            } else if (std.mem.eql(u8, tokens[idx], "f")) {
                kind = .fulltext;
                idx += 1;
            }
        }

        if (idx < tokens.len) {
            // Composite index without name: @ (a, b) → auto-generate name
            if (std.mem.eql(u8, tokens[idx], "(")) {
                idx += 1; // skip (
                while (idx < tokens.len) : (idx += 1) {
                    const tok = tokens[idx];
                    if (std.mem.eql(u8, tok, ")")) break;
                    if (std.mem.eql(u8, tok, ",")) continue;
                    const is_desc = std.mem.endsWith(u8, tok, "-");
                    const fname = if (is_desc) tok[0 .. tok.len - 1] else tok;
                    try fields.append(self.alloc, try self.alloc.dupe(u8, fname));
                    try descending.append(self.alloc, is_desc);
                }
                // Auto-generate name from fields: idx_field1_field2
                if (fields.items.len > 0) {
                    const prefix = switch (kind) {
                        .regular => "idx_",
                        .unique => "uk_",
                        .fulltext => "ft_",
                        .primary_key => unreachable,
                    };
                    var name_buf = try std.ArrayList(u8).initCapacity(self.alloc, 64);
                    try name_buf.appendSlice(self.alloc, prefix);
                    for (fields.items, 0..) |f, fi| {
                        if (fi > 0) try name_buf.append(self.alloc, '_');
                        try name_buf.appendSlice(self.alloc, f);
                    }
                    name = try name_buf.toOwnedSlice(self.alloc);
                }
                return .{
                    .kind = kind,
                    .name = name,
                    .fields = try fields.toOwnedSlice(self.alloc),
                    .descending = try descending.toOwnedSlice(self.alloc),
                    .line_no = line.line_no,
                };
            }

            // Peek ahead: if next token is NOT "(" or end, this is shorthand form
            // e.g., "@ name" where "name" is a field, not an index name
            const is_shorthand = (idx + 1 >= tokens.len) or
                !std.mem.eql(u8, tokens[idx + 1], "(");

            if (is_shorthand) {
                // Shorthand: @ field [field2 ...] → auto-generate index name
                while (idx < tokens.len) {
                    const tok = tokens[idx];
                    if (std.mem.eql(u8, tok, "(") or std.mem.eql(u8, tok, ",") or std.mem.eql(u8, tok, ")")) break;
                    const is_desc = std.mem.endsWith(u8, tok, "-");
                    const fname = if (is_desc) tok[0 .. tok.len - 1] else tok;
                    try fields.append(self.alloc, try self.alloc.dupe(u8, fname));
                    try descending.append(self.alloc, is_desc);
                    idx += 1;
                }
                // Auto-generate name: idx_ / uk_ / ft_ + fields joined by _
                const prefix = switch (kind) {
                    .regular => "idx_",
                    .unique => "uk_",
                    .fulltext => "ft_",
                    .primary_key => unreachable,
                };
                var name_buf = try std.ArrayList(u8).initCapacity(self.alloc, 64);
                try name_buf.appendSlice(self.alloc, prefix);
                for (fields.items, 0..) |f, fi| {
                    if (fi > 0) try name_buf.append(self.alloc, '_');
                    try name_buf.appendSlice(self.alloc, f);
                }
                name = try name_buf.toOwnedSlice(self.alloc);
                return .{
                    .kind = kind,
                    .name = name,
                    .fields = try fields.toOwnedSlice(self.alloc),
                    .descending = try descending.toOwnedSlice(self.alloc),
                    .line_no = line.line_no,
                };
            } else {
                // Full form: @ idx_name (field1, field2)
                name = try self.alloc.dupe(u8, tokens[idx]);
                idx += 1;
            }
        }

        while (idx < tokens.len) : (idx += 1) {
            const tok = tokens[idx];
            if (std.mem.eql(u8, tok, "(")) {
                continue;
            } else if (std.mem.eql(u8, tok, ")")) {
                break;
            } else if (std.mem.eql(u8, tok, ",")) {
                continue;
            } else {
                // Strip trailing ) if present
                var field_name = if (tok.len > 1 and tok[tok.len - 1] == ')')
                    tok[0 .. tok.len - 1]
                else
                    tok;
                const is_desc = std.mem.endsWith(u8, field_name, "-");
                if (is_desc) field_name = field_name[0 .. field_name.len - 1];
                try fields.append(self.alloc, try self.alloc.dupe(u8, field_name));
                try descending.append(self.alloc, is_desc);
            }
        }

        return .{
            .kind = kind,
            .name = name,
            .fields = try fields.toOwnedSlice(self.alloc),
            .descending = try descending.toOwnedSlice(self.alloc),
            .line_no = line.line_no,
        };
    }

    fn parseCompositePK(self: *Parser, line: tk.Line) !IndexDecl {
        var fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 8);
        var descending = try std.ArrayList(bool).initCapacity(self.alloc, 8);
        for (line.tokens) |tok| {
            if (std.mem.eql(u8, tok, "!") or std.mem.eql(u8, tok, ",")) continue;
            const is_desc = std.mem.endsWith(u8, tok, "-");
            const fname = if (is_desc) tok[0 .. tok.len - 1] else tok;
            try fields.append(self.alloc, try self.alloc.dupe(u8, fname));
            try descending.append(self.alloc, is_desc);
        }
        return .{
            .kind = .primary_key,
            .name = "",
            .fields = try fields.toOwnedSlice(self.alloc),
            .descending = try descending.toOwnedSlice(self.alloc),
            .line_no = line.line_no,
        };
    }
};

// ─── Diagnostic Trace ────────────────────────────────────────

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
                    std.debug.print(" >", .{});
                    for (fk.fields, 0..) |f, fi| {
                        if (fi > 0) std.debug.print(",", .{});
                        std.debug.print("{s}", .{f});
                    }
                    std.debug.print(" {s}(", .{fk.ref_table});
                    for (fk.ref_fields, 0..) |f, fi| {
                        if (fi > 0) std.debug.print(",", .{});
                        std.debug.print("{s}", .{f});
                    }
                    std.debug.print(")", .{});
                    for (fk.actions) |action| {
                        std.debug.print(" ", .{});
                        switch (action.trigger) {
                            .on_delete => std.debug.print("ON DELETE ", .{}),
                            .on_update => std.debug.print("ON UPDATE ", .{}),
                        }
                        switch (action.action) {
                            .cascade => std.debug.print("CASCADE", .{}),
                            .set_null => std.debug.print("SET NULL", .{}),
                        }
                    }
                }
                if (field.comment) |c| std.debug.print(" {s}", .{c});
                std.debug.print("\n", .{});
            }
            for (table.fks) |fk| {
                std.debug.print("    > ", .{});
                for (fk.fields, 0..) |f, fi| {
                    if (fi > 0) std.debug.print(",", .{});
                    std.debug.print("{s}", .{f});
                }
                std.debug.print(" {s}(", .{fk.ref_table});
                for (fk.ref_fields, 0..) |f, fi| {
                    if (fi > 0) std.debug.print(",", .{});
                    std.debug.print("{s}", .{f});
                }
                std.debug.print(")", .{});
                for (fk.actions) |action| {
                    std.debug.print(" ", .{});
                    switch (action.trigger) {
                        .on_delete => std.debug.print("ON DELETE ", .{}),
                        .on_update => std.debug.print("ON UPDATE ", .{}),
                    }
                    switch (action.action) {
                        .cascade => std.debug.print("CASCADE", .{}),
                        .set_null => std.debug.print("SET NULL", .{}),
                    }
                }
                std.debug.print("\n", .{});
            }
            for (table.indexes) |idx| {
                std.debug.print("    @ ", .{});
                switch (idx.kind) {
                    .regular => std.debug.print("idx", .{}),
                    .unique => std.debug.print("uk", .{}),
                    .fulltext => std.debug.print("ft", .{}),
                    .primary_key => std.debug.print("pk", .{}),
                }
                std.debug.print(" {s}(", .{idx.name});
                for (idx.fields, 0..) |f, fi| {
                    if (fi > 0) std.debug.print(",", .{});
                    std.debug.print("{s}", .{f});
                }
                std.debug.print(")\n", .{});
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

test "parseFusedTypeModifier: auto_inc_pk" {
    var p = Parser.init(std.testing.allocator);
    const r = p.parseFusedTypeModifier("n++", 1).?;
    try std.testing.expect(r.type_info != null);
    try std.testing.expect(r.modifier != null);
    try std.testing.expectEqual(ModifierType.auto_inc_pk, r.modifier.?.kind);
}

test "parseFusedTypeModifier: auto_inc" {
    var p = Parser.init(std.testing.allocator);
    const r = p.parseFusedTypeModifier("t+", 1).?;
    try std.testing.expect(r.type_info != null);
    try std.testing.expect(r.modifier != null);
    try std.testing.expectEqual(ModifierType.auto_inc, r.modifier.?.kind);
}

test "parseFusedTypeModifier: primary_key" {
    var p = Parser.init(std.testing.allocator);
    const r = p.parseFusedTypeModifier("n!", 1).?;
    try std.testing.expect(r.type_info != null);
    try std.testing.expectEqual(ModifierType.primary_key, r.modifier.?.kind);
}

test "parseFusedTypeModifier: not_null" {
    var p = Parser.init(std.testing.allocator);
    const r = p.parseFusedTypeModifier("s128*", 1).?;
    try std.testing.expect(r.type_info != null);
    try std.testing.expectEqual(ModifierType.not_null, r.modifier.?.kind);
}

test "parseFusedTypeModifier: not_null_default" {
    var p = Parser.init(std.testing.allocator);
    const r = p.parseFusedTypeModifier("*=0", 1).?;
    try std.testing.expect(r.type_info == null);
    try std.testing.expect(r.modifier != null);
    try std.testing.expectEqual(ModifierType.not_null, r.modifier.?.kind);
    try std.testing.expect(r.default_val != null);
    try std.testing.expectEqualStrings("0", r.default_val.?.value);
}

test "parseFusedTypeModifier: unsigned" {
    var p = Parser.init(std.testing.allocator);
    const r = p.parseFusedTypeModifier("nu", 1).?;
    try std.testing.expect(r.type_info != null);
    try std.testing.expect(r.modifier != null);
    try std.testing.expectEqual(ModifierType.unsigned, r.modifier.?.kind);
}

test "parseFusedTypeModifier: null for non-fused" {
    var p = Parser.init(std.testing.allocator);
    try std.testing.expectEqual(@as(?Parser.FusedTypeResult, null), p.parseFusedTypeModifier("n", 1));
    try std.testing.expectEqual(@as(?Parser.FusedTypeResult, null), p.parseFusedTypeModifier("hello", 1));
    try std.testing.expectEqual(@as(?Parser.FusedTypeResult, null), p.parseFusedTypeModifier("+", 1));
}

test "parseStandaloneModifier: all modifiers" {
    var p = Parser.init(std.testing.allocator);
    const toks = &.{ "++", "+", "*", "!", "@", "@u" };
    const expected = &.{ ModifierType.auto_inc_pk, ModifierType.auto_inc, ModifierType.not_null, ModifierType.primary_key, ModifierType.inline_index, ModifierType.inline_unique };
    inline for (0..6) |i| {
        const r = p.parseStandaloneModifier(&.{toks[i]}, 0, toks[i], 1).?;
        try std.testing.expectEqual(expected[i], r.modifier.kind);
    }
}

test "parseStandaloneModifier: null for non-modifier" {
    var p = Parser.init(std.testing.allocator);
    try std.testing.expectEqual(@as(?Parser.ModifierResult, null), p.parseStandaloneModifier(&.{"hello"}, 0, "hello", 1));
    try std.testing.expectEqual(@as(?Parser.ModifierResult, null), p.parseStandaloneModifier(&.{"n"}, 0, "n", 1));
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
