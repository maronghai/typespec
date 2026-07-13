# Schema Spec

A minimal DSL for declaring database schemas using single-character symbols. Built on [Type Spec](type.md) for field types.

---

## Contents

1. [Schema & Table](#1-schema--table)
2. [Fields & Modifiers](#2-fields--modifiers)
3. [Comments](#3-comments)
4. [Primary Keys](#4-primary-keys)
5. [Foreign Keys](#5-foreign-keys)
6. [Indexes](#6-indexes)
7. [CHECK Constraints](#7-check-constraints)
8. [Templates](#8-templates)
9. [Grammar & Diagnostics](#9-grammar--diagnostics)
10. [FAQ](#10-faq)

---

## 1. Schema & Table

```asm
$ schema_name [charset] [autofk]    ; charset default utf8mb4, one $ per file
^ [EngineName]                       ; table engine (^ alone = default InnoDB)
# table_name  : comment              ; table with optional comment
#base table_name  : comment          ; table using template
```

### Custom Types

Define type aliases in the schema block using `~`:

```asm
$ mydb
  ~ uuid s36                    ; varchar(36) everywhere
  ~ email s128                  ; varchar(128) everywhere
  ~ ip_addr mysql=s45 postgres=inet sqlite=s45  ; dialect-specific
```

Custom types can be used as field types:

```asm
# user
uuid uuid *                          ; resolves to varchar(36)
email email *                        ; resolves to varchar(128)
ip ip_addr                           ; MySQL: varchar(45), PG: inet
```

`autofk` auto-generates FK + INDEX for `_id` suffix fields if the referenced table exists.

### Engine

```asm
^MyISAM                     ; standalone: all following tables use MyISAM
# log ^MEMORY : cache表      ; inline: only this table uses MEMORY
```

| DSL | SQL |
|-----|-----|
| `^` or omitted | `ENGINE=InnoDB` |
| `^MyISAM` | `ENGINE=MyISAM` |
| `^MEMORY` | `ENGINE=MEMORY` |

Engine applies to the next `#` table block. Default is InnoDB when omitted.

### Minimal Example

```asm
# user

id n++
name s32
```

```sql
CREATE TABLE `user` (
  `id`   int AUTO_INCREMENT PRIMARY KEY,
  `name` varchar(32)
)
```

---

## 2. Fields & Modifiers

### Field Declaration

```asm
field_name  [type_symbol]  [modifier...]  [check]  [: | -- | ; comment]
```

**Suffix inference** (no type symbol needed):

| Suffix | Type | Example |
|--------|------|---------|
| `_id` | int | `user_id` → int |
| `_on` | date | `paid_on` → date |
| `_at` | datetime | `created_at` → datetime |
| *(none)* | varchar(255) | `name` → varchar(255) |

### Modifiers

| Symbol | Meaning | Type | Example |
|--------|---------|------|---------|
| `+` | AUTO_INCREMENT / CURRENT_TIMESTAMP | numeric / datetime | `id n+` / `ts +` |
| `++` | + PRIMARY KEY / ON UPDATE | numeric / datetime | `id n++` / `ts ++` |
| `!` | PRIMARY KEY | any | `id n!` |
| `=` | DEFAULT value | any | `status 1 =0` |
| `*` | NOT NULL | any | `name s32 *` |
| `*=` | NOT NULL + DEFAULT | any | `status 1 *=0` |
| `u` | UNSIGNED | numeric | `count nu` |
| `@` / `@u` | INDEX / UNIQUE INDEX | any | `name s32 @` |
| `[...]` | CHECK constraint | any | `age n [0,150]` |
| `:` | COMMENT clause | — | `name : 用户名` |

**Notes:**
- `=` must be directly attached to value (`=0`, not `= 0`). SQL keywords emitted bare; others auto-quoted.
- `+`/`++` on numeric types → AUTO_INCREMENT; on datetime types → timestamp defaults.
- Inline FULLTEXT (`@f`) not supported — use standalone `@f field_name`.

### Example

```asm
# user

id          n++
username    s32
email       s128
avatar      S
is_admin    b
balance     m
created_at  +
updated_at  ++
deleted_on
```

```sql
CREATE TABLE `user` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `username`   varchar(32),
  `email`      varchar(128),
  `avatar`     text,
  `is_admin`   boolean,
  `balance`    decimal(16, 2),
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_on` date
)
```

---

## 3. Comments

| Symbol | Type | Output |
|--------|------|--------|
| `;` | Spec comment | Stripped |
| `--` | SQL comment | Passed to DDL |
| `:` | COMMENT clause | Table/column |

```asm
# user  : TABLE OF USER

id    n++   : auto-increment id
name  s32   : username, unique
```

```sql
CREATE TABLE `user` (
  `id`   int AUTO_INCREMENT PRIMARY KEY COMMENT 'auto-increment id',
  `name` varchar(32) COMMENT 'username, unique'
  COMMENT = 'TABLE OF USER'
)
```

> **Note**: `--` comments inside `%` or `#` blocks are silently ignored.

---

## 4. Primary Keys

**Single column**: `id n++` (AUTO_INCREMENT) or `code s32!` (no auto increment).

**Composite** — use `!` at start of line with space-separated field names:

```asm
# order_item

order_id
product_id
quantity   n

! order_id product_id
```

```sql
CREATE TABLE `order_item` (
  `order_id`   int,
  `product_id` int,
  `quantity`   int,
  PRIMARY KEY (`order_id`, `product_id`)
)
```

---

## 5. Foreign Keys

### FK Variations

| Form | Syntax | Infers |
|------|--------|--------|
| Standard | `field > table.field` | — |
| Without dot | `field table` | ref = `id` |
| Trailing dot | `field table.` | ref = field_name |
| Ultra | `> table.field` | local = `{table}_id` |
| Ultra without dot | `> table` | local = `{table}_id`, ref = `id` |

### FK Actions

Append action tokens after the FK reference to specify referential behavior:

| Token | Meaning | SQL |
|-------|---------|-----|
| `C` | ON UPDATE CASCADE | `ON UPDATE CASCADE` |
| `N` | ON UPDATE SET NULL | `ON UPDATE SET NULL` |
| `-C` | ON DELETE CASCADE | `ON DELETE CASCADE` |
| `-N` | ON DELETE SET NULL | `ON DELETE SET NULL` |

RESTRICT / NO ACTION is the default — omit tokens for no action.

```asm
; Cascading deletes and updates
> user_id user.id -C C

; Delete cascade only (update defaults to RESTRICT)
> order_id order.id -C

; Set null on delete, cascade on update
> coupon_id coupon.id -N C

; Inline FK with actions
user_id n > user.id -C C
```

```sql
FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE ON UPDATE CASCADE,
FOREIGN KEY (`coupon_id`) REFERENCES `coupon`(`id`) ON DELETE SET NULL ON UPDATE CASCADE
```

### Inline FK (Recommended)

```asm
# order

id          n++
order_no    s64 *
user_id     > user.id                  ; inline FK
amount      m *
```

```sql
CREATE TABLE `order` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `order_no`   varchar(64) NOT NULL,
  `user_id`    int,
  `amount`     decimal(16, 2) NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`)
)
```

### Standalone FK

```asm
> user_id user.id    ; shorthand
> user.id            ; ultra shorthand
> user               ; ultra without .id
> user_id user       ; without dot
> order_no order.    ; trailing dot
```

All forms produce the same DDL.

### Multiple FK Example

```asm
# order_item

order_id
product_id
quantity    n =1

> order.id
> product.id
```

```sql
CREATE TABLE `order_item` (
  `order_id`   int,
  `product_id` int,
  `quantity`   int DEFAULT 1,
  FOREIGN KEY (`order_id`)   REFERENCES `order`(`id`),
  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`)
)
```

> **Tip**: To document FK intent without DDL: `user_id ; -> user.id`.

---

## 6. Indexes

### Syntax

| Form | Example | Output |
|------|---------|--------|
| Full (with name) | `@ idx_name (name)` | `INDEX idx_name (name)` |
| Shorthand | `@ name` | `INDEX idx_name (name)` |
| Shorthand composite | `@ status created_at` | `INDEX idx_status_created_at (status, created_at)` |
| DESC | `@ name- created_at` | `INDEX idx_name_created_at (name DESC, created_at)` |
| Unique | `@u email` | `UNIQUE INDEX uk_email (email)` |
| Unique composite | `@u name email` | `UNIQUE INDEX uk_name_email (name, email)` |
| Fulltext | `@f content` | `FULLTEXT INDEX ft_content (content)` |

**Naming conventions**: `idx_` (regular), `uk_` (unique), `fk_` (FK), `ft_` (fulltext).

**Limitations**: No unique fulltext (`@fu`), prefix indexes, descending indexes, partial indexes, or expression indexes — write SQL manually for these.

---

## 7. CHECK Constraints

### Syntax

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

### Disambiguation Rules

| Pattern | Example | SQL Output |
|---------|---------|------------|
| `[a,b]` — 2 bare numbers | `[0,150]` | `CHECK (field BETWEEN 0 AND 150)` |
| `[a,b)` — upper exclusive | `[0,150)` | `CHECK (field >= 0 AND field < 150)` |
| `(a,b]` — lower exclusive | `(0,150]` | `CHECK (field > 0 AND field <= 150)` |
| `(a,b)` — both exclusive | `(0,150)` | `CHECK (field > 0 AND field < 150)` |
| `{a,b,c,…}` — IN list | `{0,1,2}` | `CHECK (field IN (0, 1, 2))` |
| `{>X}` / `{>=X}` / `{<X}` / `{<=X}` | `{>0}` | `CHECK (field > 0)` |
| `{op a, op b}` — compound | `{>=0, <=1}` | `CHECK (field >= 0 AND field <= 1)` |

> **Note**: `[a,b]` uses BETWEEN (inclusive). Use `{a,b}` for IN lists with 2+ values.

### Example

```asm
# user

id          n++
username    s32 *
age         n =0 [0,150]
status      n =0 {0,1,2}
balance     m =0 {>=0}
type        s32 {'a','b','c'}
```

```sql
CREATE TABLE `user` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `username`   varchar(32) NOT NULL,
  `age`        int DEFAULT 0 CHECK (age BETWEEN 0 AND 150),
  `status`     int DEFAULT 0 CHECK (status IN (0, 1, 2)),
  `balance`    decimal(16, 2) DEFAULT 0 CHECK (balance >= 0),
  `type`       varchar(32) CHECK (type IN ('a', 'b', 'c'))
)
```

---

## 8. Templates

Templates define reusable table skeletons with `...` slot for field insertion.

| Type | Syntax | Usage |
|------|--------|-------|
| Named | `% name` | `#name table` |
| Default | `%` | `# table` (no template ref) |
| Inheritance | `% child > parent` | Inherits parent fields |
| Mixin | `% child p1 + p2` | Merges multiple parents |

### Default Template

Unnamed `%` is the default — applied to any `#` table without a template reference:

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

> **Rule**: If multiple unnamed `%` exist, the **last** one is the default.

### Named Template

```asm
% audit

id n++
...
create_at +
update_at ++

#audit order

order_no s64
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
```

### Template Inheritance

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
```

### Template Mixins

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
```

Each parent is resolved sequentially. Name conflicts → later parent wins. Max **4 parents**.

```asm
# user_mixin user

phone s16
```

```sql
CREATE TABLE `user` (
  `id`         int AUTO_INCREMENT PRIMARY KEY,
  `version`    bigint,
  `deleted_at` datetime,
  `deleted_by` int,
  `name`       varchar(32) NOT NULL,
  `email`      varchar(128) NOT NULL,
  `phone`      varchar(16)
)
```

### Slot Merge Algorithm

1. **Resolve parent** recursively
2. **Split parent** → `parent_before` + `parent_after`
3. **Split child** → `child_before` + `child_after`
4. **Merge**: `parent_before + child_before + <concrete> + child_after + parent_after`
5. **Name conflicts** → child replaces parent (full override)

If child doesn't redefine `...`, use parent's slot position.

### Inheritance Rules

1. Child inherits all parent fields
2. Child can redefine `...` position
3. Field order: parent_before + child_before + concrete + child_after + parent_after
4. Name conflicts: child **completely replaces** parent (full override)
5. Multiple inheritance via `+`: parents merged sequentially, later wins
6. Circular inheritance detected → error

### Multi-level Inheritance Example

```asm
% base
id n++
...
version N
status 1 =0
create_at +
update_at ++

% audit > base
...
deleted_at
deleted_by n

% soft_delete > audit
...
restore_token s64

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

## 9. Grammar & Diagnostics

The full EBNF grammar is in [`grammar.ebnf`](grammar.ebnf). Key notes:

**`field_name` vs `word`** — `field_name` allows leading digit (`128`), `word` requires leading letter/underscore.

**Ambiguity** — `128 status` is ambiguous. Parser resolves by context: if second token is known type, it's the type; otherwise, first token is field name.

**Modifier context-sensitivity** — `+`/`++` meaning depends on type symbol (semantic layer, not syntactic).

**Default template** — `%` with no name is default for all `#` tables without template reference.

**`[...]` context** — Square brackets denote CHECK constraints, never used in FK declarations.

### Diagnostic Messages

```
warning: unrecognized token 'foo' in field 'bar' (line 5)
warning: 'auto_increment' modifier invalid for this type (line 3)
warning: shorthand index is single-column only (line 5)
warning: unrecognized FK form on line 8
```

---

## 10. FAQ

### Q1: ENUM types?

```asm
status  e(pending,active,closed)     ; ENUM('pending','active','closed')
gender  e(M,F,X) *                   ; ENUM('M','F','X') NOT NULL
role    e('admin user','guest')      ; ENUM('admin user','guest')
```

### Q2: Complex CHECK expressions?

TypeSpec supports simple CHECK (see [§7](#7-check-constraints)). For complex ones, write SQL manually.

### Q3: Database-specific features?

TypeSpec is DB-agnostic. Use SQL comments for DB-specific behavior:

```asm
-- MySQL
created_at +   ; DEFAULT CURRENT_TIMESTAMP

-- PostgreSQL
created_at +   ; DEFAULT NOW()
```

### Q4: Migration from SQL?

Convert table structure → field types → modifiers → constraints. See [Quick Start](README.md#quick-start).

### Q5: ORM integration?

Yes. Generate DDL → import into ORM → use ORM for queries.

### Q6: Soft deletes?

```asm
% soft_delete
id n++
...
deleted_at
deleted_by n

#soft_delete user
name s32 *
email s128 *
```

### Q7: FK actions?

```asm
> user_id user.id -S S     ; ON DELETE CASCADE ON UPDATE CASCADE
> coupon_id coupon.id -N S ; ON DELETE SET NULL ON UPDATE CASCADE
> order_id order.id -S     ; ON DELETE CASCADE only
```

`-C` = ON DELETE CASCADE, `-N` = ON DELETE SET NULL, `C` = ON UPDATE CASCADE, `N` = ON UPDATE SET NULL. Omit for RESTRICT (default).

### Q8: Version control?

```bash
cd zig-typespec && zig build
./zig-out/bin/typespec ../schema_v1.tps -o v1.sql
./zig-out/bin/typespec ../schema_v2.tps -o v2.sql
diff v1.sql v2.sql
```

---

## Design Principles

1. **Minimum keystrokes** — single-character types, fused modifiers, shorthand indexes, suffix inference
2. **Minimal syntax** — no keywords, no braces, no quotes around names
3. **Convention over configuration** — suffix inference, sensible defaults
4. **Shorthand where unambiguous** — single-column indexes, FKs omit redundant names
5. **Type Spec as foundation** — field types delegated to [Type Spec](type.md)
6. **Modifier composition** — `++` = `+` + `!` (numeric) or `+` + `+` (timestamp)
7. **Three-layer comments** — spec (`;`), SQL (`--`), column (`:`)
8. **Template-driven** — define once, apply everywhere with `...` slot
9. **DB-agnostic core** — symbols map to SQL standard; tool handles dialects
10. **FK actions as postfix** — `-C`/`-N`/`C`/`N` appended to FK reference, no extra syntax
