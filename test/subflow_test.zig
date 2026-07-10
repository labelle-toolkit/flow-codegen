//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;

pub const SubflowTests = struct {
    // A reusable subgraph: one f32 param, one f32 output.
    const combat_subgraph =
        \\{
        \\  "name": "combat_subgraph",
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
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "b", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const flow_b =
            \\{
            \\  "name": "b",
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
            \\  "nodes": [ { "id": 1, "type": "Subflow", "flow": "combat_subgraph", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        const right =
            \\{
            \\  "name": "right",
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
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        const ab_under =
            \\{
            \\  "name": "a_b",
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
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        // Entry is an OnCall flow → its `pub fn` is `onCall`.
        const entry_src =
            \\{
            \\  "name": "uses_oncall_named",
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

    test "subgraph entry with a single Output returns it" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "scoring",
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

    test "subgraph entry with multiple Outputs returns a result struct" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "stats",
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
