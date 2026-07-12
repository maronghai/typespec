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
bash tests/test.sh                  # MySQL (82 tests)
bash tests/test_postgres.sh         # PostgreSQL (82 tests)
bash tests/test_sqlite.sh           # SQLite (16 tests)
bash tests/test_migrate.sh          # Migration (10 tests)
bash tests/test_reverse.sh          # Reverse engineering (15 tests)
bash tests/test_diff.sh             # Schema diff (8 tests)
bash tests/test_error_recovery.sh   # Error recovery (3 tests)
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

- **DialectBackend vtable** ([dialect.zig](zig-typespec/src/dialect.zig)): 16 function pointers for dialect-specific SQL rendering. [codegen.zig](zig-typespec/src/codegen.zig) is fully dialect-agnostic (zero `switch(dialect)` in production code). Adding a new SQL dialect = new enum variant + type mappings + ~60-line backend implementation.

- **Semantic Pass Manager** ([semantic.zig](zig-typespec/src/semantic.zig)): Extensible array of `SemanticPass` structs. Current passes: `autofk` → `suffix_inference` → `validate`. New passes: write a `fn(*PassContext) !void` and add to `DEFAULT_PASSES`.

- **TypedAst IR** ([typed_ast.zig](zig-typespec/src/typed_ast.zig)): Separates type resolution from code generation. Codegen only outputs strings — no type inference logic.

- **Template Slot Merging** ([template.zig](zig-typespec/src/template.zig)): Template inheritance with `...` slot controls field insertion order. Merge formula: `parent_before + child_before + <concrete> + child_after + parent_after`. Max 4 parents via mixin syntax (`+`).

- **Custom Type System**: `@type` directives in schema block define user-defined type aliases with optional dialect overrides. Resolved during type resolution, not parsing.

### Module Roles (by size, largest first)

| Module | Role |
|--------|------|
| `sql_parser.zig` | Recursive-descent SQL DDL parser (reverse pipeline) |
| `diff.zig` | Structural schema comparison with rename detection |
| `type_map.zig` | Single source of truth for TPS↔SQL type mappings (FORWARD_MAP + REVERSE_MAP) |
| `parser.zig` | Token-level `.tps` parser → AST (delegates to parse_field/fk/check/index.zig) |
| `codegen.zig` | TypedAst → SQL DDL text (delegates to dialect backend) |
| `reverse_codegen.zig` | SQL → `.tps` + greedy template extraction algorithm |
| `semantic.zig` | Pass manager + template resolution orchestration |
| `dialect.zig` | DialectBackend vtable implementations for MySQL/PG/SQLite |
| `main.zig` | CLI entry point, argument parsing, command dispatch, shared pipeline |
| `template.zig` | Template inheritance resolution and slot-based field merging |

### Testing

- **Unit tests**: Inline `test` blocks in Zig source (run via `zig build test`)
- **Golden tests**: Shell scripts compile `.tps` files and `diff` against `.sql` golden files in `tests/expected/`
- Test data: `.tps` input files in `tests/`, expected output in `tests/expected/`

## Conventions

- Zig 0.16+, formatted with `zig fmt`
- Line endings: LF, 4-space indent for `.zig`/`.yml`, 2-space for `.md`/`.sh`/`.sql`
- All modules take `std.mem.Allocator` (arena-style, command-lifetime memory)
- Parser is fail-fast on syntax errors; semantic analyzer collects multiple diagnostics
