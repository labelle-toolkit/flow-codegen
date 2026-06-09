//! Input REPORTER nodes (labelle-gui#208 Option A) — the held-state
//! complement to the engine input EVENTS already shipped. Each is a pure
//! REPORTER (output pin `value`, no exec pins) that lowers to a GAME INPUT
//! MIXIN method (labelle-engine `src/game/input_mixin.zig`):
//!
//!   IsKeyDown { key }     → game.isKeyDown(.<key>)        (bool)
//!   IsKeyPressed { key }  → game.isKeyPressed(.<key>)     (bool)
//!   GetMouseX             → game.getMouseX()              (f32)
//!   GetMouseY             → game.getMouseY()              (f32)
//!   GetMouseWheel         → game.getMouseWheelMove()      (f32)
//!
//! Unlike the string reporters (flow-codegen#26) these allocate NOTHING,
//! so they are pure-inlinable leaves (`inline.zig`): a `While` cond / `Delay`
//! snapshot re-reads live input each pass instead of freezing a binding.
//!
//! Coverage per node: parse → codegen emits the expected mixin call;
//! round-trip (parse → write → parse) is stable; the generated Zig passes
//! AstGen (`expectAstGenOk`). Plus: validation rejects an empty / non-ident
//! `key`; a reporter feeding a `Branch`/`Compare` reads correctly; and a
//! `While` cond re-inlines an input reporter verbatim.
//!
//! NOTE on validation reach: `expectAstGenOk` runs Parse + AstGen, NOT
//! Sema. The `key` is spliced as a Zig ENUM LITERAL (`.<key>`), so AstGen
//! is happy with ANY identifier — it CANNOT verify the tag names a real
//! `KeyboardKey` member. That check resolves in Sema at game compile.

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;
const expectAstGenOk = helpers.expectAstGenOk;

pub const InputReporterTests = struct {
    // -----------------------------------------------------------------
    // IsKeyDown
    // -----------------------------------------------------------------

    test "IsKeyDown lowers to game.isKeyDown(.<key>) with an enum-literal key" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "ikd_demo",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyDown", "key": "space", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "out", "value_type": "bool", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .IsKeyDown);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.IsKeyDown.key, "space"));

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "ikd_demo" });
        defer allocator.free(out);

        // Enum-literal key — `.space`, NOT a quoted string or imported enum.
        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n1_value = game.isKeyDown(.space);",
        ) != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return n1_value;") != null);

        try expectAstGenOk(allocator, out);
    }

    test "IsKeyDown round-trips through write (parse -> write -> parse)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "ikd_rt",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyDown", "key": "w", "pos": [10, 20] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);

        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .IsKeyDown);
        try expect.toBeTrue(std.mem.eql(u8, roundtrip.flow.nodes[0].kind.IsKeyDown.key, "w"));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "IsKeyDown with an empty key is rejected at parse/validate" {
        const allocator = std.testing.allocator;
        // No `key` defaults to "" — not a plausible identifier, so the
        // generated `.<key>` would be unparseable. Rejected by `validate`.
        const src =
            \\{
            \\  "name": "ikd_empty",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyDown", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "IsKeyDown with a non-identifier key is rejected" {
        const allocator = std.testing.allocator;
        // `1space` starts with a digit — not a Zig identifier.
        const src =
            \\{
            \\  "name": "ikd_bad",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyDown", "key": "1space", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    // -----------------------------------------------------------------
    // IsKeyPressed
    // -----------------------------------------------------------------

    test "IsKeyPressed lowers to game.isKeyPressed(.<key>)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "ikp_demo",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyPressed", "key": "enter", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "out", "value_type": "bool", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .IsKeyPressed);

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "ikp_demo" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n1_value = game.isKeyPressed(.enter);",
        ) != null);

        try expectAstGenOk(allocator, out);
    }

    test "IsKeyPressed round-trips through write" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "ikp_rt",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyPressed", "key": "left", "pos": [1, 2] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);
        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.toBeTrue(std.mem.eql(u8, roundtrip.flow.nodes[0].kind.IsKeyPressed.key, "left"));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    // -----------------------------------------------------------------
    // GetMouseX / GetMouseY / GetMouseWheel (payload-free)
    // -----------------------------------------------------------------

    test "GetMouseX lowers to game.getMouseX()" {
        const allocator = std.testing.allocator;
        const out = try renderSingleReporter(allocator, "GetMouseX", "f32");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = game.getMouseX();") != null);
        try expectAstGenOk(allocator, out);
    }

    test "GetMouseY lowers to game.getMouseY()" {
        const allocator = std.testing.allocator;
        const out = try renderSingleReporter(allocator, "GetMouseY", "f32");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = game.getMouseY();") != null);
        try expectAstGenOk(allocator, out);
    }

    test "GetMouseWheel lowers to game.getMouseWheelMove()" {
        const allocator = std.testing.allocator;
        const out = try renderSingleReporter(allocator, "GetMouseWheel", "f32");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = game.getMouseWheelMove();") != null);
        try expectAstGenOk(allocator, out);
    }

    test "GetMouseX round-trips through write (payload-free)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "gmx_rt",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetMouseX", "pos": [7, 8] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);
        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .GetMouseX);

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    // -----------------------------------------------------------------
    // Integration: reporter feeding a Branch / Compare / While
    // -----------------------------------------------------------------

    test "IsKeyDown feeding a Branch cond reads through its binding" {
        const allocator = std.testing.allocator;
        // The Branch reads the reporter via the `n<id>_value` binding
        // reference (the held-state poll done once at the branch) — the
        // canonical `Branch(cond = IsKeyDown("w")) -> move` shape.
        const src =
            \\{
            \\  "name": "ikd_branch",
            \\  "variables": [
            \\    { "name": "moved", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyDown", "key": "w", "pos": [0, 0] },
            \\    { "id": 2, "type": "Branch", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 4, "type": "SetVariable", "name": "moved", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "cond" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "then" }, "to": { "node": 4 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "ikd_branch" });
        defer allocator.free(out);

        // The reporter binds once, then the Branch consumes that binding.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = game.isKeyDown(.w);") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "if (n1_value) {") != null);

        try expectAstGenOk(allocator, out);
    }

    test "GetMouseX feeding a Compare reads through its binding" {
        const allocator = std.testing.allocator;
        // GetMouseX > 100 → bool. Proves the f32 reporter is usable as a
        // Compare operand (the mouse-region-gate shape).
        const src =
            \\{
            \\  "name": "gmx_cmp",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetMouseX", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "100.0", "pos": [0, 0] },
            \\    { "id": 3, "type": "Compare", "op": "gt", "pos": [0, 0] },
            \\    { "id": 4, "type": "Output", "name": "out", "value_type": "bool", "pos": [0, 0] }
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

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "gmx_cmp" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = game.getMouseX();") != null);
        // The Compare reads the mouse-X binding as its left operand.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "n1_value > ") != null);

        try expectAstGenOk(allocator, out);
    }

    test "IsKeyDown feeding a While cond is re-inlined verbatim (not frozen)" {
        const allocator = std.testing.allocator;
        // A `While` deep-inlines its cond so it recomputes each iteration.
        // Because input reporters are pure (allocate nothing), the mixin
        // call is spliced straight into the `while (...)` header — NOT a
        // frozen `n<id>_value` binding reference.
        const src =
            \\{
            \\  "name": "ikd_while",
            \\  "variables": [
            \\    { "name": "ticks", "type": "i32", "default": 0 }
            \\  ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "IsKeyDown", "key": "space", "pos": [0, 0] },
            \\    { "id": 2, "type": "While", "pos": [0, 0] },
            \\    { "id": 3, "type": "ChangeVariable", "name": "ticks", "by": "1", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "cond" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 2, "pin": "body" }, "to": { "node": 3 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "ikd_while" });
        defer allocator.free(out);

        // The mixin call is inlined into the while header, recomputed each
        // pass — no frozen `n1_value` binding for the reporter.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "while (game.isKeyDown(.space))") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = game.isKeyDown") == null);

        try expectAstGenOk(allocator, out);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// Render a single payload-free reporter wired into an `Output`, so the
    /// reporter is consumed (no unused-binding lint) and the generated Zig
    /// is a complete, AstGen-checkable fragment.
    fn renderSingleReporter(
        allocator: std.mem.Allocator,
        type_name: []const u8,
        value_type: []const u8,
    ) ![]const u8 {
        const src = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "single",
            \\  "event": {{ "type": "OnCall" }},
            \\  "nodes": [
            \\    {{ "id": 1, "type": "{s}", "pos": [0, 0] }},
            \\    {{ "id": 2, "type": "Output", "name": "out", "value_type": "{s}", "pos": [0, 0] }}
            \\  ],
            \\  "edges": [
            \\    {{ "from": {{ "node": 1, "pin": "value" }}, "to": {{ "node": 2, "pin": "value" }} }}
            \\  ]
            \\}}
        , .{ type_name, value_type });
        defer allocator.free(src);

        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        return try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "single" });
    }
};
