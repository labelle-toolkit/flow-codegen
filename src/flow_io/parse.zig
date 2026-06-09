//! Parser — JSONC source → typed `Flow` (`model.zig`).
//!
//! Reads the flat `.flow.jsonc` schema (RFC-FLOWS-JSONC §1, §2): a node
//! is `{ "id", "type", "pos", …params }` — no tagged-union `kind`
//! wrapper — and the link list is named `edges`. After building the
//! `Flow`, `parseFlowNamed` runs `validate.zig`'s checks before handing
//! back a `LoadedFlow`.
//!
//! Ownership: a heap-allocated arena owns every slice the `Flow`
//! references; the caller frees both via `LoadedFlow.deinit()`.

const std = @import("std");
const jsonc = @import("../jsonc.zig");
const model = @import("model.zig");
const validate = @import("validate.zig").validate;

const Event = model.Event;
const BinOpKind = model.BinOpKind;
const CompareKind = model.CompareKind;
const LogicKind = model.LogicKind;
const Pos = model.Pos;
const Param = model.Param;
const Binding = model.Binding;
const NodeKind = model.NodeKind;
const Node = model.Node;
const PinRef = model.PinRef;
const Edge = model.Edge;
const ExecEdge = model.ExecEdge;
const Variable = model.Variable;
const Collection = model.Collection;
const Flow = model.Flow;
const LoadedFlow = model.LoadedFlow;

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

pub fn buildFlow(
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
    const locals = try buildVariables(a, obj.get("locals"));
    const collections = try buildCollections(a, obj.get("collections"));
    const nodes = try buildNodes(a, obj.get("nodes") orelse return error.MalformedFlow);
    // `links` was the pre-rename (RFC §2) name for `edges`. A file
    // still using it would otherwise load with zero connections and
    // pass validation — reject the stale key rather than ignore it.
    if (obj.get("edges") == null and obj.get("links") != null) return error.MalformedFlow;
    const edges = try buildEdges(a, obj.get("edges"));
    const exec_edges = try buildExecEdges(a, obj.get("exec_edges"));

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
        .locals = locals,
        .collections = collections,
        .nodes = nodes,
        .edges = edges,
        .exec_edges = exec_edges,
    };
}

pub fn buildEvent(a: std.mem.Allocator, v: std.json.Value) !Event {
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

pub fn buildVariables(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Variable {
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

/// Parse the optional `collections` array (flow-codegen#24). Absent →
/// empty slice (every pre-collections file). A LIST entry is `{ "name":
/// "<ident>", "element": "<zig type text>" }` (the `kind` field is
/// optional and defaults to `"list"`, so pre-MAPS files parse unchanged).
/// A MAP entry is `{ "name": "<ident>", "kind": "map", "key": "<type>",
/// "value": "<type>" }`. The shape-specific fields (`element` vs
/// `key`/`value`) are validated in `flow_io.validate`
/// (`MalformedCollection`); here we only require `name` and a recognised
/// `kind`.
pub fn buildCollections(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Collection {
    const v = maybe orelse return &.{};
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Collection, items.len);
    for (items, 0..) |it, i| {
        if (it != .object) return error.MalformedFlow;
        const o = it.object;
        const cname = o.get("name") orelse return error.MalformedFlow;
        if (cname != .string) return error.MalformedFlow;

        // `kind` is optional; absent → `.list` (back-compat). Unknown
        // discriminator strings are `MalformedFlow`.
        const kind: model.CollectionKind = if (o.get("kind")) |k| blk: {
            if (k != .string) return error.MalformedFlow;
            if (std.mem.eql(u8, k.string, "list")) break :blk .list;
            if (std.mem.eql(u8, k.string, "map")) break :blk .map;
            return error.MalformedFlow;
        } else .list;

        // Optional per-shape type fields — duped when present, empty
        // otherwise. The presence rules (list needs `element`; map needs
        // `key`+`value`) are enforced in `validate`.
        const element = if (o.get("element")) |e| blk: {
            if (e != .string) return error.MalformedFlow;
            break :blk try a.dupe(u8, e.string);
        } else "";
        const key = if (o.get("key")) |kk| blk: {
            if (kk != .string) return error.MalformedFlow;
            break :blk try a.dupe(u8, kk.string);
        } else "";
        const value = if (o.get("value")) |vv| blk: {
            if (vv != .string) return error.MalformedFlow;
            break :blk try a.dupe(u8, vv.string);
        } else "";

        out[i] = .{
            .name = try a.dupe(u8, cname.string),
            .kind = kind,
            .element = element,
            .key = key,
            .value = value,
        };
    }
    return out;
}

/// Render a JSON-native variable default as Zig source text. Like
/// `parseParamLiteral`, but accepts JSON `null` (for nullable `?T`
/// variables) and renders it as the Zig `null` keyword.
pub fn parseVariableDefault(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
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

pub fn buildParams(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Param {
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
pub fn parseParamLiteral(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
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

pub fn buildNodes(a: std.mem.Allocator, v: std.json.Value) ![]Node {
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Node, items.len);
    for (items, 0..) |it, i| {
        out[i] = try buildNode(a, it);
    }
    return out;
}

pub fn buildNode(a: std.mem.Allocator, v: std.json.Value) !Node {
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

pub fn buildPos(maybe: ?std.json.Value) !Pos {
    const v = maybe orelse return .{ 0, 0 };
    if (v != .array or v.array.items.len != 2) return error.MalformedFlow;
    return .{
        try jsonNumber(v.array.items[0]),
        try jsonNumber(v.array.items[1]),
    };
}

pub fn jsonNumberF64(v: std.json.Value) !f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.MalformedFlow,
        else => error.MalformedFlow,
    };
}

pub fn jsonNumber(v: std.json.Value) !f32 {
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
pub fn buildNodeKind(a: std.mem.Allocator, type_name: []const u8, o: std.json.ObjectMap) !NodeKind {
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
    } else if (std.mem.eql(u8, type_name, "Branch")) {
        // Control-flow `if`/then-else (flow-codegen#8). No per-kind
        // payload — the `cond` source is a data edge and the
        // `then`/`else` targets are exec edges (`Flow.exec_edges`).
        return .{ .Branch = .{} };
    } else if (std.mem.eql(u8, type_name, "ForRange")) {
        // Count loop (flow-codegen#21). No per-kind payload — `start`,
        // `end`, `step` are data edges and the `body` target is an exec
        // edge.
        return .{ .ForRange = .{} };
    } else if (std.mem.eql(u8, type_name, "While")) {
        // Condition loop (flow-codegen#21). No per-kind payload — `cond`
        // is a data edge and the `body` target is an exec edge.
        return .{ .While = .{} };
    } else if (std.mem.eql(u8, type_name, "Once")) {
        // Exec-gate that passes control the first time only (flow-codegen#47).
        // No per-kind payload — the `body` target is an exec edge and the
        // gate state is a per-node `pub var` emitted by codegen.
        return .{ .Once = .{} };
    } else if (std.mem.eql(u8, type_name, "Cooldown")) {
        // Exec-gate that re-blocks for `seconds` after firing
        // (flow-codegen#47). The `body` target is an exec edge; only the
        // inline `seconds` duration lives on the node. Absent `seconds`
        // defaults to `0` (a gate that never blocks).
        return .{ .Cooldown = .{
            .seconds = if (o.get("seconds")) |sv|
                try jsonNumberF64(sv)
            else
                0,
        } };
    } else if (std.mem.eql(u8, type_name, "Delay")) {
        // Deferred-subflow exec node (flow-codegen#48). The `body` target
        // is an exec edge into the single Subflow it defers; only the
        // inline `seconds` duration lives on the node. Absent `seconds`
        // defaults to `0` (fires on the next scheduler tick). Same
        // `f64`-from-JSON shape as `Cooldown`.
        return .{ .Delay = .{
            .seconds = if (o.get("seconds")) |sv|
                try jsonNumberF64(sv)
            else
                0,
        } };
    } else if (std.mem.eql(u8, type_name, "Select")) {
        // Pure-expression multi-way picker (flow-codegen#22). No per-kind
        // payload — `selector`, `case<N>`, and `default` are all data edges.
        return .{ .Select = .{} };
    } else if (std.mem.eql(u8, type_name, "Switch")) {
        // N-way control-flow branch (flow-codegen#22). No per-kind payload —
        // the `selector` source is a data edge and the `case<N>`/`default`
        // targets are exec edges.
        return .{ .Switch = .{} };
    } else if (std.mem.eql(u8, type_name, "Log")) {
        // Debug-print command (flow-codegen#20). `value` is an optional
        // data edge; only the inline `label` lives on the node. Absent
        // `label` defaults to `""`.
        return .{ .Log = .{
            .label = if (o.get("label")) |lv|
                (if (lv == .string) try a.dupe(u8, lv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "Format")) {
        // String-formatting reporter (flow-codegen#26). The printf-style
        // `template` is the only inline field; the typed `arg<N>` value
        // pins are data edges. Absent `template` defaults to `""` (a valid,
        // argument-free template) — mirrors `Log`'s `label` default.
        return .{ .Format = .{
            .template = if (o.get("template")) |tv|
                (if (tv == .string) try a.dupe(u8, tv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "Concat")) {
        // String-join reporter (flow-codegen#26). No per-kind payload —
        // its `arg<N>` string inputs are all data edges.
        return .{ .Concat = .{} };
    } else if (std.mem.eql(u8, type_name, "IntToString")) {
        // Integer-stringify reporter (flow-codegen#26). No per-kind
        // payload — its single `value` integer input is a data edge.
        return .{ .IntToString = .{} };
    } else if (std.mem.eql(u8, type_name, "FloatToString")) {
        // Float-stringify reporter (flow-codegen#26). No per-kind payload —
        // its single `value` float input is a data edge.
        return .{ .FloatToString = .{} };
    } else if (std.mem.eql(u8, type_name, "IsKeyDown")) {
        // Input reporter (labelle-gui#208 Option A). `key` is the bare
        // `KeyboardKey` enum-tag name (e.g. `"space"`, `"w"`); codegen
        // emits it as a Zig enum literal `game.isKeyDown(.<key>)`. No
        // data input pins — `key` is an inline FIELD, not a wire. Absent
        // `key` defaults to `""` (rejected by `validate`).
        return .{ .IsKeyDown = .{
            .key = if (o.get("key")) |kv|
                (if (kv == .string) try a.dupe(u8, kv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "IsKeyPressed")) {
        // Rising-edge sibling of `IsKeyDown` (labelle-gui#208 Option A).
        // Same enum-literal `key` field encoding.
        return .{ .IsKeyPressed = .{
            .key = if (o.get("key")) |kv|
                (if (kv == .string) try a.dupe(u8, kv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "IsKeyReleased")) {
        // Falling-edge sibling of `IsKeyDown` (labelle-gui#208). Same
        // enum-literal `key` field encoding.
        return .{ .IsKeyReleased = .{
            .key = if (o.get("key")) |kv|
                (if (kv == .string) try a.dupe(u8, kv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "IsMouseButtonDown")) {
        // Mouse-button input reporter (labelle-gui#208). `button` is the
        // bare `MouseButton` enum-tag name (e.g. `"left"`, `"right"`);
        // codegen emits it as a Zig enum literal
        // `game.isMouseButtonDown(.<button>)`. No data input pins —
        // `button` is an inline FIELD, not a wire. Absent `button` defaults
        // to `""` (rejected by `validate`).
        return .{ .IsMouseButtonDown = .{
            .button = if (o.get("button")) |bv|
                (if (bv == .string) try a.dupe(u8, bv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "IsMouseButtonPressed")) {
        // Rising-edge sibling of `IsMouseButtonDown` (labelle-gui#208).
        // Same enum-literal `button` field encoding.
        return .{ .IsMouseButtonPressed = .{
            .button = if (o.get("button")) |bv|
                (if (bv == .string) try a.dupe(u8, bv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "IsMouseButtonReleased")) {
        // Falling-edge sibling of `IsMouseButtonDown` (labelle-gui#208).
        // Same enum-literal `button` field encoding.
        return .{ .IsMouseButtonReleased = .{
            .button = if (o.get("button")) |bv|
                (if (bv == .string) try a.dupe(u8, bv.string) else return error.MalformedFlow)
            else
                "",
        } };
    } else if (std.mem.eql(u8, type_name, "GetMouseX")) {
        // Input reporter (labelle-gui#208 Option A). No per-kind payload,
        // no input pins — lowers to `game.getMouseX()`.
        return .{ .GetMouseX = .{} };
    } else if (std.mem.eql(u8, type_name, "GetMouseY")) {
        // Input reporter (labelle-gui#208 Option A). No per-kind payload,
        // no input pins — lowers to `game.getMouseY()`.
        return .{ .GetMouseY = .{} };
    } else if (std.mem.eql(u8, type_name, "GetMouseWheel")) {
        // Input reporter (labelle-gui#208 Option A). No per-kind payload,
        // no input pins — lowers to `game.getMouseWheelMove()`.
        return .{ .GetMouseWheel = .{} };
    } else if (std.mem.eql(u8, type_name, "ListAppend")) {
        // List ops (flow-codegen#24) reference a list by `collection`
        // name; their data inputs (`value`/`index`) are edges.
        return .{ .ListAppend = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "ListLength")) {
        return .{ .ListLength = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "ListGet")) {
        return .{ .ListGet = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "ListSet")) {
        return .{ .ListSet = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "ListContains")) {
        return .{ .ListContains = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "ListClear")) {
        return .{ .ListClear = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "ForEach")) {
        // ForEach (flow-codegen#24) — its `body` is an exec output and
        // `item`/`index` are data outputs; only the list `collection`
        // name lives on the node.
        return .{ .ForEach = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapSet")) {
        // Map ops (flow-codegen#24, MAPS) reference a map by `collection`
        // name; their data inputs (`key`/`value`/`default`) and the
        // `MapForEach` `body`/`key`/`value` pins are edges, not payload.
        return .{ .MapSet = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapGet")) {
        return .{ .MapGet = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapHas")) {
        return .{ .MapHas = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapRemove")) {
        return .{ .MapRemove = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapClear")) {
        return .{ .MapClear = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapLength")) {
        return .{ .MapLength = .{ .collection = try reqStr(a, o, "collection") } };
    } else if (std.mem.eql(u8, type_name, "MapForEach")) {
        return .{ .MapForEach = .{ .collection = try reqStr(a, o, "collection") } };
    }
    return error.UnknownNodeType;
}

/// `Literal.value` is Zig expression text. The on-disk `"value"` may
/// be a JSON string (already Zig text) or a JSON number/bool — in
/// which case it is rendered as a Zig literal.
pub fn literalValue(a: std.mem.Allocator, o: std.json.ObjectMap) ![]const u8 {
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

pub fn buildBindings(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Binding {
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

pub fn reqStr(a: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return error.MalformedFlow;
    if (v != .string) return error.MalformedFlow;
    return try a.dupe(u8, v.string);
}

pub fn buildEdges(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Edge {
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

pub fn buildPinRef(a: std.mem.Allocator, maybe: ?std.json.Value) !PinRef {
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

/// Parse the optional `exec_edges` array (flow-codegen#8). Absent →
/// empty slice (every pre-control-flow file). Each entry is `{ "from":
/// { "node", "pin" }, "to": { "node" } }`: `from` is a full pin ref
/// (the `Branch`'s `then`/`else` exec output), `to` is a bare node ref
/// — the target node is *entered*, not wired to a named input pin.
pub fn buildExecEdges(a: std.mem.Allocator, maybe: ?std.json.Value) ![]ExecEdge {
    const v = maybe orelse return &.{};
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(ExecEdge, items.len);
    for (items, 0..) |it, i| {
        if (it != .object) return error.MalformedFlow;
        out[i] = .{
            .from = try buildPinRef(a, it.object.get("from")),
            .to_node = try buildNodeRef(it.object.get("to")),
        };
    }
    return out;
}

/// Parse a bare node reference — `{ "node": <id> }` — the `to` end of
/// an exec edge. Unlike `buildPinRef` there is no `pin`: an exec edge
/// enters a node, it does not target one of its input pins.
pub fn buildNodeRef(maybe: ?std.json.Value) !u32 {
    const v = maybe orelse return error.MalformedFlow;
    if (v != .object) return error.MalformedFlow;
    const node_v = v.object.get("node") orelse return error.MalformedFlow;
    if (node_v != .integer or node_v.integer < 0) return error.MalformedFlow;
    return std.math.cast(u32, node_v.integer) orelse return error.MalformedFlow;
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
