//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;

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
