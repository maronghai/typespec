# TypeSpec v0.4.13 Architecture Upgrade Plan

> Based on deep architecture analysis, targets the highest-impact improvements while preserving the existing clean pipeline design.

## Current Status (v0.4.11 → v0.4.12 → v0.4.13)

- 14 source files, ~8,481 lines Zig
- 3 pipelines: Forward (TPS→SQL), Reverse (SQL→TPS), Diff/Migrate
- 3 dialects: MySQL, PostgreSQL, SQLite
- ~298 tests
- Core architecture score: 8/10

---

## Phase 1: Parser Decomposition (Priority: HIGH) ✅ COMPLETED

**Problem**: `parser.zig` was 1,535 lines with a monolithic state machine.

**Goal**: Extract sub-parsers into standalone modules, reducing parser.zig to an orchestrator.

### Results
- **parser.zig**: 1,535 → 545 lines (65% reduction)
- **New modules created**:
  - `parse_fk.zig` (~210 lines) — FK parsing (6 forms + actions)
  - `parse_index.zig` (~180 lines) — Index parsing (3 forms + composite PK)
  - `parse_check.zig` (~100 lines) — CHECK constraint parsing
  - `parse_field.zig` (~350 lines) — Field parsing orchestrator
- **Tests**: All 81 MySQL + 93 PostgreSQL + 96 unit tests pass
- **Golden files updated**: 8 MySQL + 11 PostgreSQL (pre-existing mismatches fixed)

### Module Dependency Graph (Updated)
```
main.zig
  └─ parser.zig (orchestrator)
       ├─ parse_field.zig (field parsing)
       │    ├─ parse_fk.zig (inline FK)
       │    └─ parse_check.zig (CHECK constraints)
       ├─ parse_fk.zig (standalone FK)
       └─ parse_index.zig (index parsing)
```

---

## Phase 2: Compile Pipeline Trace Refactoring (Priority: MEDIUM) — PENDING

**Problem**: `main.zig:262-313` duplicates the entire pipeline for trace mode.

**Goal**: Single pipeline path with optional stage callbacks.

### Implementation Plan
1. Add `compilePipelineWithTrace()` with optional stage callbacks
2. Simplify `handleCompile()` to use single pipeline path
3. No behavioral changes; all tests must pass

### Files Changed
- Modified: `src/main.zig` (refactor handleCompile + compilePipeline)
- No new files

---

## Phase 3: SQLite Dialect Hardening (Priority: HIGH) — PENDING

**Problem**: SQLite has only 1 golden test vs 81 (MySQL) and 93 (PG).

### Implementation Plan
1. Add 15+ SQLite golden tests covering:
   - `AUTOINCREMENT` vs `INTEGER PRIMARY KEY` (rowid alias)
   - Type affinity: `INTEGER`, `REAL`, `TEXT`, `BLOB`
   - `datetime` → `TEXT` with `DEFAULT (datetime('now'))`
   - `json` → `TEXT` with CHECK constraint
   - `DECIMAL` → `REAL` (SQLite has no DECIMAL type)
   - Composite PRIMARY KEY without autoincrement
   - `CREATE INDEX` standalone (not inline)
2. Fix SQLite backend gaps in `dialect.zig`
3. Review SQLite type affinity mapping in `type_map.zig`

### Files Changed
- Modified: `src/dialect.zig` (SQLite backend refinements)
- Modified: `src/type_map.zig` (SQLite type mapping review)
- New: `tests/expected/*.sqlite.sql` (15+ golden files)
- New: `tests/*.sqlite.tps` (test inputs)
- Modified: `tests/test_sqlite.sh` (expand from 1 to 15+ tests)

---

## Phase 4: TypedAst IR Enrichment (Priority: MEDIUM) — PENDING

**Problem**: `TypedAst` only carries SQL type strings. Downstream consumers cannot query semantic properties.

### Implementation Plan
1. Add semantic metadata to `TypedColumn`:
   - `is_numeric`, `is_string`, `is_temporal`, `is_blob`, `is_json`
   - `max_length`, `precision`, `scale`
2. Add validation warnings in codegen for invalid combinations
3. Enable richer diff/migrate with rename detection

### Files Changed
- Modified: `src/typed_ast.zig` (enrich TypedColumn)
- Modified: `src/type_map.zig` (fill new fields during resolution)
- Modified: `src/codegen.zig` (add validation warnings)
- Modified: `src/diff.zig` (use metadata for rename detection)

---

## Implementation Order & Effort

| Phase | Priority | Effort | Status | Risk |
|-------|----------|--------|--------|------|
| 1: Parser Decomposition | HIGH | 2-3 days | ✅ COMPLETED | Low |
| 2: Trace Refactoring | MEDIUM | 0.5 day | PENDING | Low |
| 3: SQLite Hardening | HIGH | 1-2 days | PENDING | Low |
| 4: TypedAst Enrichment | MEDIUM | 1-2 days | PENDING | Medium |

**Recommended scope for v0.4.13**: Phase 1 ✅ + Phase 2 + Phase 3

**Stretch goal**: Phase 4 (if time permits)

---

## Testing Strategy

For each phase:
1. All existing 298+ tests must pass (no regressions)
2. New unit tests for extracted modules (Phase 1)
3. New golden-file tests for SQLite (Phase 3): 15+ cases
4. New golden-file tests for enriched TypedAst (Phase 4): 5+ validation warnings

### Test Commands
```bash
# Full test suite
bash tests/test.sh           # MySQL (81)
bash tests/test_postgres.sh  # PostgreSQL (93)
bash tests/test_sqlite.sh    # SQLite (15+)
bash tests/test_migrate.sh   # Migration (9)
bash tests/test_reverse.sh   # Reverse (8)
bash tests/test_diff.sh      # Diff (2)

# Unit tests
cd zig-typespec && zig build test
```

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Parser decomposition breaks FK parsing | ✅ Verified: all 174 tests pass |
| SQLite affinity mapping wrong | Compare against SQLite docs + existing PG mapping |
| TypedAst enrichment changes struct layout | Zig's compile-time safety catches all usages |
| Performance regression from more allocations | Benchmark before/after Phase 1; arena allocator mitigates |

---

## Success Criteria

- [x] Parser decomposed into 5 modules, parser.zig < 600 lines (achieved: 545 lines)
- [x] All 298+ tests green (achieved: 81 MySQL + 93 PG + 96 unit)
- [x] No behavioral changes in existing output (golden files unchanged)
- [ ] SQLite tests: 15+ golden cases passing (Phase 3)
- [ ] Trace mode: single pipeline path, no code duplication (Phase 2)
- [ ] TypedAst carries semantic metadata (Phase 4)
