const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });

    const flow_codegen_module = b.addModule("flow_codegen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ───────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run flow_codegen tests");

    // Lightweight smoke compilation of the public surface. Picks up
    // any `test {}` blocks added directly to `src/` files in the
    // future; today these files have no in-place tests (the real
    // suite lives in `test/root_test.zig`).
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    // BDD-style tests, mirroring labelle-gfx/spatial_grid.
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flow_codegen", .module = flow_codegen_module },
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });
    test_step.dependOn(&b.addRunArtifact(root_tests).step);

    // `convert` step — drives the RFC-FLOW-VOCABULARY §3 v1 → v2
    // converter over a single `.flow.jsonc` file (flow-codegen#15 item
    // 4). Rewrites a legacy `event: { type: OnEvent, name: ... }`
    // header into an in-graph `Event` node. Idempotent — a file
    // already on the v2 form (carries an Event node) is canonicalized
    // through the renderer (byte-identical on a second run).
    //
    //   zig build convert -- <path/to/foo.flow.jsonc>
    //
    // Lifecycle events (`OnCreate` / `OnUpdate` / `OnDestroy`) and
    // `OnCall` subgraphs are NOT Event-node-compatible — the engine
    // does not yet expose them as `pub const Events`. The driver
    // reports them and leaves the file unchanged.
    //
    // The earlier `convert_legacy_onevent` step (RFC-PLUGIN-EVENTS
    // phase 6, flow-codegen#13) was retired alongside the legacy
    // `OnEvent` parser branch; this step picks up the same name.
    const convert_exe = b.addExecutable(.{
        .name = "convert_legacy_v1_to_v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/convert_legacy_v1_to_v2.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flow_codegen", .module = flow_codegen_module },
            },
        }),
    });
    const convert_run = b.addRunArtifact(convert_exe);
    if (b.args) |args| convert_run.addArgs(args);
    const convert_step = b.step("convert", "Convert a v1 .flow.jsonc (legacy event: header) to a v2 (Event node) form");
    convert_step.dependOn(&convert_run.step);
}
