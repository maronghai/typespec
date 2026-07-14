const std = @import("std");
const sql_parser = @import("sql_parser.zig");
const SqlParser = sql_parser.SqlParser;
const IndexKind = sql_parser.IndexKind;
const FkActionType = sql_parser.FkActionType;
const FkActionTrigger = sql_parser.FkActionTrigger;

test "parse basic CREATE TABLE" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE "user" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  "name" TEXT NOT NULL
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .sqlite);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 1), result.schema.tables.len);
    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("user", tbl.name);
    try std.testing.expectEqual(@as(usize, 2), tbl.columns.len);
    try std.testing.expectEqualStrings("id", tbl.columns[0].name);
    try std.testing.expectEqualStrings("INTEGER", tbl.columns[0].type_sql);
    try std.testing.expect(tbl.columns[0].primary_key);
    try std.testing.expect(tbl.columns[0].auto_increment);
    try std.testing.expectEqualStrings("name", tbl.columns[1].name);
    try std.testing.expectEqualStrings("TEXT", tbl.columns[1].type_sql);
    try std.testing.expect(!tbl.columns[1].nullable);
}

test "parse multi-column table with modifiers" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE `orders` (
        \\  `id` int NOT NULL AUTO_INCREMENT,
        \\  `amount` decimal(10,2) UNSIGNED DEFAULT 0.00,
        \\  `created` timestamp DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        \\  `status` enum('pending','active','closed') DEFAULT 'pending',
        \\  PRIMARY KEY (`id`)
        \\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='order table';
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("orders", tbl.name);
    try std.testing.expectEqualStrings("InnoDB", tbl.engine.?);
    try std.testing.expectEqualStrings("utf8mb4", tbl.charset.?);
    try std.testing.expectEqualStrings("order table", tbl.comment.?);
    try std.testing.expectEqual(@as(usize, 4), tbl.columns.len);

    try std.testing.expectEqualStrings("int", tbl.columns[0].type_sql);
    try std.testing.expect(tbl.columns[0].auto_increment);
    try std.testing.expect(!tbl.columns[0].nullable);

    try std.testing.expectEqualStrings("decimal(10,2)", tbl.columns[1].type_sql);
    try std.testing.expect(tbl.columns[1].unsigned);
    try std.testing.expectEqualStrings("0.00", tbl.columns[1].default_val.?);

    try std.testing.expect(tbl.columns[2].on_update_current_timestamp);
    try std.testing.expectEqualStrings("CURRENT_TIMESTAMP", tbl.columns[2].default_val.?);

    try std.testing.expectEqualStrings("enum('pending','active','closed')", tbl.columns[3].type_sql);
    try std.testing.expectEqualStrings("pending", tbl.columns[3].default_val.?);

    try std.testing.expectEqual(@as(usize, 1), tbl.indexes.len);
    try std.testing.expectEqual(IndexKind.primary_key, tbl.indexes[0].kind);
}

test "parse VARCHAR and parameterized types" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  a varchar(255) NOT NULL,
        \\  b char(10),
        \\  c text,
        \\  d int(11) UNSIGNED
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("varchar(255)", tbl.columns[0].type_sql);
    try std.testing.expectEqualStrings("char(10)", tbl.columns[1].type_sql);
    try std.testing.expectEqualStrings("text", tbl.columns[2].type_sql);
    try std.testing.expectEqualStrings("int(11)", tbl.columns[3].type_sql);
    try std.testing.expect(tbl.columns[3].unsigned);
}

test "parse FOREIGN KEY with actions" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE `order` (
        \\  `id` int NOT NULL AUTO_INCREMENT,
        \\  `user_id` int NOT NULL,
        \\  PRIMARY KEY (`id`),
        \\  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE ON UPDATE SET NULL
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            for (tbl.indexes) |idx| alloc.free(idx.fields);
            alloc.free(tbl.indexes);
            for (tbl.foreign_keys) |fk| {
                alloc.free(fk.fields);
                alloc.free(fk.ref_fields);
                alloc.free(fk.actions);
            }
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 1), tbl.foreign_keys.len);
    const fk = tbl.foreign_keys[0];
    try std.testing.expectEqual(@as(usize, 1), fk.fields.len);
    try std.testing.expectEqualStrings("user_id", fk.fields[0]);
    try std.testing.expectEqualStrings("user", fk.ref_table);
    try std.testing.expectEqualStrings("id", fk.ref_fields[0]);
    try std.testing.expectEqual(@as(usize, 2), fk.actions.len);
    try std.testing.expectEqual(FkActionTrigger.on_delete, fk.actions[0].trigger);
    try std.testing.expectEqual(FkActionType.cascade, fk.actions[0].action);
    try std.testing.expectEqual(FkActionTrigger.on_update, fk.actions[1].trigger);
    try std.testing.expectEqual(FkActionType.set_null, fk.actions[1].action);
}

test "parse FOREIGN KEY composite fields" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE order_item (
        \\  order_id int NOT NULL,
        \\  product_id int NOT NULL,
        \\  quantity int DEFAULT 1,
        \\  FOREIGN KEY (order_id, product_id) REFERENCES order_product(order_id, product_id)
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            for (tbl.indexes) |idx| alloc.free(idx.fields);
            alloc.free(tbl.indexes);
            for (tbl.foreign_keys) |fk| {
                alloc.free(fk.fields);
                alloc.free(fk.ref_fields);
                alloc.free(fk.actions);
            }
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const fk = result.schema.tables[0].foreign_keys[0];
    try std.testing.expectEqual(@as(usize, 2), fk.fields.len);
    try std.testing.expectEqualStrings("order_id", fk.fields[0]);
    try std.testing.expectEqualStrings("product_id", fk.fields[1]);
    try std.testing.expectEqualStrings("order_product", fk.ref_table);
    try std.testing.expectEqual(@as(usize, 2), fk.ref_fields.len);
}

test "parse CREATE INDEX standalone" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  id int NOT NULL,
        \\  name varchar(100),
        \\  email varchar(255)
        \\);
        \\CREATE INDEX idx_name ON t (name);
        \\CREATE UNIQUE INDEX uk_email ON t (email);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            for (tbl.indexes) |idx| {
                alloc.free(idx.fields);
                alloc.free(idx.name);
            }
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 2), tbl.indexes.len);
    try std.testing.expectEqual(IndexKind.regular, tbl.indexes[0].kind);
    try std.testing.expectEqualStrings("idx_name", tbl.indexes[0].name);
    try std.testing.expectEqual(@as(usize, 1), tbl.indexes[0].fields.len);
    try std.testing.expectEqualStrings("name", tbl.indexes[0].fields[0]);
    try std.testing.expectEqual(IndexKind.unique, tbl.indexes[1].kind);
    try std.testing.expectEqualStrings("uk_email", tbl.indexes[1].name);
}

test "parse PG CREATE INDEX composite" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (id int, a text, b text);
        \\CREATE INDEX idx复合 ON t (a, b DESC);
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            for (tbl.indexes) |idx| {
                alloc.free(idx.fields);
                alloc.free(idx.name);
            }
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 1), tbl.indexes.len);
    try std.testing.expectEqual(IndexKind.regular, tbl.indexes[0].kind);
    try std.testing.expectEqual(@as(usize, 2), tbl.indexes[0].fields.len);
    try std.testing.expectEqualStrings("a", tbl.indexes[0].fields[0]);
    try std.testing.expectEqualStrings("b", tbl.indexes[0].fields[1]);
    try std.testing.expectEqual(@as(usize, 2), tbl.indexes[0].descending.len);
    try std.testing.expect(!tbl.indexes[0].descending[0]);
    try std.testing.expect(tbl.indexes[0].descending[1]);
}

test "COMMENT ON TABLE" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE "user" (id int, name text);
        \\COMMENT ON TABLE "user" IS 'The user table';
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 1), result.schema.tables.len);
    try std.testing.expectEqualStrings("The user table", result.schema.tables[0].comment.?);
}

test "COMMENT ON COLUMN" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE "t" (id int, name text);
        \\COMMENT ON COLUMN "t"."name" IS 'Display name';
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const col = result.schema.tables[0].columns[1];
    try std.testing.expectEqualStrings("name", col.name);
    try std.testing.expectEqualStrings("Display name", col.comment.?);
}

test "PG serial normalization" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  id serial,
        \\  big_id bigserial,
        \\  regular int
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("integer", tbl.columns[0].type_sql);
    try std.testing.expect(tbl.columns[0].auto_increment);
    try std.testing.expectEqualStrings("bigint", tbl.columns[1].type_sql);
    try std.testing.expect(tbl.columns[1].auto_increment);
    try std.testing.expectEqualStrings("int", tbl.columns[2].type_sql);
    try std.testing.expect(!tbl.columns[2].auto_increment);
}

test "PG GENERATED ALWAYS AS IDENTITY" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const col = result.schema.tables[0].columns[0];
    try std.testing.expectEqualStrings("integer", col.type_sql);
    try std.testing.expect(col.auto_increment);
    try std.testing.expect(col.primary_key);
}

test "SQLite AUTOINCREMENT" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE "todo" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  "title" TEXT NOT NULL
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .sqlite);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const col = result.schema.tables[0].columns[0];
    try std.testing.expectEqualStrings("INTEGER", col.type_sql);
    try std.testing.expect(col.primary_key);
    try std.testing.expect(col.auto_increment);
}

test "SQLite @tps metadata comments" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE "t" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  "name" TEXT NOT NULL
        \\);
        \\-- @tps id n
        \\-- @tps name s32
    ;
    var parser = SqlParser.init(alloc, sql, .sqlite);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("n", tbl.columns[0].tps_override.?);
    try std.testing.expectEqualStrings("s32", tbl.columns[1].tps_override.?);
}

test "SQLite column comment via -- table.col: text" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE "t" (
        \\  "id" INTEGER PRIMARY KEY,
        \\  "name" TEXT
        \\);
        \\-- t.name: The user name
    ;
    var parser = SqlParser.init(alloc, sql, .sqlite);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqualStrings("The user name", result.schema.tables[0].columns[1].comment.?);
}

test "skip ALTER TABLE statement" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (id int, name text);
        \\ALTER TABLE t ADD COLUMN age int;
        \\CREATE TABLE t2 (id int);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 2), result.schema.tables.len);
    try std.testing.expectEqualStrings("t", result.schema.tables[0].name);
    try std.testing.expectEqualStrings("t2", result.schema.tables[1].name);
}

test "parse ALTER TABLE ADD FOREIGN KEY" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE orders (
        \\  id int AUTO_INCREMENT PRIMARY KEY,
        \\  user_id int NOT NULL
        \\);
        \\ALTER TABLE orders ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE;
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 1), result.schema.tables.len);
    try std.testing.expectEqualStrings("orders", result.schema.tables[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.schema.tables[0].foreign_keys.len);
    const fk = result.schema.tables[0].foreign_keys[0];
    try std.testing.expectEqualStrings("user_id", fk.fields[0]);
    try std.testing.expectEqualStrings("user", fk.ref_table);
    try std.testing.expectEqualStrings("id", fk.ref_fields[0]);
    try std.testing.expectEqual(@as(usize, 1), fk.actions.len);
}

test "parse ALTER TABLE ADD FOREIGN KEY without constraint name" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (id int, ref_id int);
        \\ALTER TABLE t ADD FOREIGN KEY (ref_id) REFERENCES other(id);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 1), result.schema.tables.len);
    try std.testing.expectEqual(@as(usize, 1), result.schema.tables[0].foreign_keys.len);
    try std.testing.expectEqualStrings("ref_id", result.schema.tables[0].foreign_keys[0].fields[0]);
    try std.testing.expectEqualStrings("other", result.schema.tables[0].foreign_keys[0].ref_table);
}

test "skip CREATE EXTENSION/SCHEMA/TYPE" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE EXTENSION IF NOT EXISTS pgcrypto;
        \\CREATE SCHEMA IF NOT EXISTS app;
        \\CREATE TABLE t (id int);
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 1), result.schema.tables.len);
    try std.testing.expectEqualStrings("t", result.schema.tables[0].name);
}

test "parse CREATE DATABASE with charset" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE DATABASE IF NOT EXISTS mydb CHARACTER SET utf8mb4;
        \\CREATE TABLE t (id int);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqualStrings("mydb", result.schema.name.?);
    try std.testing.expectEqualStrings("utf8mb4", result.schema.charset.?);
}

test "parse PG CREATE DATABASE with encoding" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE DATABASE mydb ENCODING 'UTF8';
        \\CREATE TABLE t (id int);
    ;
    var parser = SqlParser.init(alloc, sql, .pg);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqualStrings("mydb", result.schema.name.?);
    try std.testing.expectEqualStrings("UTF8", result.schema.charset.?);
}

test "parse CHECK constraint" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  age int CHECK (age >= 0 AND age <= 150),
        \\  status text CHECK (status IN ('active', 'inactive'))
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            for (tbl.checks) |ck| {
                alloc.free(ck.field_name);
                alloc.free(ck.expr);
            }
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 2), tbl.checks.len);
    try std.testing.expectEqualStrings("age", tbl.checks[0].field_name);
    try std.testing.expect(tbl.checks[0].expr.len > 0);
    try std.testing.expectEqualStrings("status", tbl.checks[1].field_name);
}

test "parse inline column DEFAULT values" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  a int DEFAULT 42,
        \\  b text DEFAULT 'hello',
        \\  c int DEFAULT NULL,
        \\  d decimal(10,2) DEFAULT 0.00,
        \\  e blob DEFAULT b'0'
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("42", tbl.columns[0].default_val.?);
    try std.testing.expectEqualStrings("'hello'", tbl.columns[1].default_val.?);
    try std.testing.expectEqualStrings("NULL", tbl.columns[2].default_val.?);
    try std.testing.expectEqualStrings("0.00", tbl.columns[3].default_val.?);
    try std.testing.expectEqualStrings("b'0'", tbl.columns[4].default_val.?);
}

test "parse inline COMMENT on columns" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  id int COMMENT 'primary key',
        \\  name varchar(100) COMMENT 'user name'
        \\) COMMENT='table desc';
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqualStrings("primary key", tbl.columns[0].comment.?);
    try std.testing.expectEqualStrings("user name", tbl.columns[1].comment.?);
    try std.testing.expectEqualStrings("table desc", tbl.comment.?);
}

test "parse multiple tables in one statement" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE user (id int, name text);
        \\CREATE TABLE post (id int, user_id int, title text);
        \\CREATE TABLE comment (id int, post_id int, body text);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    try std.testing.expectEqual(@as(usize, 3), result.schema.tables.len);
    try std.testing.expectEqualStrings("user", result.schema.tables[0].name);
    try std.testing.expectEqualStrings("post", result.schema.tables[1].name);
    try std.testing.expectEqualStrings("comment", result.schema.tables[2].name);
    try std.testing.expectEqual(@as(usize, 3), result.schema.tables[2].columns.len);
}

test "parse inline index MySQL" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  id int NOT NULL AUTO_INCREMENT,
        \\  email varchar(255) NOT NULL,
        \\  UNIQUE KEY uk_email (email),
        \\  INDEX idx_id (id),
        \\  PRIMARY KEY (`id`)
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            for (tbl.indexes) |idx| {
                alloc.free(idx.fields);
                alloc.free(idx.name);
            }
            alloc.free(tbl.indexes);
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const tbl = result.schema.tables[0];
    try std.testing.expectEqual(@as(usize, 3), tbl.indexes.len);
}

test "FK with ON DELETE SET NULL only" {
    const alloc = std.testing.allocator;
    const sql =
        \\CREATE TABLE t (
        \\  id int NOT NULL,
        \\  ref_id int,
        \\  FOREIGN KEY (ref_id) REFERENCES other(id) ON DELETE SET NULL
        \\);
    ;
    var parser = SqlParser.init(alloc, sql, .mysql);
    const result = try parser.parse();
    defer {
        alloc.free(result.diagnostics);
        for (result.schema.tables) |tbl| {
            alloc.free(tbl.columns);
            for (tbl.indexes) |idx| alloc.free(idx.fields);
            alloc.free(tbl.indexes);
            for (tbl.foreign_keys) |fk| {
                alloc.free(fk.fields);
                alloc.free(fk.ref_fields);
                alloc.free(fk.actions);
            }
            alloc.free(tbl.foreign_keys);
            alloc.free(tbl.checks);
        }
        alloc.free(result.schema.tables);
    }

    const fk = result.schema.tables[0].foreign_keys[0];
    try std.testing.expectEqual(@as(usize, 1), fk.actions.len);
    try std.testing.expectEqual(FkActionTrigger.on_delete, fk.actions[0].trigger);
    try std.testing.expectEqual(FkActionType.set_null, fk.actions[0].action);
}
