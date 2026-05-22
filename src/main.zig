//! `flow-codegen` CLI entry point.
//!
//! Today the CLI exposes a single subcommand:
//!
//!   flow-codegen convert [--keep] <file.flow.zon> [more.flow.zon ...]
//!       Rewrite each `.flow.zon` file as `.flow.jsonc` (RFC
//!       `RFC-FLOWS-JSONC.md`, Migration section). Per the RFC's
//!       "hard cut" the original `.flow.zon` is deleted after a
//!       successful write; pass `--keep` to leave it in place.
//!
//! This is a build-time / migration tool. The shipped game never
//! runs it — it links the *generated Zig*, not the flow file.

const std = @import("std");
const convert = @import("convert.zig");

const usage =
    \\flow-codegen — flow-graph tooling
    \\
    \\Usage:
    \\  flow-codegen convert [--keep] <file.flow.zon> [<file.flow.zon> ...]
    \\
    \\  convert   Rewrite each .flow.zon file as .flow.jsonc.
    \\            The original .flow.zon is deleted unless --keep is given.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(io, &stderr_buf);
    const err_w = &stderr_file.interface;

    if (args.len < 2) {
        try err_w.writeAll(usage);
        try err_w.flush();
        return 2;
    }

    const subcommand = args[1];
    if (!std.mem.eql(u8, subcommand, "convert")) {
        try err_w.print("flow-codegen: unknown subcommand '{s}'\n\n", .{subcommand});
        try err_w.writeAll(usage);
        try err_w.flush();
        return 2;
    }

    const code = try runConvert(io, gpa, args[2..], err_w);
    try err_w.flush();
    return code;
}

fn runConvert(
    io: std.Io,
    gpa: std.mem.Allocator,
    rest: []const [:0]const u8,
    err_w: *std.Io.Writer,
) !u8 {
    var keep_source = false;
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);

    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--keep")) {
            keep_source = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err_w.print("flow-codegen convert: unknown flag '{s}'\n", .{arg});
            return 2;
        } else {
            try inputs.append(gpa, arg);
        }
    }

    if (inputs.items.len == 0) {
        try err_w.writeAll("flow-codegen convert: no input files\n\n");
        try err_w.writeAll(usage);
        return 2;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const out_w = &stdout_file.interface;

    var failed = false;
    for (inputs.items) |path| {
        const out_path = convert.convertFile(io, gpa, path, !keep_source) catch |err| {
            try err_w.print("flow-codegen convert: {s}: {s}\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        defer gpa.free(out_path);
        try out_w.print("{s} -> {s}\n", .{ path, out_path });
    }
    try out_w.flush();

    return if (failed) 1 else 0;
}
