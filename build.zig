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

    // `convert` step — drives `flow_io.legacy_onevent_to_name` over a
    // single `.flow.jsonc` file (Migration "Flow side", RFC-PLUGIN-
    // EVENTS §7). Lets in-tree flows be migrated without standing up a
    // full editor pass.
    //
    //   zig build convert -- <path/to/foo.flow.jsonc>
    //
    // Idempotent — a file already on the new form is reported and left
    // alone.
    const convert_exe = b.addExecutable(.{
        .name = "convert_legacy_onevent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/convert_legacy_onevent.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flow_codegen", .module = flow_codegen_module },
            },
        }),
    });
    const convert_run = b.addRunArtifact(convert_exe);
    if (b.args) |args| convert_run.addArgs(args);
    const convert_step = b.step("convert", "Convert a legacy OnEvent .flow.jsonc to the new name form");
    convert_step.dependOn(&convert_run.step);
}
