# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.3.0] - 2026-07-02

### Changed
- **Breaking**: Unique index shorthand changed from `@!` to `@u` (more intuitive: `u` = unique, saves 1 Shift keystroke)
- **Breaking**: Removed `_by` suffix inference — `deleted_by` now requires explicit type (e.g., `deleted_by n`). The `_by → int` convention was unintuitive since `_by` fields are often strings (usernames), not integers.

### Fixed
- Updated grammar, documentation, and all examples to reflect both changes

## [0.2.0] - 2024-07-02

### Added
- Type-modifier fusion: `n!` (int PRIMARY KEY), `n*` (int NOT NULL), `s32!`, `s128*`
- FK ultra-shorthand: `-> user.id` infers local field as `user_id`
- FK action abbreviations: `[C]` (CASCADE), `[SN]` (SET NULL), `[R]` (RESTRICT), `[NA]` (NO ACTION), `[U C]` (UPDATE CASCADE)
- Template inheritance shorthand: `% audit > base` (saves 6 chars vs `extends`)
- `_by` suffix inference: `deleted_by` → int (alongside existing `_id`, `_on`, `_at`)
- Diagnostic warnings for unrecognized tokens and invalid modifier-type combinations

### Changed
- Table name heuristic: `# name` (2 tokens) = table without template; `# tmpl name` (3+ tokens) = table with template ref
- Grammar EBNF updated with `>` shorthand, FK abbreviations, ultra-shorthand production

### Fixed
- FK actions outside brackets silently ignored → now emit warning
- Unrecognized tokens in field declarations silently dropped → now emit warning

## [0.1.0] - 2024-07-01

### Added
- Template inheritance with `extends` keyword
- Default template support (unnamed `%`)
- Composite primary key support
- CHECK constraint syntax
- Three comment styles: `;` (spec), `--` (SQL), `//` (COMMENT clause)

### Changed
- Improved EBNF grammar documentation
- Enhanced FAQ sections

## [0.0.0] - 2024-01-01

### Added
- Initial release
- Type Spec: field type declarations (`n`, `s`, `m`, `t`, etc.)
- Schema Spec: table structure, constraints, indexes, foreign keys
- Template system with `...` slot
- Suffix-based type inference (`_id`, `_on`, `_at`)
- Regex patterns for parsing
