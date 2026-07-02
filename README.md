# TypeSpec

> A minimal DSL for declaring database schemas using single-character symbols.
> One character = one type. Convention over configuration. Template-driven.

```
$ ecommerce                              CREATE DATABASE `ecommerce`;

% base                                   CREATE TABLE `user` (
id n++                                    `id`    int AUTO_INCREMENT PRIMARY KEY,
...                                        `name`  varchar(32) NOT NULL,
version   N                                `email` varchar(128) NOT NULL,
status    1 =0                             `balance` decimal(16, 2) DEFAULT 0,
create_at t+                               `version` bigint,
update_at t++                              `status`  int(1) DEFAULT 0,
                                            ...
#base user  // 用户表                      COMMENT = '用户表'
                                          );
name      s32 *
email     s128 *
balance   m =0
```

## Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [Type System](#type-system)
- [Schema Syntax](#schema-syntax)
- [Template System](#template-system)
- [Complete Example](#complete-example)
- [EBNF Grammar](#ebnf-grammar)
- [Design Principles](#design-principles)
- [FAQ](#faq)

## Features

| Feature | TypeSpec | Raw SQL |
|---------|---------|---------|
| `id n++` | `int AUTO_INCREMENT PRIMARY KEY` | 30 chars |
| `balance m =0` | `decimal(16, 2) DEFAULT 0` | 24 chars |
| `create_at t+` | `datetime DEFAULT CURRENT_TIMESTAMP` | 34 chars |
| `email s128 *` | `varchar(128) NOT NULL` | 21 chars |
| `@ name` | `INDEX idx_name (name)` | 21 chars (shorthand saves 67%) |
| `-> uid user.id` | `FOREIGN KEY (uid) REFERENCES user(id)` | 37 chars (shorthand saves 60%) |
| `-> user.id` | `FOREIGN KEY (user_id) REFERENCES user(id)` | 42 chars (ultra-shorthand saves 75%) |
| `[C]` | `[CASCADE]` | 6 chars per FK action |
| `n!` | `int PRIMARY KEY` | Fused type+modifier saves 1 char |
| `>` | `% audit > base` | `>` saves 6 chars vs `extends` |
| Suffix inference | `_id`→int, `_at`→datetime | Explicit type every time |

**Average compression: 3-5x per field** — common declarations shrink dramatically (e.g., `id n++` = 5 chars vs `int AUTO_INCREMENT PRIMARY KEY` = 30 chars).

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/) 0.14 or later

### 1. Write a Schema

Create a `.tps` file:

```asm
$ myapp

% base
id n++
...
version   N
status    1 =0
create_at t+
update_at t++

#base user  // 用户表

name      s32 *
email     s128 *
password  s256 *
avatar    S
is_admin  b =0
balance   m =0
settings  j

@u email           ; shorthand → UNIQUE INDEX uk_email (email)
@ name             ; shorthand → INDEX idx_name (name)

#base order  // 订单表

order_no    s64 *
user_id             ; suffix _id → int
amount      m *
discount    M =0
note        s512
paid_on     d

-> user_id user.id [CASCADE]   ; single-arrow shorthand

@u order_no       ; shorthand → UNIQUE INDEX uk_order_no (order_no)
@ user_id         ; shorthand → INDEX idx_user (user_id)
```

### 2. Generate SQL

```bash
# Using the Zig compiler
cd zig-typespec && zig build
./zig-out/bin/typespec ../myapp.tps -o myapp.sql

# Or pipe to stdout
./zig-out/bin/typespec ../myapp.tps
```

### 3. Output

```sql
CREATE DATABASE `myapp`;

CREATE TABLE `user` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `name`       varchar(32) NOT NULL,
  `email`      varchar(128) NOT NULL,
  `password`   varchar(256) NOT NULL,
  `avatar`     text,
  `is_admin`   boolean DEFAULT 0,
  `balance`    decimal(16, 2) DEFAULT 0,
  `settings`   json,
  `version`    bigint,
  `status`     int(1) DEFAULT 0,
  `create_at`  datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`  datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  UNIQUE INDEX `uk_email` (`email`),
  INDEX `idx_name` (`name`),

  COMMENT = '用户表'
);

CREATE TABLE `order` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `order_no`   varchar(64) NOT NULL,
  `user_id`    int,
  `amount`     decimal(16, 2) NOT NULL,
  `discount`   decimal(20, 6) DEFAULT 0,
  `note`       varchar(512),
  `paid_on`    date,
  `version`    bigint,
  `status`     int(1) DEFAULT 0,
  `create_at`  datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`  datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
  UNIQUE INDEX `uk_order_no` (`order_no`),
  INDEX `idx_user` (`user_id`),

  COMMENT = '订单表'
);
```

## Type System

One character = one type. Case matters.

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `n` | int | 32-bit integer |
| `N` | bigint | 64-bit integer |
| `\d+` | int(n) | Integer with display width (e.g. `128` → int(128)) |
| `\d+,\d+` | decimal(m,n) | Fixed-point number (e.g. `10,2` → decimal(10,2)) |
| `m` | decimal(16,2) | Standard currency |
| `M` | decimal(20,6) | High-precision currency |
| `s` | varchar | Variable-length string (default) |
| `s\d+` | varchar(n) | VARCHAR with explicit length |
| `S` | text | Unlimited-length text |
| `b` | boolean | True/false |
| `B` | blob | Binary data |
| `j` | json | JSON document |
| `d` | date | Date only |
| `t` | datetime | Date + time |

**Suffix inference** — no type symbol needed:

| Suffix | Inferred Type | Example |
|--------|---------------|---------|
| `_id` | int | `user_id` → int |
| `_on` | date | `paid_on` → date |
| `_at` | datetime | `created_at` → datetime |
| *(none)* | varchar | `name` → varchar |

Explicit type always wins: `user_id s32` → varchar(32), not int.

## Schema Syntax

### Structural Marks

| Symbol | Meaning | Example |
|--------|---------|---------|
| `$` | Database | `$ ecommerce` |
| `#` | Table | `# user` |
| `#name` | Table with template | `#base user` |
| `%` | Template definition | `% base` |
| `% ... extends` | Template inheritance | `% audit extends base` |
| `...` | Template slot (insertion point) | `...` |

### Field Modifiers

| Symbol | Meaning | Applies to | Example |
|--------|---------|------------|---------|
| `++` | AUTO_INCREMENT PRIMARY KEY | n, N, \d+ | `id n++` |
| `+` | AUTO_INCREMENT | n, N, \d+ | `seq n+` |
| `++` | DEFAULT CURRENT_TIMESTAMP ON UPDATE | t, d | `update_at t++` |
| `+` | DEFAULT CURRENT_TIMESTAMP | t, d | `create_at t+` |
| `!` | PRIMARY KEY | any | `code s32 !` |
| `=` | DEFAULT value | any | `status 1 =0` |
| `*` | NOT NULL | any | `name s32 *` |
| `[...]` | CHECK constraint | any | `age n [0,150]` |
| `//` | COMMENT clause | — | `name s32 // 用户名` |

> **Note**: `+` and `++` only have defined behavior on numeric types (`n`, `N`, `\d+`) and datetime types (`t`, `d`). Using them on other types (e.g., `s+`, `m++`) is undefined and should be avoided.

### Foreign Keys

```asm
-> user_id user.id                          ; basic FK (shorthand)
-> user_id -> user.id                       ; basic FK (full form)
-> user.id                                  ; ultra-shorthand: infers user_id
-> user.id [CASCADE]                        ; ultra-shorthand + action
-> user_id user.id [CASCADE]                ; ON DELETE CASCADE
-> user_id user.id [C]                      ; abbreviation (saves 6 chars)
-> user_id user.id [C, U R]                 ; compound: ON DELETE CASCADE ON UPDATE RESTRICT
```

### Indexes

```asm
@ name                  ; shorthand: INDEX idx_name (name)
@u email                ; shorthand: UNIQUE INDEX uk_email (email)
@f content              ; shorthand: FULLTEXT INDEX ft_content (content)
@ idx_name (name)       ; full syntax (same result as shorthand above)
@u uk_email (email)     ; full syntax
@f ft_content (title, content)  ; full syntax for composite
```

> **Note**: Shorthand is single-column only. Composite indexes (`@ idx_name (f1, f2)`) require the full syntax. `@fu` (unique fulltext) is not supported — MySQL does not allow UNIQUE on FULLTEXT indexes.

### CHECK Constraints

```asm
age     n [0,150]              ; CHECK (age BETWEEN 0 AND 150)    — 2 bare nums = range
status  1 [0,1,2]             ; CHECK (status IN (0, 1, 2))      — 3+ values = IN list
amount  m [>0]                 ; CHECK (amount > 0)               — comparison
ratio   M [>=0, <=1]          ; CHECK (ratio >= 0 AND ratio <= 1) — compound
type    s32 ['a','b','c']     ; CHECK (type IN ('a', 'b', 'c'))  — string IN list
```

> **Disambiguation**: `[a,b]` with exactly 2 bare numbers → BETWEEN. `[a,b,c,...]` with 3+ values → IN.

### Comments

```asm
; spec comment — stripped from output       ; internal notes
-- SQL comment — passed to DDL              ; DBA documentation
// COMMENT clause — becomes SQL COMMENT     ; database metadata
```

## Template System

Templates define reusable table patterns. The `...` slot controls where concrete fields are inserted.

### Basic Template

```asm
% base

id n++
...
version   N
status    1 =0
create_at t+
update_at t++

#base user  // 用户表

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

```asm
% base
id n++
...
version   N
status    1 =0
create_at t+
update_at t++

% audit extends base
...
deleted_at t
deleted_by n

% soft_delete extends audit
...
restore_token s64

#soft_delete user  // 3-level inheritance

name      s32 *
email     s128 *

→ Result: id, name, email, version, status, create_at, update_at,
          deleted_at, deleted_by, restore_token
          ↑ from base     ↑ concrete    ↑ from audit  ↑ from soft_delete
```

### Default Template

An unnamed `%` applies to all `#` tables without a template reference:

```asm
%
id n++
...
created_at t+

# user       ; ← automatically gets the default template
name s32 *

# setting    ; ← also gets it
key s128 *
value S
```

## Complete Example

A full e-commerce schema with 21 tables: see [examples/complex-ecommerce.tps](examples/complex-ecommerce.tps) (426 lines → [430 lines SQL](examples/complex-ecommerce.sql)).

| Example | Description | Tables |
|---------|-------------|--------|
| [user-order.tps](examples/user-order.tps) | Templates, FK, indexes | 3 |
| [template-inheritance.tps](examples/template-inheritance.tps) | 3-level inheritance | 2 |
| [constraints.tps](examples/constraints.tps) | CHECK constraints, composite PKs | 3 |
| [complex-ecommerce.tps](examples/complex-ecommerce.tps) | Full e-commerce platform | 21 |

## EBNF Grammar

The complete grammar is defined in [grammar.ebnf](grammar.ebnf). Key productions:

```
spec          = { blank_line | schema_decl | template_def | table_decl }
table_decl    = "#", [template_ref], WS, table_name, [comment_trailing], newline, field_list
field_list    = { field_decl | blank_line | foreign_key_decl | index_decl | template_slot }
field_decl    = field_name, [WS, type_symbol], [WS, modifier_list], [WS, check_clause], newline
template_def  = "%", [name], [">" | "extends", parent], newline, field_list
foreign_key_decl = "->", [field_name, ["->"]], ref_table, ".", ref_field, [action_list], newline
index_decl    = "@", ["!" | "f"], index_name, ["(", fields, ")"], newline
```

See [schema.md §13](schema.md#13-ebnf-grammar) for grammar notes and [type.md §3](type.md#3-type-symbol-grammar) for type symbol definitions.

## Design Principles

1. **Minimal syntax** — every construct is a single character or short symbol
2. **Convention over configuration** — suffix inference eliminates redundant declarations
3. **Shorthand where unambiguous** — single-column indexes and FKs omit redundant names/brackets
4. **Type Spec as foundation** — field types are fully delegated to the type system
5. **Modifier composition** — `++` composes `+` + `!` (numeric) or `+` + `+` (timestamp)
6. **Three-layer comments** — spec (`;`), SQL (`--`), column (`//`)
7. **Template-driven** — define once, apply everywhere with precise slot control
8. **DB-agnostic core** — symbols map to SQL standards; the compiler handles dialects

## FAQ

**Q: What's the difference between `n` and `N`?**
`n` = INT (32-bit, up to 2.1 billion). `N` = BIGINT (64-bit, up to 9.2 quintillion).

**Q: What's the difference between `m` and `M`?**
`m` = DECIMAL(16,2) (up to 999,999,999,999.99). `M` = DECIMAL(20,6) (high-precision).

**Q: Can I override suffix inference?**
Yes. `user_id s32` → varchar(32), not int. Explicit type always wins.

**Q: How do I handle ENUM types?**
Use CHECK constraints: `status 1 [0,1,2]` or `type s32 ['active','inactive']`.

**Q: How do I create composite foreign keys?**
TypeSpec supports single-column FKs. For composite FKs, use `ALTER TABLE` in SQL.

**Q: Does it support PostgreSQL?**
TypeSpec generates MySQL DDL by default. The compiler can be extended for other dialects.

**Q: What if a field name ends with `_at`/`_on`/`_id` but isn't a timestamp/foreign key?**
Use an explicit type to override suffix inference. For example, `point_at s32` → varchar(32), not datetime.

**Q: Can I use `+` on a varchar or decimal field?**
No. `+`/`++` only work on numeric types (`n`, `N`, `\d+`) for AUTO_INCREMENT, and datetime types (`t`, `d`) for timestamp defaults. Using them on other types is undefined.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

[MIT](LICENSE)
