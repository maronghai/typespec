const std = @import("std");
const tk = @import("tokenizer.zig");
const diag = @import("diagnostic.zig");
const ast_mod = @import("ast.zig");
const parse_fk = @import("parse_fk.zig");
const parse_check = @import("parse_check.zig");
const Field = ast_mod.Field;
const TypeInfo = ast_mod.TypeInfo;
const Modifier = ast_mod.Modifier;
const ModifierType = ast_mod.ModifierType;
const DefaultVal = ast_mod.DefaultVal;
const CheckConstraint = ast_mod.CheckConstraint;
const FkDecl = ast_mod.FkDecl;

pub const FusedTypeResult = struct {
    type_info: ?TypeInfo = null,
    modifier: ?Modifier = null,
    default_val: ?DefaultVal = null,
};

pub const ModifierResult = struct {
    modifier: Modifier,
    end_idx: usize,
};

pub const EnumTypeResult = struct {
    type_info: TypeInfo,
    end_idx: usize,
};

/// Parse fused tokens like `n++`, `s128*`, `nu`, `*=0`, `t+`.
/// Returns null if the token is not a fused type+modifier form.
pub fn parseFusedTypeModifier(tok: []const u8, line_no: usize) ?FusedTypeResult {
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
    if (last == 'u' and tok.len >= 2 and tok[tok.len - 2] != '+') {
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

/// Parse type token: n, N, s, S, m, M, b, B, j, d, t, s128, 16,2, 11
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

/// Parse standalone modifiers: `++`, `+`, `*`, `!`, `@`, `@u`.
pub fn parseStandaloneModifier(tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize) ?ModifierResult {
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

/// Parse `e(M,F,X)` or `e('a','b')` enum types.
/// `tok` must be `"e"` and `idx` must point to it.
pub fn parseEnumType(alloc: std.mem.Allocator, tokens: []const []const u8, idx: usize, raw: []const u8, line_no: usize) !EnumTypeResult {
    const paren_col = diag.tokenColumn(tokens[idx + 1], raw);
    var i = idx + 2; // skip e and (
    var enum_vals = try std.ArrayList([]const u8).initCapacity(alloc, 8);
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
                        try enum_vals.append(alloc, try alloc.dupe(u8, val));
                    }
                    rest = rest[cp + 1 ..];
                } else {
                    if (rest.len > 0) {
                        var val = rest;
                        if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
                            val = val[1 .. val.len - 1];
                        }
                        try enum_vals.append(alloc, try alloc.dupe(u8, val));
                    }
                    break;
                }
            }
        } else {
            var val = val_tok;
            if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
                val = val[1 .. val.len - 1];
            }
            try enum_vals.append(alloc, try alloc.dupe(u8, val));
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
        .type_info = .{ .enum_type = try enum_vals.toOwnedSlice(alloc) },
        .end_idx = i + 1, // +1 to skip past ')'
    };
}

/// Parse a single field declaration line.
pub fn parseField(alloc: std.mem.Allocator, line: tk.Line) !Field {
    if (line.tokens.len == 0) return error.EmptyField;

    const name = try alloc.dupe(u8, line.tokens[0]);
    var type_info: TypeInfo = .none;
    var modifiers = try std.ArrayList(Modifier).initCapacity(alloc, 8);
    var default_val: ?DefaultVal = null;
    var check: ?CheckConstraint = null;
    var inline_fk: ?FkDecl = null;
    var comment: ?[]const u8 = null;

    var i: usize = 1;
    while (i < line.tokens.len) {
        const tok = line.tokens[i];

        // 1. Fused type+modifier: n++, s128*, *=0, nu, t+
        if (parseFusedTypeModifier(tok, line.line_no)) |result| {
            if (result.type_info) |ti| {
                // Only set type and add modifier if type wasn't already set
                if (type_info == .none) {
                    type_info = ti;
                    if (result.modifier) |mod| try modifiers.append(alloc, mod);
                }
            } else {
                // No type (e.g. *=0) — always apply modifier + default
                if (result.modifier) |mod| try modifiers.append(alloc, mod);
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
                try modifiers.append(alloc, .{ .kind = .unsigned, .line_no = line.line_no });
                i += 1;
                continue;
            }
        }

        // 3. Enum type: e(M,F,X) or e('admin','user')
        if (type_info == .none and std.mem.eql(u8, tok, "e") and i + 1 < line.tokens.len and std.mem.eql(u8, line.tokens[i + 1], "(")) {
            const result = try parseEnumType(alloc, line.tokens, i, line.raw, line.line_no);
            type_info = result.type_info;
            i = result.end_idx;
            continue;
        }

        // 4. Comments: : (column), -- (SQL), ; (spec)
        if (tok.len >= 1 and tok[0] == ':') { comment = tok; break; }
        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') { comment = tok; break; }
        if (tok[0] == ';') break;

        // 5. Standalone modifiers: ++, +, *, !, @, @u
        if (parseStandaloneModifier(line.tokens, i, line.raw, line.line_no)) |result| {
            try modifiers.append(alloc, result.modifier);
            i = result.end_idx;
            continue;
        }

        // 6. Inline FK: > table.field or table.field
        if (std.mem.eql(u8, tok, ">") or
            (std.mem.indexOfScalar(u8, tok, '.') != null and tok[0] != '[' and tok[0] != '=' and tok[0] != '/' and tok[0] != '-' and tok[0] != ';'))
        {
            const result = try parse_fk.parseInlineFk(alloc, line.tokens, i, name, line.raw, line.trimmed, line.line_no);
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
            if (try parse_check.parseCheckConstraint(alloc, line.tokens, i, line.raw, line.line_no)) |result| {
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
        .modifiers = try modifiers.toOwnedSlice(alloc),
        .default_val = default_val,
        .check = check,
        .fk = inline_fk,
        .comment = comment,
        .line_no = line.line_no,
        .loc = null,
    };
}
