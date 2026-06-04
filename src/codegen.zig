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
    /// Optional registry of plugin / game-script `FlowNodes`
    /// (RFC-FLOW-VOCABULARY §1 + §5). Required when the flow uses
    /// `CustomNode` nodes — codegen consults the registry to map
    /// dotted names to qualified `PluginFlowNodes` decls and to pick
    /// the command-vs-reporter lowering shape per the impl's return
    /// type. `null` is equivalent to an empty registry: a flow with no
    /// `CustomNode` nodes renders unchanged; any `CustomNode` reference
    /// is rejected as `UnknownFlowNode`. The assembler fills this from
    /// its phase-2 discovery walk; tests construct it inline.
    custom_nodes: ?*const CustomNodeRegistry = null,

    /// Optional registry of plugin / game-script `Coercions`
    /// (RFC-FLOW-VOCABULARY §2 / O4). Threaded into the wire-fit
    /// lookup so an edge across two pins with different Zig types is
    /// accepted when a registered `(from_zig_type, to_zig_type)` pair
    /// exists; edge codegen then wraps the source expression in
    /// `game_mod.PluginCoercions.<qualified>.convert(<expr>)`. `null`
    /// is equivalent to an empty registry — the wire-fit falls back
    /// to type equality (rule 1) + numeric widening (rule 2 / O1)
    /// only. The assembler fills this from its phase-2 discovery walk;
    /// tests construct it inline.
    coercions: ?*const CoercionRegistry = null,
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
    /// A `CustomNode` (RFC-FLOW-VOCABULARY §1) names a dotted entry
    /// that is not registered in the `CustomNodeRegistry` passed to
    /// `renderFlowZig` / `renderFlowFile`. The assembler-emitted
    /// `PluginFlowNodes` registry is the source of truth at build
    /// time; an unknown name surfaces here at codegen rather than as
    /// a deferred Zig compile error against the missing decl.
    UnknownFlowNode,
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
// CustomNode registry — name-keyed metadata for plugin / game-script
// FlowNodes (RFC-FLOW-VOCABULARY §1 + §5, flow-codegen#15 item 2)
// =====================================================================

/// One entry per discoverable plugin / game-script `FlowNode`. Built by
/// the assembler from its `PluginFlowNodes` walk (labelle-assembler
/// phase 2, RFC §2) and passed to `renderFlowFile` so codegen can:
///
/// - reject `CustomNode` references to unknown names as
///   `error.UnknownFlowNode` rather than deferring to a vaguer Zig
///   compile error against the missing decl;
/// - emit the **command** lowering (a bare statement) for `void`
///   impls vs the **reporter** lowering (`const n<id>_value = ...;`)
///   for value-returning impls (RFC §6 — command vs reporter shape).
///
/// The reflection on the `impl` decl happens once at assembler time;
/// flow-codegen consumes the precomputed `is_void` flag here. The
/// registry borrows its string slices from the caller.
pub const CustomNodeEntry = struct {
    /// Qualified decl name as it appears on `game_mod.PluginFlowNodes`
    /// (`"box2d__apply_impulse"`). Used directly in the emitted call
    /// site. The dotted form (`"box2d.apply_impulse"`) is what the
    /// `.flow.jsonc` author writes; the assembler maps the two via
    /// `PluginFlowNodes.resolve(...)`.
    qualified: []const u8,
    /// True when the impl's return type is `void` — codegen emits a
    /// bare statement; false when it returns a value — codegen binds
    /// the result to `n<id>_value`. RFC §6 ("Command vs reporter
    /// visual" — defaulted from `impl`'s return type).
    is_void: bool,
};

/// A flat, name-keyed registry of `CustomNode` entries. Empty by
/// default (`CustomNodeRegistry.empty(allocator)`) so callers that
/// don't use `CustomNode` nodes — every pre-RFC-FLOW-VOCABULARY-§1
/// flow — keep an unchanged call signature; an empty registry simply
/// rejects every `CustomNode` reference as `UnknownFlowNode`.
pub const CustomNodeRegistry = struct {
    map: std.StringHashMap(CustomNodeEntry),

    pub fn init(allocator: std.mem.Allocator) CustomNodeRegistry {
        return .{ .map = std.StringHashMap(CustomNodeEntry).init(allocator) };
    }

    pub fn deinit(self: *CustomNodeRegistry) void {
        self.map.deinit();
    }

    /// Register `entry` under its dotted name (`"box2d.apply_impulse"`).
    /// Borrows the slices on `entry` from the caller; the assembler's
    /// arena holds them for the lifetime of the codegen call.
    pub fn add(self: *CustomNodeRegistry, dotted: []const u8, entry: CustomNodeEntry) !void {
        try self.map.put(dotted, entry);
    }

    pub fn get(self: *const CustomNodeRegistry, dotted: []const u8) ?CustomNodeEntry {
        return self.map.get(dotted);
    }
};

// =====================================================================
// CoercionRegistry — type-keyed lookup for plugin-declared coercions
// (RFC-FLOW-VOCABULARY §2 / O4, flow-codegen#15 item 5)
// =====================================================================

/// One entry per discoverable plugin / game-script `Coercion`. Built
/// by the assembler from its `PluginCoercions` walk (parallel to
/// `CustomNodeEntry`). Carries the Zig source text of the `From` and
/// `To` types so wire-fit can match an edge's producer- and
/// consumer-pin types, plus the qualified decl name codegen emits at
/// the call site.
///
/// The strings are borrowed from the caller; the assembler's arena
/// owns them for the lifetime of the codegen call.
pub const CoercionEntry = struct {
    /// Qualified decl name as it appears on `game_mod.PluginCoercions`
    /// (`"box2d__body_to_entity"`). Used directly in the emitted call
    /// site as `game_mod.PluginCoercions.<qualified>.convert(<expr>)`.
    qualified: []const u8,
    /// Zig source text of the impl's single parameter type (e.g.
    /// `"BodyId"`, `"u64"`). The editor's wire-fit matches this
    /// string against the producer pin's declared type; codegen
    /// reuses the same key for its `accepts` lookup.
    from_zig_type: []const u8,
    /// Zig source text of the impl's return type (e.g. `"u32"`,
    /// `"EntityId"`). Matched against the consumer pin's declared
    /// type. The labelle-core factory rejects `void` impls at
    /// comptime, so this field is never empty in practice.
    to_zig_type: []const u8,
};

/// Outcome of a wire-fit lookup (RFC-FLOW-VOCABULARY §2). Returned by
/// `CoercionRegistry.wireFitAccepts`. The three accept cases tell the
/// editor (and any source-text-driven wire-fit caller) which rule
/// applied, so a UI can surface "via numeric widening" vs "via
/// declared coercion `<name>`" diagnostics distinctly.
pub const WireFit = union(enum) {
    /// Rule 1 — Zig type equality. The two type strings match
    /// verbatim.
    exact,
    /// Rule 2 (O1) — numeric widening. Currently only flagged when
    /// the caller hands `wireFitAccepts` two distinct primitive
    /// numeric type names where Zig's implicit widening accepts the
    /// conversion. For now the codegen-side check is a thin sentinel
    /// (the actual numeric-widening matrix lives in
    /// `labelle-core.numericFits` and is consumed at editor compile
    /// time); flow-codegen's runtime caller is the editor.
    numeric_widen,
    /// Rule 3 — a registered plugin coercion bridges the gap. Carries
    /// the qualified decl name flow-codegen wraps the edge in.
    coercion: []const u8,
    /// Refused — no built-in rule matched and no coercion is
    /// registered for `(from, to)`.
    refused,
};

/// A flat registry of plugin coercions keyed by `(from, to)` Zig
/// source-text type names. Empty by default — every flow that doesn't
/// declare cross-type wires keeps its unchanged behaviour; an empty
/// registry simply makes `wireFitAccepts` return `.refused` for any
/// (from, to) the editor's built-in rules don't already accept.
///
/// The key is a heap-allocated `"<from>->><to>"` string so the same
/// `std.StringHashMap` shape powers lookups. Borrows the `entry` values
/// from the caller.
pub const CoercionRegistry = struct {
    /// Composite key: `"<from_zig_type>->><to_zig_type>"`. The `->>`
    /// separator is unambiguous (Zig type names don't contain it) and
    /// avoids the per-pair allocation a `struct{from,to}` key would
    /// need going through a custom HashMap context. Keys live in the
    /// registry's `arena` and are freed by `deinit`.
    map: std.StringHashMap(CoercionEntry),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) CoercionRegistry {
        return .{
            .map = std.StringHashMap(CoercionEntry).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CoercionRegistry) void {
        self.map.deinit();
        self.arena.deinit();
    }

    /// Register `entry` under its `(from, to)` type-name pair. A
    /// duplicate `(from, to)` overwrites the prior entry — same
    /// last-write-wins shape `PluginPinStyles` dedupe uses, surfacing
    /// late-loaded plugin conventions cleanly.
    pub fn add(self: *CoercionRegistry, entry: CoercionEntry) !void {
        const key = try std.fmt.allocPrint(
            self.arena.allocator(),
            "{s}->>{s}",
            .{ entry.from_zig_type, entry.to_zig_type },
        );
        try self.map.put(key, entry);
    }

    /// Look up a coercion for `(from, to)`. Returns `null` when no
    /// entry is registered — the caller falls back to the built-in
    /// wire-fit rules (or refuses the wire).
    pub fn get(self: *const CoercionRegistry, from: []const u8, to: []const u8) ?CoercionEntry {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}->>{s}", .{ from, to }) catch return null;
        return self.map.get(key);
    }

    /// Resolve the wire-fit outcome for a pin pair (RFC-FLOW-VOCABULARY
    /// §2 rule chain):
    ///   1. equality — strings match → `.exact`.
    ///   2. (caller-side: numeric widening — flow-codegen doesn't
    ///       reflect on Zig types from source text; callers that need
    ///       this consult `labelle-core.numericFits` against actual
    ///       Zig `type` values. The `numeric_widen` outcome is
    ///       reserved for the future editor-side check that pairs
    ///       both rules).
    ///   3. registry — a registered `(from, to)` → `.coercion(qualified)`.
    ///   4. otherwise → `.refused`.
    ///
    /// This is the contract the editor and any source-text-driven
    /// codegen consumer consults at edge-validation time.
    pub fn wireFitAccepts(self: *const CoercionRegistry, from: []const u8, to: []const u8) WireFit {
        if (std.mem.eql(u8, from, to)) return .exact;
        if (self.get(from, to)) |entry| return .{ .coercion = entry.qualified };
        return .refused;
    }
};

/// Wrap a Zig source expression in a `<qualified>.convert(<expr>)`
/// call against `game_mod.PluginCoercions`. Edge codegen calls this
/// when the wire-fit lookup returned `.coercion(qualified)`. Returns
/// the wrapped expression on `alloc`; the caller owns the bytes.
///
/// The wrap is shallow on purpose — flow-codegen never threads `game`
/// into the convert call because the labelle-core factory rejects
/// multi-param impls at comptime, so a registered coercion always has
/// a single-arg call site. If a coercion genuinely needs game state,
/// the source plugin must declare a `FlowNode` instead.
pub fn wrapEdgeWithCoercion(
    alloc: std.mem.Allocator,
    qualified: []const u8,
    expr: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "game_mod.PluginCoercions.{s}.convert({s})",
        .{ qualified, expr },
    );
}

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
    // entry `pub fn` name (`onCall` / `setup`) is checked too: a
    // subgraph whose name sanitizes to one of those would emit a `fn`
    // colliding with the file's `pub fn`.
    try assertNoSymbolCollision(allocator, entryFunctionName(entry.event), subgraphs.items);

    // Each flow's declared `params` must not collide (after
    // sanitization) with each other or the fixed `fn` params —
    // checked for the entry flow and every referenced subgraph. The
    // entry reserves its lifecycle arg; a subgraph does not.
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

    // File-scope `var` declarations (RFC-FLOW-VOCABULARY §4 —
    // variables). One `pub var <name>: <type> = <default>;` per
    // declared entry. Scoped to this flow's emitted `.zig` module
    // (persistent across handler invocations); declared `pub` so
    // integration tests and the eventual global-variables story
    // (project-wide `variables/` folder generating cross-flow `pub
    // var`s) share one shape. Codegen never emits `@import("…")` of
    // another flow's variables, so the RFC's "invisible to other
    // flows" constraint holds at the codegen layer.
    if (entry.variables.len != 0) {
        for (entry.variables) |v| {
            try w.print("pub var {s}: {s} = {s};\n", .{ v.name, v.type, v.default.zig_text });
        }
        try w.writeAll("\n");
    }

    // Entry flow → its event `pub fn`.
    try renderEntryFunction(allocator, w, entry, registry, options.custom_nodes, options.flow_name);

    // Subgraphs → one `fn` each (RFC §6).
    for (subgraphs.items) |sg| {
        try w.writeAll("\n");
        try renderSubgraphFunction(allocator, w, sg, registry, options.custom_nodes);
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
    custom_nodes: ?*const CustomNodeRegistry,
    flow_name: []const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    // An `OnEvent` flow has a different shape from the lifecycle events
    // — a plugin-callback handler plus a `setup` that installs it —
    // so it has its own renderer.
    if (flow.event == .OnEvent)
        return renderEventEntry(allocator, w, flow, registry, custom_nodes, flow_name);

    var ctx = try GraphContext.init(allocator, flow, registry, custom_nodes);
    defer ctx.deinit();

    // An `OnCall` entry is a subgraph in its own right (RFC §3/§6) —
    // it has no `entity` in scope, only declared `params`. An
    // entity-scoped node (`GetComponent` / `SetField`) here must wire
    // its `entity` input pin (RFC-PLUGIN-EVENTS §9); an unwired one
    // would emit a read of an undefined `entity`. The check is
    // per-node so a flow can mix wired and unwired entity-scoped
    // nodes freely.
    //
    // Post-Phase 6 (RFC-FLOW-VOCABULARY): the lifecycle event-header
    // path is gone — every flow that previously bound a lifecycle
    // `entity` identifier now reads `payload.entity` through a wired
    // `Identifier` node, so `OnCall` is the only entry-function path
    // through here.
    try assertEntityAvailable(flow);

    // An `OnCall` flow used as the file entry point is a subgraph in
    // its own right (RFC §3/§6): its `Output` nodes form the return
    // value, exactly as for a referenced subgraph.
    const entry_fn = entryFunctionName(flow.event);
    const outputs = try collectOutputs(allocator, flow);
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

    // Render the body into a buffer first, so we can see whether `game`
    // is actually referenced. Zig rejects *both* an unused parameter
    // and a pointless `_ = x;` discard of a used one — so it is
    // discarded only when the body never mentions it.
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_aw.deinit();
    const bw = &body_aw.writer;

    try emitBody(allocator, bw, &ctx, flow_name, true);

    // Return statement for an OnCall entry with declared Outputs.
    if (outputs.len == 1) {
        const expr = (try ctx.resolveInput(allocator, outputs[0], "value")) orelse return error.DanglingPin;
        defer allocator.free(expr);
        try bw.print("    return {s};\n", .{expr});
    } else if (outputs.len > 1) {
        try bw.writeAll("    return .{\n");
        for (outputs) |o| {
            const expr = (try ctx.resolveInput(allocator, o, "value")) orelse return error.DanglingPin;
            defer allocator.free(expr);
            const field = try sanitizeSymbol(allocator, o.kind.Output.name);
            defer allocator.free(field);
            try bw.print("        .{s} = {s},\n", .{ field, expr });
        }
        try bw.writeAll("    };\n");
    }

    const body = try body_aw.toOwnedSlice();
    defer allocator.free(body);

    // `game` is the only fixed parameter of an `OnCall` entry — discard
    // it when unreferenced.
    if (!mentionsIdent(body, "game")) try w.writeAll("    _ = game;\n");

    try w.writeAll(body);
    try w.writeAll("}\n");
}

/// Render an `OnEvent` flow.
///
/// The handler is a hook-handler-struct method (`FlowEventHandler`)
/// named after the event's qualified tag (`box2d.collision_begin` →
/// `box2d__collision_begin`). The method takes `(self: *@This(),
/// payload: <PayloadType>)`; the payload type comes from
/// `@FieldType(game.PluginEvents, "<qualified_tag>")` against the
/// assembler's resolver (RFC-PLUGIN-EVENTS phase 1). `game` is reachable
/// through `self.game_ptr` (the field-injection convention every
/// shipped engine hook handler already follows —
/// `labelle-engine/src/game.zig:419-429`), so entity-scoped nodes
/// (`GetComponent` / `SetField`) and `Subflow` nodes work in a
/// new-form flow the same way they do in a lifecycle flow. The entity
/// input pin (RFC §9) is mandatory — there is no lifecycle `entity` to
/// fall back on.
///
/// The v1 legacy form (`module` + `callback` + `params`) was removed
/// in RFC-PLUGIN-EVENTS phase 6 (flow-codegen#13); a `.flow.jsonc` with
/// the retired keys now fails to parse in `flow_io.buildEvent`.
fn renderEventEntry(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    flow: flow_io.Flow,
    registry: *const FlowRegistry,
    custom_nodes: ?*const CustomNodeRegistry,
    flow_name: []const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var ctx = try GraphContext.init(allocator, flow, registry, custom_nodes);
    defer ctx.deinit();

    // `name` is `?[]const u8` (RFC-FLOW-VOCABULARY §3 — the field is
    // optional so an `Event` *node* can carry the trigger name; the
    // loader's `buildFlow` already populated it either from the header
    // or the synthesized node, and the empty-name case is rejected
    // upstream). The unwrap reaches the resolved name unconditionally.
    return renderNewFormEventEntry(allocator, w, flow, &ctx, flow_name, flow.event.OnEvent.name.?);
}

/// Map a dotted event name (`box2d.collision_begin`) to the qualified
/// variant tag (`box2d__collision_begin`) the assembler emits in its
/// `PluginEvents` union (labelle-assembler#174 — RFC-PLUGIN-EVENTS phase
/// 1). The mapping is mechanical (replace `.` with `__`) and matches
/// the codegen at `labelle-assembler/src/main_zig.zig:525` —
/// `_entry.name ++ "__" ++ _d.name`. A name with no `.` is treated as a
/// game event (declared in `events/*.zig`) and round-trips verbatim,
/// matching the way `GameEvents` variant names are emitted bare.
///
/// Caller owns the returned bytes.
fn qualifiedTagFromDotted(allocator: std.mem.Allocator, dotted: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, dotted.len + countByte(dotted, '.'));
    var i: usize = 0;
    for (dotted) |c| {
        if (c == '.') {
            out[i] = '_';
            out[i + 1] = '_';
            i += 2;
        } else {
            out[i] = c;
            i += 1;
        }
    }
    return out;
}

/// Count occurrences of `c` in `s` — the shared length helper between
/// `qualifiedTagFromDotted` (allocating) and the inline `Emit` lowering
/// (allocating on a per-node scratch arena). Hoisted so both call sites
/// agree on the output-length formula `s.len + countByte(s, '.')`.
fn countByte(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |b| if (b == c) {
        n += 1;
    };
    return n;
}

/// Render the new-form `OnEvent` flow (RFC-PLUGIN-EVENTS §7, phase 3).
///
/// Emits a `pub const FlowEventHandler = struct { game_ptr: *anyopaque =
/// undefined, pub fn <qualified_tag>(self: *@This(), payload: ...) void
/// { ... } };` whose payload type is reflected from
/// `@FieldType(game_mod.PluginEvents, "<qualified_tag>")`. The
/// assembler discovers this struct in scanner-sorted order and appends
/// `*FlowEventHandler` to the `GameHooks` receiver tuple (phase 4 —
/// labelle-assembler#175, not in scope here). The engine's existing
/// `setHooks` loop (`labelle-engine/src/game.zig:419-429`) injects the
/// `*AssembledGame` pointer into `self.game_ptr` at init.
///
/// The handler body is the same topo-sorted lowering lifecycle handlers
/// use — `game` is reachable through the downcast and entity-scoped
/// nodes resolve their `entity` input pin (RFC §9, the entity-pin
/// scaffold from `8e7fb7b`). No lifecycle `entity` fallback: every
/// entity-scoped node must wire its `entity` pin explicitly, since a
/// new-form OnEvent flow has no "the entity" — entity ids ride the
/// payload.
fn renderNewFormEventEntry(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    flow: flow_io.Flow,
    ctx: *GraphContext,
    flow_name: []const u8,
    dotted_name: []const u8,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    // Entity-scoped nodes inside a new-form flow MUST wire the entity
    // pin (RFC §9 — "the entity pin is mandatory; no lifecycle `entity`
    // fallback"). A new-form flow has `game` reachable through
    // `game_ptr` but no in-scope `entity` identifier, so an unwired
    // entity pin is the same `DanglingPin` case `assertEntityAvailable`
    // already raises for `OnCall` entries and `Subflow` subgraphs.
    try assertEntityAvailable(flow);

    // Collect every in-graph `Event` node — by document order — so a
    // multi-trigger flow (RFC-FLOW-VOCABULARY §3 — "A flow with multiple
    // Event nodes is a multi-trigger flow", resolves RFC open question
    // O2) emits one `FlowEventHandler` method per trigger sharing a
    // common downstream-body helper.
    //
    // For the legacy header path (no Event nodes, `event:` carries the
    // trigger), we fall back to the single passed-in `dotted_name`.
    var trigger_names: std.ArrayList([]const u8) = .empty;
    defer trigger_names.deinit(allocator);
    for (flow.nodes) |n| {
        if (n.kind == .Event) try trigger_names.append(allocator, n.kind.Event.name);
    }
    if (trigger_names.items.len == 0) try trigger_names.append(allocator, dotted_name);

    // Header — flow files compile in isolation, so the import of
    // `PluginEvents` rides through the same `game_mod` (`@import("game")`)
    // shim the existing `Game`/`EntityId` decls do. The shim re-export
    // is the phase-3 assembler-side change paired with this codegen.
    try w.writeAll("const PluginEvents = game_mod.PluginEvents;\n\n");

    // Single-trigger flow (the established shape): keep one `__EvPayload`
    // alias and inline the topo-sorted body into the single dispatch
    // method, where `payload` is in scope. This preserves the existing
    // single-event tests + the bouncing-ball codegen byte-for-byte.
    if (trigger_names.items.len == 1) {
        const qualified = try qualifiedTagFromDotted(allocator, trigger_names.items[0]);
        defer allocator.free(qualified);

        // Reflect the payload type through `@FieldType(...)`. The compiler
        // catches an unknown tag here — a flow naming `frobnitz.foo` when
        // no plugin declares it surfaces as a build-time error against the
        // `PluginEvents` field set, not a missing-key in a sidecar.
        try w.print(
            "const __EvPayload = @FieldType(PluginEvents, \"{s}\");\n\n",
            .{qualified},
        );

        try w.writeAll("pub const FlowEventHandler = struct {\n");
        try w.writeAll("    game_ptr: *anyopaque = undefined,\n\n");

        try w.print(
            "    pub fn {s}(self: *@This(), payload: __EvPayload) void {{\n",
            .{qualified},
        );

        try w.writeAll("        const game: *Game = @ptrCast(@alignCast(self.game_ptr));\n");

        // Render the body to a buffer so we can detect which of the fixed
        // parameters (`game`, `payload`) the topo-sorted node bodies
        // actually mention. Zig 0.16 rejects both an unused parameter
        // *and* a pointless `_ = x;` discard of a used one — the buffer
        // pattern is the same one `renderEntryFunction` already uses.
        var body_aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer body_aw.deinit();
        try emitBody(allocator, &body_aw.writer, ctx, flow_name, true);
        const body = try body_aw.toOwnedSlice();
        defer allocator.free(body);

        // Discard the param/binding when the body never reads it.
        if (!mentionsIdent(body, "game")) try w.writeAll("        _ = game;\n");
        if (!mentionsIdent(body, "payload")) try w.writeAll("        _ = payload;\n");

        try indentBlock(w, body, "    ");
        try w.writeAll("    }\n");
        try w.writeAll("};\n");
        return;
    }

    // Multi-trigger flow — one `FlowEventHandler` struct, one `pub fn`
    // per Event node, each method dispatching to a shared `bodyImpl`
    // helper that runs the topo-sorted downstream node bodies (RFC §3,
    // open question O2). Per-event payload aliases (`__EvPayload_<tag>`)
    // keep each method's signature accurate against `PluginEvents`; the
    // helper takes only `game` because the shared body cannot bind to a
    // single payload shape across distinct triggers.
    //
    // De-duplicate trigger names — a flow declaring the same event on
    // two nodes is a structural duplicate (one method per event variant
    // is what `MergeHooks.emit` dispatches against; emitting it twice
    // would be a duplicate decl). `qualified_seen` is a name set;
    // `qualified_storage` keeps the appearance order so the emitted
    // method order matches the document order.
    var qualified_seen: std.StringHashMap(void) = .init(allocator);
    defer qualified_seen.deinit();
    var qualified_storage: std.ArrayList([]u8) = .empty;
    defer {
        for (qualified_storage.items) |q| allocator.free(q);
        qualified_storage.deinit(allocator);
    }
    for (trigger_names.items) |dotted| {
        const q = try qualifiedTagFromDotted(allocator, dotted);
        const gop = try qualified_seen.getOrPut(q);
        if (gop.found_existing) {
            allocator.free(q);
            continue;
        }
        try qualified_storage.append(allocator, q);
    }

    // Per-event payload alias — `__EvPayload_<qualified>`. Same
    // `@FieldType` reflection as the single-event path; the compiler
    // catches an unknown tag against the `PluginEvents` field set.
    for (qualified_storage.items) |q| {
        try w.print(
            "const __EvPayload_{s} = @FieldType(PluginEvents, \"{s}\");\n",
            .{ q, q },
        );
    }
    try w.writeAll("\n");

    try w.writeAll("pub const FlowEventHandler = struct {\n");
    try w.writeAll("    game_ptr: *anyopaque = undefined,\n\n");

    // One dispatch method per Event node. The body is a discard of the
    // unused `payload` (each method picks one event's payload shape,
    // but the shared body can't bind to a specific one) + a call into
    // `bodyImpl(game)`. Same `*Game` downcast every shipped handler
    // uses (`labelle-engine/src/game.zig:419-429`).
    for (qualified_storage.items) |q| {
        try w.print(
            "    pub fn {s}(self: *@This(), payload: __EvPayload_{s}) void {{\n",
            .{ q, q },
        );
        try w.writeAll("        const game: *Game = @ptrCast(@alignCast(self.game_ptr));\n");
        try w.writeAll("        _ = payload;\n");
        try w.writeAll("        bodyImpl(game);\n");
        try w.writeAll("    }\n\n");
    }

    // `bodyImpl(game: *Game) void` — the shared helper. Takes the
    // already-downcast `*Game` so each dispatch method does the
    // `@ptrCast` once, not the helper itself; this also keeps the
    // helper independent of `*anyopaque` so callers outside the struct
    // (the test harness, future opt-in inline-flow inspection) can
    // exercise it directly. `fn` (not `pub fn`) — the helper is a
    // codegen implementation detail.
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_aw.deinit();
    try emitBody(allocator, &body_aw.writer, ctx, flow_name, true);
    const body = try body_aw.toOwnedSlice();
    defer allocator.free(body);

    try w.writeAll("    fn bodyImpl(game: *Game) void {\n");
    if (!mentionsIdent(body, "game")) try w.writeAll("        _ = game;\n");
    try indentBlock(w, body, "    ");
    try w.writeAll("    }\n");
    try w.writeAll("};\n");
}

/// Prepend `indent` to every non-empty line in `body` so a buffered
/// function body (rendered with the lifecycle handler's `    ` prefix)
/// nests one more level inside the new-form handler's enclosing
/// `pub fn <tag>` block. Empty lines stay empty so the output keeps a
/// clean look.
fn indentBlock(w: *std.Io.Writer, body: []const u8, indent: []const u8) !void {
    var it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |line| {
        if (first) {
            first = false;
        } else {
            try w.writeByte('\n');
        }
        if (line.len > 0) {
            try w.writeAll(indent);
            try w.writeAll(line);
        }
    }
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// True when `ident` appears in `src` as a whole identifier token —
/// not flanked by an identifier character on either side. Lets the
/// entry-function renderer tell a referenced parameter from an unused
/// one without a real parser.
fn mentionsIdent(src: []const u8, ident: []const u8) bool {
    if (ident.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, ident)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(src[pos - 1]);
        const after = pos + ident.len;
        const after_ok = after >= src.len or !isIdentChar(src[after]);
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

/// Emit one subgraph as a `fn` (RFC §6): params → fn args, `Output`
/// nodes → return value, body in topo order.
fn renderSubgraphFunction(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    flow: flow_io.Flow,
    registry: *const FlowRegistry,
    custom_nodes: ?*const CustomNodeRegistry,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var ctx = try GraphContext.init(allocator, flow, registry, custom_nodes);
    defer ctx.deinit();

    // A subgraph has no `entity` in scope — only declared params. An
    // entity-scoped node (`GetComponent` / `SetField`) must wire its
    // `entity` input pin (RFC-PLUGIN-EVENTS §9); an unwired one is
    // `DanglingPin` against the offending node. A wired one is fine —
    // the wired expression is what `writeNodeBody` emits as the
    // entity argument.
    try assertEntityAvailable(flow);

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

    // Signature: `fn <symbol>(game: anytype, <param>: <type>, …) <ret> {`
    try w.print("fn {s}(game: anytype", .{symbol});
    try writeParamArgs(allocator, w, flow.params);
    try w.writeAll(") ");
    try writeReturnType(w, symbol, outputs);
    try w.writeAll(" {\n");

    try emitBody(allocator, w, &ctx, flow.name, true);

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

/// Emit the topo-sorted node bodies for a flow into `w`. `emit_preview`
/// gates the per-node `emitNodeEntered` pulse — it reads `game`, so an
/// `OnEvent` handler (which has no `game`) passes `false`.
///
/// `Event` nodes (RFC-FLOW-VOCABULARY §3) are graph triggers and emit
/// no body — they're dropped here so they participate in neither the
/// preview pulse nor the body lowering.
fn emitBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (ctx.order) |id| {
        const node = ctx.index.byId(id) orelse unreachable;
        if (node.kind == .Event) continue;
        if (emit_preview) try writePreviewPulse(w, flow_name, node.id);
        try writeNodeBody(w, node, ctx, scratch.allocator());
        try discardUnconsumedResult(w, node, ctx);
        _ = scratch.reset(.retain_capacity);
    }
}

/// Emit `_ = n<id>_<pin>;` for a node whose result value is bound to a
/// `const` but read by no downstream edge — e.g. a terminal `Call`
/// invoked purely for its side effect. Without this the unreferenced
/// `const` is an "unused local constant" compile error. Nodes that
/// emit a bare statement (`SetField`, a void `Subflow`) and `Output`
/// nodes bind no value and are skipped.
fn discardUnconsumedResult(
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

// =====================================================================
// Graph context — index + topo order, shared by entry & subgraph paths
// =====================================================================

const GraphContext = struct {
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

    fn init(
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
            if (!isInputPin(consumer.kind, e.to.pin)) return error.UnknownPin;
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
        // An OnCall flow used as the file entry point still needs a
        // callable surface — emit `pub fn onCall`.
        .OnCall => try w.writeAll("pub fn onCall(game: anytype"),
        // `OnEvent` flows are emitted by `renderEventEntry`, which
        // never calls this header writer.
        .OnEvent => unreachable,
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
        // `GetComponent` and `SetField` resolve their entity argument
        // through the optional `entity` input pin (RFC-PLUGIN-EVENTS
        // §9). A wired pin overrides the in-scope `entity`; an unwired
        // pin in a flow with no `entity` in scope is `DanglingPin` —
        // caught up-front by `assertEntityAvailable` so the per-node
        // emission can assume the binding exists.
        .GetComponent => |b| {
            const entity_expr = (try ctx.resolveInput(scratch, node, "entity")) orelse
                try scratch.dupe(u8, "entity");
            try w.print(
                "    const n{d}_value = game.getComponent({s}, {s}) orelse return;\n",
                .{ node.id, entity_expr, b.type },
            );
        },
        .SetField => |b| {
            const dot = std.mem.lastIndexOfScalar(u8, b.target, '.') orelse return error.UnknownPin;
            const type_name = b.target[0..dot];
            const field_name = b.target[dot + 1 ..];
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            const entity_expr = (try ctx.resolveInput(scratch, node, "entity")) orelse
                try scratch.dupe(u8, "entity");
            try w.print(
                "    game.setField({s}, .{s}, {s}, {s});\n",
                .{ type_name, field_name, entity_expr, value_expr },
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
        // `Emit` lowers to `game.emit(.{ .<qualified_tag> = .{...} })`
        // (RFC-PLUGIN-EVENTS §8). The payload's field set is the set
        // of edges wired into the node — each input pin's name is a
        // payload field — and the qualified tag is the dotted
        // `event` mapped mechanically (`.` → `__`) to match the
        // `PluginEvents` variant the assembler emits
        // (labelle-assembler#174). Buffered (`game.emit`, not
        // `emitSync`) per RFC §4 / §8 — the default that every
        // shipped #422 use site uses; a `sync = true` opt-in is
        // tracked for a later phase. No output pin: statement, not
        // expression.
        //
        // Field-shape validation rides through the Zig compiler — an
        // edge wired into a pin named after a non-existent payload
        // field surfaces as an "unknown field" error against the
        // generated `.{ .foo = ... }` literal; a missing required
        // field surfaces as a "missing field" error against the
        // resolved `__EvPayload` type. The resolver IS the union, so
        // there is no second source of truth to keep in sync.
        .Emit => |b| {
            const qualified = try scratch.alloc(u8, b.event.len + countByte(b.event, '.'));
            {
                var i: usize = 0;
                for (b.event) |c| {
                    if (c == '.') {
                        qualified[i] = '_';
                        qualified[i + 1] = '_';
                        i += 2;
                    } else {
                        qualified[i] = c;
                        i += 1;
                    }
                }
            }

            // Collect the wired-pin edges going into this node, in
            // ascending-pin-name order so the emitted struct literal is
            // deterministic (the same payload wired the same way always
            // produces byte-identical output — matters for git diffs
            // and Ast.parse stability).
            var pins: std.ArrayList(*const flow_io.Edge) = .empty;
            defer pins.deinit(scratch);
            for (ctx.flow.edges) |*e| {
                if (e.to.node == node.id) try pins.append(scratch, e);
            }
            std.mem.sort(*const flow_io.Edge, pins.items, {}, struct {
                fn lt(_: void, lhs: *const flow_io.Edge, rhs: *const flow_io.Edge) bool {
                    return std.mem.order(u8, lhs.to.pin, rhs.to.pin) == .lt;
                }
            }.lt);

            // A wireless `Emit` lowers to `game.emit(.{ .<tag> = .{} });`
            // — a payload type with no fields trivially typechecks; one
            // with fields surfaces a "missing field" error at compile
            // time. Same one-line shape either way so the diagnostic is
            // sourced against the generated line, not buried in a
            // multi-line literal.
            if (pins.items.len == 0) {
                try w.print(
                    "    game.emit(.{{ .{s} = .{{}} }});\n",
                    .{qualified},
                );
            } else {
                try w.print("    game.emit(.{{ .{s} = .{{\n", .{qualified});
                for (pins.items) |edge| {
                    const consumer = ctx.index.byId(node.id) orelse unreachable;
                    const expr = (try ctx.resolveInput(scratch, consumer, edge.to.pin)) orelse
                        return error.DanglingPin;
                    try w.print("        .{s} = {s},\n", .{ edge.to.pin, expr });
                }
                try w.writeAll("    } });\n");
            }
        },
        // The graph-trigger `Event` node carries no body — it
        // identifies the flow's trigger (the loader synthesizes the
        // file's `event:` from it) but doesn't itself emit Zig.
        // `emitBody` filters it out of the topo order so this arm is
        // a defensive no-op.
        .Event => {},
        // `GetVariable` reads the file-scope `var`. Its declared
        // identifier is the variable name verbatim (variables are
        // already Zig identifiers per the `Variable.name` contract).
        .GetVariable => |b| try w.print(
            "    const n{d}_value = {s};\n",
            .{ node.id, b.name },
        ),
        // `SetVariable` writes the wired `value` into the file-scope
        // `var`. The `value` pin MUST be wired — `SetVariable` with no
        // input is `DanglingPin` (unlike `ChangeVariable` whose `by`
        // has an inline default).
        .SetVariable => |b| {
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    {s} = {s};\n",
                .{ b.name, value_expr },
            );
        },
        // `ChangeVariable` increments the file-scope `var` by the
        // wired `by` pin — or, when the pin is unwired, by the inline
        // `by` literal stored on the node (defaults to `"1"`). This
        // matches Scratch's "change X by [1]" block: the `1` lives on
        // the node itself, no edge required.
        //
        // The lowering is `var += by` (numerics) or `var = var != by`
        // (boolean toggle). v1 doesn't distinguish at codegen time —
        // `+=` typechecks for `i32`/`f32` and the boolean form is left
        // for a follow-up node; a user wiring `ChangeVariable` to a
        // `bool` variable today gets a Zig type error at compile time.
        //
        // A `DEBUG`-mode print is emitted after the change so the
        // running counter is visible without a sidecar `.zig` (the
        // RFC's goal: collapse `setTotal`'s `std.debug.print` into
        // the codegen itself). `builtin.mode == .Debug` keeps release
        // builds silent. The format `{s}: {d}\n` uses the variable
        // name as the label — matches the "counts ball hits live"
        // verification format.
        .ChangeVariable => |b| {
            const by_expr = (try ctx.resolveInput(scratch, node, "by")) orelse
                try scratch.dupe(u8, b.by);
            try w.print(
                "    {s} += {s};\n",
                .{ b.name, by_expr },
            );
            try w.print(
                "    if (@import(\"builtin\").mode == .Debug) std.debug.print(\"{s}: {{d}}\\n\", .{{{s}}});\n",
                .{ b.name, b.name },
            );
        },
        // `ClearVariable` writes the bare `null` keyword into the
        // nullable variable (RFC-FLOW-VOCABULARY §4 — nullable variable
        // operations). The flow-layer nullability check happened in
        // `flow_io.validate`; here the type signal is the keyword
        // `null` itself, which Zig accepts as the initial / cleared
        // value of any `?T`.
        .ClearVariable => |b| try w.print(
            "    {s} = null;\n",
            .{b.name},
        ),
        // `HasValueVariable` lowers to a `bool`-typed local — the
        // `<var> != null` test (RFC-FLOW-VOCABULARY §4 — nullable
        // variable operations). The reporter shape mirrors
        // `GetVariable`: one `n<id>_value` binding consumers read
        // through their input pins.
        .HasValueVariable => |b| try w.print(
            "    const n{d}_value = {s} != null;\n",
            .{ node.id, b.name },
        ),
        // `CustomNode` lowers to a call against the assembler-emitted
        // `game_mod.PluginFlowNodes.<qualified>.impl` (RFC-FLOW-VOCABULARY
        // §1 + §5). The dotted name on the node maps to the qualified
        // decl through the `CustomNodeRegistry` (built by the assembler
        // from its phase-2 discovery walk); an unknown name is
        // `UnknownFlowNode` here rather than a vaguer Zig compile error
        // against a missing decl.
        //
        // Pins are positional, named `arg0`/`arg1`/... matching the
        // `Call` node convention (and counted the same way via
        // `countCallArgs`). Unwired pins resolve to `undefined` — Zig's
        // type-checker catches the mismatch against the impl's actual
        // signature, which is the source of truth for arity at compile
        // time of the generated file.
        //
        // Command vs reporter shape is keyed off the registry's
        // `is_void` flag (RFC §6 — "defaults from `impl`'s return
        // type"): a `void` impl emits a bare statement; a value-
        // returning impl binds the result to `n<id>_value` so downstream
        // pins can wire from it. The `kind` override on the FlowNode
        // factory is editor-side metadata; codegen ignores it.
        .CustomNode => |b| {
            const reg = ctx.custom_nodes orelse return error.UnknownFlowNode;
            const entry = reg.get(b.name) orelse return error.UnknownFlowNode;

            const arity = countCallArgs(ctx.flow, node.id);
            // Reach `impl` through the registry entry's TYPE, not the value.
            // `PluginFlowNodes.<q>` is a FlowNode *value*; `value.impl(game, …)`
            // would trip Zig's method-call syntax and bind the value as impl's
            // first parameter (`game`), shifting every real arg. `@TypeOf(...)`
            // gives the FlowNodeReturn struct type, so `Type.impl(game, …)` is a
            // plain namespaced call with no receiver to bind (flow-codegen#28).
            if (entry.is_void) {
                try w.print(
                    "    @TypeOf(game_mod.PluginFlowNodes.{s}).impl(game",
                    .{entry.qualified},
                );
            } else {
                try w.print(
                    "    const n{d}_value = @TypeOf(game_mod.PluginFlowNodes.{s}).impl(game",
                    .{ node.id, entry.qualified },
                );
            }
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                try w.writeAll(", ");
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
        // `GetVariable` is a reporter (RFC-FLOW-VOCABULARY §4) — its
        // single output pin is `value`, the same shape as `Literal` /
        // `Identifier` / `GetComponent`. `SetVariable` /
        // `ChangeVariable` are commands and bind no value (same as
        // `SetField` / `Emit` / `Output`); the `Event` node is the
        // graph trigger and is dropped from the body entirely (see
        // `emitBody`).
        .GetVariable => "value",
        // `HasValueVariable` is a reporter (RFC-FLOW-VOCABULARY §4 —
        // nullable variable operations) — single output pin `value` of
        // type `bool`, the same naming as `GetVariable`.
        .HasValueVariable => "value",
        // `CustomNode` is the plugin-declared verb (RFC-FLOW-VOCABULARY
        // §1 + §5). When the impl returns a value, the binding name is
        // `n<id>_value` (matching the reporter naming convention shared
        // with `GetVariable` / `Literal` / `Identifier`); when the impl
        // returns `void` the node emits a bare statement and the value
        // pin is `""`. The branch is resolved at emission time from the
        // `CustomNodeRegistry`, but the output-pin name for downstream
        // pin resolution stays `value` either way — Zig's type-checker
        // catches a wire from a void impl's pin against the generated
        // call site. `discardUnconsumedResult` consults the registry
        // through the producer-node lookup to know whether a discard
        // line is needed.
        .CustomNode => "value",
        // `Emit` lowers to a statement, not an expression — it has no
        // output pin (RFC-PLUGIN-EVENTS §8); same as `SetField` /
        // `Output`. Skipped by `discardUnconsumedResult`. `ClearVariable`
        // is a command (RFC-FLOW-VOCABULARY §4) — it writes the bare
        // `null` keyword into the variable and binds no value.
        .SetField, .Output, .Emit, .Event, .SetVariable, .ChangeVariable, .ClearVariable => "",
    };
}

fn isInputPin(k: flow_io.NodeKind, pin: []const u8) bool {
    return switch (k) {
        // `GetComponent` accepts an optional `entity` input pin
        // (RFC-PLUGIN-EVENTS §9) — when wired it overrides the
        // in-scope `entity` identifier. No other inputs.
        .GetComponent => std.mem.eql(u8, pin, "entity"),
        .Literal, .Identifier, .Param, .GetVariable => false,
        // `SetField` takes `value` (existing) and the same optional
        // `entity` pin as `GetComponent` (RFC-PLUGIN-EVENTS §9).
        .SetField => std.mem.eql(u8, pin, "value") or std.mem.eql(u8, pin, "entity"),
        .Output => std.mem.eql(u8, pin, "value"),
        .BinOp => std.mem.eql(u8, pin, "a") or std.mem.eql(u8, pin, "b"),
        .Call => isCallArgPin(pin),
        // A Subflow's input pins are its referenced flow's params —
        // any non-empty name is accepted here; an unknown param is
        // caught against the registry at emit time.
        .Subflow => pin.len != 0,
        // `Emit`'s input pins are the resolved payload struct's
        // fields — the assembler's resolver is the source of truth
        // (RFC-PLUGIN-EVENTS §8). The structural validator here
        // accepts any non-empty name; an unwired-or-unknown field is
        // caught at codegen against the generated `.{ .field = ... }`
        // literal (Zig's compiler reports the unknown/missing field
        // against the resolved `PluginEvents` variant type).
        .Emit => pin.len != 0,
        // The `Event` node is the graph trigger — it has no input
        // pins (the file-level event source is what defines the
        // payload; payload fields surface as the node's *output* pins,
        // tracked separately by the editor — codegen drops the node
        // from the body entirely so no input edges should target it).
        .Event => false,
        // `SetVariable` consumes the wired `value`; `ChangeVariable`
        // consumes the wired `by` (or its inline-default `by` literal
        // when no edge is present — see `writeNodeBody`).
        .SetVariable => std.mem.eql(u8, pin, "value"),
        .ChangeVariable => std.mem.eql(u8, pin, "by"),
        // `ClearVariable` is a no-input command — it writes the bare
        // `null` keyword. `HasValueVariable` is a no-input reporter —
        // its single output pin is `value` (the `<var> != null` test).
        .ClearVariable, .HasValueVariable => false,
        // `CustomNode` input pins are positional, named `argN` (the
        // same convention as `Call`). Any well-formed pin name is
        // accepted here; the impl's actual signature is the source of
        // truth for arity at compile time of the generated `.zig` —
        // Zig's type-checker catches mismatches against the call site.
        .CustomNode => isCallArgPin(pin),
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
        .OnCall => "onCall",
        // An `OnEvent` flow's public entry is its `setup` — the
        // registrar the script-runner calls (see `renderEventEntry`).
        .OnEvent => "setup",
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
/// with each other or with the fixed `game` parameter. Such a flow
/// parses cleanly yet emits a signature with duplicate parameter
/// identifiers, which Zig rejects (`ParamNameCollision`). Post Phase 6
/// (RFC-FLOW-VOCABULARY) the only fixed parameter on every emitted
/// signature is `game` — the lifecycle dt/entity args are gone, and an
/// `OnEvent` handler's payload pins are derived names that don't
/// collide with declared params.
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

    try putOwnedKey(allocator, &seen, "game");

    for (flow.params) |p| {
        const name = try sanitizeSymbol(allocator, p.name);
        const gop = try seen.getOrPut(name);
        if (gop.found_existing) {
            allocator.free(name);
            return error.ParamNameCollision;
        }
    }
}

/// True when `node` is entity-scoped and has no incoming edge on its
/// optional `entity` input pin (RFC-PLUGIN-EVENTS §9). In a context
/// where no `entity` identifier is in scope (an `OnCall` entry or a
/// `Subflow`-referenced subgraph), this is the per-node `DanglingPin`
/// signal — the v1 blanket-rejection refined to a node-level check.
fn entityScopedAndUnwired(flow: flow_io.Flow, node: flow_io.Node) bool {
    switch (node.kind) {
        .GetComponent, .SetField => {},
        else => return false,
    }
    for (flow.edges) |e| {
        if (e.to.node == node.id and std.mem.eql(u8, e.to.pin, "entity")) return false;
    }
    return true;
}

/// Reject an entity-scoped node missing both an entity-pin wire and an
/// in-scope `entity` identifier (RFC-PLUGIN-EVENTS §9). Called from the
/// `OnCall` entry path and `renderSubgraphFunction` — both contexts
/// where `entity` is not a function parameter. Returns `DanglingPin`
/// against the first offending node so the diagnostic points at a
/// specific `.flow.jsonc` location, per the RFC §9 per-node check that
/// lets a flow mix wired and unwired entity-scoped nodes freely.
fn assertEntityAvailable(flow: flow_io.Flow) CodegenError!void {
    for (flow.nodes) |n| {
        if (entityScopedAndUnwired(flow, n)) return error.DanglingPin;
    }
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
