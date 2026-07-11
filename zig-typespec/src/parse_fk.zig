// ─── Foreign Key Parsing ──────────────────────────────────────
// Extracted from parser.zig for modularity.

const std = @import("std");
const ast_mod = @import("ast.zig");
const diag = @import("diagnostic.zig");
const tk = @import("tokenizer.zig");
const FkDecl = ast_mod.FkDecl;
const FkAction = ast_mod.FkAction;
const FkActionType = ast_mod.FkActionType;
const FkActionTrigger = ast_mod.FkActionTrigger;

pub const InlineFkResult = struct {
    fk: FkDecl,
    end_idx: usize,
};

pub fn parseInlineFK(
    alloc: std.mem.Allocator,
    tokens: []const []const u8,
    idx: usize,
    field_name: []const u8,
    raw: []const u8,
    trimmed: []const u8,
    line_no: usize,
) !InlineFkResult {
    // Inline FK: > table.field or > table(id)
    // Reconstruct the FK line for parseFK
    var fk_tokens = try std.ArrayList([]const u8).initCapacity(alloc, 8);
    try fk_tokens.append(alloc, ">");
    var i = idx;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        if (tok.len == 1 and (tok[0] == ':' or tok[0] == '-' or tok[0] == ';')) break;
        try fk_tokens.append(alloc, tok);
    }
    // If no explicit ref field, infer from field_name
    const has_ref = for (tokens[idx..]) |t| {
        if (std.mem.eql(u8, t, "(") or std.mem.eql(u8, t, ".")) break true;
    } else false;
    if (!has_ref) {
        // Shorthand: > table  →  > table(field_name)
        // Find the table name (last token before potential action tokens)
        if (fk_tokens.items.len >= 2) {
            _ = fk_tokens.items[1]; // table name already captured
            try fk_tokens.append(alloc, "(");
            try fk_tokens.append(alloc, field_name);
            try fk_tokens.append(alloc, ")");
        }
    }
    const synthetic_line = tk.Line{
        .line_type = .FK,
        .tokens = try fk_tokens.toOwnedSlice(alloc),
        .raw = raw,
        .trimmed = trimmed,
        .line_no = line_no,
    };
    // We need Parser to call parseFK, but we can't import it here.
    // Instead, call the standalone parseFK function.
    const fk = try parseFK(alloc, synthetic_line);
    return .{ .fk = fk, .end_idx = i };
}

pub fn parseFK(alloc: std.mem.Allocator, line: tk.Line) !FkDecl {
    // FK format: > field_list ref_table(ref_field_list) [ON DELETE action] [ON UPDATE action]
    const tokens = line.tokens;
    if (tokens.len < 2) {
        diag.printDiagnostic(.{
            .severity = .@"error",
            .line_no = line.line_no,
            .col = if (tokens.len > 0) diag.tokenColumn(tokens[0], line.raw) else null,
            .message = "FOREIGN KEY requires fields and reference",
            .source_line = line.raw,
        });
        return error.ParseError;
    }

    // Parse local fields (between > and ref_table)
    var fields = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    var ref_table: []const u8 = "";
    var ref_fields_start: usize = 0;
    var i: usize = 1; // skip >

    // Collect field names until we hit the ref table
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        if (std.mem.eql(u8, tok, "(") or std.mem.eql(u8, tok, ".") or std.mem.eql(u8, tok, ")")) {
            // Found ref syntax — the previous token is the ref table
            if (i > 1) {
                ref_table = tokens[i - 1];
                ref_fields_start = i;
            }
            break;
        }
        if (tok.len == 1 and (tok[0] == ':' or tok[0] == ';' or tok[0] == '-')) break;
        // Skip commas
        if (std.mem.eql(u8, tok, ",")) continue;
        try fields.append(alloc, tok);
    }

    // If we didn't find ( or ., the last collected token is the ref table
    if (ref_table.len == 0 and fields.items.len > 0) {
        ref_table = fields.pop().?;
        ref_fields_start = i;
    }

    // Parse ref fields
    var ref_fields = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    if (ref_fields_start < tokens.len and std.mem.eql(u8, tokens[ref_fields_start], "(")) {
        i = ref_fields_start + 1;
        while (i < tokens.len) : (i += 1) {
            const tok = tokens[i];
            if (std.mem.eql(u8, tok, ")")) { i += 1; break; }
            if (std.mem.eql(u8, tok, ",")) continue;
            try ref_fields.append(alloc, tok);
        }
    } else {
        // Default ref field: id
        try ref_fields.append(alloc, "id");
    }

    // Infer ref_table from field name if not explicit (e.g., user_id → user)
    if (ref_table.len == 0 and fields.items.len == 1) {
        const fname = fields.items[0];
        if (std.mem.endsWith(u8, fname, "_id") and fname.len > 3) {
            ref_table = try std.fmt.allocPrint(alloc, "{s}", .{fname[0 .. fname.len - 3]});
        }
    }

    // If no explicit ref fields, infer from ref_table: ref_table + "_id" pattern
    if (ref_fields.items.len == 0) {
        // Default: id
        try ref_fields.append(alloc, "id");
    }

    // Parse optional ON DELETE/ON UPDATE actions
    const actions = try parseFKActions(alloc, tokens, i);

    return .{
        .fields = try fields.toOwnedSlice(alloc),
        .ref_table = ref_table,
        .ref_fields = try ref_fields.toOwnedSlice(alloc),
        .actions = actions,
        .line_no = line.line_no,
    };
}

pub fn parseFKActions(alloc: std.mem.Allocator, tokens: []const []const u8, start: usize) ![]const FkAction {
    var actions = try std.ArrayList(FkAction).initCapacity(alloc, 2);
    var i = start;
    while (i + 2 < tokens.len) : (i += 1) {
        if (std.mem.eql(u8, tokens[i], "ON")) {
            const trigger_str = tokens[i + 1];
            const action_str = tokens[i + 2];
            const trigger: FkActionTrigger = if (std.mem.eql(u8, trigger_str, "DELETE"))
                .on_delete
            else if (std.mem.eql(u8, trigger_str, "UPDATE"))
                .on_update
            else
                continue;
            const action: FkActionType = if (std.mem.eql(u8, action_str, "CASCADE"))
                .cascade
            else if (std.mem.eql(u8, action_str, "SET") and i + 3 < tokens.len and std.mem.eql(u8, tokens[i + 3], "NULL"))
                .set_null
            else
                continue;
            try actions.append(alloc, .{ .trigger = trigger, .action = action });
            if (std.mem.eql(u8, action_str, "SET")) i += 1; // skip NULL
        }
    }
    return try actions.toOwnedSlice(alloc);
}
