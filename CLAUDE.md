# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

TypeSpec is a minimal DSL for declaring database schemas using single-character symbols, implemented in Zig. It compiles `.tps` schema files into SQL DDL (MySQL/PostgreSQL/SQLite), and supports reverse engineering (SQL→.tps), schema diff, and migration generation.

## Build & Test Commands

```bash
cd zig-typespec && zig build                          # Build (debug)
cd zig-typespec && zig build -Doptimize=ReleaseSafe   # Build (release)
cd zig-typespec && zig build test                     # Unit tests (inline Zig test blocks)
cd zig-typespec && zig fmt --check src/               # Formatting check
```

### Golden File Tests (shell-based, compare compiler output against .sql golden files)

```bash
bash tests/test.sh                  # MySQL (84 tests)
bash tests/test_postgres.sh         # PostgreSQL (82 tests)
bash tests/test_sqlite.sh           # SQLite (24 tests)
bash tests/test_migrate.sh          # Migration (34 tests)
bash tests/test_reverse.sh          # Reverse engineering (17 tests)
bash tests/test_diff.sh             # Schema diff (12 tests)
bash tests/test_error_recovery.sh   # Error recovery (9 tests)
```

Run a single golden test by filter: `bash tests/test.sh 01` (matches test name substring).

### Quick Usage

```bash
./zig-out/bin/typespec schema.tps                        # Compile to stdout
./zig-out/bin/typespec schema.tps -o out.sql             # Compile to file
./zig-out/bin/typespec schema.tps -d pg                  # PostgreSQL output
./zig-out/bin/typespec schema.tps -d sqlite              # SQLite output
./zig-out/bin/typespec migrate old.tps new.tps           # Migration SQL
./zig-out/bin/typespec reverse schema.sql -t             # Reverse-engineer with template extraction
```

## Architecture

### Three Pipelines

1. **Forward**: `.tps` → Tokenizer → Parser → Template Resolution → Semantic Analyzer → Type Resolver → Codegen → SQL
2. **Reverse**: SQL DDL → SqlParser → ReverseCodegen (with optional template extraction) → `.tps`
3. **Diff/Migrate**: Two `.tps` files each compile to `ResolvedAst` → DiffEngine produces `SchemaDiff` → MigrationGenerator outputs ALTER TABLE SQL

### IR Boundaries

`Line[]` (tokenizer output) → `Ast` (parser output: schema, templates, tables) → `[]ResolvedTable` (templates merged) → `ResolvedAst` (passes applied) → `TypedAst` (SQL type strings resolved, modifiers as booleans) → SQL string

### Key Design Patterns

- **DialectBackend vtable** ([dialect.zig](zig-typespec/src/dialect.zig)): 22 core + 5 optional function pointers + 3 behavioral flags for dialect-specific SQL rendering. [codegen.zig](zig-typespec/src/codegen.zig) is fully dialect-agnostic (zero `switch(dialect)` in production code). Per-dialect implementations: [dialect_mysql.zig](zig-typespec/src/dialect_mysql.zig), [dialect_pg.zig](zig-typespec/src/dialect_pg.zig), [dialect_sqlite.zig](zig-typespec/src/dialect_sqlite.zig); shared PG/SQLite logic in [dialect_common.zig](zig-typespec/src/dialect_common.zig). Adding a new SQL dialect = new enum variant + new `dialect_<name>.zig` (~200 lines).

- **Semantic Pass Manager** ([semantic.zig](zig-typespec/src/semantic.zig)): Extensible array of `SemanticPass` structs with `depends_on` dependency declarations. Current passes: `autofk` → `suffix_inference` → `validate` → `validate_type_modifiers`. Debug mode validates dependency ordering. New passes: write a `fn(*PassContext) !void` and add to `DEFAULT_PASSES`.

- **TypedAst IR** ([typed_ast.zig](zig-typespec/src/typed_ast.zig)): Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.

- **Template Slot Merging** ([template.zig](zig-typespec/src/template.zig)): Template inheritance with `...` slot controls field insertion order. Merge formula: `parent_before + child_before + <concrete> + child_after + parent_after`. Max 4 parents via mixin syntax (`+`).

- **Custom Type System**: `~` directives in schema block define user-defined type aliases with optional dialect overrides. Resolved during type resolution, not parsing.

- **Self-contained SqlType** ([sql_type.zig](zig-typespec/src/sql_type.zig)): `SqlType.toSql()` is the single source of truth for type rendering — no delegation to `type_map.zig`. `type_registry.lookupSqlTypeDirect()` returns `SqlType` variants directly, avoiding stringly-typed round-trips.

### Module Roles (by size, largest first)

| Module | Role |
|--------|------|
| `codegen.zig` | TypedAst → SQL DDL text, 5 sub-functions (emitColumnDefs, emitInlineIndexes, emitConstraints, emitTableMetadata, emitStandaloneIndexes) |
| `sql_parser.zig` | Recursive-descent SQL DDL parser (reverse pipeline) |
| `semantic.zig` | Pass manager + template resolution orchestration |
| `dialect.zig` | DialectBackend vtable definition + getBackend() + shared emitCheckExpr helper |
| `dialect_mysql.zig` | MySQL DialectBackend implementation (~270 lines) |
| `dialect_pg.zig` | PostgreSQL DialectBackend implementation (~150 lines) |
| `dialect_sqlite.zig` | SQLite DialectBackend implementation (~160 lines) |
| `dialect_common.zig` | Shared PG/SQLite dialect functions (quoting, indexes, ALTER) |
| `parser.zig` | Token-level `.tps` parser → AST (delegates to parse_*.zig modules) |
| `diff.zig` | Table-level diff orchestration + SchemaDiff types + printing |
| `reverse_map.zig` | Reverse lookup logic (SQL → TPS symbol matching + heuristics) |
| `reverse_map_data.zig` | REVERSE_MAP data table (SQL ↔ TPS type mappings, 46 entries) |
| `migrate.zig` | Migration SQL generation, 7 sub-functions (emitDroppedTables, emitViewDiffs, emitTableDiffs, emitFieldDiffs, emitIndexDiffs, emitMetadataDiffs, emitFkDiffs) |
| `ast_visitor.zig` | Comptime-generic AST traversal utilities |
| `parse_field.zig` | Field declaration parsing (type, modifiers, default, inline FK) |
| `tokenizer.zig` | Lexical tokenizer (.tps text → Line[]) |
| `diff_fields.zig` | Field-level diffing + rename detection + equality helpers |
| `sql_parser_create.zig` | CREATE TABLE parsing (extracted from sql_parser.zig) |
| `reverse_column.zig` | Column reverse engineering (type mapping, suffix, inline index detection) |
| `diagnostic.zig` | Multi-error diagnostic collector with JSON output |
| `template.zig` | Template inheritance resolution and slot-based field merging |
| `template_extraction.zig` | Template extraction from SQL (reverse pipeline) |
| `typed_ast.zig` | TypedAst IR: SqlType resolution + ColumnFlags bitflags |
| `reverse_codegen.zig` | SQL → `.tps` orchestration, 4 sub-functions |
| `ast.zig` | AST type definitions (Schema, Table, Field, Template, etc.) |
| `diff_format.zig` | Diff output formatting |
| `reverse_check.zig` | CHECK constraint reverse engineering |
| `sql_type.zig` | Self-contained SqlType union with `toSql()` — single source of truth for type rendering |
| `sqlite_hints.zig` | SQLite-specific type affinity hints |
| `reverse_fk.zig` | FK classification for reverse pipeline |
| `type_map.zig` | Helper functions (lookupCustomType, isNumericTpsType) + SqlType re-export |
| `type_registry.zig` | TPS symbol → SqlType direct mapping (lookupSqlTypeDirect) + CORE_TYPES |
| `diff_indexes.zig` | Index diffing |
| `diff_fks.zig` | FK diffing |
| `json_schema.zig` | JSON Schema output (dialect-agnostic) |
| `pipeline_forward.zig` | Forward pipeline orchestration (no cli.zig dependency) |
| `pipeline_reverse.zig` | Reverse pipeline + dialect auto-detection |
| `cli.zig` | CLI argument parsing, help text, Command/ParsedArgs type definitions |
| `pipeline_diff.zig` | Diff/migrate pipeline orchestration |
| `compiler.zig` | Re-export hub for pipeline modules |
| `main.zig` | CLI entry point, command dispatch, output format routing |

### Testing

- **Unit tests**: Inline `test` blocks in Zig source (run via `zig build test`)
- **Golden tests**: Shell scripts compile `.tps` files and `diff` against `.sql` golden files in `tests/expected/`
- Test data: `.tps` input files in `tests/`, expected output in `tests/expected/`

## Conventions

- Zig 0.16+, formatted with `zig fmt`
- Line endings: LF, 4-space indent for `.zig`/`.yml`, 2-space for `.md`/`.sh`/`.sql`
- All modules take `std.mem.Allocator` (arena-style, command-lifetime memory)
- Parser is fail-fast on syntax errors; semantic analyzer collects multiple diagnostics
