const std = @import("std");
const sp = @import("sql_parser.zig");
const common = @import("sql_parser_common.zig");
const SqlTable = common.SqlTable;
const SqlForeignKey = common.SqlForeignKey;

// ─── ALTER TABLE Parsing ────────────────────────────────────────

pub fn parseAlterTable(self: *sp.SqlParser, tables: []SqlTable) !void {
    // ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ...
    self.skipSpacesAndNewlines();
    if (self.matchKeyword("TABLE")) {
        self.skipSpaces();
        const tbl_name = try self.parseIdentifier();
        self.skipSpaces();
        if (self.matchKeyword("ADD")) {
            self.skipSpaces();
            // Optional: CONSTRAINT constraint_name
            if (self.matchKeyword("CONSTRAINT")) {
                self.skipSpaces();
                _ = try self.parseIdentifier(); // constraint name
                self.skipSpaces();
            }
            if (self.matchKeyword("FOREIGN")) {
                // ALTER TABLE t ADD [CONSTRAINT fk] FOREIGN KEY (cols) REFERENCES ref (cols) [actions]
                self.skipSpaces();
                const fk = try self.parseForeignKey();
                // Find the table and append the FK by creating a new slice
                for (tables) |*tbl| {
                    if (std.mem.eql(u8, tbl.name, tbl_name)) {
                        const new_len = tbl.foreign_keys.len + 1;
                        var new_fks = try self.alloc.alloc(SqlForeignKey, new_len);
                        for (tbl.foreign_keys, 0..) |old_fk, i| new_fks[i] = old_fk;
                        new_fks[new_len - 1] = fk;
                        tbl.foreign_keys = new_fks;
                        break;
                    }
                }
            } else {
                // Other ALTER TABLE ADD (column, index, etc.) — skip
                self.skipToSemicolon();
            }
        } else {
            // ALTER TABLE ... (non-ADD) — skip
            self.skipToSemicolon();
        }
    } else {
        self.skipToSemicolon();
    }
}
