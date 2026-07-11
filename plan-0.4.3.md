# TypeSpec v0.4.3 架构升级计划

> 基于 v0.4.2 深度代码审计，聚焦可维护性与扩展性。

---

## 现状评估

| 维度 | 评分 | 说明 |
|------|------|------|
| 架构合理性 | ★★★★☆ | 4 阶段编译流水线教科书级正确 |
| 扩展性 | ★★★☆☆ | 横向扩展好（加类型/方言），纵向扩展有天花板 |
| 代码质量 | ★★★★☆ | 零依赖、180 测试、EBNF 形式化语法 |
| 可维护性 | ★★★☆☆ | Parser 单体函数 1339 行，诊断系统粗糙 |

---

## 问题清单

### P0 — 清理技术债

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| P0-1 | parser.zig 重新导出所有 AST 类型（第 6-24 行），无调用方使用 | parser.zig | 代码混乱，新人误解 |
| P0-2 | `readStdin` 吞掉错误 `catch {}` | main.zig:153 | 隐藏 I/O 问题 |
| P0-3 | `generateCheckExpr` 作为模块级 pub fn，与 Codegen struct 方法风格不一致 | codegen.zig:679 | 风格不统一 |

### P1 — 架构改进

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| P1-1 | `--dialect` 手动线性扫描解析，子命令增加时脆弱 | main.zig:42-64 | CLI 可维护性 |
| P1-2 | Codegen 每处 `switch(self.dialect)` 硬编码三方言，扩展到 5+ 方言时爆炸 | codegen.zig | 方言扩展成本 O(n²) |
| P1-3 | Diagnostic 直接 `stderr.print`，无法 JSON/LSP 结构化输出 | diagnostic.zig | 集成困难 |
| P1-4 | 无显式 IR 层，`ResolvedAst` 直接到 codegen | semantic.zig / codegen.zig | 多输出格式需重构 |

### P2 — 可扩展性

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| P2-1 | Parser 是 flat if-else 链（parseField 10 个分支），新增语法困难 | parser.zig:696-811 | 新语法维护成本高 |
| P2-2 | Semantic 3 次全表遍历串联（模板→autofk→suffix），无 pass 管理器 | semantic.zig:41-207 | 加新 pass 要改 analyze() |
| P2-3 | 无插件/扩展机制，用户无法插入自定义转换 | — | 二次开发受限 |

### P3 — 按需改进

| # | 问题 | 影响 |
|---|------|------|
| P3-1 | 无条件编译/macro 系统 | 高级 DSL 特性 |
| P3-2 | 无增量编译/缓存 | 大 schema 性能 |
| P3-3 | 测试纯 golden-file，无 property-based/fuzz 测试 | 边界情况覆盖 |

---

## 实施计划

### Phase 1：P0 清理（~2h）

1. **删除 parser.zig re-export**（第 6-24 行）
   - 检查所有 `import("parser.zig")` 的调用方，确认直接用 `import("ast.zig")`
   - 删除 19 行 re-export 代码

2. **修复 readStdin 错误处理**
   ```zig
   // main.zig:153 — 将 catch {} 改为 catch |e|
   r.interface.appendRemainingUnlimited(alloc, &result) catch |e| {
       // 保留已读内容，不吞错误
       if (result.items.len == 0) return e;
   };
   ```

3. **移动 generateCheckExpr 到 Codegen struct**
   ```zig
   // codegen.zig — 从模块级 fn 变为 Codegen 的方法
   fn generateCheckExpr(self: Codegen, w: anytype, field_name: []const u8, ck: CheckConstraint) !void {
       _ = self; // 暂不使用
       // ... 原有逻辑
   }
   ```

### Phase 2：P1 架构改进（~8h）

#### 2a. CLI 参数解析重构

将 main.zig 的手动扫描替换为结构化 subcommand 模式：

```zig
const Command = union(enum) {
    compile: struct { input: ?[]const u8, output: ?[]const u8, trace: bool },
    diff: struct { old: []const u8, new: []const u8 },
    migrate: struct { old: []const u8, new: []const u8, output: ?[]const u8 },
    reverse: struct { input: ?[]const u8, output: ?[]const u8, with_templates: bool },
};

fn parseArgs(alloc: std.mem.Allocator, raw_args: []const []const u8) !struct { dialect: Dialect, cmd: Command } {
    // 两遍扫描：第一遍提取 -d/--dialect，第二遍路由子命令
}
```

#### 2b. DialectBackend 接口

为方言切换引入 vtable 模式，避免 switch 爆炸：

```zig
pub const DialectBackend = struct {
    quoteIdent: *const fn (w: anytype, name: []const u8) anyerror!void,
    emitIndex: *const fn (w: anytype, idx: IndexDecl, needs_comma: *bool) anyerror!void,
    emitFooter: *const fn (w: anytype, table: ResolvedTable, charset: ?[]const u8) anyerror!void,
    emitComments: *const fn (w: anytype, table: ResolvedTable) anyerror!void,
    emitStandaloneIndex: *const fn (w: anytype, table: ResolvedTable) anyerror!void,
    typeMap: *const fn (type_info: TypeInfo) []const u8,
};

pub const mysql_backend: DialectBackend = .{ ... };
pub const pg_backend: DialectBackend = .{ ... };
pub const sqlite_backend: DialectBackend = .{ ... };
```

新增方言只需实现 `DialectBackend` + 注册到 `TYPE_TABLE`。

#### 2c. Diagnostic 结构化输出

```zig
pub const Diagnostic = struct {
    severity: Severity,
    line_no: usize,
    col: ?usize,
    message: []const u8,
    expected: ?[]const u8,
    actual: ?[]const u8,
    source_line: ?[]const u8,
};

pub const DiagnosticCollector = struct {
    diagnostics: std.ArrayList(Diagnostic),
    max_errors: usize = 16,

    pub fn formatJson(self: DiagnosticCollector, w: anytype) !void { ... }
    pub fn formatTerminal(self: DiagnosticCollector, w: anytype) !void { ... }
    pub fn hasErrors(self: DiagnosticCollector) bool { ... }
};
```

#### 2d. IR 层引入

在 Semantic 和 Codegen 之间加 `TypedAst`：

```zig
pub const TypedAst = struct {
    database: ?DatabaseDecl,
    tables: []const TypedTable,
    meta: []const MetaDecl, // CHECK/COMMENT/INDEX 聚合
};

pub const TypedTable = struct {
    name: []const u8,
    columns: []const TypedColumn,
    constraints: []const TableConstraint,
};

pub const TypedColumn = struct {
    name: []const u8,
    sql_type: []const u8,   // 已解析为具体 SQL 类型
    nullable: bool,
    primary_key: bool,
    auto_increment: bool,
    default: ?[]const u8,
    comment: ?[]const u8,
};
```

`ResolvedAst` → `TypedAst` 转换负责方言无关的类型解析，`TypedAst` → SQL 负责纯输出。

### Phase 3：P2 可扩展性（~12h，按需）

#### 3a. Parser 重构为递归下降

将 `parseField` 的 10 分支 if-else 拆为独立的 token 匹配函数：

```zig
fn parseFieldTokens(self: *Parser, tokens: []const []const u8, ...) !Field {
    var parser = FieldParser.init(tokens);
    while (parser.hasMore()) {
        if (parser.tryParseFusedTypeModifier()) |r| { ... }
        else if (parser.tryParsePlainType()) |r| { ... }
        else if (parser.tryParseEnum()) |r| { ... }
        else if (parser.tryParseCheck()) |r| { ... }
        else if (parser.tryParseFk()) |r| { ... }
        else if (parser.tryParseModifier()) |r| { ... }
        else if (parser.tryParseDefault()) |r| { ... }
        else { parser.warn("unrecognized token"); }
    }
}
```

#### 3b. Semantic Pass 管理器

```zig
pub const SemanticPass = struct {
    name: []const u8,
    run: *const fn (self: *SemanticAnalyzer, ast: *ResolvedAst) anyerror!void,
};

const DEFAULT_PASSES = [_]SemanticPass{
    .{ .name = "template_resolution", .run = resolveTemplates },
    .{ .name = "autofk", .run = inferAutoFk },
    .{ .name = "suffix_inference", .run = inferSuffixTypes },
};
```

#### 3c. 插件钩子（远期）

在编译流水线中暴露 hook points：

```zig
pub const CompilerHook = struct {
    on_parsed: ?*const fn (ast: Ast) ?Ast = null,       // AST 变换
    on_resolved: ?*const fn (resolved: ResolvedAst) ?ResolvedAst = null,
    on_codegen: ?*const fn (sql: []const u8) ?[]const u8 = null, // SQL 后处理
};
```

---

## 测试策略

每个 Phase 完成后：

| 阶段 | 验证方式 |
|------|----------|
| Phase 1 | 现有 180 测试全过 + 新增 re-export 移除后的编译检查 |
| Phase 2a | 新增 CLI 参数解析单元测试（10+ 用例） |
| Phase 2b | 现有 golden-file 全过（重构不改行为） |
| Phase 2c | 新增 Diagnostic JSON 输出测试 |
| Phase 2d | 新增 TypedAst 生成测试 + 与现有 codegen 输出对比 |
| Phase 3 | 现有 golden-file 全过 + 新增 parser 单元测试 |

---

## 里程碑

| 版本 | 内容 | 预计工时 |
|------|------|----------|
| v0.4.3 | P0 清理 + P1-1 CLI 重构 | 4h |
| v0.4.4 | P1-2 DialectBackend + P1-3 Diagnostic | 8h |
| v0.5.0 | P1-4 IR 层 + P2-1 Parser 重构 | 12h |
| v0.6.0 | P2-2 Pass 管理器 + P2-3 插件钩子 | 12h |

---

## 不做什么

- **不重写整个项目** — 当前架构 90 分，增量改进即可
- **不引入外部依赖** — 零依赖是核心优势
- **不做 GUI/Web 界面** — CLI 是正确的产品形态
- **不做 ORM 代码生成** — IR 层为它铺路，但不在此版本实现
