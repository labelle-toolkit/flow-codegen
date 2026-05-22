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

    test "renders OnUpdate event signature with custom arg_dt name" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{ "event": { "type": "OnUpdate", "arg_dt": "delta" }, "nodes": [], "edges": [] }
        , "demo");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onUpdate(game: *Game, delta: f32) void") != null);
    }

    test "renders OnCreate event signature" {
        const allocator = std.testing.allocator;
        const out = try render(allocator,
            \\{ "event": { "type": "OnCreate", "arg_entity": "self" }, "nodes": [], "edges": [] }
        , "spawn");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCreate(game: *Game, self: EntityId) void") != null);
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
    const void_subgraph =
        \\{
        \\  "name": "void_sub",
        \\  "event": { "type": "OnCall" },
        \\  "nodes": [
        \\    { "id": 1, "type": "GetComponent", "component": "Health", "pos": [0, 0] }
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
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn combat_subgraph(game: *Game, damage: f32) f32 {") != null);
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
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn void_sub(game: *Game) void {") != null);
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
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn multi(game: *Game, x: f32) multi_Result {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return .{") != null);
    }
};
