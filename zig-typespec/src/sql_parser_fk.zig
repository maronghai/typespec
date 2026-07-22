const std = @import("std");
const sp = @import("sql_parser.zig");
const common = @import("sql_parser_common.zig");
const FkAction = common.FkAction;
const FkActionTrigger = common.FkActionTrigger;
const FkActionType = common.FkActionType;
const SqlForeignKey = common.SqlForeignKey;

// ─── FOREIGN KEY Parsing ──────────────────────────────────────

pub fn parseForeignKey(self: *sp.SqlParser) !SqlForeignKey {
    self.expectKeyword("FOREIGN");
    self.skipSpaces();
    self.expectKeyword("KEY");
    self.skipSpaces();
    var fk_fields = (try self.parseParenFieldList()).fields;
    self.skipSpaces();
    self.expectKeyword("REFERENCES");
    self.skipSpaces();
    const ref_table = try self.parseIdentifier();
    self.skipSpaces();
    var fk_ref_fields = (try self.parseParenFieldList()).fields;

    var actions = try std.ArrayList(FkAction).initCapacity(self.alloc, 4);
    while (true) {
        self.skipSpaces();
        if (self.matchKeyword("ON")) {
            self.skipSpaces();
            const trigger: FkActionTrigger = blk: {
                if (self.matchKeyword("DELETE")) break :blk .on_delete;
                if (self.matchKeyword("UPDATE")) break :blk .on_update;
                self.reportError("expected DELETE or UPDATE after ON in foreign key action", .{});
                return error.ExpectedDeleteOrUpdate;
            };
            self.skipSpaces();
            const act: FkActionType = blk: {
                if (self.matchKeyword("CASCADE")) break :blk .cascade;
                if (self.matchKeyword("RESTRICT")) break :blk .restrict;
                if (self.matchKeyword("NO")) {
                    self.skipSpaces();
                    if (self.matchKeyword("ACTION")) break :blk .no_action;
                }
                if (self.matchKeyword("SET")) {
                    self.skipSpaces();
                    if (self.matchKeyword("NULL")) break :blk .set_null;
                    if (self.matchKeyword("DEFAULT")) break :blk .set_default;
                }
                self.reportError("expected CASCADE, RESTRICT, NO ACTION, SET NULL, or SET DEFAULT in foreign key action", .{});
                return error.ExpectedFkAction;
            };
            try actions.append(self.alloc, .{ .trigger = trigger, .action = act });
        } else {
            break;
        }
    }

    return .{
        .fields = try fk_fields.toOwnedSlice(self.alloc),
        .ref_table = ref_table,
        .ref_fields = try fk_ref_fields.toOwnedSlice(self.alloc),
        .actions = try actions.toOwnedSlice(self.alloc),
    };
}
