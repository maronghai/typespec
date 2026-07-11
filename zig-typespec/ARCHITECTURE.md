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
   └────┬────┘ └──────┘ └────────┘ └───────┘
        │                ╲    ╱
        ▼                 ╲  ╱
   ┌─────────┐     ┌───────────┐
   │ dialect  │     │ diagnostic│
   └─────────┘     └───────────┘
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
[3] Semantic Analyzer (semantic.zig, 453 lines)
    Template resolution + inheritance merging
    Semantic passes: autofk, suffix_inference
    Output: ResolvedAst
    │
    ▼
[4] Type Resolver (typed_ast.zig, 232 lines)
    Abstract TypeInfo → concrete SQL type strings per dialect
    Modifier classification into boolean flags
    Output: TypedAst (dialect-agnostic IR)
    │
    ▼
[5] Code Generator (codegen.zig, 323 lines)
    TypedAst → SQL DDL text
    Dialect-specific rendering via DialectBackend vtable
    Output: SQL string
```

### IR Boundaries

| IR | Location | Content |
|----|----------|---------|
| `Line[]` | Tokenizer output | Line type + token array |
| `Ast` | Parser output | Schema, templates, tables, SQL comments |
| `ResolvedAst` | Semantic output | Templates applied, types inferred, autofk expanded |
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

5 function pointers for dialect-specific SQL generation:

```zig
DialectBackend = struct {
    quoteIdent:             fn(w, name) -> !void,
    emitIndex:              fn(w, idx, needs_comma) -> !void,
    emitCreateDatabase:     fn(w, name, charset) -> !void,
    emitUnsigned:           fn(w) -> !void,
    emitTimestampModifier:  fn(w, with_on_update) -> !void,
};
```

| Method | MySQL | PostgreSQL | SQLite |
|--------|-------|-----------|--------|
| `quoteIdent` | backticks | double-quotes | double-quotes |
| `emitIndex` | inline INDEX/UNIQUE/FULLTEXT | UNIQUE (...) inline | UNIQUE (...) inline |
| `emitCreateDatabase` | CHARACTER SET | ENCODING | no-op |
| `emitUnsigned` | `UNSIGNED` | no-op | no-op |
| `emitTimestampModifier` | `DEFAULT CURRENT_TIMESTAMP [ON UPDATE ...]` | `DEFAULT CURRENT_TIMESTAMP` | `DEFAULT CURRENT_TIMESTAMP` |

PG and SQLite share 4/5 method implementations. `emitCheckExpr` is a shared standalone function (all dialects use identical CHECK syntax).

## Semantic Pass Manager

```zig
SemanticPass = struct { name: []const u8, run: fn(*PassContext) !void };
DEFAULT_PASSES = [_]SemanticPass{ autofk, suffix_inference };
```

New passes can be added by:
1. Writing a function with signature `fn(*PassContext) !void`
2. Adding a `SemanticPass` entry to `DEFAULT_PASSES`

## Key Design Decisions

1. **TypedAst IR layer**: Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.
2. **DialectBackend vtable**: 5 function pointers cover all dialect differences. Adding a new dialect requires < 50 lines.
3. **AST-level diff**: Semantic comparison, not text diff. Detects renames by signature matching.
4. **Arena allocation**: All modules take `std.mem.Allocator`. Arena-style usage for command-lifetime memory.
5. **Parser module extraction**: `parse_field.zig`, `parse_fk.zig`, `parse_check.zig`, `parse_index.zig` serve as standalone reference implementations.

## Adding a New SQL Dialect

1. Add variant to `Dialect` enum in `type_map.zig`
2. Add type mappings to `TYPE_TABLE` in `type_map.zig`
3. Create `DialectBackend` instance in `dialect.zig`
4. Register in `getBackend()` switch
5. Update `typed_ast.zig` TypeResolver for any dialect-specific type logic
6. Add golden file tests in `tests/`

## Testing Strategy

| Layer | Files | Count | Coverage |
|-------|-------|-------|----------|
| Unit tests | `type_map.zig`, `tokenizer.zig`, `parser.zig`, `diff.zig`, `semantic.zig` | ~96 | Core logic |
| MySQL golden | `tests/test.sh` | 81 | Full pipeline |
| PG golden | `tests/test_postgres.sh` | 93 | Full pipeline |
| SQLite golden | `tests/test_sqlite.sh` | 1 | Full pipeline |
| Migrate golden | `tests/test_migrate.sh` | 9 | Diff + migration SQL |
| Reverse golden | `tests/test_reverse.sh` | 8 | SQL → .tps |
| Diff golden | `tests/test_diff.sh` | 2 | Schema comparison |
| **Total** | | **~298** | |
