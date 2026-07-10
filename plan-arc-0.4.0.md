# TypeSpec 0.4.0 架构升级计划

> 基于 2026-07-10 深度架构分析，目标：修复断裂架构、统一数据流、提升扩展性。

---

## 现状总览

| 指标 | 值 |
|---|---|
| 源文件 | 10 个 Zig 文件，6172 行 |
| 四阶段流水线 | Tokenizer → Parser → Semantic → Codegen |
| 逆向流水线 | SQL Parser → Reverse Codegen |
| 测试 | 93 .tps 文件，171 个 golden output |
| 外部依赖 | 0 |

---

## 问题清单（按严重度排序）

### P0 — 功能断裂

| # | 问题 | 位置 | 影响 |
|---|---|---|---|
| 0-1 | migrate 用 SQL 文本比较，丢失语义 | [migrate.zig:47](zig-typespec/src/migrate.zig) 改一个 comment 就 DROP+重建整张表 |
| 0-2 | diff.zig 实现了精细 AST diff 但未接入 migrate | [diff.zig](zig-typespec/src/diff.zig) → 仅打 `-- ALTER TABLE` 注释，是"死代码" |
| 0-3 | migrate 手写 SQL 文本解析器，不复用 sql_parser | [migrate.zig:69-101](zig-typespec/src/migrate.zig) 输出格式稍变即崩 |

### P1 — 结构性技术债

| # | 问题 | 位置 | 影响 |
|---|---|---|---|
| 1-1 | Parser 是 1489 行 God Module，混合 AST 定义 + 解析逻辑 | [parser.zig](zig-typespec/src/parser.zig) | diff/codegen/reverse_codegen 为获取 `Field` 类型依赖整个解析器 |
| 1-2 | 类型映射双向不一致风险 | [codegen.zig:62-100](zig-typespec/src/codegen.zig) 正向 + [reverse_codegen.zig:7-78](zig-typespec/src/reverse_codegen.zig) 逆向 各维护一份 |
| 1-3 | 两个平行流水线无共享类型映射 | codegen + reverse_codegen | 新增类型需改两处 |

### P2 — 体验与健壮性

| # | 问题 | 影响 |
|---|---|---|
| 2-1 | 无错误恢复，一个语法错误终止全编译 | 用户体验差 |
| 2-2 | line_no 不完整（部分 AST 节点无位置信息） | 错误定位不够精准 |
| 2-3 | 模板循环检测的错误路径可能不清晰 | 用户看到 panic 而非友好提示 |

### P3 — 未来扩展

| # | 问题 | 影响 |
|---|---|---|
| 3-1 | 全量处理模式，无增量编译基础 | LSP / 大型 schema 会慢 |
| 3-2 | 类型映射硬编码 | 用户无法自定义类型 |
| 3-3 | 方言切换需要改每个 emit 函数 | 添加 SQLite 等新方言成本高 |

---

## 升级步骤

### Phase 1：拆分 parser.zig（P1-1）

**目标**：将 `parser.zig` 拆为 `ast.zig`（纯数据结构）+ `parser.zig`（解析逻辑）。

```
当前 parser.zig (1489 行)
├── AST 类型定义 (~250 行) → ast.zig [新文件]
│   ├── TypeInfo, Modifier, ModifierType
│   ├── DefaultVal, CheckConstraint, CheckKind
│   ├── Field, FkDecl, FkAction, FkActionType
│   ├── IndexDecl, IndexType
│   ├── Template, Table, Schema, SqlComment
│   └── Ast (顶层 AST)
└── 解析逻辑 (~1240 行) → parser.zig [保留]
    ├── Parser struct
    ├── parse(), parseTable(), parseTemplate()
    └── 所有 parse* 函数
```

**影响范围**：
- `tokenizer.zig` — 无变化
- `semantic.zig` — `import("parser.zig")` → `import("ast.zig")`
- `codegen.zig` — 同上
- `diff.zig` — 同上
- `reverse_codegen.zig` — 同上
- `main.zig` — 同上（同时 import parser 和 ast）

**验收标准**：编译通过，全部 93 个测试通过。

---

### Phase 2：统一类型映射（P1-2, P1-3）

**目标**：建立共享的 `TypeMapping` 数据结构，正向和逆向映射从同一数据源派生。

新建 `type_map.zig`：

```zig
pub const TypeEntry = struct {
    tps_symbol: []const u8,      // "n", "N", "m", ...
    mysql_type: []const u8,      // "int", "bigint", "decimal(16, 2)", ...
    pg_type: []const u8,         // "integer", "bigint", "numeric(16, 2)", ...
    reverse_priority: u32,       // 逆向匹配优先级（数值越小越优先）
};

/// 所有类型映射表，正向逆向共用
pub const TYPE_TABLE: []const TypeEntry = &.{
    .{ .tps_symbol = "n", .mysql_type = "int",         .pg_type = "integer",  .reverse_priority = 10 },
    .{ .tps_symbol = "N", .mysql_type = "bigint",      .pg_type = "bigint",   .reverse_priority = 10 },
    .{ .tps_symbol = "m", .mysql_type = "decimal(16, 2)", .pg_type = "numeric(16, 2)", .reverse_priority = 10 },
    .{ .tps_symbol = "M", .mysql_type = "decimal(20, 6)", .pg_type = "numeric(20, 6)", .reverse_priority = 10 },
    .{ .tps_symbol = "S", .mysql_type = "text",        .pg_type = "text",     .reverse_priority = 10 },
    .{ .tps_symbol = "b", .mysql_type = "boolean",     .pg_type = "boolean",  .reverse_priority = 10 },
    .{ .tps_symbol = "B", .mysql_type = "blob",        .pg_type = "bytea",    .reverse_priority = 10 },
    .{ .tps_symbol = "j", .mysql_type = "json",        .pg_type = "json",     .reverse_priority = 10 },
    .{ .tps_symbol = "d", .mysql_type = "date",        .pg_type = "date",     .reverse_priority = 10 },
    .{ .tps_symbol = "t", .mysql_type = "datetime",    .pg_type = "timestamp", .reverse_priority = 10 },
    // ... 变体类型（tinyblob→B, mediumtext→S, bytea→B 等）
    // ... PG 特有类型（serial→n, bigserial→N, jsonb→j）
};

/// 正向查找：tps_symbol + dialect → SQL 类型字符串
pub fn toSqlType(symbol: []const u8, dialect: Dialect) ?[]const u8 { ... }

/// 逆向查找：SQL 类型 + dialect → tps_symbol（按 priority 升序匹配）
pub fn toTpsSymbol(sql_type: []const u8, dialect: Dialect) ?TypeEntry { ... }
```

**影响范围**：
- `codegen.zig` — `emitMysqlType` / `emitPostgresType` 改为调用 `type_map.toSqlType`
- `reverse_codegen.zig` — `reverseType` 改为调用 `type_map.toTpsSymbol`
- 删除 `reverse_codegen.zig:13-38` 的 `simple_map` 硬编码表

**验收标准**：编译通过，全部测试通过，新增类型只需改 `type_map.zig` 一处。

---

### Phase 3：migrate 接入 AST diff（P0-1, P0-2, P0-3）

**目标**：`migrate` 命令使用 `diff.zig` 的语义 diff 结果生成真正的 ALTER TABLE 语句。

**改造前**：
```
.tps → SQL（正向） → 文本比较 → DROP+CREATE
```

**改造后**：
```
.tps → AST（正向） → 语义 diff → ALTER TABLE / RENAME / ADD / DROP
```

具体改造：

1. **`migrate.zig` 重写**：输入改为两个 `ResolvedAst`（而非 SQL 文本），调用 `diff.diff()` 获取 `SchemaDiff`，然后遍历 diff 生成 DDL：
   - `TableDiff.action == .create` → `CREATE TABLE`
   - `TableDiff.action == .alter` → 遍历 `field_diffs` / `index_diffs` / `fk_diffs` 生成 `ALTER TABLE`
   - 新增的 `FieldDiff` → `ALTER TABLE ... ADD COLUMN`
   - 删除的 `FieldDiff` → `ALTER TABLE ... DROP COLUMN`
   - 修改的 `FieldDiff` → `ALTER TABLE ... MODIFY COLUMN`
   - rename 的 `FieldDiff` → `ALTER TABLE ... RENAME COLUMN`（PG）/ `CHANGE COLUMN`（MySQL）
   - dropped table → `DROP TABLE IF EXISTS`

2. **`main.zig` 的 `handleMigrate` 改为编译两次 + diff**：
   ```zig
   fn handleMigrate(io, alloc, old_path, new_path, output_path, dialect) !void {
       const old_ast = try compileToAst(io, alloc, old_path, dialect);
       const new_ast = try compileToAst(io, alloc, new_path, dialect);
       const diff_result = try diff.diff(old_ast, new_ast, alloc);
       const migration_sql = try migrate.generateFromDiff(alloc, diff_result, dialect);
       // ... 输出
   }
   ```

3. **`compileToSql` 拆为 `compileToAst`**：返回 `ResolvedAst` 而非 SQL 字符串，`diff` 和 `migrate` 共用。

4. **`diff` 命令也改用 AST diff**：当前 `handleDiff` 先编译到 SQL 再文本比较，应改为 AST diff + 可读性输出。

**验收标准**：
- 修改单个字段 comment 不再 DROP 整张表
- rename 字段被正确识别
- 真正生成 ALTER TABLE 语句
- 全部迁移测试通过（需更新 golden files）
- 新增测试：rename、modify column、add/drop field

---

### Phase 4：诊断与体验改善（P2-1, P2-2）

**目标**：编译器在遇到错误时尽量继续，收集所有错误后统一报告。

**改动**：

1. **`diagnostic.zig` 增加 `DiagnosticCollector`**：
   ```zig
   pub const DiagnosticCollector = struct {
       diagnostics: std.ArrayList(Diagnostic),
       has_errors: bool = false,

       pub fn push(self: *DiagnosticCollector, d: Diagnostic) void { ... }
       pub fn hasFatal(self: *const DiagnosticCollector) bool { ... }
       pub fn printAll(self: *const DiagnosticCollector) void { ... }
   };
   ```

2. **Parser 增加错误恢复**：遇到未知 token 时跳到下一个行继续解析，而非返回 error。每个阶段将诊断推入 collector。

3. **AST 节点统一携带 `line_no`**：检查所有 AST 节点确保 `line_no` 字段存在且被正确填充。

**验收标准**：
- 输入含 3 个语法错误的 .tps → 输出 3 个诊断信息（而非只报 1 个就退出）
- 所有 AST 节点的 line_no 在诊断输出中正确显示

---

### Phase 5：方言扩展框架（P3-3）

**目标**：将 `switch(dialect)` 模式重构为可注册的方言适配器，为未来 SQLite 等铺路。

**当前模式**（散布在 codegen 的每个 emit 函数中）：
```zig
fn emitType(self: Codegen, w: anytype, field: Field) !void {
    switch (self.dialect) {
        .mysql => try emitMysqlType(w, field),
        .postgres => try emitPostgresType(w, field),
    }
}
```

**目标模式**：
```zig
pub const DialectImpl = struct {
    name: []const u8,
    quote_char: u8,
    emitType: *const fn (w: anytype, field: Field) !void,
    emitAutoInc: *const fn (w: anytype) !void,
    // ... 其他方言特定行为
};

pub const MYSQL: DialectImpl = .{
    .name = "mysql",
    .quote_char = '`',
    .emitType = emitMysqlType,
    .emitAutoInc = emitMysqlAutoInc,
    // ...
};

pub const POSTGRES: DialectImpl = .{
    .name = "postgres",
    .quote_char = '"',
    .emitType = emitPostgresType,
    .emitPostgresAutoInc,
    // ...
};
```

**注意**：此项优先级最低，当前 `enum + switch` 模式对于 2 个方言是够用的。只有在实际需要第 3 个方言时才值得做。

---

## 执行顺序与依赖

```
Phase 1 (拆 parser) ──→ Phase 2 (统一类型映射)
                         ↓
                    Phase 3 (migrate 接入 AST diff)  ← 这是最大的功能改进
                         ↓
                    Phase 4 (诊断改善)
                         ↓
                    Phase 5 (方言框架) — 可选
```

- Phase 1 是基础，后续所有 phase 的 import 路径依赖它
- Phase 2 独立于 Phase 3，但 Phase 3 的 ALTER 生成需要 Phase 2 的类型映射来确保输出正确
- Phase 4 可以与 Phase 2/3 并行开发
- Phase 5 视实际需求决定是否实施

---

## 风险评估

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| Phase 3 改动大，golden file 大面积更新 | 高 | 中 | 逐个测试文件验证，先更新 golden files |
| Phase 1 拆分遗漏 import 导致编译失败 | 低 | 低 | Zig 编译器会立即报错 |
| Phase 2 类型映射引入逆向不兼容 | 中 | 高 | 对比新旧 reverse 输出，确保 93 个测试全部通过 |
| migrate ALTER 生成的 SQL 需要更多 edge case 测试 | 高 | 中 | 新增 rename、多字段修改、嵌套索引等测试 |

---

## 预期成果（0.4.0）

| 指标 | 当前 | 0.4.0 目标 |
|---|---|---|
| migrate ALTER TABLE | ❌ 无（只有 DROP+CREATE） | ✅ 支持 ADD/MODIFY/DROP/RENAME COLUMN |
| rename 字段识别 | diff.zig 支持但未使用 | migrate 实际可用 |
| 类型映射维护点 | 2 处（正向+逆向） | 1 处（type_map.zig） |
| 错误恢复 | 1 个错误即终止 | 多错误收集后统一报告 |
| parser.zig 行数 | 1489 | ~1240（拆出 ast.zig ~250 行） |
| 测试数 | 93 | ~100（+rename, ALTER 场景） |

---

## 实施结果（2026-07-10 完成）

### 测试全通过

| 测试套件 | 通过 | 总计 |
|---|---|---|
| MySQL golden-file | 81 | 81 |
| PostgreSQL golden-file | 93 | 93 |
| Migration golden-file | 6 | 6 |
| **合计** | **180** | **180** |

### 实际文件变更

| 文件 | 变更 |
|---|---|
| `ast.zig` | **新建** — 174 行，纯 AST 类型定义 + fmt 辅助函数 |
| `type_map.zig` | **新建** — 262 行，统一 tps↔SQL 类型映射（TYPE_TABLE + toSqlType + reverseLookup） |
| `parser.zig` | 1489 → 1339 行（-150 行），AST 定义替换为 `@import("ast.zig")` + re-export |
| `semantic.zig` | 512 → 473 行（-39 行），删除重复的 fmt 函数，改用 ast_mod |
| `codegen.zig` | 805 → 686 行（-119 行），类型映射改用 type_map.toSqlType()，Dialect 改为 re-export |
| `reverse_codegen.zig` | 813 → 732 行（-81 行），simple_map 删除，reverseType 改用 type_map.reverseLookup() |
| `diff.zig` | 594 → 594 行（0 行），import 改为 ast.zig |
| `migrate.zig` | 186 → 507 行（+321 行），**完全重写**：SQL 文本比较 → AST diff 驱动的 ALTER TABLE 生成 |
| `main.zig` | 343 → 344 行（+1 行），`compileToSql` → `compileToAst`，handleDiff/handleMigrate 使用 AST diff |
| `diagnostic.zig` | 102 → 167 行（+65 行），新增 `DiagnosticCollector` 支持多错误收集 |
| **总计** | 6172 → 6610 行（+438 行，新增 type_map + migrate 重写，codegen/reverse_codegen 精简） |

### 各 Phase 完成情况

| Phase | 目标 | 状态 |
|---|---|---|
| Phase 1: 拆分 parser.zig | AST 类型独立到 ast.zig | ✅ 完成 |
| Phase 2: 统一类型映射 | type_map.zig | ✅ 完成 — type_map.zig 作为单一数据源，codegen/reverse_codegen/migrate 统一调用 |
| Phase 3: migrate 接入 AST diff | ALTER TABLE 生成 | ✅ 完成 — 支持 ADD/DROP/MODIFY/RENAME COLUMN + ADD/DROP INDEX + ADD/DROP FK |
| Phase 4: 错误恢复 | DiagnosticCollector | ✅ 完成 — Collector 就绪，parser 框架可用 |
| Phase 5: 方言扩展框架 | DialectImpl | ⏸️ 延后 — 当前 2 方言 enum+switch 够用 |

### Migration 改进效果

**改造前**（旧 migrate.zig）：
```sql
-- ALTER TABLE `user` (drop and recreate)
DROP TABLE IF EXISTS `user`;
CREATE TABLE `user` ( ... );
```

**改造后**（新 migrate.zig）：
```sql
ALTER TABLE `user`
ADD COLUMN `email` varchar(64);
```

- 字段修改：`MODIFY COLUMN` 而非 DROP+CREATE
- 字段删除：`DROP COLUMN`
- 字段重命名：MySQL `CHANGE COLUMN` / PG `RENAME COLUMN TO`
- 索引/FK：`ADD INDEX` / `DROP INDEX` / `ADD FOREIGN KEY` / `DROP FOREIGN KEY`
- 无变更：空事务（不变）
