# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Rune is a minimal DSL for declaring database schemas using single-character symbols, implemented in Zig. It compiles `.ss` schema files into SQL DDL (MySQL/PostgreSQL/SQLite), and supports reverse engineering (SQL→.ss), schema diff, and migration generation.

## Build & Test Commands

```bash
cd rune && zig build                          # Build (debug)
cd rune && zig build -Doptimize=ReleaseSafe   # Build (release)
cd rune && zig build test                     # Unit tests (inline Zig test blocks)
cd rune && zig fmt --check src/               # Formatting check
cd rune && zig build bench                    # Benchmark (per-stage pipeline timing)
cd rune && zig build bench -- --save           # Save current timing as baseline
cd rune && zig build bench -- --check          # Check for regressions vs baseline (>20% = exit 1)
```

### Golden File Tests (shell-based, compare compiler output against .sql golden files)

```bash
bash tests/test.sh                  # MySQL (85 tests)
bash tests/test_postgres.sh         # PostgreSQL (83 tests)
bash tests/test_sqlite.sh           # SQLite (24 tests)
bash tests/test_migrate.sh          # Migration (34 tests)
bash tests/test_reverse.sh          # Reverse engineering (15 tests)
bash tests/test_diff.sh             # Schema diff (12 tests)
bash tests/test_error_recovery.sh   # Error recovery (12 tests)
bash tests/test_json_schema.sh      # JSON Schema (1 test)
bash tests/test_roundtrip.sh        # Round-trip (20 tests)
```

Run a single golden test by filter: `bash tests/test.sh 01` (matches test name substring).

### Quick Usage

```bash
./rune/zig-out/bin/rune schema.ss                        # Compile to stdout
./rune/zig-out/bin/rune schema.ss -o out.sql             # Compile to file
./rune/zig-out/bin/rune schema.ss -d pg                  # PostgreSQL output
./rune/zig-out/bin/rune schema.ss -d sqlite              # SQLite output
./rune/zig-out/bin/rune migrate old.ss new.ss           # Migration SQL
./rune/zig-out/bin/rune reverse schema.sql -t             # Reverse-engineer with template extraction
```

## Architecture

### Source Layout

```
rune/src/
  main.zig, cli.zig, compiler.zig, io.zig, utils.zig   # CLI + glue
  bench.zig, json_schema.zig, ast_visitor.zig            # standalone modules
  pipeline/    forward.zig, reverse.zig, diff.zig        # pipeline orchestration
  parser/      tokenizer.zig, parser.zig, parse_*.zig,   # forward parser (13 files)
               sql_parser*.zig, sql_parser_test.zig
  codegen/     codegen.zig, columns.zig, indexes.zig     # SQL code generation
  dialect/     dialect.zig, enum.zig, mysql.zig,          # dialect backends (7 files)
               pg.zig, sqlite.zig, common.zig, sqlite_hints.zig
  reverse/     codegen.zig, column.zig, map.zig,          # reverse engineering (7 files)
               map_data.zig, fk.zig, check.zig, template_extraction.zig
  diff/        engine.zig, types.zig, fields.zig,         # diff/migrate (9 files)
               fks.zig, indexes.zig, format.zig, semantic.zig, migrate.zig
  types/       ast.zig, resolved_ast.zig, typed_ast.zig,  # type system (8 files)
               sql_type.zig, type_map.zig, type_registry.zig,
               type_resolver.zig, symbol_table.zig
  semantic/    analyzer.zig, pass_manager.zig,            # semantic analysis (6 files)
               trace.zig, diagnostic.zig, template.zig,
               test_helpers.zig, pass/*.zig               # 8 pass implementations
```

### Three Pipelines

1. **Forward**: `.ss` → Tokenizer → Parser → Template Resolution → Semantic Analyzer → Type Resolver → Codegen → SQL
2. **Reverse**: SQL DDL → SqlParser → ReverseCodegen (with optional template extraction) → `.ss`
3. **Diff/Migrate**: Two `.ss` files each compile to `ResolvedAst` → DiffEngine produces `SchemaDiff` → MigrationGenerator outputs ALTER TABLE SQL

### IR Boundaries

`Line[]` (tokenizer output) → `Ast` (parser output: schema, templates, tables) → `[]ResolvedTable` (templates merged) → `ResolvedAst` (passes applied) → `TypedAst` (SQL type strings resolved, modifiers as booleans) → SQL string

### Key Design Patterns

- **DialectBackend vtable** (`dialect/dialect.zig`): 30 function pointers (24 required + 6 optional) + 3 behavioral flags for dialect-specific SQL rendering. `codegen/codegen.zig` is fully dialect-agnostic (zero `switch(dialect)` in production code). Per-dialect: `dialect/mysql.zig`, `dialect/pg.zig`, `dialect/sqlite.zig`; shared logic in `dialect/common.zig`. Adding a new SQL dialect = new enum variant + new `dialect/<name>.zig` (~200 lines).

- **Semantic Pass Manager** (`semantic/pass_manager.zig`): `PassContext` + `SemanticPass` interface + `DEFAULT_PASSES` array. Pass implementations in `semantic/pass/*.zig` (8 passes). `semantic/analyzer.zig` orchestrates template resolution + pass execution. Dependency ordering validated at comptime. New passes: create `semantic/pass/<name>.zig` with `pub fn run(ctx: *PassContext) !void` and add to `DEFAULT_PASSES`.

- **ResolvedAst IR** (`types/resolved_ast.zig`): `ResolvedTable` + `ResolvedAst` — output of template resolution + semantic passes. Separated from `types/ast.zig` (parser output) for clean IR boundary. Re-exported from `ast.zig` for backward compatibility.

- **TypedAst IR** (`types/typed_ast.zig`): Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.

- **Template Slot Merging** (`semantic/template.zig`): Template inheritance with `...` slot controls field insertion order. Merge formula: `parent_before + child_before + <concrete> + child_after + parent_after`. Max 4 parents via mixin syntax (`+`).

- **Self-contained SqlType** (`types/sql_type.zig`): `SqlType.toSql()` delegates to `DialectBackend.renderType` for dialect-aware rendering. `toJsonSchema()` provides dialect-agnostic JSON Schema output.

- **Dialect-Aware Diff** (`diff/semantic.zig`): Type equivalence checking uses canonical SS symbol mapping — different symbols that resolve to the same SQL type are equivalent (e.g. `N4` ↔ `4`), but distinct types like `n` (int) vs `N` (bigint) are NOT equivalent.

- **Two-Pass FK Diffing** (`diff/fks.zig`): First pass matches identical FKs (structure + actions). Second pass matches structurally identical FKs with different actions → `modify`. Remaining unmatched FKs → `drop`/`add`.

- **Reverse Lookup Vtable**: `DialectBackend.reverseLookup` (optional) allows dialect-specific reverse engineering (e.g. SQLite's heuristic-based INTEGER/TEXT disambiguation). Fallback to general `reverse/map.zig` matching when vtable is null.

- **Unified ReverseResult** (`dialect/dialect.zig`): Single `ReverseResult` struct shared by `types/type_registry.zig` and `reverse/column.zig` — zero duplication across the reverse pipeline.

### Module Roles

| Directory | Module | Role |
|-----------|--------|------|
| `pipeline/` | `forward.zig` | `.ss` → SQL orchestration (tokenizer → parser → semantic → type resolver → codegen) |
| | `reverse.zig` | SQL → `.ss` orchestration + dialect auto-detection |
| | `diff.zig` | Diff/migrate pipeline orchestration |
| `parser/` | `parser.zig` | Token-level `.ss` parser → AST, dispatches to parse_* modules |
| | `parse_field.zig` | Field declaration parsing (type, modifiers, default, inline FK) |
| | `parse_fk.zig`, `parse_check.zig`, `parse_index.zig` | FK/Check/Index parsing |
| | `parse_template.zig`, `parse_table.zig` | Template and table header parsing |
| | `parse_recovery.zig` | Forward parser error recovery |
| | `sql_parser.zig` | Recursive-descent SQL DDL parser (reverse pipeline) |
| | `sql_parser_helpers.zig` | Identifier/literal parsing, expression parser |
| | `sql_parser_create.zig`, `sql_parser_alter.zig`, etc. | SQL sub-statement parsing |
| `codegen/` | `codegen.zig` | TypedAst → SQL DDL text, orchestrates column/index/constraint emission |
| | `columns.zig` | Column definition rendering |
| | `indexes.zig` | Inline and standalone index emission |
| `dialect/` | `dialect.zig` | DialectBackend vtable + getBackend() + ReverseResult |
| | `enum.zig` | Dialect enum (mysql, pg, sqlite) |
| | `mysql.zig`, `pg.zig`, `sqlite.zig` | Per-dialect backend implementations |
| | `common.zig` | Shared PG/SQLite dialect functions |
| | `sqlite_hints.zig` | SQLite type affinity hints + column heuristics |
| `reverse/` | `codegen.zig` | SQL → `.ss` orchestration |
| | `column.zig` | Column reverse engineering |
| | `map.zig`, `map_data.zig` | Reverse lookup logic + REVERSE_MAP data (46 entries) |
| | `fk.zig`, `check.zig` | FK/Check constraint reverse engineering |
| | `template_extraction.zig` | Template extraction from SQL |
| `diff/` | `engine.zig` | Table-level diff engine |
| | `types.zig` | SchemaDiff, TableDiff, FieldDiff data structures |
| | `fields.zig` | Field-level diffing + rename detection |
| | `fks.zig` | FK diffing — two-pass matching |
| | `indexes.zig` | Index diffing |
| | `format.zig` | Diff output formatting |
| | `semantic.zig` | Dialect-aware type equivalence |
| | `migrate.zig` | Migration SQL generation |
| `types/` | `ast.zig` | AST type definitions (Schema, Table, Field, Template, etc.) |
| | `resolved_ast.zig` | ResolvedTable + ResolvedAst (semantic output) |
| | `typed_ast.zig` | TypedAst IR + ColumnFlags bitflags |
| | `sql_type.zig` | Self-contained SqlType union with toSql()/toJsonSchema() |
| | `type_map.zig` | Helper functions (lookupCustomType, isNumericSymType) |
| | `type_registry.zig` | SS symbol → SqlType direct mapping |
| | `type_resolver.zig` | ResolvedAst → TypedAst type resolution |
| | `symbol_table.zig` | Schema-level symbol table for name resolution |
| `semantic/` | `analyzer.zig` | SemanticAnalyzer + diagnosticTrace |
| | `pass_manager.zig` | PassContext + SemanticPass + DEFAULT_PASSES |
| | `trace.zig` | Shared AST trace formatting |
| | `diagnostic.zig` | Multi-error diagnostic collector |
| | `template.zig` | Template inheritance resolution |
| | `pass/*.zig` | 8 semantic passes (autofk, suffix_inference, validate, etc.) |
| root | `main.zig` | CLI entry point, command dispatch |
| | `cli.zig` | Argument parsing, Command/ParsedArgs types |
| | `compiler.zig` | Re-export hub for pipeline modules |
| | `io.zig` | File I/O, stdin reading, output writing |
| | `bench.zig` | Benchmark entry point |
| | `json_schema.zig` | JSON Schema output |

### Testing

- **Unit tests**: Zig `test` blocks — inline in production files, or in dedicated `*_test.zig` files (`diff_test.zig`, `codegen_test.zig`, `diff/migrate_test.zig`, `ast_visitor_test.zig`, `diff_fields_test.zig`, `parser/sql_parser_test.zig`, `semantic/analyzer.zig`). Run via `zig build test`
- **Golden tests**: Shell scripts compile `.ss` files and `diff` against `.sql` golden files in `tests/expected/`
- Test data: `.ss` input files in `tests/`, expected output in `tests/expected/`

## Conventions

- Zig 0.16+, formatted with `zig fmt`
- Line endings: LF, 4-space indent for `.zig`/`.yml`, 2-space for `.md`/`.sh`/`.sql`
- All modules take `std.mem.Allocator` (arena-style, command-lifetime memory)
- Parser is fail-fast on syntax errors; semantic analyzer collects multiple diagnostics
