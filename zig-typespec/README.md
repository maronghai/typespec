# zig-typespec

A compiler that transforms `.tps` schema files into MySQL or PostgreSQL DDL SQL. Written in Zig 0.16.

Supports forward compilation (`.tps` → SQL), reverse engineering (SQL → `.tps`), schema diff, and migration generation.

## Build

```bash
zig build
```

Output binary: `zig-out/bin/typespec`

## Usage

```
typespec <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `typespec <file.tps>` | Compile a `.tps` file to SQL DDL |
| `typespec reverse <file.sql>` | Reverse-engineer SQL DDL to `.tps` schema |
| `typespec diff <old.tps> <new.tps>` | Show schema differences between two versions |
| `typespec migrate <old.tps> <new.tps>` | Generate migration SQL (transaction-wrapped) |

### Options

| Option | Description |
|--------|-------------|
| `-o <file>` | Write output to file instead of stdout |
| `-t` | Show compilation trace / extract templates (reverse) |
| `-d, --dialect <dialect>` | Target SQL dialect: `mysql` (default), `pg`, `postgres` |

### Pipe Mode

Read from stdin when no input file is given. Detects TTY automatically — shows usage in interactive terminals, reads pipe data otherwise.

```bash
# Compile .tps from pipe
echo '# t
id n++
name s32 *' | typespec

# Reverse-engineer SQL from pipe
cat schema.sql | typespec reverse

# Reverse-engineer with template extraction
cat schema.sql | typespec reverse -t

# Using - as explicit stdin
typespec reverse - < schema.sql
```

### Compile

```bash
# Print MySQL DDL to stdout (default)
typespec schema.tps

# Print PostgreSQL DDL
typespec schema.tps -d pg

# Write to file
typespec schema.tps -o schema.sql

# PostgreSQL output to file
typespec schema.tps -d pg -o schema_pg.sql

# Show compilation pipeline trace
typespec schema.tps -t
```

**Flags:**

| Flag | Description |
|------|-------------|
| `-o <file>` | Write output to file instead of stdout |
| `-t` | Print diagnostic trace for each pipeline stage (tokenizer → parser → semantic → codegen) |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Compilation error (syntax, unknown token, etc.) |

### Reverse

Reverse-engineers MySQL DDL SQL back into `.tps` schema files.

```bash
# Print to stdout
typespec reverse schema.sql

# Write to file
typespec reverse schema.sql -o schema.tps

# Extract shared templates across tables
typespec reverse schema.sql -t -o schema.tps
```

**Flags:**

| Flag | Description |
|------|-------------|
| `-o <file>` | Write output to file instead of stdout |
| `-t` | Extract common field sequences into `% template` definitions |

**What it handles:**

| Feature | Input (SQL) | Output (.tps) |
|---------|-------------|---------------|
| Types | `int`, `bigint`, `varchar(N)`, `decimal(P,S)`, `text`, `boolean`, `blob`, `json`, `date`, `datetime`, `bit(1)`, `ENUM(...)` | `n`, `N`, `sN`, `m`/`M`, `S`, `b`, `B`, `j`, `d`, `t`, `b`, `e(...)` |
| Modifiers | `NOT NULL`, `AUTO_INCREMENT`, `PRIMARY KEY`, `UNSIGNED` | `*`, `+`, `!`, `u` (fused: `++` = AI+PK) |
| Defaults | `DEFAULT 0`, `DEFAULT 'val'`, `DEFAULT CURRENT_TIMESTAMP`, `DEFAULT b'0'` | `=0`, `=val`, `+`/`++` on datetime, `=0` |
| Suffix inference | `user_id int` → `user_id` (type omitted) | `_id`→int, `_on`→date, `_at`→datetime, default→varchar(255) |
| Comments | `COMMENT 'text'` on columns and tables | `: text` |
| Indexes | `INDEX`, `UNIQUE INDEX`, `FULLTEXT INDEX`, composite | `@`, `@u`, `@f`, standalone (`@ f1 f2` for composite) |
| Foreign keys | `FOREIGN KEY ... REFERENCES` | `> field table.id` (shorthand) or full form |
| CHECK constraints | `BETWEEN`, `IN`, comparison operators | `[a,b]`, `{a,b}`, `{>0}` |
| Table options | `ENGINE`, `CHARSET`, `COMMENT`, `AUTO_INCREMENT=N`, `COLLATE` | Parsed and emitted |
| Column charset | `CHARACTER SET ... COLLATE ...` | Silently skipped |
| Index options | `USING BTREE`, `ASC`/`DESC`, index `COMMENT` | Silently skipped |
| DML/transactions | `BEGIN`, `COMMIT`, `INSERT`, `UPDATE`, `ALTER`, `DROP` | Silently skipped |
| `IF NOT EXISTS` | `CREATE TABLE IF NOT EXISTS` | Supported |

**Template extraction (`-t`):**

Extracts multiple templates using `>` inheritance. Finds common field sequences across tables, then each table is assigned to the template covering the most of its fields.

```sql
-- Input: tables with shared audit fields and varying extras
CREATE TABLE `user` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(32) NOT NULL,
  `status` tinyint DEFAULT 0,
  `create_at` datetime,
  `update_at` datetime,
  `tenant_id` bigint DEFAULT 0
);
CREATE TABLE `order` (
  `id` int NOT NULL AUTO_INCREMENT,
  `order_no` varchar(64) NOT NULL,
  `create_at` datetime,
  `update_at` datetime,
  `tenant_id` bigint DEFAULT 0
);
CREATE TABLE `log` (
  `id` int NOT NULL AUTO_INCREMENT,
  `message` text,
  `create_at` datetime,
  `update_at` datetime
);
```

```tps
# Output with -t
$ demo

% base
...
create_at t +
update_at t ++

% base2 > base
...
status n =0
tenant_id N =0

# base2 user
name s32 *

# base2 order
order_no s64 *

# base log
message S
```

- `% base` — common fields shared by all tables
- `% base2 > base` — extends `base` with `status` and `tenant_id` (only tables with all these fields use it)
- Each table references exactly one template; non-template fields are listed inline

**Error reporting:**

Structured diagnostics with file, line, column, source context, and caret pointer:

```
error: expected ')', got ' '
  --> schema.sql:3:1
   |
 3 | CREATE TABLE `t` (
   |                 ^
```

### Diff

Compiles both files and compares the generated SQL at the table level.

```bash
typespec diff schema_v1.tps schema_v2.tps
```

**Output format:**

```
-- CREATE TABLE `new_table`       ← table exists in v2 but not v1
-- ALTER TABLE `user`             ← table exists in both but SQL differs
-- DROP TABLE `old_table`         ← table exists in v1 but not v2
```

No flags beyond the two input files.

### Migrate

Generates a transaction-wrapped migration script from the diff.

```bash
# Print to stdout
typespec migrate schema_v1.tps schema_v2.tps

# Write to file
typespec migrate schema_v1.tps schema_v2.tps -o migration.sql
```

**Output format:**

```sql
-- Migration: schema diff
-- Generated by zig-typespec migrate

BEGIN;

CREATE TABLE `new_table` (
  ...
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS `old_table`;

-- ALTER TABLE `user` (drop and recreate)
DROP TABLE IF EXISTS `user`;
CREATE TABLE `user` (
  ...
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

COMMIT;
```

**Migration strategy:**

- New tables → `CREATE TABLE`
- Dropped tables → `DROP TABLE IF EXISTS`
- Modified tables → `DROP` + `CREATE` (idempotent, safe to re-run)

All operations are wrapped in a single transaction.

## Compilation Pipeline

```
.tps file
  │
  ▼
Tokenizer    Line classification + token splitting
  │
  ▼
Parser       AST construction (schema, templates, tables, fields, FKs, indexes)
  │
  ▼
Semantic     Template resolution, inheritance merging, suffix inference, autofk
  │
  ▼
Codegen      MySQL DDL generation (CREATE TABLE, INDEX, FOREIGN KEY, CHECK)
  │
  ▼
.sql output
```

## Reverse Engineering Pipeline

```
.sql input
  │
  ▼
SQL Parser   Parse CREATE DATABASE/TABLE, columns, indexes, FKs, CHECK constraints
  │
  ▼
IR           Structured representation (SqlSchema → SqlTable → SqlColumn)
  │
  ▼
Reverse Codegen   Type mapping, modifier reconstruction, suffix inference,
                  CHECK/INDEX/FK conversion, template extraction (-t)
  │
  ▼
.tps output
```

## Source Structure

```
src/
├── main.zig             Entry point, CLI parsing, pipeline orchestration
├── tokenizer.zig        Line classification (Schema/Table/Field/FK/Index/Slot/Comment)
├── parser.zig           AST types + parsing (1473 lines, the largest file)
├── semantic.zig         Template resolution, suffix inference, autofk
├── codegen.zig          SQL DDL generation
├── diagnostic.zig       Error/warning reporting with source context
├── diff.zig             Schema diff engine (AST-level)
├── migrate.zig          SQL-level diff + migration SQL generator
├── sql_parser.zig       MySQL DDL parser (CREATE DATABASE/TABLE → IR)
└── reverse_codegen.zig  IR → .tps reverse codegen + template extraction
```

## Testing

### Golden-file tests (compile)

```bash
bash tests/test.sh           # Run all
bash tests/test.sh template  # Filter by name
```

Each test compiles a `.tps` file and diffs the output against `tests/expected/<name>.sql`.

### Migration tests

```bash
bash tests/test_migrate.sh           # Run all
bash tests/test_migrate.sh add-table # Filter by name
```

Each test runs `typespec migrate` on a pair of files and diffs against a golden SQL file.

Test file naming convention:

```
tests/migrate-<name>-old.tps    ← v1 schema
tests/migrate-<name>-new.tps    ← v2 schema
tests/expected/migrate-<name>.sql ← expected migration output
```

## Dependencies

- Zig 0.16 (standard library only, no external packages)

## License

See [LICENSE](../LICENSE) (MIT).
