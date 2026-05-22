//! Forward codegen for the Flow editor (`.flow.jsonc` → Zig source).
//!
//! `renderFlowZig` turns a parsed `flow_io.Flow` into a complete `.zig`
//! file: imports + a `pub fn` for the flow's `Event`, plus — when the
//! flow (transitively) references subgraphs — one `fn` per referenced
//! flow. The assembler calls this at `zig build generate` time.
//!
//! ## Pipeline
//!
//! 1. Index nodes by id and build the consumer→producer pin map from
//!    the edge list.
//! 2. Topologically sort the nodes (Kahn's algorithm) so a node's
//!    inputs are always defined before the node itself emits.
//! 3. For each node, in topo order, emit the node's Zig template with
//!    input pins resolved to the producing node's variable, a `param`
//!    argument, a `binding` literal, or a per-kind default.
//!
//! ## Subgraph composition (RFC-FLOWS-JSONC.md §3, §6)
//!
//! A `Subflow` node references another flow by name. `renderFlowFile`
//! resolves those references through a `FlowRegistry`, runs a
//! reference-cycle check (RFC §4 — reported with the full chain), and
//! emits **call-style** code (RFC §6):
//!
//! - each referenced flow becomes its own `fn`, named by a
//!   deterministic symbol derived from its effective name;
//! - each declared `param` is a function parameter; a `Param` node
//!   reads it;
//! - `Output` nodes become the function's return — a single value,
//!   a struct of named results when there is more than one, or `void`
//!   when the flow declares none;
//! - a `Subflow` node lowers to a *call* of that function, every
//!   argument supplied explicitly (wired pin → `binding` literal →
//!   declared `default`).
//!
//! ## Preview pulse (folded from former issue #90)
//!
//! Each emitted node body is preceded by an `emitNodeEntered` pulse
//! guarded by `if (game.preview)` so production builds pay nothing.
//!
//! ## Pin variables
//!
//! Pin values live in `n<node_id>_<pin>` locals. `GetComponent`
//! produces a single `n<id>_value` binding and downstream consumers
//! may ask for any pin name (treated as a field access).

const std = @import("std");
const flow_io = @import("flow_io.zig");

const components_import_path_fmt = "../../components/{s}.zig";

/// Caller-facing configuration for a single-flow render.
pub const Options = struct {
    flow_name: []const u8,
};

/// Codegen-side failure modes.
pub const CodegenError = error{
    /// Topo sort couldn't make progress — the graph contains a cycle.
    CycleDetected,
    /// A required input pin has no incoming edge and no default.
    DanglingPin,
    /// An edge names a `to.pin` that isn't an input pin on the
    /// consumer node.
    UnknownPin,
    /// A `GetComponent` / `SetField` references a namespaced type.
    NamespacedComponentType,
    /// Future-proofing for additional `NodeKind` variants.
    UnsupportedNodeKind,
    /// A `Subflow` node references a flow name not in the registry.
    UnknownFlowRef,
    /// A `Subflow` reference graph contains a cycle (RFC §4).
    FlowReferenceCycle,
    /// A `Subflow` `binding` names a param the referenced flow does
    /// not declare (RFC §3 — `error.UnknownFlowParam`).
    UnknownFlowParam,
    /// A referenced flow's `param` pin is neither wired, bound, nor
    /// has a declared `default` (RFC §3 precedence rule 3).
    MissingFlowArg,
    /// Two distinct effective flow names sanitize to the same Zig
    /// identifier (e.g. `a-b` and `a_b` both → `a_b`). RFC §5 keeps
    /// effective names unique, but `sanitizeSymbol` is lossy, so a
    /// collision would emit two `fn` definitions with the same name.
    SymbolCollision,
    /// A subgraph (an `OnCall` flow lowered to a `fn` — RFC §6) uses a
    /// `GetComponent` / `SetField` node, which needs an `entity` in
    /// scope. Subgraphs receive only declared `params` (RFC §3), so no
    /// `entity` is available; entity-scoped nodes in a subgraph are
    /// rejected rather than emitted against an undefined binding.
    EntityUnavailableInSubgraph,
    /// A flow's effective name sanitizes to the bare `_` (an empty or
    /// all-non-identifier name). Zig reserves `_` as the discard
    /// identifier and rejects it as a `fn` name, so such a subgraph
    /// would emit `fn _(...)` and fail to compile.
    InvalidFlowName,
    /// A flow declares a `param` whose sanitized name collides with
    /// another param or with a fixed `fn` parameter (`game`, or the
    /// lifecycle `dt` / `entity` arg) — the emitted signature would
    /// have duplicate parameter identifiers.
    ParamNameCollision,
};

// =====================================================================
// Flow registry — name-keyed map for Subflow resolution (RFC §5)
// =====================================================================

/// A flat, name-keyed registry of flows. `Subflow` references resolve
/// against it (RFC §5 — flows live in their own namespace, distinct
/// from prefabs/scenes). Borrows the `Flow` values from the caller.
pub const FlowRegistry = struct {
    map: std.StringHashMap(flow_io.Flow),

    pub const RegistryError = error{
        /// Two flow files share an effective name (RFC §5 —
        /// `error.DuplicateFlowName`).
        DuplicateFlowName,
    };

    pub fn init(allocator: std.mem.Allocator) FlowRegistry {
        return .{ .map = std.StringHashMap(flow_io.Flow).init(allocator) };
    }

    pub fn deinit(self: *FlowRegistry) void {
        self.map.deinit();
    }

    /// Register `flow` under its effective name. A duplicate effective
    /// name is `error.DuplicateFlowName` (RFC §5).
    pub fn add(self: *FlowRegistry, flow: flow_io.Flow) !void {
        const gop = try self.map.getOrPut(flow.name);
        if (gop.found_existing) return RegistryError.DuplicateFlowName;
        gop.value_ptr.* = flow;
    }

    pub fn get(self: *const FlowRegistry, name: []const u8) ?flow_io.Flow {
        return self.map.get(name);
    }
};

// =====================================================================
// Cycle detection over Subflow references (RFC §4)
// =====================================================================

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

    const flow = registry.get(name) orelse return; // unresolved: caught at emit time
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

// =====================================================================
// Public entry points
// =====================================================================

/// Render a single flow as a Zig source file. When the flow references
/// subgraphs, prefer `renderFlowFile` — this entry point emits no
/// subgraph functions and treats a `Subflow` node as `UnknownFlowRef`
/// unless an empty registry happens to suffice.
pub fn renderFlowZig(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    options: Options,
) (CodegenError || FlowRegistry.RegistryError || std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var registry = FlowRegistry.init(allocator);
    defer registry.deinit();
    return renderFlowFile(allocator, flow, &registry, options);
}

/// Render `entry` as a Zig file: its event `pub fn`, plus a `fn` for
/// every flow transitively reachable through `Subflow` nodes (RFC §6).
/// `registry` resolves those references. Caller owns the returned bytes.
pub fn renderFlowFile(
    allocator: std.mem.Allocator,
    entry: flow_io.Flow,
    registry: *const FlowRegistry,
    options: Options,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    // RFC §4: cycle check runs before any emission, rooted at the
    // entry flow itself — so cycles are rejected even when the entry
    // is unnamed or not registered ("caught regardless of which flow
    // is the build entry point").
    {
        var chain: ?[]const u8 = null;
        detectReferenceCycleFlow(allocator, registry, entry, entry.name, &chain) catch |err| {
            if (chain) |c| allocator.free(c);
            return err;
        };
        if (chain) |c| allocator.free(c);
    }

    // Collect the transitive set of referenced subgraphs.
    var subgraphs: std.ArrayList(flow_io.Flow) = .empty;
    defer subgraphs.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    try collectSubgraphs(allocator, registry, entry, &subgraphs, &seen);

    // Distinct effective names that sanitize to the same identifier
    // would emit colliding `fn` definitions — reject up front (RFC §6
    // assumes symbols don't collide; `sanitizeSymbol` is lossy). The
    // entry `pub fn` name (`onUpdate`/`onCreate`/`onDestroy`/`onCall`)
    // is checked too: a subgraph whose name sanitizes to one of those
    // would emit a `fn` colliding with the file's `pub fn`.
    try assertNoSymbolCollision(allocator, entryFunctionName(entry.event), subgraphs.items);

    // Each flow's declared `params` must not collide (after
    // sanitization) with each other or the fixed `fn` params —
    // checked for the entry flow and every referenced subgraph.
    try assertNoParamCollision(allocator, entry);
    for (subgraphs.items) |sg| try assertNoParamCollision(allocator, sg);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    // File header.
    try w.writeAll("//! Generated by labelle-gui codegen — DO NOT EDIT.\n");
    try w.writeAll("//! Source: ");
    try w.print("{f}", .{std.zig.fmtString(options.flow_name)});
    try w.writeAll(".flow.jsonc\n\n");
    try w.writeAll("const std = @import(\"std\");\n");
    try w.writeAll("const game_mod = @import(\"game\");\n");
    try w.writeAll("const Game = game_mod.Game;\n");
    try w.writeAll("const EntityId = game_mod.EntityId;\n");

    // Component imports — union across the entry flow and all
    // referenced subgraphs, de-duplicated, sorted (issue #101).
    const component_types = try collectComponentTypesAll(allocator, entry, subgraphs.items);
    defer allocator.free(component_types);
    for (component_types) |type_name| {
        try w.print(
            "const {s} = @import(\"" ++ components_import_path_fmt ++ "\").{s};\n",
            .{ type_name, type_name, type_name },
        );
    }
    try w.writeAll("\n");

    // Entry flow → its event `pub fn`.
    try renderEntryFunction(allocator, w, entry, registry, options.flow_name);

    // Subgraphs → one `fn` each (RFC §6).
    for (subgraphs.items) |sg| {
        try w.writeAll("\n");
        try renderSubgraphFunction(allocator, w, sg, registry);
    }

    return aw.toOwnedSlice();
}

/// Depth-first collect of every flow reachable through `Subflow`
/// nodes, excluding `entry` itself. Order is deterministic
/// (discovery order). Assumes the cycle check already passed.
fn collectSubgraphs(
    allocator: std.mem.Allocator,
    registry: *const FlowRegistry,
    flow: flow_io.Flow,
    out: *std.ArrayList(flow_io.Flow),
    seen: *std.StringHashMap(void),
) (CodegenError || std.mem.Allocator.Error)!void {
    for (flow.nodes) |n| {
        if (n.kind != .Subflow) continue;
        const ref_name = n.kind.Subflow.flow;
        if (seen.contains(ref_name)) continue;
        const ref = registry.get(ref_name) orelse return error.UnknownFlowRef;
        try seen.put(ref_name, {});
        try out.append(allocator, ref);
        try collectSubgraphs(allocator, registry, ref, out, seen);
    }
}

// =====================================================================
// Function emission
// =====================================================================

fn renderEntryFunction(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    flow: flow_io.Flow,
    registry: *const FlowRegistry,
    flow_name: []const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var ctx = try GraphContext.init(allocator, flow, registry);
    defer ctx.deinit();

    // An `OnCall` entry is a subgraph in its own right (RFC §3/§6) —
    // it has no `entity` in scope, only declared `params`. Reject
    // entity-scoped nodes (`GetComponent` / `SetField`) rather than
    // emit reads of an undefined `entity`, exactly as a referenced
    // subgraph does in `renderSubgraphFunction`. The lifecycle events
    // do bind `entity` (see below), so this applies to `OnCall` only.
    if (flow.event == .OnCall and anyNodeNeedsEntity(flow.nodes))
        return error.EntityUnavailableInSubgraph;

    // An `OnCall` flow used as the file entry point is a subgraph in
    // its own right (RFC §3/§6): its `Output` nodes form the return
    // value, exactly as for a referenced subgraph. The lifecycle
    // events (`OnUpdate`/`OnCreate`/`OnDestroy`) are fixed-signature
    // engine callbacks and always return `void`; any `Output` nodes
    // there carry no return (kept as-is).
    const entry_fn = entryFunctionName(flow.event);
    const outputs = if (flow.event == .OnCall)
        try collectOutputs(allocator, flow)
    else
        try allocator.alloc(*const flow_io.Node, 0);
    defer allocator.free(outputs);

    // Distinct Output names sanitizing to one identifier would emit a
    // result struct with duplicate fields — reject up front.
    try assertNoOutputCollision(allocator, outputs);

    // Multi-output entry returns a named result struct (RFC §6).
    if (outputs.len > 1) {
        try w.print("const {s}_Result = struct {{\n", .{entry_fn});
        for (outputs) |o| {
            const field = try sanitizeSymbol(allocator, o.kind.Output.name);
            defer allocator.free(field);
            try w.print("    {s}: {s},\n", .{ field, o.kind.Output.type });
        }
        try w.writeAll("};\n");
    }

    try writeFnHeader(allocator, w, flow, outputs);

    // Entity binding for OnCreate/OnDestroy/OnUpdate templates.
    if (anyNodeNeedsEntity(flow.nodes)) {
        switch (flow.event) {
            .OnUpdate => {
                try w.writeAll("    // TODO(#42): real entity selection for OnUpdate flows.\n");
                try w.writeAll("    const entity: EntityId = undefined;\n");
            },
            .OnCreate => |b| {
                if (!std.mem.eql(u8, b.arg_entity, "entity")) {
                    try w.print("    const entity = {s};\n", .{b.arg_entity});
                }
            },
            .OnDestroy => |b| {
                if (!std.mem.eql(u8, b.arg_entity, "entity")) {
                    try w.print("    const entity = {s};\n", .{b.arg_entity});
                }
            },
            .OnCall => {},
        }
    }

    try emitBody(allocator, w, &ctx, flow_name);

    // Return statement for an OnCall entry with declared Outputs.
    if (outputs.len == 1) {
        const expr = (try ctx.resolveInput(allocator, outputs[0], "value")) orelse return error.DanglingPin;
        defer allocator.free(expr);
        try w.print("    return {s};\n", .{expr});
    } else if (outputs.len > 1) {
        try w.writeAll("    return .{\n");
        for (outputs) |o| {
            const expr = (try ctx.resolveInput(allocator, o, "value")) orelse return error.DanglingPin;
            defer allocator.free(expr);
            const field = try sanitizeSymbol(allocator, o.kind.Output.name);
            defer allocator.free(field);
            try w.print("        .{s} = {s},\n", .{ field, expr });
        }
        try w.writeAll("    };\n");
    }
    try w.writeAll("}\n");
}

/// Emit one subgraph as a `fn` (RFC §6): params → fn args, `Output`
/// nodes → return value, body in topo order.
fn renderSubgraphFunction(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    flow: flow_io.Flow,
    registry: *const FlowRegistry,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var ctx = try GraphContext.init(allocator, flow, registry);
    defer ctx.deinit();

    // A subgraph has no `entity` in scope — only declared params. An
    // entity-scoped node (GetComponent / SetField) cannot be emitted
    // against an undefined binding (RFC §3 — params are the only
    // inputs); reject it explicitly.
    if (anyNodeNeedsEntity(flow.nodes)) return error.EntityUnavailableInSubgraph;

    const symbol = try sanitizeSymbol(allocator, flow.name);
    defer allocator.free(symbol);

    // An empty (or all-non-identifier) flow name sanitizes to the bare
    // `_`, which Zig reserves as the discard identifier and rejects as
    // a `fn` name. Such a subgraph passes registry and collision
    // checks yet emits uncompilable `fn _(...)` — reject it up front.
    if (std.mem.eql(u8, symbol, "_")) return error.InvalidFlowName;

    const outputs = try collectOutputs(allocator, flow);
    defer allocator.free(outputs);

    // Distinct Output names that sanitize to one identifier would emit
    // a result struct with duplicate fields — reject up front.
    try assertNoOutputCollision(allocator, outputs);

    // Multi-output subgraphs return a named result struct (RFC §6).
    // Declare it just above the function so the type is in scope.
    // Output names are sanitized to valid Zig identifiers so a name
    // like `hit-points` or `2nd` still compiles.
    if (outputs.len > 1) {
        try w.print("const {s}_Result = struct {{\n", .{symbol});
        for (outputs) |o| {
            const field = try sanitizeSymbol(allocator, o.kind.Output.name);
            defer allocator.free(field);
            try w.print("    {s}: {s},\n", .{ field, o.kind.Output.type });
        }
        try w.writeAll("};\n");
    }

    // Signature: `fn <symbol>(game: *Game, <param>: <type>, …) <ret> {`
    try w.print("fn {s}(game: *Game", .{symbol});
    try writeParamArgs(allocator, w, flow.params);
    try w.writeAll(") ");
    try writeReturnType(w, symbol, outputs);
    try w.writeAll(" {\n");

    try emitBody(allocator, w, &ctx, flow.name);

    // Return statement (RFC §6).
    if (outputs.len == 1) {
        const expr = (try ctx.resolveInput(allocator, outputs[0], "value")) orelse return error.DanglingPin;
        defer allocator.free(expr);
        try w.print("    return {s};\n", .{expr});
    } else if (outputs.len > 1) {
        try w.writeAll("    return .{\n");
        for (outputs) |o| {
            const expr = (try ctx.resolveInput(allocator, o, "value")) orelse return error.DanglingPin;
            defer allocator.free(expr);
            const field = try sanitizeSymbol(allocator, o.kind.Output.name);
            defer allocator.free(field);
            try w.print("        .{s} = {s},\n", .{ field, expr });
        }
        try w.writeAll("    };\n");
    }
    try w.writeAll("}\n");
}

/// Subgraph return type (RFC §6): `void` for zero `Output` nodes, the
/// single output's declared `type` for one, and the generated
/// `<symbol>_Result` struct for many. `Output.type` carries the Zig
/// type (defaulting to `f32` on disk); precise inference through the
/// pin type-system is deferred (RFC open question 2 / #44).
fn writeReturnType(
    w: *std.Io.Writer,
    symbol: []const u8,
    outputs: []const *const flow_io.Node,
) !void {
    if (outputs.len == 0) {
        try w.writeAll("void");
    } else if (outputs.len == 1) {
        try w.writeAll(outputs[0].kind.Output.type);
    } else {
        try w.print("{s}_Result", .{symbol});
    }
}

/// Emit the topo-sorted node bodies for a flow into `w`.
fn emitBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (ctx.order) |id| {
        const node = ctx.index.byId(id) orelse unreachable;
        try writePreviewPulse(w, flow_name, node.id);
        try writeNodeBody(w, node, ctx, scratch.allocator());
        _ = scratch.reset(.retain_capacity);
    }
}

// =====================================================================
// Graph context — index + topo order, shared by entry & subgraph paths
// =====================================================================

const GraphContext = struct {
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    registry: *const FlowRegistry,
    index: Index,
    order: []u32,

    fn init(
        allocator: std.mem.Allocator,
        flow: flow_io.Flow,
        registry: *const FlowRegistry,
    ) (CodegenError || std.mem.Allocator.Error)!GraphContext {
        var index = try buildIndex(allocator, flow);
        errdefer index.deinit();

        const order = try topoSort(allocator, flow);
        errdefer allocator.free(order);

        // Validate every edge's `to.pin` against the consumer's input
        // pin signature.
        for (flow.edges) |e| {
            const consumer = index.byId(e.to.node) orelse unreachable;
            if (!isInputPin(consumer.kind, e.to.pin)) return error.UnknownPin;
        }

        return .{
            .allocator = allocator,
            .flow = flow,
            .registry = registry,
            .index = index,
            .order = order,
        };
    }

    fn deinit(self: *GraphContext) void {
        self.index.deinit();
        self.allocator.free(self.order);
    }

    /// Resolve `pin` on `consumer` to a Zig expression, allocated on
    /// `alloc`. `null` when the pin is disconnected (caller decides
    /// default vs error). Per-node emission passes a scratch arena so
    /// the returned text is reclaimed after the node; the subgraph
    /// `return` path passes the long-lived allocator.
    fn resolveInput(
        self: *GraphContext,
        alloc: std.mem.Allocator,
        consumer: *const flow_io.Node,
        pin: []const u8,
    ) (CodegenError || std.mem.Allocator.Error)!?[]const u8 {
        const edge = self.index.producerOf(consumer.id, pin) orelse return null;
        const producer = self.index.byId(edge.from.node) orelse return error.UnknownPin;

        // A Subflow's output pins are the referenced flow's `Output`
        // node names (RFC §3) — resolved against the registry so the
        // scalar-vs-struct shape (RFC §6) is honoured.
        if (producer.kind == .Subflow) {
            return try self.resolveSubflowOutput(alloc, producer, edge.from.pin);
        }

        const primary = primaryOutputPin(producer.kind);
        if (primary.len != 0 and std.mem.eql(u8, edge.from.pin, primary)) {
            return try std.fmt.allocPrint(
                alloc,
                "n{d}_{s}",
                .{ producer.id, primary },
            );
        }
        switch (producer.kind) {
            // GetComponent: non-`value` pins are field accesses.
            .GetComponent => return try std.fmt.allocPrint(
                alloc,
                "n{d}_value.{s}",
                .{ producer.id, edge.from.pin },
            ),
            else => return error.UnknownPin,
        }
    }

    /// Resolve an output `pin` read from a `Subflow` producer. The pin
    /// must name an `Output` node of the referenced flow (RFC §3). A
    /// single-output subgraph returns a scalar — the pin resolves to
    /// `n{id}_result`; a multi-output one returns a struct — the pin
    /// resolves to `n{id}_result.<sanitized field>` (RFC §6).
    fn resolveSubflowOutput(
        self: *GraphContext,
        alloc: std.mem.Allocator,
        producer: *const flow_io.Node,
        pin: []const u8,
    ) (CodegenError || std.mem.Allocator.Error)![]const u8 {
        const ref = self.registry.get(producer.kind.Subflow.flow) orelse
            return error.UnknownFlowRef;

        var output_count: usize = 0;
        var matched = false;
        for (ref.nodes) |n| {
            if (n.kind != .Output) continue;
            output_count += 1;
            if (std.mem.eql(u8, n.kind.Output.name, pin)) matched = true;
        }
        // The pin must name a real Output of the referenced flow.
        if (!matched) return error.UnknownPin;

        if (output_count == 1) {
            return try std.fmt.allocPrint(alloc, "n{d}_result", .{producer.id});
        }
        // Multi-output: field name is the sanitized Output name, to
        // match the generated `<symbol>_Result` struct fields.
        const field = try sanitizeSymbol(alloc, pin);
        defer alloc.free(field);
        return try std.fmt.allocPrint(
            alloc,
            "n{d}_result.{s}",
            .{ producer.id, field },
        );
    }
};

const Index = struct {
    allocator: std.mem.Allocator,
    by_id: std.AutoHashMap(u32, *const flow_io.Node),
    producers: std.HashMap(EdgeKey, *const flow_io.Edge, EdgeKeyContext, std.hash_map.default_max_load_percentage),

    fn deinit(self: *Index) void {
        self.by_id.deinit();
        self.producers.deinit();
    }

    fn byId(self: *const Index, id: u32) ?*const flow_io.Node {
        return self.by_id.get(id);
    }

    fn producerOf(self: *const Index, consumer: u32, pin: []const u8) ?*const flow_io.Edge {
        return self.producers.get(.{ .node = consumer, .pin = pin });
    }
};

const EdgeKey = struct {
    node: u32,
    pin: []const u8,
};

const EdgeKeyContext = struct {
    pub fn hash(_: EdgeKeyContext, k: EdgeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.node));
        h.update(k.pin);
        return h.final();
    }
    pub fn eql(_: EdgeKeyContext, a: EdgeKey, b: EdgeKey) bool {
        return a.node == b.node and std.mem.eql(u8, a.pin, b.pin);
    }
};

fn buildIndex(allocator: std.mem.Allocator, flow: flow_io.Flow) !Index {
    var idx: Index = .{
        .allocator = allocator,
        .by_id = std.AutoHashMap(u32, *const flow_io.Node).init(allocator),
        .producers = std.HashMap(EdgeKey, *const flow_io.Edge, EdgeKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
    };
    errdefer idx.deinit();

    for (flow.nodes) |*n| {
        try idx.by_id.put(n.id, n);
    }
    for (flow.edges) |*e| {
        try idx.producers.put(.{ .node = e.to.node, .pin = e.to.pin }, e);
    }
    return idx;
}

/// Kahn's algorithm — dependencies before dependents, ties by id.
fn topoSort(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
) (CodegenError || std.mem.Allocator.Error)![]u32 {
    var indeg = std.AutoHashMap(u32, usize).init(allocator);
    defer indeg.deinit();
    for (flow.nodes) |n| try indeg.put(n.id, 0);
    for (flow.edges) |e| {
        const entry = indeg.getPtr(e.to.node) orelse return error.CycleDetected;
        entry.* += 1;
    }

    var ready: std.ArrayList(u32) = .empty;
    defer ready.deinit(allocator);
    for (flow.nodes) |n| {
        if (indeg.get(n.id).? == 0) try ready.append(allocator, n.id);
    }
    std.mem.sort(u32, ready.items, {}, std.sort.asc(u32));

    const order = try allocator.alloc(u32, flow.nodes.len);
    errdefer allocator.free(order);
    var emitted: usize = 0;

    while (ready.items.len > 0) {
        const next = ready.orderedRemove(0);
        order[emitted] = next;
        emitted += 1;

        var added: std.ArrayList(u32) = .empty;
        defer added.deinit(allocator);
        for (flow.edges) |e| {
            if (e.from.node != next) continue;
            const d = indeg.getPtr(e.to.node).?;
            if (d.* > 0) {
                d.* -= 1;
                if (d.* == 0) try added.append(allocator, e.to.node);
            }
        }
        std.mem.sort(u32, added.items, {}, std.sort.asc(u32));
        for (added.items) |id| {
            var i: usize = 0;
            while (i < ready.items.len and ready.items[i] < id) : (i += 1) {}
            try ready.insert(allocator, i, id);
        }
    }

    if (emitted != flow.nodes.len) return error.CycleDetected;
    return order;
}

// =====================================================================
// Node body emission
// =====================================================================

/// Emit the `pub fn` header for the file entry point. The flow's
/// top-level `params` are appended as fn parameters — same as a
/// subgraph — so `Param` nodes in the entry flow resolve their reads
/// to in-scope identifiers (RFC §3).
///
/// `outputs` is the entry flow's `Output` nodes (empty for lifecycle
/// events, which always return `void`). When non-empty — an `OnCall`
/// entry — the return type follows the subgraph rule (RFC §6): the
/// single output's `type`, or the `<entry_fn>_Result` struct.
fn writeFnHeader(
    allocator: std.mem.Allocator,
    w: anytype,
    flow: flow_io.Flow,
    outputs: []const *const flow_io.Node,
) !void {
    switch (flow.event) {
        .OnUpdate => |b| try w.print(
            "pub fn onUpdate(game: *Game, {s}: f32",
            .{b.arg_dt},
        ),
        .OnCreate => |b| try w.print(
            "pub fn onCreate(game: *Game, {s}: EntityId",
            .{b.arg_entity},
        ),
        .OnDestroy => |b| try w.print(
            "pub fn onDestroy(game: *Game, {s}: EntityId",
            .{b.arg_entity},
        ),
        // An OnCall flow used as the file entry point still needs a
        // callable surface — emit `pub fn onCall`.
        .OnCall => try w.writeAll("pub fn onCall(game: *Game"),
    }
    try writeParamArgs(allocator, w, flow.params);
    try w.writeAll(") ");
    try writeReturnType(w, entryFunctionName(flow.event), outputs);
    try w.writeAll(" {\n");
}

/// Emit a flow's declared `params` as `fn` arguments — `, <name>:
/// <type>` each. Names are run through `sanitizeSymbol` to a valid
/// Zig identifier (RFC §3); `Param` node reads (see `writeNodeBody`)
/// apply the same sanitization so the emitted identifiers line up.
fn writeParamArgs(
    allocator: std.mem.Allocator,
    w: anytype,
    params: []const flow_io.Param,
) !void {
    for (params) |p| {
        const name = try sanitizeSymbol(allocator, p.name);
        defer allocator.free(name);
        try w.print(", {s}: {s}", .{ name, p.type });
    }
}

fn writePreviewPulse(w: anytype, flow_name: []const u8, node_id: u32) !void {
    try w.writeAll("    if (game.preview) |*_p| {\n");
    try w.print(
        "        _p.emitNodeEntered(\"{f}\", {d}) catch {{}};\n",
        .{ std.zig.fmtString(flow_name), node_id },
    );
    try w.writeAll("    }\n");
}

fn writeNodeBody(
    w: anytype,
    node: *const flow_io.Node,
    ctx: *GraphContext,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    // `scratch` is a per-node arena (reset in `emitBody`) — every
    // expression string allocated here is reclaimed once the node is
    // emitted, so `defer free` is omitted on scratch allocations.
    switch (node.kind) {
        .GetComponent => |b| try w.print(
            "    const n{d}_value = game.getComponent(entity, {s}) orelse return;\n",
            .{ node.id, b.type },
        ),
        .SetField => |b| {
            const dot = std.mem.lastIndexOfScalar(u8, b.target, '.') orelse return error.UnknownPin;
            const type_name = b.target[0..dot];
            const field_name = b.target[dot + 1 ..];
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    game.setField({s}, .{s}, entity, {s});\n",
                .{ type_name, field_name, value_expr },
            );
        },
        .BinOp => |b| {
            const a_expr = (try ctx.resolveInput(scratch, node, "a")) orelse try scratch.dupe(u8, "0");
            const b_expr = (try ctx.resolveInput(scratch, node, "b")) orelse try scratch.dupe(u8, "0");
            const op_text: []const u8 = switch (b.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
            };
            try w.print(
                "    const n{d}_result = {s} {s} {s};\n",
                .{ node.id, a_expr, op_text, b_expr },
            );
        },
        .Literal => |b| try w.print(
            "    const n{d}_value = {s};\n",
            .{ node.id, b.value },
        ),
        .Identifier => |b| try w.print(
            "    const n{d}_value = {s};\n",
            .{ node.id, b.name },
        ),
        // A Param node yields a declared parameter's value (RFC §3).
        // The parameter is in scope as a function argument; sanitize
        // the read to match the signature (see `writeParamArgs`).
        .Param => |b| {
            const name = try sanitizeSymbol(scratch, b.param);
            try w.print("    const n{d}_value = {s};\n", .{ node.id, name });
        },
        // An Output node carries no body — its `value` pin is read by
        // the function's `return` (see renderSubgraphFunction).
        .Output => {},
        .Call => |b| {
            const arity = countCallArgs(ctx.flow, node.id);
            try w.print("    const n{d}_result = {s}(", .{ node.id, b.callee });
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                if (i > 0) try w.writeAll(", ");
                var buf: [16]u8 = undefined;
                const pin = std.fmt.bufPrint(&buf, "arg{d}", .{i}) catch unreachable;
                const expr = (try ctx.resolveInput(scratch, node, pin)) orelse
                    try scratch.dupe(u8, "undefined");
                try w.writeAll(expr);
            }
            try w.writeAll(");\n");
        },
        // A Subflow node lowers to a *call* of the referenced flow's
        // generated function (RFC §6). Each param argument is supplied
        // explicitly: wired pin → binding literal → declared default.
        .Subflow => |b| {
            const ref = ctx.registry.get(b.flow) orelse return error.UnknownFlowRef;

            // Reject bindings naming a param the ref doesn't declare.
            for (b.bindings) |bd| {
                if (!hasParam(ref.params, bd.param)) return error.UnknownFlowParam;
            }

            // Reject edges wired into a pin that names no declared
            // param — a typo on a param pin must surface as an error,
            // not silently fall through to the declared default.
            for (ctx.flow.edges) |e| {
                if (e.to.node != node.id) continue;
                if (!hasParam(ref.params, e.to.pin)) return error.UnknownFlowParam;
            }

            const symbol = try sanitizeSymbol(scratch, ref.name);

            // A void subgraph (zero `Output` nodes) is lowered to a
            // bare call statement; a value-producing one binds the
            // result so downstream pins can read `n<id>_result`.
            const ref_void = !anyOutput(ref.nodes);
            if (ref_void) {
                try w.print("    {s}(game", .{symbol});
            } else {
                try w.print("    const n{d}_result = {s}(game", .{ node.id, symbol });
            }
            for (ref.params) |p| {
                try w.writeAll(", ");
                const arg = try resolveSubflowArg(scratch, ctx, node, p, b.bindings);
                try w.writeAll(arg);
            }
            try w.writeAll(");\n");
        },
    }
}

/// Resolve the value supplied for `param` at a `Subflow` call site,
/// honouring the RFC §3 precedence: wired pin → `binding` literal →
/// declared `default`. Returns Zig source text on `alloc`.
fn resolveSubflowArg(
    alloc: std.mem.Allocator,
    ctx: *GraphContext,
    subflow_node: *const flow_io.Node,
    param: flow_io.Param,
    bindings: []const flow_io.Binding,
) (CodegenError || std.mem.Allocator.Error)![]const u8 {
    // 1. Wired — an edge into the param-named input pin.
    if (try ctx.resolveInput(alloc, subflow_node, param.name)) |expr| return expr;
    // 2. Binding literal.
    for (bindings) |bd| {
        if (std.mem.eql(u8, bd.param, param.name)) {
            return try alloc.dupe(u8, bd.value.zig_text);
        }
    }
    // 3. Declared default.
    if (param.default) |d| return try alloc.dupe(u8, d.zig_text);
    // Neither wired, bound, nor defaulted (RFC §3 rule 3).
    return error.MissingFlowArg;
}

// =====================================================================
// Pin signatures
// =====================================================================

fn primaryOutputPin(k: flow_io.NodeKind) []const u8 {
    return switch (k) {
        .GetComponent, .Literal, .Identifier, .Param => "value",
        .BinOp, .Call, .Subflow => "result",
        .SetField, .Output => "",
    };
}

fn isInputPin(k: flow_io.NodeKind, pin: []const u8) bool {
    return switch (k) {
        // Pure producers.
        .GetComponent, .Literal, .Identifier, .Param => false,
        .SetField => std.mem.eql(u8, pin, "value"),
        .Output => std.mem.eql(u8, pin, "value"),
        .BinOp => std.mem.eql(u8, pin, "a") or std.mem.eql(u8, pin, "b"),
        .Call => isCallArgPin(pin),
        // A Subflow's input pins are its referenced flow's params —
        // any non-empty name is accepted here; an unknown param is
        // caught against the registry at emit time.
        .Subflow => pin.len != 0,
    };
}

fn isCallArgPin(pin: []const u8) bool {
    if (!std.mem.startsWith(u8, pin, "arg")) return false;
    const tail = pin[3..];
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn countCallArgs(flow: flow_io.Flow, node_id: u32) usize {
    var max_idx: ?usize = null;
    for (flow.edges) |e| {
        if (e.to.node != node_id) continue;
        if (!std.mem.startsWith(u8, e.to.pin, "arg")) continue;
        const idx = std.fmt.parseInt(usize, e.to.pin[3..], 10) catch continue;
        if (max_idx == null or idx > max_idx.?) max_idx = idx;
    }
    return if (max_idx) |m| m + 1 else 0;
}

// =====================================================================
// Helpers
// =====================================================================

fn hasParam(params: []const flow_io.Param, name: []const u8) bool {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

fn anyOutput(nodes: []const flow_io.Node) bool {
    for (nodes) |n| if (n.kind == .Output) return true;
    return false;
}

/// Collect the `Output` nodes of a flow, in ascending-id order so the
/// generated return struct field order is deterministic (RFC §6).
fn collectOutputs(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
) ![]*const flow_io.Node {
    var list: std.ArrayList(*const flow_io.Node) = .empty;
    errdefer list.deinit(allocator);
    for (flow.nodes) |*n| {
        if (n.kind == .Output) try list.append(allocator, n);
    }
    const out = try list.toOwnedSlice(allocator);
    std.mem.sort(*const flow_io.Node, out, {}, struct {
        fn lt(_: void, a: *const flow_io.Node, b: *const flow_io.Node) bool {
            return a.id < b.id;
        }
    }.lt);
    return out;
}

/// Reject the case where two `Output` nodes with distinct names
/// sanitize to the same Zig identifier — the multi-output result
/// struct (RFC §6) would then declare two fields with the same name
/// and fail to compile (CodegenError.SymbolCollision). Single- and
/// zero-output flows cannot collide, so the check is a no-op there.
fn assertNoOutputCollision(
    allocator: std.mem.Allocator,
    outputs: []const *const flow_io.Node,
) (CodegenError || std.mem.Allocator.Error)!void {
    if (outputs.len < 2) return;
    var by_field = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = by_field.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        by_field.deinit();
    }
    for (outputs) |o| {
        const name = o.kind.Output.name;
        const field = try sanitizeSymbol(allocator, name);
        const gop = try by_field.getOrPut(field);
        if (gop.found_existing) {
            allocator.free(field);
            // Two Output nodes may legitimately share a name in a
            // malformed graph; either way distinct names mapping to
            // one field is the unrecoverable case.
            if (!std.mem.eql(u8, gop.value_ptr.*, name))
                return error.SymbolCollision;
        } else {
            gop.value_ptr.* = name;
        }
    }
}

/// Deterministically derive a valid Zig identifier from a flow's
/// effective name (RFC §6 — "sanitized to a valid Zig identifier").
/// Non-identifier characters become `_`; a leading digit is prefixed
/// with `_`. Caller owns the returned bytes.
pub fn sanitizeSymbol(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const prefix_underscore = name.len == 0 or (name[0] >= '0' and name[0] <= '9');
    const len = name.len + @intFromBool(prefix_underscore);
    const out = try allocator.alloc(u8, if (len == 0) 1 else len);
    var i: usize = 0;
    if (prefix_underscore) {
        out[0] = '_';
        i = 1;
    }
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        out[i] = if (ok) c else '_';
        i += 1;
    }
    return out;
}

/// The `pub fn` name emitted for a flow used as the file entry point,
/// keyed by its `Event`. These four names occupy the file's top-level
/// symbol namespace alongside the subgraph `fn`s.
fn entryFunctionName(event: flow_io.Event) []const u8 {
    return switch (event) {
        .OnUpdate => "onUpdate",
        .OnCreate => "onCreate",
        .OnDestroy => "onDestroy",
        .OnCall => "onCall",
    };
}

/// Reject the case where two file-level symbols with distinct effective
/// names sanitize to the same Zig identifier — that would emit two
/// definitions with the same symbol and fail to compile
/// (CodegenError.SymbolCollision). Covers both the subgraph `fn`s and
/// the entry `pub fn` (`entry_fn_name`): a subgraph whose name
/// sanitizes to e.g. `onCall` collides with the entry handler.
fn assertNoSymbolCollision(
    allocator: std.mem.Allocator,
    entry_fn_name: []const u8,
    subgraphs: []const flow_io.Flow,
) (CodegenError || std.mem.Allocator.Error)!void {
    // Each symbol maps to the source it was emitted from. A subgraph
    // claiming the entry handler's identifier is always a collision —
    // even if its flow name happens to equal `entry_fn_name` — because
    // the entry `pub fn` and a subgraph `fn` are two distinct
    // definitions in one file.
    const Source = union(enum) { entry, subgraph: []const u8 };
    var by_symbol = std.StringHashMap(Source).init(allocator);
    defer {
        var it = by_symbol.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        by_symbol.deinit();
    }
    // Seed with the entry `pub fn` name. It is already a valid Zig
    // identifier, so it equals its own sanitized form.
    {
        const seed = try allocator.dupe(u8, entry_fn_name);
        const gop = try by_symbol.getOrPut(seed);
        if (gop.found_existing) allocator.free(seed) else gop.value_ptr.* = .entry;
    }
    for (subgraphs) |sg| {
        const symbol = try sanitizeSymbol(allocator, sg.name);
        const gop = try by_symbol.getOrPut(symbol);
        if (gop.found_existing) {
            allocator.free(symbol);
            switch (gop.value_ptr.*) {
                // Colliding with the entry handler is always fatal.
                .entry => return error.SymbolCollision,
                // Same subgraph name twice is fine (registry de-dups);
                // only a distinct name colliding is an error.
                .subgraph => |prev| if (!std.mem.eql(u8, prev, sg.name))
                    return error.SymbolCollision,
            }
        } else {
            gop.value_ptr.* = .{ .subgraph = sg.name };
        }
    }
}

/// `seen.put` with an allocator-owned copy of `name` as the key,
/// freeing the copy when the key already exists. Keys are freed by
/// the caller's `keyIterator` loop on cleanup.
fn putOwnedKey(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMap(void),
    name: []const u8,
) std.mem.Allocator.Error!void {
    const key = try allocator.dupe(u8, name);
    const gop = try seen.getOrPut(key);
    if (gop.found_existing) allocator.free(key);
}

/// Reject a flow whose declared `params`, after sanitization, collide
/// with each other or with a fixed `fn` parameter — `game`, or the
/// lifecycle arg (`OnUpdate` dt / `OnCreate`+`OnDestroy` entity). Such
/// a flow parses cleanly yet emits a signature with duplicate
/// parameter identifiers, which Zig rejects (`ParamNameCollision`).
fn assertNoParamCollision(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
) (CodegenError || std.mem.Allocator.Error)!void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    // Fixed parameters always present in the emitted signature: every
    // flow takes `game`, and a lifecycle event adds its dt/entity arg
    // verbatim — exactly as `writeFnHeader` emits them.
    try putOwnedKey(allocator, &seen, "game");
    switch (flow.event) {
        .OnUpdate => |b| try putOwnedKey(allocator, &seen, b.arg_dt),
        .OnCreate => |b| try putOwnedKey(allocator, &seen, b.arg_entity),
        .OnDestroy => |b| try putOwnedKey(allocator, &seen, b.arg_entity),
        .OnCall => {},
    }

    for (flow.params) |p| {
        const name = try sanitizeSymbol(allocator, p.name);
        const gop = try seen.getOrPut(name);
        if (gop.found_existing) {
            allocator.free(name);
            return error.ParamNameCollision;
        }
    }
}

fn anyNodeNeedsEntity(nodes: []const flow_io.Node) bool {
    for (nodes) |n| {
        switch (n.kind) {
            .GetComponent, .SetField => return true,
            else => {},
        }
    }
    return false;
}

/// Collect component type names referenced across the entry flow and
/// every subgraph — de-duplicated, alphabetically sorted.
fn collectComponentTypesAll(
    allocator: std.mem.Allocator,
    entry: flow_io.Flow,
    subgraphs: []const flow_io.Flow,
) (CodegenError || std.mem.Allocator.Error)![][]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    try collectComponentTypesInto(entry, &seen, &list, allocator);
    for (subgraphs) |sg| {
        try collectComponentTypesInto(sg, &seen, &list, allocator);
    }

    const out = try list.toOwnedSlice(allocator);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

fn collectComponentTypesInto(
    flow: flow_io.Flow,
    seen: *std.StringHashMap(void),
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error)!void {
    for (flow.nodes) |n| {
        const type_name: ?[]const u8 = switch (n.kind) {
            .GetComponent => |b| b.type,
            .SetField => |b| blk: {
                const dot = std.mem.lastIndexOfScalar(u8, b.target, '.') orelse break :blk null;
                break :blk b.target[0..dot];
            },
            else => null,
        };
        if (type_name) |t| {
            if (t.len == 0) continue;
            if (std.mem.indexOfScalar(u8, t, '.') != null) return error.NamespacedComponentType;
            const gop = try seen.getOrPut(t);
            if (!gop.found_existing) try list.append(allocator, t);
        }
    }
}
