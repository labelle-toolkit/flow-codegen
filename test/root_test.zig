//! Tests for the `flow_codegen` sub-package — the `.flow.jsonc`
//! parser and the graph-to-Zig codegen pass (RFC-FLOWS-JSONC.md).
//!
//! BDD-style tests using `zspec`, mirroring the convention in
//! `labelle-gfx`'s `spatial_grid` sub-package.
//!
//! This file is a thin aggregator (flow-codegen#41): each top-level
//! test struct lives in its own `test/<feature>_test.zig` and is
//! re-exported here so `zspec.runAll(@This())` picks it all up. Shared
//! imports and helpers live in `test/helpers.zig`.

const std = @import("std");
const zspec = @import("zspec");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;

test {
    zspec.runAll(@This());
}

// ---------------------------------------------------------------------
// Per-feature test files (flow-codegen#41).
// ---------------------------------------------------------------------

/// Golden-file tests for the Call → CustomNode converter
/// (flow-codegen#18). Lives in its own file under `test/` for
/// readability; re-exported here so `zspec.runAll` picks it up.
pub const CallToCustomNodeTests = @import("call_to_customnode_test.zig").CallToCustomNodeTests;

pub const JsoncTests = @import("jsonc_test.zig").JsoncTests;
pub const FlowIoTests = @import("flow_io_test.zig").FlowIoTests;
pub const FlowCodegenTests = @import("codegen_test.zig").FlowCodegenTests;
pub const SubflowTests = @import("subflow_test.zig").SubflowTests;
pub const FlowVocabularyTests = @import("vocabulary_test.zig").FlowVocabularyTests;
pub const CustomNodeTests = @import("customnode_test.zig").CustomNodeTests;
pub const CoercionTests = @import("coercion_test.zig").CoercionTests;

/// String-formatting + value-helper reporter nodes (flow-codegen#26):
/// `Format` / `Concat` / `IntToString` / `FloatToString`.
pub const StringNodeTests = @import("string_nodes_test.zig").StringNodeTests;

/// Input REPORTER nodes (labelle-gui#208): `IsKeyDown` / `IsKeyPressed` /
/// `IsKeyReleased` / `IsMouseButtonDown` / `IsMouseButtonPressed` /
/// `IsMouseButtonReleased` / `GetMouseX` / `GetMouseY` / `GetMouseWheel`.
/// Plus the gamepad reporters (labelle-assembler#250 Phase 3):
/// `IsGamepadButtonDown` / `IsGamepadButtonPressed` /
/// `IsGamepadButtonReleased` / `GetGamepadAxisValue`.
pub const InputReporterTests = @import("input_reporters_test.zig").InputReporterTests;

/// Time exec-gate nodes (flow-codegen#47): `Once` / `Cooldown`.
pub const TimeGateTests = @import("time_gate_test.zig").TimeGateTests;

/// Deferred-subflow exec node (flow-codegen#48, Stage 2 of #25): `Delay`.
pub const DelayTests = @import("delay_test.zig").DelayTests;

// =====================================================================
// Codegen validation — flows that parse cleanly but would otherwise
// emit Zig that fails to compile (PR #6 review follow-up)
// =====================================================================

/// Unlike the suites above, these build each `flow_io.Flow` directly
/// with a `zspec` factory rather than parsing JSONC: the concern is
/// purely how `renderFlowFile` lowers a structurally-valid graph, so
/// the parser is deliberately kept out of the loop.
pub const CodegenValidationTests = zspec.context("codegen rejects flows that would emit invalid Zig", struct {
    /// `flow_io.Flow` factory — an empty `.subgraph` flow by default;
    /// each test overrides only the fields under test. The factory
    /// supplies every field (it does not fall back to struct field
    /// defaults), so `params` / `nodes` / `edges` default to empty.
    const FlowFactory = zspec.Factory.define(flow_io.Flow, .{
        .name = "flow",
        .event = flow_io.Event{ .subgraph = {} },
        .params = &.{},
        .variables = &.{},
        .locals = &.{},
        .collections = &.{},
        .nodes = &.{},
        .edges = &.{},
        .exec_edges = &.{},
    });

    /// Assert `src` is syntactically valid Zig — generated code must
    /// compile. Mirrors the `std.zig.Ast.parse` check used elsewhere.
    fn expectParses(allocator: std.mem.Allocator, src: []const u8) !void {
        const z = try allocator.allocSentinel(u8, src.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..src.len], src);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{src});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "sanitizes param names in the emitted signature" {
        const allocator = std.testing.allocator;
        // `hit-points` is not a valid Zig identifier — it must
        // sanitize consistently in the `fn` signature and the `Param`
        // node read so the emitted source compiles.
        var params = [_]flow_io.Param{
            .{ .name = "hit-points", .type = "f32", .default = .{ .zig_text = "1.0" } },
        };
        var nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Param = .{ .param = "hit-points" } } },
            .{ .id = 2, .pos = .{ 0, 0 }, .kind = .{ .Output = .{ .name = "out" } } },
        };
        var edges = [_]flow_io.Edge{
            .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "value" } },
        };
        const flow = FlowFactory.build(.{
            .name = "sanitize_param",
            .params = &params,
            .nodes = &nodes,
            .edges = &edges,
        });

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(flow);

        const out = try flow_codegen.renderFlowFile(allocator, flow, &reg, .{ .flow_name = "sanitize_param" });
        defer allocator.free(out);
        try expect.toContain(out, "pub fn onCall(game: anytype, hit_points: f32) f32 {");
        try expect.toContain(out, "const n1_value = hit_points;");
        try expectParses(allocator, out);
    }

    test "rejects a param colliding with the fixed game parameter" {
        const allocator = std.testing.allocator;
        // A param named `game` would emit `fn (game: anytype, game: f32)`
        // — duplicate parameter identifiers, which Zig rejects.
        var params = [_]flow_io.Param{.{ .name = "game", .type = "f32" }};
        const flow = FlowFactory.build(.{ .name = "param_clash", .params = &params });

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(flow);

        try std.testing.expectError(
            error.ParamNameCollision,
            flow_codegen.renderFlowFile(allocator, flow, &reg, .{ .flow_name = "param_clash" }),
        );
    }

    test "allows a subgraph param named `dt` (no implicit lifecycle arg reservation)" {
        const allocator = std.testing.allocator;
        // Post-Phase 6 (RFC-FLOW-VOCABULARY) the lifecycle dt/entity
        // args are gone; a `.subgraph` entry emits `fn (game,
        // <params>)`, so a param named `dt` is a regular param — no
        // implicit reservation, no collision.
        var sub_params = [_]flow_io.Param{
            .{ .name = "dt", .type = "f32", .default = .{ .zig_text = "0.016" } },
        };
        var sub_nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Param = .{ .param = "dt" } } },
            .{ .id = 2, .pos = .{ 0, 0 }, .kind = .{ .Output = .{ .name = "out" } } },
        };
        var sub_edges = [_]flow_io.Edge{
            .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "value" } },
        };
        const sub = FlowFactory.build(.{
            .name = "tick_helper",
            .event = flow_io.Event{ .subgraph = {} },
            .params = &sub_params,
            .nodes = &sub_nodes,
            .edges = &sub_edges,
        });
        var entry_nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Subflow = .{ .flow = "tick_helper" } } },
        };
        const entry = FlowFactory.build(.{
            .name = "uses_tick_helper",
            .event = flow_io.Event{ .subgraph = {} },
            .nodes = &entry_nodes,
        });

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(sub);
        try reg.add(entry);

        const out = try flow_codegen.renderFlowFile(allocator, entry, &reg, .{ .flow_name = "uses_tick_helper" });
        defer allocator.free(out);
        // The subgraph `fn` takes only `game` + its declared `dt`.
        try expect.toContain(out, "fn tick_helper(game: anytype, dt: f32) f32 {");
        try expectParses(allocator, out);
    }

    test "rejects a subgraph whose name sanitizes to the bare underscore" {
        const allocator = std.testing.allocator;
        // A flow named `-` sanitizes to `_`, which Zig reserves as the
        // discard identifier and rejects as a `fn` name.
        const sub = FlowFactory.build(.{ .name = "-" });
        var entry_nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Subflow = .{ .flow = "-" } } },
        };
        const entry = FlowFactory.build(.{ .name = "uses_underscore", .nodes = &entry_nodes });

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(sub);
        try reg.add(entry);

        try std.testing.expectError(
            error.InvalidFlowName,
            flow_codegen.renderFlowFile(allocator, entry, &reg, .{ .flow_name = "uses_underscore" }),
        );
    }

    test "rejects an entity-scoped node in a subgraph entry flow with no entity-pin wire" {
        const allocator = std.testing.allocator;
        // A `.subgraph` entry is a subgraph in its own right (RFC §3/§6)
        // — no `entity` in scope. An entity-scoped node without a wire
        // on its `entity` input pin (RFC-PLUGIN-EVENTS §9) is
        // `DanglingPin`. Replaces the v1 blanket
        // `EntityUnavailableInSubgraph`.
        var nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .GetComponent = .{ .type = "Health" } } },
        };
        const flow = FlowFactory.build(.{ .name = "oncall_entity", .nodes = &nodes });

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(flow);

        try std.testing.expectError(
            error.DanglingPin,
            flow_codegen.renderFlowFile(allocator, flow, &reg, .{ .flow_name = "oncall_entity" }),
        );
    }
});
