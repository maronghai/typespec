# TypeSpec v0.4.19 Upgrade Plan

> Generated from architecture deep analysis (2026-07-13)

## Overview

Addresses 7 architectural risks and improvement areas identified in the codebase review. Target: ship engineering hardening + extensibility foundations without breaking changes.

---

## Phase 1: Engineering Hardening (CI/CD + Quality)

### 1.1 GitHub Actions CI

**File:** `.github/workflows/ci.yml`

```yaml
name: CI
on: [status, push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with:
          version: 0.16.0
      - run: cd zig-typespec && zig build test
      - run: bash tests/test.sh
      - run: bash tests/test_postgres.sh
      - run: bash tests/test_sqlite.sh
      - run: bash tests/test_migrate.sh
      - run: bash tests/test_reverse.sh
      - run: bash tests/test_diff.sh
```

### 1.2 zig fmt Enforcement

- Add `zig fmt --check zig-typespec/src/` to CI
- Add `.editorconfig` at root for consistent formatting across editors

### 1.3 Automated Release Pipeline

**File:** `.github/workflows/release.yml`

- Trigger on git tag matching `v*`
- Cross-compile: Linux (x86_64, aarch64), macOS (x86_64, aarch64), Windows (x86_64)
- Upload binaries to GitHub Release
- Tag format: `v0.4.19`, `v0.5.0`, etc.

---

## Phase 2: Parser Modularization

### 2.1 Split parser.zig (1450 lines) into focused modules

| New Module | Responsibility | Est. Lines |
|-----------|---------------|-----------|
| `parse_schema.zig` | Schema-level declarations (`$`, charset, autofk) | ~80 |
| `parse_template.zig` | Template declarations (`%`, parents, slots) | ~200 |
| `parse_table.zig` | Table declarations (`#`, engine, comments) | ~150 |
| `parse_composite.zig` | Composite primary keys, SQL comments | ~120 |
| `parser.zig` (slimmed) | Top-level dispatch + shared state | ~400 |

### 2.2 Migration Strategy

- Create new modules alongside existing parser.zig
- Move functions incrementally, run `zig build test` after each move
- No external API changes — parser.zig remains the public entry point

---

## Phase 3: Error Recovery (LSP Foundation)

### 3.1 Panic Recovery in Parser

Current: parser stops at first syntax error.
Target: collect all errors, continue parsing.

**Approach:**
- Replace `return error.ParseError` with `diagnostics.push(.{ .severity = .@"error", ... })` + skip-to-next-stable-point
- Add "synchronization tokens" (`#`, `%`, `$`) as recovery points
- Each parse function returns partial AST even on failure

### 3.2 Extended Diagnostic Types

```zig
pub const DiagnosticSeverity = enum { @"error", warning, @"info" };
pub const Diagnostic = struct {
    severity: DiagnosticSeverity,
    line_no: usize,
    column: ?usize = null,
    message: []const u8,
    related: ?[]const u8 = null,  // "see template '%base' defined here"
};
```

### 3.3 Exit Code Policy

- 0 errors → exit 0 (warnings are fine)
- 1+ errors → exit 1
- `--no-errors` flag: emit SQL even with errors (best-effort, for IDE preview)

---

## Phase 4: Type System Extension

### 4.1 Custom Type Support

Add extensible type registration alongside the 10 core types:

```
# In schema block:
$ mydb
  @type uuid = b(16)
  @type inet = s45
  @type jsonb = j
```

**Implementation:**
- Extend `TypeInfo` union: add `.custom` variant with name lookup
- Add `custom_types: StringHashMap(TypeInfo)` to `Schema`
- Parser: recognize `@type` directive in schema block
- Type resolver: check custom map before `FORWARD_MAP`
- Codegen: custom types resolve to their base SQL type per dialect

### 4.2 Dialect-Specific Type Override

```
$ mydb
  @type uuid postgres=uuid mysql=b(16) sqlite=s36
```

When a custom type has dialect-specific overrides, use those instead of the base mapping.

---

## Phase 5: Performance Profiling

### 5.1 Benchmark Suite

**File:** `bench/compile.zig`

Scenarios:
- Tiny: 3 tables, 5 fields each (baseline)
- Medium: 20 tables, 10 fields each (complex e-commerce)
- Large: 100 tables, 15 fields each (enterprise schema)

Measure: parse time, template resolution, semantic analysis, codegen, total.

### 5.2 Optimization Targets

- Pre-size `ArrayList` with known capacities where possible
- Reuse `StringHashMap` across passes instead of re-allocating
- Consider arena allocator for whole compilation lifetime (if not already)

---

## Phase 6: Documentation Updates

### 6.1 Update ARCHITECTURE.md

- Document new parser module structure
- Add error recovery design section
- Update module dependency graph

### 6.2 Update CONTRIBUTING.md

- Add `zig fmt` requirement
- Add CI checks section
- Document new parser module creation pattern

### 6.3 Changelog Entry

```markdown
## v0.4.19 (2026-07-xx)

### Added
- GitHub Actions CI (build + test + release)
- Cross-platform release binaries (Linux/macOS/Windows)
- Parser modularization (5 focused modules)
- Error recovery: continue parsing after syntax errors
- Custom type support (`@type` directive)
- Benchmark suite

### Changed
- `zig fmt` enforced across all source files
- Parser now reports all errors instead of stopping at first
- Diagnostic system supports info severity and related-location hints

### Internal
- Parser split: parse_schema, parse_template, parse_table, parse_composite
- Automated cross-compilation release pipeline
```

---

## Execution Order

| Phase | Depends On | Risk | Effort |
|-------|-----------|------|--------|
| 1. CI/CD | None | Low | 1-2h |
| 2. Parser split | None | Medium | 3-4h |
| 3. Error recovery | Phase 2 | Medium | 4-6h |
| 4. Custom types | None | Low | 2-3h |
| 5. Benchmarks | Phase 2 | Low | 1-2h |
| 6. Docs | All | Low | 1h |

**Parallel tracks:** Phase 1 and Phase 4 can run independently. Phase 2 should finish before Phase 3 and 5.

---

## Non-Goals for v0.4.19

- New SQL dialects (Oracle, MSSQL) — defer to v0.5.x
- LSP server — defer to v0.6.x (needs error recovery first)
- Template extraction algorithm improvement — working well enough
- Breaking syntax changes — stability priority
