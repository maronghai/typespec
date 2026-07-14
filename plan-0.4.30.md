# TypeSpec v0.4.30 Upgrade Plan

基于深度架构分析，按优先级分 5 个 Phase。

## [x] Phase 1: 统一 Dialect 枚举（~1h）

**问题**：`codegen.Dialect`(mysql, pg, sqlite) vs `sql_parser.Dialect`(mysql, postgresql, sqlite) 两套枚举，PG 名字不同，`compiler.zig:126` 隐式字符串转换。

**改动**：
1. `dialect_enum.zig` 定义全局 `Dialect` 枚举（`mysql`, `pg`, `sqlite`）
2. 删除 `codegen.zig` 和 `sql_parser.zig` 中各自的 `Dialect` 定义
3. 全项目 import 统一到 `dialect_enum.zig`
4. `compiler.zig:126` 的 `detectSqlDialect` 返回统一枚举
5. `cli.zig:117-122` `parseDialect` 返回统一枚举

**文件**：`dialect_enum.zig`, `codegen.zig`, `sql_parser.zig`, `compiler.zig`, `cli.zig`, `main.zig`, `reverse_codegen.zig`, `migrate.zig`

**验证**：`zig build test` + 全部 golden test 通过

---

## [x] Phase 2: sql_parser.zig 拆分（~3h）

**问题**：1,287 行单文件，占代码量 11%，方言判断散落为 if-else。

**拆分方案**：
```
sql_parser.zig          → 保留入口 + 共享 helper（~300 行）
sql_parser_common.zig   → 已有，不动（73 行）
sql_parser_create.zig   → parseCreateTable + parseColumn（~350 行）
sql_parser_alter.zig    → ALTER TABLE 解析（~150 行）
sql_parser_index.zig    → parseIndex/Unique/Fulltext/PrimaryKey（~120 行）
sql_parser_fk.zig       → parseForeignKey（~80 行）
sql_parser_test.zig     → 已有，保持
```

**关键**：
- `SqlParser` struct 保留在 `sql_parser.zig`，子模块接收 `*SqlParser` 参数
- 共享 helper（`peek`, `advance`, `skipSpaces`, `matchKeyword` 等）留在 base
- 方言判断未来可进一步提取为 vtable，本阶段先保持 if-else

**验证**：`sql_parser_test.zig` 25 个 test 全过 + reverse golden test 通过

---

## [x] Phase 3: 测试覆盖补全（~2h）

**问题**：migrate.zig（407 行）、template extraction（175 行）、diagnostic.zig（268 行）无单元测试。

### 3a. migrate.zig 单元测试（~30 个）
覆盖场景：
- MySQL RENAME（CHANGE COLUMN 语法）
- PG RENAME（RENAME COLUMN 语法）
- SQLite DROP COLUMN → warning comment
- SQLite MODIFY COLUMN → warning comment
- FK add/drop 三种方言
- Index add/drop 三种方言
- BEGIN/COMMIT 包裹
- 空 diff 输出

### 3b. reverse_codegen.zig 补充测试（~15 个）
覆盖场景：
- `findTemplates()` 基本模板发现
- `findBestWithNewFields()` 评分逻辑
- 单表/多表/无模板场景
- 模板继承关系检测
- 空 schema / 单表 schema

### 3c. diagnostic.zig 单元测试（~10 个）
覆盖场景：
- `DiagnosticCollector` push/record/hasErrors
- `formatJson()` 输出格式
- `formatTerminal()` 输出格式
- `tokenColumn()` 计算
- 严重级别过滤

**验证**：`zig build test` 通过，inline test 数量从 206 → ~260

---

## [x] Phase 4: Parser 错误处理优化（~1.5h）

### 4a. 提取 parser.zig 重复错误处理
7 个 `catch |err|` 块（parser.zig:102-339）结构完全相同，提取为：
```zig
fn handleParseError(self: *Parser, err: anyerror, line_no: usize, comptime msg: []const u8) void {
    if (self.diagnostics) |dc| {
        dc.record(.{ .line_no = line_no, .message = msg, .severity = .@"error" });
    }
}
```
调用处简化为一行。减少 ~50 行重复代码。

### 4b. 自定义类型循环引用检测
在 `typed_ast.zig:107-119` 的递归解析中加入 `visited` HashMap：
```zig
var visited = std.StringHashMap(void).init(alloc);
defer visited.deinit();
// 递归前检查 visited，递归时插入
```
防止 `~A B` + `~B A` 导致栈溢出。

### 4c. Pass Manager 环依赖检测
在 `semantic.zig:71-82` 的 debug 验证中加入 DFS 环检测，而非仅检查拓扑序。

**验证**：`zig build test` + golden test 通过；构造循环自定义类型 .tps 验证报错而非 crash

---

## [x] Phase 5: Diff 系统方言感知（~1h）

**问题**：`formatDiff()` 用 backtick 引号（MySQL 风格），PG/SQLite 应该用双引号。

**改动**：
1. `formatDiff()` / `printDiff()` 接收 `Dialect` 参数
2. 通过 `getBackend(dialect).quoteIdent()` 渲染表名/列名
3. 追加 `TableDiff` 的 engine/charset 变更检测（可选）
4. `compiler.zig:94-99` 的 `handleDiff` 将 dialect 传入 diff 层

**验证**：diff golden test 中补充 PG 双引号场景

---

## 优先级与依赖

```
Phase 1 (Dialect 统一)
  ↓
Phase 2 (sql_parser 拆分) ← 依赖 Phase 1 的统一枚举
  ↓
Phase 3 (测试补全) ← 依赖 Phase 2 的拆分完成
  ↓
Phase 4 (Parser 优化) ← 独立，可并行
  ↓
Phase 5 (Diff 方言) ← 依赖 Phase 1
```

Phase 4 可与 Phase 2/3 并行。总计预估 **~8.5h**。

---

## 风险项

| 风险 | 影响 | 缓解 |
|------|------|------|
| sql_parser 拆分引入回归 | 高 | 拆分后立即跑 25 个 sql_parser_test + reverse golden test |
| Dialect 枚举统一漏改引用 | 中 | `zig build test` 编译期即可发现 |
| migrate 单元测试需 mock DialectBackend | 低 | 复用 `dialect.zig` 现有 backend 实例 |
| template extraction 测试需构造复杂 schema | 中 | 从现有 127 个 .tps 文件中选取有多表模板的用例 |
