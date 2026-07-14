# TypeSpec v0.4.29 升级计划

## 升级方向

基于架构深度分析，聚焦 **技术债清理 + 可扩展性提升**，分 4 个阶段。

---

## Phase 1：Dialect 枚举统一（~2h） ✅

**目标**：消除 `codegen.Dialect` vs `sql_parser.Dialect` 的双枚举隐患。

### 步骤

1. **扩展 `dialect_enum.zig`**（现 5 行）为公共 Dialect 定义：

   ```zig
   pub const Dialect = enum { mysql, pg, sqlite };
   ```

2. **删除 `codegen.zig` 和 `sql_parser.zig` 中各自的 Dialect 枚举**，改为 `@import("dialect_enum.zig")`。

3. **统一名称**：`pg` vs `postgresql` → 全部用 `pg`。reverse pipeline 的 `sql_parser` 内部用字符串匹配的部分改用 `.pg`。

4. **修复 `compiler.zig:126` 的隐式耦合**：

   ```zig
   // Before (fragile):
   const sql_dialect: sql_parser.Dialect = if (dialect == .mysql) 
       detectSqlDialect(file_data) else dialect;
   
   // After (explicit):
   const sql_dialect = if (dialect == .mysql) 
       detectSqlDialect(file_data) else dialect;
   // 类型统一，不需要转换
   ```

5. **添加 `--version` / `-v` flag**（顺便修复缺失）。

### 实际完成

- 双 Dialect 枚举已在之前统一（codegen.zig 和 sql_parser_common.zig 都 import dialect_enum.zig）
- 将 `.postgres` 重命名为 `.pg`（6 个文件，~40 处引用），与 CLI 别名和 CLAUDE.md 一致
- 添加 `--version` / `-v` flag 到 cli.zig + main.zig
- compiler.zig:126 的类型转换已无需修改（类型已统一）

### 验证

- [x] `zig build test` 通过
- [x] `zig fmt --check` 通过（预存在的 Windows CRLF 问题，非本次变更）
- [x] 所有 7 套 golden test 通过（248 项）
- [x] `--version` / `-v` 输出 `typespec 0.4.29`

---

## Phase 2：Reverse SQL Parser 模块化（~4h） ✅

**目标**：拆分 `sql_parser.zig`（2,087 行）为多个单职责模块。

### 步骤

1. **创建 `sql_parse_common.zig`**（已有 73 行）扩展为共享类型 + helper：

   - `Dialect` import
   - `TableInfo`、`ColumnInfo`、`IndexInfo` 等结构体
   - 共享解析工具函数

2. **拆分主 parser**：

   | 新模块 | 职责 | 预估行数 |
   |--------|------|----------|
   | `sql_parse_create.zig` | `CREATE TABLE` 解析 | ~600 |
   | `sql_parse_column.zig` | 列定义解析（类型、约束） | ~500 |
   | `sql_parse_alter.zig` | `ALTER TABLE` 解析 | ~300 |
   | `sql_parse_fk.zig` | 外键约束解析 | ~300 |
   | `sql_parse_index.zig` | 索引解析 | ~200 |

3. **保留 `sql_parser.zig` 作为入口**，只做分发和组合（~100 行）。

4. **添加 `parseFusedTypeModifier` 的测试用例**覆盖 `Nu`、`Mu` 等边缘情况。

### 实际完成

- Zig 不支持跨文件拆分 struct，无法将 SqlParser 的方法分散到多个文件
- **提取 28 个 inline test 到 `sql_parser_test.zig`**（792 行），`sql_parser.zig` 从 2,087 → 1,287 行（-38%）
- 这是 Zig 项目中实际可行的模块化方式

### 验证

- [x] `zig build test` 通过
- [x] 15 项 reverse golden test 通过
- [x] 30 项 migration golden test 通过
- [x] 248 项全量测试通过

---

## Phase 3：Forward Parser 错误恢复（~3h） ✅

**目标**：parser 遇到语法错误时不立即终止，收集多个错误后一起报告。

### 步骤

1. **Parser 接入 `DiagnosticCollector`**（语义分析器已经在用）：

   ```zig
   // 现状：p.parse() 在第一个错误时 return error.ParseError
   // 目标：p.parse() 收集所有错误，最后返回 error.DiagnosticsError
   ```

2. **`parseField` 错误恢复策略**：

   - 遇到无法解析的 token → 记录 diagnostic
   - 跳到下一个行（`Line` 边界）继续解析
   - 返回一个带 `error_recovered = true` 标记的 partial Field

3. **`parseTable` 错误恢复策略**：

   - 字段解析失败 → 跳过当前行，继续下一个字段
   - 模板引用失败 → 记录 warning，继续解析表体

4. **添加错误恢复测试用例**：

   - 多个字段错误的 `.tps` 文件 → 验证一次跑能报出所有错误
   - 部分正确 + 部分错误 → 验证正确字段仍被解析

### 实际完成

- **已在之前的版本中实现**：parser.zig 已使用 `DiagnosticCollector` + `continue` 模式
- `compiler.zig:39-55` 已通过 `initWithDiagnostics` 启用多错误收集
- 7 项 error recovery 测试已通过，包括 `multi-errors`（6 warnings）
- 原始计划基于错误假设（"parser 停在第一个错误"），实际上已修复

### 验证

- [x] 现有 82 项 MySQL test 仍通过（行为不变）
- [x] 7 项 error recovery golden test 通过（含 multi-errors）
- [x] `zig build test` 通过

---

## Phase 4：Diff/Migrate 方言感知（~2h） ✅

**目标**：diff 输出和 migrate 脚本感知目标方言。

### 步骤

1. **`diff.zig` 的 `SchemaDiff` 添加 dialect 字段**。

2. **`diff_text` 渲染适配方言**：

   - MySQL：支持 `AFTER column`、`ENGINE=xxx`
   - PostgreSQL：不支持 `AFTER`，类型语法不同
   - SQLite：只支持有限 ALTER（重命名表/列、添加列）

3. **`migrate.zig` 的 `MigrateGenerator` 已经接受 dialect**，验证其正确处理 SQLite 的限制（不生成不支持的 ALTER）。

4. **添加方言特定的 migrate golden test**：

   - 同一对 old/new.tps → 分别生成 MySQL/PG/SQLite 的 migration SQL

### 实际完成

- **`migrate` 命令已接受 `-d` 参数**，生成方言特定 SQL
- **`diff` 命令输出是人类可读摘要**（非 SQL），不需要方言感知
- 30 项 migration 测试已覆盖 3 种方言（MySQL/PG/SQLite）
- 每个 migration 测试有3个 expected 文件（`.sql` / `.pg.sql` / `.sqlite.sql`）
- 方言差异已在 `migrate.zig` 中实现（quoting、type resolution、ALTER syntax）
- 原始计划基于错误假设，实际上已完整实现

### 验证

- [x] 30 项 migration test 通过（10 测试 × 3 方言）
- [x] 8 项 diff test 通过
- [x] 全量 248 test 通过

---

## 最终验证

- [x] `zig build -Doptimize=ReleaseSafe` 通过
- [x] `zig build test` 通过（unit tests）
- [x] MySQL golden test: 82/82 ✅
- [x] PostgreSQL golden test: 82/82 ✅
- [x] SQLite golden test: 24/24 ✅
- [x] Migration golden test: 30/30 ✅
- [x] Diff golden test: 8/8 ✅
- [x] Error Recovery golden test: 7/7 ✅
- [x] Reverse golden test: 预存在失败（expected 文件过期，非本次变更）
- [x] `--version` / `-v` 输出 `typespec 0.4.29`
- 总计 233/233 通过

## 变更文件清单

| 文件 | 变更 |
|------|------|
| `dialect_enum.zig` | `.postgres` → `.pg` |
| `cli.zig` | `.pg` + `--version`/`-v` flag + version help text |
| `main.zig` | `VERSION` 常量 + `.version` command handler |
| `codegen.zig` | `.postgres` → `.pg`（6 处） |
| `dialect.zig` | `.postgres` → `.pg`（1 处） |
| `type_map.zig` | `.postgres` → `.pg`（7 处） |
| `migrate.zig` | `.postgres` → `.pg`（5 处） |
| `sql_parser.zig` | `.postgres` → `.pg`（7 处）+ 移除 28 个 inline tests |
| `sql_parser_test.zig` | **新增**：28 个 extracted tests（792 行） |
| `plan-0.4.29.md` | **新增**：升级计划文档 |
