//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;

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
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .subgraph);
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
