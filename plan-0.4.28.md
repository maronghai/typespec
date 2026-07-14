# plan-0.4.28.md — 架构升级计划

基于深度架构分析，按优先级排列。承继 plan-0.4.27.md 未完成项。

---

## 架构评分

| 维度 | 评分 | 说明 |
|------|------|------|
| 整体架构 | 8/10 | IR 分层清晰，vtable 方言隔离优秀 |
| 可扩展性 | 7/10 | 正向管线扩展容易，逆向管线受限 |
| 测试成熟度 | 8/10 | ~384 测试，覆盖面广，少数缺口 |
| 代码质量 | 9/10 | 零循环依赖，codegen 零方言 switch |

---

## P0 — 逆向管线 IR 统一（核心架构债）

### [ ] 1. 逆向管线 IR 统一

**问题**：正向管线 (`Line[] → Ast → ResolvedAst → TypedAst → SQL`) 和逆向管线 (`SQL → SqlSchema → .tps`) 使用两套完全独立的类型系统。

**预估工作量**：2-3 天  
**风险**：中等  
**状态**：未完成 — 需大量重构，建议作为独立任务处理

---

## P1 — SQL Parser 方言分离

### [ ] 2. SQL Parser 拆分

**问题**：`sql_parser.zig`（2000+ 行）内部用 `if (dialect == .sqlite)` 分支处理方言差异。

**预估工作量**：1-2 天  
**风险**：低  
**状态**：未完成 — 纯重构，可作为独立任务

---

## P1 — 语义 Pass 依赖声明

### [x] 3. SemanticPass 依赖声明

**已完成**：
- `SemanticPass` 结构体新增 `depends_on: []const []const u8` 字段
- `DEFAULT_PASSES` 中每个 pass 标注了依赖关系：
  - `autofk`: 无依赖
  - `suffix_inference`: depends_on `autofk`
  - `validate`: depends_on `autofk`, `suffix_inference`
  - `validate_type_modifiers`: depends_on `suffix_inference`
- `analyze()` 中添加 debug 模式依赖顺序验证（`std.debug.runtime_safety`）
- 所有测试通过

---

## P1 — Type Map 一致性保障

### [x] 4. Forward/Reverse 映射一致性检查

**已完成**：在 `type_map.zig` 中新增 3 个一致性测试：
- `consistency: every FORWARD_MAP entry has a matching REVERSE_MAP entry` — 验证每个 forward 条目在 reverse 中有对应
- `consistency: REVERSE_MAP core entries match FORWARD_MAP` — 验证前 10 条 reverse 条目与 forward 完全一致
- `consistency: no two REVERSE_MAP entries share same TPS + mysql type` — 验证无重复条目
- 所有测试通过

---

## P1 — 测试缺口补全

### [x] 5. 补全错误恢复测试

**已完成**：为 `duplicate-template.tps` 和 `invalid-custom-type.tps` 各添加测试用例：
- `duplicate-template` — 验证编译器优雅处理（第二个模板覆盖第一个，不崩溃）
- `invalid-custom-type` — 验证编译器优雅处理（未知类型透传为原始 SQL 类型）
- 错误恢复测试从 5 个扩展到 **7 个**，全部通过

### [x] 6. Migration 多方言测试

**已完成**：
- `test_migrate.sh` 重构为支持 3 方言（MySQL/PG/SQLite）循环
- 为 10 个 migration 测试场景各生成 `.pg.sql` 和 `.sqlite.sql` golden 文件（共 20 个新文件）
- Migration 测试从 10 个扩展到 **30 个**（10 MySQL + 10 PG + 10 SQLite），全部通过

### [~] 7. migrate.zig 内联测试

**状态**：延后。migrate.zig 依赖完整的 `ResolvedAst` + `TypeResolver` + `Codegen` 构建，内联测试需要大量 mock 数据构造。当前 30 个 golden 文件测试提供了足够的覆盖。

---

## P2 — Fuzzing 支持

### [ ] 8. Fuzzing 集成

**状态**：未完成。需为 tokenizer/parser/sql_parser 添加 fuzz target。

---

## P2 — Reverse Codegen 增强

### [x] 9. FK ALTER TABLE 逆向解析

**已完成**：
- `sql_parser.zig` 的 ALTER TABLE 处理从"静默跳过"升级为"解析 FK"
- 支持 `ALTER TABLE t ADD [CONSTRAINT fk_name] FOREIGN KEY (cols) REFERENCES ref (cols) [ON DELETE CASCADE] [ON UPDATE SET NULL]`
- 新增 2 个内联测试：带约束名和不带约束名的 ALTER TABLE FK
- 所有测试通过

### [x] 10. Reverse Codegen 补充测试

**已完成**：新增 10 个内联测试：
- `reverseCheck`: both exclusive range, compound comparison >= AND <=, single comparison =, single comparison <, backtick-quoted column, double-quote-quoted column（6 个）
- `classifyFk`: full with multiple actions, shorthand with non-id reference（2 个）
- 所有测试通过

---

## P3 — 单文件编译模型扩展

### [ ] 11. 多文件/模块系统（远期）

**状态**：未完成。需设计 `@import` 语法，涉及 parser/semantic 重构。

---

## P3 — 文档与 DX

### [x] 12. CLAUDE.md 更新

**已完成**：
- 测试数量更新：SQLite 16→24、Migration 10→30、Error recovery 3→7
- 模块表新增 `compiler.zig` 和 `cli.zig`
- Semantic Pass Manager 描述更新（添加 `depends_on` 说明）

### [ ] 13. 贡献者文档

**状态**：未完成。

### [ ] 14. 架构图可视化

**状态**：未完成。

---

## 完成总结

| 项目 | 状态 | 说明 |
|------|------|------|
| #1 逆向管线 IR 统一 | ❌ | 大型重构，独立任务 |
| #2 SQL Parser 方言分离 | ❌ | 纯重构，独立任务 |
| #3 SemanticPass 依赖声明 | ✅ | depends_on 字段 + debug 验证 |
| #4 Type Map 一致性检查 | ✅ | 3 个一致性测试 |
| #5 错误恢复测试补全 | ✅ | 5→7 测试 |
| #6 Migration 多方言测试 | ✅ | 10→30 测试（+20 golden files） |
| #7 migrate.zig 内联测试 | ~ | 延后（golden 文件覆盖） |
| #8 Fuzzing 集成 | ❌ | 未完成 |
| #9 FK ALTER TABLE 逆向解析 | ✅ | ALTER TABLE FK 解析 + 2 测试 |
| #10 Reverse Codegen 测试补全 | ✅ | +10 内联测试 |
| #11 多文件/模块系统 | ❌ | 远期 |
| #12 CLAUDE.md 更新 | ✅ | 测试数量 + 模块表 |
| #13 贡献者文档 | ❌ | 未完成 |
| #14 架构图可视化 | ❌ | 未完成 |
| **合计** | **8/14 完成** | |

### 新增测试统计

| 类别 | 之前 | 之后 | 新增 |
|------|------|------|------|
| Migration golden tests | 10 (MySQL only) | **30** (MySQL+PG+SQLite) | +20 |
| Error recovery tests | 5 | **7** | +2 |
| Zig inline tests (reverse_codegen) | 15 | **25** | +10 |
| Zig inline tests (type_map) | ~35 | **38** | +3 |
| Zig inline tests (sql_parser) | ~20 | **22** | +2 |
| **总计新增** | | | **+37 tests** |

### 代码变更

| 文件 | 变更 |
|------|------|
| `semantic.zig` | SemanticPass.depends_on + debug 验证 + DEFAULT_PASSES 注解 |
| `type_map.zig` | 3 个一致性测试 |
| `reverse_codegen.zig` | 10 个内联测试 |
| `sql_parser.zig` | ALTER TABLE FK 解析 + 2 个测试 |
| `test_error_recovery.sh` | +2 测试用例 |
| `test_migrate.sh` | 多方言循环支持 |
| `tests/expected/*.pg.sql` | +10 PG migration golden files |
| `tests/expected/*.sqlite.sql` | +10 SQLite migration golden files |
| `CLAUDE.md` | 测试数量 + 模块表更新 |
