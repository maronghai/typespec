# TypeSpec v0.4.7 Upgrade Plan

> 基于架构深度分析，聚焦可维护性、可测试性、错误处理三个维度。

---

## P0: 可靠性（Reliability）

| # | Item | Files | Effort | Description |
|---|------|-------|--------|-------------|
| P0-1 | Parser 注入 DiagnosticCollector | `parser.zig`, `main.zig` | 中 | 正向编译路径支持多错误上报；错误时 panic recovery 收集诊断，返回部分 AST + 所有诊断；取代当前的单错误终止模式 |
| P0-2 | migrate.zig 列定义复用 Codegen | `migrate.zig`, `codegen.zig`, `dialect.zig` | 中 | 将 `emitColumnDef` 提取为 Codegen 的公共方法，migrate 通过 Codegen 实例复用；消除 migrate 中的方言 switch 重复 |

## P1: 架构改进（Maintainability）

| # | Item | Files | Effort | Description |
|---|------|-------|--------|-------------|
| P1-1 | TypeInfo tagged union 精简 | `ast.zig`, `type_map.zig`, `typed_ast.zig`, `parser.zig`, `sql_parser.zig`, `reverse_codegen.zig` | 高 | 将 `int_explicit` / `decimal_explicit` / `varchar_explicit` 合并为 `parameterized { spec: []const u8, display_width: ?u32, precision: ?u32, scale: ?u32 }`，减少 6→4 变体；或保留当前结构但提取公共 `ParamInfo` struct |
| P1-2 | sql_parser.zig 字符扫描提取 | `sql_parser.zig`, `sql_scanner.zig` | 中 | 提取 `skipWhitespace` / `parseIdentifier` / `readQuoted` / `parseNumber` 等通用扫描器到独立模块；sql_parser.zig 通过 import 复用 |
| P1-3 | reverse_codegen.zig 模板提取限制 | `reverse_codegen.zig` | 低 | 当前最大 5 个模板是硬编码；改为根据 schema 规模动态计算上限（如 `min(5, table_count / 3)`） |

## P2: 可测试性（Testability）

| # | Item | Files | Effort | Description |
|---|------|-------|--------|-------------|
| P2-1 | diff.zig 单元测试 | `diff.zig` | 低 | 构造小 ResolvedAst → 调用 diff() → 断言 SchemaDiff 内容；覆盖：新增表、删除表、重命名字段、修改类型、新增索引 |
| P2-2 | semantic.zig 单元测试 | `semantic.zig` | 低 | 模板解析 + 后缀推断的独立测试；覆盖：单继承、多继承、循环检测、`_id` / `_at` / `_on` 推断 |
| P2-3 | codegen.zig 单元测试 | `codegen.zig` | 中 | 构造 TypedAst → 调用 generateFromTypedAst() → 断言 SQL 输出；覆盖：三种方言的 CREATE TABLE、INDEX、FK、CHECK |
| P2-4 | migrate golden file 扩展 | `tests/` | 低 | 新增：rename column、add/drop index、add/drop FK、SQLite 限制警告 |

## P3: 文档（Documentation）

| # | Item | Files | Effort | Description |
|---|------|-------|--------|-------------|
| P3-1 | 内部架构图 | `zig-typespec/ARCHITECTURE.md` | 低 | ASCII 模块依赖图 + 数据流图 + IR 说明；面向贡献者 |
| P3-2 | 贡献指南 | `CONTRIBUTING.md` | 低 | 构建、测试、新方言扩展步骤、代码风格约定 |

---

## Effort Estimate

| Phase | Items | Days |
|-------|-------|------|
| P0 | P0-1 + P0-2 | 2-3 |
| P1 | P1-1 + P1-2 + P1-3 | 2-3 |
| P2 | P2-1 + P2-2 + P2-3 + P2-4 | 1-2 |
| P3 | P3-1 + P3-2 | 0.5 |
| **Total** | | **5.5-8.5** |

## Risk Assessment

| Item | Risk | Mitigation |
|------|------|------------|
| P0-1 | Parser panic recovery 可能遗漏边界 case | 先写覆盖所有已知语法的 golden file，再重构 |
| P1-1 | TypeInfo 变更影响面广（6 个文件） | 保持向后兼容：旧变体作为别名保留 1 个版本 |
| P1-2 | sql_parser 重构可能引入回归 | 先补 sql_parser 单元测试，再重构 |
| P2-3 | Codegen 单元测试需构造 TypedAst | 复用 migrate 测试的辅助函数 |

## Not In Scope (v0.4.7)

- 新增 SQL 方言（ClickHouse、DuckDB 等）— 等 vtable 验证充分后再扩展
- 库化（将编译流水线暴露为 Zig 库）— 需要更稳定的公共 API 设计
- SQL VIEW / TRIGGER 支持 — 需要 sql_parser 大幅重构
- 前端语法扩展（循环/条件）— 超出 DSL 范围
