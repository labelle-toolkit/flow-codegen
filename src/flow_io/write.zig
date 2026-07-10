//! Writer — typed `Flow` (`model.zig`) → `.flow.jsonc` source.
//!
//! `renderFlowJsonc` emits a canonical, deterministic serialization
//! (nodes sorted by id, edges by endpoints, params in declared order)
//! so editor re-saves diff cleanly (RFC open question 3). `saveFlow`
//! persists the rendered text to disk.

const std = @import("std");
const model = @import("model.zig");

const Event = model.Event;
const Node = model.Node;
const NodeKind = model.NodeKind;
const Edge = model.Edge;
const ExecEdge = model.ExecEdge;
const LoadedFlow = model.LoadedFlow;

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

    // No `event:` header is ever emitted (RFC-FLOW-VOCABULARY §3,
    // flow-codegen#17): an event-driven flow carries its trigger as an
    // in-graph `Event` node and a subgraph declares no trigger at all, so
    // the flow's trigger round-trips through `nodes` alone. The loader's
    // `buildFlow` rejects any top-level `event:` key.

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

    // Locals block (issue #23). Omitted when empty, mirroring the
    // `variables` block's formatting and ordering exactly.
    if (flow.locals.len != 0) {
        try w.writeAll("  \"locals\": [\n");
        for (flow.locals, 0..) |v, i| {
            try w.writeAll("    { \"name\": ");
            try writeJsonString(w, v.name);
            try w.writeAll(", \"type\": ");
            try writeJsonString(w, v.type);
            try w.writeAll(", \"default\": ");
            try writeVariableDefault(w, allocator, v.default.zig_text);
            try w.writeAll(" }");
            if (i + 1 < flow.locals.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ],\n");
    }

    // Collections block (flow-codegen#24). Omitted when empty, mirroring
    // the `variables`/`locals` blocks' formatting. Deterministic order:
    // the in-memory order (source order), like `variables`.
    if (flow.collections.len != 0) {
        try w.writeAll("  \"collections\": [\n");
        for (flow.collections, 0..) |c, i| {
            try w.writeAll("    { \"name\": ");
            try writeJsonString(w, c.name);
            // Lists round-trip exactly as before (no `kind` key emitted —
            // it defaults to `.list` on re-parse). Maps emit `kind` + the
            // `key`/`value` type fields (flow-codegen#24).
            switch (c.kind) {
                .list => {
                    try w.writeAll(", \"element\": ");
                    try writeJsonString(w, c.element);
                },
                .map => {
                    try w.writeAll(", \"kind\": \"map\", \"key\": ");
                    try writeJsonString(w, c.key);
                    try w.writeAll(", \"value\": ");
                    try writeJsonString(w, c.value);
                },
            }
            try w.writeAll(" }");
            if (i + 1 < flow.collections.len) try w.writeAll(",");
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
    // The `edges` block keeps no trailing comma unless an `exec_edges`
    // block follows it — emitted only when non-empty so pre-control-flow
    // files round-trip byte-for-byte (flow-codegen#8).
    if (flow.exec_edges.len == 0) {
        try w.writeAll("  ]\n");
    } else {
        try w.writeAll("  ],\n");

        const sorted_exec = try allocator.dupe(ExecEdge, flow.exec_edges);
        defer allocator.free(sorted_exec);
        std.mem.sort(ExecEdge, sorted_exec, {}, lessThanExecEdge);

        try w.writeAll("  \"exec_edges\": [\n");
        for (sorted_exec, 0..) |x, i| {
            try w.print("    {{ \"from\": {{ \"node\": {d}, \"pin\": ", .{x.from.node});
            try writeJsonString(w, x.from.pin);
            try w.print(" }}, \"to\": {{ \"node\": {d} }} }}", .{x.to_node});
            if (i + 1 < sorted_exec.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ]\n");
    }

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

/// Deterministic order for exec edges (flow-codegen#8) — by source
/// `Branch` id, then by exec pin (`else` < `then`), then by target node.
/// Keeps editor re-saves diff-clean, matching `lessThanEdge`.
fn lessThanExecEdge(_: void, a: ExecEdge, b: ExecEdge) bool {
    if (a.from.node != b.from.node) return a.from.node < b.from.node;
    const fp = std.mem.order(u8, a.from.pin, b.from.pin);
    if (fp != .eq) return fp == .lt;
    return a.to_node < b.to_node;
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
        // `Branch` carries no per-kind fields (flow-codegen#8) — its
        // wiring lives in the data `edges` (`cond`) and `exec_edges`
        // (`then`/`else`) lists, not on the node. `ForRange`/`While`
        // (flow-codegen#21) are the same shape: their `start`/`end`/`step`
        // / `cond` inputs are data edges and their `body` target is an
        // exec edge, so they carry no on-node payload either.
        // `Select`/`Switch` (flow-codegen#22) are payload-free too: a
        // `Select`'s `selector`/`case<N>`/`default` inputs are data edges,
        // and a `Switch`'s `selector` is a data edge while its
        // `case<N>`/`default` targets are exec edges.
        // `Concat`/`IntToString`/`FloatToString` (flow-codegen#26) are
        // payload-free string reporters: their value inputs (`arg<N>` for
        // `Concat`, `value` for the to-string nodes) are all data edges, so
        // they carry no on-node fields — same as `Branch`/`Select` above.
        // `Once` (flow-codegen#47) is payload-free like `Branch`: its `body`
        // target is an exec edge and its gate is a per-node `pub var` emitted
        // by codegen, not on-node state — so nothing to write here.
        // `GetMouseX`/`GetMouseY`/`GetMouseWheel` (labelle-gui#208 Option A)
        // are payload-free input reporters — they take no inputs and lower
        // directly to a mixin getter, so nothing to write here.
        .Branch, .ForRange, .While, .Select, .Switch, .Concat, .IntToString, .FloatToString, .Once, .GetMouseX, .GetMouseY, .GetMouseWheel => {},
        // `IsKeyDown`/`IsKeyPressed` (labelle-gui#208 Option A) carry only
        // their inline `key` (the bare `KeyboardKey` enum-tag name); the
        // node has no input pins. Emit `key` like `Log`'s `label` so the
        // round-trip stays byte-deterministic.
        .IsKeyDown => |b| {
            try w.writeAll(", \"key\": ");
            try writeJsonString(w, b.key);
        },
        .IsKeyPressed => |b| {
            try w.writeAll(", \"key\": ");
            try writeJsonString(w, b.key);
        },
        .IsKeyReleased => |b| {
            try w.writeAll(", \"key\": ");
            try writeJsonString(w, b.key);
        },
        // `IsMouseButtonDown`/`IsMouseButtonPressed`/`IsMouseButtonReleased`
        // (labelle-gui#208) carry only their inline `button` (the bare
        // `MouseButton` enum-tag name); the node has no input pins. Emit
        // `button` like `IsKeyDown`'s `key` so the round-trip stays
        // byte-deterministic.
        .IsMouseButtonDown => |b| {
            try w.writeAll(", \"button\": ");
            try writeJsonString(w, b.button);
        },
        .IsMouseButtonPressed => |b| {
            try w.writeAll(", \"button\": ");
            try writeJsonString(w, b.button);
        },
        .IsMouseButtonReleased => |b| {
            try w.writeAll(", \"button\": ");
            try writeJsonString(w, b.button);
        },
        // `IsGamepadButtonDown`/`Pressed`/`Released` (labelle-assembler#250)
        // carry only their inline `button` (the bare `GamepadButton`
        // enum-tag name); the node has no input pins. Emit `button` like the
        // mouse reporters so the round-trip stays byte-deterministic.
        .IsGamepadButtonDown => |b| {
            try w.writeAll(", \"button\": ");
            try writeJsonString(w, b.button);
        },
        .IsGamepadButtonPressed => |b| {
            try w.writeAll(", \"button\": ");
            try writeJsonString(w, b.button);
        },
        .IsGamepadButtonReleased => |b| {
            try w.writeAll(", \"button\": ");
            try writeJsonString(w, b.button);
        },
        // `GetGamepadAxisValue` (labelle-assembler#250) carries only its
        // inline `axis` (the bare `GamepadAxis` enum-tag name); the node has
        // no input pins. Emit `axis` so the round-trip stays deterministic.
        .GetGamepadAxisValue => |b| {
            try w.writeAll(", \"axis\": ");
            try writeJsonString(w, b.axis);
        },
        // `Cooldown` (flow-codegen#47) carries only its inline `seconds`
        // duration (an `f64`); its `body` target is an exec edge. Emit
        // `seconds` with `{d}` so the round-trip stays byte-deterministic
        // (matches how node `pos` floats are written).
        .Cooldown => |b| {
            try w.print(", \"seconds\": {d}", .{b.seconds});
        },
        // `Delay` (flow-codegen#48) carries only its inline `seconds`
        // duration (an `f64`); its `body` target is an exec edge into the
        // deferred Subflow. Emit `seconds` with `{d}` so the round-trip
        // stays byte-deterministic, exactly like `Cooldown`.
        .Delay => |b| {
            try w.print(", \"seconds\": {d}", .{b.seconds});
        },
        // `Format` (flow-codegen#26) carries only its inline `template`
        // (printf-style `std.fmt` syntax); its typed `arg<N>` value inputs
        // are data edges. Emit `template` like `Log`'s `label` so the
        // round-trip stays byte-deterministic.
        .Format => |b| {
            try w.writeAll(", \"template\": ");
            try writeJsonString(w, b.template);
        },
        // `Log` (flow-codegen#20) carries only its inline `label`; the
        // `value` input is a data edge. Emit `label` like other node
        // payload fields so the round-trip stays byte-deterministic.
        .Log => |b| {
            try w.writeAll(", \"label\": ");
            try writeJsonString(w, b.label);
        },
        // List operation nodes (flow-codegen#24) carry only the list
        // `collection` name; their data inputs (`value`/`index`) and the
        // `ForEach` `body`/`item`/`index` pins are edges, not payload.
        // Map operation nodes (flow-codegen#24, MAPS) likewise carry only
        // the map `collection` name; their data inputs and the
        // `MapForEach` `body`/`key`/`value` pins are edges, not payload.
        .ListAppend,
        .ListLength,
        .ListGet,
        .ListSet,
        .ListContains,
        .ListClear,
        .ForEach,
        .MapSet,
        .MapGet,
        .MapHas,
        .MapRemove,
        .MapClear,
        .MapLength,
        .MapForEach,
        => {
            const collection = switch (k) {
                .ListAppend => |b| b.collection,
                .ListLength => |b| b.collection,
                .ListGet => |b| b.collection,
                .ListSet => |b| b.collection,
                .ListContains => |b| b.collection,
                .ListClear => |b| b.collection,
                .ForEach => |b| b.collection,
                .MapSet => |b| b.collection,
                .MapGet => |b| b.collection,
                .MapHas => |b| b.collection,
                .MapRemove => |b| b.collection,
                .MapClear => |b| b.collection,
                .MapLength => |b| b.collection,
                .MapForEach => |b| b.collection,
                else => unreachable,
            };
            try w.writeAll(", \"collection\": ");
            try writeJsonString(w, collection);
        },
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
