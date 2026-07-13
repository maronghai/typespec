# TypeSpec v0.4.20 Upgrade Plan

> Generated from architecture deep analysis (2026-07-13)

## Overview

Addresses remaining architectural risks identified in codebase review: parser/modularization debt, forward parser error recovery, diff engine complexity, and type constraint strictness. Builds on v0.4.19 foundation (CI, custom types, benchmarks).

---

## Phase 1: Parser Modularization

### 1.1 Problem

[parser.zig](zig-typespec/src/parser.zig) (741 lines) handles schema, template, table, field, index, FK, composite PK, and SQL comments in one file. [parse_field.zig](zig-typespec/src/parse_field.zig), [parse_fk.zig](zig-typespec/src/parse_fk.zig), [parse_check.zig](zig-typespec/src/parse_check.zig), [parse_index.zig](zig-typespec/src/parse_index.zig) already exist as extracted modules — extend this pattern.

### 1.2 New Modules

| New Module | Extract From parser.zig | Est. Lines |
|-----------|------------------------|-----------|
| `parse_schema.zig` | `parseSchemaDecl()` + charset/autofk parsing | ~80 |
| `parse_template.zig` | `parseTemplateDef()` + parent_ref + slot detection | ~200 |
| `parse_table.zig` | `parseTableDecl()` + engine/comment parsing | ~150 |

[parser.zig](zig-typespec/src/parser.zig) becomes the top-level dispatch: `parse()` method that iterates lines, calls `parseSchemaDecl`/`parseTemplateDef`/`parseTableDef`/etc. Expected to shrink to ~350 lines.

### 1.3 Migration

- Create new modules alongside existing parser.zig
- Move functions incrementally, run `zig build test` + golden tests after each move
- No external API changes — parser.zig remains the public entry point
- Each new module is a `pub fn` callable from parser.zig

---

## Phase 2: Forward Parser Error Recovery

### 2.1 Problem

Forward parser stops at first syntax error. Users see only one error per compile. The reverse parser ([sql_parser.zig](zig-typespec/src/sql_parser.zig)) already has multi-error collection — extend this to the forward path.

### 2.2 Approach

**Synchronization tokens**: `$`, `%`, `#` at line start are recovery points. On error, skip to next stable point and continue parsing.

```zig
// In each parse function, catch errors and push diagnostics:
fn parseTableDecl(...) catch |err| {
    diagnostics.push(.{ .severity = .@"error", .line_no = line, .message = @errorName(err) });
    // skip to next '#' or '%' or '$' or EOF
    return null; // partial result
};
```

### 2.3 Changes

**File:** [parser.zig](zig-typespec/src/parser.zig) (or new `parse_recovery.zig`)

- Add `DiagnosticCollector` to `Parser` struct
- Each `parse*()` function catches errors, pushes diagnostics, returns `?Result` (null on failure)
- Top-level `parse()` collects all non-null results into AST
- On 1+ errors, print all diagnostics and exit with code 1

**File:** [diagnostic.zig](zig-typespec/src/diagnostic.zig)

- Add `DiagnosticCollector` struct (already exists in reverse parser, reuse pattern)
- Support `push()`, `printAll()`, `hasErrors()` methods

### 2.4 Exit Code Policy

| Errors | Warnings | Exit Code | Behavior |
|--------|----------|-----------|----------|
| 0 | 0+ | 0 | Normal output |
| 1+ | any | 1 | Print all errors, abort |
| 0 | 1+ | 0 | Print warnings, normal output |

### 2.5 Tests

- Extend `tests/test_error_recovery.sh` with more scenarios
- Add golden tests for multi-error output format
- Target: 5+ error recovery test cases

---

## Phase 3: Type Constraint Strictness

### 3.1 Problem

`+`/`++` on varchar/boolean/blob types is "undefined" in the spec but produces no diagnostic in the compiler. Users get silently wrong output.

### 3.2 Changes

**File:** [semantic.zig](zig-typespec/src/semantic.zig) — new pass `validate_type_modifiers`

Add to `DEFAULT_PASSES` after `validate`:

```zig
.{ .name = "validate_type_modifiers", .run = runValidateTypeModifiers },
```

**Validation rules:**

| Modifier | Valid Types | Error Message |
|----------|------------|---------------|
| `+` / `++` (numeric context) | `n`, `N`, `\d+` | "'auto_increment' modifier invalid for type '{type}'" |
| `+` / `++` (datetime context) | `t`, `d` | "'current_timestamp' modifier invalid for type '{type}'" |
| `u` (unsigned) | `n`, `N`, `\d+` | "'unsigned' modifier invalid for type '{type}'" |

**File:** [type_map.zig](zig-typespec/src/type_map.zig)

Add helper:

```zig
pub fn isNumericTpsType(ti: TypeInfo) bool { ... }
pub fn isDatetimeTpsType(ti: TypeInfo) bool { ... }
```

(`isDatetimeTpsType` already exists; add `isNumericTpsType` to match.)

### 3.3 Tests

- Unit tests in [semantic.zig](zig-typespec/src/semantic.zig) for each violation
- Golden test with warning output for invalid modifier combinations

---

## Phase 4: Diff Engine Decomposition

### 4.1 Problem

[diff.zig](zig-typespec/src/diff.zig) (1,019 lines) handles table diff, field diff, index diff, FK diff, and rename detection in one file.

### 4.2 New Modules

| New Module | Responsibility | Est. Lines |
|-----------|---------------|-----------|
| `diff_fields.zig` | Field-level diffing + rename detection | ~250 |
| `diff_indexes.zig` | Index diffing | ~150 |
| `diff_fks.zig` | FK diffing | ~150 |
| `diff.zig` (slimmed) | Table-level orchestration + SchemaDiff types | ~400 |

### 4.3 Migration

Same incremental approach as Phase 1: extract one module at a time, run `zig build test` + `bash tests/test_diff.sh` + `bash tests/test_migrate.sh` after each extraction.

---

## Phase 5: Documentation Updates

### 5.1 ARCHITECTURE.md

- Update module dependency graph with new parse_* modules
- Document error recovery design (synchronization tokens, partial AST)
- Add "Type Constraint Validation" section

### 5.2 CONTRIBUTING.md

- Update "Adding a new feature" section with error recovery info
- Add `zig fmt` enforcement note (already present, verify)

### 5.3 CHANGELOG.md

```markdown
## v0.4.20 (2026-07-xx)

### Added
- Parser modularization: parse_schema.zig, parse_template.zig, parse_table.zig
- Forward parser error recovery: multiple errors per compile, sync-token recovery
- Type constraint validation: `+`/`++`/`u` on wrong types now produces warnings
- Diff engine modularization: diff_fields.zig, diff_indexes.zig, diff_fks.zig
- 5+ new error recovery test cases

### Changed
- parser.zig slimmed from ~741 to ~350 lines (dispatch-only)
- diff.zig slimmed from ~1,019 to ~400 lines (orchestration-only)
- Type modifier validation now warns on undefined combinations

### Internal
- parse_schema.zig (~80 lines), parse_template.zig (~200 lines), parse_table.zig (~150 lines)
- diff_fields.zig (~250 lines), diff_indexes.zig (~150 lines), diff_fks.zig (~150 lines)
```

---

## Execution Order

| Phase | Depends On | Risk | Effort | Parallel? |
|-------|-----------|------|--------|-----------|
| 1. Parser modularization | None | Medium | 3-4h | ✅ Track A |
| 2. Error recovery | Phase 1 | Medium | 4-6h | Track A |
| 3. Type constraints | None | Low | 1-2h | ✅ Track B |
| 4. Diff decomposition | None | Low | 2-3h | ✅ Track B |
| 5. Docs | All | Low | 1h | Final |

**Track A:** Phase 1 → Phase 2 (parser work)
**Track B:** Phase 3 + Phase 4 (independent)

---

## Non-Goals for v0.4.20

- New SQL dialects (Oracle, MSSQL) — defer to v0.5.x
- LSP server — defer to v0.6.x (needs error recovery first, shipping in this version)
- Template extraction algorithm improvement — working well enough
- Breaking syntax changes — stability priority
- Zig-based benchmark suite — shell benchmark already exists, Zig version deferred
- Incremental/streaming compilation — schema files are small, not needed yet
