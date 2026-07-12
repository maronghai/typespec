# Changelog

## v0.4.19 (2026-07-13)

### Added
- GitHub Actions CI (build + test on push/PR)
- Automated cross-platform release pipeline (Linux/macOS/Windows)
- Custom type system: `@type` directive for user-defined type aliases
- Dialect-specific type overrides (`@type uuid postgres=uuid mysql=s36`)
- `.editorconfig` for consistent formatting
- Shell-based benchmark suite (`bench/benchmark.sh`)
- `raw_sql` TypeInfo variant for dialect overrides

### Changed
- `zig fmt` enforced in CI
- Parser accepts unknown identifiers as potential custom type names
- Tokenizer classifies `@type` lines as `TypeDef` (not `Index`)
- `Schema` and `ResolvedAst` include `custom_types` field

### Internal
- `parseTypeDef()` method in Parser for `@type` directive parsing
- `lookupCustomType()` function in type_map.zig
- Custom type resolution in typed_ast.zig (checks custom types before FORWARD_MAP)
- Test count: 213+ (82 MySQL + 82 PG + 16 SQLite + 10 Migration + 15 Reverse + 8 Diff + 1 custom-types)

## v0.4.18

- Previous release
