// ─── Dialect Enum ───────────────────────────────────────────────
// Single source of truth for supported SQL dialects.
// Imported by: type_map, dialect, sql_parser_common, codegen, typed_ast.

pub const Dialect = enum { mysql, pg, sqlite };
