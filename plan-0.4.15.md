# TypeSpec v0.4.15 Architecture Upgrade Plan

> 基于深度架构分析，聚焦代码质量、健壮性与可维护性。延续 v0.4.14 未完成的重构工作，并针对架构分析发现的新问题进行修复。

## Current Status (v0.4.14)

- 18 源文件，~8,567 行 Zig，零外部依赖
- 3 条流水线：正向（TPS→SQL）、逆向（SQL→TPS）、Diff/Migrate
- 3 方言：MySQL、PostgreSQL、SQLite
- DialectBackend vtable 15 方法，codegen.zig 零方言引用
- ~298+ 测试（81 MySQL + 93 PG + 16 SQLite + 10 Migrate + 15 Reverse + 8 Diff + ~96 Zig unit tests）
- 架构成熟度评分：8/10（上版 7.5）

---

## Phase 1: sql_parser.zig 方言拆分（Priority: HIGH）

**问题**：`sql_parser.zig` 1,289 行，全项目最大单文件，三种方言的 DDL 解析逻辑混在同一文件中。修改 MySQL 路径可能误触 PostgreSQL/SQLite 逻辑。

**目标**：按方言拆分为独立模块，共享公共解析基础设施。

### 实现计划

1. 提取 `sql_parser_common.zig`（~200 行）
   - 共享类型定义：`SqlSchema`、`SqlTable`、`SqlColumn`、`SqlIndex`、`SqlFk`、`SqlCheck`
   - 共享工具函数：identifier 引用剥离（backtick/quote/double-quote）
   - `SqlParseResult` + `SqlDiagnostic` 定义
   - 公共解析状态结构（`alloc`、`src`、`pos`、`diagnostics`）

2. 提取 `sql_parser_mysql.zig`（~400 行）
   - MySQL 特有：backtick identifier、`CHARACTER SET`、`ENGINE=`、`COMMENT=`、`AUTO_INCREMENT`
   - `CREATE DATABASE ... CHARACTER SET`

3. 提取 `sql_parser_pg.zig`（~350 行）
   - PostgreSQL 特有：double-quote identifier、`GENERATED ALWAYS AS IDENTITY`、`COMMENT ON`
   - `CREATE DATABASE ... ENCODING`

4. 提取 `sql_parser_sqlite.zig`（~300 行）
   - SQLite 特有：无引号 identifier 风格、`AUTOINCREMENT`、类型亲和性推断

5. `sql_parser.zig` 瘦身为协调者（~80 行）
   - `parse()` 根据 dialect enum 分派到对应子模块
   - 保留公共接口 `SqlParseResult` 不变

### 文件变更

- 新增：`src/sql_parser_common.zig`、`src/sql_parser_mysql.zig`、`src/sql_parser_pg.zig`、`src/sql_parser_sqlite.zig`
- 修改：`src/sql_parser.zig`（瘦身为协调者）
- 不变：所有现有测试通过

### 模块依赖（更新后）

```
sql_parser.zig (coordinator, ~80 lines)
  ├─ sql_parser_common.zig (shared types + utilities, ~200 lines)
  ├─ sql_parser_mysql.zig (MySQL DDL parsing, ~400 lines)
  ├─ sql_parser_pg.zig (PostgreSQL DDL parsing, ~350 lines)
  └─ sql_parser_sqlite.zig (SQLite DDL parsing, ~300 lines)
```

---

## Phase 2: type_map.zig 职责分离（Priority: HIGH）

**问题**：`type_map.zig` 812 行同时承载类型映射、`Dialect` 枚举定义、SQLite 启发式逻辑。`Dialect` 被全部 18 个模块引用却定义在"类型映射"文件中，违反单一职责。

**目标**：将 `Dialect` 枚举提升为独立模块，SQLite 启发式逻辑分离。

### 实现计划

1. 提取 `dialect.zig` 重命名为 `dialect_backend.zig`，并将 `Dialect` 枚举独立
   - 当前 `dialect.zig` 已是 vtable 实现，`Dialect` 枚举却在 `type_map.zig` 中
   - 统一到一处：`dialect_backend.zig` 同时包含枚举和 vtable

2. 提取 `sqlite_hints.zig`（~80 行）
   - SQLite 列名启发式推断：`is_*` → boolean、`settings`/`metadata` → json
   - `isBooleanColumnName()`、`isJsonColumnName()`、`isTextColumnName()`
   - `isDatetimeSqlType()`、`isCurrentTimestamp()`

3. `type_map.zig` 瘦身
   - 仅保留 `TYPE_TABLE` 数组（50+ 条映射）、`toSqlType()`、`reverseLookup()`
   - import `dialect_backend.zig` 获取 `Dialect`
   - import `sqlite_hints.zig` 获取启发式函数

### 文件变更

- 新增：`src/sqlite_hints.zig`
- 修改：`src/dialect.zig`（导入 Dialect 枚举统一到此处，或从 type_map 移入）
- 修改：`src/type_map.zig`（移出 Dialect 定义和 SQLite 逻辑）
- 修改：所有 import `type_map.Dialect` 的模块（约 10 个文件的 import 路径调整）

---

## Phase 3: 错误处理统一化（Priority: MEDIUM）

**问题**：架构分析发现三处错误处理不一致：

1. `runValidate()`（semantic.zig:369-434）FK 引用检查通过 `std.debug.print` 直接输出，不返回 error，不走 DiagnosticCollector
2. `parseArgs()`（main.zig:58-149）中的错误也用 `std.debug.print` + `std.process.exit(1)`
3. 而 `diagnostic.zig` 已有完善的 `DiagnosticCollector` 系统（含 JSON 输出、终端格式化、错误计数）

**目标**：统一所有错误走结构化诊断路径。

### 实现计划

1. **runValidate() 接入 DiagnosticCollector**
   - `PassContext` 增加 `diagnostics: *DiagnosticCollector` 字段
   - FK 引用不存在 → `push Diagnostic{ .severity = .@"error", ... }`
   - 重复字段名 → `push Diagnostic{ .severity = .warning, ... }`
   - 验证结束后检查 `hasErrors()` 决定是否终止

2. **main.zig parseArgs() 统一**
   - `parseArgs` 返回 `error{DiagnosticError} || ParsedArgs`
   - 错误通过 DiagnosticCollector 收集，最后 `printAll()` + `exit(1)`
   - 消除散落的 `std.debug.print` + `std.process.exit(1)` 模式

3. **handleReverse() 已正确使用 DiagnosticCollector（保持不变）**

### 文件变更

- 修改：`src/semantic.zig`（`PassContext` 增加 diagnostics 字段）
- 修改：`src/main.zig`（`parseArgs` 改用 DiagnosticCollector）
- 修改：`src/main.zig`（`compilePipeline` 传递 diagnostics 到 SemanticAnalyzer）

---

## Phase 4: handleCompile trace 路径去重（Priority: MEDIUM）

**问题**：[main.zig:262-313](zig-typespec/src/main.zig) 中 `handleCompile` 的 trace 分支完整复制了 `compilePipeline` + TypeResolver + Codegen 的逻辑（约 40 行重复），只是在每步之间插入 `diagnosticTrace` 调用。

**目标**：消除代码重复，让非 trace 和 trace 路径共享同一流水线。

### 实现计划

1. 引入 `StageCallback` 类型：
   ```zig
   const StageCallback = ?*const fn (stage: u8) void;
   ```

2. 重构 `compilePipeline` 为带可选回调的版本：
   ```zig
   fn compilePipelineWithCallback(io, alloc, file_data, on_stage) !ResolvedAst
   ```
   每个阶段完成后调用 `on_stage(stage_id)` 以输出诊断 trace

3. `handleCompile` 的 trace 和非 trace 分支统一为一次调用
4. 消除 ~40 行重复代码

### 文件变更

- 修改：`src/main.zig`（`compilePipeline` 重构 + `handleCompile` 简化）

---

## Phase 5: 内存泄漏修复 — page_allocator（Priority: MEDIUM）

**问题**：[dialect.zig:354](zig-typespec/src/dialect.zig) 中 `pgSqliteEmitInlineColumnStandaloneIndex` 使用 `std.heap.page_allocator`：

```zig
try pgSqliteQuoteIdent(w, try std.fmt.allocPrint(std.heap.page_allocator, "idx_{s}_{s}", .{ table_name, col_name }));
```

`page_allocator` 每次分配至少 64KB，且在当前 arena 模式下不会被释放。在有大量 inline index 的表上会累积泄漏。

**目标**：消除 page_allocator 使用，改为 arena 分配或栈分配。

### 实现计划

1. **方案 A（推荐）**：直接 `w.print("idx_{s}_{s}", ...)` 逐段写入，避免中间字符串分配
2. **方案 B**：如果必须预格式化，使用 arena allocator（需传递到 vtable 方法）

### 文件变更

- 修改：`src/dialect.zig`（`pgSqliteEmitInlineColumnStandaloneIndex` 函数）

---

## Phase 6: 单元测试强化（Priority: MEDIUM）

**问题**：Golden file 测试覆盖了端到端路径，但以下边界情况缺乏细粒度单元测试：

1. 模板合并的 slot 边界（slot 在首/末/中间、同名字段类型冲突）
2. 递归模板继承的深度（3 层以上）
3. DialectBackend 各方法的 PG/SQLite 特殊行为

**目标**：为高风险模块追加 20+ 单元测试。

### 实现计划

1. **semantic.zig 模板测试**（8 项）
   - slot 在首位置的合并
   - slot 在末位置的合并
   - 父子同名字段类型冲突
   - 3 层递归继承
   - 多 mixin 同时应用
   - 空字段模板
   - 默认模板（无名模板）应用

2. **diff.zig 边界测试**（5 项）
   - 空 schema diff（两个空 schema）
   - 只有注释变更
   - 字段重命名 + 类型变更同时发生
   - 多表同时 drop + create
   - FK 变更（action 从 CASCADE 改为 SET NULL）

3. **codegen.zig 方言测试**（7 项）
   - SQLite AUTOINCREMENT 行为
   - PG GENERATED ALWAYS AS IDENTITY 行为
   - MySQL ENGINE/CHARACTER SET 输出
   - PG COMMENT ON TABLE/COLUMN 独立语句
   - SQLite `--` 注释风格
   - 检查表达式跨方言（BETWEEN、IN、comparison）

### 文件变更

- 修改：`src/semantic.zig`（追加 ~8 个 test block）
- 修改：`src/diff.zig`（追加 ~5 个 test block）
- 修改：`src/codegen.zig`（追加 ~7 个 test block）

---

## 实施顺序与工作量

| Phase | 优先级 | 工作量 | 来源 | 风险 |
|-------|--------|--------|------|------|
| 1: sql_parser 方言拆分 | HIGH | 2-3 天 | Deferred from v0.4.14 | Low |
| 2: type_map 职责分离 | HIGH | 1 天 | Deferred from v0.4.14 | Low |
| 3: 错误处理统一化 | MEDIUM | 1-2 天 | 架构分析新发现 | Medium |
| 4: handleCompile 去重 | MEDIUM | 0.5 天 | 架构分析新发现 | Low |
| 5: page_allocator 泄漏修复 | MEDIUM | 0.5 天 | 架构分析新发现 | Low |
| 6: 单元测试强化 | MEDIUM | 1-2 天 | 架构分析新发现 | Low |

**预估总工作量**：6-9 天

**实施顺序**：Phase 1 → 2（重构先行，避免返工）→ 5（快速修复）→ 4（小重构）→ 3（需谨慎）→ 6（收尾）

---

## 测试策略

每个 Phase 执行后：
1. 全部 298+ 现有测试必须通过（无回归）
2. `zig build test` 单元测试全绿
3. 新增测试按 Phase 计划追加

### 测试命令

```bash
# 端到端 golden file 测试
bash tests/test.sh           # MySQL (81)
bash tests/test_postgres.sh  # PostgreSQL (93)
bash tests/test_sqlite.sh    # SQLite (16)
bash tests/test_migrate.sh   # Migration (10)
bash tests/test_reverse.sh   # Reverse (15)
bash tests/test_diff.sh      # Diff (8)

# 单元测试
cd zig-typespec && zig build test
```

### 验证清单

Phase 1 完成后：
```bash
# 验证 sql_parser 拆分无回归
bash tests/test_reverse.sh   # 所有 15 项通过
bash tests/test.sh           # 所有 81 项通过
bash tests/test_postgres.sh  # 所有 93 项通过
bash tests/test_sqlite.sh    # 所有 16 项通过
```

Phase 3 完成后：
```bash
# 验证错误处理统一化
# 故意提交错误 FK 引用的 .tps，确认输出结构化诊断而非 raw debug.print
echo '# t\nid n++\nfoo_id n > nonexistent_table(id)' | ./zig-out/bin/typespec
# 预期：结构化 error 诊断 + non-zero exit code
```

---

## 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| sql_parser 拆分破坏解析逻辑 | Low | High | 保持公共接口不变；Phase 1 完成后运行全部 345 测试 |
| Dialect 枚举迁移影响所有 import | Low | Medium | Zig 编译器会 catch 所有引用错误；一次性修改 |
| 错误处理统一化改变退出行为 | Medium | Medium | 保持 exit code 语义不变（有 error → exit 1） |
| 模板合并单元测试覆盖不足 | Low | Medium | 先手动验证已知边界 case，再写测试固化 |

---

## 成功标准

- [ ] `sql_parser.zig` 从 1,289 行瘦身为 ~80 行协调者 + 4 个子模块
- [ ] `type_map.zig` 从 812 行瘦身（移出 ~100 行到 sqlite_hints.zig + Dialect 枚举）
- [ ] `codegen.zig` + `semantic.zig` + `main.zig` 中零 `std.debug.print` 错误输出（全走 DiagnosticCollector）
- [ ] `handleCompile` trace/非trace 路径合并，消除 ~40 行重复
- [ ] `pgSqliteEmitInlineColumnStandaloneIndex` 零 page_allocator 调用
- [ ] 新增 20+ 单元测试覆盖模板合并/diff/codegen 边界
- [ ] 全部 345+ 现有端到端测试通过（无回归）
- [ ] `zig build test` 单元测试全绿

---

## 架构目标：v0.4.15 后的模块依赖图

```
main.zig (entry, CLI, orchestration)
├─ tokenizer.zig (line classification + tokenization)
├─ parser.zig (token → AST)
│  ├─ parse_field.zig (field declarations)
│  ├─ parse_fk.zig (foreign keys)
│  ├─ parse_check.zig (CHECK constraints)
│  └─ parse_index.zig (indexes + composite PK)
├─ semantic.zig (template resolution + passes)
├─ typed_ast.zig (type resolver: abstract → concrete SQL types)
├─ codegen.zig (dialect-agnostic SQL generation)
├─ dialect.zig (DialectBackend vtable + 3 backends)
├─ type_map.zig (TYPE_TABLE + forward/reverse mapping)
├─ sqlite_hints.zig (SQLite heuristic inference)
├─ diff.zig (AST-level schema comparison)
├─ migrate.zig (ALTER TABLE generation)
├─ sql_parser.zig (coordinator)
│  ├─ sql_parser_common.zig (shared types)
│  ├─ sql_parser_mysql.zig (MySQL DDL)
│  ├─ sql_parser_pg.zig (PostgreSQL DDL)
│  └─ sql_parser_sqlite.zig (SQLite DDL)
├─ reverse_codegen.zig (SQL → TPS conversion)
└─ diagnostic.zig (structured diagnostics, zero dependency)
```

零循环依赖，所有叶子模块（ast.zig、diagnostic.zig、sqlite_hints.zig）无内部依赖。
