# Changelog

## v0.4.22 (2026-07-13)

### Added
- SQLite roundtrip preservation: `-- @tps col_name type` metadata comments
  - Forward compiler emits `-- @tps` comments for SQLite to preserve original TPS types
  - Reverse compiler parses `-- @tps` comments to restore exact TPS types
  - Ensures `typespec -d sqlite | typespec reverse -d sqlite` is identity

### Changed
- `TypedColumn` gains `tps_type: ?[]const u8` field for original TPS type tracking
- `SqlColumn` gains `tps_override: ?[]const u8` field for roundtrip metadata
- Codegen emits `-- @tps` comments only for SQLite dialect (lossless dialects skip)

### Files
- `typed_ast.zig`: Added `tps_type` field and capture logic in `resolveColumn`
- `codegen.zig`: Emit `-- @tps` comments for SQLite
- `sql_parser_common.zig`: Added `tps_override` field to `SqlColumn`
- `sql_parser.zig`: Parse `-- @tps` comments in `captureTrailingComments`
- `reverse_codegen.zig`: Use `tps_override` before heuristic lookup
- 16 SQLite golden test files updated with `-- @tps` comments

## v0.4.21 (2026-07-13)

### Changed
- Custom type syntax: `@type name base_type` → `~ name base_type` (single `~` character replaces `@type`)
- Tokenizer classifies `~` lines as `TypeDef`
- `parse_typedef.zig` updated for `~` token layout (`["~", "name", ...]`)

## v0.4.20 (2026-07-13)

### Added
- Type constraint validation: `+`/`++`/`u` on wrong types now produces warnings
- Diff engine modularization: `diff_fields.zig`, `diff_indexes.zig`, `diff_fks.zig`
- Parser modularization: `parse_typedef.zig` extracted from parser.zig
- 6 new unit tests for type modifier validation

### Changed
- `diff.zig` slimmed from 1,019 to 608 lines (field/index/FK logic extracted)
- `parser.zig` delegates `@type` parsing to `parse_typedef.zig`
- Semantic pass pipeline now includes `validate_type_modifiers` pass
- Forward parser error recovery: `parseTemplate`/`parseTableHeader`/`parseTypeDef` now catch errors and record diagnostics instead of aborting
- `main.zig` uses `DiagnosticCollector` for multi-error reporting in forward pipeline
- `semantic.zig` `analyze()` returns `SemanticError` when errors are collected (stops codegen)
- FK validation (non-existent table/field) downgraded to warnings — DB enforces constraints

### Internal
- `diff_fields.zig` (260 lines): field diffing, rename detection, equality helpers
- `diff_indexes.zig` (81 lines): index diffing
- `diff_fks.zig` (85 lines): FK diffing
- `parse_typedef.zig` (54 lines): `@type` directive parsing
- `type_map.zig`: `isNumericTpsType()` helper already existed, now used by validation pass

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
