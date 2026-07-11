# TypeSpec v0.4.4 Architecture Improvement Plan

> 基于深度架构分析，修复技术债、补全未完成的抽象、改善测试覆盖。

---

## Phase 1: P0 修复（可靠性）

| # | Item | Description | Risk |
|---|------|-------------|------|
| P0-1 | 统一 Dialect 枚举 | `type_map.zig` 为唯一定义点；删除 `sql_parser.zig:5` 的重复定义；`codegen.zig:16` 不再需要 re-export；`main.zig:317-321` 手动映射消除 | Low |
| P0-2 | 修复内存泄漏 | `reverse_codegen.zig` 6 处 `page_allocator` → 传入的 `alloc` 参数（第 243/277/329/461/479/496 行） | Low |
| P0-3 | 删除死 import | `semantic.zig:3` 删除 `const Parser = @import("parser.zig").Parser;` | Low |
| P0-4 | 修复 migrate trailing comma hack | `migrate.zig` 的 `fixTrailingCommas()` 字符串后处理 → 在 codegen 层正确处理最后一列不加逗号 | Medium |

---

## Phase 2: P1 架构补全（统一性）

| # | Item | Description | Risk |
|---|------|-------------|------|
| P1-1 | TypedAst 接入主流水线 | `main.zig` 的 `handleCompile` 从 `cg.generate(resolved)` 改为 `TypeResolver.resolve(resolved, dialect)` + `cg.generateFromTypedAst(typed)` | Medium |
| P1-2 | 删除重复 codegen 逻辑 | `codegen.zig` 中删除旧路径 `generate()` / `generateTable()`（~150 行），保留 `generateFromTypedAst()` / `generateTypedTable()` 作为唯一路径 | Medium |
| P1-3 | generateTypedTable 使用 vtable | `codegen.zig:359-408` 中 inline switch 替换为 `self.backend.*()` 调用 | Medium |
| P1-4 | 接入 DiagnosticCollector | Parser 改为收集错误到 DiagnosticCollector 而非直接 print；reverse 路径同理 | Medium |
| P1-5 | 统一正向/逆向共享枚举 | `IndexKind`、`FkActionType`、`FkActionTrigger` 从 `ast.zig` 导出复用，`sql_parser.zig` 不再重复定义 | Low |

---

## Phase 3: P2 测试补全（覆盖）

| # | Item | Description | Risk |
|---|------|-------------|------|
| P2-1 | 逆向路径 golden file 测试 | 为 `typespec reverse` 添加 `test_reverse.sh`，至少覆盖：基础 CREATE TABLE、带 FK、带 INDEX、多表、PG 方言 | Low |
| P2-2 | Diff 命令 golden file 测试 | 为 `typespec diff` 添加 `test_diff.sh`，至少覆盖：无变化、加列、加表、删表、改列 | Low |
| P2-3 | SQLite 测试扩展 | 现有 1 个 SQLite 测试 → 至少 10 个（覆盖 types、FK、index、template、enum） | Low |
| P2-4 | 负面测试 | 添加错误输入测试：空字段、循环模板继承、未知类型符号、FK 引用不存在的表 | Low |
| P2-5 | 往返测试 | `tps → compile → sql → reverse → tps' → compile → sql'`，验证 `sql == sql'` | Low |
| P2-6 | build.zig 添加 test step | 添加 `b.addTest()` 使 `zig build test` 可用 | Low |

---

## Phase 4: P3 基础设施（可选）

| # | Item | Description | Risk |
|---|------|-------------|------|
| P3-1 | CI pipeline | GitHub Actions: build + test (MySQL/PG/SQLite/Migrate/Reverse/Diff) | Low |
| P3-2 | 性能基准 | 编译 100+ 表 .tps 的基准时间，防止性能退化 | Low |
| P3-3 | 插件接口（探索） | 如果未来需要用户自定义 pass 或方言，设计 `Plugin` trait | High |

---

## 依赖关系

```
P0-1 ──┐
P0-2 ──┤
P0-3 ──┼── P1-1 ── P1-2 ── P1-3
P0-4 ──┘         │
                 ├── P1-4
                 └── P1-5
                       │
                       ▼
              P2-1 ~ P2-6（可并行）
                       │
                       ▼
              P3-1 ~ P3-3（可并行）
```

---

## 预期收益

| 指标 | 当前 | 目标 |
|------|------|------|
| Dialect 定义点 | 3 处 | 1 处 |
| page_allocator 泄漏 | 6 处 | 0 处 |
| TypedAst IR 使用率 | 0% | 100%（主流水线） |
| codegen 路径数 | 2（重复） | 1（唯一） |
| 逆向路径测试 | 0 | ≥5 golden file |
| Diff 测试 | 0 | ≥5 golden file |
| SQLite 测试 | 1 | ≥10 |
| 总测试数 | ~169 | ~200+ |
| 内联 Zig test | 0 | >0（关键模块） |

---

## 开始日期

2026-07-11
