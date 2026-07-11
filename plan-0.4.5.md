# TypeSpec v0.4.5 升级计划

> 基于深度架构分析，修复技术债务、提升可靠性与可扩展性。

## 目标

修复 v0.4.4 遗留的架构债务，使项目进入健康状态：
1. DialectBackend vtable 对齐（消除双路径）
2. 缓冲区安全修复
3. 代码重复消除
4. 单元测试从 0 → 核心模块覆盖
5. DiagnosticCollector 接入主流水线

---

## Phase 1: P0 修复（可靠性）

### P0-1: DialectBackend vtable 对齐

**问题**：11 个 vtable 方法只用了 4 个，其余被 codegen.zig 内联 switch 绕过。

**方案**：删除 6 个废弃的 vtable 方法，将 vtable 缩小到实际使用的接口：

```zig
pub const DialectBackend = struct {
    quoteIdent: *const fn (w: anytype, name: []const u8) anyerror!void,
    emitIndex: *const fn (w: anytype, idx: IndexDecl, needs_comma: *bool) anyerror!void,
    emitUnsigned: *const fn (w: anytype) anyerror!void,
    emitTimestampModifier: *const fn (w: anytype, with_on_update: bool) anyerror!void,
};
```

被删除的方法（及其在 codegen.zig 中的内联替代）：
- `emitFooter` → codegen.zig L206-221 内联
- `emitComments` → codegen.zig L224-256 内联
- `emitStandaloneIndexes` → codegen.zig L258-276 内联
- `emitFieldSuffix` → codegen.zig L100-120 内联
- `emitFieldComment` → codegen.zig L130-136 内联
- `emitInlineIndexes` → codegen.zig L175-188 内联
- `emitCreateDatabase` → main.zig 内联

**涉及文件**：`dialect.zig`、`codegen.zig`
**风险**：低（纯删除，行为不变）
**预计时间**：1h

### P0-2: 修复缓冲区溢出

**问题**：两处固定大小缓冲区无越界检查。

**方案**：

1. `typed_ast.zig` 的 `resolveColumn` — MySQL ENUM 分支（L157-168）：
   用 `std.ArrayList(u8)` 替代 `type_buf: [64]u8` 的手动写入。

2. `reverse_codegen.zig` 的 `parseInList`（L194）和 `classifyFk`（L291）：
   256 字节栈缓冲区加 bounds check，超长时返回 error 而非静默截断。

**涉及文件**：`typed_ast.zig`、`reverse_codegen.zig`
**风险**：低（防御性修复）
**预计时间**：1h

---

## Phase 2: P1 架构改进（统一性）

### P1-1: migrate.zig 方言处理统一

**问题**：migrate 有三重方言路径（vtable CREATE + helper 函数 ALTER + raw switch）。

**方案**：将 `migrate.zig` 的 helper 函数迁移到 `DialectBackend`：

```zig
// 新增到 DialectBackend（或保持在 migrate.zig 但统一调用方式）
emitAlterAddColumn: *const fn (w, table, col_def) !void,
emitAlterDropColumn: *const fn (w, table, col_name) !void,
emitAlterModifyColumn: *const fn (w, table, col_def) !void,
emitAlterChangeColumn: *const fn (w, table, old_name, col_def) !void,
```

或者更务实的方案：**不扩展 vtable**，而是提取 `migrate.zig` 的 helper 为一个 `MigrateDialect` struct，与 `DialectBackend` 平行但更小。

**涉及文件**：`migrate.zig`、`dialect.zig`
**风险**：中（迁移 ALTER 路径的方言逻辑）
**预计时间**：3h

### P1-2: PG/SQLite backend 去重

**问题**：`pgEmitIndex` 和 `sqliteEmitIndex` 等 ~200 行完全重复。

**方案**：提取共享实现：

```zig
fn commonPgSqliteEmitIndex(w: anytype, idx: IndexDecl, needs_comma: *bool) !void { ... }
fn commonPgSqliteEmitFooter(w: anytype, table: TypedTable) !void { ... }
fn commonPgSqliteEmitStandaloneIndexes(w: anytype, table: TypedTable) !void { ... }
```

PG 和 SQLite backend 各自只保留差异方法（`quoteIdent`、`emitComments`、`emitCreateDatabase`）。

**涉及文件**：`dialect.zig`
**风险**：低（纯重构，不改行为）
**预计时间**：1.5h

### P1-3: reverse_codegen.zig 模板类型匹配

**问题**：`findTemplates()` 只匹配列名，不检查列类型。

**方案**：在列名匹配后增加类型比较。两种策略：
- **宽松策略**：列名匹配 + 类型相同 → 模板字段；列名匹配但类型不同 → 跳过该字段
- **严格策略**：所有匹配列的类型必须完全一致，否则不形成模板

推荐宽松策略（允许部分字段进入模板，其余留在表中）。

**涉及文件**：`reverse_codegen.zig`
**风险**：中（可能改变现有 reverse 输出）
**预计时间**：2h

---

## Phase 3: P2 测试补全（覆盖）

### P2-1: 核心模块单元测试

**问题**：14 个源文件零 `test` block，单元测试覆盖 0%。

**方案**：为以下模块添加 Zig inline test：

| 模块 | 测试内容 | 优先级 |
|------|----------|--------|
| `type_map.zig` | forward/reverse 类型映射正确性 | 高 |
| `tokenizer.zig` | 行分类、token 分割 | 高 |
| `ast.zig` | 数据结构初始化 | 低 |
| `typed_ast.zig` | resolveColumn 各分支 | 高 |
| `diff.zig` | fieldsEqual、rename 检测 | 中 |
| `semantic.zig` | 模板合并、slot 机制 | 中 |

示例（`type_map.zig`）：

```zig
test "n maps to int in MySQL" {
    const result = type_map.toSqlType(.{ .simple = "n" }, .mysql);
    try std.testing.expectEqualStrings("int", result);
}
```

**涉及文件**：`type_map.zig`、`tokenizer.zig`、`typed_ast.zig`、`diff.zig`、`semantic.zig`
**风险**：零（只增不改）
**预计时间**：3h

### P2-2: reverse 路径 golden file 扩展

**问题**：reverse 测试只有 2 个 golden file（basic.sql、fk-index.sql），覆盖不足。

**方案**：新增测试用例：
- `enum.sql` — ENUM 类型 + CHECK 约束
- `composite-pk.sql` — 复合主键
- `template.sql` — 跨表模板提取（`-t` flag）
- `check-range.sql` — BETWEEN / IN / 比较约束

**涉及文件**：`tests/reverse/*.sql`、`tests/reverse/*.mysql.tps`
**风险**：零
**预计时间**：1.5h

---

## Phase 4: P3 改善（可选，视时间）

### P3-1: DiagnosticCollector 接入主流水线

**问题**：`DiagnosticCollector` 已实现但未使用，parser 仍用 `printDiagnostic` 立即输出。

**方案**：
1. Parser 改为向 `DiagnosticCollector` push 诊断信息
2. 编译结束后统一输出（可选 JSON 格式）
3. `main.zig` 检查 `collector.hasErrors()` 决定 exit code

**涉及文件**：`parser.zig`、`diagnostic.zig`、`main.zig`
**风险**：中（parser 中所有 diagnostic 调用点需改）
**预计时间**：3h

### P3-2: migrate `old_ast` 参数激活

**问题**：`generateFromDiff` 接收旧 AST 但完全忽略。

**方案**：利用 `old_ast` 实现精确的 MODIFY 检测（类型变更、修饰符变更），生成 `MODIFY COLUMN` 而非 `DROP + ADD`。

**涉及文件**：`migrate.zig`、`diff.zig`
**风险**：中高（diff 逻辑变更）
**预计时间**：4h

---

## 依赖关系

```
P0-1 (vtable 对齐) ──→ P1-1 (migrate 统一) ──→ P1-3 (模板类型匹配)
                         ↑
P0-2 (缓冲区安全) ──────┘

P1-2 (PG/SQLite 去重) ──→ P2-1 (单元测试)

P3-1 (Diagnostic) ──→ P3-2 (old_ast 激活)  [独立]
```

## 预计总时间

| Phase | Items | 预计 |
|-------|-------|------|
| P0 | P0-1, P0-2 | 2h |
| P1 | P1-1, P1-2, P1-3 | 6.5h |
| P2 | P2-1, P2-2 | 4.5h |
| P3 | P3-1, P3-2 | 7h（可选） |
| **总计** | | **13h + 7h 可选** |

## 预期指标

| 指标 | 当前 (v0.4.4) | 目标 (v0.4.5) |
|------|---------------|---------------|
| 测试总数 | 181 | 195+ |
| Zig inline test | 0 | 30+ |
| vtable 方法数 | 11（4 active） | 4（全部 active） |
| 缓冲区风险 | 2 处 | 0 |
| PG/SQLite 重复行 | ~200 | ~0 |
| migrate 方言路径 | 3 | 1 |
