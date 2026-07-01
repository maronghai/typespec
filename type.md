# Type Spec

A minimal DSL for declaring database field types using single-character symbols and suffix conventions.

## Quick Reference

| Symbol | Type | Example |
|--------|------|---------|
| `n` | int | `id n` |
| `N` | bigint | `version N` |
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

**Suffix auto-inference** — when no type symbol is given:

| Suffix | Inferred Type | Example |
|--------|---------------|---------|
| `_id` | int | `group_id` → int |
| `_on` | date | `delete_on` → date |
| `_at` | datetime | `update_at` → datetime |
| *(none)* | varchar | `name` → varchar |

---

## 1. Type System

### 1.1 Numeric

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `n` | int | 32-bit integer |
| `N` | bigint | 64-bit integer |
| `\d+` | int(n) | Integer with display width |
| `\d+,\d+` | decimal(m,n) | Fixed-point: precision m, scale n |

**Notes:**

- `int(n)` — In MySQL, `n` is the display width (not storage size). `int(1)` stores the same as `int(11)`. PostgreSQL ignores this parameter. If cross-DB compatibility is needed, use `n`/`N` instead.
- `decimal(m,n)` — `m` is the total number of significant digits (including decimal places), `n` is the number of digits after the decimal point. `decimal(16,2)` stores up to 999,999,999,999.99.

### 1.2 String

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `s` | varchar | Variable-length string (default type) |
| `s\d+` | varchar(n) | VARCHAR with explicit max length |
| `S` | text | Unlimited-length text |

When a field has no type symbol, it defaults to `s` (varchar). This makes the syntax clean for the most common case.

### 1.3 Boolean

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `b` | boolean | True/false value (MySQL: tinyint(1)) |

### 1.4 Date & Time

| Symbol | SQL Type | Description |
|--------|----------|-------------|
| `d` | date | Date only (YYYY-MM-DD) |
| `t` | datetime | Date + time (YYYY-MM-DD HH:MM:SS) |

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

---

## 3. Type Symbol Grammar

Type symbols are defined in EBNF (see [Schema Spec §13](schema.md#13-ebnf-grammar) for the full grammar including fields, modifiers, and constraints):

```ebnf
type_symbol      = numeric_type
                 | money_type
                 | string_type
                 | atomic_type ;

(* ── Numeric ── *)

numeric_type     = int_short | int_explicit | decimal_explicit ;
int_short        = "n" | "N" ;
int_explicit     = positive_int ;
decimal_explicit = positive_int, ",", positive_int ;
positive_int     = digit, { digit } ;

(* ── Money ── *)

money_type       = "m" | "M" ;

(* ── String ── *)

string_type      = varchar_short | varchar_explicit | text_type ;
varchar_short    = "s" ;
varchar_explicit = "s", positive_int ;
text_type        = "S" ;

(* ── Atomic ── *)

atomic_type      = "b" | "B" | "j" | "d" | "t" ;
```

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
```

### 5.2 Compiled Regex

ZZ concatenates the branches into a single alternation, wrapped with word boundaries:

```
\b(?:[nNmMSBbdjt]|\d+(?:,\d+)?|s\d+)?\b
```

**Breakdown:**

| Segment | Matches |
|---------|---------|
| `[nNmMSBbdjt]` | Single-character type symbols |
| `\d+(?:,\d+)?` | Numeric: `int(n)` or `decimal(m,n)` |
| `s\d+` | String with explicit length: `s100`, `s32`, etc. |
| `\b` | Word boundary — prevents partial matches |

---

## 6. Design Principles

1. **One character = one type** — every symbol is a single lowercase/uppercase letter, easy to type and parse.
2. **Convention over configuration** — suffix inference (`_id`, `_on`, `_at`) eliminates redundant declarations.
3. **Explicit when needed** — `s100` for arbitrary lengths.
4. **Defaults are sensible** — no type symbol → varchar, since strings are the most common field type.
5. **DB-agnostic** — symbols map to SQL standard types; the consuming tool (DB Spec) handles dialect-specific DDL.

---

## 7. FAQ

### Q1: What's the difference between `n` and `N`?

- `n` = INT (32-bit, up to 2.1 billion)
- `N` = BIGINT (64-bit, up to 9.2 quintillion)

Use `n` for most IDs and counters. Use `N` for large numbers or timestamps.

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

### Q8: Can I use spaces in field names?

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

### Q9: How do I handle reserved words?

Avoid using SQL reserved words as field names. If you must, you'll need to quote them in the generated SQL:

```asm
; These are reserved words in SQL:
order
select
table
```

**Recommendation**: Use descriptive names like `order_no`, `select_option`, `table_name`.
