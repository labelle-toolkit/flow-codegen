//! Deferred-subflow exec node (flow-codegen#48, Stage 2 of #25): `Delay`.
//!
//! `Delay` sits on an exec edge and routes control through a single `body`
//! exec output, but UNLIKE the `Once`/`Cooldown` gates it does NOT run that
//! body synchronously. Its `body` MUST connect to exactly ONE `Subflow`
//! node. At the Delay site codegen:
//!   - SNAPSHOTS the deferred subflow's input args into a heap capture
//!     struct (`game.allocator.create`'d; the scheduler owns + frees it),
//!   - registers a (scaled, pause-aware) timer via
//!     `game.scheduler.after(<seconds>, <entity-or-null>, __cap, &tramp)`.
//! The subflow runs later off a generated trampoline that casts the
//! type-erased game/ctx pointers back and forwards the snapshotted args.
//!
//! Module-level state is emitted by `entry.zig`, namespaced by the flow's
//! function name `<flowfn>` (node ids are unique only WITHIN a flow):
//!   - `const __DelayCap_<flowfn>_n<id> = struct { <arg>: <type>, … };`
//!   - `fn __delay_tramp_<flowfn>_n<id>(game_ctx: *anyopaque, ctx:
//!     *anyopaque) void { … }`.
//!
//! Coverage:
//!   - parse → codegen emits the capture struct, the trampoline, and the
//!     `scheduler.after` call site (assert substrings),
//!   - capture fields match the deferred subflow's declared inputs; the
//!     snapshot assigns the wired exprs,
//!   - per-flow namespacing: a Delay in the entry AND one in a subflow get
//!     DISTINCT struct/trampoline names (regression for the gates' aliasing
//!     class),
//!   - validation: a `Delay` whose `body` targets a non-`Subflow` (or
//!     nothing) is REJECTED,
//!   - round-trip (parse → write → parse) preserves `seconds`,
//!   - the generated Zig passes AstGen (`expectAstGenOk`).
//!
//! AstGen CAVEAT: `expectAstGenOk` runs AstGen only (no Sema), so it CANNOT
//! verify `game.scheduler.after`'s real signature, the `*Game` cast in the
//! trampoline, or that the subflow function is called with the right arg
//! types. Those resolve only when a real game compiles. The substring
//! assertions below pin the STRUCTURE; an end-to-end game build validates
//! the integration.

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;
const expectAstGenOk = helpers.expectAstGenOk;

pub const DelayTests = struct {
    // A deferred subflow that takes two scalar params and writes them into
    // a local (so the generated subgraph `fn` passes AstGen cleanly with no
    // host `entity` in scope). Its declared inputs `amount`/`flag` become
    // the Delay capture struct's fields.
    const callee_sub =
        \\{
        \\  "name": "deferred_body",
        \\  "event": { "type": "OnCall" },
        \\  "params": [
        \\    { "name": "amount", "type": "i32", "default": 0 },
        \\    { "name": "flag", "type": "bool", "default": false }
        \\  ],
        \\  "locals": [
        \\    { "name": "sink", "type": "i32", "default": 0 },
        \\    { "name": "toggled", "type": "bool", "default": false }
        \\  ],
        \\  "nodes": [
        \\    { "id": 1, "type": "Param", "param": "amount", "pos": [0, 0] },
        \\    { "id": 2, "type": "SetVariable", "name": "sink", "pos": [0, 0] },
        \\    { "id": 3, "type": "Param", "param": "flag", "pos": [0, 0] },
        \\    { "id": 4, "type": "SetVariable", "name": "toggled", "pos": [0, 0] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
        \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
        \\  ]
        \\}
    ;

    test "Delay emits a capture struct, a trampoline, and a scheduler.after call" {
        const allocator = std.testing.allocator;
        // Entry (OnCall): a Delay (id 1) defers a Subflow (id 2) by 2.5s.
        // The subflow's `amount` pin is wired to a Literal (9); its `flag`
        // pin is left to the declared default (false).
        const entry_src =
            \\{
            \\  "name": "delay_demo",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 2.5, "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "deferred_body", "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 9, "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 2, "pin": "amount" } }
            \\  ],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, callee_sub);
        defer sub.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), entry.flow.nodes[0].kind), .Delay);
        try expect.equal(entry.flow.nodes[0].kind.Delay.seconds, @as(f64, 2.5));

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "delay_demo" });
        defer allocator.free(out);

        // Module-level capture struct — one field per deferred subflow param.
        const cap_at = std.mem.indexOf(u8, out, "const __DelayCap_onCall_n1 = struct { amount: i32, flag: bool };");
        try expect.toBeTrue(cap_at != null);

        // Module-level trampoline: casts both type-erased pointers, then
        // forwards the snapshotted args to the subflow.
        const tramp_at = std.mem.indexOf(u8, out, "fn __delay_tramp_onCall_n1(game_ctx: *anyopaque, ctx: *anyopaque) void {");
        try expect.toBeTrue(tramp_at != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const game: *Game = @ptrCast(@alignCast(game_ctx));") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const cap: *__DelayCap_onCall_n1 = @ptrCast(@alignCast(ctx));") != null);
        // A value-less subgraph is a bare call; this one is void → bare call.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "deferred_body(game, cap.amount, cap.flag);") != null);

        // Delay site: create + snapshot + register.
        const create_at = std.mem.indexOf(u8, out, "const __cap_n1 = game.allocator.create(__DelayCap_onCall_n1) catch return;");
        try expect.toBeTrue(create_at != null);
        // The snapshot assigns the wired Literal (9) for `amount` and the
        // declared default (false) for the unwired `flag`.
        const snap_at = std.mem.indexOf(u8, out, "__cap_n1.* = .{ .amount = 9, .flag = false };");
        try expect.toBeTrue(snap_at != null);
        // Register the timer — typed capture passed straight through, entity
        // null, trampoline by reference, seconds as an f64 literal.
        const after_at = std.mem.indexOf(u8, out, "game.scheduler.after(2.5, null, __cap_n1, &__delay_tramp_onCall_n1);");
        try expect.toBeTrue(after_at != null);

        // The module-level decls precede the call site.
        try expect.toBeTrue(cap_at.? < create_at.?);
        try expect.toBeTrue(tramp_at.? < create_at.?);
        // The snapshot happens after the create, before the register.
        try expect.toBeTrue(create_at.? < snap_at.?);
        try expect.toBeTrue(snap_at.? < after_at.?);

        try expectAstGenOk(allocator, out);
    }

    test "Delay with unwired seconds defaults to 0" {
        const allocator = std.testing.allocator;
        const entry_src =
            \\{
            \\  "name": "delay_default",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "deferred_body", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, callee_sub);
        defer sub.deinit();
        try expect.equal(entry.flow.nodes[0].kind.Delay.seconds, @as(f64, 0));

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "delay_default" });
        defer allocator.free(out);

        // Both params unwired → both take their declared defaults.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__cap_n1.* = .{ .amount = 0, .flag = false };") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.scheduler.after(0, null, __cap_n1, &__delay_tramp_onCall_n1);") != null);
        try expectAstGenOk(allocator, out);
    }

    test "Delay deferring a zero-param subflow emits an empty capture + bare call" {
        const allocator = std.testing.allocator;
        // A subflow with NO params yields an empty capture struct; the
        // trampoline discards the unused `cap` and calls the subflow with
        // just `game`.
        const noparam_sub =
            \\{
            \\  "name": "noparam_body",
            \\  "event": { "type": "OnCall" },
            \\  "locals": [ { "name": "sink", "type": "i32", "default": 0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "sink", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "delay_noparam",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 1.0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "noparam_body", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var sub = try flow_io.parseFlow(allocator, noparam_sub);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "delay_noparam" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const __DelayCap_onCall_n1 = struct {};") != null);
        // Empty struct → empty snapshot literal.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__cap_n1.* = .{};") != null);
        // Trampoline discards the unused capture and calls with just `game`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_ = cap;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "noparam_body(game);") != null);
        try expectAstGenOk(allocator, out);
    }

    // -----------------------------------------------------------------
    // Per-flow namespacing — a Delay in the entry AND one in a subflow at
    // the SAME node id must get DISTINCT capture/trampoline names. Node ids
    // are unique only WITHIN a flow; without the `<flowfn>` prefix both
    // would collide on `__DelayCap_n1` / `__delay_tramp_n1` (the same
    // aliasing class the `Once`/`Cooldown` gates had).
    // -----------------------------------------------------------------

    test "Delay at id 1 in entry and subflow get DISTINCT namespaced decls" {
        const allocator = std.testing.allocator;
        // The deferred body `deferred_body` is reached from BOTH the entry's
        // Delay and an intermediate subflow's Delay — same node id (1) in
        // each, the collision case.
        const mid_sub =
            \\{
            \\  "name": "mid_caller",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 3.0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "deferred_body", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        const entry_src =
            \\{
            \\  "name": "delay_caller",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 2.0, "pos": [0, 0] },
            \\    { "id": 2, "type": "Subflow", "flow": "mid_caller", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
            \\}
        ;
        var entry = try flow_io.parseFlow(allocator, entry_src);
        defer entry.deinit();
        var mid = try flow_io.parseFlow(allocator, mid_sub);
        defer mid.deinit();
        var sub = try flow_io.parseFlow(allocator, callee_sub);
        defer sub.deinit();

        var reg = flow_codegen.FlowRegistry.init(allocator);
        defer reg.deinit();
        try reg.add(entry.flow);
        try reg.add(mid.flow);
        try reg.add(sub.flow);

        const out = try flow_codegen.renderFlowFile(allocator, entry.flow, &reg, .{ .flow_name = "delay_caller" });
        defer allocator.free(out);

        // TWO DISTINCT capture structs + trampolines — one per flow.
        const entry_cap = std.mem.indexOf(u8, out, "const __DelayCap_onCall_n1 = struct {");
        const mid_cap = std.mem.indexOf(u8, out, "const __DelayCap_mid_caller_n1 = struct {");
        try expect.toBeTrue(entry_cap != null);
        try expect.toBeTrue(mid_cap != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn __delay_tramp_onCall_n1(") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "fn __delay_tramp_mid_caller_n1(") != null);

        // The un-namespaced names must NOT appear anywhere — the bug they
        // would mask is two Delays sharing `__DelayCap_n1` / `__delay_tramp_n1`.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__DelayCap_n1") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "__delay_tramp_n1") == null);

        // Each call site references its own flow's trampoline.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "&__delay_tramp_onCall_n1);") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "&__delay_tramp_mid_caller_n1);") != null);

        try expectAstGenOk(allocator, out);
    }

    // -----------------------------------------------------------------
    // Validation — a Delay's `body` must target exactly one Subflow.
    // -----------------------------------------------------------------

    test "rejects a Delay whose body targets a non-Subflow node" {
        const allocator = std.testing.allocator;
        // The Delay's `body` exec output targets a SetVariable, not a
        // Subflow — a Delay defers a subflow call, nothing else.
        const src =
            \\{
            \\  "name": "bad_delay_target",
            \\  "variables": [ { "name": "out", "type": "i32", "default": 0 } ],
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 1.0, "pos": [0, 0] },
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
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    test "rejects a Delay whose body targets nothing" {
        const allocator = std.testing.allocator;
        // A Delay with no `body` exec edge has nothing to defer — malformed.
        const src =
            \\{
            \\  "name": "dangling_delay",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 1.0, "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        try std.testing.expectError(error.MalformedFlow, flow_io.parseFlow(allocator, src));
    }

    // -----------------------------------------------------------------
    // Round-trip — the inline `seconds` survives write.
    // -----------------------------------------------------------------

    test "Delay round-trips through write preserving seconds" {
        const allocator = std.testing.allocator;
        // The body edge is required for a VALID flow, but the round-trip
        // assertion only needs the node + its `seconds` to survive; wire it
        // to a Subflow so parse() (which validates) accepts the source.
        const src =
            \\{
            \\  "name": "delay_rt",
            \\  "event": { "type": "OnCall" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Delay", "seconds": 1.5, "pos": [10, 20] },
            \\    { "id": 2, "type": "Subflow", "flow": "deferred_body", "pos": [0, 0] }
            \\  ],
            \\  "edges": [],
            \\  "exec_edges": [
            \\    { "from": { "node": 1, "pin": "body" }, "to": { "node": 2 } }
            \\  ]
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
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .Delay);
        try expect.equal(roundtrip.flow.nodes[0].kind.Delay.seconds, @as(f64, 1.5));
    }
};
