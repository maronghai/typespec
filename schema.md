# Schema Spec

A minimal DSL for declaring database schemas — tables, fields, constraints, indexes, and foreign keys — using single-character symbols. Built on top of [Type Spec](type.md) for field type declarations.

## Quick Reference

### Structural Marks

| Symbol | Meaning | Example |
|--------|---------|---------|
| `$` | Schema (database) | `$ demo` |
| `#` | Table | `# user` |
| `#name` | Table using named template | `#base user` |
| `%` | Template definition (default) | `% base` |
| `% ... extends` | Template inheritance | `% audit extends base` |
| `...` | Template slot (insertion point) | `...` |

### Field Modifiers

| Symbol | Meaning | Applies to | Example |
|--------|---------|------------|---------|
| `+` | AUTO_INCREMENT | n, N, `\d+` | `id n+` |
| `++` | AUTO_INCREMENT PRIMARY KEY | n, N, `\d+` | `id n++` |
| `+` | DEFAULT CURRENT_TIMESTAMP | t, d | `create_at t+` |
| `++` | DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP | t, d | `update_at t++` |
| `!` | PRIMARY KEY | any | `id n!` |
| `=` | DEFAULT value | any | `status 1 =0` |
| `*` | NOT NULL | any | `name s32 *` |
| `[...]` | CHECK constraint | any | `status 1 =0 [0,1]` |
| `//` | Column/table COMMENT | — | `name // 用户名` |

### FK Actions

| Symbol | Meaning | Example |
|--------|---------|---------|
| `[CASCADE]` | ON DELETE CASCADE | `-> uid -> user.id [CASCADE]` |
| `[SET NULL]` | ON DELETE SET NULL | `-> uid -> user.id [SET NULL]` |
| `[NO ACTION]` | ON DELETE NO ACTION | `-> uid -> user.id [NO ACTION]` |
| `[RESTRICT]` | ON DELETE RESTRICT | `-> uid -> user.id [RESTRICT]` |
| `[CASCADE, UPDATE CASCADE]` | ON DELETE + ON UPDATE | `-> uid -> user.id [CASCADE, UPDATE CASCADE]` |

### Comment Styles

| Symbol | Type | Scope |
|--------|------|-------|
| `;` | Spec comment | Line, not in output |
| `--` | SQL comment | Passed to DDL output |
| `//` | COMMENT clause | Table or column |

---

## Contents

1. [Schema Declaration](#1-schema-declaration)
2. [Table Declaration](#2-table-declaration)
3. [Field Declaration](#3-field-declaration)
4. [Field Modifiers](#4-field-modifiers)
5. [Comments](#5-comments)
6. [Composite Primary Key](#6-composite-primary-key)
7. [Foreign Keys](#7-foreign-keys)
8. [Indexes](#8-indexes)
9. [NOT NULL](#9-not-null)
10. [CHECK Constraints](#10-check-constraints)
11. [Templates](#11-templates)
12. [Complete Example](#12-complete-example)
13. [EBNF Grammar](#13-ebnf-grammar)
14. [Design Principles](#14-design-principles)
15. [FAQ](#15-faq)

---

## 1. Schema Declaration

A schema (database) is declared with `$`:

```asm
$ schema_name
```

#### Example

```asm
$ demo
```

#### DDL Output

```sql
CREATE DATABASE `demo`
```

---

## 2. Table Declaration

A table is declared with `#`, followed by the table name and an optional comment:

```asm
# table_name  // table comment
```

A table can reference a named template:

```asm
#base user  // uses template defined by % base
```

### Minimal Table

```asm
# user
```

```sql
CREATE TABLE `user` (
)
```

### Table with Comment

```asm
# user  // TABLE OF USER
```

```sql
CREATE TABLE `user` (
  COMMENT = 'TABLE OF USER'
)
```

### Table with Template

```asm
% base
id n++
...
version N
status 1

delete_at t
create_at t+
update_at t++

#base user  // TABLE OF USER

name
password s100
avatar S

balance m
```

```sql
CREATE TABLE `user` (
  `id`        int AUTO_INCREMENT PRIMARY KEY,

  `name`      varchar(255),
  `password`  varchar(100),
  `avatar`    text,

  `balance`   decimal(16, 2),
  `version`   bigint,
  `status`    int(1),

  `delete_at` datetime,
  `create_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  COMMENT = 'TABLE OF USER'
)
```

---

## 3. Field Declaration

Each field occupies one line. The declaration follows the [Type Spec](type.md) format, extended with modifiers:

```asm
field_name  [type_symbol]  [modifier...]  [check]  [// | -- | ; comment]
```

Multiple modifiers can be combined (e.g., `=0 *`). Modifier resolution depends on the type symbol — see §13 Modifier Resolution.

Fields without a type symbol inherit the default type per [Type Spec suffix inference](type.md#2-naming-conventions):

| Suffix | Inferred Type |
|--------|---------------|
| `_id` | int |
| `_on` | date |
| `_at` | datetime |
| *(none)* | varchar |

> **Note**: If a field name ends with `_at`/`_on`/`_id` but isn't a timestamp or foreign key, use an explicit type to override suffix inference. For example, `point_at s32` → varchar(32), not datetime.

### Example

```asm
# user

id          n++         ; auto-increment primary key
username    s32         ; varchar(32)
email       s128        ; varchar(128)
password    s256        ; varchar(256)
avatar      S           ; text
is_admin    b           ; boolean
balance     m           ; decimal(16,2)
settings    j           ; json
created_at  t+          ; datetime DEFAULT CURRENT_TIMESTAMP
updated_at  t++         ; datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE
deleted_on  d           ; date
```

```sql
CREATE TABLE `user` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `username`   varchar(32),
  `email`      varchar(128),
  `password`   varchar(256),
  `avatar`     text,
  `is_admin`   boolean,
  `balance`    decimal(16, 2),
  `settings`   json,
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_on` date
)
```

---

## 4. Field Modifiers

### 4.1 Auto Increment (`+`)

Applies to numeric types (`n`, `N`, `\d+`):

```asm
id n+     ; AUTO_INCREMENT
version N+ ; AUTO_INCREMENT
```

```sql
`id`      int AUTO_INCREMENT
`version` bigint AUTO_INCREMENT
```

### 4.2 Auto Increment + Primary Key (`++`)

Shorthand for `+ !` combined:

```asm
id n++    ; AUTO_INCREMENT PRIMARY KEY
```

```sql
`id` int AUTO_INCREMENT PRIMARY KEY
```

### 4.3 Timestamp Auto-Value (`+` and `++`)

For datetime/date types, `+` means `DEFAULT CURRENT_TIMESTAMP` (auto-set on insert). `++` means `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP` (auto-set on insert, auto-update on modify):

```asm
create_at t+    ; datetime, auto-set on insert
update_at t++   ; datetime, auto-set on insert, auto-update on modify
deleted_on d+   ; date, auto-set on insert
```

```sql
`create_at` datetime DEFAULT CURRENT_TIMESTAMP
`update_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
`deleted_on` date DEFAULT CURRENT_TIMESTAMP
```

### 4.4 Primary Key (`!`)

Marks a single column as primary key (without auto increment):

```asm
code s32 !     ; PRIMARY KEY
```

```sql
`code` varchar(32) PRIMARY KEY
```

### 4.5 Default Value (`=`)

Assigns a default value:

```asm
status  1 =0           ; DEFAULT 0
balance m =0.00        ; DEFAULT 0.00
name    s32 =''        ; DEFAULT ''
```

```sql
`status`     int(1) DEFAULT 0
`balance`    decimal(16, 2) DEFAULT 0.00
`name`       varchar(32) DEFAULT ''
```

---

## 5. Comments

Three comment styles serve different purposes:

### 5.1 Spec Comment (`;`)

Internal documentation, stripped from DDL output:

```asm
id n++   ; this is a spec comment — not in SQL
```

```sql
`id` int AUTO_INCREMENT PRIMARY KEY
```

### 5.2 SQL Comment (`--`)

Passed through to DDL output as SQL comments:

```asm
id n++  -- primary identifier
```

```sql
`id` int AUTO_INCREMENT PRIMARY KEY -- primary identifier
```

### 5.3 Column/Table Comment (`//`)

Generates a `COMMENT` clause in DDL:

```asm
# user  // TABLE OF USER

id    n++   // auto-increment id
name  s32   // username, unique
```

```sql
CREATE TABLE `user` (
  `id`   int AUTO_INCREMENT PRIMARY KEY COMMENT 'auto-increment id',
  `name` varchar(32) COMMENT 'username, unique',
  COMMENT = 'TABLE OF USER'
)
```

---

## 6. Composite Primary Key

Multiple fields marked with `!` form a composite primary key:

```asm
# user_role

user_id n!    ; part of composite PK
role_id n!    ; part of composite PK
```

```sql
CREATE TABLE `user_role` (
  `user_id` int,
  `role_id` int,
  PRIMARY KEY (`user_id`, `role_id`)
)
```

---

## 7. Foreign Keys

Foreign key relationships are declared with `->`:

```asm
-> user_id -> user.id
```

### FK Syntax

There are two syntax styles for foreign keys:

#### Style 1: Comment-only (documentation)

```asm
# order

id          n++
order_no    s64
user_id             ; -> user.id
amount      m
```

This is a **spec comment** (`; -> user.id`) — it documents the FK intent in the source but generates no DDL. Use this when you want to record the relationship without enforcing it at the database level.

#### Style 2: Standalone Declaration (enforced FK)

```asm
# order

id          n++
order_no    s64
user_id     n
amount      m

-> user_id -> user.id
```

This generates a real `FOREIGN KEY` constraint in the DDL:

```sql
FOREIGN KEY (`user_id`) REFERENCES `user`(`id`)
```

**Use Style 2** when you want the database to enforce referential integrity.

### FK Actions

Append `[action]` to specify referential actions. Supported actions:

| Action | SQL Output |
|--------|-----------|
| `CASCADE` | ON DELETE CASCADE |
| `SET NULL` | ON DELETE SET NULL |
| `NO ACTION` | ON DELETE NO ACTION (default) |
| `RESTRICT` | ON DELETE RESTRICT |
| `UPDATE <action>` | ON UPDATE instead of ON DELETE |

Multiple actions are comma-separated: `[CASCADE, UPDATE SET NULL]`.

### Examples

Basic FK:

```asm
# order

id          n++
order_no    s64
user_id     n
amount      m

-> user_id -> user.id
```

```sql
CREATE TABLE `order` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `order_no`   varchar(64),
  `user_id`    int,
  `amount`     decimal(16, 2),

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`)
)
```

FK with cascade:

```asm
# order_item

order_id    n
product_id  n
quantity    n =1

-> order_id -> order.id [CASCADE]
-> product_id -> product.id [SET NULL, UPDATE CASCADE]
```

```sql
CREATE TABLE `order_item` (
  `order_id`   int,
  `product_id` int,
  `quantity`   int DEFAULT 1,

  FOREIGN KEY (`order_id`)   REFERENCES `order`(`id`)    ON DELETE CASCADE,
  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`)  ON DELETE SET NULL ON UPDATE CASCADE
)
```

### FK with Multiple Columns

For composite foreign keys, declare multiple `->` statements:

```asm
# order_item

order_id    n
product_id  n
quantity    n =1

-> order_id -> order.id [CASCADE]
-> product_id -> product.id [CASCADE]
```

```sql
CREATE TABLE `order_item` (
  `order_id`   int,
  `product_id` int,
  `quantity`   int DEFAULT 1,

  FOREIGN KEY (`order_id`) REFERENCES `order`(`id`) ON DELETE CASCADE,
  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`) ON DELETE CASCADE
)
```

**Note**: TypeSpec doesn't support composite foreign keys (multiple columns referencing one foreign key). For that, you'd need to write the SQL manually or extend the syntax.

---

## 8. Indexes

Indexes are declared with `@`:

```asm
@ index_name (field1, field2)       ; regular index
@! unique_name (field1, field2)     ; unique index
@f fulltext_name (field1, field2)   ; fulltext index
```

### Index Syntax

#### Basic Index

```asm
@ idx_name (name)
```

```sql
INDEX `idx_name` (`name`)
```

#### Unique Index

```asm
@! uk_email (email)
```

```sql
UNIQUE INDEX `uk_email` (`email`)
```

#### Composite Index

```asm
@ idx_status_created (status, created_at)
```

```sql
INDEX `idx_status_created` (`status`, `created_at`)
```

### Index Naming Conventions

| Index Type | Prefix | Example |
|------------|--------|---------|
| Regular | `idx_` | `idx_name` |
| Unique | `uk_` | `uk_email` |
| Foreign Key | `fk_` | `fk_user_id` |
| Fulltext | `ft_` | `ft_content` |

### Index Examples

```asm
# user

id      n++
name    s32
email   s128
status  1 =0
content S

@ idx_name (name)
@! uk_email (email)
@ idx_status (status, created_at)
@f ft_content (content)
```

```sql
CREATE TABLE `user` (
  `id`      int AUTO_INCREMENT PRIMARY KEY,
  `name`    varchar(32),
  `email`   varchar(128),
  `status`  int(1) DEFAULT 0,
  `content` text,

  INDEX `idx_name` (`name`),
  UNIQUE INDEX `uk_email` (`email`),
  INDEX `idx_status` (`status`, `created_at`),
  FULLTEXT INDEX `ft_content` (`content`)
)
```

### Index Limitations

**Note**: TypeSpec supports basic index types. For advanced features, you may need to write SQL manually:

- Unique fulltext index (`@f!`): MySQL does not allow UNIQUE on FULLTEXT indexes
- Prefix indexes: `INDEX idx_name (name(10))`
- Descending indexes: `INDEX idx_name (name DESC)`
- Partial indexes (PostgreSQL): `CREATE INDEX idx ON t(c) WHERE condition`
- Covering indexes: `CREATE INDEX idx ON t(c1, c2) INCLUDE (c3)`
- Expression indexes: `CREATE INDEX idx ON t(LOWER(name))`

---

## 9. NOT NULL

Fields are nullable by default. Mark with `*` for NOT NULL:

```asm
name    s32 *    ; NOT NULL
email   s128 *   ; NOT NULL
```

```sql
`name`  varchar(32) NOT NULL
`email` varchar(128) NOT NULL
```

---

## 10. CHECK Constraints

Inline check constraints are declared with `[` ... `]`:

```asm
status  1 =0 [0,1]           ; CHECK (status IN (0, 1))
age     n =0 [0,150]         ; CHECK (age BETWEEN 0 AND 150)
amount  m =0 [>0]            ; CHECK (amount > 0)
```

```sql
`status` int(1) DEFAULT 0 CHECK (status IN (0, 1)),
`age`    int DEFAULT 0 CHECK (age BETWEEN 0 AND 150),
`amount` decimal(16, 2) DEFAULT 0 CHECK (amount > 0)
```

### CHECK Syntax

The CHECK constraint syntax supports several patterns. **String values use single quotes** (`'a'`), while **numeric values are bare** (`0`, `150`).

#### Range Constraints

```asm
age n [0,150]               ; CHECK (age BETWEEN 0 AND 150)
score n [0,100]             ; CHECK (score BETWEEN 0 AND 100)
```

#### IN Constraints

```asm
status 1 [0,1,2]           ; CHECK (status IN (0, 1, 2))
type s32 ['a','b','c']     ; CHECK (type IN ('a', 'b', 'c'))
```

#### Comparison Constraints

```asm
amount m [>0]               ; CHECK (amount > 0)
quantity n [>=1]            ; CHECK (quantity >= 1)
ratio M [>=0, <=1]          ; CHECK (ratio >= 0 AND ratio <= 1)
```

#### Complex Expressions

**Note**: TypeSpec supports simple CHECK expressions. For complex expressions, you may need to write SQL manually.

```asm
; Simple expressions (supported)
start_date d [>='2020-01-01']
end_date d [>='2020-01-01']

; Complex expressions (not supported in TypeSpec)
; CHECK (start_date < end_date)
; CHECK (email LIKE '%@%.%')
; CHECK (JSON_VALID(settings))
```

### CHECK Examples

```asm
# user

id          n++
username    s32 *
email       s128 *
age         n =0 [0,150]
status      1 =0 [0,1,2]
balance     m =0 [>=0]
score       M =0 [0,100]
```

```sql
CREATE TABLE `user` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `username`   varchar(32) NOT NULL,
  `email`      varchar(128) NOT NULL,
  `age`        int DEFAULT 0 CHECK (age BETWEEN 0 AND 150),
  `status`     int(1) DEFAULT 0 CHECK (status IN (0, 1, 2)),
  `balance`    decimal(16, 2) DEFAULT 0 CHECK (balance >= 0),
  `score`      decimal(20, 6) DEFAULT 0 CHECK (score BETWEEN 0 AND 100)
)
```

---

## 11. Templates

Templates define reusable table skeletons. A template is declared with `%`:

```asm
% template_name
```

The `...` slot marks where concrete fields are inserted:

```asm
% base

id n++
...
version   N
status    1 =0

delete_at t
create_at t+
update_at t++
```

When a table uses a template (`#name`), its fields are inserted at the `...` slot. Fields before `...` in the template come first; fields after come after the inserted fields.

### Default Template

A template with no name (just `%`) is the default — applied to any `#` table that doesn't specify a template reference:

```asm
%

id n++
...

# user

name
email s128
```

```sql
CREATE TABLE `user` (
  `id`    int AUTO_INCREMENT PRIMARY KEY,
  `name`  varchar(255),
  `email` varchar(128)
)
```

**Rule**: If multiple unnamed `%` templates exist, the **last** one in the file is the default. Named templates (`% base`) are never used as defaults.

### Named Template

```asm
% audit

id n++
...
created_at t+
updated_at t++

#audit order

order_no s64
amount   m

#audit payment

order_id n
pay_no   s64
amount   m
```

```sql
CREATE TABLE `order` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `order_no`   varchar(64),
  `amount`     decimal(16, 2),
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)

CREATE TABLE `payment` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `order_id`   int,
  `pay_no`     varchar(64),
  `amount`     decimal(16, 2),
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)
```

### Template Inheritance

Templates can extend other templates with `extends`:

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
```

The child inherits all parent fields. The `...` slot can be redefined in the child; if omitted, the parent's slot position is used. The concrete fields from the table are inserted at the effective `...` position. See **Slot Merge Algorithm** below for the formal merge rules.

```asm
#base order

order_no s64
amount   m
```

```sql
CREATE TABLE `order` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `order_no`   varchar(64),
  `amount`     decimal(16, 2),
  `version`    bigint,
  `status`     int(1) DEFAULT 0,
  `create_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at` datetime
)
```

### Template Slot Position

The `...` slot determines where concrete fields are inserted. A template's field list is split into two parts by `...`:

```
% template
field_a       ← before slot
field_b       ← before slot
...           ← slot
field_c       ← after slot
field_d       ← after slot
```

When a table references this template, its fields replace `...`:

```
#base my_table
field_x
field_y
```

Result:
```
field_a, field_b, field_x, field_y, field_c, field_d
```

### Slot Merge Algorithm

When a template inherits from a parent, the merge follows these steps:

**Step 1 — Resolve parent's effective fields.**
The parent template produces a flat field list by recursively applying the same algorithm (base case: no parent).

**Step 2 — Split parent into before-slot and after-slot.**
```
parent_before = fields before parent's `...`
parent_after  = fields after parent's `...`
```

**Step 3 — Split child into before-slot and after-slot.**
```
child_before = fields before child's `...`
child_after  = fields after child's `...`
```

**Step 4 — Merge.**
```
result = parent_before
       + child_before
       + <concrete fields from table>
       + child_after
       + parent_after
```

If the child does **not** redefine `...`, use the parent's slot position for both splits (i.e., `child_before = []`, `child_after = parent_before + child_own_fields + parent_after` — but this is equivalent to just appending child fields after parent fields).

**Step 5 — Name conflict resolution.**
If a field name appears in both `parent_before` and `child_before`, or in `parent_after` and `child_after`, or across any two segments, the **child's version replaces** the parent's. The replacement is a **complete override** — the parent field's type, modifiers, and constraints are discarded. When the same name appears in a child segment and a parent segment, the child wins.

### Inheritance Rules

1. **Field Inheritance**: Child inherits all parent fields
2. **Slot Override**: Child can redefine `...` position
3. **Field Order**: Result = parent_before + child_before + concrete_fields + child_after + parent_after
4. **Name Conflict**: Child fields **completely replace** parent fields with the same name (full override, not merge)
5. **Multiple Inheritance**: Not supported (single inheritance only)

### Example: Multi-level Inheritance

```asm
% base
id n++
...
version N
status 1 =0
create_at t+
update_at t++

% audit extends base
...
deleted_at t
deleted_by n

% soft_delete extends audit
...
restore_token s64
```

```asm
#base user
name s32 *
email s128 *
```

```sql
CREATE TABLE `user` (
  `id` int AUTO_INCREMENT PRIMARY KEY,
  `name` varchar(32) NOT NULL,
  `email` varchar(128) NOT NULL,
  `version` bigint,
  `status` int(1) DEFAULT 0,
  `create_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at` datetime,
  `deleted_by` int,
  `restore_token` varchar(64)
)
```

---

## 12. Complete Example

```asm
$ ecommerce

% base
id n++
...
version   N
status    1 =0
delete_at t
create_at t+
update_at t++

; ──── Tables ────

#base user  // 用户表

name      s32 *
email s128 *
password  s256 *
avatar    S
is_admin  b =0
balance   m =0
settings  j

@! uk_email (email)
@ idx_name (name)

#base product  // 商品表

name        s128 *
description S
price       m *
stock       n =0
category_id         ; suffix _id → int

@ idx_category (category_id)
@ idx_price (price)

#base order  // 订单表

order_no    s64 *
user_id             ; suffix _id → int
amount      m *
discount    M =0
note        s512
paid_on     d

-> user_id -> user.id [CASCADE]

@! uk_order_no (order_no)
@ idx_user (user_id)
@ idx_paid (paid_on)
```

```sql
CREATE DATABASE `ecommerce`;

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
  `delete_at`  datetime,
  `create_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  UNIQUE INDEX `uk_email` (`email`),
  INDEX `idx_name` (`name`),

  COMMENT = '用户表'
);

CREATE TABLE `product` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `name`        varchar(128) NOT NULL,
  `description` text,
  `price`       decimal(16, 2) NOT NULL,
  `stock`       int DEFAULT 0,
  `category_id` int,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `delete_at`   datetime,
  `create_at`  datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`  datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  INDEX `idx_category` (`category_id`),
  INDEX `idx_price` (`price`),

  COMMENT = '商品表'
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
  `delete_at`  datetime,
  `create_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
  UNIQUE INDEX `uk_order_no` (`order_no`),
  INDEX `idx_user` (`user_id`),
  INDEX `idx_paid` (`paid_on`),

  COMMENT = '订单表'
);
```

---

## 13. EBNF Grammar

The full EBNF grammar is defined in [`grammar.ebnf`](grammar.ebnf). It covers schema, template, table, field, modifier, CHECK, FK, index, and comment productions. Type symbol definitions are in [Type Spec §3](type.md#3-type-symbol-grammar) — only referenced here, not duplicated.

### Grammar Notes

**`field_name` vs `word`** — `field_name` allows a leading digit (e.g., `128`), while `word` requires a leading letter or underscore. This is intentional: field names like `128` are valid in the source format, but table/schema/index names follow SQL identifier rules (must start with a letter or `_`).

**Ambiguity: digit-leading field name vs `int_explicit`** — A line like `128 status` is ambiguous: is `128` the field name (with unknown type `status`), or `status` the field name (with type `int(128)`)? The parser resolves this by context: if the second token is a known type symbol, it is the type; otherwise, the first token is the field name and the rest is the type. When in doubt, use an explicit type symbol.

**Modifier context-sensitivity** — The grammar is context-free for `+`. Its meaning depends on the type symbol (see Modifier Resolution below). This is a semantic layer, not a syntactic one — the parser produces an AST node; the type-checker resolves the meaning. On `t`/`d` types, `+` means `DEFAULT CURRENT_TIMESTAMP` and `++` means `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`. The `=` modifier always requires a value after it.

**Default template** — A `%` declaration with no name defines the default template. Any `# table` without a template reference (`#name`) automatically applies the default template. This is a parser-level behavior, not represented in the syntactic grammar.

**`[...]` context** — Square brackets serve two purposes: CHECK constraints in `field_decl` (e.g., `status 1 [0,1]`) and FK action lists in `foreign_key_decl` (e.g., `-> uid -> user.id [CASCADE]`). These never appear in the same production, so there is no ambiguity — `field_decl` uses `check_clause`, while `foreign_key_decl` uses `fk_action_list`.

### Modifier Resolution

| Context | Symbol | Resolved As |
|---------|--------|-------------|
| `n` / `N` / `\d+` + `+` | `+` | AUTO_INCREMENT |
| `n` / `N` / `\d+` + `++` | `++` | AUTO_INCREMENT PRIMARY KEY |
| `t` / `d` + `+` | `+` | DEFAULT CURRENT_TIMESTAMP |
| `t` / `d` + `++` | `++` | DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP |
| any type + `=` | `=` | DEFAULT value |
| any type + `!` | `!` | PRIMARY KEY |
| any type + `*` | `*` | NOT NULL |

> **Note**: `+`/`++` only have defined behavior on numeric and datetime types. Using them on other types (e.g., `s+`, `m++`) is undefined and should be avoided.

---

## 14. Design Principles

1. **Minimal syntax** — every construct is a single character or short symbol. No keywords, no braces, no quotes around names.
2. **Convention over configuration** — suffix inference (`_id`, `_on`, `_at`) and sensible defaults (no type = varchar) eliminate redundancy.
3. **Type Spec as foundation** — field types are fully delegated to [Type Spec](type.md); schema.md only adds structure and constraints.
4. **Modifier composition** — symbols like `++` compose primitive modifiers (`+` + `!` for numeric, `+` + `+` for timestamp) into common patterns.
5. **Three-layer comments** — spec (`;`) for authoring notes, SQL (`--`) for DDL comments, column (`//`) for COMMENT clauses.
6. **Template-driven** — define table patterns once, apply them everywhere. The `...` slot gives precise control over field ordering.
7. **DB-agnostic core** — symbols map to SQL standard concepts; the consuming tool handles dialect-specific DDL (MySQL, PostgreSQL, etc.).

---

## 15. FAQ

### Q1: How do I handle ENUM types?

TypeSpec doesn't have a built-in ENUM type, but you can simulate it:

```asm
; Option 1: Use CHECK constraint
status 1 [0,1,2]

; Option 2: Use VARCHAR with CHECK
type s32 ['active','inactive','deleted']

; Option 3: Use SQL directly (not in TypeSpec)
-- CREATE TABLE t (type ENUM('active','inactive','deleted'))
```

### Q2: How do I create composite foreign keys?

TypeSpec doesn't support composite foreign keys directly. You can:

1. Use multiple single-column foreign keys:

```asm
-> order_id -> order.id [CASCADE]
-> product_id -> product.id [CASCADE]
```

2. Write the SQL manually for true composite FK:

```sql
ALTER TABLE order_item ADD CONSTRAINT fk_composite
  FOREIGN KEY (order_id, product_id)
  REFERENCES order_product (order_id, product_id);
```

### Q3: How do I add CHECK constraints with complex expressions?

TypeSpec supports simple CHECK expressions. For complex ones:

```asm
; Simple (supported)
start_date d [>='2020-01-01']
end_date d [>='2020-01-01']

; Complex (not supported in TypeSpec)
; CHECK (start_date < end_date)
; CHECK (email LIKE '%@%.%')
; CHECK (JSON_VALID(settings))
```

For complex expressions, you'll need to write the SQL manually or extend TypeSpec.

### Q4: How do I handle database-specific features?

TypeSpec is DB-agnostic. For database-specific features:

1. Use SQL comments to document:

```asm
-- MySQL specific
created_at t+  ; DEFAULT CURRENT_TIMESTAMP

-- PostgreSQL specific
created_at t+  ; DEFAULT NOW()
```

2. Write the SQL manually for features not in TypeSpec.

### Q5: How do I migrate from SQL to TypeSpec?

Convert table structure → field types → modifiers → constraints. See the [Quick Start](README.md#quick-start) in README for a walkthrough example.

### Q6: Can I use TypeSpec with ORMs?

Yes! TypeSpec generates standard SQL DDL, which ORMs can work with. You can:

1. Generate DDL from TypeSpec
2. Import the schema into your ORM
3. Use the ORM for queries

### Q7: How do I handle soft deletes?

Use a template with `deleted_at`:

```asm
% soft_delete
id n++
...
deleted_at t
deleted_by n

#soft_delete user
name s32 *
email s128 *
```

This adds `deleted_at` and `deleted_by` fields to every table using the template.

### Q8: How do I version control my schemas?

1. Store TypeSpec files in Git
2. Use migration scripts for changes
3. Generate DDL for each version

Example workflow:

```bash
# Create initial schema
typespec compile schema.tps -o schema_v1.sql

# Make changes
typespec compile schema.tps -o schema_v2.sql

# Generate migration
typespec diff schema_v1.sql schema_v2.sql > migration.sql
```
