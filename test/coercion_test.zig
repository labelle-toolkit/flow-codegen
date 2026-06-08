//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;

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

    test "While cond reporters inlined-only are suppressed (no orphan bindings)" {
        // bugbot HIGH (flow-codegen#21): `Compare(GetVariable x, Literal 10)
        // → While.cond` inlines the comparison into the `while` header. The
        // Compare/GetVariable/Literal reporters feed ONLY the cond, so their
        // `n<id>_…` bindings would be orphaned, unused `const`s → a Zig
        // "unused local constant" compile error. They must be suppressed.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "wh_suppress",
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
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "wh_suppress" });
        defer allocator.free(out);

        // The header still inlines the condition.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while ((x < 10)) {") != null);
        // NONE of the inlined-only reporters emit a binding before the loop.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n3_result") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n1_value") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n2_value") == null);
        // No `const n…` binding at all survives this flow (all reporters
        // were inlined into the header).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n") == null);
        // …and their preview pulses are gone too (no emit for node 1/2/3).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "emitNodeEntered(\"wh_suppress\", 1)") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "emitNodeEntered(\"wh_suppress\", 3)") == null);

        try expectParses(allocator, out);
    }

    test "While cond reporter shared with a real consumer keeps its binding" {
        // Precision (flow-codegen#21): a reporter inlined into a `While.cond`
        // but ALSO feeding a real consumer must KEEP its binding — only the
        // cond inlines a separate recomputed copy. Here `GetVariable x`
        // feeds both the Compare (cond) and a `SetVariable y` command, so
        // `n1_value` is still referenced and must be emitted.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "wh_shared",
            \\  "variables": [ { "name": "x", "type": "i32", "default": 0 }, { "name": "y", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "x", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 10, "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "lt", "pos": [0, 0] },
            \\    { "id": 4, "type": "While", "pos": [0, 0] },
            \\    { "id": 5, "type": "ChangeVariable", "name": "x", "by": 1, "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "y", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "a" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "b" } },
            \\    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "cond" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 6, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 4, "pin": "body" }, "to": { "node": 5 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "wh_shared" });
        defer allocator.free(out);

        // The cond still inlines a recomputed copy.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while ((x < 10)) {") != null);
        // GetVariable x is shared → its binding survives and is referenced
        // by the SetVariable.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = x;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "y = n1_value;") != null);
        // The Compare and Literal feed ONLY the cond → still suppressed.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n3_result") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n2_value") == null);

        try expectParses(allocator, out);
    }

    test "ForRange index consumed outside the loop body is rejected" {
        // bugbot MEDIUM (flow-codegen#21): a node OUTSIDE the loop body that
        // reads `ForRange.index` would emit `i_<id>` out of scope. Codegen
        // rejects it (`error.MalformedFlow`) rather than emit uncompilable
        // Zig. Here a top-level SetVariable reads the index but is NOT wired
        // to the loop's `body` exec edge, so its scope is top-level.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "fr_oos",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForRange", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "index" }, "to": { "node": 2, "pin": "value" } }
            \\  ],
            \\  "exec_edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.MalformedFlow,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "fr_oos" }),
        );
    }

    // =====================================================================
    // Select — pure-expression multi-way picker (flow-codegen#22)
    // =====================================================================

    test "Select lowers to an inline switch expression with wired cases" {
        // `selector` picks among `case0`/`case1` value inputs, falling back
        // to `default` for the `else` prong. The whole thing is a pure
        // expression bound to `n<id>_result` — no exec edges.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sel_basic",
            \\  "variables": [ { "name": "picked", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 10, "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 20, "pos": [0, 0] },
            \\    { "id": 4, "type": "Literal", "value": 99, "pos": [0, 0] },
            \\    { "id": 5, "type": "Select", "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "picked", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 5, "pin": "selector" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 5, "pin": "case0" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 5, "pin": "case1" } },
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 5, "pin": "default" } },
            \\    { "from": { "node": 5, "pin": "result" }, "to": { "node": 6, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "sel_basic" });
        defer allocator.free(out);

        // The inline switch expression, bound to the reporter's result.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n5_result = switch (n1_value) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "0 => n2_value,") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "1 => n3_value,") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "else => n4_value,") != null);
        // The result is consumed downstream — no orphan binding.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "picked = n5_result;") != null);

        try expectParses(allocator, out);
    }

    test "Select with unwired selector/default falls back to compiling values" {
        // Unwired `selector` → `0`; unwired `default` → the last wired
        // case's expression (so the `else` prong matches a real value).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sel_defaults",
            \\  "variables": [ { "name": "picked", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 2, "type": "Select", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "picked", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "case0" } },
            \\    { "from": { "node": 2, "pin": "result" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "sel_defaults" });
        defer allocator.free(out);

        // Unwired selector defaults to 0; the lone case0 is also the else
        // fallback (last wired case), so no bare `0` of unknown type.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = switch (0) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "0 => n1_value,") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "else => n1_value,") != null);

        try expectParses(allocator, out);
    }

    // =====================================================================
    // Switch — N-way control-flow branch (flow-codegen#22)
    // =====================================================================

    test "Switch lowers to a switch statement with each case's command nested" {
        // `selector` gates an N-way `switch` statement; each `case<N>` exec
        // output nests its commands in a `N => { … }` prong, and `default`
        // becomes the `else => { … }` prong.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sw_basic",
            \\  "variables": [
            \\    { "name": "a", "type": "i32", "default": 0 },
            \\    { "name": "b", "type": "i32", "default": 0 },
            \\    { "name": "c", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "Switch", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 11, "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "a", "pos": [0, 0] },
            \\    { "id": 5, "type": "Literal", "value": 22, "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "b", "pos": [0, 0] },
            \\    { "id": 7, "type": "Literal", "value": 33, "pos": [0, 0] },
            \\    { "id": 8, "type": "SetVariable", "name": "c", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "selector" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } },
            \\    { "from": { "node": 5, "pin": "value" }, "to": { "node": 6, "pin": "value" } },
            \\    { "from": { "node": 7, "pin": "value" }, "to": { "node": 8, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "case0" }, "to": { "node": 4 } },
            \\    { "from": { "node": 2, "pin": "case1" }, "to": { "node": 6 } },
            \\    { "from": { "node": 2, "pin": "default" }, "to": { "node": 8 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "sw_basic" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "switch (n1_value) {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "0 => {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "1 => {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "else => {") != null);
        // Each side's command nests one level deeper than the switch
        // (8-space indent under the entry fn's 4).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "            a = n3_value;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "            b = n5_value;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "            c = n7_value;") != null);

        try expectParses(allocator, out);
    }

    test "Switch with unwired default emits an exhaustive empty else prong" {
        // No `default` exec edge → an empty `else => {}` so the lowered Zig
        // switch stays exhaustive.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sw_noelse",
            \\  "variables": [ { "name": "a", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Switch", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 5, "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "a", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "selector" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "case0" }, "to": { "node": 4 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "sw_noelse" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "0 => {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "else => {},") != null);

        try expectParses(allocator, out);
    }

    test "Switch sinks a reporter used only inside one case into that prong" {
        // A reporter (GetVariable) read only by a command in `case0` must
        // sink into that prong, after the write — mirroring the Branch
        // reporter-sinking test.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sw_sink",
            \\  "variables": [
            \\    { "name": "count", "type": "i32", "default": 0 },
            \\    { "name": "mirror", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Switch", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 5, "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "count", "pos": [0, 0] },
            \\    { "id": 5, "type": "GetVariable", "name": "count", "pos": [0, 0] },
            \\    { "id": 6, "type": "SetVariable", "name": "mirror", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "selector" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } },
            \\    { "from": { "node": 5, "pin": "value" }, "to": { "node": 6, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "case0" }, "to": { "node": 4 } },
            \\    { "from": { "node": 2, "pin": "case0" }, "to": { "node": 6 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "sw_sink" });
        defer allocator.free(out);

        const switch_at = std.mem.indexOf(u8, out, "switch (n1_value) {");
        const write_at = std.mem.indexOf(u8, out, "count = n3_value;");
        const read_at = std.mem.indexOf(u8, out, "const n5_value = count;");
        try expect.toBeTrue(switch_at != null);
        try expect.toBeTrue(write_at != null);
        try expect.toBeTrue(read_at != null);
        // The read sinks into the prong, after both the switch header and
        // the write (read-after-write preserved).
        try expect.toBeTrue(read_at.? > switch_at.?);
        try expect.toBeTrue(read_at.? > write_at.?);
        // Sunk one level deep — 12-space indent (switch prong block).
        try expect.toBeTrue(std.mem.indexOf(u8, out, "            const n5_value = count;") != null);

        try expectParses(allocator, out);
    }

    test "Switch is a valid exec source (pin case0 / default)" {
        // A `Switch`'s `case<N>` and `default` are valid exec-edge sources
        // — the loader accepts them like a Branch's then/else.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sw_validsrc",
            \\  "variables": [
            \\    { "name": "a", "type": "i32", "default": 0 },
            \\    { "name": "x", "type": "?i32", "default": null }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Switch", "pos": [0, 0] },
            \\    { "id": 3, "type": "ClearVariable", "name": "x", "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "a", "pos": [0, 0] },
            \\    { "id": 5, "type": "Literal", "value": 1, "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "selector" } },
            \\    { "from": { "node": 5, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "case0" }, "to": { "node": 3 } },
            \\    { "from": { "node": 2, "pin": "default" }, "to": { "node": 4 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "sw_validsrc" });
        defer allocator.free(out);
        try expectParses(allocator, out);
    }

    test "Switch with an invalid exec pin is rejected" {
        // A `Switch` exec edge from a non-case/non-default pin is malformed
        // — only `case<N>` / `default` are valid exec sources.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sw_badpin",
            \\  "variables": [ { "name": "x", "type": "?i32", "default": null } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Switch", "pos": [0, 0] },
            \\    { "id": 3, "type": "ClearVariable", "name": "x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "selector" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "then" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "non-control node is not a valid exec source (Select rejected)" {
        // A pure reporter like `Select` has no exec outputs — an exec edge
        // originating from it is malformed.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "sel_notexec",
            \\  "variables": [ { "name": "x", "type": "?i32", "default": null } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Select", "pos": [0, 0] },
            \\    { "id": 2, "type": "ClearVariable", "name": "x", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "case0" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    // =====================================================================
    // Collections — growable LIST ops + ForEach (flow-codegen#24)
    // =====================================================================

    test "collections block emits a module-level std.ArrayList pub var" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_decl",
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_decl" });
        defer allocator.free(out);

        // Game-allocator-backed, `.empty`-init module `pub var`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var scores: std.ArrayList(u32) = .empty;") != null);

        try expectParses(allocator, out);
    }

    test "ListAppend lowers to append(game.allocator, value) catch {}" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_append",
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 2, "type": "ListAppend", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_append" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "scores.append(game.allocator, n1_value) catch {};") != null);

        try expectParses(allocator, out);
    }

    test "ListLength binds .items.len and is consumed downstream" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_len",
            \\  "variables": [ { "name": "n", "type": "usize", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ListLength", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "n", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_len" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = scores.items.len;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n = n1_value;") != null);

        try expectParses(allocator, out);
    }

    test "ListGet reads items[index] directly" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_get",
            \\  "variables": [ { "name": "v", "type": "u32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "ListGet", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "v", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "index" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_get" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value = scores.items[n1_value];") != null);

        try expectParses(allocator, out);
    }

    test "ListSet writes items[index] = value" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_set",
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 9, "pos": [0, 0] },
            \\    { "id": 3, "type": "ListSet", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "index" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_set" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "scores.items[n1_value] = n2_value;") != null);

        try expectParses(allocator, out);
    }

    test "ListContains lowers to a for-else membership scan binding a bool" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_contains",
            \\  "variables": [ { "name": "has", "type": "bool", "default": false } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 5, "pos": [0, 0] },
            \\    { "id": 2, "type": "ListContains", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "has", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_contains" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value = for (scores.items) |__e| { if (__e == n1_value) break true; } else false;") != null);

        try expectParses(allocator, out);
    }

    test "ListClear lowers to clearRetainingCapacity" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_clear",
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ListClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "list_clear" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "scores.clearRetainingCapacity();") != null);

        try expectParses(allocator, out);
    }

    test "ForEach lowers to a for over items with item/index captures and nested body" {
        const allocator = std.testing.allocator;
        // Body reads BOTH `item` and `index`, so both captures are live.
        const src =
            \\{
            \\  "name": "foreach_basic",
            \\  "variables": [
            \\    { "name": "sum", "type": "u32", "default": 0 },
            \\    { "name": "last", "type": "usize", "default": 0 }
            \\  ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "sum", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "last", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "item" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 1, "pin": "index" }, "to": { "node": 3, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } },
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "foreach_basic" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "for (scores.items, 0..) |item_1, idx_1| {") != null);
        // Body nodes reference the captures, NOT n<id>_ bindings.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "sum = item_1;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "last = idx_1;") != null);
        // Body nested one level under the entry fn → 8-space indent.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        sum = item_1;") != null);

        try expectParses(allocator, out);
    }

    test "ForEach uses _ for an unread capture (no unused-capture error)" {
        const allocator = std.testing.allocator;
        // Body reads only `item` — the `index` capture must become `_`.
        const src =
            \\{
            \\  "name": "foreach_item_only",
            \\  "variables": [ { "name": "sum", "type": "u32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "sum", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "item" }, "to": { "node": 2, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "foreach_item_only" });
        defer allocator.free(out);

        // The unread `index` capture is `_`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "for (scores.items, 0..) |item_1, _| {") != null);

        try expectParses(allocator, out);
    }

    test "ForEach with a body that reads neither capture emits both as _" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "foreach_neither",
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "ListClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "foreach_neither" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "for (scores.items, 0..) |_, _| {") != null);

        try expectParses(allocator, out);
    }

    test "a collection name colliding with a variable is rejected" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_clash_var",
            \\  "variables": [ { "name": "scores", "type": "i32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.DuplicateVariableName, flow_io.parseFlow(allocator, src));
    }

    test "a collection name colliding with a local is rejected" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_clash_local",
            \\  "locals": [ { "name": "scores", "type": "i32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.DuplicateVariableName, flow_io.parseFlow(allocator, src));
    }

    test "a list node naming an undeclared collection is rejected" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_unknown",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ListClear", "collection": "ghost", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.UnknownCollection, flow_io.parseFlow(allocator, src));
    }

    test "a list node on a map collection is rejected (kind mismatch, bugbot)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "kind_mismatch",
            \\  "event": { "type": "OnCall" },
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "ListClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedCollection, flow_io.parseFlow(allocator, src));
    }

    test "a map node on a list collection is rejected (kind mismatch, bugbot)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "kind_mismatch2",
            \\  "event": { "type": "OnCall" },
            \\  "collections": [ { "name": "xs", "element": "u32" } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "MapClear", "collection": "xs", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedCollection, flow_io.parseFlow(allocator, src));
    }

    test "ForEach item consumed outside the body scope is rejected" {
        // Mirrors the ForRange.index out-of-scope test: a top-level
        // SetVariable reads ForEach.item but is NOT wired to the loop's
        // `body` exec edge, so its scope is top-level → out-of-scope read.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "foreach_oos",
            \\  "variables": [ { "name": "out", "type": "u32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "item" }, "to": { "node": 2, "pin": "value" } }
            \\  ],
            \\  "exec_edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.MalformedFlow,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "foreach_oos" }),
        );
    }

    test "round-trips collections + list/ForEach nodes through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_roundtrip",
            \\  "collections": [ { "name": "scores", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "ForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "ListClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        // The `collections` block and the `collection` field survive.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"collections\": [") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"name\": \"scores\", \"element\": \"u32\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"type\": \"ForEach\", \"collection\": \"scores\"") != null);

        // Re-parse → re-render is byte-stable.
        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "absence of a collections block is preserved on round-trip" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "no_collections",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);
        // No `collections` block emitted when none declared.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"collections\"") == null);
    }

    // =====================================================================
    // Collections — MAP ops + MapForEach (flow-codegen#24, MAPS)
    // =====================================================================

    test "map collections block emits a module-level std.AutoHashMapUnmanaged pub var" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_decl",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_decl" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var scores: std.AutoHashMapUnmanaged(u32, i32) = .empty;") != null);

        try expectParses(allocator, out);
    }

    test "MapSet lowers to put(game.allocator, key, value) catch {}" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_set",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 3, "type": "MapSet", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "key" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_set" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "scores.put(game.allocator, n1_value, n2_value) catch {};") != null);

        try expectParses(allocator, out);
    }

    test "MapGet lowers to get(key) orelse default" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_get",
            \\  "variables": [ { "name": "v", "type": "i32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": -1, "pos": [0, 0] },
            \\    { "id": 3, "type": "MapGet", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "v", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "key" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "default" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_get" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = scores.get(n1_value) orelse n2_value;") != null);

        try expectParses(allocator, out);
    }

    test "MapGet default defaults to 0 when the default input is unwired" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_get_nodef",
            \\  "variables": [ { "name": "v", "type": "i32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 2, "type": "MapGet", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "v", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "key" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_get_nodef" });
        defer allocator.free(out);

        // Unwired `default` mirrors ListGet's convention → bare `0`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value = scores.get(n1_value) orelse 0;") != null);

        try expectParses(allocator, out);
    }

    test "MapHas lowers to contains(key) binding a bool" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_has",
            \\  "variables": [ { "name": "h", "type": "bool", "default": false } ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 5, "pos": [0, 0] },
            \\    { "id": 2, "type": "MapHas", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "h", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "key" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_has" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_value = scores.contains(n1_value);") != null);

        try expectParses(allocator, out);
    }

    test "MapRemove lowers to _ = remove(key)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_remove",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 5, "pos": [0, 0] },
            \\    { "id": 2, "type": "MapRemove", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "key" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_remove" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = scores.remove(n1_value);") != null);

        try expectParses(allocator, out);
    }

    test "MapLength lowers to count() and MapClear to clearRetainingCapacity" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_len_clear",
            \\  "variables": [ { "name": "n", "type": "usize", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "MapLength", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "n", "pos": [0, 0] },
            \\    { "id": 3, "type": "MapClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "map_len_clear" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = scores.count();") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "scores.clearRetainingCapacity();") != null);

        try expectParses(allocator, out);
    }

    test "MapForEach lowers to an iterator while-loop with key/value captures and nested body" {
        const allocator = std.testing.allocator;
        // Body reads BOTH `key` and `value` → entry is captured + read.
        const src =
            \\{
            \\  "name": "mapforeach_basic",
            \\  "variables": [
            \\    { "name": "ksum", "type": "u32", "default": 0 },
            \\    { "name": "vsum", "type": "i32", "default": 0 }
            \\  ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "MapForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "ksum", "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "vsum", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "key" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } },
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "mapforeach_basic" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "var it_1 = scores.iterator();") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (it_1.next()) |entry_1| {") != null);
        // Body nodes read the entry's key_ptr/value_ptr, NOT n<id>_ bindings.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "ksum = entry_1.key_ptr.*;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "vsum = entry_1.value_ptr.*;") != null);
        // Body nested one level under the entry fn → 8-space indent.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "        ksum = entry_1.key_ptr.*;") != null);
        // The entry is read, so no `_ = entry_1;` suppressor.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = entry_1;") == null);

        try expectParses(allocator, out);
    }

    test "MapForEach with a body that reads neither capture suppresses the unused entry" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "mapforeach_neither",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "MapForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "MapClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "mapforeach_neither" });
        defer allocator.free(out);

        // The entry is captured (always) but unread → suppressed.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (it_1.next()) |entry_1| {") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = entry_1;") != null);

        try expectParses(allocator, out);
    }

    test "MapForEach key consumed outside the body scope is rejected" {
        // A top-level SetVariable reads MapForEach.key but is NOT wired to
        // the loop's `body` exec edge → out-of-scope read.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "mapforeach_oos",
            \\  "variables": [ { "name": "out", "type": "u32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "MapForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "out", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "key" }, "to": { "node": 2, "pin": "value" } }
            \\  ],
            \\  "exec_edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.MalformedFlow,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "mapforeach_oos" }),
        );
    }

    test "a map collection name colliding with a variable is rejected" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_clash_var",
            \\  "variables": [ { "name": "scores", "type": "i32", "default": 0 } ],
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.DuplicateVariableName, flow_io.parseFlow(allocator, src));
    }

    test "a map missing key is rejected (MalformedCollection)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_no_key",
            \\  "collections": [ { "name": "scores", "kind": "map", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedCollection, flow_io.parseFlow(allocator, src));
    }

    test "a map missing value is rejected (MalformedCollection)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_no_value",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedCollection, flow_io.parseFlow(allocator, src));
    }

    test "a list missing element is rejected (MalformedCollection)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_no_element",
            \\  "collections": [ { "name": "xs" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedCollection, flow_io.parseFlow(allocator, src));
    }

    test "round-trips a map collection + map nodes through renderFlowJsonc" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "map_roundtrip",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "MapForEach", "collection": "scores", "pos": [0, 0] },
            \\    { "id": 2, "type": "MapClear", "collection": "scores", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        // The map `collections` entry carries kind/key/value; the node
        // carries `collection`.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"name\": \"scores\", \"kind\": \"map\", \"key\": \"u32\", \"value\": \"i32\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"type\": \"MapForEach\", \"collection\": \"scores\"") != null);

        // Re-parse → re-render is byte-stable.
        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();
        const rendered2 = try flow_io.renderFlowJsonc(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "a list collection round-trip stays byte-identical (kind defaults to list)" {
        // Back-compat: a pre-MAPS list file omits `kind`; the writer must
        // NOT start emitting a `kind` key for lists.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "list_backcompat",
            \\  "collections": [ { "name": "xs", "element": "u32" } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var l1 = try flow_io.parseFlow(allocator, src);
        defer l1.deinit();
        const rendered = try flow_io.renderFlowJsonc(allocator, l1);
        defer allocator.free(rendered);

        // List entry emits exactly `name` + `element`, no `kind`.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"name\": \"xs\", \"element\": \"u32\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"kind\"") == null);
    }
};
