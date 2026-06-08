//! Control-flow scopes (flow-codegen#8) and the scope-driven body walker.
//!
//! Computes each node's control-flow scope (the `Branch`/loop nesting it
//! lives in), then emits the topo-sorted node bodies, expanding `Branch`
//! into `if`/`else`, `Switch` into a `switch` statement, and the loop
//! family (`ForRange`/`While`/`ForEach`) into the matching Zig loop.

const std = @import("std");
const flow_io = @import("../flow_io.zig");
const errors = @import("errors.zig");
const pins = @import("pins.zig");
const graph = @import("graph.zig");
const nodes = @import("nodes.zig");
const inliner = @import("inline.zig");
const text = @import("text.zig");

const CodegenError = errors.CodegenError;
const GraphContext = graph.GraphContext;
const primaryOutputPin = pins.primaryOutputPin;
const countSwitchCases = pins.countSwitchCases;
const writePreviewPulse = nodes.writePreviewPulse;
const writeNodeBody = nodes.writeNodeBody;
const discardUnconsumedResult = graph.discardUnconsumedResult;
const deepInlineExpr = inliner.deepInlineExpr;
const computeWhileSuppressed = inliner.computeWhileSuppressed;
const indentBlock = text.indentBlock;

// =====================================================================
// Control flow — scopes (flow-codegen#8)
// =====================================================================

/// One frame of a control-flow scope path: a `Branch` id plus which of
/// its two exec sides we descended into. A scope is a slice of these,
/// root-to-leaf; the empty slice is the top-level scope.
const ScopeFrame = struct {
    branch: u32,
    /// `"then"` or `"else"` — the exec pin we entered the branch by.
    side: []const u8,
};

/// Per-node computed scope (`node id → scope path`). Scopes are owned by
/// an internal arena freed in `deinit`; `get` returns the empty slice
/// for any node with no recorded scope (top-level / unknown).
const ScopeMap = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMap(u32, []const ScopeFrame),

    fn get(self: *const ScopeMap, id: u32) []const ScopeFrame {
        return self.map.get(id) orelse &.{};
    }

    fn deinit(self: *ScopeMap) void {
        self.map.deinit();
        self.arena.deinit();
    }
};

fn scopeEql(a: []const ScopeFrame, b: []const ScopeFrame) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.branch != y.branch or !std.mem.eql(u8, x.side, y.side)) return false;
    }
    return true;
}

/// True when `anc` is an ancestor-or-equal of `desc` — i.e. `anc` is a
/// prefix of `desc`. The lowest-common-ancestor reporter sink relies on
/// this (a reporter sinks to the deepest scope that is a prefix of every
/// consumer's scope).
fn scopePrefix(anc: []const ScopeFrame, desc: []const ScopeFrame) bool {
    if (anc.len > desc.len) return false;
    return scopeEql(anc, desc[0..anc.len]);
}

/// Lowest common ancestor of two scope paths — their longest shared
/// prefix. Returns a sub-slice of `a` (no allocation), valid as long as
/// `a` lives.
fn scopeLca(a: []const ScopeFrame, b: []const ScopeFrame) []const ScopeFrame {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i].branch != b[i].branch or !std.mem.eql(u8, a[i].side, b[i].side)) break;
    }
    return a[0..i];
}

/// Append one frame to a scope, returning a freshly allocated path on
/// `allocator`. The `side` string is a comptime literal (`"then"` /
/// `"else"`) so it is not duped.
fn appendFrame(
    allocator: std.mem.Allocator,
    scope: []const ScopeFrame,
    branch: u32,
    side: []const u8,
) ![]ScopeFrame {
    const out = try allocator.alloc(ScopeFrame, scope.len + 1);
    @memcpy(out[0..scope.len], scope);
    out[scope.len] = .{ .branch = branch, .side = side };
    return out;
}

/// Compute every node's control-flow scope (flow-codegen#8).
///
/// **Command / `Branch` nodes** take the scope of the exec edge that
/// targets them: a node entered from `(B, side)` has scope `scope(B) ++
/// (B, side)`, which nests naturally (the branch `B`'s own scope is
/// resolved the same way, recursively). A node targeted by no exec edge
/// is top-level. Resolution memoizes and guards against an exec-edge
/// cycle (a malformed graph) by bailing to top-level rather than
/// looping.
///
/// **Reporter nodes** (anything with a primary output pin) take the
/// lowest-common-ancestor of all their data consumers' scopes — the
/// deepest scope that is an ancestor-or-equal of *every* consumer's
/// scope. A reporter consumed only inside one branch side sinks into
/// that side (so a `GetVariable` reading a `SetVariable` from the same
/// side lands after it); a reporter shared across sides bubbles up to
/// the common ancestor and computes before the `if`. An unconsumed
/// reporter is top-level. Reporters are resolved in reverse topo order
/// so each consumer's scope is known before its producers'.
fn computeScopes(
    allocator: std.mem.Allocator,
    ctx: *GraphContext,
) (CodegenError || std.mem.Allocator.Error)!ScopeMap {
    var sm: ScopeMap = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .map = std.AutoHashMap(u32, []const ScopeFrame).init(allocator),
    };
    errdefer sm.deinit();
    const a = sm.arena.allocator();

    // 1. Exec-targeted nodes take the scope of the exec edge targeting
    //    them. Commands / Branch nodes are the usual case, but a reporter
    //    can also be exec-wired into a branch (a side-effecting
    //    Call/CustomNode/Subflow run for its effect, value unused) — it
    //    must run on that side, so exec-targeted reporters take their exec
    //    scope here rather than falling to the data-consumer LCA below,
    //    which would leave an unconsumed one top-level (flow-codegen#8).
    for (ctx.flow.nodes) |n| {
        if (n.kind == .Event) continue;
        if (isReporter(n.kind) and !isExecTarget(ctx, n.id)) continue;
        const sc = try execScopeOf(a, ctx, n.id, 0);
        try sm.map.put(n.id, sc);
    }

    // 2. Reporter scopes = LCA of consumers' scopes, in reverse topo
    //    order so consumers (which appear later in topo order) are
    //    resolved first.
    var i: usize = ctx.order.len;
    while (i > 0) {
        i -= 1;
        const id = ctx.order[i];
        const node = ctx.index.byId(id) orelse unreachable;
        if (node.kind == .Event) continue;
        if (!isReporter(node.kind)) continue;
        // An exec-wired reporter already got its scope in step 1.
        if (sm.map.contains(id)) continue;

        var acc: ?[]const ScopeFrame = null;
        var any_consumer = false;
        for (ctx.flow.edges) |e| {
            if (e.from.node != id) continue;
            any_consumer = true;
            const consumer_scope = sm.get(e.to.node);
            if (acc) |cur| {
                acc = scopeLca(cur, consumer_scope);
            } else {
                acc = consumer_scope;
            }
        }
        // Unconsumed reporters stay top-level. The LCA sub-slices alias
        // a consumer's stored path, which the arena keeps alive; dupe to
        // a fresh allocation so the entry owns its bytes regardless of
        // later mutation.
        if (any_consumer) {
            const lca = acc orelse &.{};
            try sm.map.put(id, try a.dupe(ScopeFrame, lca));
        }
    }

    return sm;
}

/// Validate that every consumer of a `ForRange` node's `index` output is
/// within that loop's body scope (flow-codegen#21, bugbot "ForRange index
/// used out of scope"). `resolveInput` maps an `index` wire to the loop
/// var `i_<id>`, which is declared only inside the loop's body block; a
/// consumer computed OUTSIDE that scope would emit an out-of-scope read.
///
/// The body scope is `scope(forrange) ++ { branch: <forrange id>, side:
/// "body" }`. A valid consumer's computed scope must be that body scope
/// or a descendant (`scopePrefix(body_scope, consumer_scope)`). Otherwise
/// the flow is malformed — `error.MalformedFlow` (matching the existing
/// error set rather than emitting uncompilable Zig).
fn validateForRangeIndexScopes(
    allocator: std.mem.Allocator,
    ctx: *GraphContext,
    scopes: *const ScopeMap,
) (CodegenError || std.mem.Allocator.Error)!void {
    for (ctx.flow.nodes) |*n| {
        if (n.kind != .ForRange) continue;
        // The loop's body scope: the ForRange's own scope plus the
        // `body` frame (reusing the `branch`/`side` frame shape the loop
        // emission already relies on — see `emitLoop`).
        const own_scope = scopes.get(n.id);
        const body_scope = try appendFrame(allocator, own_scope, n.id, "body");
        defer allocator.free(body_scope);

        for (ctx.flow.edges) |e| {
            if (e.from.node != n.id) continue;
            if (!std.mem.eql(u8, e.from.pin, "index")) continue;
            const consumer_scope = scopes.get(e.to.node);
            if (!scopePrefix(body_scope, consumer_scope)) {
                return error.MalformedFlow;
            }
        }
    }
}

/// Validate that every consumer of a `ForEach` node's `item` / `index`
/// output is within that loop's body scope (flow-codegen#24) — the
/// direct analogue of `validateForRangeIndexScopes`. The `item_<id>` /
/// `idx_<id>` captures are declared only inside the `for` body block; a
/// consumer computed OUTSIDE that scope would emit an out-of-scope read,
/// so the flow is `error.MalformedFlow`.
fn validateForEachCaptureScopes(
    allocator: std.mem.Allocator,
    ctx: *GraphContext,
    scopes: *const ScopeMap,
) (CodegenError || std.mem.Allocator.Error)!void {
    for (ctx.flow.nodes) |*n| {
        if (n.kind != .ForEach) continue;
        const own_scope = scopes.get(n.id);
        const body_scope = try appendFrame(allocator, own_scope, n.id, "body");
        defer allocator.free(body_scope);

        for (ctx.flow.edges) |e| {
            if (e.from.node != n.id) continue;
            // Only the `item`/`index` data outputs are scope-bound captures.
            if (!std.mem.eql(u8, e.from.pin, "item") and
                !std.mem.eql(u8, e.from.pin, "index")) continue;
            const consumer_scope = scopes.get(e.to.node);
            if (!scopePrefix(body_scope, consumer_scope)) {
                return error.MalformedFlow;
            }
        }
    }
}

/// Validate that every consumer of a `MapForEach` node's `key` / `value`
/// output is within that loop's body scope (flow-codegen#24, MAPS) — the
/// direct analogue of `validateForEachCaptureScopes`. The `entry_<id>`
/// capture (whose `key_ptr`/`value_ptr` the outputs read) is declared only
/// inside the `while` body block; a consumer computed OUTSIDE that scope
/// would emit an out-of-scope read, so the flow is `error.MalformedFlow`.
fn validateMapForEachCaptureScopes(
    allocator: std.mem.Allocator,
    ctx: *GraphContext,
    scopes: *const ScopeMap,
) (CodegenError || std.mem.Allocator.Error)!void {
    for (ctx.flow.nodes) |*n| {
        if (n.kind != .MapForEach) continue;
        const own_scope = scopes.get(n.id);
        const body_scope = try appendFrame(allocator, own_scope, n.id, "body");
        defer allocator.free(body_scope);

        for (ctx.flow.edges) |e| {
            if (e.from.node != n.id) continue;
            // Only the `key`/`value` data outputs are scope-bound captures.
            if (!std.mem.eql(u8, e.from.pin, "key") and
                !std.mem.eql(u8, e.from.pin, "value")) continue;
            const consumer_scope = scopes.get(e.to.node);
            if (!scopePrefix(body_scope, consumer_scope)) {
                return error.MalformedFlow;
            }
        }
    }
}

/// Resolve a command/`Branch` node's scope from the exec edge targeting
/// it. `depth` guards against an exec-edge cycle in a malformed graph —
/// beyond the node count there must be a loop, so bail to top-level.
fn execScopeOf(
    a: std.mem.Allocator,
    ctx: *GraphContext,
    node_id: u32,
    depth: usize,
) (CodegenError || std.mem.Allocator.Error)![]const ScopeFrame {
    if (depth > ctx.flow.nodes.len) return &.{};
    for (ctx.flow.exec_edges) |x| {
        if (x.to_node != node_id) continue;
        // The branch's own scope, then descend into this side.
        const branch_scope = try execScopeOf(a, ctx, x.from.node, depth + 1);
        return try appendFrame(a, branch_scope, x.from.node, x.from.pin);
    }
    return &.{};
}

/// A node is a "reporter" when it binds a value (`n<id>_…`) — it has a
/// non-empty primary output pin. Commands (`SetVariable`, `Branch`, …)
/// and the trigger `Event` node return `false`.
fn isReporter(k: flow_io.NodeKind) bool {
    return primaryOutputPin(k).len != 0;
}

/// Whether any exec edge targets `node_id` (the loader guarantees at
/// most one). Such a node runs on a branch side regardless of whether
/// it's a command or a value-binding reporter (flow-codegen#8).
fn isExecTarget(ctx: *GraphContext, node_id: u32) bool {
    for (ctx.flow.exec_edges) |x| {
        if (x.to_node == node_id) return true;
    }
    return false;
}

/// Emit the topo-sorted node bodies for a flow into `w`. `emit_preview`
/// gates the per-node `emitNodeEntered` pulse — it reads `game`, so an
/// `OnEvent` handler (which has no `game`) passes `false`.
///
/// `Event` nodes (RFC-FLOW-VOCABULARY §3) are graph triggers and emit
/// no body — they're dropped here so they participate in neither the
/// preview pulse nor the body lowering.
pub fn emitBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    // Flow-local (temporary) variables (issue #23). Each `locals` entry
    // lowers to a function-scoped `var <name>: <type> = <default>;` at
    // the TOP of the handler body — re-initialized on every invocation,
    // NOT a module-level `pub var` (those come from `flow.variables` and
    // are emitted at module scope in `generate`). The variable nodes
    // (`GetVariable` / `SetVariable` / …) resolve a bare `<name>`, which
    // now binds to this in-scope local; collisions with a file-scope
    // `variables` name are rejected in `flow_io.validate`, so no routing
    // is needed.
    //
    // Never-mutated lint: a function-local `var` that is never written
    // (a local touched only by `GetVariable`) trips Zig's "local
    // variable is never mutated, use const"; one never read trips
    // "unused local variable". A trailing `_ = &<name>;` takes the
    // variable's address, which both counts as a use AND defeats the
    // never-mutated lint (the address could escape and be written
    // through), so a single suppressor handles the read-only,
    // write-only, and never-touched cases uniformly — and is a harmless
    // no-op when the local IS mutated by a `SetVariable`/`ChangeVariable`
    // downstream. (Module-level `pub var`s don't get either lint, so
    // this is new to the function-local path.)
    for (ctx.flow.locals) |v| {
        try w.print("    var {s}: {s} = {s};\n", .{ v.name, v.type, v.default.zig_text });
        try w.print("    _ = &{s};\n", .{v.name});
    }

    // Control flow (flow-codegen#8). With zero `Branch` nodes / empty
    // `exec_edges` every node's scope is the top-level (empty) path and
    // `emitScope(top)` walks the topo `order` exactly as the old flat
    // loop did — the output is byte-for-byte identical to the
    // pre-control-flow shape. When a `Branch` is present its `then`/`else`
    // sides are emitted as nested `if`/`else` blocks (see `emitScope`).
    var scopes = try computeScopes(allocator, ctx);
    defer scopes.deinit();

    // ForRange `index` scope validation (flow-codegen#21, bugbot
    // "ForRange index used out of scope"): the loop var `i_<id>` is
    // declared only inside the loop's body block, so every consumer of a
    // `ForRange.index` output must compute within that body scope (or a
    // descendant). A consumer outside it would emit an out-of-scope
    // `i_<id>` read → a Zig "use of undeclared identifier". Reject such a
    // flow up front rather than emit uncompilable code.
    try validateForRangeIndexScopes(allocator, ctx, &scopes);

    // ForEach `item`/`index` scope validation (flow-codegen#24): same
    // shape as `ForRange.index` — the `item_<id>` / `idx_<id>` captures
    // are declared only inside the `for` body block, so every consumer of
    // a `ForEach.item`/`ForEach.index` output must compute within that
    // body scope (or a descendant). Reject an out-of-scope read up front.
    try validateForEachCaptureScopes(allocator, ctx, &scopes);

    // MapForEach `key`/`value` scope validation (flow-codegen#24, MAPS):
    // same shape as `ForEach` — the `entry_<id>` capture is declared only
    // inside the `while` body block, so every consumer of a
    // `MapForEach.key`/`MapForEach.value` output must compute within that
    // body scope (or a descendant). Reject an out-of-scope read up front.
    try validateMapForEachCaptureScopes(allocator, ctx, &scopes);

    // Suppression pre-pass (flow-codegen#21, bugbot "While cond leaves
    // unused bindings"): a reporter wired ONLY into `While.cond` pins
    // (transitively, through other inlined reporters) is inlined into the
    // `while` header by `deepInlineExpr` and never read through its
    // `n<id>_…` binding. Emitting that binding would leave an orphaned,
    // unused `const` → a Zig compile error. Skip such nodes entirely.
    var suppressed = try computeWhileSuppressed(allocator, ctx);
    defer suppressed.deinit();

    try emitScope(allocator, w, ctx, flow_name, emit_preview, &scopes, &suppressed, &.{}, scratch.allocator());
}

/// Emit every node whose computed scope equals `scope`, in topo order.
/// A `Branch` node at this scope expands to a Zig `if (<cond>) { … }
/// else { … }`, with each side recursively emitted at `scope ++ (branch,
/// side)`. Nested-block bodies are rendered to a buffer and re-indented
/// with `indentBlock` (the same mechanism `renderNewFormEventEntry` uses
/// for the function body) so `writeNodeBody`'s hardcoded 4-space base
/// indent compounds cleanly per nesting level without threading an
/// indent counter through every emission helper (flow-codegen#8).
fn emitScope(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    for (ctx.order) |id| {
        const node = ctx.index.byId(id) orelse unreachable;
        if (node.kind == .Event) continue;

        // Reporters inlined exclusively into `While` conds (suppression
        // pre-pass) emit nothing — their value lives in the inlined
        // `while` header, not an `n<id>_…` binding (flow-codegen#21).
        if (suppressed.contains(id)) continue;

        const node_scope = scopes.get(id);
        if (!scopeEql(node_scope, scope)) continue;

        if (node.kind == .Branch) {
            try emitBranch(allocator, w, ctx, flow_name, emit_preview, scopes, suppressed, scope, node, scratch);
            continue;
        }

        // Loop control nodes (flow-codegen#21) expand to a `while` header
        // wrapping the recursively-emitted body scope — mirroring how a
        // `Branch` expands to nested `if`/`else` blocks (see `emitLoop`).
        if (node.kind == .ForRange or node.kind == .While) {
            try emitLoop(allocator, w, ctx, flow_name, emit_preview, scopes, suppressed, scope, node, scratch);
            continue;
        }

        // `ForEach` (flow-codegen#24) joins the loop family — it expands to
        // a `for (<list>.items, 0..) |item_<id>, idx_<id>|` header wrapping
        // the recursively-emitted body scope (see `emitForEach`).
        if (node.kind == .ForEach) {
            try emitForEach(allocator, w, ctx, flow_name, emit_preview, scopes, suppressed, scope, node, scratch);
            continue;
        }

        // `MapForEach` (flow-codegen#24, MAPS) is the map analogue — it
        // expands to a `var it_<id> = <map>.iterator(); while
        // (it_<id>.next()) |entry_<id>| { … }` wrapping the recursively-
        // emitted body scope (see `emitMapForEach`).
        if (node.kind == .MapForEach) {
            try emitMapForEach(allocator, w, ctx, flow_name, emit_preview, scopes, suppressed, scope, node, scratch);
            continue;
        }

        // `Once`/`Cooldown` (flow-codegen#47) are exec-gates: they expand to
        // a single guarded `if` wrapping the recursively-emitted body scope
        // (no `else`), the single-output analogue of `emitBranch` (see
        // `emitGate`). Their gate state is a per-node module-level `pub var`
        // emitted by `entry.zig`.
        if (node.kind == .Once or node.kind == .Cooldown) {
            try emitGate(allocator, w, ctx, flow_name, emit_preview, scopes, suppressed, scope, node, scratch);
            continue;
        }

        // `Switch` (flow-codegen#22) expands to a `switch` statement with a
        // block per case side, mirroring how a `Branch` expands to nested
        // `if`/`else` blocks (see `emitSwitch`).
        if (node.kind == .Switch) {
            try emitSwitch(allocator, w, ctx, flow_name, emit_preview, scopes, suppressed, scope, node, scratch);
            continue;
        }

        if (emit_preview) try writePreviewPulse(w, flow_name, node.id);
        try writeNodeBody(w, node, ctx, scratch);
        try discardUnconsumedResult(w, node, ctx);
    }
}

/// Lower a `Branch` node at `scope` to `if (<cond>) { … } else { … }`.
/// The `cond` data input resolves through the normal pin machinery;
/// unwired it defaults to `false` (flow-codegen#8). Each side's body is
/// the recursive `emitScope` of `scope ++ (branch, side)` — every
/// command/`Branch` reached by an exec edge from this side, plus every
/// reporter whose lowest-common-ancestor scope sinks into that side.
fn emitBranch(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    node: *const flow_io.Node,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (emit_preview) try writePreviewPulse(w, flow_name, node.id);

    const cond_expr = (try ctx.resolveInput(scratch, node, "cond")) orelse
        try scratch.dupe(u8, "false");

    inline for (.{ "then", "else" }) |side| {
        // Render the side's body to a buffer, then re-indent it one
        // level so it nests under the `if`/`else`. An empty side still
        // emits `{}` — a valid, if vacuous, Zig block.
        var side_aw: std.Io.Writer.Allocating = .init(allocator);
        defer side_aw.deinit();
        const child = try appendFrame(allocator, scope, node.id, side);
        defer allocator.free(child);
        try emitScope(allocator, &side_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
        const body = side_aw.written();

        if (std.mem.eql(u8, side, "then")) {
            try w.print("    if ({s}) {{\n", .{cond_expr});
        } else {
            try w.writeAll("    } else {\n");
        }
        // The side body already ends in `\n`; `indentBlock` preserves
        // that trailing newline (its final, empty split element writes
        // the `\n` but no content), so the cursor lands at a fresh line
        // ready for the next `} else {` / closing `}`.
        if (body.len != 0) try indentBlock(w, body, "    ");
    }
    try w.writeAll("    }\n");
}

/// Lower a `Switch` node at `scope` to a Zig `switch` STATEMENT
/// (flow-codegen#22) — the N-way analogue of `emitBranch`. The `selector`
/// data input resolves through the normal pin machinery; unwired it
/// defaults to `0`. Each wired `case<N>` exec output becomes a prong
/// `N => { <emitScope(case<N>)> }`, and the `default` exec output becomes
/// the `else => { … }` prong (an empty `else => {}` when `default` is
/// unwired, so the lowered switch is exhaustive valid Zig). Each side's
/// body is the recursive `emitScope` of `scope ++ (switch id, "case<N>")`
/// (or `"default"`), buffered and re-indented one level with `indentBlock`
/// exactly like `emitBranch`'s sides.
fn emitSwitch(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    node: *const flow_io.Node,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (emit_preview) try writePreviewPulse(w, flow_name, node.id);

    const sel_expr = (try ctx.resolveInput(scratch, node, "selector")) orelse
        try scratch.dupe(u8, "0");

    try w.print("    switch ({s}) {{\n", .{sel_expr});

    // One prong per wired `case<N>` exec output. The side string `"case<N>"`
    // is the `ScopeFrame.side` `execScopeOf` produced for nodes reached by
    // that exec edge — `scopeEql` matches on the bytes, so formatting a
    // fresh `case<N>` here keys the same scope. Allocated on `scratch` so it
    // outlives the child scope's use within this iteration.
    const ncases = countSwitchCases(ctx.flow, node.id);
    var i: usize = 0;
    while (i < ncases) : (i += 1) {
        const side = try std.fmt.allocPrint(scratch, "case{d}", .{i});

        var side_aw: std.Io.Writer.Allocating = .init(allocator);
        defer side_aw.deinit();
        const child = try appendFrame(allocator, scope, node.id, side);
        defer allocator.free(child);
        try emitScope(allocator, &side_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
        const body = side_aw.written();

        if (body.len == 0) {
            // A prong wired to no body still needs a block to keep the
            // switch exhaustive over its label.
            try w.print("        {d} => {{}},\n", .{i});
        } else {
            try w.print("        {d} => {{\n", .{i});
            try indentBlock(w, body, "        ");
            try w.writeAll("        },\n");
        }
    }

    // The `else` prong from the `default` exec output. An unwired `default`
    // still emits `else => {}` so the switch is exhaustive valid Zig.
    {
        var def_aw: std.Io.Writer.Allocating = .init(allocator);
        defer def_aw.deinit();
        const child = try appendFrame(allocator, scope, node.id, "default");
        defer allocator.free(child);
        try emitScope(allocator, &def_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
        const body = def_aw.written();

        if (body.len == 0) {
            try w.writeAll("        else => {},\n");
        } else {
            try w.writeAll("        else => {\n");
            try indentBlock(w, body, "        ");
            try w.writeAll("        },\n");
        }
    }

    try w.writeAll("    }\n");
}

/// Lower a `ForRange` / `While` loop node at `scope` to a Zig `while`
/// (flow-codegen#21). The body scope frame reuses the `branch` field as
/// the controlling node id with side `"body"`, so `execScopeOf` already
/// routes body-targeted nodes here (the field is named `branch` for the
/// `Branch`-era code, but it is just "the controlling node's id").
///
/// `ForRange` emits a scoped block declaring an explicit `i32` loop var
/// (`var i_<id>: i32 = …`) — Zig 0.16 rejects a bare `var i = 0` as a
/// `comptime_int`, so the annotation is required — and a counted
/// `while (i_<id> < <end>) : (i_<id> += <step>)`. Unwired
/// `start`/`end`/`step` default to `0`/`0`/`1`. The block scopes the loop
/// var so two `ForRange` nodes never collide even before the per-id
/// suffix.
///
/// `While` re-checks its condition every iteration, but the data model
/// binds reporters ONCE before the loop — referencing a binding would
/// freeze the condition. So the `cond` is **deep-inlined**
/// (`deepInlineExpr`) into the header: its pure reporter subtree is
/// expanded into a single Zig expression that re-reads its operands each
/// pass (e.g. a `Compare(GetVariable x, Literal 10)` → `while (x < 10)`).
/// A `cond` whose subtree can't be deep-inlined (a side-effecting
/// `Call` / `CustomNode` / `GetComponent` / `Subflow`) falls back to the
/// frozen `n<id>_…` binding reference — such a condition does NOT
/// re-evaluate (documented limitation; deep-inline covers the pure
/// comparison/logic/variable cases the loop nodes are designed for).
///
/// The body is rendered to a buffer and re-indented one level with
/// `indentBlock` — the same buffer+indent mechanism `emitBranch` uses —
/// so nested loop bodies compound the 4-space base indent cleanly.
fn emitLoop(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    node: *const flow_io.Node,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (emit_preview) try writePreviewPulse(w, flow_name, node.id);

    // Render the body scope to a buffer, then re-indent it under the loop
    // header. The body scope frame is `{ branch: <loop id>, side: "body" }`
    // — every node reached by the loop's `body` exec edge, plus every
    // reporter whose LCA scope sinks into the body (recomputed each pass).
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    defer body_aw.deinit();
    const child = try appendFrame(allocator, scope, node.id, "body");
    defer allocator.free(child);
    try emitScope(allocator, &body_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
    const body = body_aw.written();

    switch (node.kind) {
        .ForRange => {
            // Defaults: start → 0, end → 0, step → 1 (a zero-trip loop
            // when nothing is wired). The loop var is `i_<id>` so two
            // ForRange nodes never collide; the enclosing block scopes it.
            const start_expr = (try ctx.resolveInput(scratch, node, "start")) orelse
                try scratch.dupe(u8, "0");
            const end_expr = (try ctx.resolveInput(scratch, node, "end")) orelse
                try scratch.dupe(u8, "0");
            const step_expr = (try ctx.resolveInput(scratch, node, "step")) orelse
                try scratch.dupe(u8, "1");

            try w.writeAll("    {\n");
            try w.print("        var i_{d}: i32 = {s};\n", .{ node.id, start_expr });
            try w.print(
                "        while (i_{d} < {s}) : (i_{d} += {s}) {{\n",
                .{ node.id, end_expr, node.id, step_expr },
            );
            // Body buffered at the 4-space base; re-indent it two levels
            // (the enclosing block + the `while`) so its statements land at
            // 12 spaces.
            if (body.len != 0) try indentBlock(w, body, "        ");
            try w.writeAll("        }\n");
            try w.writeAll("    }\n");
        },
        .While => {
            // Deep-inline the cond so the `while` re-evaluates it each
            // iteration; fall back to `false` (loop never runs) when the
            // `cond` pin is unwired.
            const cond_expr = (try deepInlineExpr(scratch, ctx, node, "cond")) orelse
                try scratch.dupe(u8, "false");
            try w.print("    while ({s}) {{\n", .{cond_expr});
            if (body.len != 0) try indentBlock(w, body, "    ");
            try w.writeAll("    }\n");
        },
        else => unreachable,
    }
}

/// Lower an `Once` / `Cooldown` exec-gate node at `scope` to a single
/// guarded `if` wrapping the body scope (flow-codegen#47) — the
/// single-output analogue of `emitBranch` (one guarded scope, no `else`).
/// The body scope frame is `{ branch: <gate id>, side: "body" }`, so
/// `execScopeOf` already routes body-targeted nodes here, exactly like the
/// loop family.
///
/// `Once` flips a per-node `pub var __once_<flow_fn>_n<id>: bool` (emitted
/// by `entry.zig`) and runs the body the first time only:
/// `if (!__once_<flow_fn>_n<id>) { __once_<flow_fn>_n<id> = true; <body> }`.
/// The `<flow_fn>` prefix (`ctx.flow_fn` — the flow's sanitized function
/// name) namespaces the var per-flow, since node ids are only unique
/// WITHIN a flow (flow-codegen#47).
///
/// `Cooldown` compares the host game clock against a per-node `pub var
/// __cd_<flow_fn>_n<id>: f64` last-fired timestamp and re-blocks for `seconds`:
/// `if (game.elapsedSeconds() - __cd_<flow_fn>_n<id> >= <seconds>) {`
/// `    __cd_<flow_fn>_n<id> = game.elapsedSeconds(); <body> }`. `game.elapsedSeconds()`
/// is a host accessor provided by labelle-engine. The body is buffered and
/// re-indented one level with `indentBlock`, the same mechanism
/// `emitBranch`/`emitLoop` use, so nested gate bodies indent cleanly.
fn emitGate(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    node: *const flow_io.Node,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (emit_preview) try writePreviewPulse(w, flow_name, node.id);

    // Render the body scope to a buffer, then re-indent it under the guard
    // — same buffer+indent mechanism `emitBranch`/`emitLoop` use. The body
    // scope frame is `{ branch: <gate id>, side: "body" }`.
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    defer body_aw.deinit();
    const child = try appendFrame(allocator, scope, node.id, "body");
    defer allocator.free(child);
    try emitScope(allocator, &body_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
    const body = body_aw.written();

    switch (node.kind) {
        .Once => {
            // First-time-only gate: guard on the per-node bool, then set it
            // before running the body so re-entry is blocked forever. The
            // var is namespaced by the flow's function name (`ctx.flow_fn`)
            // so a gate at node id N in a subflow doesn't share state with a
            // gate at node id N in the entry flow (flow-codegen#47).
            try w.print("    if (!__once_{s}_n{d}) {{\n", .{ ctx.flow_fn, node.id });
            try w.print("        __once_{s}_n{d} = true;\n", .{ ctx.flow_fn, node.id });
            if (body.len != 0) try indentBlock(w, body, "    ");
            try w.writeAll("    }\n");
        },
        .Cooldown => {
            // Cooldown gate: open when at least `seconds` have elapsed since
            // the last firing, then stamp the clock before running the body.
            // `ctx.flow_fn` namespaces the per-node timestamp var the same
            // way `Once` namespaces its bool (flow-codegen#47).
            const seconds = node.kind.Cooldown.seconds;
            try w.print(
                "    if (game.elapsedSeconds() - __cd_{s}_n{d} >= {d}) {{\n",
                .{ ctx.flow_fn, node.id, seconds },
            );
            try w.print("        __cd_{s}_n{d} = game.elapsedSeconds();\n", .{ ctx.flow_fn, node.id });
            if (body.len != 0) try indentBlock(w, body, "    ");
            try w.writeAll("    }\n");
        },
        else => unreachable,
    }
}

/// Lower a `ForEach` node at `scope` to a Zig `for` over the named list
/// (flow-codegen#24). Joins the loop family: like `emitLoop`, the body
/// scope frame is `{ branch: <foreach id>, side: "body" }`, so
/// `execScopeOf` already routes body-targeted nodes here, and reporters
/// whose LCA scope sinks into the body recompute each pass.
///
/// Lowers to `for (<list>.items, 0..) |item_<id>, idx_<id>| { <body> }`.
/// The body reads the `item`/`index` output pins through `resolveInput`,
/// which maps them to `item_<id>` / `idx_<id>` (NOT `n<id>_…` bindings) —
/// mirroring `ForRange.index`.
///
/// Unused-capture handling: Zig errors on an unused `for` capture. We
/// detect whether the body wires the `item` / `index` output pins and
/// substitute `_` for an unread capture (e.g. a ForEach whose body never
/// reads `index` emits `|item_<id>, _|`). When NEITHER is read, both
/// become `_` and the loop runs purely for its body's side effects.
fn emitForEach(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    node: *const flow_io.Node,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (emit_preview) try writePreviewPulse(w, flow_name, node.id);

    // Render the body scope to a buffer, then re-indent it under the `for`
    // header — same buffer+indent mechanism `emitLoop`/`emitBranch` use.
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    defer body_aw.deinit();
    const child = try appendFrame(allocator, scope, node.id, "body");
    defer allocator.free(child);
    try emitScope(allocator, &body_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
    const body = body_aw.written();

    // A `for` capture that is never read is a Zig "unused capture" error.
    // Substitute `_` for an unread `item` / `index` output pin. The list
    // is referenced by name (the module-level `pub var std.ArrayList`).
    const collection = node.kind.ForEach.collection;
    const item_cap = if (anyConsumerOf(ctx, node.id, "item"))
        try std.fmt.allocPrint(scratch, "item_{d}", .{node.id})
    else
        try scratch.dupe(u8, "_");
    const idx_cap = if (anyConsumerOf(ctx, node.id, "index"))
        try std.fmt.allocPrint(scratch, "idx_{d}", .{node.id})
    else
        try scratch.dupe(u8, "_");

    try w.print(
        "    for ({s}.items, 0..) |{s}, {s}| {{\n",
        .{ collection, item_cap, idx_cap },
    );
    if (body.len != 0) try indentBlock(w, body, "    ");
    try w.writeAll("    }\n");
}

/// Lower a `MapForEach` node at `scope` to a Zig hash-map iterator loop
/// (flow-codegen#24, MAPS). The map analogue of `emitForEach`: the body
/// scope frame is `{ branch: <id>, side: "body" }`, so `execScopeOf` routes
/// body-targeted nodes here, and reporters whose LCA scope sinks into the
/// body recompute each pass.
///
/// Lowers to:
///   var it_<id> = <map>.iterator();
///   while (it_<id>.next()) |entry_<id>| { <body> }
/// The body reads the `key`/`value` output pins through `resolveInput`,
/// which maps them to `entry_<id>.key_ptr.*` / `entry_<id>.value_ptr.*`.
///
/// Unused-capture handling: a `while`-payload capture that is never read is
/// a Zig "unused capture" error. `entry_<id>` is always captured; when
/// NEITHER `key` nor `value` is read we discard it with `_ = entry_<id>;`
/// inside the body so the loop runs purely for its side effects.
fn emitMapForEach(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ctx: *GraphContext,
    flow_name: []const u8,
    emit_preview: bool,
    scopes: *const ScopeMap,
    suppressed: *const std.AutoHashMap(u32, void),
    scope: []const ScopeFrame,
    node: *const flow_io.Node,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    if (emit_preview) try writePreviewPulse(w, flow_name, node.id);

    // Render the body scope to a buffer, then re-indent it under the
    // `while` header — same buffer+indent mechanism `emitForEach` uses.
    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    defer body_aw.deinit();
    const child = try appendFrame(allocator, scope, node.id, "body");
    defer allocator.free(child);
    try emitScope(allocator, &body_aw.writer, ctx, flow_name, emit_preview, scopes, suppressed, child, scratch);
    const body = body_aw.written();

    const collection = node.kind.MapForEach.collection;
    const reads_entry = anyConsumerOf(ctx, node.id, "key") or
        anyConsumerOf(ctx, node.id, "value");

    try w.print("    var it_{d} = {s}.iterator();\n", .{ node.id, collection });
    try w.print("    while (it_{d}.next()) |entry_{d}| {{\n", .{ node.id, node.id });
    // Suppress the unused capture when the body reads neither field.
    if (!reads_entry) try w.print("        _ = entry_{d};\n", .{node.id});
    if (body.len != 0) try indentBlock(w, body, "    ");
    try w.writeAll("    }\n");
}

/// True when any data edge reads the `pin` output of node `id` — used by
/// `emitForEach` to decide whether a `for` capture is live (flow-codegen#24).
fn anyConsumerOf(ctx: *GraphContext, id: u32, pin: []const u8) bool {
    for (ctx.flow.edges) |e| {
        if (e.from.node == id and std.mem.eql(u8, e.from.pin, pin)) return true;
    }
    return false;
}
