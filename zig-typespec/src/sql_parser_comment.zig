const std = @import("std");
const sp = @import("sql_parser.zig");
const common = @import("sql_parser_common.zig");
const SqlTable = common.SqlTable;

// ─── COMMENT ON Parsing ─────────────────────────────────────────

pub fn parseCommentOn(self: *sp.SqlParser, tables: []SqlTable) !void {
    // PG: COMMENT ON TABLE/COLUMN ... IS 'text'
    self.skipSpacesAndNewlines();
    if (self.matchKeyword("ON")) {
        self.skipSpacesAndNewlines();
        if (self.matchKeyword("TABLE")) {
            self.skipSpaces();
            const full_ident = try self.parseDottedIdentifier();
            // Match against full table name (may include schema prefix)
            self.skipSpaces();
            if (self.matchKeyword("IS")) {
                self.skipSpaces();
                const cmt = try self.parseStringLiteral();
                for (tables) |*tbl| {
                    if (std.mem.eql(u8, tbl.name, full_ident)) {
                        tbl.comment = cmt;
                        break;
                    }
                }
            }
        } else if (self.matchKeyword("COLUMN")) {
            self.skipSpaces();
            // PG: "schema"."table"."column" or "table"."column"
            const full_ident = try self.parseDottedIdentifier();
            // Split at last dot: tbl=everything_before, col=last_part
            var tbl_name: []const u8 = full_ident;
            var col_name: []const u8 = "";
            if (std.mem.lastIndexOfScalar(u8, full_ident, '.')) |dot_pos| {
                tbl_name = full_ident[0..dot_pos];
                col_name = full_ident[dot_pos + 1 ..];
            }
            self.skipSpaces();
            if (self.matchKeyword("IS")) {
                self.skipSpaces();
                const cmt = try self.parseStringLiteral();
                for (tables) |*tbl| {
                    if (std.mem.eql(u8, tbl.name, tbl_name)) {
                        for (tbl.columns) |*col| {
                            if (col_name.len > 0 and std.mem.eql(u8, col.name, col_name)) {
                                col.comment = cmt;
                                break;
                            }
                        }
                        break;
                    }
                }
            } else {
                self.skipToSemicolon();
            }
        } else {
            self.skipToSemicolon();
        }
    } else {
        self.skipToSemicolon();
    }
}
