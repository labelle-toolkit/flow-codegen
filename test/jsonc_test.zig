//! Split out of `root_test.zig` (flow-codegen#41).

const std = @import("std");
const helpers = @import("helpers.zig");
const expect = helpers.expect;
const flow_codegen_pkg = helpers.flow_codegen_pkg;

pub const JsoncTests = struct {
    const jsonc = flow_codegen_pkg.jsonc;

    test "strips line comments and trailing commas, ignores string content" {
        const a = std.testing.allocator;
        const out = try jsonc.strip(a, "{ \"u\": \"a//b\", \"n\": 1, } // end\n");
        defer a.free(out);
        // The `//` inside the string survives; the trailing `,` and
        // the line comment become spaces.
        try expect.toBeTrue(std.mem.indexOf(u8, out, "\"a//b\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "// end") == null);
    }
};
