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

pub const Ast = struct {
    schema: ?Schema,
    templates: []const Template,
    tables: []const Table,
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
                .SQLComment => {},
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
            if (!std.mem.eql(u8, line.tokens[1], "extends")) {
                name = try self.alloc.dupe(u8, line.tokens[1]);
            }
        }
        for (line.tokens, 0..) |tok, i| {
            if (std.mem.eql(u8, tok, "extends") and i + 1 < line.tokens.len) {
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
        if (tokens.len >= 2) {
            if (tokens[1].len >= 2 and !(tokens[1][0] == '/' and tokens[1][1] == '/')) {
                template_ref = try self.alloc.dupe(u8, tokens[1]);
                if (tokens.len >= 3) {
                    table_name = try self.alloc.dupe(u8, tokens[2]);
                    if (tokens.len >= 4) {
                        comment = try self.alloc.dupe(u8, tokens[3]);
                    }
                }
            } else {
                table_name = try self.alloc.dupe(u8, tokens[1]);
                if (tokens.len >= 3) {
                    comment = try self.alloc.dupe(u8, tokens[2]);
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

    fn parseCheck(self: *Parser, tok: []const u8, line_no: usize) !CheckConstraint {
        if (tok.len < 3) return error.InvalidCheckConstraint;
        const inner = tok[1 .. tok.len - 1];
        _ = self;
        return .{ .kind = classifyCheck(inner), .expr = inner, .line_no = line_no };
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

        // Expected: ["->", field, "->", "table.field", ...]
        // If syntax doesn't match (e.g., composite FK), return empty FK
        if (line.tokens.len >= 4 and std.mem.eql(u8, line.tokens[2], "->")) {
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
                    // Collect tokens until ] (space-separated)
                    var action_str = try std.ArrayList(u8).initCapacity(self.alloc, 32);
                    var needs_space = false;
                    i += 1;
                    while (i < line.tokens.len and !std.mem.eql(u8, line.tokens[i], "]")) : (i += 1) {
                        if (needs_space) try action_str.append(self.alloc, ' ');
                        try action_str.appendSlice(self.alloc, line.tokens[i]);
                        needs_space = true;
                    }
                    const inner = try action_str.toOwnedSlice(self.alloc);
                    var action_it = std.mem.splitScalar(u8, inner, ',');
                    while (action_it.next()) |a| {
                        const trimmed = std.mem.trim(u8, a, " ");
                        if (trimmed.len == 0) continue;
                        if (std.mem.startsWith(u8, trimmed, "UPDATE ")) {
                            try actions.append(self.alloc, .{ .on_update = try self.alloc.dupe(u8, trimmed[7..]) });
                        } else {
                            try actions.append(self.alloc, .{ .on_delete = try self.alloc.dupe(u8, trimmed) });
                        }
                    }
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

    fn parseIndex(self: *Parser, line: tk.Line) !IndexDecl {
        var kind: IndexType = .regular;
        var name: []const u8 = "";
        var fields = try std.ArrayList([]const u8).initCapacity(self.alloc, 8);

        const tokens = line.tokens;
        var idx: usize = 1;

        if (idx < tokens.len) {
            if (std.mem.eql(u8, tokens[idx], "!")) {
                kind = .unique;
                idx += 1;
            } else if (std.mem.eql(u8, tokens[idx], "f")) {
                kind = .fulltext;
                idx += 1;
            }
        }

        if (idx < tokens.len) {
            name = try self.alloc.dupe(u8, tokens[idx]);
            idx += 1;
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
