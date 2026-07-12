# TypeSpec Architecture

> Internal architecture documentation for contributors.

## Overview

TypeSpec is a compiler that transforms `.tps` schema files into SQL DDL. It consists of two independent pipelines:

1. **Forward pipeline**: `.tps` → SQL DDL (CREATE TABLE, indexes, FKs)
2. **Reverse pipeline**: SQL DDL → `.tps` schema
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
   │typed_ast │ │ diff │ │type_map│ │ ast   │
   └────┬────┘ └──────┘ └────────┘ └───┬───┘
        │                ╲    ╱         │
        ▼                 ╲  ╱          ▼
   ┌─────────┐     ┌───────────┐  ┌──────────┐
   │ dialect  │     │diagnostic │  │ template │
   └─────────┘     └───────────┘  └──────────┘
                                         │
                                    ┌────┘
                                    ▼
                              ┌──────────┐
                              │ semantic │
                              └──────────┘
```

**Leaf modules** (zero internal dependencies): `ast.zig`, `type_map.zig`, `diagnostic.zig`

## Forward Pipeline

```
Input (.tps text)
    │
    ▼
[1] Tokenizer (tokenizer.zig, 346 lines)
    Line classification + token splitting
    Output: []Line (line_type + tokens)
    │
    ▼
[2] Parser (parser.zig, 1450 lines)
    Token-level parsing into AST
    Output: Ast (schema, templates, tables, sql_comments)
    │
    ▼
[3] Template Resolution (template.zig, ~250 lines)
    Template inheritance merging + slot-based field injection
    Output: []ResolvedTable (templates applied to each table)
    │
    ▼
[4] Semantic Analyzer (semantic.zig, ~300 lines)
    Pass manager: autofk, suffix_inference, validate
    Output: ResolvedAst (templates resolved + passes applied)
    │
    ▼
[5] Type Resolver (typed_ast.zig, 232 lines)
    Abstract TypeInfo → concrete SQL type strings per dialect
    Modifier classification into boolean flags
    Output: TypedAst (dialect-agnostic IR)
    │
    ▼
[6] Code Generator (codegen.zig, 323 lines)
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
| `TypedAst` | TypeResolver output | SQL type strings resolved, modifiers as booleans |
| `SchemaDiff` | Diff output | Table/field/index/FK diffs with rename detection |

## Reverse Pipeline

```
Input (SQL DDL text)
    │
    ▼
[1] SQL Parser (sql_parser.zig, 1289 lines)
    Recursive-descent DDL parsing (independent of forward tokenizer)
    Output: SqlSchema (tables, columns, indexes, FKs, checks)
    │
    ▼
[2] Reverse Codegen (reverse_codegen.zig, 706 lines)
    SQL types → TPS symbols (via type_map.zig reverse lookup)
    Template extraction (greedy + scoring algorithm)
    Output: .tps text
```

## Diff/Migrate Pipeline

```
(old.tps, new.tps)
    │
    ▼
[1] Compile both to ResolvedAst (forward pipeline)
    │
    ▼
[2] Diff Engine (diff.zig, 594 lines)
    Structural comparison with rename detection
    Output: SchemaDiff
    │
    ├──▶ Diff Printer (human-readable diff output)
    │
    └──▶ Migration Generator (migrate.zig, 465 lines)
         SchemaDiff → ALTER TABLE SQL
         Uses Codegen.emitColumnDef for column rendering
         Output: migration SQL
```

## DialectBackend Vtable

16 function pointers for dialect-specific SQL generation:

```zig
DialectBackend = struct {
    quoteIdent:             fn(w, name) -> !void,
    emitIndex:              fn(w, idx, needs_comma) -> !void,
    emitCreateDatabase:     fn(w, name, charset) -> !void,
    emitUnsigned:           fn(w) -> !void,
    emitTimestampModifier:  fn(w, with_on_update) -> !void,
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

PG and SQLite share 4/5 method implementations. `emitCheckExpr` is a shared standalone function (all dialects use identical CHECK syntax).

## Semantic Pass Manager

```zig
SemanticPass = struct { name: []const u8, run: fn(*PassContext) !void };
DEFAULT_PASSES = [_]SemanticPass{ autofk, suffix_inference, validate };
```

New passes can be added by:
1. Writing a function with signature `fn(*PassContext) !void`
2. Adding a `SemanticPass` entry to `DEFAULT_PASSES`

## Template Extraction Algorithm (Reverse Pipeline)

When `typespec reverse -t` is used, the reverse codegen extracts common field sequences across tables and promotes them as reusable templates.

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

TypeSpec uses two separate mapping tables in `type_map.zig`:

- **`FORWARD_MAP`**: 10 core single-char TPS symbols → SQL types. Used by `toSqlType()` and `typed_ast.resolveColumn()`. Clean, minimal, no priority fields needed.

- **`REVERSE_MAP`**: ~35 entries covering all SQL type variants → TPS symbols. Used by `reverseLookup()` and `reverseLookupSqlite()`. Includes core entries (for SQLite lossy affinity) plus MySQL/PG variant types. Entries have `rev_priority` for disambiguation.

- **`TYPE_TABLE`**: Computed constant combining both maps. Available for backward compatibility; new code should prefer `FORWARD_MAP` or `REVERSE_MAP`.

## Key Design Decisions

1. **TypedAst IR layer**: Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.
2. **DialectBackend vtable**: 16 function pointers cover all dialect differences. Adding a new dialect requires < 60 lines. codegen.zig is fully dialect-agnostic (zero `switch(dialect)` in production code).
3. **AST-level diff**: Semantic comparison, not text diff. Detects renames by signature matching.
4. **Arena allocation**: All modules take `std.mem.Allocator`. Arena-style usage for command-lifetime memory.
5. **Parser module extraction**: `parse_field.zig`, `parse_fk.zig`, `parse_check.zig`, `parse_index.zig` serve as standalone reference implementations.
6. **Template/Semantic separation**: Template resolution (inheritance, slot merging) is independent of semantic passes (autofk, suffix_inference, validation). Each can be modified without affecting the other.

## Adding a New SQL Dialect

1. Add variant to `Dialect` enum in `type_map.zig`
2. Add type mappings to `FORWARD_MAP` and `REVERSE_MAP` in `type_map.zig`
3. Create `DialectBackend` instance in `dialect.zig` (implement all 16 methods)
4. Register in `getBackend()` switch
5. Add golden file tests in `tests/`

No changes needed in `codegen.zig` — it is fully dialect-agnostic.

## Testing Strategy

| Layer | Files | Count | Coverage |
|-------|-------|-------|----------|
| Unit tests | `type_map.zig`, `tokenizer.zig`, `parser.zig`, `diff.zig`, `semantic.zig`, `template.zig` | ~100 | Core logic |
| MySQL golden | `tests/test.sh` | 81 | Full pipeline |
| PG golden | `tests/test_postgres.sh` | 93 | Full pipeline |
| SQLite golden | `tests/test_sqlite.sh` | 16 | Full pipeline |
| Migrate golden | `tests/test_migrate.sh` | 10 | Diff + migration SQL |
| Reverse golden | `tests/test_reverse.sh` | 15 | SQL → .tps |
| Diff golden | `tests/test_diff.sh` | 8 | Schema comparison |
| **Total** | | **~223+** | |
