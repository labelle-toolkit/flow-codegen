//! Cycle detection over `Subflow` references (RFC §4). flow-codegen and
//! the GUI run the same walk and emit the same human-readable chain
//! diagnostic.

const std = @import("std");
const flow_io = @import("../flow_io.zig");
const errors = @import("errors.zig");
const registries = @import("registries.zig");

const CodegenError = errors.CodegenError;
const FlowRegistry = registries.FlowRegistry;

/// Walk the `Subflow` reference graph rooted at `start` and reject any
/// cycle. On a cycle, `chain_out` is set to a human-readable chain
/// (`A -> B -> A`) allocated on `allocator` — the caller owns it and
/// frees it; on success `chain_out` is left `null`.
///
/// This is the RFC §4 check. flow-codegen and the GUI run the same
/// walk and emit the same chain diagnostic.
pub fn detectReferenceCycle(
    allocator: std.mem.Allocator,
    registry: *const FlowRegistry,
    start: []const u8,
    chain_out: *?[]const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    chain_out.* = null;
    const flow = registry.get(start) orelse return; // unresolved: caught at emit time
    try detectReferenceCycleFlow(allocator, registry, flow, start, chain_out);
}

/// Like `detectReferenceCycle`, but rooted at a concrete `Flow` value
/// rather than a registry name. This is the form `renderFlowFile` uses
/// for the build entry point — the entry flow may be unnamed or absent
/// from `registry`, and its `Subflow` cycles must still be rejected
/// (RFC §4 — "caught regardless of which flow is the build entry
/// point"). `root_name` only labels the root in the reported chain.
pub fn detectReferenceCycleFlow(
    allocator: std.mem.Allocator,
    registry: *const FlowRegistry,
    root: flow_io.Flow,
    root_name: []const u8,
    chain_out: *?[]const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    chain_out.* = null;
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    // Walk the root's own Subflow edges. The root is pushed under
    // `root_name` so a self/transitive reference back to it is caught
    // even when the root is not registered under that name.
    const label = if (root_name.len != 0) root_name else root.name;
    try stack.append(allocator, label);
    for (root.nodes) |n| {
        if (n.kind == .Subflow) {
            try walkRefs(allocator, registry, n.kind.Subflow.flow, &stack, &visited, chain_out);
        }
    }
    _ = stack.pop();
}

fn walkRefs(
    allocator: std.mem.Allocator,
    registry: *const FlowRegistry,
    name: []const u8,
    stack: *std.ArrayList([]const u8),
    visited: *std.StringHashMap(void),
    chain_out: *?[]const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    // On-stack name → cycle. Report the full chain (RFC §4).
    for (stack.items) |s| {
        if (std.mem.eql(u8, s, name)) {
            chain_out.* = try formatChain(allocator, stack.items, name);
            return error.FlowReferenceCycle;
        }
    }
    // Fully explored already — skip (a DAG diamond is not a cycle).
    if (visited.contains(name)) return;

    // A `Subflow` naming a flow absent from the registry is rejected
    // here, during the cycle walk, rather than deferred to
    // `collectSubgraphs` — the specific `UnknownFlowRef` is a clearer
    // diagnostic than a later, vaguer failure, and a cyclic graph
    // whose closure includes a missing name is still caught.
    const flow = registry.get(name) orelse return error.UnknownFlowRef;
    try stack.append(allocator, name);
    for (flow.nodes) |n| {
        if (n.kind == .Subflow) {
            try walkRefs(allocator, registry, n.kind.Subflow.flow, stack, visited, chain_out);
        }
    }
    _ = stack.pop();
    try visited.put(name, {});
}

fn formatChain(
    allocator: std.mem.Allocator,
    stack: []const []const u8,
    closing: []const u8,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    // Start the chain at the first occurrence of `closing`.
    var begin: usize = 0;
    for (stack, 0..) |s, i| {
        if (std.mem.eql(u8, s, closing)) {
            begin = i;
            break;
        }
    }
    for (stack[begin..]) |s| {
        try w.writeAll(s);
        try w.writeAll(" -> ");
    }
    try w.writeAll(closing);
    return aw.toOwnedSlice();
}
