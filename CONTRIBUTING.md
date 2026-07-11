# Contributing to TypeSpec

## Prerequisites

- [Zig](https://ziglang.org/) 0.16 or later
- Bash (for test scripts)

## Build

```bash
cd zig-typespec
zig build
```

Output binary: `zig-out/bin/typespec`

## Run Tests

```bash
# All forward compilation tests (MySQL)
bash tests/test.sh

# PostgreSQL tests
bash tests/test_postgres.sh

# SQLite tests
bash tests/test_sqlite.sh

# Migration tests
bash tests/test_migrate.sh

# Reverse engineering tests
bash tests/test_reverse.sh

# Diff tests
bash tests/test_diff.sh

# Zig unit tests (type_map, tokenizer, parser, diff, semantic)
cd zig-typespec && zig build test

# Filter by name
bash tests/test.sh template
bash tests/test_migrate.sh add-column
```

## Adding a New Feature

### 1. Add a new TPS type symbol

1. Add mapping to `TYPE_TABLE` in `src/type_map.zig`
2. Add reverse mapping for SQL → TPS
3. Update `src/typed_ast.zig` TypeResolver if dialect-specific logic needed
4. Add unit tests in `type_map.zig`
5. Add golden file test in `tests/`

### 2. Add a new SQL dialect

1. Add variant to `Dialect` enum in `src/type_map.zig`
2. Add type mappings to `TYPE_TABLE`
3. Create `DialectBackend` instance in `src/dialect.zig`
4. Register in `getBackend()` switch
5. Update `src/typed_ast.zig` for dialect-specific type logic
6. Add golden file tests

### 3. Add a new semantic pass

1. Write a function with signature `fn(*PassContext) !void`
2. Add a `SemanticPass` entry to `DEFAULT_PASSES` in `src/semantic.zig`
3. Add unit tests

### 4. Add a new CHECK constraint form

1. Update `classifyCheck()` in `src/parse_check.zig`
2. Update `emitCheckExpr()` in `src/dialect.zig`
3. Update reverse parsing in `src/reverse_codegen.zig`
4. Add golden file tests for all three paths

## Golden File Tests

Each test compiles a `.tps` file and diffs the output against `tests/expected/<name>.sql`.

### Adding a new compile test

1. Create `tests/<name>.tps`
2. Run the compiler and capture output:
   ```bash
   ./zig-typespec/zig-out/bin/typespec tests/<name>.tps > tests/expected/<name>.sql
   ```
3. Verify the output is correct
4. Add the test case to `tests/test.sh`

### Adding a new migrate test

1. Create `tests/migrate-<name>-old.tps` and `tests/migrate-<name>-new.tps`
2. Generate expected output:
   ```bash
   ./zig-typespec/zig-out/bin/typespec migrate tests/migrate-<name>-old.tps tests/migrate-<name>-new.tps > tests/expected/migrate-<name>.sql
   ```
3. Verify and add to `tests/test_migrate.sh`

### Adding a new reverse test

1. Create `tests/reverse/<name>.sql`
2. Generate expected output:
   ```bash
   ./zig-typespec/zig-out/bin/typespec reverse tests/reverse/<name>.sql -d mysql > tests/reverse/<name>.mysql.tps
   ```
3. For dialect-specific golden files, use suffix: `.mysql.tps`, `.pg.tps`, `.sqlite.tps`
4. Add to `tests/test_reverse.sh`

## Code Style

- Use `std.mem.Allocator` as first parameter for memory-owning functions
- Arena allocation for command-lifetime memory (allocate once, free at end)
- Errors propagate via `try`/`catch`; use `DiagnosticCollector` for multi-error reporting
- Keep modules dependency-free where possible (leaf modules: `ast.zig`, `type_map.zig`, `diagnostic.zig`)
- Match existing comment density and naming conventions

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for module dependency graph, pipeline design, and key architectural decisions.
