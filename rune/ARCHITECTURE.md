# Rune Architecture

> Internal architecture documentation for contributors.

## Overview

Rune is a compiler that transforms `.ss` schema files into SQL DDL. It consists of two independent pipelines:

1. **Forward pipeline**: `.ss` → SQL DDL (CREATE TABLE, indexes, FKs)
2. **Reverse pipeline**: SQL DDL → `.ss` schema
3. **Diff/Migrate**: compare two schemas and generate migration SQL

## Module Dependency Graph

```
                    main.zig (entry + orchestration)
                   ╱    │    ╲         ╲
                  ╱     │     ╲         ╲
           ┌─────┐  ┌──┴───┐  ┌───────┐  ┌────────┐
           │codegen│ │migrate│ │reverse_│  │sql_parser│
           └──┬──┘ └──┬──┘  └──┬────┘  └──┬─────┘
              │        │        │           │
        ┌─────┘   ┌────┘    ┌───┘      ┌───┘
        ▼         ▼         ▼          ▼
   ┌─────────┐ ┌──────┐ ┌────────┐ ┌───────┐
   │typed_ast │ │ diff │ │reverse_│ │ ast   │
   └────┬────┘ └──────┘ │ map    │ └───┬───┘
        │                └────────┘     │
        ▼                 ╲    ╱        ▼
   ┌─────────┐     ┌───────────┐  ┌──────────┐
   │ sql_type │     │diagnostic │  │ template │
   └────┬────┘     └───────────┘  └──────────┘
        │                               │
        ▼                          ┌────┘
   ┌──────────┐                    ▼
   │type_reg  │              ┌──────────┐
   └──────────┘              │ semantic │
                             └──────────┘
```

**Leaf modules** (zero internal dependencies): `ast.zig`, `dialect_enum.zig`, `diagnostic.zig`

**Key modules**:
- `sql_type.zig`: `SqlType` union with `toSql()` delegating to `DialectBackend.renderType`. Variants: int, bigint, smallint, decimal, varchar, text, blob, json, jsonb, datetime, date, timestamptz, boolean, uuid, inet, serial, enum_values, raw_sql, passthrough. `toJsonSchema()` for JSON Schema output.
- `type_map.zig`: Helper functions (`lookupCustomType`, `isNumericSymType`, etc.) + `SqlType` re-export
- `type_registry.zig`: SS symbol → `SqlType` direct mapping (`lookupSqlTypeDirect`) and reverse lookup. 17 core SS symbols: n, N, i, m, M, s, S, b, B, j, J, I, d, t, T, U, p

### Extracted Sub-Modules

| Parent Module | Extracted Module | Responsibility |
|--------------|-----------------|---------------|
| `parser.zig` | `parse_typedef.zig` | `~` directive parsing (name, base type, dialect overrides) |
| `parser.zig` | `parse_field.zig` | Field declaration parsing (name, type, modifiers, default, check) |
| `parser.zig` | `parse_fk.zig` | Foreign key parsing (inline + standalone, actions) |
| `parser.zig` | `parse_check.zig` | CHECK constraint classification (range, IN, comparison) |
| `parser.zig` | `parse_index.zig` | Index + composite PK parsing |
| `parser.zig` | `parse_template.zig` | Template header parsing + slot detection |
| `parser.zig` | `parse_table.zig` | Table header parsing + engine token stripping |
| `parser.zig` | `parse_trace.zig` | Parser diagnostic trace output (debug mode) |
| `parser.zig` | `parse_recovery.zig` | Error handling + sync point detection for error recovery |
| `diff.zig` | `diff_fields.zig` | Field-level diffing + rename detection + equality helpers |
| `diff.zig` | `diff_indexes.zig` | Index diffing |
| `diff.zig` | `diff_fks.zig` | FK diffing |
| `diff.zig` | `diff_semantic.zig` | Dialect-aware type equivalence (canonical SS symbol mapping) |
| `diff.zig` | `diff_format.zig` | Human-readable diff formatting |
| `codegen.zig` | `codegen_columns.zig` | Column definition rendering (emitColumnDef, emitColumnDefEx, emitDefault) + shared `isDominatedByExplicitIndex()` |
| `codegen.zig` | `codegen_indexes.zig` | Inline and standalone index emission |
| `sql_parser.zig` | `sql_parser_helpers.zig` | Identifier/literal/word parsing, whitespace/comment skipping, trailing comment capture, `parseExpression` |
| `sql_parser.zig` | `sql_parser_alter.zig` | ALTER TABLE statement parsing |
| `sql_parser.zig` | `sql_parser_comment.zig` | COMMENT ON TABLE/COLUMN parsing |
| `sql_parser.zig` | `sql_parser_create.zig` | CREATE DATABASE/TABLE/column parsing |
| `sql_parser.zig` | `sql_parser_fk.zig` | Foreign key parsing (reverse pipeline) |
| `sql_parser.zig` | `sql_parser_index.zig` | Index declaration parsing (reverse pipeline) |
| `sql_parser.zig` | `sql_parser_check.zig` | CHECK constraint parsing (reverse pipeline) |
| `reverse_codegen.zig` | `reverse_column.zig` | Column reverse engineering (type mapping, suffix, inline index detection) |
| `reverse_codegen.zig` | `reverse_fk.zig` | FK reverse classification |
| `reverse_codegen.zig` | `reverse_check.zig` | CHECK constraint reverse engineering |

## Forward Pipeline

```
Input (.ss text)
    │
    ▼
[1] Tokenizer (tokenizer.zig, 399 lines)
    Line classification + token splitting
    Output: []Line (line_type + tokens)
    │
    ▼
[2] Parser (parser.zig, 425 lines + 9 parse_*.zig modules)
    Token-level parsing into AST
    Output: Ast (schema, templates, tables, sql_comments)
    │
    ▼
[3] Template Resolution (template.zig, 351 lines)
    Template inheritance merging + slot-based field injection
    Output: []ResolvedTable (templates applied to each table)
    │
    ▼
[4] Semantic Analyzer (semantic.zig, 789 lines)
    Pass manager: validate_template_types, autofk, suffix_inference, validate, validate_type_modifiers, validate_indexes, validate_schema
    Output: ResolvedAst (templates resolved + passes applied)
    │
    ▼
[5] Type Resolver (typed_ast.zig, 289 lines)
    Abstract TypeInfo → concrete SqlType per dialect
    Modifier classification into ColumnFlags bitflags
    Output: TypedAst (dialect-agnostic IR)
    │
    ▼
[6] Code Generator (codegen.zig + codegen_columns.zig + codegen_indexes.zig)
    TypedAst → SQL DDL text
    Dialect-specific rendering via DialectBackend vtable
    Output: SQL string
```

### IR Boundaries

| IR | Location | Content |
|----|----------|---------|
| `Line[]` | Tokenizer output | Line type + token array |
| `Ast` | Parser output | Schema, templates, tables, SQL comments |
| `[]ResolvedTable` | Template output | Tables with template fields merged |
| `ResolvedAst` | Semantic output | Templates applied + passes run (autofk, suffix_inference, validate) |
| `TypedAst` | TypeResolver output | SQL type strings resolved, modifiers as booleans, `sym_type` for roundtrip |
| `SchemaDiff` | Diff output | Table/field/index/FK diffs with rename detection |

## Reverse Pipeline

```
Input (SQL DDL text)
    │
    ▼
[1] SQL Parser (sql_parser.zig, 413 lines + 8 sql_parser_*.zig modules)
    Recursive-descent DDL parsing (independent of forward tokenizer)
    Output: SqlSchema (tables, columns, indexes, FKs, checks)
    │
    ▼
[2] Reverse Codegen (reverse_codegen.zig, 298 lines, 4 sub-functions)
    SQL types → SS symbols (via reverse_map.zig reverse lookup)
    Template extraction (greedy + scoring algorithm)
    Index inline detection: recognizes both MySQL-style "idx_field" and
    PG/SQLite-style "idx_table_field" as inline index suffixes (@, @u).
    Non-standard index names preserved in full form: @ idx_name (field).
    Confidence comments suppressed on fields with inline index suffixes.
    Output: .ss text
```

## Diff/Migrate Pipeline

```
(old.ss, new.ss)
    │
    ▼
[1] Compile both to ResolvedAst (forward pipeline)
    │
    ▼
[2] Diff Engine (diff.zig, 710 lines + diff_fields/diff_indexes/diff_fks/diff_format)
    Structural comparison with rename detection
    Output: SchemaDiff
    │
    ├──▶ Diff Printer (human-readable diff output)
    │
    └──▶ Migration Generator (migrate.zig, 458 lines, 6 sub-functions)
         SchemaDiff → ALTER TABLE SQL
         Sub-functions: emitDroppedTables, emitViewDiffs, emitTableDiffs,
         emitFieldDiffs, emitIndexDiffs, emitMetadataDiffs, emitFkDiffs
         FK rendering via DialectBackend.emitForeignKey
         Output: migration SQL
```

## DialectBackend Vtable

23 core + 6 optional function pointers + 3 behavioral flags for dialect-specific SQL generation (32 total dispatch points):

```zig
DialectBackend = struct {
    // Core rendering
    quoteIdent:             fn(w, name) -> !void,
    emitIndex:              fn(w, idx, needs_comma) -> !void,
    emitCreateDatabase:     fn(w, name, charset) -> !void,
    emitUnsigned:           fn(w) -> !void,
    emitTimestampModifier:  fn(w, with_on_update) -> !void,
    // Table structure
    emitTableFooter:        fn(w, engine, charset, comment) -> !void,
    emitTableComment:       fn(w, table_name, comment) -> !void,
    emitColumnComment:      fn(w, table_name, col_name, comment) -> !void,
    emitAutoIncrement:      fn(w) -> !void,
    emitPrimaryKey:         fn(w, auto_increment) -> !void,
    emitInlineIndex:        fn(w, col_name, is_unique, needs_comma) -> !void,
    emitStandaloneIndex:    fn(w, table_name, idx) -> !void,
    emitInlineColumnComment: fn(w, comment) -> !void,
    emitEnumTypeCheck:      fn(w, col_name, enum_values) -> !void,
    emitInlineColumnStandaloneIndex: fn(w, table_name, col_name) -> !void,
    // Metadata comments
    emitTypeMetadata:    fn(w, col_name, sym_type) -> !void,
    emitConfidenceComment:  fn(w, confidence) -> !void,
    // ALTER TABLE migration
    emitAlterDropColumn:    fn(w, col_name) -> !void,
    emitAlterModifyColumn:  fn(w, col_name) -> !void,
    emitAlterRenameColumn:  fn(w, old_name, new_name) -> !void,
    emitAlterAddIndex:      fn(w, table_name, idx) -> !void,
    emitAlterDropIndex:     fn(w, idx) -> !void,
    emitAlterDropFk:        fn(w, fk) -> !void,
    commentResult:          fn() -> CommentResult,
    emitAlterTableComment:  fn(w, table_name, comment) -> !void,
    emitAlterEngine:        fn(w, engine) -> !void,
    // View support
    emitCreateView:         fn(w, name, query) -> !void,
    // Type rendering (single source of truth)
    renderType:             fn(w, sql_type) -> !void,
    // FK rendering (shared via dialect_common.zig:emitForeignKeyShared)
    emitForeignKey:         fn(w, fk) -> !void,
    // Reverse engineering (optional)
    reverseLookup:          fn(sql_type, col_name, is_auto_inc, is_default_ts) -> ?ReverseResult,
    // Behavioral flags (eliminate dialect checks in caller)
    rename_needs_column_def: bool,     // MySQL CHANGE COLUMN
    modify_needs_column_def: bool,     // MySQL/PG MODIFY COLUMN
    modify_column_def_skips_name: bool, // PG ALTER COLUMN TYPE
};
```

| Method | MySQL | PostgreSQL | SQLite |
|--------|-------|-----------|--------|
| `quoteIdent` | backticks | double-quotes | double-quotes |
| `emitIndex` | inline INDEX/UNIQUE/FULLTEXT | UNIQUE (...) inline | UNIQUE (...) inline |
| `emitCreateDatabase` | CHARACTER SET | ENCODING | no-op |
| `emitUnsigned` | `UNSIGNED` | no-op | no-op |
| `emitTimestampModifier` | `DEFAULT CURRENT_TIMESTAMP [ON UPDATE ...]` | `DEFAULT CURRENT_TIMESTAMP` | `DEFAULT CURRENT_TIMESTAMP` |
| `emitTableFooter` | `ENGINE=... CHARSET=... COMMENT='...'` | `);` | `);` |
| `emitTableComment` | no-op (in footer) | `COMMENT ON TABLE` | `-- comment` |
| `emitColumnComment` | no-op (inline) | `COMMENT ON COLUMN` | `-- table.col: comment` |
| `emitAutoIncrement` | `AUTO_INCREMENT` | `GENERATED ALWAYS AS IDENTITY` | no-op |
| `emitPrimaryKey` | `PRIMARY KEY` | `PRIMARY KEY` | `PRIMARY KEY [AUTOINCREMENT]` |
| `emitInlineIndex` | `INDEX`/`UNIQUE INDEX` | `UNIQUE (...)` | `UNIQUE (...)` |
| `emitStandaloneIndex` | no-op (inline) | `CREATE INDEX` | `CREATE INDEX` |
| `emitInlineColumnComment` | `COMMENT '...'` | no-op (standalone) | no-op (standalone) |
| `emitEnumTypeCheck` | no-op (native ENUM) | `CHECK (... IN (...))` | `CHECK (... IN (...))` |
| `emitInlineColumnStandaloneIndex` | no-op (inline) | `CREATE INDEX` | `CREATE INDEX` |
| `renderType` | `int`, `bigint`, `smallint`, `decimal`, `varchar`, `text`, `blob`, `json`, `datetime`, `date`, `timestamptz`, `boolean`, `uuid`, `serial` | `integer`, `bigint`, `smallint`, `numeric`, `varchar`, `text`, `bytea`, `json`, `timestamp`, `date`, `timestamptz`, `boolean`, `uuid`, `serial` | `INTEGER`, `NUMERIC`, `varchar`, `TEXT`, `BLOB`, `INTEGER` |
| `emitForeignKey` | `FOREIGN KEY (...) REFERENCES ...` | `FOREIGN KEY (...) REFERENCES ...` | `FOREIGN KEY (...) REFERENCES ...` |

PG and SQLite share 4/5 method implementations. `emitCheckExpr` is a shared standalone function (all dialects use identical CHECK syntax). `emitForeignKey` is shared via `dialect_common.zig:emitForeignKeyShared` (takes `quoteIdent` function pointer).

## Semantic Pass Manager

```zig
SemanticPass = struct { name: []const u8, run: fn(*PassContext) !void, depends_on: []const []const u8 };
DEFAULT_PASSES = [_]SemanticPass{ validate_template_types, autofk, suffix_inference, validate, validate_type_modifiers, validate_indexes, validate_schema };
```

New passes can be added by:
1. Writing a function with signature `fn(*PassContext) !void`
2. Adding a `SemanticPass` entry to `DEFAULT_PASSES`

### Schema-Level Validation (validate_schema pass)

The `validate_schema` pass runs after all table-level passes and performs global consistency checks:

- **Circular FK detection**: DFS traversal of the FK dependency graph. Detects A→B→C→A cycles and reports them as warnings (non-blocking).
- **FK target field existence**: Validates that all FK referenced fields exist in the target table. Reports errors (blocking).
- **Self-referencing FK field count**: Validates that self-referencing FKs have matching local/referenced field counts. Reports errors (blocking).

## Template Extraction Algorithm (Reverse Pipeline)

When `rune reverse -t` is used, the reverse codegen extracts common field sequences across tables and promotes them as reusable templates.

### Algorithm

1. **Candidate generation**: For each table, slide a window of length L (starting from `max_cols`, decrementing to 2) across the column list. Each window position produces a candidate template.

2. **Filtering**: A candidate must contain at least 2 fields not yet covered by previously extracted templates. This prevents degenerate single-field templates.

3. **Matching**: For each candidate, find all tables that contain the same contiguous field sequence (same names + same SQL types, in order). At least 2 tables must match.

4. **Scoring**: `score = matching_tables × field_count × log₂(field_count)`. This favors templates that cover many fields across many tables. Logarithmic weighting on field count prevents excessively large templates from dominating.

5. **Greedy selection**: At each length L, the highest-scoring candidate across all tables is selected. The algorithm then marks those fields as "covered" and repeats.

6. **Early termination**: When `L < 3` and a best candidate already exists, the inner loop breaks (templates smaller than 2 fields are not useful).

7. **Assignment**: After extraction, each table is assigned to its best-matching template (most fields covered). Templates with fewer than 2 assigned tables are discarded.

8. **Naming**: Templates are named `base`, `base2`, `base3`, etc.

### Complexity

- **Time**: O(tables × columns² × L) where L is the sliding window size (bounded by max columns per table).
- **Space**: O(tables × columns) for the candidate and assignment structures.

### Properties

- **Deterministic**: Same input always produces the same output (no randomness).
- **Greedy-optimal**: At each step, picks the locally best template. Does not guarantee global optimum but produces good results in practice.
- **Idempotent**: Re-running on already-templated output produces no additional templates (covered fields are filtered out).

## Type Mapping System

Rune uses a three-layer type mapping system:

- **`sql_type.zig` (SqlType.toSql)**: Delegates to `DialectBackend.renderType` for dialect-aware rendering. Variants: int, bigint, smallint, decimal, varchar, text, blob, json, jsonb, datetime, date, timestamptz, boolean, uuid, inet, serial, enum_values, raw_sql, passthrough. SS symbols: n, N, i, m, M, s, S, b, B, j, J, I, d, t, T, U, p.

- **`type_registry.zig` (CORE_TYPES)**: Static array of 17 SS symbol entries with dialect-specific SQL names. Provides two lookup functions:
  - `lookupSqlType(sym, dialect)` → `?[]const u8` (SQL name string, for backward compat)
  - `lookupSqlTypeDirect(sym, dialect)` → `?SqlType` (direct variant, avoids stringly-typed round-trip)

- **`reverse_map.zig` (REVERSE_MAP)**: ~35 entries covering all SQL type variants → SS symbols. Used by `reverseLookup()` and `reverseLookupSqlite()`. Includes core entries (for SQLite lossy affinity) plus MySQL/PG variant types.

- **`type_map.zig`**: Helper functions (`lookupCustomType`, `isNumericSymType`, `isDatetimeSymType`) + `SqlType` re-export for backward compatibility. No longer contains rendering logic.

## Key Design Decisions

1. **TypedAst IR layer**: Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.
2. **DialectBackend vtable**: 23 core + 6 optional function pointers + 3 behavioral flags cover all dialect differences. Adding a new dialect requires < 100 lines. codegen.zig is fully dialect-agnostic (zero `switch(dialect)` in production code). FK rendering is shared via `dialect_common.zig:emitForeignKeyShared`.
3. **Self-contained SqlType**: `SqlType.toSql()` delegates to `DialectBackend.renderType`. Adding a new type = add variant to union + add case to all `renderType` implementations + add to `type_registry.zig`. SS symbol naming: lowercase for core types (n, s, b, j, d, t), uppercase for variants (N, M, S, B, T, U, i, p). Unsigned uses `+` prefix (`+n`, `+N`, `+i`).
4. **Direct type lookup**: `type_registry.lookupSqlTypeDirect()` returns `SqlType` variants directly, avoiding the stringly-typed round-trip (SS symbol → SQL string → SqlType).
5. **AST-level diff**: Semantic comparison, not text diff. Detects renames by signature matching. Dialect-aware type equivalence (`diff_semantic.zig`) uses canonical SS symbol mapping — different symbols that resolve to the same SQL type are equivalent (e.g., `N4` ↔ `4` in MySQL), but distinct types like `n` (int) vs `N` (bigint) are NOT equivalent.
6. **Arena allocation**: All modules take `std.mem.Allocator`. Arena-style usage for command-lifetime memory.
7. **God function decomposition**: Large functions (>100 lines) are split into focused sub-functions. `migrate.zig:generateFromDiff` (258→7 sub-fns), `codegen.zig:generateTypedTable` (135→5 sub-fns), `reverse_codegen.zig:generateInner` (215→4 sub-fns).
8. **Pipeline-CLI separation**: `pipeline_forward.zig` has no dependency on `cli.zig`. Output format dispatch (SQL vs JSON Schema) is the caller's responsibility.
9. **Template/Semantic separation**: Template resolution (inheritance, slot merging) is independent of semantic passes (autofk, suffix_inference, validation). Each can be modified without affecting the other.
10. **Custom type system**: Users can define named type aliases via `~` directives in the schema block. Custom types support dialect-specific overrides and are resolved during type resolution (not parsing).
11. **SQLite roundtrip preservation**: `-- @sym col_name type` metadata comments preserve original SS types through lossy SQLite type affinity. Forward compiler emits comments; reverse compiler parses them for exact type restoration.
12. **Unified ReverseResult**: `dialect.zig` defines the single `ReverseResult` struct (`sym`, `omit`, `score`, `is_parameterized`). Both `type_registry.zig` and `reverse_column.zig` re-export it — zero type duplication across the reverse pipeline.

## Custom Type System

Users can define custom type aliases in the schema block:

```
$ mydb
  ~ uuid s36
  ~ email s128
  ~ ip_addr mysql=s45 postgres=inet sqlite=s45

# user
uuid uuid *
email email *
ip ip_addr
```

### How it works

1. **Tokenizer**: Lines starting with `~` are classified as `TypeDef` (not `Index`)
2. **Parser**: `parseTypeDef()` extracts name, base type, and dialect overrides
3. **Schema**: Custom types are stored in `Schema.custom_types` and passed through `ResolvedAst`
4. **Type resolver**: When resolving a field type, checks custom types first (multi-char names only)
5. **Dialect overrides**: Use `raw_sql` TypeInfo variant to prevent infinite recursion

### Adding a new custom type

No code changes needed — users define types in `.ss` files. For built-in support of a new type:

1. Add variant to `SqlType` union in `sql_type.zig`
2. Add case to `SqlType.toSql()` for dialect rendering
3. Add entry to `CORE_TYPES` in `type_registry.zig` (for single-char symbols)
4. Add to `REVERSE_MAP` in `reverse_map.zig` for reverse engineering support
5. Add unit tests and golden file tests

## Adding a New SQL Dialect

1. Add variant to `Dialect` enum in `dialect_enum.zig`
2. Add type mappings to `CORE_TYPES` in `type_registry.zig`
3. Add reverse mappings to `REVERSE_MAP` in `reverse_map.zig`
4. Update `SqlType.toSql()` in `sql_type.zig` with new dialect case
5. Create `DialectBackend` instance in `dialect_<name>.zig` (implement all 22 core methods + optional methods + 3 flags)
6. Register in `getBackend()` switch in `dialect.zig`
7. Optionally implement `reverseLookup` for dialect-specific reverse engineering (e.g., SQLite's heuristic-based type disambiguation)
8. Add golden file tests in `tests/`

No changes needed in `codegen.zig` — it is fully dialect-agnostic.

## Benchmark Infrastructure

`src/bench.zig` measures per-stage latency for the forward pipeline using `Io.Clock.Timestamp` (nanosecond precision).

### Schema Sizes

| File | Tables | Fields | Description |
|------|--------|--------|-------------|
| `bench/small.ss` | 6 | ~30 | Blog-like schema (user, post, comment, tag) |
| `bench/medium.ss` | 21 | ~200 | Project management (users, projects, issues, PRs) |
| `bench/large.ss` | 32 | ~400 | Enterprise platform (tenants, tasks, sprints, audits) |

### Usage

```bash
zig build bench                              # default: small, 10 iterations
zig build bench -- bench/medium.ss 20       # custom file + count
zig build bench -- bench/large.ss 5         # large schema
```

### Pipeline Stages Measured

1. **Tokenize**: Line splitting + token classification
2. **Parse**: Token-level parsing into AST
3. **Semantic**: Template resolution + pass manager (autofk, suffix_inference, validate)
4. **Type Resolve**: TypeInfo → SqlType per dialect
5. **Codegen**: TypedAst → SQL DDL text via DialectBackend vtable

## Testing Strategy

| Layer | Files | Count | Coverage |
|-------|-------|-------|----------|
| Unit tests | `type_map.zig`, `type_registry.zig`, `sql_type.zig`, `tokenizer.zig`, `parser.zig`, `diff.zig`, `diff_semantic.zig`, `semantic.zig`, `template.zig`, `reverse_column.zig`, `sql_parser_test.zig` | ~160 | Core logic |
| MySQL golden | `tests/test.sh` | 85 | Full pipeline |
| PG golden | `tests/test_postgres.sh` | 83 | Full pipeline |
| SQLite golden | `tests/test_sqlite.sh` | 24 | Full pipeline |
| Migrate golden | `tests/test_migrate.sh` | 34 | Diff + migration SQL |
| Reverse golden | `tests/test_reverse.sh` | 15 | SQL → .ss |
| Diff golden | `tests/test_diff.sh` | 12 | Schema comparison |
| Error recovery | `tests/test_error_recovery.sh` | 12 | Parse error handling + schema-level validation |
| JSON Schema | `tests/test_json_schema.sh` | 1 | JSON Schema output |
| Roundtrip | `tests/test_roundtrip.sh` | 20 | Forward → reverse fidelity |
| **Total** | | **~450+** | |
