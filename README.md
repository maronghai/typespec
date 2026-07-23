# TypeSpec

> A minimal DSL for declaring database schemas using single-character symbols.
> One character = one type. Convention over configuration. Template-driven.

```
$ ecommerce                              CREATE DATABASE `ecommerce`;

% base
id n++
...                                        CREATE TABLE `user` (
version   N                                `id`    int AUTO_INCREMENT PRIMARY KEY,
status    1 =0                             `name`  varchar(32) NOT NULL,
create_at +                                `email` varchar(128) NOT NULL,
update_at ++                               `balance` decimal(16, 2) DEFAULT 0,
                                            `version` bigint,
#base user  : 用户表                       `status`  int(1) DEFAULT 0,
                                            ...
name      s32 *                            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
email     s128 *                             COMMENT='用户表';
balance   m =0
```

## Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [Type System](#type-system)
- [Schema Syntax](#schema-syntax)
- [Template System](#template-system)
- [Views](#views)
- [Examples](#examples)
- [Migration](#migration)
- [Reverse Engineering](#reverse-engineering)
- [Grammar](#grammar)
- [Design Principles](#design-principles)
- [FAQ](#faq)

## Features

| Feature | TypeSpec | Raw SQL |
|---------|---------|---------|
| `id n++` | `int AUTO_INCREMENT PRIMARY KEY` | 30 chars |
| `balance m =0` | `decimal(16, 2) DEFAULT 0` | 24 chars |
| `create_at +` | `datetime DEFAULT CURRENT_TIMESTAMP` | 34 chars |
| `email s128 *` | `varchar(128) NOT NULL` | 21 chars |
| `@ name` | `INDEX idx_name (name)` | 21 chars (shorthand saves 71%) |
| `> user.id` | `FOREIGN KEY (user_id) REFERENCES user(id)` | 42 chars (ultra-shorthand saves 76%) |
| `> user.id -C C` | `...ON DELETE CASCADE ON UPDATE CASCADE` | FK actions (saves 86%) |
| `^MyISAM` | `ENGINE=MyISAM` | Table engine (1 char vs 15) |
| `n!` | `int PRIMARY KEY` | Fused type+modifier saves 1 char |
| `+n` | `int UNSIGNED` | Unsigned prefix syntax |
| `*=0` | `NOT NULL DEFAULT 0` | Fused modifier saves 1 char |
| `e(M,F,X)` | `ENUM('M','F','X')` | Inline enum, no DDL needed |
| `! a b` | `PRIMARY KEY (a,b)` | Composite primary key |
| `% user base + soft` | merge fields from multiple parents | Template mixins |
| Suffix inference | `_id`→int, `_at`→datetime | Explicit type every time |
| `migrate` | `ALTER TABLE ... ADD/MODIFY/DROP/RENAME COLUMN` | AST-level diff, not text diff |
| `& view = SELECT ...` | `CREATE VIEW ... AS SELECT ...` | Inline view definition |

**Average compression: 3-5x per field** — common declarations shrink dramatically.

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/) 0.16 or later

### 1. Write a Schema

Create a `.tps` file:

```asm
$ myapp

% base
id n++
...
version   N
status    1 =0
create_at +
update_at ++

#base user  : 用户表

name      s32 *     : 用户名
email     s128 *    : 唯一邮箱
password  s256 *    : bcrypt hash
avatar    S         : 头像 URL
is_admin  b =0      : 管理员标记
balance   m =0      : 余额（分）
settings  j         : JSON 偏好

@u email           ; → UNIQUE INDEX uk_email (email)
@ name             ; → INDEX idx_name (name)

#base order  ^MyISAM  : 订单表

order_no    s64 *     : 唯一订单号
user_id               : 下单用户（suffix _id → int）
amount      m *       : 总额（分）
discount    M =0      : 折扣（分）
note        s512      : 买家留言
paid_on               : 支付日期（suffix _on → date）

@u order_no       ; → UNIQUE INDEX uk_order_no (order_no)
@ user_id         ; → INDEX idx_user_id (user_id)

> user_id user.id   ; single-arrow shorthand
```

### 2. Generate SQL

```bash
cd zig-typespec && zig build
./zig-out/bin/typespec ../myapp.tps -o myapp.sql

# PostgreSQL output
./zig-out/bin/typespec ../myapp.tps -d pg -o myapp_pg.sql
```

### 3. Output

See [examples/user-order.tps](examples/user-order.tps) for complete TypeSpec → SQL output.

## Type System

One character = one type. Case matters.

| Symbol | SQL Type (MySQL) | SQL Type (PostgreSQL) | Description |
|--------|-----------------|---------------------|-------------|
| `n` | int | integer | 32-bit integer |
| `N` | bigint | bigint | 64-bit integer |
| `i` | smallint | smallint | 16-bit integer |
| `\d+` | int(n) | integer | Integer with display width (PG ignores width) |
| `\d+,\d+` | decimal(m,n) | numeric(m,n) | Fixed-point number |
| `m` | decimal(16,2) | numeric(16,2) | Standard currency |
| `M` | decimal(20,6) | numeric(20,6) | High-precision currency |
| `s` | varchar(255) | varchar(255) | Variable-length string (default) |
| `s\d+` | varchar(n) | varchar(n) | VARCHAR with explicit length |
| `S` | text | text | Unlimited-length text |
| `b` | boolean | boolean | True/false |
| `B` | blob | bytea | Binary data |
| `j` | json | json | JSON document |
| `J` | json | jsonb | Binary JSON (PG native jsonb) |
| `I` | varchar(45) | inet | IP address (PG native inet) |
| `d` | date | date | Date only |
| `t` | datetime | timestamp | Date + time |
| `T` | timestamp | timestamptz | Timestamp with time zone |
| `U` | char(36) | uuid | UUID type |
| `p` | int | serial | Auto-incrementing integer |
| `e(...)` | ENUM('...') | text + CHECK | Enumeration |

**Suffix inference** — no type symbol needed:

| Suffix | Inferred Type | Example |
|--------|---------------|---------|
| `_id` | int | `user_id` → int |
| `_on` | date | `paid_on` → date |
| `_at` | datetime | `created_at` → datetime |
| *(none)* | varchar(255) | `name` → varchar(255) |

Explicit type always wins: `user_id s32` → varchar(32), not int.

## Schema Syntax

See [schema.md](schema.md) for complete syntax reference.

### Structural Marks

| Symbol | Meaning | Example |
|--------|---------|---------|
| `$` | Database | `$ ecommerce` |
| `$ name charset` | Database with charset | `$ mydb utf8mb4` |
| `^` | Engine (default InnoDB) | `^MyISAM` |
| `#` | Table | `# user` |
| `#name` | Table with template | `#base user` |
| `%` | Template definition | `% base` |
| `% >` | Template inheritance | `% audit > base` |
| `&` | View | `& active_users = SELECT ...` |
| `...` | Template slot (insertion point) | `...` |

### Field Modifiers

| Symbol | Meaning | Applies to | Example |
|--------|---------|------------|---------|
| `++` | AUTO_INCREMENT PRIMARY KEY | n, N, \d+ | `id n++` |
| `+` | AUTO_INCREMENT | n, N, \d+ | `seq n+` |
| `++` | DEFAULT CURRENT_TIMESTAMP ON UPDATE | t, d | `update_at ++` |
| `+` | DEFAULT CURRENT_TIMESTAMP | t, d | `create_at +` |
| `!` | PRIMARY KEY | any | `code s32 !` |
| `=` | DEFAULT value | any | `status 1 =0` |
| `*` | NOT NULL | any | `name s32 *` |
| `*=` | NOT NULL + DEFAULT | any | `status 1 *=0` |
| `+n`/`+N`/`+i` | UNSIGNED | n, N, i | `count +n` |
| `@u` | UNIQUE INDEX (inline) | any | `email s128 * @u` |
| `@` | INDEX (inline) | any | `name s32 @` |
| `@f` | FULLTEXT INDEX (inline) | any | `content S @f` |
| `[...]` | CHECK constraint | any | `age n [0,150]` |
| `:` | COMMENT clause | — | `name s32 : 用户名` |

> **Note**: `+` and `++` only have defined behavior on numeric types (`n`, `N`, `\d+`) and datetime types (`t`, `d`). Using them on other types is undefined.

### Foreign Keys

```asm
; ── Inline FK (field + FK in one line) ──
user_id     > user.id                      ; inline with arrow
user_id     user.id                        ; inline without arrow
id n > user.id                             ; ultra inline (infers user_id)

; ── Standalone FK ──
> user_id user.id                          ; shorthand
> user.id                                  ; ultra shorthand (infers user_id)

; ── FK Actions ──
> user_id user.id -C C                     ; ON DELETE CASCADE ON UPDATE CASCADE
> order_id order.id -C                     ; ON DELETE CASCADE only
> coupon_id coupon.id -N C                 ; ON DELETE SET NULL ON UPDATE CASCADE
user_id n > user.id -C C                   ; inline FK with actions
```

**FK Actions**: `-C` = ON DELETE CASCADE, `-N` = ON DELETE SET NULL, `C` = ON UPDATE CASCADE, `N` = ON UPDATE SET NULL. Omit for RESTRICT (default).

### Indexes

```asm
@ name                  ; shorthand: INDEX idx_name (name)
@u email                ; shorthand: UNIQUE INDEX uk_email (email)
@f content              ; shorthand: FULLTEXT INDEX ft_content (content)
@ idx_name (name)       ; full syntax (same result as shorthand above)
@u uk_email (email)     ; full syntax
@f ft_content (title, content)  ; full syntax for composite
```

> **Note**: Shorthand is single-column only. Composite indexes require full syntax. `@fu` (unique fulltext) is not supported.
>
> **Output order**: Columns → Indexes → Foreign Keys. Standalone `@` lines must appear inside the `#` table block (after fields, before `>` FK lines).

### CHECK Constraints

```asm
age     n [0,150]              ; CHECK (age BETWEEN 0 AND 150)    — inclusive both
age     n [0,150)              ; CHECK (age >= 0 AND age < 150)   — upper exclusive
age     n (0,150]              ; CHECK (age > 0 AND age <= 150)   — lower exclusive
age     n (0,150)              ; CHECK (age > 0 AND age < 150)    — both exclusive
status  1 {0,1,2}             ; CHECK (status IN (0, 1, 2))      — IN list
amount  m {>0}                 ; CHECK (amount > 0)               — comparison
ratio   M {>=0,<=100}         ; CHECK (ratio >= 0 AND ratio <= 100) — compound
type    s32 {a,b,c}           ; CHECK (type IN ('a', 'b', 'c'))  — string IN list
```

> **Disambiguation**: `[a,b]` uses BETWEEN (inclusive). Use `{a,b}` for IN lists. `[a,b)` `(a,b]` `(a,b)` for exclusive bounds.

### Comments

```asm
; spec comment — stripped from output       ; internal notes
-- SQL comment — passed to DDL              ; DBA documentation
: COMMENT clause — becomes SQL COMMENT      ; database metadata
```

**When to use each comment style:**

| Style | Output | Use Case | Example |
|-------|--------|----------|---------|
| `;` | Stripped | Internal notes, TODOs, design rationale | `; TODO: add index later` |
| `--` | SQL comment | DBA documentation, migration notes | `-- Added in v2.1` |
| `:` | COMMENT clause | Database metadata, API documentation | `: 用户登录名` |

> **Rule of thumb**: Use `;` for your notes, `--` for DBA notes, `:` for database metadata.

## Template System

Templates define reusable table patterns. The `...` slot controls where concrete fields are inserted.

### Basic Template

```asm
% base

id n++
...
version   N
status    1 =0
create_at +
update_at ++

#base user  : 用户表

name      s32 *
email     s128 *

→ Result: id, name, email, version, status, create_at, update_at
           ↑ before slot    ↑ concrete    ↑ after slot
```

### Template Inheritance

Templates can extend other templates. The merge algorithm:

```
result = parent_before + child_before + <concrete fields> + child_after + parent_after
```

**Single parent** — use `>`:

```asm
% base
id n++
...
version   N
status    1 =0
create_at +
update_at ++

% audit > base
...
deleted_at
deleted_by n

% soft_delete > audit
...
restore_token s64

#soft_delete user  : 3-level inheritance

name      s32 *
email     s128 *

→ Result: id, name, email, version, status, create_at, update_at,
          deleted_at, deleted_by, restore_token
          ↑ from base     ↑ concrete    ↑ from audit  ↑ from soft_delete
```

**Multiple parents (mixins)** — use `+` to merge fields from several templates:

```asm
% base
id n++
version N

% soft_delete
deleted_at
deleted_by n

% user_mixin base + soft_delete   ; merges fields from both parents
name s32 *
email s128 *

# user_mixin user

phone s16

→ Result: id, version, deleted_at, deleted_by, name, email, phone
          ↑ from base   ↑ from soft_delete  ↑ concrete
```

### Default Template

An unnamed `%` applies to all `#` tables without a template reference:

```asm
%
id n++
...
created_at +

# user       ; ← automatically gets the default template
name s32 *

# setting    ; ← also gets it
key s128 *
value S
```

## Views

Define views inline with `&`:

```asm
# user
id   n++
name s32 *
active b =1

& active_users = SELECT id, name FROM user WHERE active = 1
```

Generates:

```sql
CREATE TABLE `user` (
  `id` int AUTO_INCREMENT PRIMARY KEY,
  `name` varchar(32) NOT NULL,
  `active` boolean DEFAULT 1
);
CREATE VIEW `active_users` AS SELECT id, name FROM user WHERE active = 1;
```

Views are supported in all three dialects (MySQL, PostgreSQL, SQLite) and in schema diff/migration.

## Examples

A full e-commerce schema with 21 tables: see [examples/complex-ecommerce.tps](examples/complex-ecommerce.tps) (426 lines → [430 lines SQL](examples/complex-ecommerce.sql)).

| Example | Description | Tables |
|---------|-------------|--------|
| [user-order.tps](examples/user-order.tps) | Templates, FK, indexes | 3 |
| [template-inheritance.tps](examples/template-inheritance.tps) | 3-level inheritance | 2 |
| [constraints.tps](examples/constraints.tps) | CHECK constraints, composite PKs | 3 |
| [complex-ecommerce.tps](examples/complex-ecommerce.tps) | Full e-commerce platform | 21 |

## Grammar

The complete grammar is defined in [grammar.ebnf](grammar.ebnf). Key productions:

```
spec          = { blank_line | schema_decl | engine_decl | template_def | table_decl }
schema_decl   = "$", WS, schema_name, [WS, charset_name], [WS, comment], newline
engine_decl   = "^", [WS, engine_name], newline
table_decl    = "#", [template_ref], WS, table_name, [WS, "^", engine_name],
                [comment_trailing], newline, field_list
field_list    = { field_decl | blank_line | foreign_key_decl
                 | index_decl | composite_pk_decl | template_slot }
field_decl    = field_name, [WS, type_symbol], [WS, modifier_list],
                [WS, inline_fk], [WS, check_clause], [WS, comment_line], newline
inline_fk     = [ ">", WS ], ( ref_table, ".", ref_field | ref_table ),
                { WS, fk_action }
template_def  = "%", [name], {WS, parent_ref}, newline, field_list
parent_ref    = ">", WS, parent_name, {WS, "+", WS, parent_name}
              | parent_name, {WS, "+", WS, parent_name}
type_symbol   = numeric_type | money_type | string_type | enum_type | atomic_type
numeric_type  = "n" | "N" | "i" | decimal_type | int_explicit
decimal_type  = "m" | "M"
string_type   = "s" | varchar_explicit | "S"
varchar_explicit = "s", positive_int
enum_type     = "e", "(", (word | quoted_word), {",", (word | quoted_word)}, ")"
atomic_type   = "b" | "B" | "j" | "J" | "I" | "d" | "t" | "T" | "U" | "p"
quoted_word   = "'", word, "'"
modifier      = "++" | "+" | "!" | "*=" | "*" | "=" | "u" | "@u" | "@"
foreign_key_decl = ">", field_name, WS, ref_table, [".", ref_field],
                   {WS, fk_action}, newline
fk_action        = ("-", "C" | "-", "N" | "C" | "N")
composite_pk_decl = "!", field_name, {WS, field_name}, newline
index_decl    = "@", ["u" | "f"], index_name, ["(", fields, ")"], newline
```

See [schema.md §10](schema.md#10-grammar--diagnostics) for grammar notes and [type.md §3](type.md#3-type-symbol-grammar) for type symbol definitions.

## Design Principles

1. **Minimal syntax** — every construct is a single character or short symbol
2. **Convention over configuration** — suffix inference eliminates redundant declarations
3. **Shorthand where unambiguous** — single-column indexes and FKs omit redundant names/brackets
4. **Type Spec as foundation** — field types are fully delegated to the type system
5. **Modifier composition** — `++` composes `+` + `!` (numeric) or `+` + `+` (timestamp)
6. **Three-layer comments** — spec (`;`), SQL (`--`), column (`:`)
7. **Template-driven** — define once, apply everywhere with precise slot control
8. **DB-agnostic core** — symbols map to SQL standards; the compiler handles dialects
9. **FK actions as postfix** — `-C`/`-N`/`C`/`N` appended to FK reference, no extra syntax
10. **AST-level diff** — migration uses semantic comparison, not SQL text diff; detects renames, not just adds/drops
11. **Lowercase for core, uppercase for variants** — `n`/`s`/`b`/`j`/`d`/`t` are core; `N`/`M`/`S`/`B`/`T`/`U` are variants. `i` and `p` are lowercase exceptions for smallint and serial.

## Migration

Generate ALTER TABLE migration scripts from schema diffs:

```bash
# Print to stdout
typespec migrate old.tps new.tps

# Write to file
typespec migrate old.tps new.tps -o migration.sql

# PostgreSQL migration
typespec migrate old.tps new.tps -d pg -o migration_pg.sql
```

**What it generates:**

| Change | Output |
|--------|--------|
| New table | `CREATE TABLE` |
| Dropped table | `DROP TABLE IF EXISTS` |
| New view | `CREATE VIEW` |
| Dropped view | `DROP VIEW IF EXISTS` |
| Modified view | `DROP VIEW` + `CREATE VIEW` |
| Added column | `ALTER TABLE ... ADD COLUMN` |
| Dropped column | `ALTER TABLE ... DROP COLUMN` |
| Modified column | `ALTER TABLE ... MODIFY COLUMN` |
| Renamed column | `CHANGE COLUMN` (MySQL) / `RENAME COLUMN TO` (PG) |
| Added/dropped index | `ADD INDEX` / `DROP INDEX` |
| Added/dropped FK | `ADD FOREIGN KEY` / `DROP FOREIGN KEY` |
| Modified FK (action only) | `DROP FOREIGN KEY` + `ADD FOREIGN KEY` in single `ALTER TABLE` |
| No changes | Empty `BEGIN`/`COMMIT` |

All operations are wrapped in a transaction. The diff engine works at the AST level — it detects field renames, type changes, and structural differences rather than comparing raw SQL text.

## Reverse Engineering

Convert existing SQL DDL back to TypeSpec `.tps` schemas:

```bash
# Basic reverse (MySQL)
typespec reverse schema.sql

# PostgreSQL
typespec reverse -d pg schema.sql

# SQLite
typespec reverse -d sqlite schema.sql

# With template extraction
typespec reverse -t schema.sql

# Write to file
typespec reverse schema.sql -o schema.tps
```

### Roundtrip Preservation

SQLite's type affinity is lossy — multiple TPS types map to the same SQL type (e.g., `N` and `n` both become `INTEGER`). To preserve the original TPS type information during roundtrips (`typespec | typespec reverse`), the compiler emits metadata comments:

```sql
CREATE TABLE "users" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "name" varchar(100)
);
-- @tps id N
-- @tps name s100
```

The `-- @tps col_name type` comments are:
- **Emitted** automatically by the forward compiler for SQLite output
- **Parsed** by the reverse compiler to restore the exact TPS type
- **Ignored** by other dialects (MySQL, PostgreSQL) which have lossless type mappings

This ensures `typespec -d sqlite schema.tps | typespec reverse -d sqlite` produces output identical to the original `.tps` file.

**What it handles:**

| Feature | Support |
|---------|---------|
| CREATE TABLE (columns, types, modifiers) | ✅ |
| PRIMARY KEY (inline + composite) | ✅ |
| AUTO_INCREMENT / GENERATED AS IDENTITY | ✅ |
| NOT NULL / DEFAULT values | ✅ |
| UNIQUE INDEX / INDEX / FULLTEXT INDEX | ✅ |
| Inline index suffixes (`@`, `@u`) with table-prefixed names | ✅ |
| FOREIGN KEY with ON DELETE/UPDATE actions | ✅ |
| CHECK constraints (range, IN list, comparison) | ✅ |
| MySQL COMMENT / PG COMMENT ON / SQLite comments | ✅ |
| ENUM types | ✅ |
| CREATE VIEW | ✅ |
| Template extraction (`-t` flag) | ✅ |
| Score-based template ranking (cross-table coverage) | ✅ |

**Index roundtrip**: Single-field indexes are detected as inline suffixes (`@` / `@u`) when the SQL index name follows the `idx_<field>` or `uk_<field>` convention — including PG/SQLite table-prefixed variants like `idx_<table>_<field>`. Non-standard index names (e.g., `idx_user` for field `user_id`) are emitted in full form: `@ idx_user (user_id)`.

**Confidence comments**: SQLite reverse may assign low confidence to ambiguous types (e.g., `TEXT`). These `-- [LOW]` comments are suppressed on fields that already carry an inline index suffix, keeping the output clean.

**Template extraction** (`-t`): Automatically discovers shared field sequences across tables and extracts them as reusable templates. Uses a scoring algorithm that favors templates covering many fields across many tables.

## FAQ

**Q: What's the difference between `n`, `N`, and `i`?**
`n` = INT (32-bit, up to 2.1 billion). `N` = BIGINT (64-bit, up to 9.2 quintillion). `i` = SMALLINT (16-bit, up to 32,767).

**Q: What's the difference between `m` and `M`?**
`m` = DECIMAL(16,2) (up to 999,999,999,999.99). `M` = DECIMAL(20,6) (high-precision).

**Q: Can I override suffix inference?**
Yes. `user_id s32` → varchar(32), not int. Explicit type always wins.

**Q: How do I handle ENUM types?**
Use `e(M,F,X)` → `ENUM('M','F','X')`. For string values: `e(pending,active,closed)`.

**Q: Does it support PostgreSQL?**
Yes. Use `-d pg` or `-d postgres` to generate PostgreSQL DDL:

```bash
typespec schema.tps -d pg          # PostgreSQL output
typespec schema.tps -d mysql       # MySQL output (default)
typespec schema.tps -d sqlite      # SQLite output
typespec reverse -d pg schema.sql  # Reverse-engineer PG DDL
typespec migrate old.tps new.tps   # Generate ALTER TABLE migration
```

Type differences between dialects:

| Symbol | MySQL | PostgreSQL | SQLite |
|--------|-------|-----------|--------|
| `n` | `int` | `integer` | `INTEGER` |
| `N` | `bigint` | `bigint` | `INTEGER` |
| `i` | `smallint` | `smallint` | `INTEGER` |
| `m` | `decimal(16,2)` | `numeric(16,2)` | `NUMERIC` |
| `M` | `decimal(20,6)` | `numeric(20,6)` | `NUMERIC` |
| `B` | `blob` | `bytea` | `BLOB` |
| `t` | `datetime` | `timestamp` | `TEXT` |
| `T` | `timestamp` | `timestamptz` | `TEXT` |
| `U` | `char(36)` | `uuid` | `TEXT` |
| `p` | `int` | `serial` | `INTEGER` |
| `b` | `boolean` | `boolean` | `INTEGER` |
| `e(...)` | `ENUM(...)` | `text` + `CHECK` | `TEXT` + `CHECK` |
| `s32` | `varchar(32)` | `varchar(32)` | `TEXT` |
| `n++` | `AUTO_INCREMENT` | `GENERATED ALWAYS AS IDENTITY` | `PRIMARY KEY AUTOINCREMENT` |

PostgreSQL does not support: `UNSIGNED`, `ENGINE=`, `CHARSET=`, inline `FULLTEXT INDEX`, or `ON UPDATE CURRENT_TIMESTAMP`.

**Q: What about SQLite support?**
SQLite uses a simplified type affinity system. The compiler maps TypeSpec types to SQLite affinities (`INTEGER`, `NUMERIC`, `TEXT`, `REAL`, `BLOB`). Key differences:

- No `CREATE DATABASE` (file-based)
- No `COMMENT` syntax
- No `ENGINE`/`CHARSET` options
- `AUTOINCREMENT` only works with `INTEGER PRIMARY KEY`
- Limited `ALTER TABLE` (no `MODIFY COLUMN`, `DROP COLUMN` requires SQLite 3.35+)
- Enum types become `TEXT` + `CHECK` constraint

**Q: What if a field name ends with `_at`/`_on`/`_id` but isn't a timestamp/foreign key?**
Use an explicit type to override suffix inference. For example, `point_at s32` → varchar(32).

**Q: Can I use `+` on a varchar or decimal field?**
No. `+`/`++` only work on numeric types (`n`, `N`, `\d+`) and datetime types (`t`, `d`).

**Q: How do I use UNSIGNED?**
Use the `+` prefix on a numeric type: `+n` → `int UNSIGNED`, `+N` → `bigint UNSIGNED`, `+i` → `smallint UNSIGNED`.

**Q: How do I use UUID or serial types?**
Use `U` for UUID and `p` for serial: `token U` → uuid (PG: native uuid; MySQL: char(36)), `id p` → serial (PG: serial; MySQL/SQLite: int).

## License

[MIT](LICENSE)
