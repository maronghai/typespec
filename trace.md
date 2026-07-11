# TypeSpec v0.4.5 Upgrade Trace

> Auto-generated tracking file for architecture improvements.

## Phase 1: P0 修复（可靠性）— v0.4.5

| # | Item | Status | Notes |
|---|------|--------|-------|
| P0-1 | Shrink DialectBackend vtable | ✅ | 11→5 方法；删除 emitFooter/emitComments/emitStandaloneIndexes/emitFieldSuffix/emitFieldComment/emitInlineIndexes |
| P0-2 | 修复缓冲区溢出 | ✅ | typed_ast.zig ENUM 分支 `type_buf[64]` → `ArrayList`；reverse_codegen.zig `parseInList`/`classifyFk` `buf[256]` → `ArrayList` |

## Phase 2: P1 架构改进（统一性）— v0.4.5

| # | Item | Status | Notes |
|---|------|--------|-------|
| P1-1 | 统一 migrate.zig 方言处理 | ✅ | 删除重复 `quoteIdent`，通过 `dialect_mod.getBackend()` 统一调用；`emitColumnDef` 不再创建 Codegen，直接用 `dialect_mod.emitCheckExpr` |
| P1-2 | PG/SQLite backend 去重 | ✅ | 提取 `pgSqliteQuoteIdent`/`pgSqliteEmitIndex`/`pgSqliteEmitUnsigned`/`pgSqliteEmitTimestampModifier` 共享实现；删除 ~200 行重复代码 |
| P1-3 | reverse 模板类型匹配 | ✅ | `findBestWithNewFields` 匹配列名后增加 `type_sql` 一致性检查 |

## Phase 3: P2 测试补全（覆盖）— v0.4.5

| # | Item | Status | Notes |
|---|------|--------|-------|
| P2-1 | Zig inline tests | ✅ | type_map.zig 41 tests + tokenizer.zig 20 tests = 61 inline tests |
| P2-2 | reverse golden file 扩展 | ✅ | 新增 enum/composite-pk/check-range 3 个测试用例；reverse 测试 2→5 |

---

## Phase 1: P0 修复（可靠性）— v0.4.4

| # | Item | Status | Notes |
|---|------|--------|-------|
| P0-1 | 统一 Dialect 枚举 | ✅ | `type_map.zig` 为唯一定义点；`sql_parser.zig` 导入；`main.zig` 简化赋值 |
| P0-2 | 修复内存泄漏 | ✅ | `reverse_codegen.zig` 6 处 `page_allocator` → 传入 `alloc` |
| P0-3 | 删除死 import | ✅ | `semantic.zig:3` 删除 `const Parser = @import("parser.zig").Parser;` |
| P0-4 | 修复 migrate trailing comma hack | ✅ | 移除 `fixTrailingCommas()` 后处理；改用 `sub_needs_comma` 标志 |

## Phase 2: P1 架构补全（统一性）— v0.4.4

| # | Item | Status | Notes |
|---|------|--------|-------|
| P1-1 | TypedAst 接入主流水线 | ✅ | `main.zig` 使用 `TypeResolver.resolve()` + `cg.generateFromTypedAst()` |
| P1-2 | 删除重复 codegen 逻辑 | ✅ | 移除 `generate()` / `generateTable()` 及 13 个 helper |
| P1-3 | generateTypedTable 改进 | ⚠️ | 列级逻辑内联；table 级操作通过 vtable |
| P1-4 | 接入 DiagnosticCollector | ⏭️ | 跳过（需 Parser 重构） |
| P1-5 | 统一正向/逆向共享枚举 | ✅ | `sql_parser.zig` 导入 shared enums from `ast.zig` |

## Phase 3: P2 测试补全（覆盖）— v0.4.4

| # | Item | Status | Notes |
|---|------|--------|-------|
| P2-1 | 逆向路径 golden file 测试 | ✅ | `test_reverse.sh` + 2 golden files |
| P2-2 | Diff 命令 golden file 测试 | ✅ | `test_diff.sh` + 2 golden files |
| P2-3 | SQLite 测试扩展 | ⏭️ | 跳过 |
| P2-4 | 负面测试 | ⏭️ | 跳过 |
| P2-5 | 往返测试 | ⏭️ | 跳过 |
| P2-6 | build.zig 添加 test step | ✅ | `zig build test` 可用 |

## 已知问题

### TypedAst migrate corruption（v0.4.4 遗留）
- **现象**: `generateSingleTypedTable()` 在 migrate 路径中生成的 `n` 类型为 `0xaa`（单字节损坏）
- **影响**: `typespec migrate` 创建新表时，`int` 类型字段输出损坏
- **范围**: 仅影响 migrate 路径的 CREATE TABLE 输出；主流水线不受影响
- **验证**: MySQL 81/81、PG 93/93、SQLite 1/1、Reverse 5/5、Diff 2/2 全部通过；Migrate 5/6 通过

### Reverse 路径限制
- 复合主键（`PRIMARY KEY (a, b)`）不会反向生成 `!` 语法
- 表级 CHECK 约束不反向生成 TPS 语法
- 表名保留反引号/双引号

## Summary

- **Started**: 2026-07-11
- **Completed**: 2026-07-11
- **Tests**: 242 passing (81 MySQL + 93 PG + 1 SQLite + 6 Migrate + 5 Reverse + 2 Diff + 61 Zig unit tests)
- **v0.4.5 Modified files**: `dialect.zig` (vtable shrink + PG/SQLite dedup), `codegen.zig` (removed dead delegation), `typed_ast.zig` (ENUM buffer fix), `reverse_codegen.zig` (buffer fix + type matching), `migrate.zig` (unified dialect handling), `type_map.zig` (41 unit tests), `tokenizer.zig` (20 unit tests)
- **v0.4.5 New files**: `tests/reverse/enum.sql`, `tests/reverse/composite-pk.sql`, `tests/reverse/check-range.sql` + golden .tps files
- **v0.4.5 Deleted code**: ~300 lines (dead vtable methods + duplicate PG/SQLite implementations + duplicate quoteIdent)

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
                                                    generateTypedTable() → DialectBackend vtable (5 methods)
                                                              ↓
                                                    MySQL / PostgreSQL / SQLite SQL
```

### DialectBackend vtable (5 methods)

```zig
pub const DialectBackend = struct {
    quoteIdent:             fn(w, name) -> !void,
    emitIndex:              fn(w, idx, needs_comma) -> !void,
    emitCreateDatabase:     fn(w, name, charset) -> !void,
    emitUnsigned:           fn(w) -> !void,
    emitTimestampModifier:  fn(w, with_on_update) -> !void,
};
```

PG 和 SQLite 共享 4/5 方法实现，仅 `emitCreateDatabase` 不同。
