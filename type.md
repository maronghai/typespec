# Type Spec

A minimal DSL for declaring database field types using single-character symbols and suffix conventions.

## Quick Reference

| Symbol | Type | Example |
|--------|------|---------|
| `n` | int | `id n` |
| `N` | bigint | `version N` |
| `i` | smallint | `age i` |
| `\d+` | int(n) | `type 1` → int(1) |
| `\d+,\d+` | decimal(m,n) | `3,2` → decimal(3,2) |
| `m` | decimal(16,2) | `balance m` |
| `M` | decimal(20,6) | `rate M` |
| `s` | varchar | `name` (default) |
| `s\d+` | varchar(n) | `pin s100` → varchar(100) |
| `S` | text | `avatar S` |
| `b` | boolean | `active b` |
| `B` | blob | `data B` |
| `j` | json | `meta j` |
| `d` | date | `vip_on d` |
| `t` | datetime | `create_at t` |
| `T` | timestamptz | `created T` |
| `U` | uuid | `token U` |
| `p` | serial | `id p` |
| `e(...)` | ENUM('...') | `e(M,F,X)` |

**Suffix auto-inference** — when no type symbol is given:

| Suffix | Inferred Type | Example |
|--------|---------------|---------|
| `_id` | int | `group_id` → int |
| `_on` | date | `delete_on` → date |
| `_at` | datetime | `update_at` → datetime |
| *(none)* | varchar(255) | `name` → varchar(255) |

---

## 1. Type System

### 1.1 Numeric

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `n` | int | 32-bit integer |
| `N` | bigint | 64-bit integer |
| `i` | smallint | 16-bit integer |
| `\d+` | int(n) | Integer with display width |
| `\d+,\d+` | decimal(m,n) | Fixed-point: precision m, scale n |

**Notes:**

- `int(n)` — In MySQL, `n` is the display width (not storage size). `int(1)` stores the same as `int(11)`. PostgreSQL ignores this parameter. If cross-DB compatibility is needed, use `n`/`N` instead.
- `decimal(m,n)` — `m` is the total number of significant digits (including decimal places), `n` is the number of digits after the decimal point. `decimal(16,2)` stores up to 999,999,999,999.99.

### 1.2 String

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `s` | varchar | Variable-length string (default type, default length 255) |
| `s\d+` | varchar(n) | VARCHAR with explicit max length |
| `S` | text | Unlimited-length text |

When a field has no type symbol, it defaults to `s` (varchar). This makes the syntax clean for the most common case.

> **Note**: Bare `s` is equivalent to omitting the type entirely — both produce `varchar(255)`. Omitting saves 1 keystroke — use explicit `s` only when readability requires it. Use `s\d+` (e.g., `s100`) to specify a different length.

### 1.3 Boolean

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `b` | boolean | True/false value (MySQL: tinyint(1)) |

### 1.4 Date & Time

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `d` | date | Date only (YYYY-MM-DD) |
| `t` | datetime | Date + time (YYYY-MM-DD HH:MM:SS) |
| `T` | timestamptz | Timestamp with time zone |

### 1.5 Money

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `m` | decimal(16,2) | Standard currency (up to 999,999,999,999.99) |
| `M` | decimal(20,6) | High-precision currency / exchange rates |

### 1.6 Binary & JSON

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `B` | blob | Binary data (images, files, serialized objects) |
| `j` | json | JSON document (MySQL 5.7+, PostgreSQL, etc.) |

### 1.7 UUID & Serial

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `U` | uuid | UUID type (PG: native uuid; MySQL: char(36); SQLite: TEXT) |
| `p` | serial | Auto-incrementing integer (PG: serial; MySQL/SQLite: int) |

### 1.8 Enum

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `e(v1,v2,...)` | ENUM('v1','v2',...) | Enumeration with fixed values |
| `e('v1','v2',...)` | ENUM('v1','v2',...) | Enumeration with quoted values |

Enum values are comma-separated words (or quoted strings) inside parentheses. They can be combined with modifiers:

```asm
gender   e(M,F,X) *                ; ENUM('M','F','X') NOT NULL
status   e(pending,active,closed) =pending   ; ENUM(...) DEFAULT 'pending'
role     e(admin,user,guest)       ; ENUM('admin','user','guest')

; Quoted values for strings with special characters
name     e('admin user','guest')   ; ENUM('admin user','guest')
code     e('A-B','C-D')            ; ENUM('A-B','C-D')
```

```sql
`gender` ENUM('M', 'F', 'X') NOT NULL,
`status` ENUM('pending', 'active', 'closed') DEFAULT 'pending',
`role`   ENUM('admin', 'user', 'guest'),
`name`   ENUM('admin user', 'guest'),
`code`   ENUM('A-B', 'C-D')
```

> **Note**: Unquoted enum values must be bare words (no spaces or special characters). For values with spaces or special characters, use quoted syntax: `e('value with spaces')`.

---

## 2. Naming Conventions

Suffix-based type inference removes redundant type symbols from field names:

```asm
group_id          ; suffix _id  → int (no symbol needed)
vip_on            ; suffix _on  → date
create_at         ; suffix _at  → datetime
delete_on         ; suffix _on  → date
update_at         ; suffix _at  → datetime
```

When a suffix conflicts with an explicit symbol, the **explicit symbol wins**:

```asm
create_at t       ; _at says datetime, explicit t confirms → datetime
vip_on d          ; _on says date, explicit d confirms → date
user_id s32       ; _id says int, explicit s32 overrides → varchar(32)
```

### Type-Modifier Fusion

Type symbols can be fused with certain modifiers to save 1 keystroke:

| Fused | Equivalent | Meaning |
|-------|-----------|---------|
| `n!` | `n !` | int PRIMARY KEY |
| `n*` | `n *` | int NOT NULL |
| `s32!` | `s32 !` | varchar(32) PRIMARY KEY |
| `s128*` | `s128 *` | varchar(128) NOT NULL |
| `n++` | `n ++` | int AUTO_INCREMENT PRIMARY KEY (existing) |
| `n+` | `n +` | int AUTO_INCREMENT (existing) |
| `+n` | `n u` | int UNSIGNED |
| `+N` | `N u` | bigint UNSIGNED |
| `+i` | `i u` | smallint UNSIGNED |

The parser recognizes `!`, `*`, and `+` prefix on type tokens for unsigned, in addition to the existing `+` and `++` suffix handling.

---

## 3. Type Symbol Grammar

The complete type symbol EBNF is defined in [`grammar.ebnf`](grammar.ebnf). Here is a summary of the productions:

| Production | Definition |
|------------|-----------|
| `type_symbol` | `numeric_type \| money_type \| string_type \| enum_type \| atomic_type` |
| `numeric_type` | `int_short \| int_explicit \| decimal_explicit` |
| `int_short` | `"n" \| "N" \| "i"` |
| `int_explicit` | `positive_int` (e.g. `128` → int(128)) |
| `decimal_explicit` | `positive_int, ",", positive_int` (e.g. `16,2` → decimal(16,2)) |
| `money_type` | `"m" \| "M"` |
| `string_type` | `varchar_short \| varchar_explicit \| text_type` |
| `varchar_short` | `"s"` |
| `varchar_explicit` | `"s", positive_int` (e.g. `s128` → varchar(128)) |
| `text_type` | `"S"` |
| `enum_type` | `"e", "(", (word \| string_literal), {",", (word \| string_literal)}, ")"` |
| `atomic_type` | `"b" \| "B" \| "j" \| "d" \| "t" \| "T" \| "U" \| "p"` |

### Disambiguation

- `s` alone → `varchar_short` (varchar)
- `s` followed by digits → `varchar_explicit` — parser uses **longest match**
- `,` in `int_explicit` vs `decimal_explicit` — presence of `,` disambiguates: `128` → int, `16,2` → decimal

### Suffix Inference (Semantic Layer)

When no `type_symbol` is present, a **semantic pass** infers the type from the field name suffix:

```
field_name ends with "_id"  → int
field_name ends with "_on"  → date
field_name ends with "_at"  → datetime
otherwise                    → varchar
```

This is not part of the syntactic grammar — it is a post-parse resolution step.

---

## 4. Usage

### 4.1 Basic Field Declaration

```asm
; ── Numeric ──
id        n               ; int
group_id                  ; int (suffix _id)
type      1               ; int(1)
version   N               ; bigint
age       i               ; smallint
balance   m               ; decimal(16, 2)
rate      M               ; decimal(20, 6)

; ── String ──
name                    ; varchar (default)
pin       s100          ; varchar(100)
bio       s512          ; varchar(512)
avatar    S             ; text

; ── Boolean / Binary / JSON ──
active    b             ; boolean
data      B             ; blob
meta      j             ; json

; ── Date & Time ──
vip_on    d             ; date
delete_on               ; date (suffix _on)
create_at t             ; datetime
update_at               ; datetime (suffix _at)
created   T             ; timestamptz

; ── UUID / Serial ──
token     U             ; uuid
id        p             ; serial
```

### 4.2 User Table

```asm
id          n           ; int
username    s32         ; varchar(32)
email       s128        ; varchar(128)
password    s256        ; varchar(256)
avatar      S           ; text
is_admin    b           ; boolean
balance     m           ; decimal(16,2)
settings    j           ; json
token       U           ; uuid
created_at  t           ; datetime
updated_at              ; datetime (suffix _at)
deleted_on              ; date (suffix _on)
```

### 4.3 Order Table

```asm
id          n           ; int
order_no    s64         ; varchar(64)
user_id                   ; int (suffix _id)
amount      m           ; decimal(16,2)
discount    M           ; decimal(20,6)
status      1           ; int(1)
note        s512        ; varchar(512)
payload     B           ; blob
paid_on     d           ; date
created_at  t           ; datetime
```

---

## 5. Regex Specification

Type symbols can be parsed via regular expression. The spec uses [ZZ](https://github.com/maronghai/zz) multi-line format for readability, then compiles to a single regex.

### 5.1 ZZ Multi-line Format

Each line starting with `|` is a regex alternation branch. Comments after `;` are ignored:

```
n             ; int
|N            ; bigint
|i            ; smallint

|m            ; decimal(16,2)
|M            ; decimal(20,6)

|\d+          ; int(n)
|\d+,\d+      ; decimal(m,n)

|s\d+          ; varchar with explicit length
|S            ; text
|b            ; boolean
|B            ; blob
|j            ; json
|t            ; datetime
|d            ; date
|T            ; timestamptz
|U            ; uuid
|p            ; serial
```

### 5.2 Compiled Regex

ZZ concatenates the branches into a single alternation, wrapped with word boundaries:

```
\b(?:[nNiImMSBbdjtTUp]|\d+(?:,\d+)?|s\d+|e\([^)]+\))\b
```

**Breakdown:**

| Segment | Matches |
|---------|---------|
| `[nNiImMSBbdjtTUp]` | Single-character type symbols (`n`=int, `N`=bigint, `i`=smallint, `m`=decimal(16,2), etc.) |
| `e\([^)]+\)` | Enum type: `e(M,F,X)`, `e(pending,active,closed)`, etc. |
| `s\d+` | VARCHAR with explicit length: `s100`, `s32`, etc. (note: `s` alone is also in the character class above) |
| `\d+(?:,\d+)?` | Numeric: `int(n)` (e.g. `128`) or `decimal(m,n)` (e.g. `16,2`) |
| `?` (outer) | Entire type is optional — when absent, suffix inference applies |
| `\b` | Word boundary — prevents partial matches |

> **Note:** The ZZ format lists `|s` (bare varchar) as a separate branch, but it is absorbed into the `[nNmMSBbdjt]` character class in the compiled form. Both produce identical matching behavior.

---

## 6. Dialect Mapping

TypeSpec generates SQL DDL for different database dialects using the `-d` flag.

### MySQL (default)

```bash
typespec schema.tps              # MySQL DDL
typespec schema.tps -d mysql     # explicit MySQL
```

### PostgreSQL

```bash
typespec schema.tps -d pg        # PostgreSQL DDL
typespec schema.tps -d postgres  # alias
```

### Type Mapping by Dialect

| Symbol | MySQL | PostgreSQL | Notes |
|--------|-------|-----------|-------|
| `n` | `int` | `integer` | Same 4-byte integer |
| `N` | `bigint` | `bigint` | Same 8-byte integer |
| `i` | `smallint` | `smallint` | Same 2-byte integer |
| `m` | `decimal(16,2)` | `numeric(16,2)` | Equivalent types |
| `M` | `decimal(20,6)` | `numeric(20,6)` | Equivalent types |
| `s` / `s\d+` | `varchar(n)` | `varchar(n)` | Same |
| `S` | `text` | `text` | Same |
| `b` | `boolean` | `boolean` | Same (MySQL stores as tinyint(1)) |
| `B` | `blob` | `bytea` | PG uses bytea for binary |
| `j` | `json` | `json` | Same |
| `d` | `date` | `date` | Same |
| `t` | `datetime` | `timestamp` | PG has no datetime type |
| `T` | `timestamp` | `timestamptz` | Timestamp with time zone |
| `U` | `char(36)` | `uuid` | PG has native uuid; MySQL uses char(36) |
| `p` | `int` | `serial` | Auto-incrementing integer |
| `e(...)` | `ENUM(...)` | `text` + `CHECK` | PG: text column with CHECK constraint |
| `\d+` (int width) | `int(n)` | `integer` | PG ignores display width |
| `+n` / `+N` / `+i` | `UNSIGNED` | *(ignored)* | PG has no UNSIGNED |
| `n++` | `AUTO_INCREMENT` | `GENERATED ALWAYS AS IDENTITY` | SQL standard identity |
| `t+` | `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP` | `DEFAULT CURRENT_TIMESTAMP` | PG has no ON UPDATE |

### PostgreSQL-Specific DDL

| Feature | MySQL | PostgreSQL |
|---------|-------|-----------|
| Identifier quoting | `` `name` `` | `"name"` |
| Table options | `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4` | *(none)* |
| Table comments | `COMMENT='...'` | `COMMENT ON TABLE ... IS '...'` |
| Column comments | `COMMENT '...'` | `COMMENT ON COLUMN ... IS '...'` |
| CREATE DATABASE | `CHARACTER SET utf8mb4` | `ENCODING 'UTF8'` |
| FULLTEXT INDEX | `FULLTEXT INDEX` | *(not supported inline)* |

---

## 7. Design Principles

1. **One character = one type** — every symbol is a single lowercase/uppercase letter, easy to type and parse.
2. **Convention over configuration** — suffix inference (`_id`, `_on`, `_at`) eliminates redundant declarations.
3. **Explicit when needed** — `s100` for arbitrary lengths.
4. **Defaults are sensible** — no type symbol → varchar, since strings are the most common field type.
5. **DB-agnostic** — symbols map to SQL standard types; the consuming tool (DB Spec) handles dialect-specific DDL.
6. **Lowercase for core, uppercase for variants** — `n`/`s`/`b`/`j`/`d`/`t` are core; `N`/`M`/`S`/`B`/`T`/`U` are variants. `i` and `p` are lowercase exceptions for smallint and serial.

---

## 8. FAQ

### Q1: What's the difference between `n`, `N`, and `i`?

- `n` = INT (32-bit, up to 2.1 billion)
- `N` = BIGINT (64-bit, up to 9.2 quintillion)
- `i` = SMALLINT (16-bit, up to 32,767)

Use `n` for most IDs and counters. Use `N` for large numbers. Use `i` for small values like age, status codes, or flags.

### Q2: How do I choose between `s` and `s\d+`?

- `s` = VARCHAR (default, no length limit specified)
- `s100` = VARCHAR(100) (explicit length)

Use `s\d+` when you need a specific length.

### Q3: What's the difference between `m` and `M`?

- `m` = DECIMAL(16,2) (up to 999,999,999,999.99)
- `M` = DECIMAL(20,6) (up to 999,999,999,999,999,999.999999)

Use `m` for standard currency. Use `M` for high-precision values like exchange rates.

### Q4: How does suffix inference work?

When no type symbol is given, the field name's suffix determines the type:

```asm
group_id    ; suffix _id → INT
vip_on      ; suffix _on → DATE
update_at   ; suffix _at → DATETIME
name        ; no suffix → VARCHAR (default)
```

### Q5: Can I override suffix inference?

Yes! Explicit type symbols override suffix inference:

```asm
create_at t   ; _at says DATETIME, explicit t confirms → DATETIME
vip_on d      ; _on says DATE, explicit d confirms → DATE
user_id s32   ; _id says INT, explicit s32 overrides → VARCHAR(32)
```

### Q6: What about BOOLEAN type?

TypeSpec uses `b` for BOOLEAN. In MySQL, this maps to `TINYINT(1)`:

```asm
active b       ; BOOLEAN (MySQL: TINYINT(1))
is_admin b =0  ; BOOLEAN DEFAULT 0
```

### Q7: How do I handle JSON fields?

Use `j` for JSON:

```asm
settings j     ; JSON type
metadata j     ; JSON type
```

Note: JSON support varies by database (MySQL 5.7+, PostgreSQL, etc.).

### Q8: How do I use UUID or serial types?

Use `U` for UUID and `p` for serial:

```asm
token     U             ; uuid (PG: native uuid; MySQL: char(36))
id        p             ; serial (PG: serial; MySQL/SQLite: int)
```

`U` is especially useful for primary keys in PostgreSQL. `p` provides a shorthand for auto-incrementing integer columns.

### Q9: Can I use spaces in field names?

No. Field names must follow SQL identifier rules:

```asm
; Valid
user_name
email
create_at

; Invalid
user name      ; Space not allowed
user-name      ; Hyphen not allowed
```

### Q10: How do I handle reserved words?

Avoid using SQL reserved words as field names. If you must, you'll need to quote them in the generated SQL:

```asm
; These are reserved words in SQL:
order
select
table
```

**Recommendation**: Use descriptive names like `order_no`, `select_option`, `table_name`.

### Q11: How do I generate PostgreSQL DDL?

Use the `-d pg` flag:

```bash
typespec schema.tps -d pg        # PostgreSQL output
typespec reverse -d pg schema.sql  # Reverse-engineer PG DDL
```

TypeSpec maps `n` → `integer`, `t` → `timestamp`, `T` → `timestamptz`, `U` → `uuid`, `p` → `serial`, `B` → `bytea`, `e(...)` → `text` + `CHECK`, and `n++` → `GENERATED ALWAYS AS IDENTITY` for PostgreSQL.
