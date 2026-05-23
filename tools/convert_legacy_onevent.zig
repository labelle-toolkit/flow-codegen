//! Standalone driver for `flow_io.legacy_onevent_to_name` —
//! Migration "Flow side" (RFC-PLUGIN-EVENTS §7).
//!
//! Reads a `.flow.jsonc` file, converts its legacy `OnEvent` event
//! (`module` + `callback`) to the new `name`-resolved form, and writes
//! the rewrite back to the same path. Idempotent — a file already on
//! the new form is reported and left alone.
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
        try writeStderr(io, "usage: convert_legacy_onevent <path>\n");
        std.process.exit(2);
    };

    const cwd = std.Io.Dir.cwd();
    const raw = try cwd.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);

    var loaded = try flow_io.parseFlow(allocator, raw);
    defer loaded.deinit();

    var converted = flow_io.legacy_onevent_to_name(allocator, loaded) catch |err| switch (err) {
        error.OnEventAlreadyNew => {
            try writeStderr(io, "already in new form, no rewrite needed\n");
            return;
        },
        else => return err,
    };
    defer converted.deinit();

    const out = try flow_io.renderFlowJsonc(allocator, converted);
    defer allocator.free(out);

    try cwd.writeFile(io, .{ .sub_path = path, .data = out });
}

fn writeStderr(io: std.Io, msg: []const u8) !void {
    const stderr = std.Io.File.stderr();
    try stderr.writeStreamingAll(io, msg);
}
