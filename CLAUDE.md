# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

TypeSpec is a minimal DSL for declaring database schemas using single-character symbols, implemented in Zig. It compiles `.ss` schema files into SQL DDL (MySQL/PostgreSQL/SQLite), and supports reverse engineering (SQL→.ss), schema diff, and migration generation.

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

### Three Pipelines

1. **Forward**: `.ss` → Tokenizer → Parser → Template Resolution → Semantic Analyzer → Type Resolver → Codegen → SQL
2. **Reverse**: SQL DDL → SqlParser → ReverseCodegen (with optional template extraction) → `.ss`
3. **Diff/Migrate**: Two `.ss` files each compile to `ResolvedAst` → DiffEngine produces `SchemaDiff` → MigrationGenerator outputs ALTER TABLE SQL

### IR Boundaries

`Line[]` (tokenizer output) → `Ast` (parser output: schema, templates, tables) → `[]ResolvedTable` (templates merged) → `ResolvedAst` (passes applied) → `TypedAst` (SQL type strings resolved, modifiers as booleans) → SQL string

### Key Design Patterns

- **DialectBackend vtable** ([dialect.zig](rune/src/dialect.zig)): 23 core + 6 optional function pointers + 3 behavioral flags for dialect-specific SQL rendering. Includes `emitForeignKey` (shared FK rendering via `dialect_common.zig:emitForeignKeyShared`) and `reverseLookup` for dialect-specific reverse engineering. [codegen.zig](rune/src/codegen.zig) is fully dialect-agnostic (zero `switch(dialect)` in production code). Per-dialect implementations: [dialect_mysql.zig](rune/src/dialect_mysql.zig), [dialect_pg.zig](rune/src/dialect_pg.zig), [dialect_sqlite.zig](rune/src/dialect_sqlite.zig); shared PG/SQLite logic in [dialect_common.zig](rune/src/dialect_common.zig). Adding a new SQL dialect = new enum variant + new `dialect_<name>.zig` (~200 lines).

- **Semantic Pass Manager** ([semantic.zig](rune/src/semantic.zig)): Extensible array of `SemanticPass` structs with `depends_on` dependency declarations. Pass implementations live in [pass/*.zig](rune/src/pass/) sub-modules; `semantic.zig` is the orchestrator (~150 lines production). Current passes (7): `validate_template_types` → `autofk` → `suffix_inference` → `validate` → `validate_type_modifiers` → `validate_indexes` → `validate_schema`. The `validate_schema` pass performs global consistency checks: circular FK detection (DFS, warning), FK target field existence (error), self-referencing FK field count validation (error). Debug mode validates dependency ordering. New passes: create `pass/<name>.zig` with `pub fn run(ctx: *PassContext) !void` and add to `DEFAULT_PASSES`.

- **TypedAst IR** ([typed_ast.zig](rune/src/typed_ast.zig)): Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.

- **Template Slot Merging** ([template.zig](rune/src/template.zig)): Template inheritance with `...` slot controls field insertion order. Merge formula: `parent_before + child_before + <concrete> + child_after + parent_after`. Max 4 parents via mixin syntax (`+`).

- **Custom Type System**: `~` directives in schema block define user-defined type aliases with optional dialect overrides. Resolved during type resolution, not parsing.

- **Self-contained SqlType** ([sql_type.zig](rune/src/sql_type.zig)): `SqlType.toSql()` delegates to `DialectBackend.renderType` for dialect-aware rendering. Variants: `int`, `bigint`, `smallint`, `decimal`, `varchar`, `text`, `blob`, `json`, `jsonb`, `datetime`, `date`, `timestamptz`, `boolean`, `uuid`, `inet`, `serial`, `enum_values`, `raw_sql`, `passthrough`. TPS symbols: `n`, `N`, `i`, `m`, `M`, `s`, `S`, `b`, `B`, `j`, `J`, `I`, `d`, `t`, `T`, `U`, `p`. `toJsonSchema()` provides dialect-agnostic JSON Schema output.

- **Dialect-Aware Diff** ([diff_semantic.zig](rune/src/diff_semantic.zig)): Type equivalence checking uses canonical TPS symbol mapping — different symbols that resolve to the same SQL type are equivalent (e.g. `N4` ↔ `4`), but distinct types like `n` (int) vs `N` (bigint) are NOT equivalent. Diff engine accepts optional `Dialect` parameter.

- **Two-Pass FK Diffing** ([diff_fks.zig](rune/src/diff_fks.zig)): First pass matches identical FKs (structure + actions). Second pass matches structurally identical FKs with different actions → `modify` (single ALTER TABLE with DROP+ADD). Remaining unmatched FKs → `drop`/`add`. Produces minimal migration SQL.

- **Reverse Lookup Vtable**: `DialectBackend.reverseLookup` (optional) allows dialect-specific reverse engineering (e.g. SQLite's heuristic-based INTEGER/TEXT disambiguation). Fallback to general REVERSE_MAP matching when vtable is null.

- **Unified ReverseResult**: `dialect.zig` defines the single `ReverseResult` struct (`tps`, `omit`, `score`, `is_parameterized`). Both `type_registry.zig` and `reverse_column.zig` re-export it — zero duplication across the reverse pipeline.

### Module Roles (by size, largest first)

| Module | Role |
|--------|------|
| `codegen.zig` | TypedAst → SQL DDL text, orchestrates column/index/constraint emission. FK rendering via `DialectBackend.emitForeignKey`. Tests in `codegen_test.zig` |
| `codegen_columns.zig` | Column definition rendering (emitColumnDef, emitColumnDefEx, emitDefault) + shared `isDominatedByExplicitIndex()` helper |
| `codegen_indexes.zig` | Inline and standalone index emission (emitInlineIndexes, emitStandaloneIndexes, emitInlineColumnStandaloneIndexes) |
| `sql_parser.zig` | Recursive-descent SQL DDL parser (reverse pipeline), delegates to 8 sub-modules |
| `sql_parser_helpers.zig` | Identifier/literal/word parsing, whitespace/comment skipping, trailing comment capture, `parseExpression` general expression parser, enhanced `parseDefaultValue` (parentheses, sign support) |
| `sql_parser_alter.zig` | ALTER TABLE statement parsing |
| `sql_parser_comment.zig` | COMMENT ON TABLE/COLUMN parsing |
| `semantic.zig` | Pass manager orchestrator + `PassContext` type + `DEFAULT_PASSES` array + `diagnosticTrace`. Pass implementations in `pass/*.zig` sub-modules |
| `pass/*.zig` | 7 semantic pass implementations: `autofk`, `suffix_inference`, `validate`, `validate_template_types`, `validate_type_modifiers`, `validate_indexes`, `validate_schema` |
| `diff.zig` | Table-level diff engine + re-exports types from `diff_types.zig`. Tests in `diff_test.zig` |
| `diff_types.zig` | Shared diff data structures (SchemaDiff, TableDiff, FieldDiff, etc.) — extracted to break diff↔diff_format cycle |
| `diff_format.zig` | Diff output formatting (imports `diff_types.zig`, not `diff.zig`) |
| `parser.zig` | Token-level `.ss` parser → AST (delegates to parse_*.zig modules; main dispatch + error recovery via parse_recovery.zig) |
| `migrate.zig` | Migration SQL generation, 6 sub-functions (emitDroppedTables, emitViewDiffs, emitTableDiffs, emitFieldDiffs, emitIndexDiffs, emitMetadataDiffs, emitFkDiffs). FK rendering via `DialectBackend.emitForeignKey`. Tests in `migrate_test.zig` |
| `ast_visitor.zig` | Comptime-generic AST traversal utilities (read-only + mutable `walkResolvedTablesMut`; `ResolvedTable.fields` is `[]Field`). Tests in `ast_visitor_test.zig` |
| `parse_trace.zig` | Parser diagnostic trace output (debug mode, extracted from parser.zig) |
| `parse_recovery.zig` | Error handling (handleParseError, locFromLine) + sync point detection (findNextSyncPoint) for forward parser error recovery |
| `parse_field.zig` | Field declaration parsing (type, modifiers, default, inline FK) |
| `diff_fields.zig` | Field-level diffing + rename detection + dialect-aware equality helpers. Tests in `diff_fields_test.zig` |
| `tokenizer.zig` | Lexical tokenizer (.ss text → Line[]) |
| `sql_parser_create.zig` | CREATE TABLE parsing (extracted from sql_parser.zig) |
| `reverse_map.zig` | Reverse lookup logic (SQL → TPS symbol matching via vtable + parameterized types) |
| `reverse_column.zig` | Column reverse engineering (re-exports dialect.ReverseResult as TypeResult, suffix, inline index detection) |
| `diagnostic.zig` | Multi-error diagnostic collector with JSON output. Unified across forward and reverse pipelines (`SqlParser` uses `DiagnosticCollector` directly) |
| `trace.zig` | Shared AST trace formatting (FK actions, FK declarations, index declarations, `fmtTypeInfo`, `fmtModifiers`) used by parser.zig and semantic.zig diagnosticTrace |
| `template.zig` | Template inheritance resolution and slot-based field merging |
| `template_extraction.zig` | Template extraction from SQL (reverse pipeline) |
| `typed_ast.zig` | TypedAst IR: SqlType resolution + ColumnFlags bitflags |
| `reverse_codegen.zig` | SQL → `.ss` orchestration, 4 sub-functions |
| `ast.zig` | AST type definitions (Schema, Table, Field, Template, etc.) |
| `reverse_check.zig` | CHECK constraint reverse engineering |
| `sql_type.zig` | Self-contained SqlType union with `toSql()` — single source of truth for type rendering |
| `dialect.zig` | DialectBackend vtable + getBackend() + unified ReverseResult (score + is_parameterized) + canOmitType + emitCheckExpr |
| `dialect_mysql.zig` | MySQL DialectBackend implementation (~270 lines) |
| `dialect_sqlite.zig` | SQLite DialectBackend implementation + reverse lookup heuristics (~244 lines) |
| `dialect_common.zig` | Shared PG/SQLite dialect functions (quoting, indexes, ALTER) |
| `sqlite_hints.zig` | SQLite-specific type affinity hints + column name heuristics |
| `reverse_map_data.zig` | REVERSE_MAP data table (SQL ↔ TPS type mappings, 46 entries) |
| `reverse_fk.zig` | FK classification for reverse pipeline |
| `type_map.zig` | Helper functions (lookupCustomType, isNumericTpsType) + SqlType re-export |
| `type_registry.zig` | TPS symbol → SqlType direct mapping (lookupSqlTypeDirect) + CORE_TYPES; re-exports dialect.ReverseResult |
| `type_resolver.zig` | ResolvedAst → TypedAst type resolution |
| `diff_indexes.zig` | Index diffing |
| `diff_fks.zig` | FK diffing — two-pass matching: exact (structure+actions) → structural (structure only, actions changed → modify) |
| `diff_semantic.zig` | Dialect-aware type equivalence (canonical TPS symbol mapping; n≠N, b≠B) |
| `parse_template.zig` | Template header parsing + slot detection + flush logic |
| `parse_table.zig` | Table header parsing + engine token stripping + view line parsing |
| `json_schema.zig` | JSON Schema output (dialect-agnostic) |
| `pipeline_forward.zig` | Forward pipeline orchestration (no cli.zig dependency) |
| `pipeline_reverse.zig` | Reverse pipeline + dialect auto-detection |
| `cli.zig` | CLI argument parsing, help text, Command/ParsedArgs type definitions |
| `pipeline_diff.zig` | Diff/migrate pipeline orchestration |
| `compiler.zig` | Re-export hub for pipeline modules |
| `bench.zig` | Benchmark entry point: per-stage pipeline timing via Io.Clock.Timestamp |
| `main.zig` | CLI entry point, command dispatch, output format routing |

### Testing

- **Unit tests**: Zig `test` blocks — inline in production files, or in dedicated `*_test.zig` files (`diff_test.zig`, `codegen_test.zig`, `migrate_test.zig`, `ast_visitor_test.zig`, `diff_fields_test.zig`, `sql_parser_test.zig`, `semantic.zig`). Run via `zig build test`
- **Golden tests**: Shell scripts compile `.ss` files and `diff` against `.sql` golden files in `tests/expected/`
- Test data: `.ss` input files in `tests/`, expected output in `tests/expected/`

## Conventions

- Zig 0.16+, formatted with `zig fmt`
- Line endings: LF, 4-space indent for `.zig`/`.yml`, 2-space for `.md`/`.sh`/`.sql`
- All modules take `std.mem.Allocator` (arena-style, command-lifetime memory)
- Parser is fail-fast on syntax errors; semantic analyzer collects multiple diagnostics
