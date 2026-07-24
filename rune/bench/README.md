# Rune Benchmark

Measures per-stage latency for the forward pipeline (tokenize → parse → semantic → type_resolve → codegen).

## Usage

```bash
zig build bench                              # default: bench/small.ss, 10 iterations
zig build bench -- bench/medium.ss 20       # custom file and iteration count
zig build bench -- bench/large.ss 5         # large schema benchmark
```

## Schema Sizes

| File | Tables | Fields | Description |
|------|--------|--------|-------------|
| `small.ss` | 6 | ~30 | Blog-like schema (user, post, comment, tag) |
| `medium.ss` | 21 | ~200 | Project management (users, projects, issues, PRs) |
| `large.ss` | 32 | ~400 | Enterprise platform (tenants, tasks, sprints, audits) |

## Output

JSON format with per-stage timing in milliseconds:

```json
{
  "file": "bench/small.ss",
  "iterations": 10,
  "stages": {
    "tokenize": 0.16,
    "parse": 0.14,
    "semantic": 0.10,
    "type_resolve": 0.05,
    "codegen": 0.05
  },
  "total_ms": 0.50
}
```
