# Plan: v0.4.8 — Architecture Cleanup

> 基于深度架构分析，聚焦技术债清理和扩展性提升。

## 目标

1. 消除 parser 模块重复代码
2. 将 codegen 方言 switch 吸收回 DialectBackend vtable
3. 为未来扩展打好基础

## P0: 消除 Parser 重复（parse_field/fk/check/index.zig）

### 问题

`parser.zig` 内部有完整的 field/FK/check/index 解析逻辑，同时 `parse_field.zig`、`parse_fk.zig`、`parse_check.zig`、`parse_index.zig` 包含独立的重复版本（共 ~820 行）。`parser.zig` 不 import 这 4 个模块，两套代码并存。

### 方案

**选择 A（推荐）：删除 4 个提取模块**

理由：
- `parser.zig` 是实际使用的代码路径，且有 `self: *Parser` 上下文（方便错误恢复）
- 提取模块用独立 `Allocator` 参数，丢失了 parser 的诊断上下文
- 两套代码行为已开始漂移（提取模块缺少部分错误恢复逻辑）
- 删除后减少 ~820 行代码，降低维护负担

具体步骤：
1. 确认 `parse_field.zig` / `parse_fk.zig` / `parse_check.zig` / `parse_index.zig` 没有被任何文件 import
2. 删除 4 个文件
3. 在 `build.zig` 中无需改动（只有 `main.zig` 是编译入口）
4. 运行全部测试确认无回归

**选择 B（备选）：让 parser.zig import 提取模块**

将 `parser.zig` 中的 field/FK/check/index 解析逻辑替换为对提取模块的调用。但这需要：
- 给提取模块加上 DiagnosticCollector 参数
- 重构提取模块的函数签名以适配 Parser 上下文
- 工作量更大，收益不明显

### 测试验证

- 运行 `zig build test`（内联单元测试）
- 运行 `tests/test.sh`（MySQL 81 项）
- 运行 `tests/test_postgres.sh`（PG 93 项）
- 运行 `tests/test_sqlite.sh`（SQLite）
- 运行 `tests/test_migrate.sh`（Migration 9 项）
- 运行 `tests/test_reverse.sh`（Reverse 8 项）
- 运行 `tests/test_diff.sh`（Diff 2 项）

---

## P1: 扩展 DialectBackend vtable

### 问题

`codegen.zig` 的 `generateTypedTable` 中有 4 处 `switch (self.dialect)` 硬编码，破坏了 vtable 的抽象边界：

| 位置 | 内容 | 当前实现 |
|------|------|----------|
| 行 98-115 | inline index/unique 渲染 | `switch (self.dialect)` MySQL vs PG/SQLite |
| 行 145-160 | table footer (ENGINE, CHARSET, COMMENT) | 三路 switch |
| 行 163-195 | column/table comment 输出 | 三路 switch |
| 行 198-211 | PG/SQLite standalone CREATE INDEX | `if (self.dialect != .mysql)` |
| 行 224-240 | AUTO_INCREMENT 渲染 | 三路 switch |

### 方案

扩展 `DialectBackend`，新增 4 个方法：

```zig
pub const DialectBackend = struct {
    // ── 现有 5 个方法 ──
    quoteIdent:             *const fn (w, name) -> !void,
    emitIndex:              *const fn (w, idx, needs_comma) -> !void,
    emitCreateDatabase:     *const fn (w, name, charset) -> !void,
    emitUnsigned:           *const fn (w) -> !void,
    emitTimestampModifier:  *const fn (w, with_on_update) -> !void,

    // ── 新增 4 个方法 ──
    emitTableFooter:        *const fn (w, engine, charset, comment) -> !void,
    emitTableComments:      *const fn (w, table_name, table_comment, columns) -> !void,
    emitAutoIncrement:      *const fn (w) -> !void,
    emitInlineIndex:        *const fn (w, col_name, is_unique, needs_comma) -> !void,
};
```

具体步骤：

1. 在 `dialect.zig` 中添加 4 个新函数指针字段
2. 为 MySQL / PG / SQLite 各实现对应函数
3. 修改 `codegen.zig` 的 `generateTypedTable`，将 4 处 switch 替换为 vtable 调用
4. 运行全部测试确认无回归

### 各方言实现映射

| 新方法 | MySQL | PostgreSQL | SQLite |
|--------|-------|-----------|--------|
| `emitTableFooter` | `ENGINE=... DEFAULT CHARSET=... COMMENT='...'` | `);\n` + COMMENT ON | `);\n` + `-- comment` |
| `emitTableComments` | no-op（COMMENT 已在 footer） | `COMMENT ON TABLE/COLUMN` | `-- comment` |
| `emitAutoIncrement` | `AUTO_INCREMENT` | `GENERATED ALWAYS AS IDENTITY` | no-op（用 PRIMARY KEY AUTOINCREMENT） |
| `emitInlineIndex` | `` INDEX `idx_name` (`col`) `` / `` UNIQUE INDEX `uk_name` (`col`) `` | `UNIQUE ("col")` / no-op | `UNIQUE ("col")` / no-op |

### 测试验证

- 同 P0 全套测试
- 重点关注 PostgreSQL 和 SQLite 的 golden file 输出不变

---

## P2: 清理 codegen.zig 中冗余 switch

### 前置条件

P1 完成后执行。

### 方案

P1 完成后，`codegen.zig:70-212` 中的 `generateTypedTable` 应该不再有任何 `switch (self.dialect)`。检查并清理：

1. 行 86-116 的 inline index 循环 → 用 `emitInlineIndex` 替代
2. 行 145-160 的 footer → 用 `emitTableFooter` 替代
3. 行 163-195 的 comment → 用 `emitTableComments` 替代
4. 行 198-211 的 standalone CREATE INDEX → 考虑是否移入 vtable（PG/SQLite 特有，MySQL no-op）
5. 行 224-240 的 AUTO_INCREMENT → 用 `emitAutoIncrement` 替代
6. 行 235-240 的 SQLite PRIMARY KEY AUTOINCREMENT 特殊处理 → 移入 SQLite backend

### 目标

`codegen.zig` 成为完全方言无关的代码，只做"遍历 TypedAst → 调用 vtable → 组装输出"。

---

## P3: 类型映射表性能优化（可选）

### 问题

`type_map.zig` 的 `TYPE_TABLE` 是线性数组，反向查找用 `rev_priority` 做优先级。当方言/类型增多时 O(n) 查找效率下降。

### 方案

在 `TypeResolver.init()` 时构建反向 HashMap（TPS symbol → SQL type），替代线性扫描。

优先级较低，仅在类型表条目超过 100 时考虑。

---

## 执行顺序

```
P0（删除重复 parser） → P1（扩展 vtable） → P2（清理 codegen switch） → P3（可选）
```

P0 和 P1 可以并行进行（互不冲突），但建议先做 P0（更简单，立即减少技术债）。

## 预估工作量

| 阶段 | 预估时间 | 风险 |
|------|----------|------|
| P0 | 15 分钟 | 低（纯删除，有测试覆盖） |
| P1 | 30-45 分钟 | 中（需保证每个方言的 golden file 不变） |
| P2 | 15 分钟 | 低（P1 完成后的机械替换） |
| P3 | 10 分钟 | 低（可选优化） |
