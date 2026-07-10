//! Time exec-gate nodes (flow-codegen#47): `Once` and `Cooldown`.
//!
//! Both are EXEC-GATES — the single-output analogue of `Branch`. They sit
//! on an exec edge, run synchronously, and conditionally pass control to
//! their single `body` exec output (no `else`). Each carries per-node
//! PERSISTENT state, emitted at module scope as a `pub var` keyed by
//! (flow, node id) — namespaced by the flow's function name `<flowfn>`
//! (`onCall`/`setup` for an entry, `sanitizeSymbol(name)` for a subgraph)
//! so the same node id in two flows gets distinct slots (flow-codegen#47;
//! the `__` prefix is RESERVED for generated state):
//!   - `Once`     → `pub var __once_<flowfn>_n<id>: bool = false;` (fires the
//!     first time only, ever) and lowers to `if (!__once_<flowfn>_n<id>) {
//!     __once_<flowfn>_n<id> = true; <body> }`.
//!   - `Cooldown` → `pub var __cd_<flowfn>_n<id>: f64 = -1e18;` (a last-fired
//!     timestamp) and lowers to `if (game.elapsedSeconds() -
//!     __cd_<flowfn>_n<id> >= <seconds>) { __cd_<flowfn>_n<id> =
//!     game.elapsedSeconds(); <body> }`.
//!
//! Coverage per node:
//!   - parse → codegen emits the expected `pub var` declaration AND the
//!     guarded `if` lowering (assert substrings),
//!   - round-trip (parse → write → parse) is stable,
//!   - the generated Zig passes AstGen (`expectAstGenOk`) — the real
//!     compile check. AstGen does NOT run Sema, so the undeclared host
//!     accessor `game.elapsedSeconds()` is tolerated (this is exactly why
//!     `Cooldown` compile-checks without the labelle-engine change).
//! Plus a gate wrapping a 2-node body, asserting both body statements lower
//! INSIDE the guard.

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;
const expectAstGenOk = helpers.expectAstGenOk;

pub const TimeGateTests = struct {
    // -----------------------------------------------------------------
    // Once
    // -----------------------------------------------------------------

    test "Once emits a per-node bool pub var and a first-time-only guard" {
        const allocator = std.testing.allocator;
        // The Once node (id 1) gates a single body command (a SetVariable,
        // id 3) reached through its `body` exec output.
        const src =
            \\{
            \\  "name": "once_demo",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Once", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 9, "pos": [0, 0] },
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

        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .Once);

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "once_demo" });
        defer allocator.free(out);

        // Module-level per-node state.
        const decl_at = std.mem.indexOf(u8, out, "pub var __once_onCall_n1: bool = false;");
        try expect.toBeTrue(decl_at != null);

        // Guarded `if` lowering: test-then-set, no `else`.
        const if_at = std.mem.indexOf(u8, out, "if (!__once_onCall_n1) {");
        const set_at = std.mem.indexOf(u8, out, "__once_onCall_n1 = true;");
        const body_at = std.mem.indexOf(u8, out, "out = n2_value;");
        try expect.toBeTrue(if_at != null);
        try expect.toBeTrue(set_at != null);
        try expect.toBeTrue(body_at != null);

        // The `pub var` precedes the handler body; inside the guard the flag
        // is set first, then the body runs.
        try expect.toBeTrue(decl_at.? < if_at.?);
        try expect.toBeTrue(if_at.? < set_at.?);
        try expect.toBeTrue(set_at.? < body_at.?);

        try expectAstGenOk(allocator, out);
    }

    test "Once round-trips through write (parse -> write -> parse)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "once_rt",
            \\  "nodes": [
            \\    { "id": 1, "type": "Once", "pos": [10, 20] }
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
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .Once);
        try expect.equal(roundtrip.flow.nodes[0].id, @as(u32, 1));
    }

    // -----------------------------------------------------------------
    // Cooldown
    // -----------------------------------------------------------------

    test "Cooldown emits a per-node f64 pub var and a clock-gated guard" {
        const allocator = std.testing.allocator;
        // The Cooldown node (id 1) re-blocks for 2.5s; its body sets `out`.
        const src =
            \\{
            \\  "name": "cd_demo",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Cooldown", "seconds": 2.5, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 9, "pos": [0, 0] },
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

        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .Cooldown);
        try expect.equal(loaded.flow.nodes[0].kind.Cooldown.seconds, @as(f64, 2.5));

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "cd_demo" });
        defer allocator.free(out);

        // Module-level per-node state — sentinel so the gate opens first time.
        const decl_at = std.mem.indexOf(u8, out, "pub var __cd_onCall_n1: f64 = -1e18;");
        try expect.toBeTrue(decl_at != null);

        // Clock-gated `if` lowering: compare against the host game clock,
        // then stamp it before running the body.
        const if_at = std.mem.indexOf(u8, out, "if (game.elapsedSeconds() - __cd_onCall_n1 >= 2.5) {");
        const stamp_at = std.mem.indexOf(u8, out, "__cd_onCall_n1 = game.elapsedSeconds();");
        const body_at = std.mem.indexOf(u8, out, "out = n2_value;");
        try expect.toBeTrue(if_at != null);
        try expect.toBeTrue(stamp_at != null);
        try expect.toBeTrue(body_at != null);

        try expect.toBeTrue(decl_at.? < if_at.?);
        try expect.toBeTrue(if_at.? < stamp_at.?);
        try expect.toBeTrue(stamp_at.? < body_at.?);

        // AstGen tolerates the undeclared `game.elapsedSeconds()` accessor
        // (it does not run Sema), so the gate compile-checks without the
        // labelle-engine host change.
        try expectAstGenOk(allocator, out);
    }

    test "Cooldown with unwired seconds defaults to 0" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "cd_default",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Cooldown", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 9, "pos": [0, 0] },
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
        try expect.equal(loaded.flow.nodes[0].kind.Cooldown.seconds, @as(f64, 0));

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "cd_default" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "if (game.elapsedSeconds() - __cd_onCall_n1 >= 0) {") != null);
        try expectAstGenOk(allocator, out);
    }

    test "Cooldown round-trips through write (parse -> write -> parse) preserving seconds" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "cd_rt",
            \\  "nodes": [
            \\    { "id": 1, "type": "Cooldown", "seconds": 1.5, "pos": [10, 20] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(rendered);
        // The inline `seconds` field survives the write.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"seconds\": 1.5") != null);

        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .Cooldown);
        try expect.equal(roundtrip.flow.nodes[0].kind.Cooldown.seconds, @as(f64, 1.5));
    }

    // -----------------------------------------------------------------
    // Multi-node body — the gate wraps 2+ statements INSIDE the guard.
    // -----------------------------------------------------------------

    test "Once wrapping a 2-node body lowers both statements inside the guard" {
        const allocator = std.testing.allocator;
        // Two body commands wired off the Once's single `body` exec output
        // by fanning it out to both targets (SetVariable id 3 and id 5) —
        // the same one-pin-to-many-targets convention a Branch side uses.
        const src =
            \\{
            \\  "name": "once_multi",
            \\  "variables": [
            \\    { "name": "a", "type": "i32", "default": 0 },
            \\    { "name": "b", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Once", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 3, "type": "SetVariable", "name": "a", "pos": [0, 0] },
            \\    { "id": 4, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 5, "type": "SetVariable", "name": "b", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } },
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 5, "pin": "value" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } },
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 5 } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "once_multi" });
        defer allocator.free(out);

        const if_at = std.mem.indexOf(u8, out, "if (!__once_onCall_n1) {");
        const a_at = std.mem.indexOf(u8, out, "a = n2_value;");
        const b_at = std.mem.indexOf(u8, out, "b = n4_value;");
        try expect.toBeTrue(if_at != null);
        try expect.toBeTrue(a_at != null);
        try expect.toBeTrue(b_at != null);
        // Both body statements lower AFTER the guard opens — inside the `if`.
        try expect.toBeTrue(a_at.? > if_at.?);
        try expect.toBeTrue(b_at.? > if_at.?);

        try expectAstGenOk(allocator, out);
    }

    // -----------------------------------------------------------------
    // Cross-flow gate-state namespacing (flow-codegen#47).
    //
    // Node ids are unique only WITHIN a flow — every flow's ids start at
    // 1 — so an entry flow's `Once` at id 1 and a referenced subflow's
    // `Once` at id 1 must NOT share one module-level state slot. The gate
    // var is namespaced by the flow's function name (`onCall` for the
    // entry, `sanitizeSymbol(name)` for the subflow), so the two gates
    // resolve to DISTINCT `pub var`s. Without the namespacing both would
    // collide on `__once_n1` / `__cd_n1`: only one `pub var` would survive
    // and one gate firing would permanently block the other.
    // -----------------------------------------------------------------

    // A subflow that ALSO carries a gate at node id 1 — the id collides
    // with the entry flow's gate id. The gate body sets a module-level
    // variable (a subgraph has no `entity` in scope, RFC §3), so the
    // generated subgraph fn passes AstGen cleanly.
    const once_subflow =
        \\{
        \\  "name": "inner_once_sub",
        \\  "locals": [ { "name": "inner_out", "type": "i32", "default": 0 } ],
        \\  "nodes": [
        \\    { "id": 1, "type": "Once", "pos": [0, 0] },
        \\    { "id": 2, "type": "Literal", "value": 7, "pos": [0, 0] },
        \\    { "id": 3, "type": "SetVariable", "name": "inner_out", "pos": [0, 0] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
        \\  ],
        \\  "exec_edges": [
        \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } }
        \\  ]
        \\}
    ;

    test "Once at id 1 in entry and subflow get DISTINCT namespaced pub vars" {
        const allocator = std.testing.allocator;
        // Entry (OnCall): a Once at id 1 gates a Subflow call at id 2. The
        // referenced subflow ALSO has a Once at id 1 — the collision case.
        const entry_src =
            \\{
            \\  "name": "gated_caller",
            \\  "nodes": [
            \\    { "id": 1, "type": "Once", "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "inner_once_sub", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, once_subflow);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "gated_caller" });
        defer allocator.free(out);

        // TWO DISTINCT `pub var` declarations — one per flow — NOT one
        // shared `__once_n1`. The entry's gate is namespaced by `onCall`,
        // the subflow's by its sanitized function name `inner_once_sub`.
        const entry_decl = std.mem.indexOf(u8, out, "pub var __once_onCall_n1: bool = false;");
        const sub_decl = std.mem.indexOf(u8, out, "pub var __once_inner_once_sub_n1: bool = false;");
        try expect.toBeTrue(entry_decl != null);
        try expect.toBeTrue(sub_decl != null);

        // The un-namespaced name must NOT appear anywhere — the bug it
        // would mask is two gates sharing `__once_n1`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__once_n1") == null);

        // The entry function's guard references the entry var; the
        // subflow function's guard references the subflow var — DIFFERENT
        // variables, so neither gate can block the other.
        const entry_guard = std.mem.indexOf(u8, out, "if (!__once_onCall_n1) {");
        const sub_guard = std.mem.indexOf(u8, out, "if (!__once_inner_once_sub_n1) {");
        try expect.toBeTrue(entry_guard != null);
        try expect.toBeTrue(sub_guard != null);
        // Each guard names a different var than the other's.
        try expect.toBeTrue(entry_guard.? != sub_guard.?);

        try expectAstGenOk(allocator, out);
    }

    // A subflow carrying a Cooldown at node id 1 — same id-collision shape
    // as `once_subflow`, exercising the `__cd_` namespacing.
    const cd_subflow =
        \\{
        \\  "name": "inner_cd_sub",
        \\  "locals": [ { "name": "inner_out", "type": "i32", "default": 0 } ],
        \\  "nodes": [
        \\    { "id": 1, "type": "Cooldown", "seconds": 1.0, "pos": [0, 0] },
        \\    { "id": 2, "type": "Literal", "value": 7, "pos": [0, 0] },
        \\    { "id": 3, "type": "SetVariable", "name": "inner_out", "pos": [0, 0] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
        \\  ],
        \\  "exec_edges": [
        \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 3 } }
        \\  ]
        \\}
    ;

    test "Cooldown at id 1 in entry and subflow get DISTINCT namespaced pub vars" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "cd_caller",
            \\  "nodes": [
            \\    { "id": 1, "type": "Cooldown", "seconds": 2.0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "inner_cd_sub", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, cd_subflow);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "cd_caller" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var __cd_onCall_n1: f64 = -1e18;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub var __cd_inner_cd_sub_n1: f64 = -1e18;") != null);
        // The un-namespaced name must not survive.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__cd_n1") == null);

        const entry_guard = std.mem.indexOf(u8, out, "if (game.elapsedSeconds() - __cd_onCall_n1 >= 2) {");
        const sub_guard = std.mem.indexOf(u8, out, "if (game.elapsedSeconds() - __cd_inner_cd_sub_n1 >= 1) {");
        try expect.toBeTrue(entry_guard != null);
        try expect.toBeTrue(sub_guard != null);

        try expectAstGenOk(allocator, out);
    }
};
