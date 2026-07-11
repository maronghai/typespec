# TypeSpec v0.4.3 Upgrade Trace

> Auto-generated tracking file for architecture improvements.

## Phase 1: P0 Cleanup ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| P0-1 | Delete parser.zig re-exports (lines 6-24) | ✅ | Added 17 local type aliases in parser.zig; no callers affected |
| P0-2 | Fix readStdin error swallowing | ✅ | `catch {}` → `catch |e| { if (len==0) return e; }` |
| P0-3 | Move generateCheckExpr to Codegen | ✅ | Made it `pub fn` method; updated migrate.zig caller |

## Phase 2: P1 Architecture ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| P1-1 | CLI argument parsing refactor | ✅ | Command union + parseArgs() + dispatch() pattern |
| P1-2 | DialectBackend vtable interface | ✅ | New `dialect.zig` with 11 fn pointers per backend; codegen delegates via `self.backend.*()` |
| P1-3 | Diagnostic structured output | ✅ | Added `formatJson` and `formatTerminal` to DiagnosticCollector |
| P1-4 | IR layer (TypedAst) | ✅ | New `typed_ast.zig` with TypedAst/TypedTable/TypedColumn; TypeResolver + Codegen.generateFromTypedAst() |

## Phase 3: P2 Extensibility ✅

| # | Item | Status | Notes |
|---|------|--------|-------|
| P2-2 | Semantic pass manager | ✅ | PassContext + SemanticPass structs; DEFAULT_PASSES array; runAutoFk/runSuffixInference as registered passes |

## Summary

- **Started**: 2026-07-11
- **Completed**: 2026-07-11
- **Tests**: 181/181 passing (81 MySQL + 93 PG + 1 SQLite + 6 Migrate)
- **New files**: `dialect.zig`, `typed_ast.zig`
- **Modified files**: `parser.zig`, `main.zig`, `codegen.zig`, `diagnostic.zig`, `semantic.zig`, `migrate.zig`

## Architecture After Upgrade

```
tps → Tokenizer → Parser → Ast → Semantic → ResolvedAst
                                              ↓
                                         PassManager
                                         ├─ autofk
                                         └─ suffix_inference
                                              ↓
                                         ResolvedAst → TypeResolver → TypedAst (IR)
                                              ↓                              ↓
                                         Codegen.generate()     Codegen.generateFromTypedAst()
                                              ↓                              ↓
                                         DialectBackend                    SQL
                                         ├─ mysql_backend
                                         ├─ pg_backend
                                         └─ sqlite_backend
                                              ↓
                                            SQL
```

### Key Design Decisions

1. **DialectBackend**: Function pointer vtable in `dialect.zig`; adding a new dialect = 1 enum variant + 1 backend instance (11 functions)
2. **TypedAst IR**: ResolvedAst → TypedAst resolves types to concrete SQL strings; TypedAst → SQL is pure output
3. **Pass Manager**: PassContext holds mutable tables; new passes implement `fn(*PassContext) !void` and register in DEFAULT_PASSES
4. **DiagnosticCollector**: `formatJson` for LSP integration, `formatTerminal` for human output
