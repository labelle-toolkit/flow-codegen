//! Shared test fixtures/helpers for the `flow_codegen` test suite.
//!
//! Split out of `root_test.zig` (flow-codegen#41) so the per-feature
//! test files can share the common imports and the `expectParsesZig`
//! assertion without duplicating it.

const std = @import("std");
const zspec = @import("zspec");

pub const expect = zspec.expect;
pub const flow_codegen_pkg = @import("flow_codegen");

pub const flow_io = flow_codegen_pkg.flow_io;
pub const flow_codegen = flow_codegen_pkg.codegen;

/// Assert `src` is syntactically valid Zig — generated code must parse.
/// Reachable from every test struct (NOTE: `Ast.parse` checks SYNTAX
/// only — it does not run AstGen, so unused/never-mutated-local lints
/// are NOT caught here; those are verified out-of-band with
/// `zig ast-check`).
pub fn expectParsesZig(allocator: std.mem.Allocator, src: []const u8) !void {
    const z = try allocator.allocSentinel(u8, src.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..src.len], src);
    var ast = try std.zig.Ast.parse(allocator, z, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) std.debug.print("emitted Zig didn't parse:\n{s}\n", .{src});
    try expect.equal(ast.errors.len, @as(usize, 0));
}

/// Assert `src` is valid Zig through AstGen — the SEMANTIC-lowering pass
/// that `zig ast-check` runs, NOT merely `Ast.parse` (flow-codegen#26).
/// This is the strongest in-process "generated code compiles" check: it
/// catches AstGen-level errors that `expectParsesZig` silently lets
/// through — most importantly the unused/never-mutated-local lint that a
/// mis-emitted reporter binding would trip. AstGen does NOT run Sema, so
/// undeclared cross-decl identifiers (the generated `game`/`game_mod`/
/// `Game` surface, which resolve against the host game module) are
/// tolerated — exactly the right scope for checking a generated fragment
/// in isolation.
pub fn expectAstGenOk(allocator: std.mem.Allocator, src: []const u8) !void {
    const z = try allocator.allocSentinel(u8, src.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..src.len], src);

    var ast = try std.zig.Ast.parse(allocator, z, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) {
        std.debug.print("emitted Zig didn't parse:\n{s}\n", .{src});
        try expect.equal(ast.errors.len, @as(usize, 0));
        return;
    }

    var zir = try std.zig.AstGen.generate(allocator, ast);
    defer zir.deinit(allocator);
    if (zir.hasCompileErrors()) {
        std.debug.print("emitted Zig failed AstGen (ast-check):\n{s}\n", .{src});
    }
    try expect.toBeFalse(zir.hasCompileErrors());
}
