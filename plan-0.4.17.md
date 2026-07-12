# plan-0.4.17.md — 架构优化计划

> 基于深度代码审查的架构改进方案，目标：提升可维护性、扩展性和测试健壮性。

---

## 背景

TypeSpec v0.4.16 已具备完整的 compile/reverse/diff/migrate 四命令流水线，267+ 测试用例。本次优化聚焦**技术债务清理**和**架构可扩展性提升**，不新增用户功能。

---

## 任务清单

### Task 1: 拆分 semantic.zig（高优先级）

**问题**：`semantic.zig`（1141 行）承担过多职责——模板解析/应用、三个语义 pass、ResolvedAst 类型定义。

**方案**：

1. 新建 `template.zig`（~400 行）
   - 迁移：`ResolvedTable`、`PassContext`、模板 map 构建、`resolveTemplate()`、`applyTemplate()`、循环继承检测、mixin 合并逻辑
   - 保持：`SemanticAnalyzer.analyze()` 中模板解析部分改为调用 `template.resolveAll()`

2. `semantic.zig` 瘦身至 ~500 行
   - 保留：`SemanticPass`、`DEFAULT_PASSES`、三个 pass 函数、`analyze()` 编排逻辑
   - 新增：`ResolvedAst` / `ResolvedTable` 类型定义移至 `ast.zig`（它们是 AST 的自然延伸）

3. 更新 `ARCHITECTURE.md` 模块依赖图

**影响文件**：
- `src/semantic.zig`（修改）
- `src/template.zig`（新建）
- `src/ast.zig`（加 ResolvedTable / ResolvedAst 类型）
- `src/main.zig`（import 路径更新）
- `src/diff.zig`（import 路径更新）
- `ARCHITECTURE.md`（依赖图更新）

**验证**：`zig build test` + 全部 golden file 测试通过

---

### Task 2: 拆分 type_map 正向/反向映射（中优先级）

**问题**：`TYPE_TABLE` 单数组同时服务正向和反向映射，靠 `rev_priority` 和数组顺序消歧，映射表膨胀后维护困难。

**方案**：

```zig
// 正向映射：TPS symbol → SQL type (per dialect)
pub const FORWARD_MAP = [_]ForwardMapping{
    .{ .tps = "n", .mysql = "int", .pg = "integer", .sqlite = "INTEGER" },
    .{ .tps = "s", .mysql = "varchar(255)", .pg = "varchar(255)", .sqlite = "TEXT" },
    // ... 只含单字符核心符号 + 参数化类型
};

// 反向映射：SQL type → TPS symbol (带优先级)
pub const REVERSE_MAP = [_]ReverseMapping{
    .{ .sql_mysql = "int", .tps = "n", .priority = 10 },
    .{ .sql_mysql = "tinyint", .tps = "n", .priority = 20 },
    // ... 含所有方言变体
};
```

**影响文件**：
- `src/type_map.zig`（重构）
- `src/sql_parser.zig`（如果直接引用 TYPE_TABLE）
- `src/reverse_codegen.zig`（调用 `reverseLookup`）

**验证**：反向映射测试 + reverse golden file 测试通过

---

### Task 3: Template Extraction 算法文档化（中优先级）

**问题**：`reverse_codegen.zig` 的 template extraction 贪心打分算法无形式化文档。

**方案**：

1. 在 `ARCHITECTURE.md` 新增 `## Template Extraction Algorithm` 章节
2. 记录：
   - 输入：`SqlTable[]`（所有表的 IR）
   - 打分函数：字段序列匹配度 × 复用频率 / 模板大小
   - 阈值：分数 > N 时提取为 template
   - 复杂度：O(tables × fields²)
   - 保证：每个表最多继承 3 层 template

**影响文件**：
- `ARCHITECTURE.md`（文档更新）

---

### Task 4: 错误恢复集成测试（中优先级）

**问题**：`DiagnosticCollector` 支持错误恢复，但无专门测试验证"多错误收集"行为。

**方案**：

1. 新建 `tests/error-recovery/` 目录
2. 测试用例：
   - `multi-err-fields.tps`：同表两个无效类型 → 应收集 2 个 error
   - `multi-err-templates.tps`：模板不存在 + 字段类型错误 → 应收集 2 个 error
   - `multi-err-fk.tps`：FK 引用不存在的表 + 重复字段名 → 应收集 2 个 error
   - `err-recovery-continue.tps`：3 个错误，验证前两个不阻塞第三个的解析
3. 新建 `tests/test_error_recovery.sh`，验证 stderr 输出包含预期错误数量和消息

**影响文件**：
- `tests/error-recovery/*.tps`（新建）
- `tests/expected/error-recovery/*.err`（新建，预期错误输出）
- `tests/test_error_recovery.sh`（新建）

---

### Task 5: 扩展 DialectBackend vtable 为可选方法（低优先级）

**问题**：当前 15 个函数指针全部 required，新增方言时即使某些方法不适用（如 SQLite 的 `emitCreateDatabase` 是 no-op）也必须实现。

**方案**：

将 vtable 改为 optional 函数指针：

```zig
pub const DialectBackend = struct {
    quoteIdent: *const fn (...) anyerror!void,                    // required
    emitCreateDatabase: ?*const fn (...) anyerror!void = null,    // optional (SQLite: null)
    emitUnsigned: ?*const fn (...) anyerror!void = null,          // optional
    // ...
};
```

codegen.zig 中调用前检查 `if (backend.emitCreateDatabase) |fn_|`。

**影响文件**：
- `src/dialect.zig`（vtable 定义 + 三个 backend 实例）
- `src/codegen.zig`（调用处加 null check）

**验证**：全部 golden file 测试通过

---

### Task 6: 测试脚本结构化输出（低优先级）

**问题**：Bash golden file 测试失败时输出原始 diff，不友好。

**方案**：

在 `tests/` 公共头文件中加 helper 函数：

```bash
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; echo "     Expected: $2"; echo "     Got:      $3"; FAILURES=$((FAILURES+1)); }
summary() { echo ""; echo "Results: $PASSED passed, $FAILED failed"; [ $FAILED -eq 0 ] && exit 0 || exit 1; }
```

**影响文件**：
- `tests/test.sh`、`tests/test_postgres.sh` 等（改用 helper）
- `tests/lib.sh`（新建公共函数）

---

## 优先级排序

| Task | 优先级 | 预估工作量 | 风险 |
|------|--------|-----------|------|
| Task 1: 拆分 semantic.zig | 高 | 2-3h | 中（重构核心模块） |
| Task 2: 拆分 type_map | 中 | 1-2h | 低（数据结构重构） |
| Task 3: Template extraction 文档 | 中 | 0.5h | 无 |
| Task 4: 错误恢复测试 | 中 | 1-2h | 低（纯新增） |
| Task 5: DialectBackend optional | 低 | 1h | 低（API 兼容） |
| Task 6: 测试脚本结构化 | 低 | 1h | 无 |

---

## 执行顺序建议

```
Phase 1 (核心重构):
  Task 1 (semantic 拆分) ✅ → Task 2 (type_map 拆分) ✅ → 全量测试验证 ✅

Phase 2 (文档 + 测试):
  Task 3 (算法文档) ✅ + Task 4 (错误恢复测试) ✅ — 完成

Phase 3 (打磨):
  Task 5 (vtable optional) — 待做
  Task 6 (测试输出美化) — 待做
```

---

## 不在本次范围

- 新增 DSL 语法特性（如 VIEW、TRIGGER）
- 新增 SQL 方言（如 MSSQL、Oracle）
- 增量编译 / 缓存层
- 语言服务（LSP）
- Zig 写测试 harness（成本高，收益有限）

---

## 成功标准

1. `zig build test` 全部通过
2. 全部 golden file 测试（267+）通过
3. `semantic.zig` 行数 < 550 行
4. `ARCHITECTURE.md` 模块依赖图更新
5. 新增至少 3 个错误恢复测试用例
