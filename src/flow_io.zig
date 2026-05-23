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

/// Event entry point for a flow. `OnCall` (RFC §3) is the entry point
/// for a *subgraph* — a flow invoked by a `Subflow` node rather than a
/// lifecycle hook.
pub const Event = union(enum) {
    OnUpdate: struct { arg_dt: []const u8 = "dt" },
    OnCreate: struct { arg_entity: []const u8 = "entity" },
    OnDestroy: struct { arg_entity: []const u8 = "entity" },
    OnCall,
    /// Subscribes the flow to a plugin- or game-declared event by its
    /// dotted name (e.g. `"box2d.collision_begin"`).
    ///
    /// Resolution is the assembler's comptime `name → variant-type`
    /// pass over the merged `PluginEvents`/`GameEvents` union
    /// (RFC-PLUGIN-EVENTS §2, §7); codegen reflects the payload type
    /// out of the union and emits a hook-handler-struct method
    /// (`renderNewFormEventEntry`).
    ///
    /// The v1 `module` + `callback` + `params` legacy form was removed
    /// in RFC-PLUGIN-EVENTS phase 6 (flow-codegen#13). A `.flow.jsonc`
    /// with `"module"` / `"callback"` keys now fails to parse —
    /// `buildEvent` rejects an `OnEvent` whose `name` is absent.
    OnEvent: struct {
        /// Plugin-qualified event name
        /// (`"box2d.collision_begin"`).
        name: []const u8,
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
        /// scanner sort holds (O3). `null` on the wire (the field omitted
        /// from `.flow.jsonc`) means "no hint"; for a consumable event
        /// that is the lowest-precedence bucket. Pure passthrough at
        /// this layer: `validate` accepts the field on any `OnEvent` and
        /// `renderEventEntry` does not consume it (the handler-struct
        /// shape is the same — the assembler reads the priority off the
        /// `flow_scanner` entry, not off the generated Zig).
        priority: ?i32 = null,
    },
};

/// Binary operator for `NodeKind.BinOp`.
pub const BinOpKind = enum { add, sub, mul, div };

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

/// A fully parsed flow. Every slice is owned by the surrounding
/// `LoadedFlow.arena`. `name` is the effective registry key (RFC §5).
pub const Flow = struct {
    /// Effective name (RFC §5): the top-level `"name"` field, else the
    /// filename basename. Empty when neither is available.
    name: []const u8 = "",
    event: Event,
    params: []Param = &.{},
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

    const event = try buildEvent(a, obj.get("event") orelse return error.MalformedFlow);
    const params = try buildParams(a, obj.get("params"));
    const nodes = try buildNodes(a, obj.get("nodes") orelse return error.MalformedFlow);
    // `links` was the pre-rename (RFC §2) name for `edges`. A file
    // still using it would otherwise load with zero connections and
    // pass validation — reject the stale key rather than ignore it.
    if (obj.get("edges") == null and obj.get("links") != null) return error.MalformedFlow;
    const edges = try buildEdges(a, obj.get("edges"));

    return .{
        .name = name,
        .event = event,
        .params = params,
        .nodes = nodes,
        .edges = edges,
    };
}

fn buildEvent(a: std.mem.Allocator, v: std.json.Value) !Event {
    if (v != .object) return error.MalformedFlow;
    const t = (v.object.get("type") orelse return error.MalformedFlow);
    if (t != .string) return error.MalformedFlow;

    if (std.mem.eql(u8, t.string, "OnUpdate")) {
        return .{ .OnUpdate = .{ .arg_dt = try strField(v.object, "arg_dt", "dt") } };
    } else if (std.mem.eql(u8, t.string, "OnCreate")) {
        return .{ .OnCreate = .{ .arg_entity = try strField(v.object, "arg_entity", "entity") } };
    } else if (std.mem.eql(u8, t.string, "OnDestroy")) {
        return .{ .OnDestroy = .{ .arg_entity = try strField(v.object, "arg_entity", "entity") } };
    } else if (std.mem.eql(u8, t.string, "OnCall")) {
        return .OnCall;
    } else if (std.mem.eql(u8, t.string, "OnEvent")) {
        // The v1 legacy form (`module` + `callback` + `params`) was
        // removed in RFC-PLUGIN-EVENTS phase 6 (flow-codegen#13). An
        // `OnEvent` with `name` absent — or with any of the retired
        // legacy keys present — is a malformed flow.
        if (v.object.get("module") != null or
            v.object.get("callback") != null or
            v.object.get("params") != null)
            return error.MalformedFlow;
        const name_v = v.object.get("name") orelse return error.MalformedFlow;
        if (name_v != .string) return error.MalformedFlow;

        // Optional `priority` — RFC-PLUGIN-EVENTS O4 / phase 7
        // (labelle-core#16). The assembler honors it only when the
        // resolved event is consumable; a present-but-non-integer value
        // rejects as `MalformedFlow`, matching every other strict-type
        // field in this loader.
        const priority_opt: ?i32 = blk: {
            const v_pri = v.object.get("priority") orelse break :blk null;
            if (v_pri != .integer) return error.MalformedFlow;
            // Clamp would silently lose data; cast rejects out-of-range
            // explicitly so an outlandish 64-bit value surfaces as a
            // malformed flow rather than wrapping at the i32 boundary.
            break :blk std.math.cast(i32, v_pri.integer) orelse return error.MalformedFlow;
        };

        return .{ .OnEvent = .{
            .name = try a.dupe(u8, name_v.string),
            .priority = priority_opt,
        } };
    }
    return error.UnknownEventType;
}

/// An optional string field: `default` when the key is absent, the
/// string when present. A present-but-non-string value is a malformed
/// file (rejected) rather than silently defaulted — otherwise the
/// on-disk event arg would diverge from the generated `pub fn`
/// signature.
fn strField(obj: std.json.ObjectMap, key: []const u8, default: []const u8) ParseError![]const u8 {
    const v = obj.get(key) orelse return default;
    if (v != .string) return error.MalformedFlow;
    return v.string;
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

    // Every edge endpoint resolves to a real node.
    for (flow.edges) |e| {
        if (!hasNode(flow.nodes, e.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, e.to.node)) return error.DanglingLink;
    }

    // `Param` nodes must name a declared parameter (RFC §3); `Output`
    // node names must be unique (RFC §3).
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
            else => {},
        }
    }
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

    try w.writeAll("  \"event\": ");
    try writeEvent(w, flow.event);
    try w.writeAll(",\n");

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
    }
}

fn writeEvent(w: anytype, ev: Event) !void {
    switch (ev) {
        .OnUpdate => |b| {
            try w.writeAll("{ \"type\": \"OnUpdate\", \"arg_dt\": ");
            try writeJsonString(w, b.arg_dt);
            try w.writeAll(" }");
        },
        .OnCreate => |b| {
            try w.writeAll("{ \"type\": \"OnCreate\", \"arg_entity\": ");
            try writeJsonString(w, b.arg_entity);
            try w.writeAll(" }");
        },
        .OnDestroy => |b| {
            try w.writeAll("{ \"type\": \"OnDestroy\", \"arg_entity\": ");
            try writeJsonString(w, b.arg_entity);
            try w.writeAll(" }");
        },
        .OnCall => try w.writeAll("{ \"type\": \"OnCall\" }"),
        .OnEvent => |b| {
            try w.writeAll("{ \"type\": \"OnEvent\", \"name\": ");
            try writeJsonString(w, b.name);
            // `priority` (RFC-PLUGIN-EVENTS O4 / phase 7) is emitted
            // right after `name` so the on-disk key order stays in sync
            // with the in-source struct field order; `null` is omitted
            // (the parser treats absence as "no hint" — see `buildEvent`).
            if (b.priority) |p| {
                try w.print(", \"priority\": {d}", .{p});
            }
            try w.writeAll(" }");
        },
    }
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
