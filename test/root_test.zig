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
        \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
        \\  "nodes": [],
        \\  "edges": []
        \\}
    ;

    test "parses minimal flow with OnUpdate event" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator, minimal_on_update);
        defer loaded.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnUpdate);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.event.OnUpdate.arg_dt, "dt"));
        try expect.equal(loaded.flow.nodes.len, 0);
        try expect.equal(loaded.flow.edges.len, 0);
    }

    test "parses JSONC with comments and trailing commas" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  // entry point
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "1.5", "pos": [0, 0] }, /* a node */
            \\  ],
            \\  "edges": [],
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.flow.nodes.len, 1);
    }

    test "parses each flat NodeKind variant" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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

        try expect.equal(loaded.flow.nodes.len, 6);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .GetComponent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.GetComponent.type, "Position"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .SetField);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[2].kind), .BinOp);
        try expect.equal(loaded.flow.nodes[2].kind.BinOp.op, .mul);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[3].kind), .Literal);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[5].kind), .Call);
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
            \\    { "id": 7, "type": "Subflow", "flow": "combat", "bindings": { "damage": 25.0 }, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const sf = loaded.flow.nodes[0].kind.Subflow;
        try expect.toBeTrue(std.mem.eql(u8, sf.flow, "combat"));
        try expect.equal(sf.bindings.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, sf.bindings[0].param, "damage"));
        try expect.toBeTrue(std.mem.eql(u8, sf.bindings[0].value.zig_text, "25"));
    }

    test "parses each lifecycle Event variant" {
        const allocator = std.testing.allocator;

        const on_create =
            \\{ "event": { "type": "OnCreate", "arg_entity": "self" }, "nodes": [], "edges": [] }
        ;
        var l1 = try flow_io.parseFlow(allocator, on_create);
        defer l1.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l1.flow.event), .OnCreate);
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.event.OnCreate.arg_entity, "self"));

        const on_destroy =
            \\{ "event": { "type": "OnDestroy", "arg_entity": "victim" }, "nodes": [], "edges": [] }
        ;
        var l2 = try flow_io.parseFlow(allocator, on_destroy);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnDestroy);
    }

    test "parses an OnEvent event with callback params" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": {
            \\    "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin",
            \\    "params": [
            \\      { "name": "entity_a", "type": "u32" },
            \\      { "name": "entity_b", "type": "u32" }
            \\    ]
            \\  },
            \\  "nodes": [], "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnEvent);
        const ev = loaded.flow.event.OnEvent;
        // Legacy form: `module`+`callback` set, `name` null.
        try expect.toBeTrue(ev.name == null);
        try expect.toBeTrue(std.mem.eql(u8, ev.module.?, "box2d"));
        try expect.toBeTrue(std.mem.eql(u8, ev.callback.?, "on_collision_begin"));
        try expect.equal(ev.params.len, @as(usize, 2));
        try expect.toBeTrue(std.mem.eql(u8, ev.params[0].name, "entity_a"));
        try expect.toBeTrue(std.mem.eql(u8, ev.params[1].type, "u32"));
    }

    test "round-trips an OnEvent flow through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "on_hit",
            \\  "event": {
            \\    "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin",
            \\    "params": [ { "name": "a", "type": "u32" }, { "name": "b", "type": "u32" } ]
            \\  },
            \\  "nodes": [], "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnEvent);
        try expect.equal(l2.flow.event.OnEvent.params.len, @as(usize, 2));

        // Idempotent re-render (RFC open question 3 — stable re-save).
        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "parses a new-form OnEvent with the name field" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §7: the new form names the event and lets
        // the assembler's resolver derive the payload type. `module` /
        // `callback` / `params` are absent.
        const src =
            \\{
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [], "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnEvent);
        const ev = loaded.flow.event.OnEvent;
        try expect.toBeTrue(ev.name != null);
        try expect.toBeTrue(std.mem.eql(u8, ev.name.?, "box2d.collision_begin"));
        try expect.toBeTrue(ev.module == null);
        try expect.toBeTrue(ev.callback == null);
        try expect.equal(ev.params.len, @as(usize, 0));
    }

    test "round-trips a new-form OnEvent flow through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "on_collision",
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [], "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnEvent);
        try expect.toBeTrue(l2.flow.event.OnEvent.name != null);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnEvent.name.?, "box2d.collision_begin"));
        // Legacy fields stay null on the round-tripped form.
        try expect.toBeTrue(l2.flow.event.OnEvent.module == null);
        try expect.toBeTrue(l2.flow.event.OnEvent.callback == null);

        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "rejects an OnEvent with both name and legacy fields set" {
        const allocator = std.testing.allocator;
        // Exactly one form (`name` xor `module`+`callback`) is allowed.
        // Mixing them is a malformed flow.
        const src =
            \\{
            \\  "event": {
            \\    "type": "OnEvent", "name": "box2d.collision_begin",
            \\    "module": "box2d", "callback": "on_collision_begin"
            \\  },
            \\  "nodes": [], "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "rejects an OnEvent with neither name nor legacy fields set" {
        const allocator = std.testing.allocator;
        // An empty `OnEvent` event payload — no resolver name, no
        // legacy callback — is unparseable.
        const src =
            \\{
            \\  "event": { "type": "OnEvent" },
            \\  "nodes": [], "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "rejects an OnEvent with a partial legacy form (module only)" {
        const allocator = std.testing.allocator;
        // `module` without `callback` (or vice versa) is structurally
        // incomplete — neither form is satisfied.
        const src =
            \\{
            \\  "event": { "type": "OnEvent", "module": "box2d" },
            \\  "nodes": [], "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Nonsense", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Identifier", "name": "a", "pos": [0, 0] } ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 99, "pin": "y" } } ]
            \\}
        ;
        try std.testing.expectError(error.DanglingLink, flow_io.parseFlow(allocator, src));
    }

    test "rejects node id == 0" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 0, "type": "Identifier", "name": "a", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
        try expect.equal(l2.flow.nodes.len, 2);
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Literal", "value": "1", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        );
        defer l1.deinit();

        try flow_io.saveFlow(std.testing.io, allocator, path, l1);

        var l2 = try flow_io.loadFromFile(std.testing.io, allocator, path);
        defer l2.deinit();

        try expect.equal(l2.flow.nodes.len, 1);
        // loadFromFile derives the effective name from the basename.
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.name, "demo"));
    }

    test "legacy_onevent_to_name rewrites module + callback to a dotted name" {
        const allocator = std.testing.allocator;
        // RFC-PLUGIN-EVENTS §7 Migration "Flow side" — the converter
        // walks a legacy `OnEvent` (`module` + `callback`) and produces
        // the new `name`-resolved shape. Callback name's `on_` prefix
        // is stripped (RFC §1 — merged-union variant names drop the
        // C-callback prefix), `params` clears, `module`/`callback`
        // null out. Output round-trips through `renderFlowJsonc`.
        var legacy = try flow_io.parseFlow(allocator,
            \\{
            \\  "name": "hit_counter",
            \\  "event": {
            \\    "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin",
            \\    "params": [
            \\      { "name": "entity_a", "type": "u32" },
            \\      { "name": "entity_b", "type": "u32" }
            \\    ]
            \\  },
            \\  "nodes": [], "edges": []
            \\}
        );
        defer legacy.deinit();

        var converted = try flow_io.legacy_onevent_to_name(allocator, legacy);
        defer converted.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.Event), converted.flow.event), .OnEvent);
        const ev = converted.flow.event.OnEvent;
        try expect.toBeTrue(ev.name != null);
        try expect.toBeTrue(std.mem.eql(u8, ev.name.?, "box2d.collision_begin"));
        try expect.toBeTrue(ev.module == null);
        try expect.toBeTrue(ev.callback == null);
        try expect.equal(ev.params.len, @as(usize, 0));
        // Effective name carries over unchanged.
        try expect.toBeTrue(std.mem.eql(u8, converted.flow.name, "hit_counter"));

        // Round-trip the rewritten flow through `renderFlowJsonc`. The
        // re-parsed flow lands on the new form too — the writer emits
        // the `name`-only `OnEvent`, the parser accepts it.
        const rendered = try flow_io.renderFlowJsonc(allocator, converted);
        defer allocator.free(rendered);
        var reloaded = try flow_io.parseFlow(allocator, rendered);
        defer reloaded.deinit();
        try expect.toBeTrue(reloaded.flow.event.OnEvent.name != null);
        try expect.toBeTrue(std.mem.eql(u8, reloaded.flow.event.OnEvent.name.?, "box2d.collision_begin"));
        try expect.toBeTrue(reloaded.flow.event.OnEvent.module == null);
    }

    test "legacy_onevent_to_name passes through a callback with no on_ prefix" {
        const allocator = std.testing.allocator;
        // A plugin that didn't follow the `on_` callback convention
        // (e.g. `physics_started`) keeps its callback name verbatim —
        // mismatches against the `PluginEvents` set fall out at
        // codegen, not in the converter (which has no resolver handle).
        var legacy = try flow_io.parseFlow(allocator,
            \\{
            \\  "event": { "type": "OnEvent", "module": "physics", "callback": "physics_started" },
            \\  "nodes": [], "edges": []
            \\}
        );
        defer legacy.deinit();
        var converted = try flow_io.legacy_onevent_to_name(allocator, legacy);
        defer converted.deinit();
        try expect.toBeTrue(std.mem.eql(u8, converted.flow.event.OnEvent.name.?, "physics.physics_started"));
    }

    test "legacy_onevent_to_name rejects a non-OnEvent flow" {
        const allocator = std.testing.allocator;
        var lifecycle = try flow_io.parseFlow(allocator,
            \\{ "event": { "type": "OnCreate", "arg_entity": "entity" }, "nodes": [], "edges": [] }
        );
        defer lifecycle.deinit();
        try std.testing.expectError(
            error.NotOnEvent,
            flow_io.legacy_onevent_to_name(allocator, lifecycle),
        );
    }

    test "legacy_onevent_to_name rejects an already-new-form OnEvent flow" {
        const allocator = std.testing.allocator;
        var already_new = try flow_io.parseFlow(allocator,
            \\{
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [], "edges": []
            \\}
        );
        defer already_new.deinit();
        try std.testing.expectError(
            error.OnEventAlreadyNew,
            flow_io.legacy_onevent_to_name(allocator, already_new),
        );
    }

    test "legacy_onevent_to_name preserves nodes and edges" {
        const allocator = std.testing.allocator;
        // The graph survives the rewrite — node ids, kinds, params,
        // edges all carry over unchanged. The new form keeps the same
        // body the legacy form had, just with a different event
        // dispatch shape around it.
        var legacy = try flow_io.parseFlow(allocator,
            \\{
            \\  "event": { "type": "OnEvent", "module": "box2d", "callback": "on_collision_end" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "1", "pos": [0, 0] },
            \\    { "id": 2, "type": "Call", "callee": "doStuff", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } } ]
            \\}
        );
        defer legacy.deinit();
        var converted = try flow_io.legacy_onevent_to_name(allocator, legacy);
        defer converted.deinit();
        try expect.equal(converted.flow.nodes.len, @as(usize, 2));
        try expect.equal(converted.flow.edges.len, @as(usize, 1));
        try expect.toBeTrue(std.mem.eql(u8, converted.flow.event.OnEvent.name.?, "box2d.collision_end"));
    }
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

    test "renders OnUpdate event as the engine per-frame `tick` entry" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{ "event": { "type": "OnUpdate", "arg_dt": "delta" }, "nodes": [], "edges": [] }
        , "demo");
        defer allocator.free(out);
        // `OnUpdate` lowers to `tick` — the script-runner's per-frame
        // entry point — so the flow is actually dispatched each frame.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn tick(game: anytype, delta: f32) void") != null);
    }

    test "renders OnCreate event signature" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{ "event": { "type": "OnCreate", "arg_entity": "self" }, "nodes": [], "edges": [] }
        , "spawn");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCreate(game: anytype, self: EntityId) void") != null);
    }

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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Literal", "value": "1.5", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 2, "type": "BinOp", "op": "mul", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        , "binop");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = 0 * 0;") != null);
    }

    test "renders GetComponent node with component @import" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [ { "id": 3, "type": "GetComponent", "component": "Position", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        , "get");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = game.getComponent(entity, Position) orelse return;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const Position = @import(\"../../components/Position.zig\").Position;") != null);
    }

    test "renders SetField sourced from a Literal" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
            \\    { "id": 4, "type": "Literal", "value": "42", "pos": [0, 0] },
            \\    { "id": 5, "type": "SetField", "target": "Position.x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 4, "pin": "value" }, "to": { "node": 5, "pin": "value" } } ]
            \\}
        , "setf");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n4_value);") != null);
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
            \\  "event": { "type": "OnCreate", "arg_entity": "self" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
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

    test "lifecycle flow mixes wired and unwired entity-scoped nodes" {
        const allocator = std.testing.allocator;
        // One `GetComponent` wires its entity pin; another reads bare
        // `entity` from the lifecycle param. The lifecycle binding
        // stays in place — `anyNeedsBareEntity` triggers it — and the
        // wired node still gets the wired expression.
        const out = try render(allocator,
            \\{
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Identifier", "name": "other", "pos": [0, 0] },
            \\    { "id": 2, "type": "GetComponent", "component": "Position", "pos": [0, 0] },
            \\    { "id": 3, "type": "GetComponent", "component": "Health", "pos": [0, 0] }
            \\  ],
            \\  "edges": [ { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "entity" } } ]
            \\}
        , "mixed_get");
        defer allocator.free(out);
        // Node 2 reads the wired expression; node 3 falls back to
        // the in-scope lifecycle `entity`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.getComponent(n1_value, Position)") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.getComponent(entity, Health)") != null);
    }

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
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [], "edges": []
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
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [ { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [ { "id": 1, "type": "Emit", "event": "my_game.bare", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
            \\    { "id": 1, "type": "SetField", "target": "Position.x", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": "5", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 2, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "result" }, "to": { "node": 1, "pin": "value" } }
            \\  ]
            \\}
        , "topo");
        defer allocator.free(out);
        const lit = std.mem.indexOf(u8, out, "const n3_value = 5;").?;
        const bin = std.mem.indexOf(u8, out, "const n2_result = n3_value + 0;").?;
        const set = std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n2_result);").?;
        try expect.toBeTrue(lit < bin);
        try expect.toBeTrue(bin < set);
    }

    test "rejects graph cycle" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator,
            \\{
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [ { "id": 1, "type": "SetField", "target": "Position.x", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [ { "id": 1, "type": "GetComponent", "component": "foo.bar.Baz", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetField", "target": "Position.x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
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

    test "renders an OnEvent flow as a callback handler and setup registrar" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{
            \\  "event": {
            \\    "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin",
            \\    "params": [
            \\      { "name": "entity_a", "type": "u32" },
            \\      { "name": "entity_b", "type": "u32" }
            \\    ]
            \\  },
            \\  "nodes": [], "edges": []
            \\}
        , "on_hit");
        defer allocator.free(out);
        // The handler's signature matches the plugin callback verbatim,
        // so `&flowEvent` is assignable to its `?*const fn(...)` slot.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn flowEvent(entity_a: u32, entity_b: u32) void") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const __event_src = @import(\"box2d\");") != null);
        // `setup` is the registrar the script-runner discovers + calls.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn setup(game: anytype) void") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__event_src.on_collision_begin = &flowEvent;") != null);
        // An event param the body never reads is discarded.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = entity_a;") != null);
    }

    test "OnEvent flow output passes std.zig.Ast.parse" {
        const allocator = std.testing.allocator;
        // The bouncing-ball demo shape: read a total, add one, store it.
        const out = try render(allocator,
            \\{
            \\  "event": {
            \\    "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin",
            \\    "params": [ { "name": "a", "type": "u32" }, { "name": "b", "type": "u32" } ]
            \\  },
            \\  "nodes": [
            \\    { "id": 1, "type": "Call", "callee": "currentTotal", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "1", "pos": [0, 0] },
            \\    { "id": 3, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 4, "type": "Call", "callee": "setTotal", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "result" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "arg0" } }
            \\  ]
            \\}
        , "hit_counter");
        defer allocator.free(out);
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);
        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        try expect.equal(ast.errors.len, @as(usize, 0));
    }

    test "rejects an entity-scoped node in an OnEvent flow" {
        const allocator = std.testing.allocator;
        // An OnEvent handler runs from a plugin callback — no `game`,
        // no `entity` — so a `GetComponent` node cannot be lowered.
        var loaded = try flow_io.parseFlow(allocator,
            \\{
            \\  "event": { "type": "OnEvent", "module": "box2d", "callback": "on_x" },
            \\  "nodes": [ { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        );
        defer loaded.deinit();
        try std.testing.expectError(
            error.EntityUnavailableInSubgraph,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "bad" }),
        );
    }
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "loopy", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "multi", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "b", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "wrapper", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "needs_entity", "pos": [0, 0] } ],
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
            \\  "event": { "type": "OnUpdate", "arg_dt": "dt" },
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "odd_names", "pos": [0, 0] } ],
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
        .nodes = &.{},
        .edges = &.{},
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

    test "allows a subgraph param named after a lifecycle arg" {
        const allocator = std.testing.allocator;
        // A reusable flow declared with `OnUpdate` but referenced as a
        // subgraph emits `fn (game, <params>)` — no `dt` arg — so a
        // param named `dt` is NOT a collision (regression: the
        // collision check must not reserve a subgraph's lifecycle arg).
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
            .event = flow_io.Event{ .OnUpdate = .{} },
            .params = &sub_params,
            .nodes = &sub_nodes,
            .edges = &sub_edges,
        });
        var entry_nodes = [_]flow_io.Node{
            .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Subflow = .{ .flow = "tick_helper" } } },
        };
        const entry = FlowFactory.build(.{
            .name = "uses_tick_helper",
            .event = flow_io.Event{ .OnUpdate = .{} },
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
