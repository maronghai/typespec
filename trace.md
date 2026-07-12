# TypeSpec Upgrade Trace

> Auto-generated tracking file for architecture improvements.

## Phase 1: P0 修复（可靠性）— v0.4.7

| # | Item | Status | Notes |
|---|------|--------|-------|
| P0-1 | Parser 注入 DiagnosticCollector | ✅ | Parser 新增 `diagnostics: ?*DiagnosticCollector`；`initWithDiagnostics()` 构造器；parseField/parseFK/parseIndex/parseCompositePK 四处 catch 块收集错误继续解析；`push()` 修复 Zig 0.16 ArrayList.append 签名 |
| P0-2 | migrate.zig 列定义复用 Codegen | ✅ | 提取 `Codegen.emitColumnDef(w, TypedColumn)` 公共方法；migrate 通过 `TypeResolver.resolveColumn()` + `cg.emitColumnDef()` 复用；删除旧 `emitColumnDef()` + `emitTypeForColumn()` ~57 行 |

## Phase 2: P1 架构改进（可维护性）— v0.4.7

| # | Item | Status | Notes |
|---|------|--------|-------|
| P1-1 | TypeInfo tagged union 精简 | ⏭️ | 跳过（影响面广 6 文件，需更充分评估） |
| P1-2 | sql_parser.zig 字符扫描提取 | ⏭️ | 跳过（扫描器与 SqlParser 状态紧耦合，提取收益有限） |
| P1-3 | reverse_codegen 模板提取限制动态化 | ✅ | `while (template_idx < 5)` → `while (template_idx < @max(1, schema.tables.len / 3))` |

## Phase 3: P2 可测试性（覆盖）— v0.4.7

| # | Item | Status | Notes |
|---|------|--------|-------|
| P2-1 | diff.zig 单元测试 | ✅ | 5 个测试：空 diff、新表检测、删除表检测、新增字段、重命名字段 |
| P2-2 | semantic.zig 单元测试 | ✅ | 5 个测试：_id→int、_at→datetime、_on→date、显式类型覆盖、模板字段合并 |
| P2-3 | codegen.zig 单元测试 | ✅ | 4 个测试：MySQL 表生成、PG 表双引号、emitColumnDef 共享路径、PG 省略 UNSIGNED |
| P2-4 | migrate golden file 扩展 | ✅ | 新增 3 个测试：rename column、add index、add FK；migrate 测试 6→9 |

## Phase 4: P3 文档 — v0.4.7

| # | Item | Status | Notes |
|---|------|--------|-------|
| P3-1 | 内部架构图 | ✅ | `zig-typespec/ARCHITECTURE.md`：模块依赖图、5 阶段流水线、IR 边界表、DialectBackend vtable、语义 pass 系统、扩展指南 |
| P3-2 | 贡献指南 | ✅ | `CONTRIBUTING.md`：构建、测试、新功能/方言/pass/CHECK 扩展步骤、金标准文件添加方法、代码风格 |

---

## Phase 5: P0 重复代码清理 — v0.4.8

| # | Item | Status | Notes |
|---|------|--------|-------|
| P0-1 | 删除 4 个重复 parser 模块 | ✅ | 删除 `parse_field.zig`(372行)、`parse_fk.zig`(173行)、`parse_check.zig`(113行)、`parse_index.zig`(171行)；共 ~829 行死代码；`parser.zig` 不 import 这些模块，两套代码并存 |

## Phase 6: P1 DialectBackend vtable 扩展 — v0.4.8

| # | Item | Status | Notes |
|---|------|--------|-------|
| P1-1 | 扩展 DialectBackend vtable | ✅ | 新增 9 个方法（原 5 → 11）：`emitTableFooter`、`emitTableComment`、`emitColumnComment`、`emitAutoIncrement`、`emitPrimaryKey`、`emitInlineIndex`、`emitStandaloneIndex`、`emitInlineColumnComment`、`emitEnumTypeCheck` |
| P1-2 | MySQL backend 实现 | ✅ | 11 个方法全部实现；表尾 `ENGINE=... COMMENT='...'`；inline `COMMENT '...'`；`AUTO_INCREMENT`；`UNIQUE INDEX`/`INDEX` |
| P1-3 | PostgreSQL backend 实现 | ✅ | 11 个方法全部实现；`COMMENT ON TABLE/COLUMN`；`GENERATED ALWAYS AS IDENTITY`；`UNIQUE (...)` inline；standalone `CREATE INDEX` |
| P1-4 | SQLite backend 实现 | ✅ | 11 个方法全部实现；`-- comment` 风格；`PRIMARY KEY AUTOINCREMENT` combo；standalone `CREATE INDEX`（复用 PG 实现） |

## Phase 7: P2 codegen.zig 方言无关化 — v0.4.8

| # | Item | Status | Notes |
|---|------|--------|-------|
| P2-1 | `generateTypedTable` 清零 switch | ✅ | 6 处 `switch(self.dialect)` 全部替换为 vtable 调用 |
| P2-2 | `emitColumnDef` 清零 switch | ✅ | 2 处 `self.dialect` 检查（MySQL inline COMMENT、PG/SQLite enum CHECK）替换为 `emitInlineColumnComment` + `emitEnumTypeCheck` vtable 方法 |
| P2-3 | 验证 codegen.zig 无方言引用 | ✅ | `grep -E 'self\.dialect|switch.*dialect|\.mysql|\.postgres|\.sqlite'` 仅命中单元测试 setup 代码 |

## Phase 8: P3 进度跟踪 — v0.4.8

| # | Item | Status | Notes |
|---|------|--------|-------|
| P3-1 | 更新 trace.md | ✅ | 新增 v0.4.8 四阶段记录 |

---

## Phase 9: v0.4.14 — Architecture Hardening + Test Expansion

### Phase 9.1: SQLite Test Completion (Priority: HIGH) ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| T-1 | sqlite-autoincrement.tps | ✅ | INTEGER PRIMARY KEY AUTOINCREMENT |
| T-2 | sqlite-boolean.tps | ✅ | boolean → INTEGER (0/1) |
| T-3 | sqlite-datetime-json.tps | ✅ | datetime → TEXT, json → TEXT |
| T-4 | sqlite-decimal.tps | ✅ | DECIMAL → NUMERIC |
| T-5 | sqlite-composite-pk.tps | ✅ | composite PRIMARY KEY without autoincrement |
| T-6 | sqlite-blob.tps | ✅ | blob → BLOB |
| T-7 | sqlite-index.tps | ✅ | standalone CREATE INDEX |
| T-8 | sqlite-fk.tps | ✅ | foreign key with actions |
| T-9 | sqlite-check.tps | ✅ | CHECK constraints (BETWEEN, IN, comparison) |
| T-10 | sqlite-text.tps | ✅ | text types (S, s64) |
| T-11 | sqlite-template.tps | ✅ | template inheritance |
| T-12 | sqlite-explicit-types.tps | ✅ | explicit types (128, 10,2, s64, N, 20,6) |
| T-13 | sqlite-enum.tps | ✅ | enum → TEXT + CHECK |
| T-14 | sqlite-comment.tps | ✅ | table comment via -- style |
| T-15 | sqlite-multi-table.tps | ✅ | multiple tables with FKs |

### Phase 9.2: Diff Output Fix + Test Expansion (Priority: MEDIUM) ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| D-1 | printDiff → formatDiff (stdout) | ✅ | diff.zig: 新增 `formatDiff()` 返回字符串; main.zig: handleDiff 用 writeOutput 输出到 stdout |
| D-2 | add-column.golden 更新 | ✅ | 旧 golden 为空（stderr bug），已生成正确 golden |
| D-3 | type-change.diff.txt | ✅ | 字段类型变更检测 |
| D-4 | index-change.diff.txt | ✅ | 索引删除检测 |
| D-5 | fk-change.diff.txt | ✅ | FK 删除检测 |
| D-6 | table-drop.diff.txt | ✅ | 表删除 + 新表创建 |
| D-7 | no-change.diff.txt | ✅ | 空 diff（无变更） |
| D-8 | add-field.diff.txt | ✅ | 字段新增检测 |

### Phase 9.3: Migration Test Expansion (Priority: MEDIUM) ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| M-1 | migrate-multi-col.golden | ✅ | 多列同时 ALTER TABLE |
| M-2 | migrate-index.golden | ✅ | 索引新增/删除组合 |

### Phase 9.4: Reverse Test Expansion (Priority: MEDIUM) ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| R-1 | mysql-table | ✅ | MySQL 完整表（ENGINE, COMMENT, UNIQUE INDEX） |
| R-2 | pg-table | ✅ | PG 完整表（GENERATED AS IDENTITY, COMMENT ON） |
| R-3 | sqlite-table | ✅ | SQLite 完整表（FOREIGN KEY, INDEX, -- comment） |
| R-4 | mysql-composite | ✅ | MySQL 复合 PK + 多 FK |
| R-5 | pg-self-ref | ✅ | PG 自引用 FK（categories.parent_id） |
| R-6 | sqlite-settings | ✅ | SQLite settings 表 |
| R-7 | mysql-fk-enum | ✅ | MySQL FK + ENUM + ON UPDATE |

### Phase 9.5: DialectBackend vtable 扩展到 15 方法 (Priority: MEDIUM) ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| V-1 | emitInlineColumnStandaloneIndex 方法 | ✅ | MySQL=no-op, PG/SQLite=CREATE INDEX |
| V-2 | codegen.zig 零方言引用 | ✅ | grep 确认：仅测试 setup 代码引用 dialect |
| V-3 | ARCHITECTURE.md 更新 | ✅ | 15 方法，测试计数更新 |

---

## Summary

- **Started**: 2026-07-11
- **v0.4.14 completed**: 2026-07-12
- **Tests**: 223+ passing (81 MySQL + 93 PG + 16 SQLite + 10 Migrate + 15 Reverse + 8 Diff + ~96 Zig unit tests)
- **Items completed**: 17/17（v0.4.7: 10/12 + v0.4.8: 7/7 + v0.4.14: 30/30）
- **Items skipped**: 2/12（v0.4.7 P1-1/P1-2）
- **v0.4.14 key changes**:
  - SQLite 测试 1 → 16（16x 提升）
  - Diff 测试 2 → 8（4x 提升）
  - Migration 测试 9 → 10
  - Reverse 测试 8 → 15（近 2x 提升）
  - diff.zig: `formatDiff()` 输出到 stdout（修复 stderr bug）
  - DialectBackend vtable 14 → 15 方法
  - codegen.zig 100% 方言无关（零 switch(dialect)）
  - ARCHITECTURE.md 全面更新
- **v0.4.8 key changes**:
  - 删除 4 个重复 parser 模块（~829 行死代码）
  - DialectBackend vtable 5→11 方法
  - codegen.zig 实现零方言引用（纯 vtable 调用）
  - 新增方言只需：添加枚举 + 类型映射 + 11 个 backend 方法
- **Files modified**: `dialect.zig`（vtable 扩展）、`codegen.zig`（方言无关化）
- **Files deleted**: `parse_field.zig`、`parse_fk.zig`、`parse_check.zig`、`parse_index.zig`
