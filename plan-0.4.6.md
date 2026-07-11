# TypeSpec v0.4.6 升级计划

> 基于深度架构分析，聚焦可靠性、可维护性和可扩展性。

## Phase 1: P0 修复（可靠性）

| # | Item | 描述 | 预估 |
|---|------|------|------|
| P0-1 | 修复 TypedAst migrate corruption | `generateSingleTypedTable()` 在 migrate 路径生成 `0xaa` 单字节损坏；检查 `single_resolved` 的 ArrayList 和 `table` 切片生命周期，确认 arena 分配正确 | 中 |
| P0-2 | 统一 `compileToAst` 与 `handleCompile` | 提取 `compilePipeline(io, alloc, file_data) -> ResolvedAst` 公共函数，消除 `main.zig:282-302` 与 `handleCompile:239-279` 的重复解析逻辑 | 小 |

## Phase 2: P1 架构改进（可维护性）

| # | Item | 描述 | 预估 |
|---|------|------|------|
| P1-1 | 拆分 parser.zig | 从 1336 行的上帝文件中提取：`parse_field.zig`（fused type+modifier 解析）、`parse_fk.zig`（FK 声明解析）、`parse_check.zig`（CHECK 约束解析）、`parse_index.zig`（索引解析）。Parser 主文件只保留调度逻辑和表/模板/schema 解析 | 大 |
| P1-2 | Parser 单元测试 | 为 fused type+modifier 解析（`s128*`、`nu`、`++`、`n++`、`=0`）加 20+ 个 inline test；为 FK 解析（shorthand/standard/ultra）加 10+ 个；为 CHECK 解析加 10+ 个。目标：parser 关键路径有直接单元测试覆盖，不只靠 golden file 间接验证 | 中 |
| P1-3 | 统一错误处理路径 | `handleReverse` 内联的 40 行手写格式化（main.zig:323-367）改为使用 `DiagnosticCollector`；所有 handler 的 `process.exit(1)` 收敛到 main 层，handler 返回 error 由 main 决定退出方式 | 中 |

## Phase 3: P2 功能增强（表达力）

| # | Item | 描述 | 预估 |
|---|------|------|------|
| P2-1 | 逆向模板评分 | `findTemplates` 从纯贪心长度排序改为评分排序：`score = shared_tables * field_count * log2(field_count)`，优先提取跨更多表、覆盖更多字段的模板 | 小 |
| P2-2 | reverse golden file 扩展 | 新增：AUTO_INCREMENT 表、带 COMMENT ON 的 PG 表、SQLite 表（目前仅 1 个 SQLite 测试）的逆向测试用例 | 小 |

## Phase 4: P3 长期规划（不在此版本实施）

| # | Item | 描述 | 优先级 |
|---|------|------|--------|
| P3-1 | TypeInfo 表达力扩展 | `TypeInfo` 从枚举改为 tagged union + payload，支持复合类型（JSON/ARRAY）、带精度类型（`datetime(6)`）| 低 |
| P3-2 | LSP 集成 | 需增量解析、错误恢复、外部进程通信；先完成 P1-3 统一错误处理作为前置 | 低 |
| P3-3 | 视图/索引/存储过程 | 需扩展 AST、Parser、Semantic、Codegen 全链路，工作量大 | 低 |

---

## 实施优先级

```
P0-1 (migrate corruption) → P0-2 (消除重复) → P1-3 (统一错误处理)
                                                 ↓
                                          P1-1 (拆分 parser) → P1-2 (parser 测试)
                                                 ↓
                                          P2-1 (模板评分) + P2-2 (逆向测试扩展)
```

**关键路径**：P0-1 → P0-2 → P1-1 → P1-2，这是风险降低最大的顺序。
