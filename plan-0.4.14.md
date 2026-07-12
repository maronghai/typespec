# TypeSpec v0.4.14 Architecture Upgrade Plan

> 基于深度架构分析，针对最高影响力的改进项，同时保留现有流水线设计。

## Current Status (v0.4.13)

- 14 源文件（parser 拆分已回滚，4 个 parse_*.zig 已删除），~8,469 行 Zig
- 3 条流水线：正向（TPS→SQL）、逆向（SQL→TPS）、Diff/Migrate
- 3 方言：MySQL、PostgreSQL、SQLite
- DialectBackend vtable 14 方法，codegen.zig 零方言引用
- ~298 项测试
- 架构成熟度评分：7.5/10

---

## Phase 1: sql_parser.zig 方言拆分（Priority: HIGH）

**问题**：`sql_parser.zig` 1,289 行，全项目最大单文件，三种方言的 DDL 解析逻辑混在同一文件中，修改 MySQL 路径可能误触 PostgreSQL。

**目标**：按方言拆分为独立模块，共享公共解析基础设施。

### 实现计划

1. 提取 `sql_parser_common.zig`（~200 行）
   - 共享类型定义：`SqlSchema`、`SqlTable`、`SqlColumn`、`SqlIndex`、`SqlFk`、`SqlCheck`
   - 共享工具函数：identifier 引用剥离（backtick/quote/double-quote）
   - `SqlParseResult` + `DiagnosticCollector` 集成

2. 提取 `sql_parser_mysql.zig`（~400 行）
   - MySQL 特有：backtick identifier、`CHARACTER SET`、`ENGINE=`、`COMMENT=`、`AUTO_INCREMENT`
   - `CREATE DATABASE ... CHARACTER SET`

3. 提取 `sql_parser_pg.zig`（~350 行）
   - PostgreSQL 特有：double-quote identifier、`GENERATED ALWAYS AS IDENTITY`、`COMMENT ON`
   - `CREATE DATABASE ... ENCODING`

4. 提取 `sql_parser_sqlite.zig`（~300 行）
   - SQLite 特有：无引号 identifier、`--` 注释风格、`AUTOINCREMENT`、类型亲和性

5. `sql_parser.zig` 瘦身为协调者（~100 行）
   - `parse()` 根据 dialect enum 分派到对应子模块
   - 保留公共接口不变

### 文件变更

- 新增：`src/sql_parser_common.zig`、`src/sql_parser_mysql.zig`、`src/sql_parser_pg.zig`、`src/sql_parser_sqlite.zig`
- 修改：`src/sql_parser.zig`（瘦身为协调者）
- 修改：`src/main.zig`（import 路径调整）
- 不变：所有 298+ 测试通过

### 模块依赖（更新后）

```
sql_parser.zig (coordinator, ~100 lines)
  ├─ sql_parser_common.zig (shared types + utilities)
  ├─ sql_parser_mysql.zig (MySQL DDL parsing)
  ├─ sql_parser_pg.zig (PostgreSQL DDL parsing)
  └─ sql_parser_sqlite.zig (SQLite DDL parsing)
```

---

## Phase 2: SQLite 测试补全（Priority: HIGH）

**问题**：SQLite 仅 1 项 golden test，而 `sql_parser.zig` 中有大量 SQLite 特殊处理逻辑几乎无测试覆盖。

**目标**：追加 15+ SQLite golden tests，覆盖所有 SQLite 特有行为。

### 实现计划

1. **类型亲和性测试**（6 项）
   - `INTEGER PRIMARY KEY` vs `AUTOINCREMENT`
   - `datetime` → `TEXT DEFAULT (datetime('now'))`
   - `json` → `TEXT` + CHECK 约束
   - `DECIMAL` → `REAL`（SQLite 无 DECIMAL）
   - `boolean` → `INTEGER`（0/1）
   - `blob` → `BLOB`

2. **DDL 结构测试**（5 项）
   - 复合 `PRIMARY KEY`（无 autoincrement）
   - `CREATE INDEX` standalone（非 inline）
   - `UNIQUE INDEX` standalone
   - `--` 注释风格
   - 无 `ENGINE`/`CHARACTER SET`

3. **边界情况测试**（4 项）
   - 空表（仅 PK）
   - 多 FK 同列
   - CHECK 约束 + UNIQUE 组合
   - 模板继承 → SQLite 输出

### 文件变更

- 新增：`tests/*.sqlite.tps`（15+ 测试输入）
- 新增：`tests/expected/*.sqlite.sql`（15+ golden 文件）
- 修改：`tests/test_sqlite.sh`（从 1 项扩展到 15+ 项）

---

## Phase 3: type_map.zig 职责分离（Priority: MEDIUM）

**问题**：`type_map.zig` 812 行同时承载类型映射、方言枚举、SQLite 启发式逻辑，`Dialect` 枚举被所有模块引用却定义在"类型映射"文件中。

**目标**：将 `Dialect` 枚举和 SQLite 启发式逻辑分离到独立模块。

### 实现计划

1. 提取 `dialect_enum.zig`（~20 行）
   - `pub const Dialect = enum { mysql, postgres, sqlite }`
   - 被所有模块引用的公共定义

2. 提取 `sqlite_hint.zig`（~80 行）
   - SQLite 列名启发式推断逻辑
   - `_id` → int、`is_*` → boolean、`settings`/`metadata` → json

3. `type_map.zig` 瘦身
   - 仅保留 `TYPE_TABLE` 数组、`toSqlType()`、`reverseLookup()`
   - import `dialect_enum.zig` 获取 `Dialect`
   - import `sqlite_hint.zig` 获取启发式函数

### 文件变更

- 新增：`src/dialect_enum.zig`、`src/sqlite_hint.zig`
- 修改：`src/type_map.zig`（移出 Dialect 和 SQLite 逻辑）
- 修改：所有 import `Dialect` 的模块（import 路径调整）

---

## Phase 4: DialectBackend vtable 扩展到 14 方法（Priority: MEDIUM）

**问题**：v0.4.8 已从 5 扩展到 11 方法，但仍有部分方言差异留在 codegen.zig 中（如 `emitCheckExpr`、`emitEnumType`）。

**目标**：将所有方言差异彻底隔离到 vtable，codegen.zig 实现 100% 方言无关。

### 实现计划

1. 扫描 `codegen.zig` 中残留的 `switch(self.dialect)` 或方言条件分支
2. 将剩余方言差异提取为 vtable 方法：
   - `emitCheckExpr`（CHECK 约束表达式）
   - `emitEnumType`（MySQL native ENUM vs PG/SQLite CHECK）
   - `emitColumnDefault`（默认值渲染差异）
3. 验证 `codegen.zig` 零方言引用（grep 确认）

### 文件变更

- 修改：`src/dialect.zig`（vtable 新增方法）
- 修改：`src/codegen.zig`（替换残留 switch 为 vtable 调用）
- 修改：`src/dialect.zig`（3 个 backend 实现新方法）

---

## Phase 5: Diff/Migrate 测试扩展（Priority: MEDIUM）

**问题**：Diff 仅 2 项测试，Migrate 仅 9 项测试，覆盖不足。

**目标**：追加 10+ Diff 测试和 5+ Migrate 测试。

### 实现计划

1. **Diff 测试**（10 项）
   - 字段类型变更检测
   - 索引新增/删除/修改
   - FK 新增/删除
   - 表重命名检测
   - 模板变更传播
   - 空 diff（无变更）
   - 多表同时变更
   - CHECK 约束变更
   - 注释变更
   - 复合 PK 变更

2. **Migrate 测试**（5 项）
   - 多列同时 ALTER TABLE
   - SQLite 限制警告输出
   - PG RENAME COLUMN vs MySQL CHANGE COLUMN
   - 新增索引 + 删除索引组合
   - 新增 FK + 删除 FK 组合

### 文件变更

- 新增：`tests/diff/*.tps`（10 组 old/new 配对）
- 新增：`tests/expected/*.diff.txt`（10 golden diff 输出）
- 新增：`tests/migrate-*-old.tps` + `migrate-*-new.tps`（5 组）
- 新增：`tests/expected/migrate-*.sql`（5 golden SQL）
- 修改：`tests/test_diff.sh`、`tests/test_migrate.sh`

---

## Phase 6: 逆向工程测试扩展（Priority: MEDIUM）

**问题**：Reverse 仅 8 项测试，且三种方言覆盖不均。

**目标**：追加 8+ Reverse 测试，平衡方言覆盖。

### 实现计划

1. MySQL 特有 reverse 测试（3 项）
   - backtick identifier → TPS
   - `AUTO_INCREMENT` → `++`
   - `ENGINE=InnoDB` → `^engine(innodb)`

2. PostgreSQL 特有 reverse 测试（3 项）
   - `GENERATED ALWAYS AS IDENTITY` → `++`
   - `COMMENT ON TABLE/COLUMN` → 表/列注释
   - `CREATE INDEX` → `@index`

3. SQLite 特有 reverse 测试（2 项）
   - `INTEGER PRIMARY KEY AUTOINCREMENT` → `++`
   - `--` 注释 → `;` 注释

### 文件变更

- 新增：`tests/reverse/*.sql` + `*.mysql.tps` + `*.pg.tps` + `*.sqlite.tps`（8 组）
- 修改：`tests/test_reverse.sh`

---

## 实施顺序与工作量

| Phase | 优先级 | 工作量 | 状态 | 风险 |
|-------|--------|--------|------|------|
| 1: sql_parser 方言拆分 | HIGH | 2-3 天 | DEFERRED→v0.4.15 | Low |
| 2: SQLite 测试补全 | HIGH | 1 天 | ✅ DONE | Low |
| 3: type_map 职责分离 | MEDIUM | 1 天 | DEFERRED→v0.4.15 | Low |
| 4: DialectBackend 15 方法 | MEDIUM | 1 天 | ✅ DONE | Low |
| 5: Diff/Migrate 测试扩展 | MEDIUM | 1-2 天 | ✅ DONE | Low |
| 6: Reverse 测试扩展 | MEDIUM | 0.5 天 | ✅ DONE | Low |

**v0.4.14 实际范围**：Phase 2 + Phase 4 + Phase 5 + Phase 6 + diff stdout bug fix
**Deferred to v0.4.15**：Phase 1（sql_parser 方言拆分）+ Phase 3（type_map Dialect 提取）

---

## 测试策略

每个 Phase 执行后：
1. 全部 298+ 现有测试必须通过（无回归）
2. 新增测试按 Phase 计划追加
3. `zig build test` 单元测试全绿

### 测试命令

```bash
# 全量测试
bash tests/test.sh           # MySQL (81+)
bash tests/test_postgres.sh  # PostgreSQL (93+)
bash tests/test_sqlite.sh    # SQLite (15+)
bash tests/test_migrate.sh   # Migration (9+)
bash tests/test_reverse.sh   # Reverse (8+)
bash tests/test_diff.sh      # Diff (2+)

# 单元测试
cd zig-typespec && zig build test
```

---

## 风险评估

| 风险 | 缓解措施 |
|------|---------|
| sql_parser 拆分破坏解析逻辑 | Phase 1 完成后运行全部 298+ 测试；保持公共接口不变 |
| type_map 拆分影响所有 import | Zig 编译时检查 catch 所有引用错误；一次性修改所有 import |
| SQLite 测试 golden 文件不准 | 逐项验证 SQLite 官方文档行为；先手动运行确认输出 |
| vtable 扩展遗漏方法 | grep 验证 codegen.zig 零方言引用 |

---

## 成功标准

- [x] SQLite 测试从 1 项扩展到 16 项
- [x] codegen.zig 实现 100% 方言无关（vtable 覆盖所有差异，grep 零命中）
- [x] 全部 223+ 测试通过（原 194 + 新增 29）
- [x] 无行为变更（所有现有 golden 文件不变）
- [x] diff.zig: formatDiff() 输出到 stdout（修复 stderr bug）
- [ ] sql_parser.zig 从 1,289 行瘦身为 ~100 行协调者（DEFERRED→v0.4.15）
- [ ] 4 个新方言解析模块各自 < 400 行（DEFERRED→v0.4.15）
- [ ] Dialect enum 提升为独立模块（DEFERRED→v0.4.15）
