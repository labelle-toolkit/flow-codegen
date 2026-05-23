//! Standalone driver for the second-pass Call → CustomNode converter
//! (flow-codegen#18, RFC-FLOW-VOCABULARY *Migration* section).
//!
//! Reads a `.flow.jsonc` file, rewrites every raw `Call { callee: ... }`
//! node whose callee resolves uniquely against the project's flow
//! catalog into a `CustomNode { name: "<qualified>" }`, and saves the
//! result back to the same path. Idempotent on flows where no
//! Call resolves (the renderer's canonical re-format is byte-stable).
//!
//! ## Usage
//!
//!   zig build convert-calls -- <flow.flow.jsonc> [--catalog <path>] [--dry-run]
//!
//! - `--catalog <path>` — path to the catalog sidecar JSON. Defaults
//!   to `<project-root>/.labelle/flow_catalog.json`, where
//!   `<project-root>` is discovered by walking up from the flow file
//!   to the nearest ancestor that contains a `.labelle/` directory.
//! - `--dry-run` — print the would-be output to stdout instead of
//!   writing it back to disk. Stderr still receives the per-node
//!   diagnostics (`// TODO: ambiguous match ...`).
//!
//! Exit codes:
//!   - 0 — success (rewritten, dry-run completed, or no-op).
//!   - 2 — usage error (missing argument, malformed catalog).
//!   - other — propagated from the filesystem / parser.

const std = @import("std");
const flow_codegen = @import("flow_codegen");
const flow_io = flow_codegen.flow_io;
const call_to_customnode = flow_codegen.call_to_customnode;

const usage =
    \\usage: convert-calls <flow.flow.jsonc> [--catalog <path>] [--dry-run]
    \\
    \\  --catalog <path>  Override the catalog sidecar path. Defaults to
    \\                    <project-root>/.labelle/flow_catalog.json.
    \\  --dry-run         Print the would-be output to stdout instead of
    \\                    writing it back to disk.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // program name

    var flow_path: ?[]const u8 = null;
    var catalog_override: ?[]const u8 = null;
    var dry_run = false;

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--catalog")) {
            catalog_override = args.next() orelse {
                try writeStderr(io, "convert-calls: --catalog requires a path argument\n");
                std.process.exit(2);
            };
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try writeStderr(io, usage);
            return;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            try writeStderrFmt(io, allocator, "convert-calls: unknown flag '{s}'\n\n", .{a});
            try writeStderr(io, usage);
            std.process.exit(2);
        }
        if (flow_path != null) {
            try writeStderr(io, "convert-calls: more than one flow path supplied\n");
            std.process.exit(2);
        }
        flow_path = a;
    }

    const path = flow_path orelse {
        try writeStderr(io, usage);
        std.process.exit(2);
    };

    // ── Resolve catalog path ───────────────────────────────────────
    const catalog_path = if (catalog_override) |co|
        try allocator.dupe(u8, co)
    else
        try defaultCatalogPath(allocator, io, path);
    defer allocator.free(catalog_path);

    // ── Load catalog ──────────────────────────────────────────────
    const catalog_raw = std.Io.Dir.cwd().readFileAlloc(
        io,
        catalog_path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| {
        try writeStderrFmt(
            io,
            allocator,
            "convert-calls: failed to read catalog '{s}': {s}\n",
            .{ catalog_path, @errorName(err) },
        );
        std.process.exit(2);
    };
    defer allocator.free(catalog_raw);

    var catalog = call_to_customnode.parseCatalog(allocator, catalog_raw) catch |err| {
        try writeStderrFmt(
            io,
            allocator,
            "convert-calls: malformed catalog '{s}': {s}\n",
            .{ catalog_path, @errorName(err) },
        );
        std.process.exit(2);
    };
    defer catalog.deinit();

    // ── Load + convert flow ────────────────────────────────────────
    var loaded = try flow_io.loadFromFile(io, allocator, path);
    defer loaded.deinit();

    var result = try call_to_customnode.convertFlow(allocator, loaded.flow, catalog);
    defer result.deinit();

    // ── Diagnostics — stderr per-node summary ─────────────────────
    var rewritten_count: usize = 0;
    var ambiguous_count: usize = 0;
    var skipped_no_match: usize = 0;
    var skipped_escape: usize = 0;
    for (result.outcomes) |o| {
        switch (o.status) {
            .rewritten => |q| {
                rewritten_count += 1;
                try writeStderrFmt(
                    io,
                    allocator,
                    "  rewrite: node {d} '{s}' -> CustomNode '{s}'\n",
                    .{ o.node_id, o.callee, q },
                );
            },
            .ambiguous => |qs| {
                ambiguous_count += 1;
                try writeStderrFmt(
                    io,
                    allocator,
                    "  // TODO: ambiguous match for '{s}' (node {d}): ",
                    .{ o.callee, o.node_id },
                );
                for (qs, 0..) |q, i| {
                    if (i > 0) try writeStderr(io, ", ");
                    try writeStderr(io, q);
                }
                try writeStderr(io, "\n");
            },
            .skipped_no_match => {
                skipped_no_match += 1;
            },
            .skipped_escape_hatch => {
                skipped_escape += 1;
            },
        }
    }

    try writeStderrFmt(
        io,
        allocator,
        "convert-calls: {d} rewritten, {d} ambiguous, {d} no-match, {d} escape-hatch\n",
        .{ rewritten_count, ambiguous_count, skipped_no_match, skipped_escape },
    );

    // ── Write back / dry-run ──────────────────────────────────────
    const rendered = try flow_io.renderFlowJsonc(allocator, result.loaded);
    defer allocator.free(rendered);

    if (dry_run) {
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(io, rendered);
        return;
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered });
}

/// Walk up from the flow's directory to the nearest ancestor that
/// contains a `.labelle/` directory, and return
/// `<ancestor>/.labelle/flow_catalog.json`. Falls back to
/// `./.labelle/flow_catalog.json` (cwd-relative) when no ancestor
/// carries a `.labelle/` — the catalog read will then surface a
/// clean filesystem error.
fn defaultCatalogPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    flow_path: []const u8,
) ![]u8 {
    // Resolve the flow path's directory. Use the dirname of the
    // realpath so we walk up from the file's actual location rather
    // than the cwd-relative spelling — `realPathFile` matches the
    // Zig 0.16 `std.Io.Dir` surface.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const real_len = cwd.realPathFile(io, flow_path, &path_buf) catch {
        // Fall back to the literal dirname when realPathFile fails
        // (file doesn't exist yet, missing permission, …) — the
        // caller will see the eventual catalog-read error with the
        // correct path.
        const dn = std.fs.path.dirname(flow_path) orelse ".";
        return std.fs.path.join(allocator, &.{ dn, ".labelle", "flow_catalog.json" });
    };
    const real = path_buf[0..real_len];

    var dir = std.fs.path.dirname(real) orelse ".";
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir, ".labelle" });
        defer allocator.free(candidate);

        if (cwd.access(io, candidate, .{})) |_| {
            return std.fs.path.join(allocator, &.{ dir, ".labelle", "flow_catalog.json" });
        } else |_| {}

        // Walk up one level. Stop at the filesystem root.
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
    }

    // No `.labelle/` ancestor — return a cwd-relative default. The
    // catalog read will surface a `FileNotFound` with this path,
    // which is a clearer signal than silently no-op'ing.
    return std.fs.path.join(allocator, &.{ ".labelle", "flow_catalog.json" });
}

fn writeStderr(io: std.Io, msg: []const u8) !void {
    const stderr = std.Io.File.stderr();
    try stderr.writeStreamingAll(io, msg);
}

fn writeStderrFmt(
    io: std.Io,
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try writeStderr(io, msg);
}
