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
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    try walkRefs(allocator, registry, start, &stack, &visited, chain_out);
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
    // RFC §4: cycle check runs before any emission.
    if (entry.name.len != 0) {
        var chain: ?[]const u8 = null;
        detectReferenceCycle(allocator, registry, entry.name, &chain) catch |err| {
            if (chain) |c| allocator.free(c);
            return err;
        };
    }

    // Collect the transitive set of referenced subgraphs.
    var subgraphs: std.ArrayList(flow_io.Flow) = .empty;
    defer subgraphs.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    try collectSubgraphs(allocator, registry, entry, &subgraphs, &seen);

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

    try writeFnHeader(w, flow.event);

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

    const symbol = try sanitizeSymbol(allocator, flow.name);
    defer allocator.free(symbol);

    const outputs = try collectOutputs(allocator, flow);
    defer allocator.free(outputs);

    // Multi-output subgraphs return a named result struct (RFC §6).
    // Declare it just above the function so the type is in scope.
    if (outputs.len > 1) {
        try w.print("const {s}_Result = struct {{\n", .{symbol});
        for (outputs) |o| {
            try w.print("    {s}: {s},\n", .{ o.kind.Output.name, o.kind.Output.type });
        }
        try w.writeAll("};\n");
    }

    // Signature: `fn <symbol>(game: *Game, <param>: <type>, …) <ret> {`
    try w.print("fn {s}(game: *Game", .{symbol});
    for (flow.params) |p| {
        try w.print(", {s}: {s}", .{ p.name, p.type });
    }
    try w.writeAll(") ");
    try writeReturnType(w, symbol, outputs);
    try w.writeAll(" {\n");

    try emitBody(allocator, w, &ctx, flow.name);

    // Return statement (RFC §6).
    if (outputs.len == 1) {
        const expr = (try ctx.resolveInput(outputs[0], "value")) orelse return error.DanglingPin;
        defer allocator.free(expr);
        try w.print("    return {s};\n", .{expr});
    } else if (outputs.len > 1) {
        try w.writeAll("    return .{\n");
        for (outputs) |o| {
            const expr = (try ctx.resolveInput(o, "value")) orelse return error.DanglingPin;
            defer allocator.free(expr);
            try w.print("        .{s} = {s},\n", .{ o.kind.Output.name, expr });
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

    /// Resolve `pin` on `consumer` to a Zig expression. `null` when the
    /// pin is disconnected (caller decides default vs error).
    fn resolveInput(
        self: *GraphContext,
        consumer: *const flow_io.Node,
        pin: []const u8,
    ) (CodegenError || std.mem.Allocator.Error)!?[]const u8 {
        const edge = self.index.producerOf(consumer.id, pin) orelse return null;
        const producer = self.index.byId(edge.from.node) orelse return error.UnknownPin;

        const primary = primaryOutputPin(producer.kind);
        if (primary.len != 0 and std.mem.eql(u8, edge.from.pin, primary)) {
            return try std.fmt.allocPrint(
                self.allocator,
                "n{d}_{s}",
                .{ producer.id, primary },
            );
        }
        switch (producer.kind) {
            // GetComponent: non-`value` pins are field accesses.
            .GetComponent => return try std.fmt.allocPrint(
                self.allocator,
                "n{d}_value.{s}",
                .{ producer.id, edge.from.pin },
            ),
            // Subflow: a non-primary output pin names a result field.
            .Subflow => return try std.fmt.allocPrint(
                self.allocator,
                "n{d}_result.{s}",
                .{ producer.id, edge.from.pin },
            ),
            else => return error.UnknownPin,
        }
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

fn writeFnHeader(w: anytype, ev: flow_io.Event) !void {
    switch (ev) {
        .OnUpdate => |b| try w.print(
            "pub fn onUpdate(game: *Game, {s}: f32) void {{\n",
            .{b.arg_dt},
        ),
        .OnCreate => |b| try w.print(
            "pub fn onCreate(game: *Game, {s}: EntityId) void {{\n",
            .{b.arg_entity},
        ),
        .OnDestroy => |b| try w.print(
            "pub fn onDestroy(game: *Game, {s}: EntityId) void {{\n",
            .{b.arg_entity},
        ),
        // An OnCall flow used as the file entry point still needs a
        // callable surface — emit a parameterless `pub fn onCall`.
        .OnCall => try w.writeAll("pub fn onCall(game: *Game) void {\n"),
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
    _ = scratch;
    switch (node.kind) {
        .GetComponent => |b| try w.print(
            "    const n{d}_value = game.getComponent(entity, {s}) orelse return;\n",
            .{ node.id, b.type },
        ),
        .SetField => |b| {
            const dot = std.mem.lastIndexOfScalar(u8, b.target, '.') orelse return error.UnknownPin;
            const type_name = b.target[0..dot];
            const field_name = b.target[dot + 1 ..];
            const value_expr = (try ctx.resolveInput(node, "value")) orelse return error.DanglingPin;
            defer ctx.allocator.free(value_expr);
            try w.print(
                "    game.setField({s}, .{s}, entity, {s});\n",
                .{ type_name, field_name, value_expr },
            );
        },
        .BinOp => |b| {
            const a_expr = (try ctx.resolveInput(node, "a")) orelse try ctx.allocator.dupe(u8, "0");
            defer ctx.allocator.free(a_expr);
            const b_expr = (try ctx.resolveInput(node, "b")) orelse try ctx.allocator.dupe(u8, "0");
            defer ctx.allocator.free(b_expr);
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
        // The parameter is in scope as a function argument of the same
        // name.
        .Param => |b| try w.print(
            "    const n{d}_value = {s};\n",
            .{ node.id, b.param },
        ),
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
                const expr = (try ctx.resolveInput(node, pin)) orelse
                    try ctx.allocator.dupe(u8, "undefined");
                defer ctx.allocator.free(expr);
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

            const symbol = try sanitizeSymbol(ctx.allocator, ref.name);
            defer ctx.allocator.free(symbol);

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
                const arg = try resolveSubflowArg(ctx, node, p, b.bindings);
                defer ctx.allocator.free(arg);
                try w.writeAll(arg);
            }
            try w.writeAll(");\n");
        },
    }
}

/// Resolve the value supplied for `param` at a `Subflow` call site,
/// honouring the RFC §3 precedence: wired pin → `binding` literal →
/// declared `default`. Returns Zig source text on `ctx.allocator`.
fn resolveSubflowArg(
    ctx: *GraphContext,
    subflow_node: *const flow_io.Node,
    param: flow_io.Param,
    bindings: []const flow_io.Binding,
) (CodegenError || std.mem.Allocator.Error)![]const u8 {
    // 1. Wired — an edge into the param-named input pin.
    if (try ctx.resolveInput(subflow_node, param.name)) |expr| return expr;
    // 2. Binding literal.
    for (bindings) |bd| {
        if (std.mem.eql(u8, bd.param, param.name)) {
            return try ctx.allocator.dupe(u8, bd.value.zig_text);
        }
    }
    // 3. Declared default.
    if (param.default) |d| return try ctx.allocator.dupe(u8, d.zig_text);
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
