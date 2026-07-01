# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
