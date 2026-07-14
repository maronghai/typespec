# plan-0.4.27.md — 架构升级计划

基于深度架构分析，按优先级排列的改进项。

---

## P0 — 测试覆盖补强（高优先级）

### [x] 1. sql_parser.zig 内联测试

`sql_parser.zig` 是全项目最大文件（1,257 行），当前零内联测试，仅靠黄金文件间接覆盖。

**已完成：** 新增 20 个 Zig 内联 `test` 块，覆盖：

- `parseCreateTable` — 基本列解析、多列、带修饰符列
- `parseColumn` — 类型解析（多词类型如 `decimal(10,2)`、`varchar(255)`、`char(10)`）
- `parseColumn` — 修饰符解析（NOT NULL、UNSIGNED、AUTO_INCREMENT、PRIMARY KEY、DEFAULT、COMMENT、ON UPDATE CURRENT_TIMESTAMP）
- `parseForeignKey` — 基本 FK、复合 FK、ON DELETE/UPDATE actions（CASCADE、SET NULL）
- `parseIndex` — CREATE INDEX、CREATE UNIQUE INDEX、复合索引（含 DESC）
- `COMMENT ON TABLE` / `COMMENT ON COLUMN` — PG 注释附加
- PG `serial`/`bigserial` 归一化 + `GENERATED ALWAYS AS IDENTITY`
- SQLite `AUTOINCREMENT` + `-- @tps` 元数据注释 + `-- table.col: text` 列注释
- 跳过语句（ALTER TABLE、CREATE EXTENSION、CREATE SCHEMA）
- CREATE DATABASE with charset/encoding
- CHECK constraints
- 内联 DEFAULT 值（数字、字符串、NULL、十进制、二进制字面量）
- 多表解析
- 内联 INDEX/KEY（MySQL）

### [x] 2. SQLite 黄金文件补强

当前 SQLite 仅 16 个黄金测试，vs MySQL/PG 各 82 个。SQLite 是最容易出问题的方言。

**已完成：**

- 修复全部 16 个已有 SQLite 黄金文件（原来内容为 `error: FileNotFound` 占位符，已从编译器实际输出重新生成）
- 新增 8 个 SQLite 测试场景（sqlite-unsigned、sqlite-fk-actions、sqlite-autofk、sqlite-custom-types、sqlite-engine-ignored、sqlite-inline-comment、sqlite-template-deep、sqlite-mixed）
- SQLite 总覆盖从 16 提升至 **24**，全部通过

### [x] 3. 错误恢复测试扩充

当前仅 3 个错误恢复测试。

**已完成：**

- 新增 `multi-errors.tps` 测试 — 验证单文件产生 >=2 个 warning
- 新增 `circular-template.tps` 测试 — 验证循环模板继承检测
- 将测试脚本从 3 个扩展到 **5 个**，全部通过
- 保留了 `grep -q` 方式（因错误恢复路径的输出格式由运行时决定，黄金文件方式不适用）

### [x] 4. diff/migrate 子模块内联测试

**已完成：** 为三个 diff 子模块新增 Zig 内联测试：

- `diff_fields.zig`：10 个测试 — identical/added/dropped/modified/rename/ignore slot markers/typeInfoEqual 全变体覆盖/defaultValEqual
- `diff_indexes.zig`：8 个测试 — identical/added/dropped/modify(kind)/modify(field)/indexesEqual 各场景
- `diff_fks.zig`：8 个测试 — identical/added/dropped/changed(drop+add)/empty/bipartite-match/fksEqual 各场景

`migrate.zig` 的内联测试留到 Phase 2（因其依赖完整的 ResolvedAst 构建，需要更大的测试 harness）。

---

## P1 — 架构改进（中优先级）

### [x] 5. main.zig 职责拆分

**已完成：** 拆分为三个文件：

- `cli.zig`（~115 行）— 参数解析、帮助文本、Command/ParsedArgs 类型定义
- `compiler.zig`（~195 行）— compilePipeline()、handleCompile()、handleDiff()、handleMigrate()、handleReverse() 管线编排 + I/O helpers
- `main.zig`（~55 行）— 精简为入口点 + dispatch 路由

`compiler.zig` 可被其他工具（如 language server）直接 `@import` 调用，无需经过 CLI。

### [x] 6. Reverse Codegen 补充内联测试

**已完成：** 新增 15 个 Zig 内联测试：

- `isInlineIndex`：5 个测试 — uk_* 匹配、idx_* 匹配、多字段拒绝、名称不匹配拒绝、primary_key 拒绝
- `reverseCheck`：6 个测试 — BETWEEN、IN list、>= comparison、upper exclusive、lower exclusive、no match
- `classifyFk`：3 个测试 — shorthand single→id、full multi-field、full with actions
- `ReverseCodegen.generate`：1 个集成测试 — 基本 schema→TPS 生成

### [ ] 7. migrate.zig 补充内联测试

**未完成：** migrate.zig 依赖完整的 ResolvedAst + TypeResolver + Codegen 构建，内联测试需要大量 mock 数据构造。建议作为后续独立任务处理。

---

## P2 — 长期改进（低优先级）

### [ ] 8. Semantic Pass 依赖声明

**未完成。** 为 `SemanticPass` 添加 reads/writes 元数据，debug 模式下验证 pass 顺序。

### [ ] 9. Fuzzing 支持

**未完成。** 为 tokenizer/parser/sql_parser 添加 fuzz target。

### [ ] 10. FK ALTER TABLE 逆向解析

**未完成。** 解析 `ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` 并附加到 `SqlTable`。

### [ ] 11. 统一正向/逆向 IR（远期）

**未完成。** 设计共享 Schema IR，需大量重构，建议项目稳定后评估。

---

## P3 — 文档与 DX

### [ ] 12. 贡献者文档完善

**未完成。** 补充新 CLI 命令、黄金文件工作流、调试技巧。

### [ ] 13. 架构图更新

**未完成。** 更新 ARCHITECTURE.md / CLAUDE.md 的模块行数、依赖图可视化。

---

## 完成总结

| 项目 | 状态 | 新增测试数 |
|------|------|-----------|
| #1 sql_parser.zig 内联测试 | ✅ | 20 |
| #2 SQLite 黄金文件补强 | ✅ | +8 文件 (16→24) |
| #3 错误恢复测试扩充 | ✅ | +2 (3→5) |
| #4 diff 子模块内联测试 | ✅ | 26 |
| #5 main.zig 拆分 | ✅ | — |
| #6 reverse_codegen 测试 | ✅ | 15 |
| #7 migrate.zig 测试 | ❌ | — |
| #8-13 P2/P3 项目 | ❌ | — |
| **合计** | **6/13** | **+63 tests, +8 golden files** |

### 测试总计

| 测试套件 | 之前 | 之后 |
|----------|------|------|
| MySQL 黄金测试 | 82 | 82 |
| PostgreSQL 黄金测试 | 82 | 82 |
| SQLite 黄金测试 | 16 (全部失败) | **24 (全部通过)** |
| 错误恢复测试 | 3 | **5** |
| Zig 内联测试 | ~128 | **~191** (+63) |
| **总计** | **~309** | **~384** |

### 代码结构变化

| 文件 | 之前 | 之后 |
|------|------|------|
| main.zig | 401 行 | **55 行** |
| compiler.zig | — | **195 行** (新建) |
| cli.zig | — | **115 行** (新建) |
| sql_parser.zig | 1,257 行 (+0 tests) | **1,517 行 (+20 tests)** |
| diff_fields.zig | 260 行 (+0 tests) | **365 行 (+10 tests)** |
| diff_indexes.zig | 81 行 (+0 tests) | **145 行 (+8 tests)** |
| diff_fks.zig | 85 行 (+0 tests) | **165 行 (+8 tests)** |
| reverse_codegen.zig | 731 行 (+0 tests) | **881 行 (+15 tests)** |
