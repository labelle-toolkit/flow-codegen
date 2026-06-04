//! Tests for the `flow_codegen` sub-package — the `.flow.jsonc`
//! parser and the graph-to-Zig codegen pass (RFC-FLOWS-JSONC.md).
//!
//! BDD-style tests using `zspec`, mirroring the convention in
//! `labelle-gfx`'s `spatial_grid` sub-package.

const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const flow_codegen_pkg = @import("flow_codegen");

const flow_io = flow_codegen_pkg.flow_io;
const flow_codegen = flow_codegen_pkg.codegen;

/// Golden-file tests for the Call → CustomNode converter
/// (flow-codegen#18). Lives in its own file under `test/` for
/// readability; re-exported here so `zspec.runAll` picks it up.
pub const CallToCustomNodeTests = @import("call_to_customnode_test.zig").CallToCustomNodeTests;

test {
    zspec.runAll(@This());
}

// =====================================================================
// JSONC preprocessor
// =====================================================================

pub const JsoncTests = struct {
    const jsonc = flow_codegen_pkg.jsonc;

    test "strips line comments and trailing commas, ignores string content" {
        const a = std.testing.allocator;
        const out = try jsonc.strip(a, "{ \"u\": \"a//b\", \"n\": 1, } // end\n");
        defer a.free(out);
        // The `//` inside the string survives; the trailing `,` and
        // the line comment become spaces.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "\"a//b\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "// end") == null);
    }
};

// =====================================================================
// flow_io — parsing the flat .flow.jsonc schema
// =====================================================================

pub const FlowIoTests = struct {
    const minimal_on_update =
        \\{
        \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] } ],
        \\  "edges": []
        \\}
    ;

    test "parses minimal flow with engine.tick Event node" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator, minimal_on_update);
        defer loaded.deinit();

        // Post-Phase 6 (RFC-FLOW-VOCABULARY): the trigger lives as an
        // in-graph `Event` node; `buildFlow` synthesizes the `OnEvent`
        // event for downstream consumers (assembler `flow_scanner`).
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.event.OnEvent.name.?, "engine.tick"));
        // The minimal source has a single Event node, no other nodes.
        try expect.equal(loaded.flow.nodes.len, 1);
        try expect.equal(loaded.flow.edges.len, 0);
    }

    test "parses JSONC with comments and trailing commas" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  // entry point
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "1.5", "pos": [0, 0] }, /* a node */
            \\  ],
            \\  "edges": [],
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        // Two nodes — the Event-node trigger + the in-graph Literal.
        try expect.equal(loaded.flow.nodes.len, 2);
    }

    test "parses each flat NodeKind variant" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetField", "target": "Position.x", "pos": [0, 0] },
            \\    { "id": 3, "type": "BinOp", "op": "mul", "pos": [0, 0] },
            \\    { "id": 4, "type": "Literal", "value": "1.5", "pos": [0, 0] },
            \\    { "id": 5, "type": "Identifier", "name": "speed", "pos": [0, 0] },
            \\    { "id": 6, "type": "Call", "callee": "std.math.sin", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        // Seven nodes — the Event-node trigger + the six declared kinds.
        try expect.equal(loaded.flow.nodes.len, 7);
        // The migration inserts the Event node at index 0; the
        // declared-kind nodes follow in their source order.
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .Event);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .GetComponent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.GetComponent.type, "Position"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[2].kind), .SetField);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[3].kind), .BinOp);
        try expect.equal(loaded.flow.nodes[3].kind.BinOp.op, .mul);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[4].kind), .Literal);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[6].kind), .Call);
    }

    test "parses top-level params and Param/Output/Subflow nodes" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "combat",
            \\  "event": { "type": "OnCall" },
            \\  "params": [
            \\    { "name": "damage", "type": "f32", "default": 10.0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "damage", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "dealt", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.name, "combat"));
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnCall);
        try expect.equal(loaded.flow.params.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.params[0].name, "damage"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.params[0].type, "f32"));
        try expect.toBeTrue(loaded.flow.params[0].default != null);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .Param);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .Output);
    }

    test "parses Subflow node with bindings" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 7, "type": "Subflow", "flow": "combat", "bindings": { "damage": 25.0 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        // nodes[0] is the Event trigger; nodes[1] is the Subflow.
        const sf = loaded.flow.nodes[1].kind.Subflow;
        try expect.toBeTrue(std.mem.eql(u8, sf.flow, "combat"));
        try expect.equal(sf.bindings.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, sf.bindings[0].param, "damage"));
        try expect.toBeTrue(std.mem.eql(u8, sf.bindings[0].value.zig_text, "25"));
    }

    test "parses each lifecycle Event variant via in-graph Event nodes" {
        // Phase 6 (RFC-FLOW-VOCABULARY): the lifecycle event-driven
        // trigger ships as an in-graph `Event` node referencing one of
        // the engine-emitted names (`engine.entity_created`,
        // `engine.entity_destroyed`, etc.). The parser synthesizes
        // `Flow.event = .{ .OnEvent = .{ .name = ... } }`.
        const allocator = std.testing.allocator;

        const on_create =
            \\{ "nodes": [ { "id": 1, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] } ], "edges": [] }
        ;
        var l1 = try flow_io.parseFlow(allocator, on_create);
        defer l1.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l1.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.event.OnEvent.name.?, "engine.entity_created"));

        const on_destroy =
            \\{ "nodes": [ { "id": 1, "type": "Event", "name": "engine.entity_destroyed", "pos": [0, 0] } ], "edges": [] }
        ;
        var l2 = try flow_io.parseFlow(allocator, on_destroy);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnEvent.name.?, "engine.entity_destroyed"));
    }

    test "parses an Event-node-form flow with the name field" {
        const allocator = std.testing.allocator;
        // Post-Phase 6: the trigger is an in-graph `Event` node;
        // `buildFlow` synthesizes the `OnEvent` event for downstream
        // consumers (assembler `flow_scanner`).
        const src =
            \\{
            \\  "nodes": [ { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnEvent);
        const ev = loaded.flow.event.OnEvent;
        try expect.toBeTrue(std.mem.eql(u8, ev.name.?, "box2d.collision_begin"));
    }

    test "round-trips an Event-node-form flow through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "on_collision",
            \\  "nodes": [ { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnEvent.name.?, "box2d.collision_begin"));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    // Phase 6 (RFC-FLOW-VOCABULARY) — the legacy `event: { "type":
    // "OnEvent", ... }` header form was retired alongside the lifecycle
    // headers; the only event source is now an in-graph `Event` node.
    // The previously-here `rejects an OnEvent` tests (retired
    // `module` / `callback` / `params` keys, bare `OnEvent` with no
    // name, priority-on-header behaviour) are no longer reachable —
    // every event-driven flow goes through the Event-node path which
    // has its own schema (`name` only).

    // Phase 6 (RFC-FLOW-VOCABULARY) — the `priority` field was only
    // settable on the legacy `event:` header (RFC-PLUGIN-EVENTS O4 /
    // phase 7). With the header retired, priority can no longer be
    // set from `.flow.jsonc`; the field remains on `Event.OnEvent` for
    // assembler compatibility but reads `null` for every parsed flow.
    // The on-disk priority tests have been removed; if priority gains
    // a graph-form expression later, new tests cover that schema.

    test "parses and round-trips an Emit node" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §8: an `Emit` node fires a custom event by
        // dotted name. The parser accepts it; codegen lowering is
        // deferred until the assembler's resolver lands.
        const src =
            \\{
            \\  "name": "emitter",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Emit", "event": "my_game.player_attacked", "pos": [400, 200] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), l1.flow.nodes[0].kind), .Emit);
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.nodes[0].kind.Emit.event, "my_game.player_attacked"));

        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), l2.flow.nodes[0].kind), .Emit);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.nodes[0].kind.Emit.event, "my_game.player_attacked"));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "rejects an Emit node with no event field" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Emit", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "rejects unknown node type" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Nonsense", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.UnknownNodeType, flow_io.parseFlow(allocator, src));
    }

    test "rejects unknown event type" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "event": { "type": "OnExplode" }, "nodes": [], "edges": [] }
        ;
        try std.testing.expectError(error.UnknownEventType, flow_io.parseFlow(allocator, src));
    }

    test "rejects malformed JSONC" {
        const allocator = std.testing.allocator;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, "{ not json"));
    }

    test "rejects duplicate node IDs" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Identifier", "name": "a", "pos": [0, 0] },
            \\    { "id": 1, "type": "Identifier", "name": "b", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.DuplicateNodeId, flow_io.parseFlow(allocator, src));
    }

    test "rejects edge to nonexistent node" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [ { "id": 50, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Identifier", "name": "a", "pos": [0, 0 ] } ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 99, "pin": "y" } } ]
            \\}
        ;
        try std.testing.expectError(error.DanglingLink, flow_io.parseFlow(allocator, src));
    }

    test "rejects a node targeted by two exec edges (ambiguous scope, flow-codegen#8)" {
        const allocator = std.testing.allocator;
        // Node 9 is wired to BOTH the branch's `then` and `else` — its
        // control scope is ambiguous, so the loader rejects it.
        const src =
            \\{
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 4, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 9, "type": "ClearVariable", "name": "x", "pos": [0, 0] }
            \\  ],
            \\  "variables": [ { "name": "x", "type": "?i32", "default": null } ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 9 } },
            \\    { "from": { "node": 4, "pin": "else" }, "to": { "node": 9 } }
            \\  ]
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "rejects node id == 0" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 0, "type": "Identifier", "name": "a", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.InvalidNodeId, flow_io.parseFlow(allocator, src));
    }

    test "rejects Param node naming an undeclared parameter" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "x", "type": "f32" } ],
            \\  "nodes": [ { "id": 1, "type": "Param", "param": "y", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.UnknownParam, flow_io.parseFlow(allocator, src));
    }

    test "rejects duplicate Output names" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Output", "name": "r", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "r", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.DuplicateOutputName, flow_io.parseFlow(allocator, src));
    }

    test "rejects duplicate param names" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnCall" },
            \\  "params": [
            \\    { "name": "x", "type": "f32" },
            \\    { "name": "x", "type": "i32" }
            \\  ],
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.DuplicateParamName, flow_io.parseFlow(allocator, src));
    }

    test "displayNameFromPath strips .flow.jsonc" {
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("scripts/flows/move.flow.jsonc"),
            "move",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("/abs/path/jump.flow.jsonc"),
            "jump",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("scene.json"),
            "scene.json",
        ));
    }

    test "round-trips a flow through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "move",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "GetComponent", "component": "Position", "pos": [120, 80] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [280, 80] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "x" }, "to": { "node": 2, "pin": "a" } }
            \\  ]
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();

        try expect.toBeTrue(std.mem.eql(u8, l2.flow.name, "move"));
        // 3 nodes — Event trigger + GetComponent + BinOp.
        try expect.equal(l2.flow.nodes.len, 3);
        try expect.equal(l2.flow.edges.len, 1);

        // Idempotent re-render (RFC open question 3 — stable re-save).
        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "renderFlowJsonc emits valid JSON for string literals and defaults" {
        const allocator = std.testing.allocator;
        // A param string `default` and a `Literal` node string value
        // both carry embedded quotes / escapes. They must re-serialize
        // as JSON-escaped strings — not Zig-escaped text spliced raw,
        // which would break the JSON — and survive render→parse→render.
        const src =
            \\{
            \\  "name": "lit",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "label", "type": "[]const u8", "default": "hi \"there\"" } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "\"a\\tb\"", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        // The rendered text must itself parse — i.e. it is valid JSON.
        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(l2.flow.params.len, @as(usize, 1));

        // Idempotent re-render — the escaped literal survived intact.
        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "saveFlow + loadFromFile round trip via tmpDir" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "demo.flow.jsonc" });
        defer allocator.free(path);

        var l1 = try flow_io.parseFlow(allocator,
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Literal", "value": "1", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        );
        defer l1.deinit();

        try flow_io.saveFlow(std.testing.io, allocator, path, l1);

        var l2 = try flow_io.loadFromFile(std.testing.io, allocator, path);
        defer l2.deinit();

        // Two nodes — Event trigger + Literal.
        try expect.equal(l2.flow.nodes.len, 2);
        // loadFromFile derives the effective name from the basename.
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.name, "demo"));
    }

    // The `legacy_onevent_to_name` converter and its tests were
    // retired in RFC-PLUGIN-EVENTS phase 6 (flow-codegen#13) — the
    // legacy `module`+`callback`+`params` form no longer parses.
};

// =====================================================================
// codegen — single-flow rendering
// =====================================================================

pub const FlowCodegenTests = struct {
    fn render(allocator: std.mem.Allocator, src: []const u8, name: []const u8) ![]u8 {
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        return flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = name });
    }

    // Phase 6 (RFC-FLOW-VOCABULARY): the lifecycle entry-fn shapes
    // (`pub fn tick(game, dt)` / `pub fn onCreate(game, entity)` /
    // `pub fn onDestroy(game, entity)`) are gone. Flows formerly using
    // them now declare an in-graph `Event` node referencing the
    // engine-emitted name (`engine.tick`, `engine.entity_created`,
    // …); codegen emits a `FlowEventHandler` with a payload-typed
    // method — the entity rides `payload.entity`. The legacy
    // shape-assertion tests were removed; the FlowEventHandler shape
    // is covered by the `new-form OnEvent codegen` tests below.

    test "entry function declares top-level params so Param nodes resolve" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "damage", "type": "f32", "default": 5.0 } ],
            \\  "nodes": [ { "id": 1, "type": "Param", "param": "damage", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        , "entry_with_param");
        defer allocator.free(out);
        // The entry `pub fn` declares the param as a fn argument.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCall(game: anytype, damage: f32) void") != null);
        // The Param node reads the in-scope argument.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = damage;") != null);

        // The emitted Zig must parse.
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "renders Literal node as a const binding" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Literal", "value": "1.5", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        , "lit");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = 1.5;") != null);
    }

    test "renders BinOp with both inputs connected" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "1", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "2", "pos": [0, 0] },
            \\    { "id": 3, "type": "BinOp", "op": "sub", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } }
            \\  ]
            \\}
        , "sub");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = n1_value - n2_value;") != null);
    }

    test "renders BinOp with disconnected pins defaulting to 0" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 2, "type": "BinOp", "op": "mul", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        , "binop");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = 0 * 0;") != null);
    }

    test "renders Compare into a bool comparison (flow-codegen#7)" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "3", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "5", "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "lt", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } }
            \\  ]
            \\}
        , "cmp");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = n1_value < n2_value;") != null);
    }

    test "renders Logic and over two bool inputs (flow-codegen#7)" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "true", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "false", "pos": [0, 0] },
            \\    { "id": 3, "type": "Logic", "op": "and", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } }
            \\  ]
            \\}
        , "logic");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = n1_value and n2_value;") != null);
    }

    test "renders Logic not as a unary negation (flow-codegen#7)" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "true", "pos": [0, 0] },
            \\    { "id": 2, "type": "Logic", "op": "not", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "a" } }
            \\  ]
            \\}
        , "lnot");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = !n1_value;") != null);
    }

    test "renders GetComponent node with component @import" {
        const allocator = std.testing.allocator;
        // Post-Phase 6: Event-node-form flows have no in-scope `entity`
        // identifier — the entity pin is mandatory (RFC §9). We wire it
        // from an `Identifier` node naming `payload.entity` to mirror
        // the new-form lowering.
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 4, "type": "Identifier", "name": "payload.entity", "pos": [0, 0] },
            \\    { "id": 3, "type": "GetComponent", "component": "Position", "pos": [0, 0 ] }
            \\  ],
            \\  "edges": [ { "from": { "node": 4, "pin": "value" }, "to": { "node": 3, "pin": "entity" } } ]
            \\}
        , "get");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = game.getComponent(n4_value, Position) orelse return;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const Position = @import(\"../../components/Position.zig\").Position;") != null);
    }

    test "renders SetField sourced from a Literal" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 6, "type": "Identifier", "name": "payload.entity", "pos": [0, 0] },
            \\    { "id": 4, "type": "Literal", "value": "42", "pos": [0, 0] },
            \\    { "id": 5, "type": "SetField", "target": "Position.x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 6, "pin": "value" }, "to": { "node": 5, "pin": "entity" } },
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 5, "pin": "value" } }
            \\  ]
            \\}
        , "setf");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, n6_value, n4_value);") != null);
    }

    test "lifecycle GetComponent with a wired entity pin uses the wired expression" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §9: a wired `entity` input pin overrides
        // the in-scope `entity` identifier. The producing node here is
        // an `Identifier` that names a field of a hypothetical payload
        // (`payload.entity_a`) — `Identifier` emits its `name` text
        // verbatim, so it stands in for any future payload-field
        // accessor without coupling this test to the resolver.
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 1, "type": "Identifier", "name": "self", "pos": [0, 0] },
            \\    { "id": 2, "type": "GetComponent", "component": "Position", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "entity" } } ]
            \\}
        , "wired_get");
        defer allocator.free(out);
        // The entity argument is the wired pin's expression, not bare
        // `entity` — even though the OnCreate parameter is named
        // `self` (which would have triggered a `const entity = self;`
        // back-compat binding in the unwired case).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.getComponent(n1_value, Position)") != null);
        // No back-compat `entity` binding: every entity-scoped node
        // here wires its pin, so the lifecycle binding is suppressed.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity = self;") == null);

        // Sanity: the emitted Zig must parse.
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "lifecycle SetField with a wired entity pin uses the wired expression" {
        const allocator = std.testing.allocator;
        // Same wiring as the GetComponent case, but for SetField — the
        // entity argument moves from bare `entity` to the wired pin.
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 1, "type": "Identifier", "name": "other", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "42", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetField", "target": "Position.x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "entity" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        , "wired_set");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, n1_value, n2_value);") != null);
    }

    // Phase 6 (RFC-FLOW-VOCABULARY): the formerly-here "mixed wired /
    // unwired entity-scoped nodes" test relied on the lifecycle
    // entry-fn `entity` binding (`anyNeedsBareEntity`). With the
    // lifecycle entry path gone, every entity-scoped node in an
    // Event-node-form flow MUST wire its entity pin (RFC §9); the
    // unwired case is `DanglingPin`. The "all-wired" subcase is
    // covered by the `renders GetComponent / SetField` tests above.

    test "OnCall entry with a wired entity-pin GetComponent is allowed" {
        const allocator = std.testing.allocator;
        // An `OnCall` entry has no in-scope `entity`. RFC-PLUGIN-EVENTS
        // §9 lifts the v1 blanket-rejection: a `GetComponent` whose
        // `entity` input pin is wired is fine — the wired expression
        // is the entity argument.
        const out = try render(allocator,
            \\{
            \\  "name": "oncall_wired",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "subject", "type": "u32" } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "subject", "pos": [0, 0] },
            \\    { "id": 2, "type": "GetComponent", "component": "Position", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "entity" } } ]
            \\}
        , "oncall_wired");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.getComponent(n1_value, Position)") != null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "new-form OnEvent codegen emits a FlowEventHandler struct" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §7 phase 3 — the new form lowers to a
        // hook-handler struct (`FlowEventHandler`) whose method name
        // is the qualified tag (`box2d.collision_begin` →
        // `box2d__collision_begin`, `.` → `__`). The payload type is
        // reflected from `@FieldType(PluginEvents, "<tag>")`, the
        // dispatch method is the variant tag's identifier (matching
        // what `MergeHooks.emit` looks up on each receiver — `labelle-
        // core/src/dispatcher.zig:99-111`), and `game_ptr` is the
        // field-injection slot the engine's `setHooks` loop writes at
        // init (`labelle-engine/src/game.zig:419-429`).
        const out = try render(allocator,
            \\{
            \\  "nodes": [ { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        , "new_form_hit");
        defer allocator.free(out);

        // The mechanical `.` → `__` qualified-tag mapping (matches the
        // codegen at `labelle-assembler/src/main_zig.zig:525`).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "@FieldType(PluginEvents, \"box2d__collision_begin\")") != null);
        // The handler struct + the dispatch method named after the tag.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub const FlowEventHandler = struct") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game_ptr: *anyopaque = undefined") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn box2d__collision_begin(self: *@This(), payload: __EvPayload) void") != null);
        // The `*Game` downcast — the existing `game_ptr` contract every
        // shipped engine hook handler already uses
        // (`labelle-engine/src/game.zig:419-429`).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "@ptrCast(@alignCast(self.game_ptr))") != null);
        // No legacy `flowEvent` callback or `pub fn setup` — the new
        // form does NOT install into a `?*const fn` slot; the assembler
        // (phase 4) wires the struct into `GameHooks` receiver tuple.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn flowEvent(") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn setup(") == null);

        // Generated Zig parses cleanly.
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "new-form OnEvent codegen lifts the entity-scoped node rejection (with wired entity pin)" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §7 + §9 phase 3 — a new-form `OnEvent` flow
        // has `game` reachable through `game_ptr`, so the v1 blanket
        // rejection of `GetComponent` / `SetField` is gone. The entity
        // pin is mandatory (no lifecycle `entity` fallback), and the
        // wired `payload.entity_a` flows into the `getComponent` call.
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
            \\    { "id": 1, "type": "Identifier", "name": "payload.entity_a", "pos": [0, 0] },
            \\    { "id": 2, "type": "GetComponent", "component": "Position", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "entity" } } ]
            \\}
        , "wired_entity_pin");
        defer allocator.free(out);
        // The wired entity expression flows into the GetComponent call —
        // exactly the RFC §9 entity-pin behaviour the lifecycle path
        // already uses.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.getComponent(n1_value, Position)") != null);
    }

    test "new-form OnEvent codegen rejects an unwired entity-scoped node" {
        const allocator = std.testing.allocator;
        // RFC §9 — the entity pin is mandatory in a new-form flow.
        // Same `DanglingPin` the `OnCall` entry / `Subflow` subgraph
        // paths already raise.
        var loaded = try flow_io.parseFlow(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
            \\    { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        );
        defer loaded.deinit();
        try std.testing.expectError(
            error.DanglingPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "unwired" }),
        );
    }

    test "Emit node lowers to a buffered game.emit call" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §8 phase 3 — `Emit` lowers to a buffered
        // `game.emit(.{ .<qualified_tag> = .{ .<field> = <expr>, ... } });`
        // statement. The qualified tag uses the same mechanical `.` →
        // `__` mapping the `OnEvent` resolver uses (labelle-
        // assembler#174 / RFC §7).
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "42", "pos": [0, 0] },
            \\    { "id": 2, "type": "Emit", "event": "my_game.fired", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "attacker" } } ]
            \\}
        , "emitter");
        defer allocator.free(out);

        // Buffered (`emit`, not `emitSync`) — the default every #422
        // use site picks, and the RFC's pick to keep re-entrancy from
        // a flow body emitting mid-tick out of the picture.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.emit(.{ .my_game__fired = .{") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, ".attacker = n1_value,") != null);
        // No output pin — `Emit` is a statement, not an expression.
        // The `discardUnconsumedResult` skip and `primaryOutputPin =
        // ""` are pinned by the absence of an `_ = n2_<pin>;` line.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = n2_") == null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "Emit node with no wired pins lowers to an empty payload literal" {
        const allocator = std.testing.allocator;
        // A no-field event (e.g. a `pub const fired = struct {};`)
        // emits `game.emit(.{ .<tag> = .{} });` — the one-line shape
        // keeps diagnostics sourced against the single generated line.
        const out = try render(allocator,
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] }, { "id": 1, "type": "Emit", "event": "my_game.bare", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        , "emit_bare");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.emit(.{ .my_game__bare = .{} });") != null);
    }

    test "topo-sorts dependent nodes correctly" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 4, "type": "Identifier", "name": "payload.entity", "pos": [0, 0] },
            \\    { "id": 1, "type": "SetField", "target": "Position.x", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": "5", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 1, "pin": "entity" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 2, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "result" }, "to": { "node": 1, "pin": "value" } }
            \\  ]
            \\}
        , "topo");
        defer allocator.free(out);
        const lit = std.mem.indexOf(u8, out, "const n3_value = 5;").?;
        const bin = std.mem.indexOf(u8, out, "const n2_result = n3_value + 0;").?;
        const set = std.mem.indexOf(u8, out, "game.setField(Position, .x, n4_value, n2_result);").?;
        try expect.toBeTrue(lit < bin);
        try expect.toBeTrue(bin < set);
    }

    test "rejects graph cycle" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "result" }, "to": { "node": 2, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "result" }, "to": { "node": 1, "pin": "a" } }
            \\  ]
            \\}
        );
        defer loaded.deinit();
        try std.testing.expectError(
            error.CycleDetected,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "cyc" }),
        );
    }

    test "rejects dangling required pin on SetField" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator,
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] }, { "id": 1, "type": "SetField", "target": "Position.x", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        );
        defer loaded.deinit();
        try std.testing.expectError(
            error.DanglingPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "missing" }),
        );
    }

    test "rejects unknown pin name on edge" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "1", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "c" } } ]
            \\}
        );
        defer loaded.deinit();
        try std.testing.expectError(
            error.UnknownPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "bad" }),
        );
    }

    test "emits emitNodeEntered for each node" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 10, "type": "Literal", "value": "1", "pos": [0, 0] },
            \\    { "id": 20, "type": "Identifier", "name": "x", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        , "pulse");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 10) catch {};") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 20) catch {};") != null);
    }

    test "namespaced component type surfaces NamespacedComponentType" {
        const allocator = std.testing.allocator;
        const result = render(allocator,
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] }, { "id": 1, "type": "GetComponent", "component": "foo.bar.Baz", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        , "ns");
        try expect.toBeTrue(if (result) |out| blk: {
            allocator.free(out);
            break :blk false;
        } else |err| err == error.NamespacedComponentType);
    }

    test "single-flow output passes std.zig.Ast.parse" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.entity_created", "pos": [0, 0] },
            \\    { "id": 4, "type": "Identifier", "name": "payload.entity", "pos": [0, 0] },
            \\    { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetField", "target": "Position.x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 1, "pin": "entity" } },
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 3, "pin": "entity" } },
            \\    { "from": { "node": 1, "pin": "x" }, "to": { "node": 2, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "result" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        , "all_kinds");
        defer allocator.free(out);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    // The legacy `OnEvent` (`module` + `callback` + `params`) codegen
    // path and its tests — the file-level `flowEvent` callback + `pub
    // fn setup` registrar, the entity-scoped-node blanket rejection
    // (`error.EntityUnavailableInSubgraph`), and the `Subflow`
    // rejection (`error.UnsupportedNodeKind`) — were retired in
    // RFC-PLUGIN-EVENTS phase 6 (flow-codegen#13). The new-form
    // hook-handler-struct codegen + its tests cover the surviving
    // path.
};

// =====================================================================
// codegen — Subflow composition (RFC §3, §4, §6)
// =====================================================================

pub const SubflowTests = struct {
    // A reusable subgraph: one f32 param, one f32 output.
    const combat_subgraph =
        \\{
        \\  "name": "combat_subgraph",
        \\  "event": { "type": "OnCall" },
        \\  "params": [ { "name": "damage", "type": "f32", "default": 10.0 } ],
        \\  "nodes": [
        \\    { "id": 1, "type": "Param", "param": "damage", "pos": [0, 0] },
        \\    { "id": 2, "type": "Output", "name": "dealt", "value_type": "f32", "pos": [0, 0] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
        \\  ]
        \\}
    ;

    // A void subgraph: no params, no outputs, pure side effect.
    // A subgraph has no `entity` in scope (RFC §3 — only declared
    // params are inputs), so it uses a `Call` node, not an
    // entity-scoped GetComponent/SetField.
    const void_subgraph =
        \\{
        \\  "name": "void_sub",
        \\  "event": { "type": "OnCall" },
        \\  "nodes": [
        \\    { "id": 1, "type": "Call", "callee": "doSideEffect", "pos": [0, 0] }
        \\  ],
        \\  "edges": []
        \\}
    ;

    test "FlowRegistry rejects duplicate effective names" {
        const allocator = std.testing.allocator;
        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();

        var a = try flow_io.parseFlow(allocator, combat_subgraph);
        defer a.deinit();
        var b = try flow_io.parseFlow(allocator, combat_subgraph);
        defer b.deinit();

        try reg.add(a.flow);
        try std.testing.expectError(error.DuplicateFlowName, reg.add(b.flow));
    }

    test "renderFlowFile emits a subgraph function called from the entry flow" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "enemy_tick",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 7, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "damage": 25.0 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "enemy_tick" });
        defer allocator.free(out);

        // The subgraph becomes its own fn: params → fn args.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn combat_subgraph(game: anytype, damage: f32) f32 {") != null);
        // A Param node reads the argument.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = damage;") != null);
        // The single Output becomes a return.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return n1_value;") != null);
        // The Subflow node lowers to a call, binding the literal.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n7_result = combat_subgraph(game, 25);") != null);
    }

    test "Subflow uses declared default when param unwired and unbound" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "tick_default",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Subflow", "flow": "combat_subgraph", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "tick_default" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_result = combat_subgraph(game, 10);") != null);
    }

    test "Subflow wired pin overrides binding and default" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "tick_wired",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": "99", "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "damage": 1.0 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "damage" } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "tick_wired" });
        defer allocator.free(out);
        // Wired (rule 1) wins over the binding literal.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = combat_subgraph(game, n1_value);") != null);
    }

    test "void subgraph lowers to a bare call statement" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "tick_void",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Subflow", "flow": "void_sub", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, void_subgraph);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "tick_void" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn void_sub(game: anytype) void {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "    void_sub(game);") != null);
    }

    test "rejects Subflow binding naming an unknown param" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "tick_badbind",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "nonsense": 1.0 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        try std.testing.expectError(
            error.UnknownFlowParam,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "tick_badbind" }),
        );
    }

    test "rejects Subflow referencing an unregistered flow" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "tick_unknown",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Subflow", "flow": "ghost", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);

        try std.testing.expectError(
            error.UnknownFlowRef,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "tick_unknown" }),
        );
    }

    test "detects a reference cycle and reports the full chain" {
        const allocator = std.testing.allocator;
        // a -> b -> a
        const flow_a =
            \\{
            \\  "name": "a",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "b", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const flow_b =
            \\{
            \\  "name": "b",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "a", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        var la = try flow_io.parseFlow(allocator, flow_a);
        defer la.deinit();
        var lb = try flow_io.parseFlow(allocator, flow_b);
        defer lb.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(la.flow);
        try reg.add(lb.flow);

        var chain: ?[]const u8 = null;
        const result = flow_codegen.detectReferenceCycle(allocator, &reg, "a", &chain);
        try std.testing.expectError(error.FlowReferenceCycle, result);
        try expect.toBeTrue(chain != null);
        try expect.toBeTrue(std.mem.eql(u8, chain.?, "a -> b -> a"));
        if (chain) |c| allocator.free(c);
    }

    test "renderFlowFile rejects a self-referential flow" {
        const allocator = std.testing.allocator;
        const flow_self =
            \\{
            \\  "name": "loopy",
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Subflow", "flow": "loopy", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        var ls = try flow_io.parseFlow(allocator, flow_self);
        defer ls.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(ls.flow);

        try std.testing.expectError(
            error.FlowReferenceCycle,
            flow_codegen.renderFlowFile(allocator, ls.flow, &reg, .{ .flow_name = "loopy" }),
        );
    }

    test "a diamond reference graph is NOT a cycle" {
        const allocator = std.testing.allocator;
        // top -> {left, right}; left -> leaf; right -> leaf.
        const leaf = combat_subgraph; // name combat_subgraph
        const left =
            \\{
            \\  "name": "left",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "combat_subgraph", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const right =
            \\{
            \\  "name": "right",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "combat_subgraph", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const top =
            \\{
            \\  "name": "top",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Subflow", "flow": "left", "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "right", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var l_leaf = try flow_io.parseFlow(allocator, leaf);
        defer l_leaf.deinit();
        var l_left = try flow_io.parseFlow(allocator, left);
        defer l_left.deinit();
        var l_right = try flow_io.parseFlow(allocator, right);
        defer l_right.deinit();
        var l_top = try flow_io.parseFlow(allocator, top);
        defer l_top.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(l_leaf.flow);
        try reg.add(l_left.flow);
        try reg.add(l_right.flow);
        try reg.add(l_top.flow);

        var chain: ?[]const u8 = null;
        try flow_codegen.detectReferenceCycle(allocator, &reg, "top", &chain);
        try expect.toBeTrue(chain == null);
    }

    test "sanitizeSymbol produces valid Zig identifiers" {
        const allocator = std.testing.allocator;
        const s1 = try flow_codegen.sanitizeSymbol(allocator, "enemy-tick.v2");
        defer allocator.free(s1);
        try expect.toBeTrue(std.mem.eql(u8, s1, "enemy_tick_v2"));

        const s2 = try flow_codegen.sanitizeSymbol(allocator, "3combat");
        defer allocator.free(s2);
        try expect.toBeTrue(std.mem.eql(u8, s2, "_3combat"));
    }

    test "Subflow output passes std.zig.Ast.parse" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "enemy_tick",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 7, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "damage": 25.0 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "enemy_tick" });
        defer allocator.free(out);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "multi-output subgraph emits a result struct" {
        const allocator = std.testing.allocator;
        const multi =
            \\{
            \\  "name": "multi",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "x", "type": "f32", "default": 1.0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "x", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "a", "value_type": "f32", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "b", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "uses_multi",
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Subflow", "flow": "multi", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        var l_multi = try flow_io.parseFlow(allocator, multi);
        defer l_multi.deinit();
        var l_entry = try flow_io.parseFlow(allocator, entry_src);
        defer l_entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(l_multi.flow);
        try reg.add(l_entry.flow);

        const out = try flow_codegen.renderFlowFile(allocator, l_entry.flow, &reg, .{ .flow_name = "uses_multi" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const multi_Result = struct {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn multi(game: anytype, x: f32) multi_Result {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return .{") != null);
    }

    test "rejects a cycle even when the entry flow is unnamed" {
        const allocator = std.testing.allocator;
        // Entry (no top-level "name") -> b -> b.  The entry's own
        // Subflow cycle must be caught regardless of entry naming.
        const b_src =
            \\{
            \\  "name": "b",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "b", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const entry_src =
            \\{
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Subflow", "flow": "b", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        var lb = try flow_io.parseFlow(allocator, b_src);
        defer lb.deinit();
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        try expect.toBeTrue(entry.flow.name.len == 0);

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(lb.flow);

        try std.testing.expectError(
            error.FlowReferenceCycle,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "" }),
        );
    }

    test "single-output subflow output pin resolves to a scalar" {
        const allocator = std.testing.allocator;
        // combat_subgraph has exactly one Output ("dealt"). A subgraph
        // that wires FROM the Subflow's "dealt" pin into its own
        // Output must resolve to the scalar result, not a `.dealt`
        // field access.
        const wrapper =
            \\{
            \\  "name": "wrapper",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "damage": 5.0 }, "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "out", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "dealt" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "uses_wrapper",
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Subflow", "flow": "wrapper", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();
        var l_wrap = try flow_io.parseFlow(allocator, wrapper);
        defer l_wrap.deinit();
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(sub.flow);
        try reg.add(l_wrap.flow);
        try reg.add(entry.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "uses_wrapper" });
        defer allocator.free(out);
        // Scalar result — never a `.dealt` field access.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n1_result.dealt") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return n1_result;") != null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "rejects an edge into an undeclared Subflow param pin" {
        const allocator = std.testing.allocator;
        // The wired pin "dmage" is a typo for the declared "damage" —
        // it must surface as an error, not silently use the default.
        const entry_src =
            \\{
            \\  "name": "tick_typo",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Literal", "value": 3.0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "combat_subgraph", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "dmage" } }
            \\  ]
            \\}
        ;
        var sub = try flow_io.parseFlow(allocator, combat_subgraph);
        defer sub.deinit();
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(sub.flow);
        try reg.add(entry.flow);

        try std.testing.expectError(
            error.UnknownFlowParam,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "tick_typo" }),
        );
    }

    test "rejects subgraphs whose names collide after sanitization" {
        const allocator = std.testing.allocator;
        // "a-b" and "a_b" are distinct registry names but both
        // sanitize to the Zig identifier "a_b".
        const ab_dash =
            \\{
            \\  "name": "a-b",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        const ab_under =
            \\{
            \\  "name": "a_b",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "uses_both",
            \\  "nodes": [
            \\    { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 1, "type": "Subflow", "flow": "a-b", "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "a_b", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, ab_dash);
        defer l1.deinit();
        var l2 = try flow_io.parseFlow(allocator, ab_under);
        defer l2.deinit();
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(l1.flow);
        try reg.add(l2.flow);
        try reg.add(entry.flow);

        try std.testing.expectError(
            error.SymbolCollision,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "uses_both" }),
        );
    }

    test "rejects an entity-scoped node inside a subgraph with no entity-pin wire" {
        const allocator = std.testing.allocator;
        // A subgraph has no `entity` in scope; a `GetComponent` with no
        // wire on its `entity` input pin (RFC-PLUGIN-EVENTS §9) is
        // `DanglingPin` against the offending node. Replaces the v1
        // blanket `EntityUnavailableInSubgraph`.
        const sub_src =
            \\{
            \\  "name": "needs_entity",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "GetComponent", "component": "Health", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "uses_needs_entity",
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Subflow", "flow": "needs_entity", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        var sub = try flow_io.parseFlow(allocator, sub_src);
        defer sub.deinit();
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(sub.flow);
        try reg.add(entry.flow);

        try std.testing.expectError(
            error.DanglingPin,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "uses_needs_entity" }),
        );
    }

    test "Subflow bindings parse in deterministic (sorted) order" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "binds",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Subflow", "flow": "x",
            \\      "bindings": { "zeta": 1, "alpha": 2, "mid": 3 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const binds = loaded.flow.nodes[0].kind.Subflow.bindings;
        try expect.equal(binds.len, @as(usize, 3));
        try expect.toBeTrue(std.mem.eql(u8, binds[0].param, "alpha"));
        try expect.toBeTrue(std.mem.eql(u8, binds[1].param, "mid"));
        try expect.toBeTrue(std.mem.eql(u8, binds[2].param, "zeta"));
    }

    test "rejects subgraph whose name collides with the entry handler" {
        const allocator = std.testing.allocator;
        // A subgraph named exactly "onCall" produces a `fn onCall`,
        // colliding with the entry flow's `pub fn onCall`.
        const sub_src =
            \\{
            \\  "name": "onCall",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        // Entry is an OnCall flow → its `pub fn` is `onCall`.
        const entry_src =
            \\{
            \\  "name": "uses_oncall_named",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "onCall", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        var sub = try flow_io.parseFlow(allocator, sub_src);
        defer sub.deinit();
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(sub.flow);
        try reg.add(entry.flow);

        try std.testing.expectError(
            error.SymbolCollision,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "uses_oncall_named" }),
        );
    }

    test "rejects entry Output names that collide after sanitization" {
        const allocator = std.testing.allocator;
        // "a-b" and "a_b" are distinct Output names but both sanitize
        // to the Zig field identifier "a_b".
        const entry_src =
            \\{
            \\  "name": "colliding_outputs",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "x", "type": "f32", "default": 1.0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "x", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "a-b", "value_type": "f32", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "a_b", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);

        try std.testing.expectError(
            error.SymbolCollision,
            flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "colliding_outputs" }),
        );
    }

    test "OnCall entry with a single Output returns it" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "scoring",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "base", "type": "f32", "default": 3.0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "base", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "score", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "scoring" });
        defer allocator.free(out);
        // The entry `pub fn` returns the Output's declared type.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCall(game: anytype, base: f32) f32 {") != null);
        // …and emits the return statement reading the wired pin.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return n1_value;") != null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "OnCall entry with multiple Outputs returns a result struct" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "stats",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "base", "type": "f32", "default": 1.0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "base", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "hp", "value_type": "f32", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "mp", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "stats" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const onCall_Result = struct {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCall(game: anytype, base: f32) onCall_Result {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, ".hp = n1_value,") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, ".mp = n1_value,") != null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "multi-output subgraph sanitizes Output names into struct fields" {
        const allocator = std.testing.allocator;
        // Output names with hyphens / leading digits must sanitize so
        // the generated result struct compiles.
        const multi =
            \\{
            \\  "name": "odd_names",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "x", "type": "f32", "default": 1.0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "x", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "hit-points", "value_type": "f32", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "2nd", "value_type": "f32", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "uses_odd",
            \\  "nodes": [ { "id": 99, "type": "Event", "name": "engine.tick", "pos": [0, 0] }, { "id": 1, "type": "Subflow", "flow": "odd_names", "pos": [0, 0 ] } ],
            \\  "edges": []
            \\}
        ;
        var l_multi = try flow_io.parseFlow(allocator, multi);
        defer l_multi.deinit();
        var l_entry = try flow_io.parseFlow(allocator, entry_src);
        defer l_entry.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(l_multi.flow);
        try reg.add(l_entry.flow);

        const out = try flow_codegen.renderFlowFile(allocator, l_entry.flow, &reg, .{ .flow_name = "uses_odd" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "hit_points: f32") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_2nd: f32") != null);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }
};

// =====================================================================
// Codegen validation — flows that parse cleanly but would otherwise
// emit Zig that fails to compile (PR #6 review follow-up)
// =====================================================================

/// Unlike the suites above, these build each `flow_io.Flow` directly
/// with a `zspec` factory rather than parsing JSONC: the concern is
/// purely how `renderFlowFile` lowers a structurally-valid graph, so
/// the parser is deliberately kept out of the loop.
pub const CodegenValidationTests = zspec.context("codegen rejects flows that would emit invalid Zig", struct {
    /// `flow_io.Flow` factory — an empty `OnCall` flow by default;
    /// each test overrides only the fields under test. The factory
    /// supplies every field (it does not fall back to struct field
    /// defaults), so `params` / `nodes` / `edges` default to empty.
    const FlowFactory = zspec.Factory.define(flow_io.Flow, .{
        .name = "flow",
        .event = flow_io.Event{ .OnCall = {} },
        .params = &.{},
        .variables = &.{},
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
        // args are gone; an `OnCall` subgraph emits `fn (game,
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
            .event = flow_io.Event{ .OnCall = {} },
            .params = &sub_params,
            .nodes = &sub_nodes,
            .edges = &sub_edges,
        });
        var entry_nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Subflow = .{ .flow = "tick_helper" } } },
        };
        const entry = FlowFactory.build(.{
            .name = "uses_tick_helper",
            .event = flow_io.Event{ .OnCall = {} },
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

    test "rejects an entity-scoped node in an OnCall entry flow with no entity-pin wire" {
        const allocator = std.testing.allocator;
        // An `OnCall` entry is a subgraph in its own right (RFC §3/§6)
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

// =====================================================================
// RFC-FLOW-VOCABULARY — events as graph nodes (§3) + variables (§4)
// =====================================================================

pub const FlowVocabularyTests = struct {
    // Round-trip a flow with an Event node + ChangeVariable through
    // the parser and writer — exercises the new file format end-to-end.
    test "parses Event node + variables + ChangeVariable" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [40, 160] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        // The synthetic event matches the header form: `OnEvent` with
        // the node's name. `priority` is null when synthesized from a
        // node (only the header form carries a priority on disk).
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.event.OnEvent.name.?, "box2d.collision_begin"));
        try expect.equal(loaded.flow.event.OnEvent.priority, @as(?i32, null));

        // The variable is declared.
        try expect.equal(loaded.flow.variables.len, @as(usize, 1));
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.variables[0].name, "hits"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.variables[0].type, "i32"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.variables[0].default.zig_text, "0"));

        try expect.equal(loaded.flow.nodes.len, @as(usize, 2));
        // Order on disk: id 1 = Event, id 2 = ChangeVariable.
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .Event);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.Event.name, "box2d.collision_begin"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .ChangeVariable);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.ChangeVariable.name, "hits"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.ChangeVariable.by, "1"));
    }

    test "round-trips Event node + variables through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [40, 160] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnEvent.name.?, "box2d.collision_begin"));
        try expect.equal(l2.flow.variables.len, @as(usize, 1));
        try expect.equal(l2.flow.nodes.len, @as(usize, 2));

        // The re-rendered file must NOT contain a top-level `event:`
        // key (the node form is the source of truth on re-save).
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"event\":") == null);
    }

    test "rejects file with both header and Event node" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.ConflictingEventSource,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "rejects file with no event source" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.ConflictingEventSource,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "parses a multi-trigger flow with two Event nodes" {
        // RFC-FLOW-VOCABULARY §3 — "A flow with multiple Event nodes is
        // a multi-trigger flow" (resolves RFC open question O2). The
        // v1 `MultipleEventNodes` rejection is gone; both Event nodes
        // round-trip through the parser. `Flow.event` lifts the first
        // Event node's name for back-compat with `flow_scanner`; codegen
        // reads the full set off `flow.nodes`.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "a.b", "pos": [0, 0] },
            \\    { "id": 2, "type": "Event", "name": "c.d", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnEvent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.event.OnEvent.name.?, "a.b"));
        try expect.equal(loaded.flow.nodes.len, @as(usize, 2));
    }

    test "rejects ChangeVariable naming an unknown variable" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "x.y", "pos": [0, 0] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "ghost", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.UnknownVariable,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "rejects duplicate variable names" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [
            \\    { "name": "x", "type": "i32", "default": 0 },
            \\    { "name": "x", "type": "f32", "default": 1.0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.DuplicateVariableName,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "codegen emits file-scope var for declared variables" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [40, 160] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "hit_counter" });
        defer allocator.free(out);

        // The file-scope var.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var hits: i32 = 0;") != null);
        // The increment.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "hits += 1;") != null);
        // The debug print.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "std.debug.print(\"hits: {d}") != null);
        // The Event node was dropped from the body — no `n1_*` decl.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n1_") == null);
        // The `FlowEventHandler` struct still gets emitted (the event
        // came from the Event node, not a file-level header).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub const FlowEventHandler") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "box2d__collision_begin") != null);
    }

    test "generated Zig parses as valid Zig (Event + ChangeVariable)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [40, 160] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "hit_counter" });
        defer allocator.free(out);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "numeric widening: Literal feeding ChangeVariable i32 codegens + parses cleanly (O1)" {
        // RFC-FLOW-VOCABULARY §2 / O1 resolved — auto-accepted widenings
        // are emitted as bare expressions and rely on Zig's implicit
        // coercion. A comptime-int `Literal` feeding an `i32` variable's
        // `ChangeVariable` produces `hits += <comptime_int>` which Zig
        // accepts without a cast. The test pins the codegen + AST-parse
        // round trip so a future strictening of Zig's coercion (or a
        // misguided `@as` wrapper) doesn't slip past CI.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] },
            \\    { "id": 2, "type": "Literal", "value": "5", "pos": [40, 100] },
            \\    { "id": 3, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [40, 160] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "by" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "hit_counter" });
        defer allocator.free(out);

        // The wired Literal's value `n2_value` flows directly into the
        // ChangeVariable's `by` slot — no `@as` / `@intCast` wrapper.
        // Zig coerces the comptime-int (or u8, etc.) to i32 implicitly
        // per the O1 rule, so the generated source compiles as-is.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "hits += n2_value;") != null);

        // Sanity: the generated file parses as valid Zig.
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "GetVariable + SetVariable codegen lowering" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "counter",
            \\  "variables": [
            \\    { "name": "count", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "count", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 3, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "count", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "counter" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var count: i32 = 0;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = count;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "count = n3_result;") != null);
    }

    // =====================================================================
    // RFC-FLOW-VOCABULARY §4 — nullable variable operations
    // (flow-codegen#15 item 1)
    // =====================================================================

    test "round-trips ClearVariable + HasValueVariable through renderFlowJsonc" {
        // RFC-FLOW-VOCABULARY §4 — the nullable-only ops are
        // structurally identical to `GetVariable` / `SetVariable` on
        // the wire: one `name` payload field. Round-trip confirms the
        // parser, validator, and writer all agree on the shape.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "target_picker",
            \\  "variables": [
            \\    { "name": "target", "type": "?EntityId", "default": null }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "HasValueVariable", "name": "target", "pos": [0, 0] },
            \\    { "id": 2, "type": "ClearVariable", "name": "target", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .HasValueVariable);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.HasValueVariable.name, "target"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .ClearVariable);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.ClearVariable.name, "target"));

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);
        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(roundtrip.flow.nodes.len, @as(usize, 2));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .HasValueVariable);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[1].kind), .ClearVariable);
    }

    test "ClearVariable + HasValueVariable codegen lowering" {
        // The variable is `?EntityId`, both ops are valid. `ClearVariable`
        // lowers to `<var> = null;` (no output pin); `HasValueVariable`
        // lowers to `const n<id>_value = <var> != null;` (bool output).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "target_picker",
            \\  "variables": [
            \\    { "name": "target", "type": "?EntityId", "default": null }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "HasValueVariable", "name": "target", "pos": [0, 0] },
            \\    { "id": 2, "type": "ClearVariable", "name": "target", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "target_picker" });
        defer allocator.free(out);

        // The file-scope nullable var.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var target: ?EntityId = null;") != null);
        // `HasValueVariable` — reporter, `n<id>_value = target != null;`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = target != null;") != null);
        // `ClearVariable` — command, `target = null;`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "target = null;") != null);
    }

    test "generated Zig parses as valid Zig (Clear + HasValue)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "target_picker",
            \\  "variables": [
            \\    { "name": "target", "type": "?u32", "default": null }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "HasValueVariable", "name": "target", "pos": [0, 0] },
            \\    { "id": 2, "type": "ClearVariable", "name": "target", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "target_picker" });
        defer allocator.free(out);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "rejects ClearVariable on a non-nullable variable" {
        // RFC-FLOW-VOCABULARY §4 — `Clear` is the nullable-only op; the
        // declared `type` must start with `?`. A `Clear` on an `i32` is
        // a flow-layer type error (`MalformedFlow`), not a Zig-compiler
        // error against the generated `i32 = null;`.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [
            \\    { "name": "count", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ClearVariable", "name": "count", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.MalformedFlow,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "rejects HasValueVariable on a non-nullable variable" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [
            \\    { "name": "count", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "HasValueVariable", "name": "count", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.MalformedFlow,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "rejects ClearVariable naming an unknown variable" {
        // Same `UnknownVariable` path the other Variable* ops use —
        // checked before the nullability constraint, so a typo on a
        // never-declared var surfaces the variable-existence error
        // rather than the nullability error.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ClearVariable", "name": "ghost", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.UnknownVariable,
            flow_io.parseFlow(allocator, src),
        );
    }

    // =====================================================================
    // RFC-FLOW-VOCABULARY §3 — multi-trigger flows
    // (flow-codegen#15 item 3, resolves RFC open question O2)
    // =====================================================================

    test "multi-trigger codegen emits one method per Event + shared bodyImpl" {
        // Two Event nodes share a downstream `ChangeVariable hits`. The
        // generated `FlowEventHandler` exposes one `pub fn` per trigger,
        // each dispatching to a shared `bodyImpl(game)` helper that runs
        // the topo-sorted body. Per-event payload aliases keep each
        // method's signature accurate against `PluginEvents`.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "multi_hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
            \\    { "id": 2, "type": "Event", "name": "game.level_complete", "pos": [0, 0] },
            \\    { "id": 3, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "multi_hit_counter" });
        defer allocator.free(out);

        // Per-event payload aliases — `.` → `__` for the qualified tag.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const __EvPayload_box2d__collision_begin = @FieldType(PluginEvents, \"box2d__collision_begin\");") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const __EvPayload_game__level_complete = @FieldType(PluginEvents, \"game__level_complete\");") != null);
        // One `pub fn` per trigger.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn box2d__collision_begin(self: *@This(), payload: __EvPayload_box2d__collision_begin) void") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn game__level_complete(self: *@This(), payload: __EvPayload_game__level_complete) void") != null);
        // Shared helper — takes already-downcast `*Game`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn bodyImpl(game: *Game) void") != null);
        // Each dispatch method calls into the helper.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "bodyImpl(game);") != null);
        // The single `__EvPayload` alias (single-event shape) is NOT
        // emitted in the multi-trigger path.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const __EvPayload =") == null);
        // The shared body still carries the increment + the debug print.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "hits += 1;") != null);
    }

    test "generated Zig parses as valid Zig (multi-trigger)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "multi_hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
            \\    { "id": 2, "type": "Event", "name": "game.level_complete", "pos": [0, 0] },
            \\    { "id": 3, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "multi_hit_counter" });
        defer allocator.free(out);

        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "single-trigger flow still emits the original single-method shape" {
        // The single-event shape is unchanged — one `__EvPayload`, one
        // `pub fn` whose body is inlined directly (no `bodyImpl` helper).
        // The existing bouncing-ball test (`generated Zig parses as
        // valid Zig (Event + ChangeVariable)`) covers the byte-for-byte
        // codegen; this assertion just guards against accidental
        // regression to the multi-trigger shape.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [0, 0] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "hit_counter" });
        defer allocator.free(out);

        // The single-event payload alias.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const __EvPayload = @FieldType(PluginEvents, \"box2d__collision_begin\");") != null);
        // No `bodyImpl` helper — single-event flows inline the body.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn bodyImpl(") == null);
        // No per-event-aliased payload.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__EvPayload_") == null);
    }
};

// =====================================================================
// RFC-FLOW-VOCABULARY §1 + §5 — CustomNode (plugin / game-script
// FlowNodes) (flow-codegen#15 item 2)
// =====================================================================

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
            \\  "event": { "type": "OnCall" },
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
            \\  "event": { "type": "OnCall" },
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
            \\  "event": { "type": "OnCall" },
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
            \\  "event": { "type": "OnCall" },
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
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = @TypeOf(game_mod.PluginFlowNodes.my_helpers__score).impl(game, n1_value, n2_value);") != null);
    }

    test "codegen lowers a void-returning CustomNode (command form)" {
        // The impl returns void — codegen emits a bare statement, no
        // `const n<id>_value = ...` binding.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "command_use",
            \\  "event": { "type": "OnCall" },
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

        // Command shape: bare statement (no `const n2_value =` binding).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "@TypeOf(game_mod.PluginFlowNodes.box2d__apply_impulse).impl(game, n1_value);") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value =") == null);
        // No discard line — there is no `n2_value` to discard.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = n2_value;") == null);
    }

    test "codegen rejects unknown CustomNode name with UnknownFlowNode" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "unknown_use",
            \\  "event": { "type": "OnCall" },
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
            \\  "event": { "type": "OnCall" },
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
        // The void CustomNode body — bare statement, no result binding.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "@TypeOf(game_mod.PluginFlowNodes.my_helpers__log_it).impl(game);") != null);

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
            \\  "event": { "type": "OnCall" },
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

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = @TypeOf(game_mod.PluginFlowNodes.my_helpers__score).impl(game);") != null);
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
            \\  "event": { "type": "OnCall" },
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

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = @TypeOf(game_mod.PluginFlowNodes.my_helpers__score).impl(game);") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = n1_value;") != null);
    }
};

// =====================================================================
// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions
// (flow-codegen#15 item 5)
// =====================================================================

pub const CoercionTests = struct {
    fn buildRegistry(
        allocator: std.mem.Allocator,
        entries: []const flow_codegen.CoercionEntry,
    ) !flow_codegen.CoercionRegistry {
        var reg = flow_codegen.CoercionRegistry.init(allocator);
        errdefer reg.deinit();
        for (entries) |e| try reg.add(e);
        return reg;
    }

    /// Assert `src` is syntactically valid Zig — generated control-flow
    /// code (flow-codegen#8) must parse. Mirrors `FlowFileTests`'.
    fn expectParses(allocator: std.mem.Allocator, src: []const u8) !void {
        const z = try allocator.allocSentinel(u8, src.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..src.len], src);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{src});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "wireFitAccepts: type equality returns .exact" {
        // Rule 1 — Zig type equality always fits. The registry doesn't
        // need to contain anything for this path; it's the trivial
        // case the wire-fit chain short-circuits on first.
        const allocator = std.testing.allocator;
        var reg = try buildRegistry(allocator, &.{});
        defer reg.deinit();

        const fit = reg.wireFitAccepts("u32", "u32");
        try expect.equal(@as(std.meta.Tag(flow_codegen.WireFit), fit), .exact);
    }

    test "wireFitAccepts: registered (from, to) returns .coercion(qualified)" {
        // Rule 3 — the editor's wire-fit chain falls through here when
        // type equality (and numeric widening, checked editor-side
        // against the actual Zig types) doesn't match. A registered
        // `(BodyId, u32)` pair accepts the wire and surfaces the
        // qualified decl name flow-codegen's edge wrap will use.
        const allocator = std.testing.allocator;
        var reg = try buildRegistry(allocator, &.{
            .{
                .qualified = "box2d__body_to_entity",
                .from_zig_type = "BodyId",
                .to_zig_type = "u32",
            },
        });
        defer reg.deinit();

        const fit = reg.wireFitAccepts("BodyId", "u32");
        switch (fit) {
            .coercion => |q| try expect.toBeTrue(std.mem.eql(u8, q, "box2d__body_to_entity")),
            else => try expect.toBeTrue(false),
        }
    }

    test "wireFitAccepts: unregistered pair returns .refused" {
        // Rule 4 — no built-in match, no registered coercion. The
        // editor surfaces this as `MalformedFlow` per RFC §2's "editor
        // refuses; codegen rejects" contract.
        const allocator = std.testing.allocator;
        var reg = try buildRegistry(allocator, &.{
            .{
                .qualified = "box2d__body_to_entity",
                .from_zig_type = "BodyId",
                .to_zig_type = "u32",
            },
        });
        defer reg.deinit();

        const fit = reg.wireFitAccepts("BodyId", "f32"); // unregistered To
        try expect.equal(@as(std.meta.Tag(flow_codegen.WireFit), fit), .refused);
    }

    test "wireFitAccepts: direction matters — (A, B) does not imply (B, A)" {
        // Coercions are directional — `body_to_entity` accepts
        // `BodyId → u32`, not `u32 → BodyId`. The editor's wire-fit
        // lookup keys on the directed pair so reverse-direction wires
        // refuse unless a separate inverse coercion is declared.
        const allocator = std.testing.allocator;
        var reg = try buildRegistry(allocator, &.{
            .{
                .qualified = "box2d__body_to_entity",
                .from_zig_type = "BodyId",
                .to_zig_type = "u32",
            },
        });
        defer reg.deinit();

        const forward = reg.wireFitAccepts("BodyId", "u32");
        try expect.equal(@as(std.meta.Tag(flow_codegen.WireFit), forward), .coercion);

        const reverse = reg.wireFitAccepts("u32", "BodyId");
        try expect.equal(@as(std.meta.Tag(flow_codegen.WireFit), reverse), .refused);
    }

    test "CoercionRegistry: last-write-wins on duplicate (from, to)" {
        // A later registration for the same (from, to) overwrites the
        // earlier one — same shape `PluginPinStyles.dedupe` uses, so
        // a downstream plugin overriding an upstream's coercion has
        // predictable precedence.
        const allocator = std.testing.allocator;
        var reg = flow_codegen.CoercionRegistry.init(allocator);
        defer reg.deinit();

        try reg.add(.{
            .qualified = "first__bridge",
            .from_zig_type = "A",
            .to_zig_type = "B",
        });
        try reg.add(.{
            .qualified = "second__bridge",
            .from_zig_type = "A",
            .to_zig_type = "B",
        });

        const got = reg.get("A", "B").?;
        try expect.toBeTrue(std.mem.eql(u8, got.qualified, "second__bridge"));
    }

    test "wrapEdgeWithCoercion: emits the canonical call-site shape" {
        // Edge codegen contract: when the wire-fit returned
        // `.coercion(qualified)`, codegen wraps the resolved source
        // expression in `game_mod.PluginCoercions.<qualified>.convert(<expr>)`.
        // This pins the exact string shape downstream assembler-emitted
        // `PluginCoercions` aliases land against.
        const allocator = std.testing.allocator;
        const wrapped = try flow_codegen.wrapEdgeWithCoercion(
            allocator,
            "box2d__body_to_entity",
            "n3_value",
        );
        defer allocator.free(wrapped);
        try expect.toBeTrue(std.mem.eql(
            u8,
            wrapped,
            "game_mod.PluginCoercions.box2d__body_to_entity.convert(n3_value)",
        ));
    }

    test "Options: coercions field defaults to null" {
        // Every pre-RFC-FLOW-VOCABULARY-§2 caller passes `Options`
        // without the `coercions` field. The default must stay `null`
        // so those call sites keep compiling — empty / null registry
        // means "no coercions registered; wire-fit consults equality
        // + numeric-widening only".
        const opts: flow_codegen.Options = .{ .flow_name = "x" };
        try expect.toBeTrue(opts.coercions == null);
        try expect.toBeTrue(opts.custom_nodes == null);
    }

    test "Options: coercions threaded through renderFlowZig accepts a registry" {
        // Integration smoke: pass a populated registry through the
        // public entry point. The registry isn't consulted in any
        // existing lowering yet (edge codegen wires it through a
        // future flow_io annotation); the contract this test pins is
        // that the option exists, accepts a registry, and doesn't
        // perturb the no-CustomNode happy path.
        const allocator = std.testing.allocator;
        var reg = try buildRegistry(allocator, &.{
            .{
                .qualified = "box2d__body_to_entity",
                .from_zig_type = "BodyId",
                .to_zig_type = "u32",
            },
        });
        defer reg.deinit();

        const src =
            \\{
            \\  "name": "noop",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = "noop", .coercions = &reg },
        );
        defer allocator.free(out);

        // Sanity: the body of the entry fn was emitted.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCall(game: anytype)") != null);
    }

    // =====================================================================
    // Branch — control flow / if-then-else + exec edges (flow-codegen#8)
    // =====================================================================

    test "Branch lowers to if/else with both sides' assignments nested" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "br_if_else",
            \\  "variables": [
            \\    { "name": "lo", "type": "i32", "default": 0 },
            \\    { "name": "hi", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 10, "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "lt", "pos": [0, 0] },
            \\    { "id": 4, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 5, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "lo", "pos": [0, 0] },
            \\    { "id": 7, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 8, "type": "SetVariable", "name": "hi", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "cond" } },
            \\    { "from": { "node": 5, "pin": "value" }, "to": { "node": 6, "pin": "value" } },
            \\    { "from": { "node": 7, "pin": "value" }, "to": { "node": 8, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 6 } },
            \\    { "from": { "node": 4, "pin": "else" }, "to": { "node": 8 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "br_if_else" });
        defer allocator.free(out);

        // The Compare condition gates a real `if`, with an `else` arm.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "if (n3_result) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "} else {") != null);
        // Both sides' assignments appear, each nested one level deeper
        // than the `if` (8-space indent under the entry fn's 4).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        lo = n5_value;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        hi = n7_value;") != null);

        try expectParses(allocator, out);
    }

    test "Branch sinks a reporter read-after-write into the if-block" {
        // A side that does `SetVariable count = …` then reads `count`
        // (GetVariable) feeding another command must emit the
        // GetVariable binding INSIDE the if-block, AFTER the
        // SetVariable — proving the reporter is sunk into the side's
        // scope rather than hoisted before the branch (where it would
        // read the pre-write value).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "br_raw",
            \\  "variables": [
            \\    { "name": "count", "type": "i32", "default": 0 },
            \\    { "name": "mirror", "type": "i32", "default": 0 },
            \\    { "name": "flag", "type": "bool", "default": true }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "flag", "pos": [0, 0] },
            \\    { "id": 2, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 5, "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "count", "pos": [0, 0] },
            \\    { "id": 5, "type": "GetVariable", "name": "count", "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "mirror", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "cond" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } },
            \\    { "from": { "node": 5, "pin": "value" }, "to": { "node": 6, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "then" }, "to": { "node": 4 } },
            \\    { "from": { "node": 2, "pin": "then" }, "to": { "node": 6 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "br_raw" });
        defer allocator.free(out);

        // The GetVariable binding must appear, and AFTER the write.
        const write_at = std.mem.indexOf(u8, out, "count = n3_value;");
        const read_at = std.mem.indexOf(u8, out, "const n5_value = count;");
        const if_at = std.mem.indexOf(u8, out, "if (n1_value) {");
        try expect.toBeTrue(write_at != null);
        try expect.toBeTrue(read_at != null);
        try expect.toBeTrue(if_at != null);
        // Read is sunk into the if-block (after the `if (`) and ordered
        // after the write (read-after-write preserved).
        try expect.toBeTrue(read_at.? > if_at.?);
        try expect.toBeTrue(read_at.? > write_at.?);
        // Sunk one level deep — 8-space indent.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        const n5_value = count;") != null);

        try expectParses(allocator, out);
    }

    test "Branch shared cond reporter computes before the if" {
        // The Compare result feeding the Branch `cond` is shared (it IS
        // the condition) and must be bound BEFORE `if (`.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "br_shared",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "gt", "pos": [0, 0] },
            \\    { "id": 4, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 5, "type": "Literal", "value": 9, "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "cond" } },
            \\    { "from": { "node": 5, "pin": "value" }, "to": { "node": 6, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 6 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "br_shared" });
        defer allocator.free(out);

        const cmp_at = std.mem.indexOf(u8, out, "const n3_result = n1_value > n2_value;");
        const if_at = std.mem.indexOf(u8, out, "if (n3_result) {");
        try expect.toBeTrue(cmp_at != null);
        try expect.toBeTrue(if_at != null);
        // The condition's binding precedes the `if` that consumes it,
        // and is at top-level (4-space) indent — not sunk.
        try expect.toBeTrue(cmp_at.? < if_at.?);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "    const n3_result = n1_value > n2_value;") != null);

        try expectParses(allocator, out);
    }

    test "exec-wired reporter with unused output runs inside the branch (flow-codegen#8)" {
        // A value node (here a Call) can be exec-wired into a branch side
        // to run for its side effect, value unused. It must emit INSIDE
        // the if-block, not hoisted to top-level (bugbot follow-up).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "br_exec_reporter",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "lt", "pos": [0, 0] },
            \\    { "id": 4, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 7, "type": "Call", "callee": "doThing", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "cond" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 7 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "br_exec_reporter" });
        defer allocator.free(out);

        const if_at = std.mem.indexOf(u8, out, "if (n3_result) {");
        const call_at = std.mem.indexOf(u8, out, "n7_result = doThing");
        try expect.toBeTrue(if_at != null);
        try expect.toBeTrue(call_at != null);
        // The exec-wired Call runs inside the branch — after `if (`, not
        // hoisted before it (the bug: an unconsumed reporter stayed
        // top-level despite the exec edge).
        try expect.toBeTrue(call_at.? > if_at.?);
        try expectParses(allocator, out);
    }

    test "Branch with unwired cond defaults to false" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "br_default",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "then" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "br_default" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "if (false) {") != null);
        try expectParses(allocator, out);
    }

    test "Branch + exec_edges round-trip through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "br_rt",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "then" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.flow.exec_edges.len, @as(usize, 1));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .Branch);

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"exec_edges\"") != null);

        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(roundtrip.flow.exec_edges.len, @as(usize, 1));
        try expect.equal(roundtrip.flow.exec_edges[0].from.node, @as(u32, 1));
        try expect.toBeTrue(std.mem.eql(u8, roundtrip.flow.exec_edges[0].from.pin, "then"));
        try expect.equal(roundtrip.flow.exec_edges[0].to_node, @as(u32, 3));
    }

    test "no Branch / empty exec_edges still emits the flat form" {
        // Backward-compat: a flow with no control flow renders the same
        // top-level flat body it always did (no `if` wrapper).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "flat",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 4, "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "flat" });
        defer allocator.free(out);

        // No branch wrapper: no `else` arm, and the body stays at the
        // entry fn's 4-space indent (no 8-space sunk statements). The
        // preview pulse's own `if (game.preview)` is unrelated, so we
        // assert on the absence of the control-flow shapes specifically.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "} else {") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "    const n1_value = 4;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "    out = n1_value;") != null);
    }

    // =====================================================================
    // ForRange / While — loop control flow + body exec edges (flow-codegen#21)
    // =====================================================================

    test "ForRange lowers to a scoped i32 while loop with a nested body" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "fr_basic",
            \\  "variables": [ { "name": "acc", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 10, "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 4, "type": "ForRange", "pos": [0, 0] },
            \\    { "id": 5, "type": "SetVariable", "name": "acc", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 4, "pin": "start" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 4, "pin": "end" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "step" } },
            \\    { "from": { "node": 4, "pin": "index" }, "to": { "node": 5, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "body" }, "to": { "node": 5 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "fr_basic" });
        defer allocator.free(out);

        // The loop var is declared `i32` (a bare `var i = 0` would be a
        // comptime_int error) and the `while` is counted with the wired
        // start/end/step.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "var i_4: i32 = n1_value;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (i_4 < n2_value) : (i_4 += n3_value) {") != null);
        // A body node reading the `index` pin references the loop var
        // `i_4`, NOT an `n4_…` binding.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "acc = i_4;") != null);
        const idx_at = std.mem.indexOf(u8, out, "acc = i_4;");
        const while_at = std.mem.indexOf(u8, out, "while (i_4 <");
        try expect.toBeTrue(idx_at.? > while_at.?);
        // The body is nested two levels under the entry fn (enclosing block
        // + the `while`) → 12-space indent.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "            acc = i_4;") != null);

        try expectParses(allocator, out);
    }

    test "ForRange with unwired start/end/step uses 0/0/1 defaults" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "fr_default",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForRange", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "fr_default" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "var i_1: i32 = 0;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (i_1 < 0) : (i_1 += 1) {") != null);
        // The body command runs inside the loop block (12-space indent).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "            out = n2_value;") != null);

        try expectParses(allocator, out);
    }

    test "While re-evaluates its condition via deep-inlining (not a frozen binding)" {
        const allocator = std.testing.allocator;
        // The cond is `GetVariable x < Literal 10`. A `while` must re-read
        // `x` every iteration — so the header must be `while (x < 10)`, NOT
        // `while (n3_result)` (which would freeze the once-bound compare).
        const src =
            \\{
            \\  "name": "wh_reeval",
            \\  "variables": [ { "name": "x", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "x", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 10, "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "lt", "pos": [0, 0] },
            \\    { "id": 4, "type": "While", "pos": [0, 0] },
            \\    { "id": 5, "type": "ChangeVariable", "name": "x", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "cond" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "body" }, "to": { "node": 5 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "wh_reeval" });
        defer allocator.free(out);

        // Condition deep-inlined into the header — re-reads `x` each pass.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while ((x < 10)) {") != null);
        // NOT the frozen binding reference.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (n3_result)") == null);
        // The body (ChangeVariable) runs inside the loop block — one level
        // under the entry fn → 8-space indent.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        x += 1;") != null);

        try expectParses(allocator, out);
    }

    test "While with unwired cond defaults to false (loop never runs)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "wh_default",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "While", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "wh_default" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (false) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        out = n2_value;") != null);

        try expectParses(allocator, out);
    }

    test "loop node is a valid exec source with pin body (flow-codegen#21)" {
        // A `ForRange`/`While` body exec edge parses fine; a non-loop /
        // non-Branch exec source, or a wrong pin, is rejected.
        const allocator = std.testing.allocator;

        // Valid: ForRange `body` exec edge.
        {
            const ok_src =
                \\{
                \\  "name": "ok_for",
                \\  "variables": [ { "name": "n", "type": "?i32", "default": null } ],
                \\  "event": { "type": "OnCall" },
                \\  "nodes": [
                \\    { "id": 1, "type": "ForRange", "pos": [0, 0] },
                \\    { "id": 2, "type": "ClearVariable", "name": "n", "pos": [0, 0] }
                \\  ],
                \\  "edges": [],
                \\  "exec_edges": [
                \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
                \\  ]
                \\}
            ;
            var loaded = try flow_io.parseFlow(allocator, ok_src);
            defer loaded.deinit();
            try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .ForRange);
        }

        // Valid: While `body` exec edge.
        {
            const ok_src =
                \\{
                \\  "name": "ok_while",
                \\  "variables": [ { "name": "n", "type": "?i32", "default": null } ],
                \\  "event": { "type": "OnCall" },
                \\  "nodes": [
                \\    { "id": 1, "type": "While", "pos": [0, 0] },
                \\    { "id": 2, "type": "ClearVariable", "name": "n", "pos": [0, 0] }
                \\  ],
                \\  "edges": [],
                \\  "exec_edges": [
                \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
                \\  ]
                \\}
            ;
            var loaded = try flow_io.parseFlow(allocator, ok_src);
            defer loaded.deinit();
            try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .While);
        }

        // Rejected: a non-loop, non-Branch exec source (a Literal here).
        {
            const bad_src =
                \\{
                \\  "name": "bad_src",
                \\  "variables": [ { "name": "n", "type": "?i32", "default": null } ],
                \\  "event": { "type": "OnCall" },
                \\  "nodes": [
                \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
                \\    { "id": 2, "type": "ClearVariable", "name": "n", "pos": [0, 0] }
                \\  ],
                \\  "edges": [],
                \\  "exec_edges": [
                \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
                \\  ]
                \\}
            ;
            try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, bad_src));
        }

        // Rejected: a loop source with the wrong exec pin (`then`, not
        // `body`).
        {
            const bad_pin =
                \\{
                \\  "name": "bad_pin",
                \\  "variables": [ { "name": "n", "type": "?i32", "default": null } ],
                \\  "event": { "type": "OnCall" },
                \\  "nodes": [
                \\    { "id": 1, "type": "ForRange", "pos": [0, 0] },
                \\    { "id": 2, "type": "ClearVariable", "name": "n", "pos": [0, 0] }
                \\  ],
                \\  "edges": [],
                \\  "exec_edges": [
                \\    { "from": { "node": 1, "pin": "then" }, "to": { "node": 2 } }
                \\  ]
                \\}
            ;
            try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, bad_pin));
        }
    }

    test "nested ForRange inside a While compounds body indentation" {
        const allocator = std.testing.allocator;
        // A While whose body is a ForRange whose body sets a variable —
        // the innermost statement nests under both loops.
        const src =
            \\{
            \\  "name": "nested",
            \\  "variables": [ { "name": "go", "type": "bool", "default": true }, { "name": "acc", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "go", "pos": [0, 0] },
            \\    { "id": 2, "type": "While", "pos": [0, 0] },
            \\    { "id": 3, "type": "ForRange", "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "acc", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "cond" } },
            \\    { "from": { "node": 3, "pin": "index" }, "to": { "node": 4, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "body" }, "to": { "node": 3 } },
            \\    { "from": { "node": 3, "pin": "body" }, "to": { "node": 4 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "nested" });
        defer allocator.free(out);

        // While re-reads `go`; the inner ForRange and its body nest deeper.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (go) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "var i_3: i32 = 0;") != null);
        // Innermost statement reads the inner loop var and is deeply nested.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "acc = i_3;") != null);

        try expectParses(allocator, out);
    }
};
