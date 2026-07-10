//! String-formatting + value-helper reporter nodes (flow-codegen#26):
//! `Format`, `Concat`, `IntToString`, `FloatToString`. Each is a
//! REPORTER that allocates a `[]const u8` via `game.allocator`
//! (game-lifetime, no auto-free, `catch ""` on failure) and binds it to
//! an `n<id>_value` local exactly once — the same bound-once shape as
//! `Call`/`GetComponent` (NOT inlined like the pure reporters).
//!
//! Coverage per node:
//!   - parse → codegen produces the expected bind-to-local lowering,
//!   - round-trip (parse → write → parse) is stable,
//!   - the generated Zig passes AstGen (`expectAstGenOk`) — a real
//!     "generated code compiles" check, not merely `Ast.parse`.
//! Plus a multi-arg `Format` ordering test.

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_io = helpers.flow_io;
const flow_codegen = helpers.flow_codegen;
const expectAstGenOk = helpers.expectAstGenOk;

pub const StringNodeTests = struct {
    // -----------------------------------------------------------------
    // Format
    // -----------------------------------------------------------------

    test "Format lowers to a bound-once allocPrint with verbatim placeholders" {
        const allocator = std.testing.allocator;
        // Two typed args wired in declared order (arg0 string, arg1 int).
        // The template's `{s}`/`{d}` are REAL `std.fmt` placeholders and
        // must survive verbatim (NOT brace-doubled like a `Log` label).
        const src =
            \\{
            \\  "name": "fmt_demo",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "\"hp\"", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 42, "pos": [0, 0] },
            \\    { "id": 3, "type": "Format", "template": "{s}={d}", "pos": [0, 0] },
            \\    { "id": 4, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "arg1" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[2].kind), .Format);
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[2].kind.Format.template, "{s}={d}"));

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "fmt_demo" });
        defer allocator.free(out);

        // Exact bind-to-local lowering: typed args in declared order,
        // placeholders verbatim, game-lifetime alloc, safe empty fallback.
        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n3_value: []const u8 = std.fmt.allocPrint(game.allocator, \"{s}={d}\", .{n1_value, n2_value}) catch \"\";",
        ) != null);
        // It is a reporter consumed by the Output — returned, not discarded.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "return n3_value;") != null);

        try expectAstGenOk(allocator, out);
    }

    test "Format orders multiple typed args by declared arg<N>" {
        const allocator = std.testing.allocator;
        // Three args, wired out of source order in the edge list to prove
        // ordering is by `arg<N>` index, not edge declaration order.
        const src =
            \\{
            \\  "name": "fmt_order",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": 2, "pos": [0, 0] },
            \\    { "id": 3, "type": "Literal", "value": 3, "pos": [0, 0] },
            \\    { "id": 4, "type": "Format", "template": "{d}-{d}-{d}", "pos": [0, 0] },
            \\    { "id": 5, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "arg2" } },
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 4, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 4, "pin": "arg1" } },
            \\    { "from": { "node": 4, "pin": "value" }, "to": { "node": 5, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "fmt_order" });
        defer allocator.free(out);

        // arg0=n1, arg1=n2, arg2=n3 — ordered by index, not edge order.
        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "std.fmt.allocPrint(game.allocator, \"{d}-{d}-{d}\", .{n1_value, n2_value, n3_value}) catch \"\";",
        ) != null);

        try expectAstGenOk(allocator, out);
    }

    test "Format round-trips through write (parse -> write -> parse)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "fmt_rt",
            \\  "nodes": [
            \\    { "id": 1, "type": "Format", "template": "score: {d}", "pos": [10, 20] }
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
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .Format);
        try expect.toBeTrue(std.mem.eql(u8, roundtrip.flow.nodes[0].kind.Format.template, "score: {d}"));

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    test "Format with empty (default) template is valid" {
        const allocator = std.testing.allocator;
        // No `template` key — defaults to "" (an argument-free template).
        const src =
            \\{
            \\  "name": "fmt_empty",
            \\  "nodes": [
            \\    { "id": 1, "type": "Format", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(std.mem.eql(u8, loaded.flow.nodes[0].kind.Format.template, ""));

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "fmt_empty" });
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n1_value: []const u8 = std.fmt.allocPrint(game.allocator, \"\", .{}) catch \"\";",
        ) != null);

        try expectAstGenOk(allocator, out);
    }

    // -----------------------------------------------------------------
    // Concat
    // -----------------------------------------------------------------

    test "Concat lowers to a bound-once std.mem.concat" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "concat_demo",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "\"a\"", "pos": [0, 0] },
            \\    { "id": 2, "type": "Literal", "value": "\"b\"", "pos": [0, 0] },
            \\    { "id": 3, "type": "Concat", "pos": [0, 0] },
            \\    { "id": 4, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 3, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "arg1" } },
            \\    { "from": { "node": 3, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[2].kind), .Concat);

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "concat_demo" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n3_value: []const u8 = std.mem.concat(game.allocator, u8, &.{n1_value, n2_value}) catch \"\";",
        ) != null);

        try expectAstGenOk(allocator, out);
    }

    test "Concat with one arg lowers to a single dupe (not concat)" {
        // Arity 1 skips `std.mem.concat`'s measure+alloc+copy for a plain
        // `game.allocator.dupe`, keeping the game-allocated/author-owned
        // lifetime the multi-arg path produces (gemini, #46).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "concat_one",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "\"a\"", "pos": [0, 0] },
            \\    { "id": 2, "type": "Concat", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "concat_one" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n2_value: []const u8 = game.allocator.dupe(u8, n1_value) catch \"\";",
        ) != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "std.mem.concat") == null);

        try expectAstGenOk(allocator, out);
    }

    test "Concat with no args lowers to the empty string (no concat / no &.{})" {
        // Arity 0 binds `""` outright — `std.mem.concat(.., &.{})` would also
        // demand an element-type annotation on the empty literal (gemini, #46).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "concat_zero",
            \\  "nodes": [
            \\    { "id": 1, "type": "Concat", "pos": [0, 0] },
            \\    { "id": 2, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "concat_zero" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n1_value: []const u8 = \"\";",
        ) != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "std.mem.concat") == null);

        try expectAstGenOk(allocator, out);
    }

    test "Concat round-trips through write (payload-free)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "concat_rt",
            \\  "nodes": [
            \\    { "id": 1, "type": "Concat", "pos": [5, 6] }
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
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .Concat);

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    // -----------------------------------------------------------------
    // IntToString
    // -----------------------------------------------------------------

    test "IntToString lowers to a bound-once allocPrint {d}" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "i2s_demo",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 7, "pos": [0, 0] },
            \\    { "id": 2, "type": "IntToString", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .IntToString);

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "i2s_demo" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n2_value: []const u8 = std.fmt.allocPrint(game.allocator, \"{d}\", .{n1_value}) catch \"\";",
        ) != null);

        try expectAstGenOk(allocator, out);
    }

    test "IntToString round-trips through write (payload-free)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "i2s_rt",
            \\  "nodes": [
            \\    { "id": 1, "type": "IntToString", "pos": [1, 2] }
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
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .IntToString);

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    // -----------------------------------------------------------------
    // FloatToString
    // -----------------------------------------------------------------

    test "FloatToString lowers to a bound-once allocPrint {d}" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "f2s_demo",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "1.5", "pos": [0, 0] },
            \\    { "id": 2, "type": "FloatToString", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "out", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "value" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), loaded.flow.nodes[1].kind), .FloatToString);

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "f2s_demo" });
        defer allocator.free(out);

        try expect.toBeTrue(std.mem.indexOf(
            u8,
            out,
            "const n2_value: []const u8 = std.fmt.allocPrint(game.allocator, \"{d}\", .{n1_value}) catch \"\";",
        ) != null);

        try expectAstGenOk(allocator, out);
    }

    test "FloatToString round-trips through write (payload-free)" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "f2s_rt",
            \\  "nodes": [
            \\    { "id": 1, "type": "FloatToString", "pos": [3, 4] }
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
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .FloatToString);

        const rendered2 = try flow_io.renderFlowJsonc(allocator, roundtrip);
        defer allocator.free(rendered2);
        try expect.toBeTrue(std.mem.eql(u8, rendered, rendered2));
    }

    // -----------------------------------------------------------------
    // Cross-cutting: bound-once (NOT inlined), used by two consumers.
    // -----------------------------------------------------------------

    test "a string reporter feeding two consumers binds ONCE (not re-inlined)" {
        const allocator = std.testing.allocator;
        // A single Format feeding two Outputs must allocate exactly once
        // (one `n<id>_value` binding referenced twice) — re-inlining would
        // allocate per consumer and leak. This is the core of the
        // bound-once contract for the allocating reporters.
        const src =
            \\{
            \\  "name": "shared_fmt",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": 9, "pos": [0, 0] },
            \\    { "id": 2, "type": "Format", "template": "v={d}", "pos": [0, 0] },
            \\    { "id": 3, "type": "Output", "name": "a", "value_type": "[]const u8", "pos": [0, 0] },
            \\    { "id": 4, "type": "Output", "name": "b", "value_type": "[]const u8", "pos": [0, 0] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "arg0" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 3, "pin": "value" } },
            \\    { "from": { "node": 2, "pin": "value" }, "to": { "node": 4, "pin": "value" } }
            \\  ]
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const out = try flow_codegen.renderFlowZig(allocator, loaded.flow, .{ .flow_name = "shared_fmt" });
        defer allocator.free(out);

        // Exactly one allocPrint binding for the Format.
        const needle = "std.fmt.allocPrint(game.allocator,";
        const first = std.mem.indexOf(u8, out, needle) orelse return error.TestExpectedNeedle;
        try expect.toBeTrue(std.mem.indexOfPos(u8, out, first + needle.len, needle) == null);

        try expectAstGenOk(allocator, out);
    }
};
