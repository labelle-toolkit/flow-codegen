//! Read/write loader for the Flow editor (`.flow.jsonc` files).
//!
//! Flows are authored, hand-edited, on-disk files that describe a
//! graph of nodes wired together by pins. `codegen.zig` consumes a
//! `Flow` and emits a Zig source file.
//!
//! ## Format — `.flow.jsonc` (RFC-FLOWS-JSONC.md §1, §2)
//!
//! As of the `.flow.jsonc` RFC the on-disk format is JSONC (JSON with
//! `//` / `/* */` comments and trailing commas) and the node schema is
//! **flat**: a node is `{ "id", "type", "pos", …params }` — no
//! tagged-union `kind` wrapper. The link list is named `edges`.
//!
//! ```jsonc
//! {
//!   "name": "enemy_tick",
//!   "event": { "type": "OnUpdate", "arg_dt": "dt" },
//!   "params": [
//!     { "name": "damage", "type": "f32", "default": 10.0 }
//!   ],
//!   "nodes": [
//!     { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] },
//!     { "id": 2, "type": "BinOp", "op": "add", "pos": [0, 0] }
//!   ],
//!   "edges": [
//!     { "from": { "node": 1, "pin": "x" }, "to": { "node": 2, "pin": "a" } }
//!   ]
//! }
//! ```
//!
//! ## New node types (RFC §3)
//!
//! - `Param`   — yields a declared parameter's value as a pin output.
//! - `Output`  — names one of the flow's result pins.
//! - `Subflow` — references another flow by registry name; binds the
//!   referenced flow's `params` via `bindings` literals or wired pins.
//!
//! Ownership: a heap-allocated arena owns every slice the `Flow`
//! references; the caller frees both via `LoadedFlow.deinit()`.

const std = @import("std");
const jsonc = @import("jsonc.zig");

/// Event entry point for a flow. Per RFC-FLOW-VOCABULARY §3 (Phase 6),
/// event-driven flows declare their trigger as an in-graph `Event` node;
/// the loader synthesizes `Flow.event = .{ .OnEvent = ... }` from the
/// node's name so downstream consumers (assembler `flow_scanner`,
/// codegen's `FlowEventHandler` path) keep working unchanged. The
/// legacy file-level `event:` header is retained for one case only:
/// `OnCall` (RFC §3) — the entry point for a *subgraph* invoked by a
/// `Subflow` node rather than dispatched by an event.
pub const Event = union(enum) {
    /// Subgraph entry point (RFC §3). Set via the file-level
    /// `event: { "type": "OnCall" }` header.
    OnCall,
    /// Synthesized from an in-graph `Event` node (RFC-FLOW-VOCABULARY §3).
    /// `name` is the dotted event name (`"box2d.collision_begin"`,
    /// `"engine.tick"`). Resolution is the assembler's comptime
    /// `name → variant-type` pass over the merged
    /// `PluginEvents`/`GameEvents` union (RFC-PLUGIN-EVENTS §2, §7);
    /// codegen reflects the payload type out of the union and emits a
    /// hook-handler-struct method (`renderNewFormEventEntry`).
    ///
    /// The legacy file-level `event: { "type": "OnEvent", ... }` header
    /// was retired in Phase 6 (RFC-FLOW-VOCABULARY) alongside the
    /// lifecycle headers (`OnUpdate`/`OnCreate`/`OnDestroy`); every
    /// event-driven flow now uses the Event-node-in-graph form.
    OnEvent: struct {
        /// Plugin-qualified event name (`"box2d.collision_begin"`).
        /// Populated by the loader from the in-graph `Event` node's
        /// `name` field. Nullable in the type for parser-side
        /// construction reasons; non-null whenever the flow has been
        /// validated (the empty-name case is rejected upstream).
        name: ?[]const u8 = null,
        /// Optional dispatch-priority hint for **consumable** events
        /// (RFC-PLUGIN-EVENTS O4, phase 7 — labelle-core#16). Meaningful
        /// only when the resolved event is consumable (the payload
        /// declares `pub const consumable = true;`); the assembler sorts
        /// flow handlers whose `priority` is set ahead of the
        /// scanner-sorted tail, priority-descending, so the
        /// highest-priority listener fires first. The runtime
        /// `MergeHooks.emit` (`labelle-core/src/dispatcher.zig`) switches
        /// to the return-aware path automatically for consumable
        /// variants and breaks on the first `true`-returning handler.
        /// For notification events the assembler ignores the field — the
        /// scanner sort holds (O3). `null` means "no hint"; for a
        /// consumable event that is the lowest-precedence bucket.
        priority: ?i32 = null,
    },
};

/// Binary operator for `NodeKind.BinOp`.
pub const BinOpKind = enum { add, sub, mul, div };

/// Comparison operator for `NodeKind.Compare` — binary, produces a
/// `bool`. (flow-codegen#7)
pub const CompareKind = enum { eq, ne, lt, le, gt, ge };

/// Boolean operator for `NodeKind.Logic` — produces a `bool`. `not` is
/// unary (only the `a` pin); `@"and"`/`@"or"` are binary. (flow-codegen#7)
pub const LogicKind = enum { @"and", @"or", not };

/// On-disk position. `[120, 80]` in JSONC. Index 0 is x, 1 is y.
pub const Pos = [2]f32;

/// A literal value supplied for a parameter — either as a `param`
/// `default` or as a `Subflow` `binding`. JSON-native (RFC §3): the
/// value is stored as the source text of a Zig expression so codegen
/// can emit it verbatim. `parseParamLiteral` derives this from a
/// `std.json.Value`.
pub const Literal = struct {
    /// Zig source text — e.g. `"10"`, `"10.5"`, `"true"`,
    /// `"\"hello\""` (a quoted string literal).
    zig_text: []const u8,
};

/// A declared input parameter of a (sub)flow — its public interface
/// (RFC §3). `default` is optional; a param with no default that is
/// neither wired nor bound at a call site is a load-time error.
pub const Param = struct {
    name: []const u8,
    /// Zig type name — `"f32"`, `"i32"`, `"bool"`, … (RFC open
    /// question 2: scalars in v1).
    type: []const u8,
    default: ?Literal = null,
};

/// One binding on a `Subflow` node: a literal value for a parameter
/// pin left unwired (RFC §3 precedence rule 2).
pub const Binding = struct {
    param: []const u8,
    value: Literal,
};

/// Kind discriminator + per-kind payload for a flow node.
///
/// v1 node catalog:
///   - GetComponent / SetField — read and write ECS state
///   - BinOp                  — arithmetic combinator
///   - Literal / Identifier   — verbatim expression / bare name
///   - Call                   — invoke a function by name
///   - Param                  — read a declared parameter (RFC §3)
///   - Output                 — name a result pin (RFC §3)
///   - Subflow                — reference another flow (RFC §3)
///   - Emit                   — fire a custom event (RFC-PLUGIN-EVENTS §8)
pub const NodeKind = union(enum) {
    GetComponent: struct { type: []const u8 },
    SetField: struct { target: []const u8 },
    BinOp: struct { op: BinOpKind },
    Compare: struct { op: CompareKind },
    Logic: struct { op: LogicKind },
    Literal: struct { value: []const u8 },
    Identifier: struct { name: []const u8 },
    Call: struct { callee: []const u8 },
    Param: struct { param: []const u8 },
    /// `Output` names a result pin (RFC §3). The `type` field holds
    /// the Zig type of that result — needed so codegen can write a
    /// concrete function return type (RFC §6). On disk it is the
    /// `"value_type"` key (the node's `"type"` key is the kind
    /// discriminator); optional, defaults to `f32`. Precise type
    /// inference through the pin type-system is RFC open question 2
    /// / #44.
    Output: struct { name: []const u8, type: []const u8 = "f32" },
    Subflow: struct {
        /// Effective name of the referenced flow in the flow registry.
        flow: []const u8,
        /// Literal bindings for unwired param pins. Owned by the arena.
        bindings: []Binding = &.{},
    },
    /// `Emit` fires a custom event (RFC-PLUGIN-EVENTS §8). `event` is
    /// the dotted name (`"<plugin>.<event>"` for plugin events, or the
    /// bare name for game-scanned `events/*.zig` events) — resolved by
    /// the assembler's comptime name resolver (phase 1). The node's
    /// input pins are the payload struct's fields, reflected at codegen
    /// time; lowering deferred until the resolver lands.
    Emit: struct { event: []const u8 },
    /// `Event` — graph-level trigger (RFC-FLOW-VOCABULARY §3 — events
    /// as first-class graph nodes). Replaces the file-level `event:`
    /// header for new-form flows; the loader synthesizes
    /// `Flow.event = .{ .OnEvent = .{ .name = <node.name> } }` so
    /// existing consumers (assembler `flow_scanner`, codegen's
    /// `FlowEventHandler` path) keep working unchanged.
    ///
    /// Codegen *drops* the in-graph node from the rendered body — it
    /// is the trigger, not a value-producing node — so it doesn't
    /// participate in topo sort or pin resolution.
    Event: struct { name: []const u8 },
    /// `GetVariable` — reporter (RFC-FLOW-VOCABULARY §4). Reads a
    /// declared `Variable` by name, output pin `value` typed to the
    /// variable's declared `type`.
    GetVariable: struct { name: []const u8 },
    /// `SetVariable` — command (RFC-FLOW-VOCABULARY §4). Writes the
    /// wired `value` input pin into the declared `Variable`.
    SetVariable: struct { name: []const u8 },
    /// `ChangeVariable` — command (RFC-FLOW-VOCABULARY §4). Increments
    /// the declared numeric/boolean `Variable` by the wired `by` input
    /// pin (or by the inline `by` literal when no wire is present).
    /// For numerics: `var += by`; for `bool`: `var = var != by` (XOR
    /// toggle when `by == true`).
    ///
    /// Inline `by` matches Scratch's "change X by [1]" block, where the
    /// `1` is part of the node itself; no edge is required for the
    /// kid path. Defaults to `"1"` (the most common case — increment
    /// by one) when absent.
    ChangeVariable: struct { name: []const u8, by: []const u8 = "1" },
    /// `ClearVariable` — command (RFC-FLOW-VOCABULARY §4 — nullable
    /// variable operations). Sets the named `?T` variable to `null`.
    /// Validated against the `variables` block: the named variable must
    /// exist (`UnknownVariable`) and its declared `type` must start with
    /// `?` (`MalformedFlow`) — clearing a non-nullable variable is a
    /// type error at the flow layer.
    ClearVariable: struct { name: []const u8 },
    /// `HasValueVariable` — reporter (RFC-FLOW-VOCABULARY §4 — nullable
    /// variable operations). Output pin `value` of type `bool`, lowering
    /// to `<var> != null`. Same nullability check as `ClearVariable`.
    HasValueVariable: struct { name: []const u8 },
    /// `CustomNode` — plugin- or game-script-declared flow node
    /// (RFC-FLOW-VOCABULARY §1 + §5). References an entry in the
    /// assembler-emitted `PluginFlowNodes` registry by dotted name
    /// (`"box2d.apply_impulse"`, `"my_helpers.print_score"`). The
    /// assembler's resolver maps the dotted form to the qualified
    /// `<module>__<name>` decl on `game_mod.PluginFlowNodes`; codegen
    /// reflects on that decl's `impl` to derive the function's
    /// signature — input pins by position (excluding the first
    /// `game: anytype` param), output pin from the return type
    /// (or no output for `void` impls).
    ///
    /// `validate` accepts any non-empty name; codegen rejects unknown
    /// names against the registry as `UnknownFlowNode`.
    CustomNode: struct { name: []const u8 },
};

/// One node in a flow graph. `id` is unique within a single file
/// (RFC §3 — "ids are unique only within a single file").
pub const Node = struct {
    id: u32,
    pos: Pos,
    kind: NodeKind,
};

/// One end of an `Edge` — a node id plus a pin name.
pub const PinRef = struct {
    node: u32,
    pin: []const u8,
};

/// A directed connection between two pins. (Formerly `Link`; renamed
/// to `Edge` per RFC §2. `Link` is kept as an alias below.)
pub const Edge = struct {
    from: PinRef,
    to: PinRef,
};

/// Back-compat alias — codegen and tests still spell it `Link`.
pub const Link = Edge;

/// A top-level declared variable (RFC-FLOW-VOCABULARY §4). Lowers to a
/// file-scope `var <name>: <type> = <default>;` in the generated `.zig`
/// module — scoped to the flow, persistent across handler invocations,
/// invisible to other flows. `GetVariable` / `SetVariable` /
/// `ChangeVariable` node kinds read and write it.
pub const Variable = struct {
    /// Zig identifier — the variable's symbol in the generated module.
    name: []const u8,
    /// Zig source text of the variable's type — e.g. `"i32"`, `"f32"`,
    /// `"bool"`, `"?EntityId"`. Emitted verbatim by codegen.
    type: []const u8,
    /// Zig source text of the variable's initial value — e.g. `"0"`,
    /// `"true"`, `"null"`. Same encoding as `Param.default` /
    /// `Subflow.binding` literals (see `parseParamLiteral`); emitted
    /// verbatim by codegen as the right-hand side of `var x: T = …;`.
    default: Literal,
};

/// A fully parsed flow. Every slice is owned by the surrounding
/// `LoadedFlow.arena`. `name` is the effective registry key (RFC §5).
pub const Flow = struct {
    /// Effective name (RFC §5): the top-level `"name"` field, else the
    /// filename basename. Empty when neither is available.
    name: []const u8 = "",
    /// The flow's trigger. Either set from the file-level `event:`
    /// header (legacy / lifecycle path) or synthesized from an `Event`
    /// node in `nodes` (RFC-FLOW-VOCABULARY §3 — new-form flows). At
    /// most one of the two sources may be present; `buildFlow`
    /// rejects a file with both.
    event: Event,
    params: []Param = &.{},
    /// Top-level declared variables (RFC-FLOW-VOCABULARY §4). Each
    /// entry lowers to a file-scope `var <name>: <type> = <default>;`
    /// in the generated `.zig` module. Empty for flows that declare
    /// none — the default. Optional in the source file; absence is
    /// indistinguishable from `"variables": []`.
    variables: []Variable = &.{},
    nodes: []Node,
    /// Renamed from `links` per RFC §2; the field keeps the name
    /// `edges` to match the on-disk schema.
    edges: []Edge,

    /// Compatibility accessor — older codegen code reads `flow.links`.
    pub fn links(self: Flow) []Edge {
        return self.edges;
    }
};

/// Parsed flow plus the arena that owns its memory.
pub const LoadedFlow = struct {
    arena: *std.heap.ArenaAllocator,
    flow: Flow,

    pub fn deinit(self: *LoadedFlow) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub const ParseError = error{
    /// The file is not valid JSONC, or a required field is missing /
    /// has the wrong JSON type.
    MalformedFlow,
    /// A node's `"type"` string is not a known node kind.
    UnknownNodeType,
    /// An `"event"`'s `"type"` is not a known event kind.
    UnknownEventType,
    /// Two nodes share the same `id`.
    DuplicateNodeId,
    /// A node has `id == 0` (reserved for "unassigned").
    InvalidNodeId,
    /// An edge references a node id with no matching `Node`.
    DanglingLink,
    /// A `Param` node names a parameter not in the top-level `params`.
    UnknownParam,
    /// Two top-level `params` share a `name`.
    DuplicateParamName,
    /// Two `Output` nodes share a `name` (RFC §3).
    DuplicateOutputName,
    /// A flow file declares both an `event:` header and an in-graph
    /// `Event` node, or declares neither (RFC-FLOW-VOCABULARY §3 —
    /// exactly one trigger source).
    ConflictingEventSource,
    /// Reserved — formerly returned for flows with multiple `Event`
    /// nodes. Multi-trigger flows are now allowed (RFC-FLOW-VOCABULARY
    /// §3 — "A flow with multiple Event nodes is a multi-trigger flow",
    /// resolved per RFC open question O2). Kept in the public error set
    /// so downstream callers that exhaustively switch on `ParseError`
    /// continue to compile.
    MultipleEventNodes,
    /// Two top-level `variables` share a `name` (RFC-FLOW-VOCABULARY §4).
    DuplicateVariableName,
    /// A `GetVariable` / `SetVariable` / `ChangeVariable` names a
    /// variable not in the top-level `variables` block.
    UnknownVariable,
};

/// Read `path` as JSONC and parse it into a `LoadedFlow`. The flow's
/// effective name defaults to the file's basename when the file has no
/// top-level `"name"` (RFC §5).
pub fn loadFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedFlow {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    return parseFlowNamed(allocator, raw, displayNameFromPath(path));
}

/// Parse a flow's JSONC source. The effective name is taken from the
/// top-level `"name"` field if present, else left empty.
pub fn parseFlow(allocator: std.mem.Allocator, raw: []const u8) !LoadedFlow {
    return parseFlowNamed(allocator, raw, null);
}

/// Like `parseFlow`, but `fallback_name` supplies the effective name
/// when the file omits a top-level `"name"` (RFC §5 — basename rule).
pub fn parseFlowNamed(
    allocator: std.mem.Allocator,
    raw: []const u8,
    fallback_name: ?[]const u8,
) !LoadedFlow {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const json_src = try jsonc.strip(a, raw);

    var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json_src, .{}) catch {
        return error.MalformedFlow;
    };

    const flow = try buildFlow(a, &parsed, fallback_name);
    try validate(flow);

    return .{ .arena = arena, .flow = flow };
}

// =====================================================================
// JSON → typed Flow
// =====================================================================

fn buildFlow(
    a: std.mem.Allocator,
    root: *std.json.Value,
    fallback_name: ?[]const u8,
) !Flow {
    if (root.* != .object) return error.MalformedFlow;
    const obj = root.object;

    const name: []const u8 = blk: {
        if (obj.get("name")) |v| {
            if (v != .string) return error.MalformedFlow;
            break :blk try a.dupe(u8, v.string);
        }
        if (fallback_name) |fb| break :blk try a.dupe(u8, fb);
        break :blk "";
    };

    const params = try buildParams(a, obj.get("params"));
    const variables = try buildVariables(a, obj.get("variables"));
    const nodes = try buildNodes(a, obj.get("nodes") orelse return error.MalformedFlow);
    // `links` was the pre-rename (RFC §2) name for `edges`. A file
    // still using it would otherwise load with zero connections and
    // pass validation — reject the stale key rather than ignore it.
    if (obj.get("edges") == null and obj.get("links") != null) return error.MalformedFlow;
    const edges = try buildEdges(a, obj.get("edges"));

    // Resolve the flow's trigger. Per RFC-FLOW-VOCABULARY §3 (Phase 6),
    // event-driven flows declare their trigger as one or more in-graph
    // `Event` nodes; the only file-level `event:` header still allowed
    // is `event: { "type": "OnCall" }` for subgraphs. Declaring both an
    // `OnCall` header AND any Event node, or declaring neither source,
    // is `ConflictingEventSource`.
    //
    // The `Flow.event` field carries a single `Event` for back-compat
    // with downstream consumers (`flow_scanner`). For the multi-trigger
    // case we populate it from the *first* Event node by document
    // order; codegen reads the full set of Event nodes off `flow.nodes`
    // directly and emits one `FlowEventHandler` method per trigger.
    const header_event_val = obj.get("event");
    var event_node_count: usize = 0;
    var first_event_node_name: []const u8 = "";
    for (nodes) |n| if (n.kind == .Event) {
        if (event_node_count == 0) first_event_node_name = n.kind.Event.name;
        event_node_count += 1;
    };

    const event: Event = blk: {
        if (header_event_val) |v| {
            if (event_node_count != 0) return error.ConflictingEventSource;
            break :blk try buildEvent(a, v);
        }
        if (event_node_count >= 1) {
            break :blk .{ .OnEvent = .{
                .name = try a.dupe(u8, first_event_node_name),
                .priority = null,
            } };
        }
        return error.ConflictingEventSource;
    };

    return .{
        .name = name,
        .event = event,
        .params = params,
        .variables = variables,
        .nodes = nodes,
        .edges = edges,
    };
}

fn buildEvent(a: std.mem.Allocator, v: std.json.Value) !Event {
    _ = a;
    if (v != .object) return error.MalformedFlow;
    const t = (v.object.get("type") orelse return error.MalformedFlow);
    if (t != .string) return error.MalformedFlow;

    // Phase 6 (RFC-FLOW-VOCABULARY): the only file-level `event:` header
    // still accepted is `OnCall` (subgraph entry point). Every
    // event-driven flow — including the formerly lifecycle-headered
    // `OnUpdate`/`OnCreate`/`OnDestroy` and the legacy
    // `OnEvent` — must declare its trigger as an in-graph `Event` node
    // referencing a name from the assembler-emitted `<project>/.labelle/
    // flow_catalog.json` (e.g. `engine.tick`, `engine.entity_created`,
    // `engine.entity_destroyed`, `box2d.collision_begin`).
    if (std.mem.eql(u8, t.string, "OnCall")) {
        return .OnCall;
    }
    return error.UnknownEventType;
}

fn buildVariables(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Variable {
    const v = maybe orelse return &.{};
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Variable, items.len);
    for (items, 0..) |it, i| {
        if (it != .object) return error.MalformedFlow;
        const o = it.object;
        const vname = o.get("name") orelse return error.MalformedFlow;
        const vtype = o.get("type") orelse return error.MalformedFlow;
        const vdefault = o.get("default") orelse return error.MalformedFlow;
        if (vname != .string or vtype != .string) return error.MalformedFlow;
        out[i] = .{
            .name = try a.dupe(u8, vname.string),
            .type = try a.dupe(u8, vtype.string),
            .default = .{ .zig_text = try parseVariableDefault(a, vdefault) },
        };
    }
    return out;
}

/// Render a JSON-native variable default as Zig source text. Like
/// `parseParamLiteral`, but accepts JSON `null` (for nullable `?T`
/// variables) and renders it as the Zig `null` keyword.
fn parseVariableDefault(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .null => try a.dupe(u8, "null"),
        .bool => |b| if (b) "true" else "false",
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| try a.dupe(u8, s),
        // A JSON string becomes a Zig string literal — quote it. This
        // also covers the enum-tag-as-string pattern (`"idle"` →
        // `"idle"` in the Zig source; the consumer types it).
        .string => |s| try std.fmt.allocPrint(a, "\"{f}\"", .{std.zig.fmtString(s)}),
        else => error.MalformedFlow,
    };
}

fn buildParams(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Param {
    const v = maybe orelse return &.{};
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Param, items.len);
    for (items, 0..) |it, i| {
        if (it != .object) return error.MalformedFlow;
        const o = it.object;
        const pname = o.get("name") orelse return error.MalformedFlow;
        const ptype = o.get("type") orelse return error.MalformedFlow;
        if (pname != .string or ptype != .string) return error.MalformedFlow;
        var p: Param = .{
            .name = try a.dupe(u8, pname.string),
            .type = try a.dupe(u8, ptype.string),
            .default = null,
        };
        if (o.get("default")) |d| {
            p.default = .{ .zig_text = try parseParamLiteral(a, d) };
        }
        out[i] = p;
    }
    return out;
}

/// Render a JSON-native literal as Zig source text (RFC §3 — `default`
/// / `binding` are "JSON-native literals"). Only scalar literals are
/// supported in v1 (RFC open question 2 — non-scalar defaults deferred).
fn parseParamLiteral(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .bool => |b| if (b) "true" else "false",
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| try a.dupe(u8, s),
        // A JSON string becomes a Zig string literal — quote it.
        .string => |s| try std.fmt.allocPrint(a, "\"{f}\"", .{std.zig.fmtString(s)}),
        // null / array / object literals are deferred (RFC open Q 2).
        else => error.MalformedFlow,
    };
}

fn buildNodes(a: std.mem.Allocator, v: std.json.Value) ![]Node {
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Node, items.len);
    for (items, 0..) |it, i| {
        out[i] = try buildNode(a, it);
    }
    return out;
}

fn buildNode(a: std.mem.Allocator, v: std.json.Value) !Node {
    if (v != .object) return error.MalformedFlow;
    const o = v.object;

    const id_v = o.get("id") orelse return error.MalformedFlow;
    if (id_v != .integer or id_v.integer < 0) return error.MalformedFlow;
    const id: u32 = std.math.cast(u32, id_v.integer) orelse return error.MalformedFlow;

    const pos = try buildPos(o.get("pos"));

    const type_v = o.get("type") orelse return error.MalformedFlow;
    if (type_v != .string) return error.MalformedFlow;
    const kind = try buildNodeKind(a, type_v.string, o);

    return .{ .id = id, .pos = pos, .kind = kind };
}

fn buildPos(maybe: ?std.json.Value) !Pos {
    const v = maybe orelse return .{ 0, 0 };
    if (v != .array or v.array.items.len != 2) return error.MalformedFlow;
    return .{
        try jsonNumber(v.array.items[0]),
        try jsonNumber(v.array.items[1]),
    };
}

fn jsonNumber(v: std.json.Value) !f32 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| @floatCast(f),
        .number_string => |s| std.fmt.parseFloat(f32, s) catch error.MalformedFlow,
        else => error.MalformedFlow,
    };
}

/// Build a `NodeKind` from the flat node object — the per-`type`
/// payload fields live directly on the node object (RFC §2: no
/// tagged-union nesting).
fn buildNodeKind(a: std.mem.Allocator, type_name: []const u8, o: std.json.ObjectMap) !NodeKind {
    if (std.mem.eql(u8, type_name, "GetComponent")) {
        return .{ .GetComponent = .{ .type = try reqStr(a, o, "component") } };
    } else if (std.mem.eql(u8, type_name, "SetField")) {
        return .{ .SetField = .{ .target = try reqStr(a, o, "target") } };
    } else if (std.mem.eql(u8, type_name, "BinOp")) {
        const op_s = try reqStr(a, o, "op");
        const op = std.meta.stringToEnum(BinOpKind, op_s) orelse return error.MalformedFlow;
        return .{ .BinOp = .{ .op = op } };
    } else if (std.mem.eql(u8, type_name, "Compare")) {
        const op_s = try reqStr(a, o, "op");
        const op = std.meta.stringToEnum(CompareKind, op_s) orelse return error.MalformedFlow;
        return .{ .Compare = .{ .op = op } };
    } else if (std.mem.eql(u8, type_name, "Logic")) {
        const op_s = try reqStr(a, o, "op");
        const op = std.meta.stringToEnum(LogicKind, op_s) orelse return error.MalformedFlow;
        return .{ .Logic = .{ .op = op } };
    } else if (std.mem.eql(u8, type_name, "Literal")) {
        return .{ .Literal = .{ .value = try literalValue(a, o) } };
    } else if (std.mem.eql(u8, type_name, "Identifier")) {
        return .{ .Identifier = .{ .name = try reqStr(a, o, "name") } };
    } else if (std.mem.eql(u8, type_name, "Call")) {
        return .{ .Call = .{ .callee = try reqStr(a, o, "callee") } };
    } else if (std.mem.eql(u8, type_name, "Param")) {
        return .{ .Param = .{ .param = try reqStr(a, o, "param") } };
    } else if (std.mem.eql(u8, type_name, "Output")) {
        return .{ .Output = .{
            .name = try reqStr(a, o, "name"),
            // `value_type`, not `type` — `type` is the node-kind
            // discriminator field and JSON forbids duplicate keys.
            .type = if (o.get("value_type")) |tv|
                (if (tv == .string) try a.dupe(u8, tv.string) else return error.MalformedFlow)
            else
                "f32",
        } };
    } else if (std.mem.eql(u8, type_name, "Subflow")) {
        return .{ .Subflow = .{
            .flow = try reqStr(a, o, "flow"),
            .bindings = try buildBindings(a, o.get("bindings")),
        } };
    } else if (std.mem.eql(u8, type_name, "Emit")) {
        // `Emit` fires a custom event by dotted name
        // (RFC-PLUGIN-EVENTS §8). Codegen rejects an unknown name with
        // a sourced diagnostic; validate just confirms the field is
        // present — the assembler's resolver is the source of truth.
        return .{ .Emit = .{ .event = try reqStr(a, o, "event") } };
    } else if (std.mem.eql(u8, type_name, "Event")) {
        // RFC-FLOW-VOCABULARY §3 — graph-level trigger.
        return .{ .Event = .{ .name = try reqStr(a, o, "name") } };
    } else if (std.mem.eql(u8, type_name, "GetVariable")) {
        return .{ .GetVariable = .{ .name = try reqStr(a, o, "name") } };
    } else if (std.mem.eql(u8, type_name, "SetVariable")) {
        return .{ .SetVariable = .{ .name = try reqStr(a, o, "name") } };
    } else if (std.mem.eql(u8, type_name, "ChangeVariable")) {
        // `by` is the inline-default increment — defaults to `"1"`
        // when omitted (RFC-FLOW-VOCABULARY §4 — matches Scratch's
        // "change X by [1]" block). Same Zig-source-text encoding as
        // `Variable.default` / `Param.default`; an incoming wire on
        // the `by` pin still takes precedence (codegen's
        // `resolveInput` fall-through).
        return .{ .ChangeVariable = .{
            .name = try reqStr(a, o, "name"),
            .by = if (o.get("by")) |bv|
                try parseVariableDefault(a, bv)
            else
                try a.dupe(u8, "1"),
        } };
    } else if (std.mem.eql(u8, type_name, "ClearVariable")) {
        return .{ .ClearVariable = .{ .name = try reqStr(a, o, "name") } };
    } else if (std.mem.eql(u8, type_name, "HasValueVariable")) {
        return .{ .HasValueVariable = .{ .name = try reqStr(a, o, "name") } };
    } else if (std.mem.eql(u8, type_name, "CustomNode")) {
        // RFC-FLOW-VOCABULARY §1 — plugin-declared verb. The dotted
        // `name` (`"box2d.apply_impulse"`) is resolved at codegen
        // against `game_mod.PluginFlowNodes`; here we only require
        // the field is present and non-empty.
        const name = try reqStr(a, o, "name");
        if (name.len == 0) return error.MalformedFlow;
        return .{ .CustomNode = .{ .name = name } };
    }
    return error.UnknownNodeType;
}

/// `Literal.value` is Zig expression text. The on-disk `"value"` may
/// be a JSON string (already Zig text) or a JSON number/bool — in
/// which case it is rendered as a Zig literal.
fn literalValue(a: std.mem.Allocator, o: std.json.ObjectMap) ![]const u8 {
    const v = o.get("value") orelse return error.MalformedFlow;
    return switch (v) {
        .string => |s| try a.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| try a.dupe(u8, s),
        .bool => |b| if (b) "true" else "false",
        else => error.MalformedFlow,
    };
}

fn buildBindings(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Binding {
    const v = maybe orelse return &.{};
    if (v != .object) return error.MalformedFlow;
    const o = v.object;
    const out = try a.alloc(Binding, o.count());
    var it = o.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{
            .param = try a.dupe(u8, entry.key_ptr.*),
            .value = .{ .zig_text = try parseParamLiteral(a, entry.value_ptr.*) },
        };
    }
    // `std.json.ObjectMap` iteration order is not deterministic — sort
    // by param name so the in-memory order (and any `renderFlowJsonc`
    // re-save) is stable, keeping editor diffs clean (RFC open Q 3).
    std.mem.sort(Binding, out, {}, lessThanBinding);
    return out;
}

fn lessThanBinding(_: void, a: Binding, b: Binding) bool {
    return std.mem.lessThan(u8, a.param, b.param);
}

fn reqStr(a: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return error.MalformedFlow;
    if (v != .string) return error.MalformedFlow;
    return try a.dupe(u8, v.string);
}

fn buildEdges(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Edge {
    const v = maybe orelse return &.{};
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Edge, items.len);
    for (items, 0..) |it, i| {
        if (it != .object) return error.MalformedFlow;
        out[i] = .{
            .from = try buildPinRef(a, it.object.get("from")),
            .to = try buildPinRef(a, it.object.get("to")),
        };
    }
    return out;
}

fn buildPinRef(a: std.mem.Allocator, maybe: ?std.json.Value) !PinRef {
    const v = maybe orelse return error.MalformedFlow;
    if (v != .object) return error.MalformedFlow;
    const node_v = v.object.get("node") orelse return error.MalformedFlow;
    const pin_v = v.object.get("pin") orelse return error.MalformedFlow;
    if (node_v != .integer or node_v.integer < 0 or pin_v != .string) return error.MalformedFlow;
    return .{
        .node = std.math.cast(u32, node_v.integer) orelse return error.MalformedFlow,
        .pin = try a.dupe(u8, pin_v.string),
    };
}

// =====================================================================
// Validation
// =====================================================================

fn validate(flow: Flow) ParseError!void {
    // Unique, non-zero node ids.
    for (flow.nodes, 0..) |n, i| {
        if (n.id == 0) return error.InvalidNodeId;
        for (flow.nodes[i + 1 ..]) |m| {
            if (m.id == n.id) return error.DuplicateNodeId;
        }
    }

    // Unique param names.
    for (flow.params, 0..) |p, i| {
        for (flow.params[i + 1 ..]) |q| {
            if (std.mem.eql(u8, p.name, q.name)) return error.DuplicateParamName;
        }
    }

    // Unique variable names (RFC-FLOW-VOCABULARY §4).
    for (flow.variables, 0..) |v, i| {
        for (flow.variables[i + 1 ..]) |w| {
            if (std.mem.eql(u8, v.name, w.name)) return error.DuplicateVariableName;
        }
    }

    // Every edge endpoint resolves to a real node.
    for (flow.edges) |e| {
        if (!hasNode(flow.nodes, e.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, e.to.node)) return error.DanglingLink;
    }

    // `Param` nodes must name a declared parameter (RFC §3); `Output`
    // node names must be unique (RFC §3); Variable-touching nodes must
    // name a declared variable (RFC-FLOW-VOCABULARY §4).
    for (flow.nodes, 0..) |n, i| {
        switch (n.kind) {
            .Param => |b| {
                // A `Param` node names a declared flow param. (Post
                // RFC-PLUGIN-EVENTS phase 6 the legacy
                // `OnEvent.params` callback-arg path is gone; new-form
                // `OnEvent` flows read payload fields through wired
                // pins, not `Param` nodes.)
                if (!hasParam(flow.params, b.param))
                    return error.UnknownParam;
            },
            .Output => |b| {
                for (flow.nodes[i + 1 ..]) |m| {
                    if (m.kind == .Output and
                        std.mem.eql(u8, m.kind.Output.name, b.name))
                        return error.DuplicateOutputName;
                }
            },
            .GetVariable => |b| {
                if (!hasVariable(flow.variables, b.name)) return error.UnknownVariable;
            },
            .SetVariable => |b| {
                if (!hasVariable(flow.variables, b.name)) return error.UnknownVariable;
            },
            .ChangeVariable => |b| {
                if (!hasVariable(flow.variables, b.name)) return error.UnknownVariable;
            },
            // `ClearVariable` / `HasValueVariable` are the nullable-only
            // operations (RFC-FLOW-VOCABULARY §4). The named variable
            // must exist (`UnknownVariable`) AND its declared `type`
            // must start with `?` — clearing or null-testing a
            // non-nullable variable is a flow-layer type error. The
            // declared `type` text is held verbatim by `Variable.type`
            // (the loader stores it as the raw Zig source), so the
            // check is a literal first-byte sniff.
            .ClearVariable => |b| {
                const v = findVariable(flow.variables, b.name) orelse return error.UnknownVariable;
                if (v.type.len == 0 or v.type[0] != '?') return error.MalformedFlow;
            },
            .HasValueVariable => |b| {
                const v = findVariable(flow.variables, b.name) orelse return error.UnknownVariable;
                if (v.type.len == 0 or v.type[0] != '?') return error.MalformedFlow;
            },
            else => {},
        }
    }
}

fn hasVariable(variables: []const Variable, name: []const u8) bool {
    for (variables) |v| if (std.mem.eql(u8, v.name, name)) return true;
    return false;
}

/// Look up a declared variable by name — used by the nullable-only
/// validators (`ClearVariable` / `HasValueVariable`) that need to read
/// the declared `type` text. Returns `null` when not found.
fn findVariable(variables: []const Variable, name: []const u8) ?Variable {
    for (variables) |v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

fn hasNode(nodes: []const Node, id: u32) bool {
    for (nodes) |n| if (n.id == id) return true;
    return false;
}

fn hasParam(params: []const Param, name: []const u8) bool {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

// =====================================================================
// Writer
// =====================================================================

/// Render a `LoadedFlow` back to `.flow.jsonc` source. Canonical key
/// order; nodes sorted by `id`, edges sorted by endpoints, params by
/// declared order. Deterministic so editor re-saves diff cleanly
/// (RFC open question 3).
pub fn renderFlowJsonc(allocator: std.mem.Allocator, loaded: LoadedFlow) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    const flow = loaded.flow;

    try w.writeAll("{\n");

    if (flow.name.len != 0) {
        try w.writeAll("  \"name\": ");
        try writeJsonString(w, flow.name);
        try w.writeAll(",\n");
    }

    // The `event:` header is emitted only when the flow does NOT carry
    // an in-graph `Event` node (RFC-FLOW-VOCABULARY §3). When the file
    // uses the new-form trigger node, the event source lives in
    // `nodes` and the header is omitted; the loader's `buildFlow`
    // round-trips the same way.
    const has_event_node = blk: {
        for (flow.nodes) |n| if (n.kind == .Event) break :blk true;
        break :blk false;
    };
    if (!has_event_node) {
        try w.writeAll("  \"event\": ");
        try writeEvent(w, flow.event);
        try w.writeAll(",\n");
    }

    // Variables block (RFC-FLOW-VOCABULARY §4). Omitted when empty.
    if (flow.variables.len != 0) {
        try w.writeAll("  \"variables\": [\n");
        for (flow.variables, 0..) |v, i| {
            try w.writeAll("    { \"name\": ");
            try writeJsonString(w, v.name);
            try w.writeAll(", \"type\": ");
            try writeJsonString(w, v.type);
            try w.writeAll(", \"default\": ");
            try writeVariableDefault(w, allocator, v.default.zig_text);
            try w.writeAll(" }");
            if (i + 1 < flow.variables.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ],\n");
    }

    if (flow.params.len != 0) {
        try w.writeAll("  \"params\": [\n");
        for (flow.params, 0..) |p, i| {
            try w.writeAll("    { \"name\": ");
            try writeJsonString(w, p.name);
            try w.writeAll(", \"type\": ");
            try writeJsonString(w, p.type);
            if (p.default) |d| {
                try w.writeAll(", \"default\": ");
                try writeParamLiteral(w, allocator, d.zig_text);
            }
            try w.writeAll(" }");
            if (i + 1 < flow.params.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ],\n");
    }

    // Nodes, sorted by id.
    const sorted_nodes = try allocator.dupe(Node, flow.nodes);
    defer allocator.free(sorted_nodes);
    std.mem.sort(Node, sorted_nodes, {}, lessThanNode);

    try w.writeAll("  \"nodes\": [\n");
    for (sorted_nodes, 0..) |n, i| {
        try w.print("    {{ \"id\": {d}, \"type\": \"{s}\"", .{ n.id, nodeTypeName(n.kind) });
        try writeNodePayload(w, allocator, n.kind);
        try w.print(", \"pos\": [{d}, {d}] }}", .{ n.pos[0], n.pos[1] });
        if (i + 1 < sorted_nodes.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ],\n");

    // Edges, sorted.
    const sorted_edges = try allocator.dupe(Edge, flow.edges);
    defer allocator.free(sorted_edges);
    std.mem.sort(Edge, sorted_edges, {}, lessThanEdge);

    try w.writeAll("  \"edges\": [\n");
    for (sorted_edges, 0..) |e, i| {
        try w.print("    {{ \"from\": {{ \"node\": {d}, \"pin\": ", .{e.from.node});
        try writeJsonString(w, e.from.pin);
        try w.print(" }}, \"to\": {{ \"node\": {d}, \"pin\": ", .{e.to.node});
        try writeJsonString(w, e.to.pin);
        try w.writeAll(" } }");
        if (i + 1 < sorted_edges.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n");

    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// Write `s` into `w` as a JSON string literal — quoted and
/// JSON-escaped. `renderFlowJsonc` emits JSON, so string content must
/// use JSON escapes; `std.zig.fmtString` uses Zig's, which diverge
/// (`\xNN`, `\'`, …) and would produce invalid JSON for some inputs.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// True when `text` is a JSON-native scalar — `true`, `false`, or a
/// finite number — that can be emitted to JSONC unquoted and parse
/// straight back. Anything else must be written as a JSON string.
fn isJsonScalar(text: []const u8) bool {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return true;
    if (text.len == 0) return false;
    const f = std.fmt.parseFloat(f64, text) catch return false;
    return std.math.isFinite(f);
}

/// Write a param `default` / `Subflow` binding value as JSON. A scalar
/// `zig_text` (bool / number) is already valid JSON and emitted
/// verbatim. A Zig string literal — what `parseParamLiteral` stores
/// for a JSON string default — is decoded to its content and
/// re-emitted as a JSON string, so the file stays valid JSON and
/// round-trips back through `parseParamLiteral`.
fn writeParamLiteral(w: anytype, allocator: std.mem.Allocator, zig_text: []const u8) !void {
    if (zig_text.len >= 2 and zig_text[0] == '"') {
        const content = std.zig.string_literal.parseAlloc(allocator, zig_text) catch {
            // Not a well-formed Zig string literal — emit the raw text
            // as a JSON string rather than splice invalid JSON.
            try writeJsonString(w, zig_text);
            return;
        };
        defer allocator.free(content);
        try writeJsonString(w, content);
        return;
    }
    try w.writeAll(zig_text);
}

fn lessThanNode(_: void, a: Node, b: Node) bool {
    return a.id < b.id;
}

fn lessThanEdge(_: void, a: Edge, b: Edge) bool {
    if (a.from.node != b.from.node) return a.from.node < b.from.node;
    const fp = std.mem.order(u8, a.from.pin, b.from.pin);
    if (fp != .eq) return fp == .lt;
    if (a.to.node != b.to.node) return a.to.node < b.to.node;
    return std.mem.order(u8, a.to.pin, b.to.pin) == .lt;
}

fn nodeTypeName(k: NodeKind) []const u8 {
    return @tagName(k);
}

fn writeNodePayload(w: anytype, allocator: std.mem.Allocator, k: NodeKind) !void {
    switch (k) {
        .GetComponent => |b| {
            try w.writeAll(", \"component\": ");
            try writeJsonString(w, b.type);
        },
        .SetField => |b| {
            try w.writeAll(", \"target\": ");
            try writeJsonString(w, b.target);
        },
        .BinOp => |b| try w.print(", \"op\": \"{s}\"", .{@tagName(b.op)}),
        .Compare => |b| try w.print(", \"op\": \"{s}\"", .{@tagName(b.op)}),
        .Logic => |b| try w.print(", \"op\": \"{s}\"", .{@tagName(b.op)}),
        // `value` is Zig expression text: a JSON-native scalar is
        // written bare so it round-trips through `literalValue`'s
        // number/bool arms; anything else as a JSON string.
        .Literal => |b| {
            try w.writeAll(", \"value\": ");
            if (isJsonScalar(b.value)) {
                try w.writeAll(b.value);
            } else {
                try writeJsonString(w, b.value);
            }
        },
        .Identifier => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .Call => |b| {
            try w.writeAll(", \"callee\": ");
            try writeJsonString(w, b.callee);
        },
        .Param => |b| {
            try w.writeAll(", \"param\": ");
            try writeJsonString(w, b.param);
        },
        .Output => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
            try w.writeAll(", \"value_type\": ");
            try writeJsonString(w, b.type);
        },
        .Subflow => |b| {
            try w.writeAll(", \"flow\": ");
            try writeJsonString(w, b.flow);
            if (b.bindings.len != 0) {
                try w.writeAll(", \"bindings\": {");
                for (b.bindings, 0..) |bd, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll(" ");
                    try writeJsonString(w, bd.param);
                    try w.writeAll(": ");
                    try writeParamLiteral(w, allocator, bd.value.zig_text);
                }
                try w.writeAll(" }");
            }
        },
        .Emit => |b| {
            try w.writeAll(", \"event\": ");
            try writeJsonString(w, b.event);
        },
        .Event => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .GetVariable => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .SetVariable => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .ChangeVariable => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
            // `by` is the inline-default increment. Even when it
            // equals the codegen default (`"1"`) we still emit it so
            // round-tripping is byte-deterministic — the on-disk file
            // exposes the increment, no hidden default semantics.
            try w.writeAll(", \"by\": ");
            try writeVariableDefault(w, allocator, b.by);
        },
        .ClearVariable => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .HasValueVariable => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .CustomNode => |b| {
            try w.writeAll(", \"name\": ");
            try writeJsonString(w, b.name);
        },
    }
}

fn writeEvent(w: anytype, ev: Event) !void {
    switch (ev) {
        .OnCall => try w.writeAll("{ \"type\": \"OnCall\" }"),
        // `OnEvent` is only ever synthesized from an in-graph `Event`
        // node post-Phase 6 — the in-graph form is the on-disk source
        // of truth and `renderFlowJsonc` omits the `event:` header for
        // any flow that carries an Event node (see the `has_event_node`
        // guard there). This arm is therefore unreachable at runtime.
        .OnEvent => unreachable,
    }
}

/// Write a variable `default` as JSON. Parallel to `writeParamLiteral`
/// — emits a scalar (`true` / `1` / `1.5`) verbatim, decodes a Zig
/// string literal back to its JSON-string form, and renders the literal
/// `null` (a nullable variable's default) as JSON `null`.
fn writeVariableDefault(w: anytype, allocator: std.mem.Allocator, zig_text: []const u8) !void {
    if (std.mem.eql(u8, zig_text, "null")) {
        try w.writeAll("null");
        return;
    }
    try writeParamLiteral(w, allocator, zig_text);
}

/// Persist `loaded` to disk at `path` as `.flow.jsonc`.
pub fn saveFlow(io: std.Io, allocator: std.mem.Allocator, path: []const u8, loaded: LoadedFlow) !void {
    const text = try renderFlowJsonc(allocator, loaded);
    defer allocator.free(text);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Strip the trailing `.flow.jsonc` double extension from a path's
/// basename and return the stem (RFC §5 — basename-as-effective-name).
/// e.g. `"scripts/flows/move.flow.jsonc"` → `"move"`. Falls back to the
/// raw basename when the suffix isn't present.
pub fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".flow.jsonc";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}

test {
    std.testing.refAllDecls(@This());
}
