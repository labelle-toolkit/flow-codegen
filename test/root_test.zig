//! Tests for the `flow_codegen` sub-package — the `.flow.zon` parser
//! and the graph-to-Zig codegen pass.
//!
//! BDD-style tests using `zspec`, mirroring the convention used in
//! `labelle-gfx`'s `spatial_grid` sub-package. Tests originally lived
//! in `labelle-gui/src/tests.zig` (as `FlowIoTests` / `FlowCodegenTests`)
//! and moved here verbatim when the sub-package was promoted in
//! `labelle-gui#94`.

const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const flow_codegen_pkg = @import("flow_codegen");

const flow_io = flow_codegen_pkg.flow_io;
const flow_codegen = flow_codegen_pkg.codegen;
const flow_convert = flow_codegen_pkg.convert;

test {
    zspec.runAll(@This());
}

pub const FlowIoTests = struct {
    // The sketch from issue #46 — the canonical example a flow file
    // looks like in v1. Used by the round-trip test below.
    const sample_issue_46 =
        \\.{
        \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
        \\    .nodes = .{
        \\        .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
        \\        .{ .id = 2, .pos = .{280, 80}, .kind = .{ .BinOp = .{ .op = .add } } },
        \\        .{ .id = 3, .pos = .{440, 80}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
        \\    },
        \\    .links = .{
        \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
        \\    },
        \\}
        \\
    ;

    const minimal_on_update =
        \\.{
        \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
        \\    .nodes = .{},
        \\    .links = .{},
        \\}
        \\
    ;

    test "parses minimal flow with OnUpdate event" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator, minimal_on_update);
        defer loaded.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.Event), loaded.flow.event), .OnUpdate);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.event.OnUpdate.arg_dt, "dt"));
        try expect.equal(loaded.flow.nodes.len, 0);
        try expect.equal(loaded.flow.links.len, 0);
    }

    test "parses each NodeKind variant" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\        .{ .id = 5, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 6, .pos = .{0, 0}, .kind = .{ .Call = .{ .callee = "std.math.sin" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        try expect.equal(loaded.flow.nodes.len, 6);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[0].kind), .GetComponent);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.GetComponent.type, "Position"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .SetField);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[1].kind.SetField.target, "Position.x"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[2].kind), .BinOp);
        try expect.equal(loaded.flow.nodes[2].kind.BinOp.op, .mul);
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[3].kind), .Literal);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[3].kind.Literal.value, "1.5"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[4].kind), .Identifier);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[4].kind.Identifier.name, "speed"));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[5].kind), .Call);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[5].kind.Call.callee, "std.math.sin"));
    }

    test "parses each Event variant" {
        const allocator = std.testing.allocator;

        const on_create =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "self" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        var l1 = try flow_io.parseFlow(allocator, on_create);
        defer l1.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l1.flow.event), .OnCreate);
        try expect.toBeTrue(std.mem.eql(u8, l1.flow.event.OnCreate.arg_entity, "self"));

        const on_destroy =
            \\.{
            \\    .event = .{ .OnDestroy = .{ .arg_entity = "victim" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        var l2 = try flow_io.parseFlow(allocator, on_destroy);
        defer l2.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnDestroy);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnDestroy.arg_entity, "victim"));
    }

    test "round-trips example from #46 structurally" {
        // The renderer's output is canonical (sorted, indented) so a
        // byte-equal compare to the hand-authored source would fight
        // the spec. Instead, parse -> render -> parse and confirm the
        // structural shape matches.
        const allocator = std.testing.allocator;

        var l1 = try flow_io.parseFlow(allocator, sample_issue_46);
        defer l1.deinit();

        const rendered = try flow_io.renderFlowZon(allocator, l1);
        defer allocator.free(rendered);

        var l2 = try flow_io.parseFlow(allocator, rendered);
        defer l2.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnUpdate);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.event.OnUpdate.arg_dt, "dt"));

        try expect.equal(l2.flow.nodes.len, 3);
        try expect.equal(l2.flow.nodes[0].id, 1);
        try expect.equal(l2.flow.nodes[0].pos[0], @as(f32, 120));
        try expect.equal(l2.flow.nodes[0].pos[1], @as(f32, 80));
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), l2.flow.nodes[0].kind), .GetComponent);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.nodes[0].kind.GetComponent.type, "Position"));

        try expect.equal(l2.flow.nodes[1].id, 2);
        try expect.equal(l2.flow.nodes[1].kind.BinOp.op, .add);

        try expect.equal(l2.flow.nodes[2].id, 3);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.nodes[2].kind.SetField.target, "Position.x"));

        try expect.equal(l2.flow.links.len, 1);
        try expect.equal(l2.flow.links[0].from.node, 1);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.links[0].from.pin, "x"));
        try expect.equal(l2.flow.links[0].to.node, 2);
        try expect.toBeTrue(std.mem.eql(u8, l2.flow.links[0].to.pin, "a"));

        // And the rendered output should re-render byte-identically
        // (idempotent canonicalization).
        const rendered2 = try flow_io.renderFlowZon(allocator, l2);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "rejects duplicate node IDs" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "b" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        try std.testing.expectError(error.DuplicateNodeId, flow_io.parseFlow(allocator, src));
    }

    test "rejects link to nonexistent node" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 99, .pin = "y" } },
            \\    },
            \\}
            \\
        ;
        try std.testing.expectError(error.DanglingLink, flow_io.parseFlow(allocator, src));
    }

    test "rejects node id == 0" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 0, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "a" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        try std.testing.expectError(error.InvalidNodeId, flow_io.parseFlow(allocator, src));
    }

    test "displayNameFromPath strips .flow.zon" {
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("scripts/flows/move.flow.zon"),
            "move",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("/abs/path/to/jump.flow.zon"),
            "jump",
        ));
        // Bare `.zon` (without the `.flow` infix) is NOT stripped --
        // that's a different file kind and the editor wouldn't open
        // it via this loader anyway.
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("scene.zon"),
            "scene.zon",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("noext"),
            "noext",
        ));
    }

    test "saveFlow + loadFromFile round trip via tmpDir" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "demo.flow.zon" });
        defer allocator.free(path);

        var l1 = try flow_io.parseFlow(allocator, sample_issue_46);
        defer l1.deinit();

        try flow_io.saveFlow(std.testing.io, allocator, path, l1);

        var l2 = try flow_io.loadFromFile(std.testing.io, allocator, path);
        defer l2.deinit();

        try expect.equal(l2.flow.nodes.len, l1.flow.nodes.len);
        try expect.equal(l2.flow.links.len, l1.flow.links.len);
        try expect.equal(@as(std.meta.Tag(flow_io.Event), l2.flow.event), .OnUpdate);
    }
};

pub const FlowCodegenTests = struct {
    // Small helper -- parse a ZON source and immediately run codegen,
    // returning the rendered Zig. Frees the parser arena before
    // returning; callers own the returned bytes.
    fn renderFromZon(allocator: std.mem.Allocator, src: []const u8, name: []const u8) ![]u8 {
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        return flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = name });
    }

    test "renders OnUpdate event signature with custom arg_dt name" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "delta" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "demo");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onUpdate(game: *Game, delta: f32) void") != null);
    }

    test "renders OnCreate event signature" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "self" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "spawn");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onCreate(game: *Game, self: EntityId) void") != null);
    }

    test "renders OnDestroy event signature" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnDestroy = .{ .arg_entity = "victim" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "cleanup");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "pub fn onDestroy(game: *Game, victim: EntityId) void") != null);
    }

    test "renders Literal node as a const binding" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "lit");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n1_value = 1.5;") != null);
    }

    test "renders Identifier node as a const binding" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 7, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "id");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n7_value = speed;") != null);
    }

    test "renders BinOp node with both inputs connected (distinct producers)" {
        // Regression: a single shared scratch buffer for input
        // resolution would alias `a_expr` and `b_expr` and emit the
        // same identifier twice. Two distinct Literal producers
        // force the renderer to keep both alive simultaneously.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "2" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .sub } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 3, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "b" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "sub");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = n1_value - n2_value;") != null);
    }

    test "renders BinOp node with disconnected pins defaulting to 0" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "binop");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n2_result = 0 * 0;") != null);
    }

    test "renders GetComponent node" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "get");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_value = game.getComponent(entity, Position) orelse return;") != null);
    }

    test "OnCreate with custom arg_entity aliases to entity in template scope" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "self" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "alias");
        defer allocator.free(out);
        // The alias binds the user-chosen parameter name to `entity` so
        // the GetComponent template (which always says `entity`) compiles.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity = self;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "getComponent(entity, Position)") != null);
    }

    test "OnCreate with default arg_entity does not emit redundant alias" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "noalias");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity =") == null);
    }

    test "renders SetField node sourced from a Literal" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "42" } } },
            \\        .{ .id = 5, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 4, .pin = "value" }, .to = .{ .node = 5, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "setf");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n4_value = 42;") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n4_value);") != null);
    }

    test "renders Call node with two args" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "2.0" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .Call = .{ .callee = "std.math.atan2" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 3, .pin = "arg0" } },
            \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "arg1" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "call");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const n3_result = std.math.atan2(n1_value, n2_value);") != null);
    }

    test "topo-sorts dependent nodes correctly" {
        // Literal (id=3) -> BinOp (id=2) -> SetField (id=1). The
        // numeric ids are intentionally in REVERSE topo order so
        // that a naive id-sort would emit the wrong sequence.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "5" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 3, .pin = "value" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 1, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "topo");
        defer allocator.free(out);

        const lit_idx = std.mem.indexOf(u8, out, "const n3_value = 5;") orelse return error.TestExpectedSubstring;
        const binop_idx = std.mem.indexOf(u8, out, "const n2_result = n3_value + 0;") orelse return error.TestExpectedSubstring;
        const set_idx = std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n2_result);") orelse return error.TestExpectedSubstring;
        try expect.toBeTrue(lit_idx < binop_idx);
        try expect.toBeTrue(binop_idx < set_idx);
    }

    test "rejects cycle" {
        const allocator = std.testing.allocator;
        // Two BinOps wired into each other -- node 1's result feeds
        // node 2's `a`, and node 2's result feeds node 1's `a`.
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "result" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 1, .pin = "a" } },
            \\    },
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.CycleDetected,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "cyc" }),
        );
    }

    test "rejects dangling required pin on SetField" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.DanglingPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "missing" }),
        );
    }

    test "rejects unknown pin name on link" {
        const allocator = std.testing.allocator;
        // BinOp has input pins `a` and `b` only -- `c` is unknown.
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "c" } },
            \\    },
            \\}
            \\
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try std.testing.expectError(
            error.UnknownPin,
            flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "bad" }),
        );
    }

    test "injects emitNodeEntered for each node with correct flow_name + id" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 10, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1" } } },
            \\        .{ .id = 20, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "x" } } },
            \\        .{ .id = 30, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "2" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "pulse");
        defer allocator.free(out);

        // The total number of emitNodeEntered calls should equal the
        // node count.
        const haystack = out;
        var count: usize = 0;
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, haystack, search_start, "emitNodeEntered(")) |idx| {
            count += 1;
            search_start = idx + 1;
        }
        try expect.equal(count, @as(usize, 3));

        // And each id appears exactly once, paired with the right
        // flow_name argument.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 10) catch {};") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 20) catch {};") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "_p.emitNodeEntered(\"pulse\", 30) catch {};") != null);
    }

    test "round-trips the issue #46 example" {
        const allocator = std.testing.allocator;
        // Identical to FlowIoTests.sample_issue_46. The codegen
        // pipeline interprets `GetComponent -> BinOp.a` via the
        // producer pin name `"x"` as a field access on the bound
        // component (`n1_value.x`).
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{280, 80}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 3, .pos = .{440, 80}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 3, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "move");
        defer allocator.free(out);

        // The expected statements, in order. We assert ordering by
        // checking that each appears AFTER the previous one in the
        // output. Position-sensitive -- catches any future regression
        // where a node ends up upstream of its dependencies.
        const expected_in_order = [_][]const u8{
            "const n1_value = game.getComponent(entity, Position) orelse return;",
            "const n2_result = n1_value.x + 0;",
            "game.setField(Position, .x, entity, n2_result);",
        };
        var prev: usize = 0;
        for (expected_in_order) |needle| {
            const at = std.mem.indexOfPos(u8, out, prev, needle) orelse {
                std.debug.print("missing in output: '{s}'\noutput was:\n{s}\n", .{ needle, out });
                return error.TestExpectedSubstring;
            };
            prev = at + needle.len;
        }

        // OnUpdate flows that touch entities get the TODO stub so
        // the file still parses.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "const entity: EntityId = undefined;") != null);
    }

    test "GetComponent node emits component @import in prelude" {
        // Issue #101: the codegen used to reference `Position` without
        // importing it, so the emitted file failed to compile.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_gc");
        defer allocator.free(out);

        const needle = "const Position = @import(\"../../components/Position.zig\").Position;";
        try expect.toBeTrue(std.mem.indexOf(u8, out, needle) != null);
        // Exactly once -- no duplicate emission.
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, out, start, needle)) |at| {
            count += 1;
            start = at + 1;
        }
        try expect.equal(count, @as(usize, 1));

        // And it lands in the prelude, before the function header.
        const import_at = std.mem.indexOf(u8, out, needle).?;
        const fn_at = std.mem.indexOf(u8, out, "pub fn onCreate").?;
        try expect.toBeTrue(import_at < fn_at);
    }

    test "SetField target extracts type-name with the same split rule as the template" {
        // The SetField template uses `lastIndexOfScalar('.')` to peel
        // the type off `target`. The import collector must use the
        // same split so a target like `Position.x` produces a single
        // `Position` import that matches the symbol the template
        // actually references.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "42" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_sf");
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "const Position = @import(\"../../components/Position.zig\").Position;") != null);
        // And the SetField template still calls into the same name.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "game.setField(Position, .x, entity, n1_value);") != null);
    }

    test "duplicate component references emit exactly one @import" {
        // Two GetComponent nodes for the same type used to risk
        // emitting two import lines. The collector de-dupes via a
        // string set.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "0" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 4, .pin = "value" }, .to = .{ .node = 3, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_dup");
        defer allocator.free(out);

        const needle = "const Position = @import(\"../../components/Position.zig\").Position;";
        var count: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, out, start, needle)) |at| {
            count += 1;
            start = at + 1;
        }
        try expect.equal(count, @as(usize, 1));
    }

    test "multiple distinct component types emit sorted @import lines" {
        // Alphabetical order keeps the output byte-stable across
        // graph re-arrangements -- a `Velocity` node added before a
        // `Position` node would otherwise flip the prelude.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Velocity" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_sort");
        defer allocator.free(out);

        const pos_needle = "const Position = @import(\"../../components/Position.zig\").Position;";
        const vel_needle = "const Velocity = @import(\"../../components/Velocity.zig\").Velocity;";
        const pos_at = std.mem.indexOf(u8, out, pos_needle) orelse return error.TestExpectedSubstring;
        const vel_at = std.mem.indexOf(u8, out, vel_needle) orelse return error.TestExpectedSubstring;
        try expect.toBeTrue(pos_at < vel_at);
    }

    test "namespaced component type name surfaces NamespacedComponentType error" {
        // Bare identifiers only in v1: `const foo.bar.Baz = @import(...);`
        // isn't valid Zig, so the codegen must refuse rather than emit
        // a broken prelude. Tracked for v2.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .GetComponent = .{ .type = "foo.bar.Baz" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        const result = renderFromZon(allocator, src, "ns");
        try expect.toBeTrue(if (result) |out| blk: {
            allocator.free(out);
            break :blk false;
        } else |err| err == error.NamespacedComponentType);
    }

    test "SetField target with multi-dot type name surfaces NamespacedComponentType" {
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .SetField = .{ .target = "foo.bar.Baz.x" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 2, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const result = renderFromZon(allocator, src, "ns_sf");
        try expect.toBeTrue(if (result) |out| blk: {
            allocator.free(out);
            break :blk false;
        } else |err| err == error.NamespacedComponentType);
    }

    test "flow with no component references emits zero component @imports" {
        // Don't leak imports into pure-arithmetic flows -- they'd
        // reference files that don't exist on disk.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 2, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 3, .pos = .{0, 0}, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "value" }, .to = .{ .node = 3, .pin = "a" } },
            \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "b" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "imp_none");
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(u8, out, "@import(\"../../components/") == null);
    }

    test "output passes std.zig.Ast.parse without errors" {
        // The single strongest correctness signal -- anything we
        // emit must be syntactically valid Zig.
        const allocator = std.testing.allocator;
        const src =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{280, 80}, .kind = .{ .BinOp = .{ .op = .add } } },
            \\        .{ .id = 3, .pos = .{440, 80}, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 4, .pos = .{0, 0}, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\        .{ .id = 5, .pos = .{0, 0}, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 6, .pos = .{0, 0}, .kind = .{ .Call = .{ .callee = "std.math.max" } } },
            \\    },
            \\    .links = .{
            \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
            \\        .{ .from = .{ .node = 4, .pin = "value" }, .to = .{ .node = 2, .pin = "b" } },
            \\        .{ .from = .{ .node = 2, .pin = "result" }, .to = .{ .node = 6, .pin = "arg0" } },
            \\        .{ .from = .{ .node = 5, .pin = "value" }, .to = .{ .node = 6, .pin = "arg1" } },
            \\        .{ .from = .{ .node = 6, .pin = "result" }, .to = .{ .node = 3, .pin = "value" } },
            \\    },
            \\}
            \\
        ;
        const out = try renderFromZon(allocator, src, "all_kinds");
        defer allocator.free(out);

        // `std.zig.Ast.parse` needs a sentinel-terminated source.
        const z = try allocator.allocSentinel(u8, out.len, 0);
        defer allocator.free(z);
        @memcpy(z[0..out.len], out);

        var ast = try std.zig.Ast.parse(allocator, z, .zig);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) {
            std.debug.print("emitted Zig didn't parse:\n{s}\n", .{out});
        }
        try expect.equal(ast.errors.len, @as(usize, 0));
    }
};

pub const FlowConvertTests = struct {
    // The flows-smoke example flow (labelle-assembler) — the canonical
    // in-tree `.flow.zon`. Used as the conversion fixture.
    const flows_smoke_zon =
        \\.{
        \\    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
        \\    .nodes = .{
        \\        .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .GetComponent = .{ .type = "Position" } } },
        \\        .{ .id = 2, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "1.0" } } },
        \\        .{ .id = 3, .pos = .{ 0, 0 }, .kind = .{ .BinOp = .{ .op = .add } } },
        \\        .{ .id = 4, .pos = .{ 0, 0 }, .kind = .{ .SetField = .{ .target = "Position.x" } } },
        \\    },
        \\    .links = .{
        \\        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 3, .pin = "a" } },
        \\        .{ .from = .{ .node = 2, .pin = "value" }, .to = .{ .node = 3, .pin = "b" } },
        \\        .{ .from = .{ .node = 3, .pin = "result" }, .to = .{ .node = 4, .pin = "value" } },
        \\    },
        \\}
        \\
    ;

    // Strip `//` line comments so the JSONC output can be fed to the
    // strict `std.json` parser. Caller owns the returned bytes.
    fn stripLineComments(allocator: std.mem.Allocator, jsonc: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        var in_string = false;
        while (i < jsonc.len) : (i += 1) {
            const c = jsonc[i];
            if (in_string) {
                try out.append(allocator, c);
                if (c == '\\' and i + 1 < jsonc.len) {
                    i += 1;
                    try out.append(allocator, jsonc[i]);
                } else if (c == '"') {
                    in_string = false;
                }
                continue;
            }
            if (c == '"') {
                in_string = true;
                try out.append(allocator, c);
            } else if (c == '/' and i + 1 < jsonc.len and jsonc[i + 1] == '/') {
                while (i < jsonc.len and jsonc[i] != '\n') : (i += 1) {}
                if (i < jsonc.len) try out.append(allocator, '\n');
            } else {
                try out.append(allocator, c);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    // Convert a `.flow.zon` source and return the JSONC parsed as a
    // `std.json.Parsed(Value)` — caller calls `.deinit()`.
    fn convertToValue(allocator: std.mem.Allocator, zon: []const u8, name: ?[]const u8) !std.json.Parsed(std.json.Value) {
        var loaded = try flow_io.parseFlow(allocator, zon);
        defer loaded.deinit();
        const jsonc = try flow_convert.flowToJsonc(allocator, loaded.flow, name);
        defer allocator.free(jsonc);
        const stripped = try stripLineComments(allocator, jsonc);
        defer allocator.free(stripped);
        return std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
    }

    test "converter output is valid JSON once comments are stripped" {
        const allocator = std.testing.allocator;
        var parsed = try convertToValue(allocator, flows_smoke_zon, "tick");
        defer parsed.deinit();
        try expect.equal(@as(std.meta.Tag(std.json.Value), parsed.value), .object);
    }

    test "flattens the kind tagged-union into a flat type + params" {
        // `.kind = .{ .BinOp = .{ .op = .add } }` must become
        // `"type": "BinOp", "op": "add"` — no nested `kind` object.
        const allocator = std.testing.allocator;
        var parsed = try convertToValue(allocator, flows_smoke_zon, "tick");
        defer parsed.deinit();

        const root = parsed.value.object;
        const nodes = root.get("nodes").?.array;
        try expect.equal(nodes.items.len, @as(usize, 4));

        // Node 3 is the BinOp. Nodes are emitted id-sorted, so index 2.
        const binop = nodes.items[2].object;
        try expect.equal(binop.get("id").?.integer, @as(i64, 3));
        try expect.toBeTrue(std.mem.eql(u8, binop.get("type").?.string, "BinOp"));
        try expect.toBeTrue(std.mem.eql(u8, binop.get("op").?.string, "add"));
        // No leftover `kind` wrapper.
        try expect.toBeTrue(binop.get("kind") == null);

        // GetComponent: `.type` field is renamed to `component` per RFC §2.
        const get_comp = nodes.items[0].object;
        try expect.toBeTrue(std.mem.eql(u8, get_comp.get("type").?.string, "GetComponent"));
        try expect.toBeTrue(std.mem.eql(u8, get_comp.get("component").?.string, "Position"));
    }

    test "renames links to edges, same from/to shape" {
        const allocator = std.testing.allocator;
        var parsed = try convertToValue(allocator, flows_smoke_zon, "tick");
        defer parsed.deinit();

        const root = parsed.value.object;
        try expect.toBeTrue(root.get("links") == null);

        const edges = root.get("edges").?.array;
        try expect.equal(edges.items.len, @as(usize, 3));
        const first = edges.items[0].object;
        const from = first.get("from").?.object;
        const to = first.get("to").?.object;
        try expect.equal(from.get("node").?.integer, @as(i64, 1));
        try expect.toBeTrue(std.mem.eql(u8, from.get("pin").?.string, "x"));
        try expect.equal(to.get("node").?.integer, @as(i64, 3));
        try expect.toBeTrue(std.mem.eql(u8, to.get("pin").?.string, "a"));
    }

    test "event tagged-union is flattened with a type discriminator" {
        const allocator = std.testing.allocator;
        var parsed = try convertToValue(allocator, flows_smoke_zon, "tick");
        defer parsed.deinit();

        const event = parsed.value.object.get("event").?.object;
        try expect.toBeTrue(std.mem.eql(u8, event.get("type").?.string, "OnCreate"));
        try expect.toBeTrue(std.mem.eql(u8, event.get("arg_entity").?.string, "entity"));
    }

    test "OnUpdate event flattens to type + arg_dt" {
        const allocator = std.testing.allocator;
        const zon =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "delta" } },
            \\    .nodes = .{},
            \\    .links = .{},
            \\}
            \\
        ;
        var parsed = try convertToValue(allocator, zon, "upd");
        defer parsed.deinit();
        const event = parsed.value.object.get("event").?.object;
        try expect.toBeTrue(std.mem.eql(u8, event.get("type").?.string, "OnUpdate"));
        try expect.toBeTrue(std.mem.eql(u8, event.get("arg_dt").?.string, "delta"));
    }

    test "non-null name becomes the top-level registry key" {
        const allocator = std.testing.allocator;
        var parsed = try convertToValue(allocator, flows_smoke_zon, "tick");
        defer parsed.deinit();
        try expect.toBeTrue(std.mem.eql(u8, parsed.value.object.get("name").?.string, "tick"));
    }

    test "null name omits the optional name field" {
        const allocator = std.testing.allocator;
        var parsed = try convertToValue(allocator, flows_smoke_zon, null);
        defer parsed.deinit();
        try expect.toBeTrue(parsed.value.object.get("name") == null);
    }

    test "preserves node id and pos verbatim" {
        const allocator = std.testing.allocator;
        const zon =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 7, .pos = .{ 120, 80 }, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var parsed = try convertToValue(allocator, zon, "p");
        defer parsed.deinit();
        const node = parsed.value.object.get("nodes").?.array.items[0].object;
        try expect.equal(node.get("id").?.integer, @as(i64, 7));
        const pos = node.get("pos").?.array;
        try expect.equal(pos.items.len, @as(usize, 2));
        // Position values are whole numbers here — JSON renders them
        // as integers.
        try expect.equal(pos.items[0].integer, @as(i64, 120));
        try expect.equal(pos.items[1].integer, @as(i64, 80));
    }

    test "covers every NodeKind variant in one flow" {
        const allocator = std.testing.allocator;
        const zon =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .GetComponent = .{ .type = "Position" } } },
            \\        .{ .id = 2, .pos = .{ 0, 0 }, .kind = .{ .SetField = .{ .target = "Position.x" } } },
            \\        .{ .id = 3, .pos = .{ 0, 0 }, .kind = .{ .BinOp = .{ .op = .mul } } },
            \\        .{ .id = 4, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "1.5" } } },
            \\        .{ .id = 5, .pos = .{ 0, 0 }, .kind = .{ .Identifier = .{ .name = "speed" } } },
            \\        .{ .id = 6, .pos = .{ 0, 0 }, .kind = .{ .Call = .{ .callee = "std.math.sin" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var parsed = try convertToValue(allocator, zon, "all");
        defer parsed.deinit();
        const nodes = parsed.value.object.get("nodes").?.array;
        try expect.equal(nodes.items.len, @as(usize, 6));

        const get_comp = nodes.items[0].object;
        try expect.toBeTrue(std.mem.eql(u8, get_comp.get("type").?.string, "GetComponent"));
        try expect.toBeTrue(std.mem.eql(u8, get_comp.get("component").?.string, "Position"));

        const set_field = nodes.items[1].object;
        try expect.toBeTrue(std.mem.eql(u8, set_field.get("type").?.string, "SetField"));
        try expect.toBeTrue(std.mem.eql(u8, set_field.get("target").?.string, "Position.x"));

        const bin_op = nodes.items[2].object;
        try expect.toBeTrue(std.mem.eql(u8, bin_op.get("type").?.string, "BinOp"));
        try expect.toBeTrue(std.mem.eql(u8, bin_op.get("op").?.string, "mul"));

        const lit = nodes.items[3].object;
        try expect.toBeTrue(std.mem.eql(u8, lit.get("type").?.string, "Literal"));
        // `1.5` is a JSON-native number, not a quoted string (RFC §2).
        try expect.equal(lit.get("value").?.float, @as(f64, 1.5));

        const ident = nodes.items[4].object;
        try expect.toBeTrue(std.mem.eql(u8, ident.get("type").?.string, "Identifier"));
        try expect.toBeTrue(std.mem.eql(u8, ident.get("name").?.string, "speed"));

        const call = nodes.items[5].object;
        try expect.toBeTrue(std.mem.eql(u8, call.get("type").?.string, "Call"));
        try expect.toBeTrue(std.mem.eql(u8, call.get("callee").?.string, "std.math.sin"));
    }

    test "conversion is deterministic — same input renders byte-identically" {
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator, flows_smoke_zon);
        defer loaded.deinit();

        const a = try flow_convert.flowToJsonc(allocator, loaded.flow, "tick");
        defer allocator.free(a);
        const b = try flow_convert.flowToJsonc(allocator, loaded.flow, "tick");
        defer allocator.free(b);
        try expect.toBeTrue(std.mem.eql(u8, a, b));
    }

    test "round-trips: zon -> jsonc -> json structurally matches the source flow" {
        // The converter has no JSONC reader (the new parser, #1, owns
        // that). We instead assert the JSON object faithfully carries
        // every field the parsed `.flow.zon` had — node count, link
        // count, ids, ops, pin names.
        const allocator = std.testing.allocator;
        var loaded = try flow_io.parseFlow(allocator, flows_smoke_zon);
        defer loaded.deinit();

        var parsed = try convertToValue(allocator, flows_smoke_zon, "tick");
        defer parsed.deinit();
        const root = parsed.value.object;

        try expect.equal(root.get("nodes").?.array.items.len, loaded.flow.nodes.len);
        try expect.equal(root.get("edges").?.array.items.len, loaded.flow.links.len);

        // Every source node id appears in the JSON, with a `type`.
        for (loaded.flow.nodes) |src_node| {
            var found = false;
            for (root.get("nodes").?.array.items) |jn| {
                if (jn.object.get("id").?.integer == @as(i64, @intCast(src_node.id))) {
                    found = true;
                    try expect.toBeTrue(jn.object.get("type").?.string.len > 0);
                }
            }
            try expect.toBeTrue(found);
        }
    }

    test "escapes special characters in string values" {
        // A Literal value with an embedded quote and backslash must
        // round-trip as a valid JSON string.
        const allocator = std.testing.allocator;
        const zon =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "\"a\\b\"" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var parsed = try convertToValue(allocator, zon, "esc");
        defer parsed.deinit();
        const lit = parsed.value.object.get("nodes").?.array.items[0].object;
        try expect.toBeTrue(std.mem.eql(u8, lit.get("value").?.string, "\"a\\b\""));
    }

    test "jsoncPathFromZon swaps the .flow.zon extension" {
        const allocator = std.testing.allocator;
        const p1 = try flow_convert.jsoncPathFromZon(allocator, "scripts/flows/tick.flow.zon");
        defer allocator.free(p1);
        try expect.toBeTrue(std.mem.eql(u8, p1, "scripts/flows/tick.flow.jsonc"));

        const p2 = try flow_convert.jsoncPathFromZon(allocator, "/abs/move.flow.zon");
        defer allocator.free(p2);
        try expect.toBeTrue(std.mem.eql(u8, p2, "/abs/move.flow.jsonc"));
    }

    test "convertFile writes .flow.jsonc and (hard cut) drops the .flow.zon" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        const zon_path = try std.fs.path.join(allocator, &.{ dir, "demo.flow.zon" });
        defer allocator.free(zon_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = zon_path, .data = flows_smoke_zon });

        const out_path = try flow_convert.convertFile(std.testing.io, allocator, zon_path, true);
        defer allocator.free(out_path);
        try expect.toBeTrue(std.mem.endsWith(u8, out_path, "demo.flow.jsonc"));

        // The .flow.jsonc exists and parses; the .flow.zon is gone.
        const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(1 << 20));
        defer allocator.free(written);
        const stripped = try stripLineComments(allocator, written);
        defer allocator.free(stripped);
        var jp = try std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
        defer jp.deinit();
        try expect.equal(@as(std.meta.Tag(std.json.Value), jp.value), .object);

        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().readFileAlloc(std.testing.io, zon_path, allocator, .limited(1 << 20)),
        );
    }

    test "convertFile --keep leaves the source .flow.zon in place" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        const zon_path = try std.fs.path.join(allocator, &.{ dir, "keep.flow.zon" });
        defer allocator.free(zon_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = zon_path, .data = flows_smoke_zon });

        const out_path = try flow_convert.convertFile(std.testing.io, allocator, zon_path, false);
        defer allocator.free(out_path);

        const still_there = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, zon_path, allocator, .limited(1 << 20));
        defer allocator.free(still_there);
        try expect.toBeTrue(still_there.len > 0);
    }

    test "Literal value is emitted as a JSON-native literal, not a string" {
        const allocator = std.testing.allocator;
        const zon =
            \\.{
            \\    .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
            \\    .nodes = .{
            \\        .{ .id = 1, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "42" } } },
            \\        .{ .id = 2, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "1.0" } } },
            \\        .{ .id = 3, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "true" } } },
            \\        .{ .id = 4, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "false" } } },
            \\        .{ .id = 5, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "null" } } },
            \\        .{ .id = 6, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "-3.5e2" } } },
            \\        .{ .id = 7, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "speed" } } },
            \\        .{ .id = 8, .pos = .{ 0, 0 }, .kind = .{ .Literal = .{ .value = "007" } } },
            \\    },
            \\    .links = .{},
            \\}
            \\
        ;
        var parsed = try convertToValue(allocator, zon, "lit");
        defer parsed.deinit();
        const nodes = parsed.value.object.get("nodes").?.array;

        // Integer / float literals: JSON numbers.
        try expect.equal(nodes.items[0].object.get("value").?.integer, @as(i64, 42));
        try expect.equal(nodes.items[1].object.get("value").?.float, @as(f64, 1.0));
        try expect.equal(nodes.items[5].object.get("value").?.float, @as(f64, -350.0));
        // Booleans / null: JSON keywords.
        try expect.toBeTrue(nodes.items[2].object.get("value").?.bool);
        try expect.toBeTrue(!nodes.items[3].object.get("value").?.bool);
        try expect.equal(@as(std.meta.Tag(std.json.Value), nodes.items[4].object.get("value").?), .null);
        // Non-JSON-number text (identifier, leading-zero int) stays a string.
        try expect.toBeTrue(std.mem.eql(u8, nodes.items[6].object.get("value").?.string, "speed"));
        try expect.toBeTrue(std.mem.eql(u8, nodes.items[7].object.get("value").?.string, "007"));
    }

    test "convertFile rejects a non-.flow.zon path before the hard cut" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        // A file that is NOT a .flow.zon. If the converter accepted it,
        // the hard cut would delete this unrelated file.
        const stray_path = try std.fs.path.join(allocator, &.{ dir, "notes.txt" });
        defer allocator.free(stray_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stray_path, .data = "keep me" });

        try std.testing.expectError(
            error.NotAFlowZonFile,
            flow_convert.convertFile(std.testing.io, allocator, stray_path, true),
        );

        // The stray file is untouched — not deleted, not rewritten.
        const still_there = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stray_path, allocator, .limited(1 << 20));
        defer allocator.free(still_there);
        try expect.toBeTrue(std.mem.eql(u8, still_there, "keep me"));
    }
};
