const std = @import("std");

// ─── Re-export hub ────────────────────────────────────────────
// All pipeline logic has been split into dedicated modules.
// This file re-exports them for backward compatibility.

pub const compilePipeline = @import("pipeline/forward.zig").compilePipeline;
pub const compileToAst = @import("pipeline/forward.zig").compileToAst;
pub const handleCompile = @import("pipeline/forward.zig").handleCompile;
pub const handleCompileJsonSchema = @import("pipeline/forward.zig").handleCompileJsonSchema;
pub const PipelineResult = @import("pipeline/forward.zig").PipelineResult;

pub const handleDiff = @import("pipeline/diff.zig").handleDiff;
pub const handleMigrate = @import("pipeline/diff.zig").handleMigrate;

pub const handleReverse = @import("pipeline/reverse.zig").handleReverse;
pub const detectSqlDialect = @import("pipeline/reverse.zig").detectSqlDialect;

pub const readStdin = @import("io.zig").readStdin;
pub const readFileOrStdin = @import("io.zig").readFileOrStdin;
pub const writeOutput = @import("io.zig").writeOutput;
