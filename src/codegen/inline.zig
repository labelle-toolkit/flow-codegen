//! Deep-inlining of pure reporter subtrees (flow-codegen#21). Powers a
//! `While` header re-evaluating its condition each iteration, and the
//! suppression pre-pass that drops the now-orphaned `n<id>_…` bindings of
//! reporters consumed only by inlined `While` conds.

const std = @import("std");
const flow_io = @import("../flow_io.zig");
const errors = @import("errors.zig");
const pins = @import("pins.zig");
const graph = @import("graph.zig");

const CodegenError = errors.CodegenError;
const GraphContext = graph.GraphContext;
const primaryOutputPin = pins.primaryOutputPin;

/// Recursively expand the pure reporter subtree feeding `pin` on
/// `consumer` into a single Zig expression, allocated on `alloc`
/// (flow-codegen#21). Unlike `resolveInput` — which returns the
/// producer's once-bound `n<id>_…` *reference* — this re-reads the
/// producer's own inputs inline, so the expression recomputes wherever it
/// is placed (the key to a `While` header re-evaluating its condition).
///
/// Only *pure* reporter kinds are inlined: `GetVariable`, `Literal`,
/// `Identifier`, `HasValueVariable`, `BinOp`, `Compare`, `Logic`. Anything
/// else (a side-effecting `Call` / `CustomNode` / `GetComponent` /
/// `Subflow`, or a producer with no primary value) falls back to the
/// `resolveInput` binding reference — correct for value, but frozen
/// (does not re-evaluate). Returns `null` only when `pin` is unwired.
pub fn deepInlineExpr(
    alloc: std.mem.Allocator,
    ctx: *GraphContext,
    consumer: *const flow_io.Node,
    pin: []const u8,
) (CodegenError || std.mem.Allocator.Error)!?[]const u8 {
    const edge = ctx.index.producerOf(consumer.id, pin) orelse return null;
    const producer = ctx.index.byId(edge.from.node) orelse return error.UnknownPin;
    return try deepInlineNode(alloc, ctx, producer);
}

/// Inline a single producer node into a parenthesised Zig expression,
/// recursing through its own pure inputs. The fallback for a non-pure or
/// value-less producer is the `resolveInput` binding reference.
fn deepInlineNode(
    alloc: std.mem.Allocator,
    ctx: *GraphContext,
    producer: *const flow_io.Node,
) (CodegenError || std.mem.Allocator.Error)![]const u8 {
    switch (producer.kind) {
        // Leaf reporters — re-emit the source text verbatim, so a
        // `GetVariable` re-reads the file-scope `var` each iteration.
        .GetVariable => |b| return try alloc.dupe(u8, b.name),
        .Literal => |b| return try alloc.dupe(u8, b.value),
        .Identifier => |b| return try alloc.dupe(u8, b.name),
        // A `Param` is a pure leaf: it lowers to the containing flow's
        // sanitized fn-arg identifier (same as `nodes.zig`'s `.Param`
        // arm), which is in scope wherever the flow body — or a `Delay`
        // snapshot taken in it (flow-codegen#48, bugbot) — is emitted.
        // Inlining it (vs the frozen `n<id>_…` binding) is what lets a
        // Delay deferring a subflow wired from a param capture the param.
        .Param => |b| return try pins.sanitizeSymbol(alloc, b.param),
        .HasValueVariable => |b| return try std.fmt.allocPrint(alloc, "({s} != null)", .{b.name}),
        // Input reporters (labelle-gui#208 Option A) — pure host-state
        // reads that allocate nothing, so they re-emit the mixin call
        // verbatim each iteration (a `While(cond = IsKeyDown("w"))` polls
        // the held key every pass). `key` is spliced as a Zig enum literal
        // so it infers to `KeyboardKey` without importing the enum.
        .IsKeyDown => |b| return try std.fmt.allocPrint(alloc, "game.isKeyDown(.{f})", .{std.zig.fmtId(b.key)}),
        .IsKeyPressed => |b| return try std.fmt.allocPrint(alloc, "game.isKeyPressed(.{f})", .{std.zig.fmtId(b.key)}),
        .IsKeyReleased => |b| return try std.fmt.allocPrint(alloc, "game.isKeyReleased(.{f})", .{std.zig.fmtId(b.key)}),
        .IsMouseButtonDown => |b| return try std.fmt.allocPrint(alloc, "game.isMouseButtonDown(.{f})", .{std.zig.fmtId(b.button)}),
        .IsMouseButtonPressed => |b| return try std.fmt.allocPrint(alloc, "game.isMouseButtonPressed(.{f})", .{std.zig.fmtId(b.button)}),
        .IsMouseButtonReleased => |b| return try std.fmt.allocPrint(alloc, "game.isMouseButtonReleased(.{f})", .{std.zig.fmtId(b.button)}),
        .GetMouseX => return try alloc.dupe(u8, "game.getMouseX()"),
        .GetMouseY => return try alloc.dupe(u8, "game.getMouseY()"),
        .GetMouseWheel => return try alloc.dupe(u8, "game.getMouseWheelMove()"),
        // Gamepad reporters (labelle-assembler#250) are pure host-state
        // leaves too — re-emit the mixin call verbatim each iteration, with
        // the `button`/`axis` spliced as a Zig enum literal.
        .IsGamepadButtonDown => |b| return try std.fmt.allocPrint(alloc, "game.isGamepadButtonDown(0, .{f})", .{std.zig.fmtId(b.button)}),
        .IsGamepadButtonPressed => |b| return try std.fmt.allocPrint(alloc, "game.isGamepadButtonPressed(0, .{f})", .{std.zig.fmtId(b.button)}),
        .IsGamepadButtonReleased => |b| return try std.fmt.allocPrint(alloc, "game.isGamepadButtonReleased(0, .{f})", .{std.zig.fmtId(b.button)}),
        .GetGamepadAxisValue => |b| return try std.fmt.allocPrint(alloc, "game.getGamepadAxisValue(0, .{f})", .{std.zig.fmtId(b.axis)}),
        // Binary/unary combinators — recurse into each operand so the
        // whole subtree recomputes. Unwired operands fall back to the
        // same per-kind defaults `writeNodeBody` uses.
        .BinOp => |b| {
            const a_expr = (try deepInlineOperand(alloc, ctx, producer, "a")) orelse try alloc.dupe(u8, "0");
            const b_expr = (try deepInlineOperand(alloc, ctx, producer, "b")) orelse try alloc.dupe(u8, "0");
            const op_text: []const u8 = switch (b.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
            };
            return try std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ a_expr, op_text, b_expr });
        },
        .Compare => |b| {
            const a_expr = (try deepInlineOperand(alloc, ctx, producer, "a")) orelse try alloc.dupe(u8, "0");
            const b_expr = (try deepInlineOperand(alloc, ctx, producer, "b")) orelse try alloc.dupe(u8, "0");
            const op_text: []const u8 = switch (b.op) {
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
            };
            return try std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ a_expr, op_text, b_expr });
        },
        .Logic => |b| switch (b.op) {
            .not => {
                const a_expr = (try deepInlineOperand(alloc, ctx, producer, "a")) orelse try alloc.dupe(u8, "false");
                return try std.fmt.allocPrint(alloc, "(!{s})", .{a_expr});
            },
            .@"and", .@"or" => {
                const a_expr = (try deepInlineOperand(alloc, ctx, producer, "a")) orelse try alloc.dupe(u8, "false");
                const b_expr = (try deepInlineOperand(alloc, ctx, producer, "b")) orelse try alloc.dupe(u8, "false");
                const op_text: []const u8 = if (b.op == .@"and") "and" else "or";
                return try std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ a_expr, op_text, b_expr });
            },
        },
        // Side-effecting or value-less producers: fall back to the frozen
        // binding reference (does NOT re-evaluate — documented limitation).
        else => {
            const primary = primaryOutputPin(producer.kind);
            if (primary.len == 0) return error.UnknownPin;
            return try std.fmt.allocPrint(alloc, "n{d}_{s}", .{ producer.id, primary });
        },
    }
}

/// Resolve an operand `pin` of a node being deep-inlined: recurse when a
/// wire feeds it, `null` when it is unwired (caller supplies the default).
fn deepInlineOperand(
    alloc: std.mem.Allocator,
    ctx: *GraphContext,
    node: *const flow_io.Node,
    pin: []const u8,
) (CodegenError || std.mem.Allocator.Error)!?[]const u8 {
    const edge = ctx.index.producerOf(node.id, pin) orelse return null;
    const producer = ctx.index.byId(edge.from.node) orelse return error.UnknownPin;
    return try deepInlineNode(alloc, ctx, producer);
}

/// The pure, inlinable reporter kinds — the exact set `deepInlineNode`
/// expands in place (rather than falling back to the frozen `n<id>_…`
/// binding reference). Kept as a single predicate so the suppression
/// pre-pass (`collectWhileInlined`) walks precisely what `deepInlineExpr`
/// inlines: if these two ever diverge, a node could be suppressed yet
/// still reference an `n<id>_…` binding the pre-pass dropped, or vice
/// versa (flow-codegen#21, bugbot "While cond leaves unused bindings").
pub fn isInlinableKind(k: flow_io.NodeKind) bool {
    return switch (k) {
        .GetVariable, .Literal, .Identifier, .Param, .HasValueVariable, .BinOp, .Compare, .Logic => true,
        // Input reporters (labelle-gui#208 Option A) are pure host-state
        // leaves that allocate NOTHING — like `GetVariable`, they can be
        // re-emitted in place, so a `While`/`Delay` re-reads live input
        // each pass instead of freezing a once-bound value.
        .IsKeyDown, .IsKeyPressed, .IsKeyReleased, .IsMouseButtonDown, .IsMouseButtonPressed, .IsMouseButtonReleased, .GetMouseX, .GetMouseY, .GetMouseWheel => true,
        // Gamepad reporters (labelle-assembler#250) are pure host-state
        // leaves like the key/mouse reporters — inlinable, so a `While`/
        // `Delay` re-reads live gamepad state each pass.
        .IsGamepadButtonDown, .IsGamepadButtonPressed, .IsGamepadButtonReleased, .GetGamepadAxisValue => true,
        // String reporters (`Format`/`Concat`/`IntToString`/`FloatToString`,
        // flow-codegen#26) are intentionally absent from this set: they
        // ALLOCATE via `game.allocator`, so they must bind to an
        // `n<id>_value` local exactly once (like `Call`/`GetComponent`) —
        // inlining them per consumer would reallocate / leak on every read.
        else => false,
    };
}

/// Record every node id that gets *inlined* into some `While` node's
/// `cond` header, the same way `deepInlineExpr` walks it. Walking the
/// pure-reporter subtree feeding each `While.cond` and collecting the
/// visited ids gives the set `S`; `computeWhileSuppressed` then narrows
/// `S` to the nodes whose bindings are safe to drop.
///
/// The walk mirrors `deepInlineNode`: it descends only through
/// `isInlinableKind` producers (BinOp/Compare/Logic operands), and stops
/// at a non-inlinable producer — that producer is NOT added to `S`,
/// because `deepInlineNode` emits its frozen `n<id>_…` binding reference
/// there, so its binding is still needed.
fn collectWhileInlined(
    ctx: *GraphContext,
    inlined: *std.AutoHashMap(u32, void),
) std.mem.Allocator.Error!void {
    for (ctx.flow.nodes) |*n| {
        if (n.kind != .While) continue;
        const edge = ctx.index.producerOf(n.id, "cond") orelse continue;
        try collectInlinedFrom(ctx, edge.from.node, inlined);
    }
}

/// Walk the inlinable subtree rooted at producer `id`, recording each
/// inlinable node into `inlined`. A non-inlinable producer is the
/// boundary (its binding is referenced by the inlined expression), so it
/// is neither recorded nor descended through.
fn collectInlinedFrom(
    ctx: *GraphContext,
    id: u32,
    inlined: *std.AutoHashMap(u32, void),
) std.mem.Allocator.Error!void {
    const node = ctx.index.byId(id) orelse return;
    if (!isInlinableKind(node.kind)) return;
    const gop = try inlined.getOrPut(id);
    if (gop.found_existing) return; // already walked (shared subtree)
    // Descend through the operand pins `deepInlineNode` recurses into.
    // Leaf reporters (GetVariable/Literal/Identifier/HasValueVariable)
    // have no inlined operands; the combinators read `a`/`b`.
    inline for (.{ "a", "b" }) |pin| {
        if (ctx.index.producerOf(id, pin)) |e| {
            try collectInlinedFrom(ctx, e.from.node, inlined);
        }
    }
}

/// Compute the set of node ids to SUPPRESS — emit no binding, no
/// discard, no preview pulse. A node `n` in the inlined set `S` is
/// suppressed iff EVERY outgoing data edge from `n` targets either
/// (a) a `While` node's `cond` pin, or (b) another node in `S`. In that
/// case `n` exists only to compute inlined `While` conditions, so its
/// once-bound `n<id>_…` binding would be orphaned (the `while` header
/// inlines a recomputed copy instead). A node in `S` that ALSO feeds a
/// real consumer keeps its binding — the cond just inlines a separate
/// recomputed expression, which is correct.
///
/// Returns an arena-free `AutoHashMap`; the caller owns and `deinit`s it.
pub fn computeWhileSuppressed(
    allocator: std.mem.Allocator,
    ctx: *GraphContext,
) std.mem.Allocator.Error!std.AutoHashMap(u32, void) {
    var inlined = std.AutoHashMap(u32, void).init(allocator);
    defer inlined.deinit();
    try collectWhileInlined(ctx, &inlined);

    var suppressed = std.AutoHashMap(u32, void).init(allocator);
    errdefer suppressed.deinit();

    var it = inlined.keyIterator();
    while (it.next()) |id_ptr| {
        const id = id_ptr.*;
        var only_cond_or_inlined = true;
        for (ctx.flow.edges) |e| {
            if (e.from.node != id) continue;
            const target = ctx.index.byId(e.to.node) orelse {
                only_cond_or_inlined = false;
                break;
            };
            const into_while_cond = target.kind == .While and
                std.mem.eql(u8, e.to.pin, "cond");
            const into_inlined = inlined.contains(e.to.node);
            if (!into_while_cond and !into_inlined) {
                only_cond_or_inlined = false;
                break;
            }
        }
        if (only_cond_or_inlined) try suppressed.put(id, {});
    }

    return suppressed;
}
