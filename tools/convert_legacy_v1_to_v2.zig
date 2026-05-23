//! Standalone driver for the RFC-FLOW-VOCABULARY §3 v1 → v2 converter
//! (flow-codegen#15 item 4).
//!
//! Reads a `.flow.jsonc` file, rewrites a legacy `event: { type: OnEvent,
//! name: ... }` header into an in-graph `Event` node form, and writes
//! the rewrite back to the same path. Idempotent — a file already on
//! the new form (carries an Event node) is canonicalized through the
//! renderer (byte-identical on a second run) and reported.
//!
//! Lifecycle events (`OnCreate` / `OnUpdate` / `OnDestroy`) and `OnCall`
//! subgraphs are NOT Event-node-compatible — the engine does not yet
//! expose them as `pub const Events`, so an Event-node rewrite would
//! name a trigger the assembler cannot resolve. The driver reports
//! `NonOnEventLegacyHeader` and leaves the file unchanged.
//!
//! Usage:
//!   zig build convert -- <path/to/foo.flow.jsonc>
const std = @import("std");
const flow_io = @import("flow_codegen").flow_io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // program name

    const path = args.next() orelse {
        try writeStderr(io, "usage: convert_legacy_v1_to_v2 <path/to/foo.flow.jsonc>\n");
        std.process.exit(2);
    };

    var outcome: flow_io.ConvertOutcome = undefined;
    flow_io.convertLegacyFile(io, allocator, path, &outcome) catch |err| switch (err) {
        error.NonOnEventLegacyHeader => {
            try writeStderr(
                io,
                "skipping: legacy header is not OnEvent (lifecycle / OnCall flows aren't Event-node-compatible yet)\n",
            );
            return;
        },
        else => return err,
    };

    switch (outcome) {
        .converted => try writeStderr(io, "converted v1 → v2 (Event node synthesized from header)\n"),
        .already_v2 => try writeStderr(io, "already on v2 form (Event node), canonical re-render\n"),
    }
}

fn writeStderr(io: std.Io, msg: []const u8) !void {
    const stderr = std.Io.File.stderr();
    try stderr.writeStreamingAll(io, msg);
}
