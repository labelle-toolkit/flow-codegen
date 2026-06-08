//! Graph context — the per-flow node index + topo order, shared by the
//! entry and subgraph emission paths. Also hosts `resolveInput` (pin →
//! Zig expression) and `discardUnconsumedResult` (unused-binding cleanup),
//! both of which hang off the indexed graph.

const std = @import("std");
const flow_io = @import("../flow_io.zig");
const errors = @import("errors.zig");
const registries = @import("registries.zig");
const pins = @import("pins.zig");

const CodegenError = errors.CodegenError;
const FlowRegistry = registries.FlowRegistry;
const CustomNodeRegistry = registries.CustomNodeRegistry;
const primaryOutputPin = pins.primaryOutputPin;
const sanitizeSymbol = pins.sanitizeSymbol;
const anyOutput = pins.anyOutput;

pub const GraphContext = struct {
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    registry: *const FlowRegistry,
    /// Optional `CustomNode` registry (RFC-FLOW-VOCABULARY §1) — when
    /// `null`, any `CustomNode` reference is rejected as
    /// `UnknownFlowNode`. Threaded through here so `writeNodeBody` and
    /// `resolveInput` can consult it without changing every helper
    /// signature.
    custom_nodes: ?*const CustomNodeRegistry,
    index: Index,
    order: []u32,

    pub fn init(
        allocator: std.mem.Allocator,
        flow: flow_io.Flow,
        registry: *const FlowRegistry,
        custom_nodes: ?*const CustomNodeRegistry,
    ) (CodegenError || std.mem.Allocator.Error)!GraphContext {
        var index = try buildIndex(allocator, flow);
        errdefer index.deinit();

        const order = try topoSort(allocator, flow);
        errdefer allocator.free(order);

        // Validate every edge's `to.pin` against the consumer's input
        // pin signature.
        for (flow.edges) |e| {
            const consumer = index.byId(e.to.node) orelse unreachable;
            if (!pins.isInputPin(consumer.kind, e.to.pin)) return error.UnknownPin;
        }

        return .{
            .allocator = allocator,
            .flow = flow,
            .registry = registry,
            .custom_nodes = custom_nodes,
            .index = index,
            .order = order,
        };
    }

    pub fn deinit(self: *GraphContext) void {
        self.index.deinit();
        self.allocator.free(self.order);
    }

    /// Resolve `pin` on `consumer` to a Zig expression, allocated on
    /// `alloc`. `null` when the pin is disconnected (caller decides
    /// default vs error). Per-node emission passes a scratch arena so
    /// the returned text is reclaimed after the node; the subgraph
    /// `return` path passes the long-lived allocator.
    pub fn resolveInput(
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

        // A `ForRange`'s `index` output pin IS the loop variable
        // (flow-codegen#21) — it resolves to the `i_<id>` name declared by
        // the loop header, NOT an `n<id>_…` binding. Body nodes that read
        // `index` emit inside the `while` block, where `i_<id>` is in
        // scope. (`ForRange` exposes no other output pin.)
        if (producer.kind == .ForRange and std.mem.eql(u8, edge.from.pin, "index")) {
            return try std.fmt.allocPrint(alloc, "i_{d}", .{producer.id});
        }

        // A `ForEach`'s `item` / `index` output pins ARE the `for` loop
        // captures (flow-codegen#24) — they resolve to the `item_<id>` /
        // `idx_<id>` names declared by the loop header, NOT `n<id>_…`
        // bindings. Body nodes that read them emit inside the `for` block,
        // where the captures are in scope (mirrors `ForRange.index`).
        if (producer.kind == .ForEach and std.mem.eql(u8, edge.from.pin, "item")) {
            return try std.fmt.allocPrint(alloc, "item_{d}", .{producer.id});
        }
        if (producer.kind == .ForEach and std.mem.eql(u8, edge.from.pin, "index")) {
            return try std.fmt.allocPrint(alloc, "idx_{d}", .{producer.id});
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

pub const Index = struct {
    allocator: std.mem.Allocator,
    by_id: std.AutoHashMap(u32, *const flow_io.Node),
    producers: std.HashMap(EdgeKey, *const flow_io.Edge, EdgeKeyContext, std.hash_map.default_max_load_percentage),

    pub fn deinit(self: *Index) void {
        self.by_id.deinit();
        self.producers.deinit();
    }

    pub fn byId(self: *const Index, id: u32) ?*const flow_io.Node {
        return self.by_id.get(id);
    }

    pub fn producerOf(self: *const Index, consumer: u32, pin: []const u8) ?*const flow_io.Edge {
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

/// Emit `_ = n<id>_<pin>;` for a node whose result value is bound to a
/// `const` but read by no downstream edge — e.g. a terminal `Call`
/// invoked purely for its side effect. Without this the unreferenced
/// `const` is an "unused local constant" compile error. Nodes that
/// emit a bare statement (`SetField`, a void `Subflow`) and `Output`
/// nodes bind no value and are skipped.
pub fn discardUnconsumedResult(
    w: *std.Io.Writer,
    node: *const flow_io.Node,
    ctx: *GraphContext,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const pin = primaryOutputPin(node.kind);
    if (pin.len == 0) return; // SetField / Output bind nothing.
    // A `Subflow` only binds a result when the referenced flow has
    // `Output` nodes; a void one is lowered to a bare call statement.
    if (node.kind == .Subflow) {
        const ref = ctx.registry.get(node.kind.Subflow.flow) orelse return;
        if (!anyOutput(ref.nodes)) return;
    }
    // A `CustomNode` with a `void` impl emits a bare call statement
    // (see `writeNodeBody`) — no `n<id>_value` exists to discard. The
    // registry's `is_void` flag is the source of truth; an unregistered
    // name would already have raised `UnknownFlowNode` in
    // `writeNodeBody`, so a fall-through `return` here is safe.
    if (node.kind == .CustomNode) {
        const reg = ctx.custom_nodes orelse return;
        const entry = reg.get(node.kind.CustomNode.name) orelse return;
        if (entry.is_void) return;
    }
    for (ctx.flow.edges) |e| {
        if (e.from.node == node.id) return; // consumed by some edge
    }
    try w.print("    _ = n{d}_{s};\n", .{ node.id, pin });
}
