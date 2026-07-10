//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;
const expectParsesZig = helpers.expectParsesZig;

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

    test "rejects any top-level event header (flow-codegen#17)" {
        // Post-flow-codegen#17 the file-level `event:` header — including
        // the retired `OnCall` discriminator — is gone. A flow's trigger
        // is derived from its in-graph `Event` nodes, so ANY `event:` key
        // is rejected, even alongside a valid Event node.
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
            error.UnknownEventType,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "a flow with no Event node is a subgraph (flow-codegen#17)" {
        // RFC-FLOW-VOCABULARY §3: "a flow with zero Event nodes is a
        // subgraph" — the mechanism that superseded the `OnCall` header.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .subgraph);
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
    // issue #23 — flow-local (temporary) variables. `locals` lowers to a
    // function-scoped `var` at the top of the handler body, NOT a
    // module-level `pub var`. Mirrors the `variables` tests above.
    // =====================================================================

    test "codegen emits a function-local var for declared locals (not pub var)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "counter",
            \\  "locals": [
            \\    { "name": "tmp", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "tmp", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 3, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "tmp", "pos": [0, 0] }
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

        // A function-local `var` (with the never-mutated suppressor) —
        // NOT a module-level `pub var`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "var tmp: i32 = 0;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = &tmp;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var tmp") == null);

        // Get reads / Set writes the in-scope local by its bare name.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = tmp;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "tmp = n3_result;") != null);

        try expectParsesZig(allocator, out);
    }

    test "a local that is only Get compiles (never-mutated suppressed)" {
        // bugbot-class regression: a function-local `var` touched only by
        // `GetVariable` (never `SetVariable`/`ChangeVariable`) would trip
        // Zig's "local variable is never mutated, use const" — a real
        // semantic-analysis error `Ast.parse` does NOT catch. The trailing
        // `_ = &<name>;` takes the variable's address, defeating the lint.
        // We assert the suppressor is present (verified out-of-band to
        // pass `zig ast-check`, i.e. AstGen, not merely `Ast.parse`).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "reader",
            \\  "locals": [
            \\    { "name": "tmp", "type": "i32", "default": 7 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "tmp", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "reader" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "var tmp: i32 = 7;") != null);
        // The never-mutated suppressor immediately follows the decl.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "var tmp: i32 = 7;\n    _ = &tmp;") != null);
        // It is a function-local, never a module global.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var tmp") == null);

        try expectParsesZig(allocator, out);
    }

    test "file-scope variables still emit as pub var while locals stay in-body" {
        // A flow declaring BOTH a file var and a local: the file var is a
        // module-level `pub var`; the local is a function-body `var`.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "mixed",
            \\  "variables": [
            \\    { "name": "total", "type": "i32", "default": 0 }
            \\  ],
            \\  "locals": [
            \\    { "name": "scratch", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "ChangeVariable", "name": "total", "by": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "scratch", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "mixed" });
        defer allocator.free(out);

        // File var: module-level `pub var`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var total: i32 = 0;") != null);
        // Local: function-body `var`, never `pub var`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "var scratch: i32 = 0;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var scratch") == null);

        try expectParsesZig(allocator, out);
    }

    test "rejects a local whose name collides with a file variable" {
        // A function-local shadowing a module global is ambiguous (both
        // resolve to a bare `<name>` reference); reject it.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "clash",
            \\  "variables": [
            \\    { "name": "x", "type": "i32", "default": 0 }
            \\  ],
            \\  "locals": [
            \\    { "name": "x", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.DuplicateVariableName,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "rejects duplicate local names" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "dup_local",
            \\  "locals": [
            \\    { "name": "y", "type": "i32", "default": 0 },
            \\    { "name": "y", "type": "f32", "default": 1.0 }
            \\  ],
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(
            error.DuplicateVariableName,
            flow_io.parseFlow(allocator, src),
        );
    }

    test "round-trips a flow with locals through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "with_locals",
            \\  "locals": [
            \\    { "name": "tmp", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "ChangeVariable", "name": "tmp", "by": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        try expect.equal(l1.flow.locals.len, @as(usize, 1));
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.locals[0].name, "tmp"));

        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);
        // The `locals` block is written back.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"locals\":") != null);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(l2.flow.locals.len, @as(usize, 1));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "a flow without locals emits no locals key" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "no_locals",
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        try expect.equal(l1.flow.locals.len, @as(usize, 0));

        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);
        // Absence is preserved — no `locals` key.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"locals\":") == null);
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

    // =================================================================
    // Log node (flow-codegen#20) — builtin debug-print command.
    // =================================================================

    test "Log with a wired value + label lowers to a Debug-gated print with {any}" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "logger",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "42", "pos": [0, 0] },
            \\    { "id": 3, "type": "Log", "label": "mylabel", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "logger" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "if (@import(\"builtin\").mode == .Debug) std.debug.print(\"mylabel: {any}\\n\", .{n2_value});",
        ) != null);
        try expectParsesZig(allocator, out);
    }

    test "Log with no wired value emits a label-only print" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "logger",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 2, "type": "Log", "label": "ping", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "logger" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "if (@import(\"builtin\").mode == .Debug) std.debug.print(\"ping\\n\", .{});",
        ) != null);
        // No stray `{any}` placeholder when the value pin is unwired.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "ping: {any}") == null);
        try expectParsesZig(allocator, out);
    }

    test "Log label with a quote and a brace escapes into a valid format string" {
        const allocator = std.testing.allocator;
        // The label `say "{x}"` exercises both escaping hazards: the
        // double-quote must become `\"` (Zig string-literal escaping) and
        // the `{`/`}` must be doubled (`{{`/`}}`) so std.fmt reads them as
        // literal braces rather than a (broken) `{x}` placeholder.
        const src =
            \\{
            \\  "name": "logger",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 2, "type": "Log", "label": "say \"{x}\"", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "logger" });
        defer allocator.free(out);

        // Escaped quote + doubled braces appear in the emitted format
        // string, and the `\n` we append survives intact.
        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "std.debug.print(\"say \\\"{{x}}\\\"\\n\", .{});",
        ) != null);
        // A bare `{x}` placeholder must NOT survive — that would be an
        // invalid std.fmt specifier and fail compilation.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "say \\\"{x}\\\"") == null);
        try expectParsesZig(allocator, out);
    }

    test "Log label survives a parse -> write -> parse round trip" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "logger",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 2, "type": "Log", "label": "score = {n}", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), l1.flow.nodes[1].kind), .Log);
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.nodes[1].kind.Log.label, "score = {n}"));

        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), l2.flow.nodes[1].kind), .Log);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.nodes[1].kind.Log.label, "score = {n}"));

        // Deterministic writer — a second render is byte-identical.
        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "Log with an omitted label defaults to the empty string" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "logger",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "engine.tick", "pos": [0, 0] },
            \\    { "id": 2, "type": "Log", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.Log.label, ""));
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "logger" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "if (@import(\"builtin\").mode == .Debug) std.debug.print(\"\\n\", .{});",
        ) != null);
        try expectParsesZig(allocator, out);
    }
};
