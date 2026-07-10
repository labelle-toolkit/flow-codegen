//! Golden-file tests for the Call → CustomNode converter
//! (flow-codegen#18, RFC-FLOW-VOCABULARY *Migration* section).
//!
//! Each fixture is a triple under
//! `test/fixtures/call_to_customnode/<name>/`:
//!   - `input.flow.jsonc`   — the source flow (already v2)
//!   - `catalog.json`       — the project flow-catalog sidecar
//!   - `expected.flow.jsonc` — the post-convert rendered flow
//!
//! The test parses input + catalog, runs `convertFlow`, renders the
//! result through `renderFlowJsonc`, and compares byte-for-byte against
//! `expected.flow.jsonc`. The render path is shared with `saveFlow` so
//! the comparison covers what the driver actually writes back to disk.

const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const flow_codegen_pkg = @import("flow_codegen");

const flow_io = flow_codegen_pkg.flow_io;
const call_to_customnode = flow_codegen_pkg.call_to_customnode;

pub const CallToCustomNodeTests = struct {
    // Embed fixtures at compile time so the test binary stays
    // hermetic — no filesystem reads at test-runtime, no cwd
    // dependency. Each fixture lives in its own directory; the
    // path stem is the test name.

    const simple_input = @embedFile("fixtures/call_to_customnode/simple_match/input.flow.jsonc");
    const simple_catalog = @embedFile("fixtures/call_to_customnode/simple_match/catalog.json");
    const simple_expected = @embedFile("fixtures/call_to_customnode/simple_match/expected.flow.jsonc");

    const nomatch_input = @embedFile("fixtures/call_to_customnode/no_match/input.flow.jsonc");
    const nomatch_catalog = @embedFile("fixtures/call_to_customnode/no_match/catalog.json");
    const nomatch_expected = @embedFile("fixtures/call_to_customnode/no_match/expected.flow.jsonc");

    const ambig_input = @embedFile("fixtures/call_to_customnode/ambiguous_match/input.flow.jsonc");
    const ambig_catalog = @embedFile("fixtures/call_to_customnode/ambiguous_match/catalog.json");
    const ambig_expected = @embedFile("fixtures/call_to_customnode/ambiguous_match/expected.flow.jsonc");

    const args_input = @embedFile("fixtures/call_to_customnode/positional_args/input.flow.jsonc");
    const args_catalog = @embedFile("fixtures/call_to_customnode/positional_args/catalog.json");
    const args_expected = @embedFile("fixtures/call_to_customnode/positional_args/expected.flow.jsonc");

    const import_input = @embedFile("fixtures/call_to_customnode/import_wrapper/input.flow.jsonc");
    const import_catalog = @embedFile("fixtures/call_to_customnode/import_wrapper/catalog.json");
    const import_expected = @embedFile("fixtures/call_to_customnode/import_wrapper/expected.flow.jsonc");

    /// Run one fixture: parse, convert, render, compare against the
    /// expected rendering. Returns the (loaded, result) pair so the
    /// test can pull per-outcome diagnostics out for further checks.
    fn runFixture(
        allocator: std.mem.Allocator,
        input: []const u8,
        catalog_src: []const u8,
        expected: []const u8,
    ) !struct { rendered: []u8 } {
        var loaded = try flow_io.parseFlow(allocator, input);
        defer loaded.deinit();

        var catalog = try call_to_customnode.parseCatalog(allocator, catalog_src);
        defer catalog.deinit();

        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, result.loaded);
        errdefer allocator.free(rendered);
        try expect.toBeTrue(std.mem.eql(u8, rendered, expected));
        return .{ .rendered = rendered };
    }

    test "convertFlow carries locals + collections through (flow-codegen#24 bugbot)" {
        const allocator = std.testing.allocator;
        const input =
            \\{
            \\  "name": "f",
            \\  "locals": [ { "name": "tmp", "type": "i32", "default": 0 } ],
            \\  "collections": [ { "name": "xs", "element": "u32" } ],
            \\  "nodes": [ { "id": 1, "type": "Literal", "value": 1, "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, input);
        defer loaded.deinit();
        var catalog = try call_to_customnode.parseCatalog(allocator, simple_catalog);
        defer catalog.deinit();
        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();
        // Both blocks survive the conversion (they default to empty on
        // Flow, so a missing copy silently drops them).
        try expect.toBeTrue(result.loaded.flow.locals.len == 1);
        try expect.toBeTrue(std.mem.eql(u8, result.loaded.flow.locals[0].name, "tmp"));
        try expect.toBeTrue(result.loaded.flow.collections.len == 1);
        try expect.toBeTrue(std.mem.eql(u8, result.loaded.flow.collections[0].name, "xs"));
        try expect.toBeTrue(std.mem.eql(u8, result.loaded.flow.collections[0].element, "u32"));
    }

    test "convertFlow carries a map collection's kind/key/value through (flow-codegen#24)" {
        const allocator = std.testing.allocator;
        const input =
            \\{
            \\  "name": "f",
            \\  "collections": [ { "name": "scores", "kind": "map", "key": "u32", "value": "i32" } ],
            \\  "nodes": [ { "id": 1, "type": "MapClear", "collection": "scores", "pos": [0, 0] } ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, input);
        defer loaded.deinit();
        var catalog = try call_to_customnode.parseCatalog(allocator, simple_catalog);
        defer catalog.deinit();
        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();
        // The map shape (kind + key/value) survives the deep copy; a
        // missing field would silently drop to the `.list`/empty defaults.
        try expect.toBeTrue(result.loaded.flow.collections.len == 1);
        try expect.toBeTrue(result.loaded.flow.collections[0].kind == .map);
        try expect.toBeTrue(std.mem.eql(u8, result.loaded.flow.collections[0].key, "u32"));
        try expect.toBeTrue(std.mem.eql(u8, result.loaded.flow.collections[0].value, "i32"));
    }

    test "simple match: Call applyImpulse -> CustomNode apply_impulse" {
        const allocator = std.testing.allocator;
        const out = try runFixture(allocator, simple_input, simple_catalog, simple_expected);
        defer allocator.free(out.rendered);
    }

    test "no match: std.math.sin passes through untouched" {
        // The escape-hatch path: an `std.*` callee is left alone (RFC §7).
        const allocator = std.testing.allocator;
        const out = try runFixture(allocator, nomatch_input, nomatch_catalog, nomatch_expected);
        defer allocator.free(out.rendered);
    }

    test "ambiguous match: two plugins expose same verb -> pass through" {
        // The converter records an `ambiguous` outcome but leaves the
        // node on disk unchanged — the user resolves the ambiguity by
        // editing the callee to include a plugin prefix.
        const allocator = std.testing.allocator;

        var loaded = try flow_io.parseFlow(allocator, ambig_input);
        defer loaded.deinit();

        var catalog = try call_to_customnode.parseCatalog(allocator, ambig_catalog);
        defer catalog.deinit();

        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, result.loaded);
        defer allocator.free(rendered);
        try expect.toBeTrue(std.mem.eql(u8, rendered, ambig_expected));

        // The outcome records the ambiguity — the driver consumes
        // this to print `// TODO: ambiguous match for <callee>` to
        // stderr.
        try expect.equal(result.outcomes.len, 1);
        try expect.equal(@as(std.meta.Tag(@TypeOf(result.outcomes[0].status)), result.outcomes[0].status), .ambiguous);
        try expect.equal(result.outcomes[0].status.ambiguous.len, 2);
    }

    test "positional args are preserved: Call with arg0/arg1 -> CustomNode" {
        // Both `Call` and `CustomNode` use the same `argN` pin
        // convention (see `flow-codegen/src/codegen.zig`'s
        // `isCallArgPin`), so the edges round-trip unchanged after a
        // node-kind rewrite.
        const allocator = std.testing.allocator;
        const out = try runFixture(allocator, args_input, args_catalog, args_expected);
        defer allocator.free(out.rendered);
    }

    test "@import wrapper is stripped before resolution" {
        // `@import("../hits.zig").currentTotal` reduces to
        // `currentTotal` for matching purposes, then snake_cases to
        // `current_total` and resolves to `hits.current_total` in the
        // catalog.
        const allocator = std.testing.allocator;
        const out = try runFixture(allocator, import_input, import_catalog, import_expected);
        defer allocator.free(out.rendered);
    }

    test "no-Call flows return identical bytes" {
        // The converter is a no-op for flows that have no `Call`
        // nodes — verify the renderer still produces canonical output
        // (byte-identical to a re-render of the original).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "no_calls",
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "value": "1.5", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();

        const catalog_src =
            \\{ "plugins": [] }
        ;
        var catalog = try call_to_customnode.parseCatalog(allocator, catalog_src);
        defer catalog.deinit();

        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();

        const baseline = try flow_io.renderFlowJsonc(allocator, loaded);
        defer allocator.free(baseline);
        const converted = try flow_io.renderFlowJsonc(allocator, result.loaded);
        defer allocator.free(converted);

        try expect.toBeTrue(std.mem.eql(u8, baseline, converted));
        try expect.equal(result.outcomes.len, 0);
    }

    test "rewritten CustomNode round-trips through parseFlow" {
        // The converted flow must re-parse cleanly — the result isn't
        // useful if it lands in a state the loader can't read back.
        const allocator = std.testing.allocator;

        var loaded = try flow_io.parseFlow(allocator, simple_input);
        defer loaded.deinit();
        var catalog = try call_to_customnode.parseCatalog(allocator, simple_catalog);
        defer catalog.deinit();
        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();

        const rendered = try flow_io.renderFlowJsonc(allocator, result.loaded);
        defer allocator.free(rendered);

        var roundtrip = try flow_io.parseFlow(allocator, rendered);
        defer roundtrip.deinit();
        try expect.equal(@as(std.meta.Tag(flow_io.NodeKind), roundtrip.flow.nodes[0].kind), .CustomNode);
        try expect.toBeTrue(std.mem.eql(u8, roundtrip.flow.nodes[0].kind.CustomNode.name, "box2d.apply_impulse"));
    }

    test "catalog with unknown extra keys still parses" {
        // The catalog format evolves with each plugin-metadata feature;
        // unknown top-level / per-entry keys must be ignored, only
        // `plugins[].flow_nodes[].qualified` is required.
        const allocator = std.testing.allocator;
        const catalog_src =
            \\{
            \\  "generated_at": "2026-05-23T12:00",
            \\  "unknown_root_key": [1, 2, 3],
            \\  "plugins": [
            \\    {
            \\      "name": "box2d",
            \\      "flow_nodes": [
            \\        {
            \\          "qualified": "box2d.apply_impulse",
            \\          "unknown_entry_key": "ignored"
            \\        }
            \\      ],
            \\      "pin_styles": [],
            \\      "events": []
            \\    }
            \\  ]
            \\}
        ;
        var catalog = try call_to_customnode.parseCatalog(allocator, catalog_src);
        defer catalog.deinit();
        try expect.equal(catalog.entries.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, catalog.entries[0].qualified, "box2d.apply_impulse"));
        try expect.toBeTrue(std.mem.eql(u8, catalog.entries[0].plugin, "box2d"));
        try expect.toBeTrue(std.mem.eql(u8, catalog.entries[0].verb, "apply_impulse"));
    }

    test "catalog without plugins[] is MalformedCatalog" {
        const allocator = std.testing.allocator;
        try std.testing.expectError(
            error.MalformedCatalog,
            call_to_customnode.parseCatalog(allocator, "{}"),
        );
    }

    test "outcome statuses cover all four paths" {
        // One flow exercising every status. The catalog has both
        // `box2d.apply_impulse` and `chipmunk.apply_impulse` so a bare
        // `applyImpulse` is ambiguous; `box2d.applyImpulse` is unique;
        // `std.math.sin` is escape-hatch; `unknownFn` has no match.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "name": "all_paths",
            \\  "nodes": [
            \\    { "id": 1, "type": "Call", "callee": "box2d.applyImpulse", "pos": [0, 0] },
            \\    { "id": 2, "type": "Call", "callee": "applyImpulse", "pos": [0, 0] },
            \\    { "id": 3, "type": "Call", "callee": "std.math.sin", "pos": [0, 0] },
            \\    { "id": 4, "type": "Call", "callee": "unknownFn", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        const catalog_src =
            \\{
            \\  "plugins": [
            \\    { "name": "box2d", "flow_nodes": [ { "qualified": "box2d.apply_impulse" } ] },
            \\    { "name": "chipmunk", "flow_nodes": [ { "qualified": "chipmunk.apply_impulse" } ] }
            \\  ]
            \\}
        ;

        var loaded = try flow_io.parseFlow(allocator, src);
        defer loaded.deinit();
        var catalog = try call_to_customnode.parseCatalog(allocator, catalog_src);
        defer catalog.deinit();

        var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
        defer result.deinit();

        try expect.equal(result.outcomes.len, 4);
        // Node 1 → rewritten
        try expect.equal(@as(std.meta.Tag(@TypeOf(result.outcomes[0].status)), result.outcomes[0].status), .rewritten);
        try expect.toBeTrue(std.mem.eql(u8, result.outcomes[0].status.rewritten, "box2d.apply_impulse"));
        // Node 2 → ambiguous
        try expect.equal(@as(std.meta.Tag(@TypeOf(result.outcomes[1].status)), result.outcomes[1].status), .ambiguous);
        // Node 3 → escape hatch
        try expect.equal(@as(std.meta.Tag(@TypeOf(result.outcomes[2].status)), result.outcomes[2].status), .skipped_escape_hatch);
        // Node 4 → no match
        try expect.equal(@as(std.meta.Tag(@TypeOf(result.outcomes[3].status)), result.outcomes[3].status), .skipped_no_match);

        try expect.toBeTrue(result.anyRewritten());
    }
};
