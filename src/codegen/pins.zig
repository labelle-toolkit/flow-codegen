//! Pin signatures and small flow-shape helpers shared across the
//! codegen concern modules: which pins a node kind exposes / consumes,
//! the positional `arg<N>` / `case<N>` counters, and the symbol /
//! Output helpers (`sanitizeSymbol`, `collectOutputs`, …).

const std = @import("std");
const flow_io = @import("../flow_io.zig");
const errors = @import("errors.zig");

const CodegenError = errors.CodegenError;

pub fn primaryOutputPin(k: flow_io.NodeKind) []const u8 {
    return switch (k) {
        .GetComponent, .Literal, .Identifier, .Param => "value",
        .BinOp, .Call, .Subflow => "result",
        // Comparison / logic reporters (flow-codegen#7) — single `bool`
        // output pin, same `result` naming as `BinOp`.
        .Compare, .Logic => "result",
        // `GetVariable` is a reporter (RFC-FLOW-VOCABULARY §4) — its
        // single output pin is `value`, the same shape as `Literal` /
        // `Identifier` / `GetComponent`. `SetVariable` /
        // `ChangeVariable` are commands and bind no value (same as
        // `SetField` / `Emit` / `Output`); the `Event` node is the
        // graph trigger and is dropped from the body entirely (see
        // `emitBody`).
        .GetVariable => "value",
        // `Select` is a pure-expression reporter (flow-codegen#22) — it
        // binds an `n<id>_result` from an inline `switch` expression, the
        // same `result` naming as `BinOp` / `Compare`. `Switch` is a
        // control-flow command (no value binding — see the empty-pin arm
        // below).
        .Select => "result",
        // `HasValueVariable` is a reporter (RFC-FLOW-VOCABULARY §4 —
        // nullable variable operations) — single output pin `value` of
        // type `bool`, the same naming as `GetVariable`.
        .HasValueVariable => "value",
        // List reporters (flow-codegen#24) — `ListLength`/`ListGet`/
        // `ListContains` bind an `n<id>_value`. The command list ops
        // (`ListAppend`/`ListSet`/`ListClear`) and the `ForEach` loop
        // node bind no value (empty-pin arm below).
        .ListLength, .ListGet, .ListContains => "value",
        // Map reporters (flow-codegen#24, MAPS) — `MapGet`/`MapHas`/
        // `MapLength` bind an `n<id>_value`. The command map ops
        // (`MapSet`/`MapRemove`/`MapClear`) and the `MapForEach` loop node
        // bind no value (empty-pin arm below).
        .MapGet, .MapHas, .MapLength => "value",
        // String reporters (flow-codegen#26) — `Format`/`Concat`/
        // `IntToString`/`FloatToString` each bind a `[]const u8` to an
        // `n<id>_value` (the same `value` naming as the other reporters).
        // They are bound-once (NOT inlined) because they allocate — see
        // `inline.zig`'s `isInlinableKind`.
        .Format, .Concat, .IntToString, .FloatToString => "value",
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
        // `Branch` is a control-flow command (flow-codegen#8) — it routes
        // execution through its `then`/`else` exec outputs, producing no
        // *data* value. Empty primary pin (no `n<id>_…` binding); the
        // `if`/else wrapper is emitted by the scope walker, not the flat
        // `discardUnconsumedResult` path.
        // `ForRange` / `While` are control-flow loop nodes (flow-codegen#21)
        // — like `Branch`, they route execution (through their `body` exec
        // output) rather than bind a top-level `n<id>_…` data value, so the
        // primary pin is empty. `ForRange`'s `index` is a special-cased
        // *output* pin (the loop var, readable only inside the body) but it
        // is not a primary value binding — `resolveInput` handles it
        // directly. The loop nodes are expanded by the scope walker
        // (`emitScope`), never reaching the flat `discardUnconsumedResult`.
        // `Switch` (flow-codegen#22) is a control-flow command — like
        // `Branch`, it routes execution through its `case<N>`/`default`
        // exec outputs, producing no data value. The scope walker
        // (`emitScope`) expands it to a `switch` statement (`emitSwitch`);
        // it never reaches the flat `discardUnconsumedResult` path.
        // `Log` (flow-codegen#20) is a debug-print command — it lowers to
        // a `std.debug.print` statement and binds no data value, same as
        // `SetField` / `Emit` / `SetVariable`.
        // `ListAppend`/`ListSet`/`ListClear` are command list ops, and
        // `ForEach` is a control-flow loop node (expanded by the scope
        // walker, like `ForRange`) — none bind a data value
        // (flow-codegen#24). Likewise `MapSet`/`MapRemove`/`MapClear` are
        // command map ops and `MapForEach` is a control-flow loop node.
        .SetField, .Output, .Emit, .Event, .SetVariable, .ChangeVariable, .ClearVariable, .Branch, .ForRange, .While, .Switch, .Log, .ListAppend, .ListSet, .ListClear, .ForEach, .MapSet, .MapRemove, .MapClear, .MapForEach => "",
    };
}

pub fn isInputPin(k: flow_io.NodeKind, pin: []const u8) bool {
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
        // Compare is binary (`a`,`b`); Logic accepts `a` (+ `b` for
        // and/or — a stray `b` on a `not` node is ignored at lowering).
        .Compare, .Logic => std.mem.eql(u8, pin, "a") or std.mem.eql(u8, pin, "b"),
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
        // `Branch` consumes a single `cond` data input pin (a `bool`)
        // — flow-codegen#8. Its `then`/`else` are exec *outputs* wired
        // via `Flow.exec_edges`, not data input pins, so they never
        // appear here.
        .Branch => std.mem.eql(u8, pin, "cond"),
        // `ForRange` consumes three data inputs — `start`, `end`, `step`
        // (all unwired-defaultable; see `writeNodeBody`). Its `body` is an
        // exec *output* and `index` is a data *output* (the loop var), so
        // neither appears here (flow-codegen#21).
        .ForRange => std.mem.eql(u8, pin, "start") or
            std.mem.eql(u8, pin, "end") or
            std.mem.eql(u8, pin, "step"),
        // `While` consumes a single `cond` data input (a `bool`); its
        // `body` is an exec output, wired via `exec_edges` (flow-codegen#21).
        .While => std.mem.eql(u8, pin, "cond"),
        // `Select` (flow-codegen#22) consumes a `selector` data input, a
        // `default` value input, and positional `case<N>` value inputs
        // (mirroring `Call`'s `arg<N>`). All are data edges — `Select` has
        // no exec wiring.
        .Select => std.mem.eql(u8, pin, "selector") or
            std.mem.eql(u8, pin, "default") or
            isSelectCasePin(pin),
        // `Switch` (flow-codegen#22) consumes a single `selector` data
        // input. Its `case<N>`/`default` are exec *outputs* wired via
        // `Flow.exec_edges`, not data input pins, so they never appear here.
        .Switch => std.mem.eql(u8, pin, "selector"),
        // `Log` (flow-codegen#20) consumes a single optional `value` data
        // input — the thing to print. Unwired is valid (label-only print).
        .Log => std.mem.eql(u8, pin, "value"),
        // List operation data inputs (flow-codegen#24). The list itself is
        // referenced by `collection` name, not a pin.
        //   ListAppend → `value`; ListSet → `index`, `value`;
        //   ListGet → `index`; ListContains → `value`.
        // ListLength/ListClear take no data input; ForEach takes none (its
        // `body` is an exec output and `item`/`index` are data outputs).
        .ListAppend, .ListContains => std.mem.eql(u8, pin, "value"),
        .ListGet => std.mem.eql(u8, pin, "index"),
        .ListSet => std.mem.eql(u8, pin, "index") or std.mem.eql(u8, pin, "value"),
        .ListLength, .ListClear, .ForEach => false,
        // Map operation data inputs (flow-codegen#24, MAPS). The map itself
        // is referenced by `collection` name, not a pin.
        //   MapSet → `key`, `value`; MapGet → `key`, `default`;
        //   MapHas/MapRemove → `key`.
        // MapClear/MapLength take no data input; MapForEach takes none (its
        // `body` is an exec output and `key`/`value` are data outputs).
        .MapSet => std.mem.eql(u8, pin, "key") or std.mem.eql(u8, pin, "value"),
        .MapGet => std.mem.eql(u8, pin, "key") or std.mem.eql(u8, pin, "default"),
        .MapHas, .MapRemove => std.mem.eql(u8, pin, "key"),
        .MapClear, .MapLength, .MapForEach => false,
        // String reporters (flow-codegen#26). `Format`/`Concat` take
        // positional `arg<N>` value inputs (the same convention as
        // `Call`); `IntToString`/`FloatToString` take a single `value`
        // input (the number to render).
        .Format, .Concat => isCallArgPin(pin),
        .IntToString, .FloatToString => std.mem.eql(u8, pin, "value"),
    };
}

/// True for a `Select` value-input pin named `case<N>` (`case0`, `case1`,
/// …) — the positional case inputs of the pure-expression picker
/// (flow-codegen#22). Same shape as `isCallArgPin`, keyed on the `case`
/// prefix.
pub fn isSelectCasePin(pin: []const u8) bool {
    if (!std.mem.startsWith(u8, pin, "case")) return false;
    const tail = pin[4..];
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn isCallArgPin(pin: []const u8) bool {
    if (!std.mem.startsWith(u8, pin, "arg")) return false;
    const tail = pin[3..];
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn countCallArgs(flow: flow_io.Flow, node_id: u32) usize {
    var max_idx: ?usize = null;
    for (flow.edges) |e| {
        if (e.to.node != node_id) continue;
        if (!std.mem.startsWith(u8, e.to.pin, "arg")) continue;
        const idx = std.fmt.parseInt(usize, e.to.pin[3..], 10) catch continue;
        if (max_idx == null or idx > max_idx.?) max_idx = idx;
    }
    return if (max_idx) |m| m + 1 else 0;
}

/// Count a `Select` node's wired `case<N>` value inputs (flow-codegen#22) —
/// the case-prong count of the inline `switch` expression. Returns
/// `max(N)+1` over the wired `case<N>` **data** edges into `node_id`, or
/// `0` when none are wired. Same counting shape as `countCallArgs`.
pub fn countSelectCases(flow: flow_io.Flow, node_id: u32) usize {
    var max_idx: ?usize = null;
    for (flow.edges) |e| {
        if (e.to.node != node_id) continue;
        if (!std.mem.startsWith(u8, e.to.pin, "case")) continue;
        const idx = std.fmt.parseInt(usize, e.to.pin[4..], 10) catch continue;
        if (max_idx == null or idx > max_idx.?) max_idx = idx;
    }
    return if (max_idx) |m| m + 1 else 0;
}

/// Count a `Switch` node's wired `case<N>` exec outputs (flow-codegen#22) —
/// the prong count of the lowered `switch` statement. Returns `max(N)+1`
/// over the wired `case<N>` **exec** edges FROM `node_id`, or `0` when none
/// are wired. Unlike the data-edge counters this scans `exec_edges`.
pub fn countSwitchCases(flow: flow_io.Flow, node_id: u32) usize {
    var max_idx: ?usize = null;
    for (flow.exec_edges) |x| {
        if (x.from.node != node_id) continue;
        if (!std.mem.startsWith(u8, x.from.pin, "case")) continue;
        const idx = std.fmt.parseInt(usize, x.from.pin[4..], 10) catch continue;
        if (max_idx == null or idx > max_idx.?) max_idx = idx;
    }
    return if (max_idx) |m| m + 1 else 0;
}

// =====================================================================
// Shape helpers
// =====================================================================

pub fn hasParam(params: []const flow_io.Param, name: []const u8) bool {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

pub fn anyOutput(nodes: []const flow_io.Node) bool {
    for (nodes) |n| if (n.kind == .Output) return true;
    return false;
}

/// Collect the `Output` nodes of a flow, in ascending-id order so the
/// generated return struct field order is deterministic (RFC §6).
pub fn collectOutputs(
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
pub fn assertNoOutputCollision(
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
