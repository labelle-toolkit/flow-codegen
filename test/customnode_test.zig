//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;

pub const CustomNodeTests = struct {
    /// Build a `CustomNodeRegistry` populated with `(dotted, qualified,
    /// is_void)` triples. Caller owns the returned registry.
    fn buildRegistry(
        allocator: std.mem.Allocator,
        entries: []const struct { dotted: []const u8, qualified: []const u8, is_void: bool },
    ) !flow_codegen.CustomNodeRegistry {
        var reg = flow_codegen.CustomNodeRegistry.init(allocator);
        errdefer reg.deinit();
        for (entries) |e| {
            try reg.add(e.dotted, .{ .qualified = e.qualified, .is_void = e.is_void });
        }
        return reg;
    }

    test "round-trips a CustomNode through renderFlowJsonc" {
        // RFC-FLOW-VOCABULARY §1 — on-disk shape `{ "type":
        // "CustomNode", "name": "<dotted>", "pos": [...] }`. The parser,
        // validator, and writer all agree on the one-field payload.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "uses_custom",
            \\  "nodes": [
            \\    { "id": 1, "type": "CustomNode", "name": "box2d.apply_impulse", "pos": [120, 40] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .CustomNode);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.CustomNode.name, "box2d.apply_impulse"));

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);

        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .CustomNode);
        try expect.toBeTrue(std.mem.eql(u8, roundtrip.flow.nodes[0].kind.CustomNode.name, "box2d.apply_impulse"));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "rejects a CustomNode with no name field" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [ { "id": 1, "type": "CustomNode", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "rejects a CustomNode with an empty name" {
        // Validation rule: any non-empty name is accepted at parse time;
        // codegen resolves it against the registry. An empty name is
        // structurally malformed — no plugin can declare a zero-length
        // dotted entry.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [ { "id": 1, "type": "CustomNode", "name": "", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "codegen lowers a value-returning CustomNode (reporter form)" {
        // The impl returns a value — codegen binds the result to
        // `n<id>_value` so downstream pins can wire from it.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "reporter_use",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 3, "type": "CustomNode", "name": "my_helpers.score", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "arg1" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "my_helpers.score", .qualified = "my_helpers__score", .is_void = false },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "reporter_use", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        // Reporter shape: binds result to `n3_value`, qualified decl
        // path, both arg pins resolve to their wired producers.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = __flowReport(@TypeOf(game_mod.PluginFlowNodes.my_helpers__score).impl, .{ game, n1_value, n2_value });") != null);
    }

    test "codegen lowers a void-returning CustomNode (command form)" {
        // The impl returns void — codegen emits a bare statement, no
        // `const n<id>_value = ...` binding.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "command_use",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 42, "pos": [0, 0] },
            \\    { "id": 2, "type": "CustomNode", "name": "box2d.apply_impulse", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "box2d.apply_impulse", .qualified = "box2d__apply_impulse", .is_void = true },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "command_use", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        // Command shape: bare statement (no `const n2_value =` binding),
        // routed through the `__flowCommand` error-policy adapter (#27).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__flowCommand(@TypeOf(game_mod.PluginFlowNodes.box2d__apply_impulse).impl, .{ game, n1_value });") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value =") == null);
        // No discard line — there is no `n2_value` to discard.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = n2_value;") == null);
    }

    test "codegen rejects unknown CustomNode name with UnknownFlowNode" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "unknown_use",
            \\  "nodes": [
            \\    { "id": 1, "type": "CustomNode", "name": "nonexistent.thing", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        // Empty registry — every reference is unknown.
        var reg = flow_codegen.CustomNodeRegistry.init(allocator);
        defer reg.deinit();

        try std.testing.expectError(
            error.UnknownFlowNode,
            flow_codegen.renderFlowZig(
                allocator,
                loaded.flow,
                .{ .flow_name = "unknown_use", .custom_nodes = &reg },
            ),
        );
    }

    test "codegen rejects CustomNode when no registry is supplied" {
        // `custom_nodes = null` means "no registry" — every CustomNode
        // reference is unknown. Same diagnostic as an empty registry.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "no_reg",
            \\  "nodes": [
            \\    { "id": 1, "type": "CustomNode", "name": "box2d.apply_impulse", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        try std.testing.expectError(
            error.UnknownFlowNode,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "no_reg" }),
        );
    }

    test "Event + CustomNode flow emits FlowEventHandler + plugin call" {
        // RFC integration — an `Event` node trigger + a value-returning
        // `CustomNode` lower together: the handler struct is emitted as
        // for any new-form `OnEvent` flow, and the body inlines the
        // plugin call.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "log_hits",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
            \\    { "id": 2, "type": "CustomNode", "name": "my_helpers.log_it", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "my_helpers.log_it", .qualified = "my_helpers__log_it", .is_void = true },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "log_hits", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        // The handler struct + dispatch method are emitted as usual.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub const FlowEventHandler = struct") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn box2d__collision_begin(self: *@This()") != null);
        // The void CustomNode body — command adapter, no result binding.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__flowCommand(@TypeOf(game_mod.PluginFlowNodes.my_helpers__log_it).impl, .{ game });") != null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "value-returning CustomNode chains into a downstream consumer" {
        // The reporter shape is "useful" precisely because its result
        // can be wired into another node. Confirm the chain compiles:
        // CustomNode → BinOp → discard.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "chain",
            \\  "nodes": [
            \\    { "id": 1, "type": "CustomNode", "name": "my_helpers.score", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 10, "pos": [0, 0] },
            \\    { "id": 3, "type": "BinOp", "op": "add", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "my_helpers.score", .qualified = "my_helpers__score", .is_void = false },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "chain", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = __flowReport(@TypeOf(game_mod.PluginFlowNodes.my_helpers__score).impl, .{ game });") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = n1_value + n2_value;") != null);
    }

    // RFC-FLOW-VOCABULARY §3 Migration — the v1 → v2 converter tests
    // (`convertLegacyV1ToV2`, `convertLegacyFile`) and the
    // `NonOnEventLegacyHeader` error were retired in Phase 6 alongside
    // the legacy `event:` header itself. Event-driven flows are
    // authored directly as in-graph `Event` nodes; no rewrite path
    // exists or is needed.

    test "value-returning CustomNode with no consumer emits a discard" {
        // RFC §6 — the reporter shape binds `n<id>_value`. If no
        // downstream edge consumes it, `discardUnconsumedResult` adds
        // `_ = n<id>_value;` so Zig doesn't surface an "unused local
        // constant" error against the codegen output.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "unused_reporter",
            \\  "nodes": [
            \\    { "id": 1, "type": "CustomNode", "name": "my_helpers.score", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "my_helpers.score", .qualified = "my_helpers__score", .is_void = false },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "unused_reporter", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = __flowReport(@TypeOf(game_mod.PluginFlowNodes.my_helpers__score).impl, .{ game });") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = n1_value;") != null);
    }

    test "fallible !void command lowers through the __flowCommand adapter" {
        // flow-codegen#27 — a plugin command `impl` commonly returns
        // `!void`. flow-codegen can't see the return type (it works off a
        // string registry), so a `void`-classified CustomNode is lowered
        // through the `__flowCommand` comptime adapter, which applies the
        // best-effort log-and-continue policy iff the impl is fallible and
        // otherwise calls it directly (the error branch is comptime-
        // eliminated). Emitting a bare `impl(game, …);` instead would be a
        // raw "unhandled error union" Zig compile error for a `!void` impl.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "fallible_command",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 42, "pos": [0, 0] },
            \\    { "id": 2, "type": "CustomNode", "name": "box2d.apply_impulse", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "box2d.apply_impulse", .qualified = "box2d__apply_impulse", .is_void = true },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "fallible_command", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        // The call routes through the command adapter (no result binding).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__flowCommand(@TypeOf(game_mod.PluginFlowNodes.box2d__apply_impulse).impl, .{ game, n1_value });") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value =") == null);
        // The adapter is emitted, with the best-effort log-and-continue
        // policy for the fallible branch.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "inline fn __flowCommand(comptime f: anytype, args: anytype) void {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "@call(.auto, f, args) catch |__err|") != null);
        // The whole generated file (adapters + call site) is valid Zig
        // through AstGen, not merely parseable.
        try helpers.expectAstGenOk(allocator, out);
    }

    test "fallible !T reporter lowers through the __flowReport adapter" {
        // flow-codegen#27 — a reporter `impl` returning `!T` binds an error
        // union to `n<id>_value`; downstream pins can't consume `!T` and an
        // unwrapped error union won't compile. The `__flowReport` adapter
        // applies the fail-fast unwrap policy (a missing value can't feed
        // downstream pins) so the reporter compiles under a defined policy;
        // its return type (`__FlowNodePayload`) is the error union's payload.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "fallible_reporter",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 2, "type": "CustomNode", "name": "my_helpers.roll", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 4, "type": "BinOp", "op": "add", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 4, "pin": "a" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "b" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        var reg = try buildRegistry(allocator, &.{
            .{ .dotted = "my_helpers.roll", .qualified = "my_helpers__roll", .is_void = false },
        });
        defer reg.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "fallible_reporter", .custom_nodes = &reg },
        );
        defer allocator.free(out);

        // The reporter binds the adapter's unwrapped result and chains into
        // the downstream BinOp — proving the value is a plain `T`, not `!T`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value = __flowReport(@TypeOf(game_mod.PluginFlowNodes.my_helpers__roll).impl, .{ game, n1_value });") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n4_result = n2_value + n3_value;") != null);
        // The reporter adapter + its payload-type helper are emitted with
        // the fail-fast unwrap policy.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "inline fn __flowReport(comptime f: anytype, args: anytype) __FlowNodePayload(f) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "std.debug.panic(\"flow reporter node failed") != null);
        try helpers.expectAstGenOk(allocator, out);
    }
};
