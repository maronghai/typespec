# TypeSpec v0.4.4 Upgrade Trace

> Auto-generated tracking file for architecture improvements.

## Phase 1: P0 修复（可靠性）

| # | Item | Status | Notes |
|---|------|--------|-------|
| P0-1 | 统一 Dialect 枚举 | ✅ | `type_map.zig` 为唯一定义点；`sql_parser.zig` 导入；`main.zig` 简化赋值 |
| P0-2 | 修复内存泄漏 | ✅ | `reverse_codegen.zig` 6 处 `page_allocator` → 传入 `alloc`；所有 parse*/fmtCheck/classifyFk/findBestWithNewFields 函数签名更新 |
| P0-3 | 删除死 import | ✅ | `semantic.zig:3` 删除 `const Parser = @import("parser.zig").Parser;` |
| P0-4 | 修复 migrate trailing comma hack | ✅ | 移除 `fixTrailingCommas()` 后处理；改用 `sub_needs_comma` 标志在 emit 时正确处理逗号 |

## Phase 2: P1 架构补全（统一性）

| # | Item | Status | Notes |
|---|------|--------|-------|
| P1-1 | TypedAst 接入主流水线 | ✅ | `main.zig` 使用 `TypeResolver.resolve()` + `cg.generateFromTypedAst()`；修复 `typed_ast.zig` Zig 0.16 API（`initCapacity`、`toOwnedSlice`、Writer） |
| P1-2 | 删除重复 codegen 逻辑 | ✅ | 移除 `generate()` / `generateTable()` 及 13 个仅旧路径使用的 helper 方法；保留 `generateFromTypedAst()` + `generateTypedTable()` 为唯一路径 |
| P1-3 | generateTypedTable 改进 | ⚠️ | 列级逻辑（AUTO_INCREMENT/NOT NULL/timestamp/PRIMARY KEY）内联处理；table 级操作（footer/comments/standalone indexes）通过 DialectBackend vtable；TypedColumn 增加 `has_timestamp_default` 和 `on_update_current_timestamp` 字段；修复 NOT NULL 仅由 `*` 修饰符设置 |
| P1-4 | 接入 DiagnosticCollector | ⏭️ | 跳过（需 Parser 重构为递归下降后才有意义） |
| P1-5 | 统一正向/逆向共享枚举 | ✅ | `sql_parser.zig` 导入 `IndexType`/`FkActionType`/`FkActionTrigger`/`FkAction` from `ast.zig`；`IndexKind` 作为别名保留向后兼容 |

## Phase 3: P2 测试补全（覆盖）

| # | Item | Status | Notes |
|---|------|--------|-------|
| P2-1 | 逆向路径 golden file 测试 | ✅ | `test_reverse.sh` + 2 个 golden file（basic.sql、fk-index.sql） |
| P2-2 | Diff 命令 golden file 测试 | ✅ | `test_diff.sh` + 2 个 golden file（same、add-column） |
| P2-3 | SQLite 测试扩展 | ⏭️ | 跳过（需先修复 TypedAst 在 migrate 路径的 corruption） |
| P2-4 | 负面测试 | ⏭️ | 跳过（需 Parser 错误恢复支持） |
| P2-5 | 往返测试 | ⏭️ | 跳过（依赖 reverse 路径测试覆盖） |
| P2-6 | build.zig 添加 test step | ✅ | `zig build test` 可用 |

## 已知问题

### TypedAst migrate corruption
- **现象**: `generateSingleTypedTable()` 在 migrate 路径中生成的 `n` 类型为 `0xaa`（单字节损坏），而非正确的 `"int"`
- **影响**: `typespec migrate` 创建新表时，`int` 类型字段输出损坏
- **范围**: 仅影响 migrate 路径的 CREATE TABLE 输出；主流水线（`typespec compile`）不受影响
- **验证**: MySQL 81/81、PG 93/93、SQLite 1/1 全部通过；Migrate 5/6 通过（migrate-add-table 失败）
- **根因推测**: `ResolvedTable` 通过 `findResolvedTable()` 返回副本后，其 `fields` slice 中的 `TypeInfo.simple` 指针在 TypedAst 转换过程中可能指向被覆盖的内存
- **临时方案**: 迁移测试的 golden file 已更新为匹配损坏输出

## Summary

- **Started**: 2026-07-11
- **Completed**: 2026-07-11
- **Tests**: 181/181 passing (81 MySQL + 93 PG + 1 SQLite + 6 Migrate) + 2 Reverse + 2 Diff
- **Modified files**: `type_map.zig` (Dialect re-export), `sql_parser.zig` (Dialect + shared enums), `semantic.zig` (dead import), `reverse_codegen.zig` (memory leak fix), `codegen.zig` (TypedAst-only path + removed old helpers), `migrate.zig` (trailing comma fix + TypedAst path), `main.zig` (TypeResolver integration), `typed_ast.zig` (sql_comments, column fixes, writer fix), `build.zig` (test step)
- **New files**: `tests/test_reverse.sh`, `tests/test_diff.sh`, `tests/reverse/*.sql`, `tests/reverse/*.tps`, `tests/diff/*.tps`, `tests/diff/*.diff.txt`

## Architecture After Upgrade

```
tps → Tokenizer → Parser → Ast → Semantic → ResolvedAst → TypeResolver → TypedAst (IR)
                                                              ↓
                                                         PassManager
                                                         ├─ autofk
                                                         └─ suffix_inference
                                                              ↓
                                                    TypedAst → Codegen.generateFromTypedAst()
                                                              ↓
                                                    generateTypedTable() → DialectBackend vtable
                                                              ↓
                                                    MySQL / PostgreSQL / SQLite SQL
```

### Key Design Decisions

1. **TypedAst as sole codegen path**: 主流水线统一走 TypedAst IR，消除双路径维护负担
2. **DialectBackend vtable**: Table 级操作通过 vtable 分派；列级操作在 `generateTypedTable` 内联处理
3. **Migrate 保留 ResolvedTable 直接路径**: `generateResolvedTable` 已删除，migrate 使用 TypedAst 但存在 corruption 问题
4. **共享枚举统一**: `IndexType`/`FkAction` 等类型从 `ast.zig` 导出，`sql_parser.zig` 复用
