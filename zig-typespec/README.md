# zig-typespec

A compiler that transforms `.tps` schema files into MySQL or PostgreSQL DDL SQL. Written in Zig 0.16.

Supports forward compilation (`.tps` → SQL), reverse engineering (SQL → `.tps`), schema diff, and migration generation.

## Build

```bash
zig build                          # Build (debug)
zig build -Doptimize=ReleaseSafe   # Build (release)
zig build test                     # Unit tests
```

Output binary: `zig-out/bin/typespec`

## Benchmark

```bash
zig build bench                              # default: bench/small.tps, 10 iterations
zig build bench -- bench/medium.tps 20       # custom file and iteration count
zig build bench -- bench/large.tps 5         # large schema benchmark
```

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
| `-d, --dialect <dialect>` | Target SQL dialect: `mysql` (default), `pg`, `postgres`, `sqlite` |

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

Compares two schemas at the **AST level** (not SQL text). Detects field additions, removals, modifications, renames, index changes, and FK changes.

```bash
typespec diff schema_v1.tps schema_v2.tps
```

**Output format:**

```
-- CREATE TABLE `new_table`       ← table exists in v2 but not v1
-- ALTER TABLE `user`             ← table exists in both, field/index/FK diffs shown
  + new_field (add)
  - old_field (drop)
  ~ changed_field (modify)
  ~ old_name → new_name (rename)
-- DROP TABLE `old_table`         ← table exists in v1 but not v2
```

No flags beyond the two input files.

### Migrate

Generates a transaction-wrapped migration script from the **AST-level diff**. Produces proper `ALTER TABLE` statements instead of dropping and recreating entire tables.

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

ALTER TABLE `user`
ADD COLUMN `email` varchar(64);

ALTER TABLE `user`
MODIFY COLUMN `name` varchar(64) NOT NULL;

ALTER TABLE `user`
DROP COLUMN `old_col`;

ALTER TABLE `user`
CHANGE COLUMN `old_name` `new_name` varchar(32);

COMMIT;
```

**Migration strategy:**

| Change | MySQL Output | PostgreSQL Output |
|--------|-------------|-------------------|
| New table | `CREATE TABLE` | `CREATE TABLE` |
| Dropped table | `DROP TABLE IF EXISTS` | `DROP TABLE IF EXISTS` |
| Added column | `ALTER TABLE ... ADD COLUMN` | `ALTER TABLE ... ADD COLUMN` |
| Dropped column | `ALTER TABLE ... DROP COLUMN` | `ALTER TABLE ... DROP COLUMN` |
| Modified column | `ALTER TABLE ... MODIFY COLUMN` | `ALTER TABLE ... MODIFY COLUMN` |
| Renamed column | `ALTER TABLE ... CHANGE COLUMN` | `ALTER TABLE ... RENAME COLUMN TO` |
| Added index | `ALTER TABLE ... ADD INDEX` | `ALTER TABLE ... ADD UNIQUE` |
| Dropped index | `ALTER TABLE ... DROP INDEX` | `DROP INDEX` |
| Added FK | `ALTER TABLE ... ADD FOREIGN KEY` | `ALTER TABLE ... ADD FOREIGN KEY` |
| Dropped FK | `ALTER TABLE ... DROP FOREIGN KEY` | `ALTER TABLE ... DROP FOREIGN KEY` |
| No changes | Empty transaction | Empty transaction |

All operations are wrapped in a single `BEGIN`/`COMMIT` transaction.

## Compilation Pipeline

```
.tps file
  │
  ▼
Tokenizer    Line classification + token splitting
  │
  ▼
Parser       AST construction (tokens → AST via ast.zig types)
  │
  ▼
Semantic     Template resolution, inheritance merging, suffix inference, autofk
  │
  ▼
ResolvedAst
  │
  ▼
TypeResolver  TypeInfo → SQL type strings per dialect (typed_ast.zig IR)
  │
  ▼
TypedAst      Dialect-agnostic IR: sql_type string + boolean column flags
  │
  ▼
Codegen      SQL DDL generation via DialectBackend vtable (5 methods)
  │
  ▼
.sql output
```

**DialectBackend vtable** (5 methods):

| Method | MySQL | PostgreSQL | SQLite |
|--------|-------|-----------|--------|
| `quoteIdent` | backticks | double-quotes | double-quotes |
| `emitIndex` | inline INDEX/UNIQUE/FULLTEXT | UNIQUE (...) inline | UNIQUE (...) inline |
| `emitCreateDatabase` | CHARACTER SET | ENCODING | no-op |
| `emitUnsigned` | `UNSIGNED` | no-op | no-op |
| `emitTimestampModifier` | `DEFAULT CURRENT_TIMESTAMP [ON UPDATE ...]` | `DEFAULT CURRENT_TIMESTAMP` | `DEFAULT CURRENT_TIMESTAMP` |

PG and SQLite share 4/5 method implementations. `emitCheckExpr` is a shared standalone function (all dialects use identical CHECK syntax).

## Diff/Migrate Pipeline

```
old.tps + new.tps
  │ (both compiled through the forward pipeline above)
  ▼
ResolvedAst × 2
  │
  ▼
Diff Engine  AST-level comparison (field add/drop/modify/rename, index, FK)
  │
  ▼
SchemaDiff   Structured diff result
  │
  ├──▶ Diff Printer    Human-readable diff output (`typespec diff`)
  │
  └──▶ Migration Gen   ALTER TABLE / ADD / DROP / MODIFY / RENAME DDL (`typespec migrate`)
                         Uses type_map.zig for column type resolution
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
Reverse Codegen   Type mapping (via type_map.zig), modifier reconstruction,
                  suffix inference, CHECK/INDEX/FK conversion, template extraction (-t)
  │
  ▼
.tps output
```

## Source Structure

```
src/
├── main.zig             Entry point, CLI parsing, pipeline orchestration
├── tokenizer.zig        Line classification (Schema/Table/Field/FK/Index/Slot/Comment)
├── ast.zig              AST type definitions (Field, Table, Template, TypeInfo, etc.)
├── parser.zig           Parser (tokens → AST, 440 lines + 8 parse_*.zig modules)
├── parse_field.zig      Field parsing (fused type, enum, modifier, inline FK/CHECK)
├── parse_fk.zig         Foreign key parsing (inline + standalone FK)
├── parse_check.zig      CHECK constraint parsing (range, IN, comparison)
├── parse_index.zig      Index + composite PK parsing
├── parse_typedef.zig    ~ directive parsing (custom types)
├── parse_template.zig   Template header parsing + slot detection
├── parse_table.zig      Table header parsing + engine token stripping
├── parse_trace.zig      Parser diagnostic trace output (debug mode)
├── semantic.zig         Template resolution, suffix inference, autofk + PassManager
├── type_map.zig         Helper functions (isNumericTpsType, etc.) + SqlType re-export
├── type_registry.zig    TPS symbol → SqlType direct mapping (CORE_TYPES)
├── typed_ast.zig        TypeResolver: TypeInfo → SqlType per dialect (TypedAst IR)
├── dialect.zig          DialectBackend vtable (22 core + 6 optional) + ReverseResult
├── dialect_mysql.zig    MySQL DialectBackend implementation
├── dialect_pg.zig       PostgreSQL DialectBackend implementation
├── dialect_sqlite.zig   SQLite DialectBackend + heuristic reverse lookup
├── dialect_common.zig   Shared PG/SQLite dialect functions
├── dialect_enum.zig     Dialect enum (mysql, pg, sqlite)
├── sql_type.zig         SqlType union + toSql() (single source of truth)
├── codegen.zig          SQL DDL generation via DialectBackend vtable
├── diagnostic.zig       Error/warning reporting with source context
├── diff.zig             Schema diff engine (AST-level, rename detection)
├── diff_fields.zig      Field-level diffing + rename detection
├── diff_indexes.zig     Index diffing
├── diff_fks.zig         FK diffing
├── diff_semantic.zig    Dialect-aware type equivalence
├── diff_format.zig      Human-readable diff formatting
├── migrate.zig          Migration SQL generator (ALTER TABLE)
├── sql_parser.zig       SQL DDL parser (reverse pipeline, 413 lines)
├── sql_parser_*.zig     7 sub-modules (create, alter, comment, fk, index, helpers)
├── reverse_codegen.zig  SQL → .tps orchestration
├── reverse_map.zig      Reverse lookup logic (REVERSE_MAP)
├── reverse_map_data.zig REVERSE_MAP data table
├── reverse_column.zig   Column reverse engineering
├── reverse_fk.zig       FK reverse classification
├── reverse_check.zig    CHECK constraint reverse engineering
├── template.zig         Template inheritance + slot-based field merging
├── template_extraction.zig  Greedy template extraction (reverse -t)
├── sqlite_hints.zig     SQLite type affinity heuristics
├── json_schema.zig      JSON Schema output
├── io.zig               stdin/stdout/file I/O helpers
├── trace.zig            Shared AST trace formatting
├── bench.zig            Benchmark entry point (per-stage pipeline timing)
└── test_helpers.zig     Shared test factory functions
```

### Parser Module Split (v0.4.6)

The parser was split into 4 extracted modules (~790 lines total) for modularity and unit testing. The main `parser.zig` retains its own implementations; the extracted modules serve as standalone reference implementations that can be tested independently.

## Testing

### Test suites

| Script | Tests | Description |
|--------|-------|-------------|
| `tests/test.sh` | 81 | MySQL forward compilation golden files |
| `tests/test_postgres.sh` | 93 | PostgreSQL forward compilation golden files |
| `tests/test_sqlite.sh` | 1 | SQLite forward compilation |
| `tests/test_migrate.sh` | 6 | Migration SQL golden files |
| `tests/test_reverse.sh` | 8 | Reverse engineering golden files (MySQL/PG/SQLite) |
| `tests/test_diff.sh` | 2 | Schema diff golden files |
| `zig build test` | 76 | Zig inline unit tests (type_map + tokenizer + parser) |
| **Total** | **267** | |

### Golden-file tests (compile)

```bash
bash tests/test.sh           # Run all (MySQL)
bash tests/test.sh template  # Filter by name
bash tests/test_postgres.sh  # PostgreSQL tests
bash tests/test_sqlite.sh    # SQLite tests
```

Each test compiles a `.tps` file and diffs the output against `tests/expected/<name>.sql`.

### Migration tests

```bash
bash tests/test_migrate.sh           # Run all
bash tests/test_migrate.sh add-table # Filter by name
```

Each test runs `typespec migrate` on a pair of files and diffs against a golden SQL file.

### Reverse engineering tests

```bash
bash tests/test_reverse.sh           # Run all
bash tests/test_reverse.sh auto-inc  # Filter by name
```

Each test runs `typespec reverse` on a `.sql` file and diffs against a golden `.tps` file. Supports dialect-specific golden files (`.mysql.tps`, `.pg.tps`, `.sqlite.tps`).

### Unit tests

```bash
cd zig-typespec && zig build test
```

Inline tests covering: type_map (41), tokenizer (20), parser (15 — tryParseType, parseFusedTypeModifier, parseStandaloneModifier, classifyCheck).

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
