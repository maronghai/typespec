const std = @import("std");
const tk = @import("tokenizer.zig");

// ─── AST Types ───────────────────────────────────────────────

pub const TypeInfo = union(enum) {
    none,
    simple: []const u8,
    int_explicit: usize,
    decimal_explicit: struct { precision: usize, scale: usize },
    varchar_explicit: usize,
};

pub const ModifierType = enum {
    auto_inc_pk,
    auto_inc,
    primary_key,
    not_null,
};

pub const Modifier = struct {
    kind: ModifierType,
    line_no: usize,
};

pub const DefaultVal = struct {
    value: []const u8,
    line_no: usize,
};

pub const CheckKind = enum {
    range,
    in_list,
    comparison,
};

pub const CheckConstraint = struct {
    kind: CheckKind,
    expr: []const u8,
    line_no: usize,
};

pub const Field = struct {
    name: []const u8,
    type_info: TypeInfo,
    modifiers: []const Modifier,
    default_val: ?DefaultVal,
    check: ?CheckConstraint,
    comment: ?[]const u8,
    line_no: usize,
};

pub const FkAction = union(enum) {
    on_delete: []const u8,
    on_update: []const u8,
};

pub const FkDecl = struct {
    field: []const u8,
    ref_table: []const u8,
    ref_field: []const u8,
    actions: []const FkAction,
    line_no: usize,
};

pub const IndexType = enum {
    regular,
    unique,
    fulltext,
};

pub const IndexDecl = struct {
    kind: IndexType,
    name: []const u8,
    fields: []const []const u8,
    line_no: usize,
};

pub const Template = struct {
    name: ?[]const u8,
    extends: ?[]const u8,
    fields: []const Field,
    slot_index: ?usize,
    line_no: usize,
};

pub const Table = struct {
    template_ref: ?[]const u8,
    name: []const u8,
    comment: ?[]const u8,
    fields: []const Field,
    fks: []const FkDecl,
    indexes: []const IndexDecl,
    line_no: usize,
};

pub const Schema = struct {
    name: []const u8,
    line_no: usize,
};

pub const SqlComment = struct {
    text: []const u8,
    line_no: usize,
};

pub const Ast = struct {
    schema: ?Schema,
    templates: []const Template,
    tables: []const Table,
    sql_comments: []const SqlComment,
};

// ─── Parser ──────────────────────────────────────────────────

pub const Parser = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{ .alloc = alloc };
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
        var cur_extends: ?[]const u8 = null;
        var cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
        var cur_fks = try std.ArrayList(FkDecl).initCapacity(self.alloc, 4);
        var cur_indexes = try std.ArrayList(IndexDecl).initCapacity(self.alloc, 4);
        var cur_line_no: usize = 0;
        var in_block: enum { none, template, table } = .none;

        for (lines) |line| {
            switch (line.line_type) {
                .Empty, .SpecComment => {},
                .Schema => {
                    if (line.tokens.len >= 2) {
                        schema = .{
                            .name = try self.alloc.dupe(u8, line.tokens[1]),
                            .line_no = line.line_no,
                        };
                    }
                },
                .Template => {
                    // Flush previous template
                    if (in_block == .template) {
                        const slot_idx = findSlot(cur_fields.items);
                        try templates.append(self.alloc, .{
                            .name = cur_name,
                            .extends = cur_extends,
                            .fields = try cur_fields.toOwnedSlice(self.alloc),
                            .slot_index = slot_idx,
                            .line_no = cur_line_no,
                        });
                        // Re-init for next template (toOwnedSlice consumed the items)
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, &cur_fields, &cur_fks, &cur_indexes, cur_line_no);
                    }

                    // Parse new template header
                    const tmpl = try self.parseTemplate(line);
                    cur_name = tmpl.name;
                    cur_extends = tmpl.extends;
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
                        const slot_idx = findSlot(cur_fields.items);
                        try templates.append(self.alloc, .{
                            .name = cur_name,
                            .extends = cur_extends,
                            .fields = try cur_fields.toOwnedSlice(self.alloc),
                            .slot_index = slot_idx,
                            .line_no = cur_line_no,
                        });
                        cur_fields = try std.ArrayList(Field).initCapacity(self.alloc, 16);
                    } else if (in_block == .table) {
                        try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, &cur_fields, &cur_fks, &cur_indexes, cur_line_no);
                    }

                    // Parse new table header
                    const hdr = try self.parseTableHeader(line);
                    cur_name = hdr.name;
                    cur_comment = hdr.comment;
                    cur_template_ref = hdr.template_ref;
                    cur_extends = null;
                    cur_line_no = hdr.line_no;
                    cur_fields.clearRetainingCapacity();
                    cur_fks.clearRetainingCapacity();
                    cur_indexes.clearRetainingCapacity();
                    in_block = .table;
                },
                .Field => {
                    if (in_block != .none) {
                        const fld = try self.parseField(line);
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
                            .comment = null,
                            .line_no = line.line_no,
                        });
                    }
                },
                .FK => {
                    if (in_block == .table) {
                        const fk = try self.parseFK(line);
                        try cur_fks.append(self.alloc, fk);
                    }
                },
                .Index => {
                    if (in_block == .table) {
                        const idx = try self.parseIndex(line);
                        try cur_indexes.append(self.alloc, idx);
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
            const slot_idx = findSlot(cur_fields.items);
            try templates.append(self.alloc, .{
                .name = cur_name,
                .extends = cur_extends,
                .fields = try cur_fields.toOwnedSlice(self.alloc),
                .slot_index = slot_idx,
                .line_no = cur_line_no,
            });
        } else if (in_block == .table) {
            try self.flushTable(&tables, cur_name, cur_comment, cur_template_ref, &cur_fields, &cur_fks, &cur_indexes, cur_line_no);
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
        fields: *std.ArrayList(Field),
        fks: *std.ArrayList(FkDecl),
        indexes: *std.ArrayList(IndexDecl),
        line_no: usize,
    ) !void {
        try tables.append(self.alloc, .{
            .template_ref = template_ref,
            .name = name orelse "",
            .comment = comment,
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

    fn parseTemplate(self: *Parser, line: tk.Line) !Template {
        var name: ?[]const u8 = null;
        var extends: ?[]const u8 = null;
        if (line.tokens.len >= 2) {
            if (!std.mem.eql(u8, line.tokens[1], "extends") and !std.mem.eql(u8, line.tokens[1], ">")) {
                name = try self.alloc.dupe(u8, line.tokens[1]);
            }
        }
        for (line.tokens, 0..) |tok, i| {
            if ((std.mem.eql(u8, tok, ">") or std.mem.eql(u8, tok, "extends")) and i + 1 < line.tokens.len) {
                extends = try self.alloc.dupe(u8, line.tokens[i + 1]);
                break;
            }
        }
        return .{
            .name = name,
            .extends = extends,
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
            if (tokens[2].len >= 2 and tokens[2][0] == '/' and tokens[2][1] == '/') {
                // # table_name // comment
                table_name = try self.alloc.dupe(u8, tokens[1]);
                comment = try self.alloc.dupe(u8, tokens[2]);
            } else {
                // # template_ref table_name [// comment]
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

    fn parseField(self: *Parser, line: tk.Line) !Field {
        if (line.tokens.len == 0) return error.EmptyField;

        const name = try self.alloc.dupe(u8, line.tokens[0]);
        var type_info: TypeInfo = .none;
        var modifiers = try std.ArrayList(Modifier).initCapacity(self.alloc, 8);
        var default_val: ?DefaultVal = null;
        var check: ?CheckConstraint = null;
        var comment: ?[]const u8 = null;

        var i: usize = 1;
        while (i < line.tokens.len) : (i += 1) {
            var tok = line.tokens[i];

            // Handle ++ suffix on type tokens (e.g., "n++" -> type "n" + modifier "++")
            if (tok.len >= 3 and tok[tok.len - 1] == '+' and tok[tok.len - 2] == '+') {
                // Check if the prefix is a valid type
                const prefix = tok[0 .. tok.len - 2];
                if (tryParseType(prefix) != null) {
                    if (type_info == .none) {
                        type_info = tryParseType(prefix).?;
                        try modifiers.append(self.alloc, .{ .kind = .auto_inc_pk, .line_no = line.line_no });
                        continue;
                    }
                }
                // Not a type with ++, treat as two ++ modifiers
                try modifiers.append(self.alloc, .{ .kind = .auto_inc_pk, .line_no = line.line_no });
                continue;
            }

            // Handle + suffix on type tokens (e.g., "t+" -> type "t" + modifier "+")
            if (tok.len >= 2 and tok[tok.len - 1] == '+' and tok[tok.len - 2] != '+') {
                const prefix = tok[0 .. tok.len - 1];
                if (tryParseType(prefix) != null) {
                    if (type_info == .none) {
                        type_info = tryParseType(prefix).?;
                        try modifiers.append(self.alloc, .{ .kind = .auto_inc, .line_no = line.line_no });
                        continue;
                    }
                }
            }

            // Handle ! suffix on type tokens (e.g., "n!" -> type "n" + modifier "!")
            if (tok.len >= 2 and tok[tok.len - 1] == '!') {
                const prefix = tok[0 .. tok.len - 1];
                if (tryParseType(prefix) != null) {
                    if (type_info == .none) {
                        type_info = tryParseType(prefix).?;
                        try modifiers.append(self.alloc, .{ .kind = .primary_key, .line_no = line.line_no });
                        continue;
                    }
                }
            }

            // Handle * suffix on type tokens (e.g., "n*" -> type "n" + modifier "*")
            if (tok.len >= 2 and tok[tok.len - 1] == '*') {
                const prefix = tok[0 .. tok.len - 1];
                if (tryParseType(prefix) != null) {
                    if (type_info == .none) {
                        type_info = tryParseType(prefix).?;
                        try modifiers.append(self.alloc, .{ .kind = .not_null, .line_no = line.line_no });
                        continue;
                    }
                }
            }

            if (type_info == .none) {
                if (tryParseType(tok)) |ti| {
                    type_info = ti;
                    continue;
                }
            }

            if (tok.len >= 2 and tok[0] == '/' and tok[1] == '/') {
                comment = tok;
                break;
            }

            if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') {
                comment = tok;
                break;
            }

            if (tok[0] == ';') break;

            if (std.mem.eql(u8, tok, "++")) {
                try modifiers.append(self.alloc, .{ .kind = .auto_inc_pk, .line_no = line.line_no });
                continue;
            }

            if (std.mem.eql(u8, tok, "+")) {
                try modifiers.append(self.alloc, .{ .kind = .auto_inc, .line_no = line.line_no });
                continue;
            }

            if (std.mem.eql(u8, tok, "*")) {
                try modifiers.append(self.alloc, .{ .kind = .not_null, .line_no = line.line_no });
                continue;
            }

            if (std.mem.eql(u8, tok, "!")) {
                try modifiers.append(self.alloc, .{ .kind = .primary_key, .line_no = line.line_no });
                continue;
            }

            if (tok[0] == '=' and tok.len > 1) {
                default_val = .{ .value = tok[1..], .line_no = line.line_no };
                continue;
            }

            if (tok[0] == '[') {
                // Collect tokens until ] for check constraint
                var check_str = try std.ArrayList(u8).initCapacity(self.alloc, 32);
                var needs_comma = false;
                i += 1;
                while (i < line.tokens.len and !std.mem.eql(u8, line.tokens[i], "]")) : (i += 1) {
                    if (needs_comma) try check_str.append(self.alloc, ',');
                    try check_str.appendSlice(self.alloc, line.tokens[i]);
                    needs_comma = true;
                }
                const check_expr = try check_str.toOwnedSlice(self.alloc);
                check = .{ .kind = classifyCheck(check_expr), .expr = check_expr, .line_no = line.line_no };
                continue;
            }

            // Skip standalone ] bracket
            if (std.mem.eql(u8, tok, "]")) continue;

            // Warn on unrecognized tokens (H4: better error messages)
            std.debug.print("warning: unrecognized token '{s}' in field '{s}' (line {d})\n", .{ tok, name, line.line_no });
        }

        // Validate ++ and + modifiers against type
        for (modifiers.items) |mod| {
            if (mod.kind == .auto_inc_pk or mod.kind == .auto_inc) {
                if (type_info == .none) continue; // suffix-inferred, OK
                const is_valid = switch (type_info) {
                    .simple => |s| (s.len == 1 and (s[0] == 'n' or s[0] == 'N' or s[0] == 't' or s[0] == 'd')),
                    .int_explicit => true,
                    else => false,
                };
                if (!is_valid) {
                    const kind_str = if (mod.kind == .auto_inc_pk) "++" else "+";
                    std.debug.print("warning: '{s}' {s} modifier invalid for this type (line {d}) — valid on: n, N, integer types, t, d\n", .{ name, kind_str, line.line_no });
                }
            }
        }

        return .{
            .name = name,
            .type_info = type_info,
            .modifiers = try modifiers.toOwnedSlice(self.alloc),
            .default_val = default_val,
            .check = check,
            .comment = comment,
            .line_no = line.line_no,
        };
    }

    fn tryParseType(tok: []const u8) ?TypeInfo {
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

    fn classifyCheck(expr: []const u8) CheckKind {
        if (std.mem.indexOfScalar(u8, expr, '>') != null or std.mem.indexOfScalar(u8, expr, '<') != null) {
            return .comparison;
        }
        if (std.mem.indexOfScalar(u8, expr, ',') != null) {
            // Check if it's a range (exactly 2 numeric values) or IN list
            var parts = std.mem.splitScalar(u8, expr, ',');
            const first = std.mem.trim(u8, parts.next() orelse "", " ");
            const second = std.mem.trim(u8, parts.next() orelse "", " ");
            const third = parts.next();
            // Range: exactly 2 parts, both numeric (no quotes)
            if (third == null and first.len > 0 and second.len > 0) {
                if (first[0] != '\'' and second[0] != '\'') {
                    return .range;
                }
            }
            return .in_list;
        }
        return .comparison;
    }

    fn parseFK(self: *Parser, line: tk.Line) !FkDecl {
        var field: []const u8 = "";
        var ref_table: []const u8 = "";
        var ref_field: []const u8 = "";
        var actions = try std.ArrayList(FkAction).initCapacity(self.alloc, 8);

        // Full form:  -> field -> table.field [action]
        // Shorthand:  -> field table.field [action]
        // Ultra:      -> table.field [action]          (infers field as {table}_id)
        // Ultra bare: -> table.field                   (infers field, no action)

        const tokens = line.tokens;

        // Determine which form we're in
        const has_double_arrow = tokens.len >= 4 and std.mem.eql(u8, tokens[2], "->");
        const has_ref_dot = tokens.len >= 3 and std.mem.indexOfScalar(u8, tokens[2], '.') != null;
        const ultra_shorthand = !has_double_arrow and tokens.len >= 2 and std.mem.indexOfScalar(u8, tokens[1], '.') != null;

        if (has_double_arrow) {
            // Full form: -> field -> table.field [action]
            field = try self.alloc.dupe(u8, line.tokens[1]);
            const ref = line.tokens[3];
            if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
                ref_table = try self.alloc.dupe(u8, ref[0..dot]);
                ref_field = try self.alloc.dupe(u8, ref[dot + 1 ..]);
            }
            var i: usize = 4;
            while (i < line.tokens.len) : (i += 1) {
                const tok = line.tokens[i];
                if (std.mem.eql(u8, tok, "[")) {
                    try self.parseFKActions(line, &actions, &i);
                } else if (!std.mem.eql(u8, tok, "]")) {
                    // C3: Warn on FK action outside brackets
                    const action_token = try self.resolveFkAbbreviation(tok);
                    if (action_token) |resolved| {
                        _ = resolved;
                        std.debug.print("warning: FK action '{s}' outside brackets — use [{s}] syntax (line {d})\n", .{ tok, tok, line.line_no });
                    }
                }
            }
        } else if (has_ref_dot) {
            // Shorthand: -> field table.field [action]
            field = try self.alloc.dupe(u8, line.tokens[1]);
            const ref = line.tokens[2];
            if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
                ref_table = try self.alloc.dupe(u8, ref[0..dot]);
                ref_field = try self.alloc.dupe(u8, ref[dot + 1 ..]);
            }
            var i: usize = 3;
            while (i < line.tokens.len) : (i += 1) {
                const tok = line.tokens[i];
                if (std.mem.eql(u8, tok, "[")) {
                    try self.parseFKActions(line, &actions, &i);
                } else if (!std.mem.eql(u8, tok, "]")) {
                    std.debug.print("warning: FK action '{s}' outside brackets — use [{s}] syntax (line {d})\n", .{ tok, tok, line.line_no });
                }
            }
        } else if (ultra_shorthand) {
            // Ultra: -> table.field [action]  (infer local field as {table}_id)
            const ref = line.tokens[1];
            if (std.mem.indexOfScalar(u8, ref, '.')) |dot| {
                ref_table = try self.alloc.dupe(u8, ref[0..dot]);
                ref_field = try self.alloc.dupe(u8, ref[dot + 1 ..]);
                // Infer local field: {table}_id
                field = try std.fmt.allocPrint(self.alloc, "{s}_id", .{ref_table});
            }
            var i: usize = 2;
            while (i < line.tokens.len) : (i += 1) {
                const tok = line.tokens[i];
                if (std.mem.eql(u8, tok, "[")) {
                    try self.parseFKActions(line, &actions, &i);
                } else if (!std.mem.eql(u8, tok, "]")) {
                    std.debug.print("warning: FK action '{s}' outside brackets — use [{s}] syntax (line {d})\n", .{ tok, tok, line.line_no });
                }
            }
        }

        return .{
            .field = field,
            .ref_table = ref_table,
            .ref_field = ref_field,
            .actions = try actions.toOwnedSlice(self.alloc),
            .line_no = line.line_no,
        };
    }

    fn parseFKActions(self: *Parser, line: tk.Line, actions: *std.ArrayList(FkAction), i: *usize) !void {
        var action_str = try std.ArrayList(u8).initCapacity(self.alloc, 32);
        var needs_space = false;
        i.* += 1;
        while (i.* < line.tokens.len and !std.mem.eql(u8, line.tokens[i.*], "]")) : (i.* += 1) {
            if (needs_space) try action_str.append(self.alloc, ' ');
            try action_str.appendSlice(self.alloc, line.tokens[i.*]);
            needs_space = true;
        }
        const inner = try action_str.toOwnedSlice(self.alloc);
        var action_it = std.mem.splitScalar(u8, inner, ',');
        while (action_it.next()) |a| {
            const trimmed = std.mem.trim(u8, a, " ");
            if (trimmed.len == 0) continue;
            // M3: Resolve FK action abbreviations
            const resolved = try self.resolveFkAbbreviation(trimmed);
            const action_text = resolved orelse trimmed;
            if (std.mem.startsWith(u8, action_text, "UPDATE ")) {
                try actions.append(self.alloc, .{ .on_update = try self.alloc.dupe(u8, action_text[7..]) });
            } else {
                try actions.append(self.alloc, .{ .on_delete = try self.alloc.dupe(u8, action_text) });
            }
        }
    }

    fn resolveFkAbbreviation(self: *Parser, action: []const u8) !?[]const u8 {
        // M3: FK action abbreviations
        if (std.mem.eql(u8, action, "C")) return "CASCADE";
        if (std.mem.eql(u8, action, "SN")) return "SET NULL";
        if (std.mem.eql(u8, action, "NA")) return "NO ACTION";
        if (std.mem.eql(u8, action, "R")) return "RESTRICT";
        // Check abbreviated UPDATE variants
        if (std.mem.eql(u8, action, "U C")) return "UPDATE CASCADE";
        if (std.mem.eql(u8, action, "U SN")) return "UPDATE SET NULL";
        if (std.mem.eql(u8, action, "U NA")) return "UPDATE NO ACTION";
        if (std.mem.eql(u8, action, "U R")) return "UPDATE RESTRICT";
        // Handle compound actions like "C, U C"
        if (std.mem.indexOfScalar(u8, action, ',') != null) {
            var result = try std.ArrayList(u8).initCapacity(self.alloc, 64);
            var part_it = std.mem.splitScalar(u8, action, ',');
            var first = true;
            while (part_it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                if (trimmed.len == 0) continue;
                if (!first) try result.append(self.alloc, ',');
                first = false;
                const resolved = try self.resolveFkAbbreviation(trimmed);
                try result.appendSlice(self.alloc, resolved orelse trimmed);
            }
            return try result.toOwnedSlice(self.alloc);
        }
        return null;
    }

    fn parseIndex(self: *Parser, line: tk.Line) !IndexDecl {
        var kind: IndexType = .regular;
        var name: []const u8 = "";
        var fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 8);

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
            // Peek ahead: if next token is NOT "(" or end, this is shorthand form
            // e.g., "@ name" where "name" is a field, not an index name
            const is_shorthand = (idx + 1 >= tokens.len) or
                !std.mem.eql(u8, tokens[idx + 1], "(");

            if (is_shorthand) {
                // Shorthand: @ field → auto-generate index name with prefix (single-column only)
                const field = try self.alloc.dupe(u8, tokens[idx]);
                try fields.append(self.alloc, field);
                idx += 1;
                // Reject multi-field shorthand — composite indexes require full form
                if (idx < tokens.len and !std.mem.eql(u8, tokens[idx], "(")) {
                    std.debug.print("warning: shorthand index is single-column only, use full form for composite indexes (line {d})\n", .{line.line_no});
                }
                // Auto-generate name: idx_ / uk_ / ft_ + field
                const prefix = switch (kind) {
                    .regular => "idx_",
                    .unique => "uk_",
                    .fulltext => "ft_",
                };
                name = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, field });
                return .{
                    .kind = kind,
                    .name = name,
                    .fields = try fields.toOwnedSlice(self.alloc),
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
                const field_name = if (tok.len > 1 and tok[tok.len - 1] == ')')
                    tok[0 .. tok.len - 1]
                else
                    tok;
                try fields.append(self.alloc, try self.alloc.dupe(u8, field_name));
            }
        }

        return .{
            .kind = kind,
            .name = name,
            .fields = try fields.toOwnedSlice(self.alloc),
            .line_no = line.line_no,
        };
    }
};
