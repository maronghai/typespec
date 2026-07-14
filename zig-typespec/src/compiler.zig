const std = @import("std");

// ─── Re-export hub ────────────────────────────────────────────
// All pipeline logic has been split into dedicated modules.
// This file re-exports them for backward compatibility.

pub const compilePipeline = @import("pipeline_forward.zig").compilePipeline;
pub const compileToAst = @import("pipeline_forward.zig").compileToAst;
pub const handleCompile = @import("pipeline_forward.zig").handleCompile;
pub const PipelineResult = @import("pipeline_forward.zig").PipelineResult;

pub const handleDiff = @import("pipeline_diff.zig").handleDiff;
pub const handleMigrate = @import("pipeline_diff.zig").handleMigrate;

pub const handleReverse = @import("pipeline_reverse.zig").handleReverse;
pub const detectSqlDialect = @import("pipeline_reverse.zig").detectSqlDialect;

pub const readStdin = @import("io.zig").readStdin;
pub const readFileOrStdin = @import("io.zig").readFileOrStdin;
pub const writeOutput = @import("io.zig").writeOutput;
