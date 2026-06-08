//! Per-node body emission — the big `writeNodeBody` switch that lowers
//! each `flow_io.NodeKind` to its Zig template, plus the preview-pulse
//! emitter and the `Log` / `Subflow` argument helpers.

const std = @import("std");
const flow_io = @import("../flow_io.zig");
const errors = @import("errors.zig");
const pins = @import("pins.zig");
const graph = @import("graph.zig");
const text = @import("text.zig");

const CodegenError = errors.CodegenError;
const GraphContext = graph.GraphContext;
const sanitizeSymbol = pins.sanitizeSymbol;
const hasParam = pins.hasParam;
const anyOutput = pins.anyOutput;
const countCallArgs = pins.countCallArgs;
const countSelectCases = pins.countSelectCases;
const countByte = text.countByte;

pub fn writePreviewPulse(w: anytype, flow_name: []const u8, node_id: u32) !void {
    try w.writeAll("    if (game.preview) |*_p| {\n");
    try w.print(
        "        _p.emitNodeEntered(\"{f}\", {d}) catch {{}};\n",
        .{ std.zig.fmtString(flow_name), node_id },
    );
    try w.writeAll("    }\n");
}

pub fn writeNodeBody(
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
        // Comparison (flow-codegen#7) — binary, `result` is a `bool`.
        // Unwired inputs default to `0` (a benign `0 == 0`-style compare),
        // matching BinOp's arithmetic default.
        .Compare => |b| {
            const a_expr = (try ctx.resolveInput(scratch, node, "a")) orelse try scratch.dupe(u8, "0");
            const b_expr = (try ctx.resolveInput(scratch, node, "b")) orelse try scratch.dupe(u8, "0");
            const op_text: []const u8 = switch (b.op) {
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
            };
            try w.print(
                "    const n{d}_result = {s} {s} {s};\n",
                .{ node.id, a_expr, op_text, b_expr },
            );
        },
        // Boolean logic (flow-codegen#7) — `not` is unary (`a` only),
        // `and`/`or` are binary. Unwired inputs default to `false`.
        .Logic => |b| switch (b.op) {
            .not => {
                const a_expr = (try ctx.resolveInput(scratch, node, "a")) orelse try scratch.dupe(u8, "false");
                try w.print("    const n{d}_result = !{s};\n", .{ node.id, a_expr });
            },
            .@"and", .@"or" => {
                const a_expr = (try ctx.resolveInput(scratch, node, "a")) orelse try scratch.dupe(u8, "false");
                const b_expr = (try ctx.resolveInput(scratch, node, "b")) orelse try scratch.dupe(u8, "false");
                const op_text: []const u8 = if (b.op == .@"and") "and" else "or";
                try w.print(
                    "    const n{d}_result = {s} {s} {s};\n",
                    .{ node.id, a_expr, op_text, b_expr },
                );
            },
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
            var pin_edges: std.ArrayList(*const flow_io.Edge) = .empty;
            defer pin_edges.deinit(scratch);
            for (ctx.flow.edges) |*e| {
                if (e.to.node == node.id) try pin_edges.append(scratch, e);
            }
            std.mem.sort(*const flow_io.Edge, pin_edges.items, {}, struct {
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
            if (pin_edges.items.len == 0) {
                try w.print(
                    "    game.emit(.{{ .{s} = .{{}} }});\n",
                    .{qualified},
                );
            } else {
                try w.print("    game.emit(.{{ .{s} = .{{\n", .{qualified});
                for (pin_edges.items) |edge| {
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
        // List operations (flow-codegen#24). Each references its growable
        // list by `collection` name (the module-level `pub var
        // std.ArrayList(...)`). Commands allocate on demand through
        // `game.allocator` (always in scope here — `bodyImpl`/handlers all
        // bind a `game: *Game`).
        //
        // `ListAppend` — append the wired `value`; `catch {}` swallows the
        // OOM error so the lowering is a statement (v1: best-effort).
        .ListAppend => |b| {
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    {s}.append(game.allocator, {s}) catch {{}};\n",
                .{ b.collection, value_expr },
            );
        },
        // `ListLength` — reporter binding the list length (`usize`).
        .ListLength => |b| try w.print(
            "    const n{d}_value = {s}.items.len;\n",
            .{ node.id, b.collection },
        ),
        // `ListGet` — reporter reading `items[<index>]` directly. An
        // out-of-range index panics in safe builds (bounds-checked variant
        // is a follow-up).
        .ListGet => |b| {
            const index_expr = (try ctx.resolveInput(scratch, node, "index")) orelse return error.DanglingPin;
            try w.print(
                "    const n{d}_value = {s}.items[{s}];\n",
                .{ node.id, b.collection, index_expr },
            );
        },
        // `ListSet` — command writing `items[<index>] = <value>`.
        .ListSet => |b| {
            const index_expr = (try ctx.resolveInput(scratch, node, "index")) orelse return error.DanglingPin;
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    {s}.items[{s}] = {s};\n",
                .{ b.collection, index_expr, value_expr },
            );
        },
        // `ListContains` — reporter binding a `bool` via a Zig for-else
        // membership scan. `__e` is the loop capture; the `break true`
        // short-circuits and the `else false` is the no-match result.
        .ListContains => |b| {
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    const n{d}_value = for ({s}.items) |__e| {{ if (__e == {s}) break true; }} else false;\n",
                .{ node.id, b.collection, value_expr },
            );
        },
        // `ListClear` — command emptying the list, keeping capacity.
        .ListClear => |b| try w.print(
            "    {s}.clearRetainingCapacity();\n",
            .{b.collection},
        ),
        // `ForEach` (flow-codegen#24) is a control-flow loop node — like
        // `Branch`/`ForRange`, `emitScope` intercepts it and emits the
        // `for` header + recursively emits the body scope (see
        // `emitForEach`). Unreachable in a well-formed walk.
        .ForEach => unreachable,

        // Map operations (flow-codegen#24, MAPS). Each references its
        // `std.AutoHashMapUnmanaged` by `collection` name. Commands
        // allocate on demand through `game.allocator` (always in scope).
        //
        // `MapSet` — `put(game.allocator, key, value)`; `catch {}` swallows
        // OOM so the lowering is a statement (v1: best-effort).
        .MapSet => |b| {
            const key_expr = (try ctx.resolveInput(scratch, node, "key")) orelse return error.DanglingPin;
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    {s}.put(game.allocator, {s}, {s}) catch {{}};\n",
                .{ b.collection, key_expr, value_expr },
            );
        },
        // `MapGet` — reporter binding `get(key) orelse <default>`. The
        // `default` input defaults to `0` when unwired (mirrors `ListGet`);
        // author wires a real default for non-numeric value types.
        .MapGet => |b| {
            const key_expr = (try ctx.resolveInput(scratch, node, "key")) orelse return error.DanglingPin;
            const default_expr = (try ctx.resolveInput(scratch, node, "default")) orelse try scratch.dupe(u8, "0");
            try w.print(
                "    const n{d}_value = {s}.get({s}) orelse {s};\n",
                .{ node.id, b.collection, key_expr, default_expr },
            );
        },
        // `MapHas` — reporter binding a `bool` membership test.
        .MapHas => |b| {
            const key_expr = (try ctx.resolveInput(scratch, node, "key")) orelse return error.DanglingPin;
            try w.print(
                "    const n{d}_value = {s}.contains({s});\n",
                .{ node.id, b.collection, key_expr },
            );
        },
        // `MapRemove` — command removing the wired `key`; the `bool`
        // result is discarded.
        .MapRemove => |b| {
            const key_expr = (try ctx.resolveInput(scratch, node, "key")) orelse return error.DanglingPin;
            try w.print(
                "    _ = {s}.remove({s});\n",
                .{ b.collection, key_expr },
            );
        },
        // `MapClear` — command emptying the map, keeping capacity.
        .MapClear => |b| try w.print(
            "    {s}.clearRetainingCapacity();\n",
            .{b.collection},
        ),
        // `MapLength` — reporter binding the entry count (`usize`).
        .MapLength => |b| try w.print(
            "    const n{d}_value = {s}.count();\n",
            .{ node.id, b.collection },
        ),
        // `MapForEach` (flow-codegen#24, MAPS) is a control-flow loop node
        // — like `ForEach`, `emitScope` intercepts it and emits the
        // iterator `while` header + recursively emits the body scope (see
        // `emitMapForEach`). Unreachable in a well-formed walk.
        .MapForEach => unreachable,
        // `Branch` (flow-codegen#8) is never emitted through this flat
        // path — `emitScope` intercepts a `Branch` node and expands it
        // to an `if`/`else` wrapper (see `emitBranch`), recursing into
        // each side's scope. This arm exists only to satisfy the
        // exhaustive switch; reaching it would mean the scope walker
        // mis-classified a control-flow node.
        .Branch => unreachable,
        // `ForRange` / `While` (flow-codegen#21) are loop control nodes —
        // like `Branch`, `emitScope` intercepts them and emits the `while`
        // header + recursively emits the body scope (see `emitLoop`). This
        // arm is unreachable in a well-formed walk.
        .ForRange, .While => unreachable,
        // `Select` (flow-codegen#22) is a pure-expression reporter — it
        // lowers to an inline Zig `switch` EXPRESSION bound to
        // `n<id>_result`. Each prong `N => <case<N>>` reads the positional
        // `case<N>` value input; the `else` prong reads the `default` value
        // input. Unwired pins default to compiling values: an unwired
        // `selector` → `0`; an unwired `case<N>` → `0`; an unwired `default`
        // → the last wired case's expression (so the `else` prong matches a
        // real value), or `0` when there are no cases.
        .Select => {
            const arity = countSelectCases(ctx.flow, node.id);
            const sel_expr = (try ctx.resolveInput(scratch, node, "selector")) orelse
                try scratch.dupe(u8, "0");

            try w.print("    const n{d}_result = switch ({s}) {{\n", .{ node.id, sel_expr });

            // Each wired (or defaulted) case prong. `last_case` is kept so
            // an unwired `default` can fall back to a real case value rather
            // than a bare `0` of an unknown type.
            var last_case: ?[]const u8 = null;
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                var buf: [16]u8 = undefined;
                const pin = std.fmt.bufPrint(&buf, "case{d}", .{i}) catch unreachable;
                const expr = (try ctx.resolveInput(scratch, node, pin)) orelse
                    try scratch.dupe(u8, "0");
                last_case = expr;
                try w.print("        {d} => {s},\n", .{ i, expr });
            }

            // The `else` prong from the `default` value input. Required for
            // an exhaustive Zig `switch`; when unwired, fall back to the
            // last case's expression (or `0` when there are no cases).
            const default_expr = (try ctx.resolveInput(scratch, node, "default")) orelse
                (last_case orelse try scratch.dupe(u8, "0"));
            try w.print("        else => {s},\n", .{default_expr});
            try w.writeAll("    };\n");
        },
        // `Switch` (flow-codegen#22) is a control-flow node — like `Branch`,
        // `emitScope` intercepts it and emits a `switch` STATEMENT with a
        // block per case side (see `emitSwitch`). Unreachable in a
        // well-formed walk.
        .Switch => unreachable,
        // `Log` (flow-codegen#20) — Debug-gated `std.debug.print`, the
        // first-class promotion of the `log_i32` CustomNode. Mirrors
        // `ChangeVariable`'s `if (@import("builtin").mode == .Debug)
        // std.debug.print(...)` style. The author-controlled `label` is
        // escaped into the Zig format string by `escapeLogLabel` (Zig
        // string-literal escaping via `std.zig.fmtString`, plus
        // `{`/`}` doubling so braces in the label can't be read as
        // format placeholders). The `{any}` / `\n` we append are NOT
        // part of the label, so they stay as real format syntax.
        .Log => |b| {
            const safe_label = try escapeLogLabel(scratch, b.label);
            if (try ctx.resolveInput(scratch, node, "value")) |value_expr| {
                try w.print(
                    "    if (@import(\"builtin\").mode == .Debug) std.debug.print(\"{s}: {{any}}\\n\", .{{{s}}});\n",
                    .{ safe_label, value_expr },
                );
            } else {
                try w.print(
                    "    if (@import(\"builtin\").mode == .Debug) std.debug.print(\"{s}\\n\", .{{}});\n",
                    .{safe_label},
                );
            }
        },
        // String reporters (flow-codegen#26). Each ALLOCATES via
        // `game.allocator` (always in scope — `bodyImpl`/handlers all bind
        // a `game`) and binds the `[]const u8` result to `n<id>_value`,
        // exactly once (these kinds are deliberately NOT in `inline.zig`'s
        // pure-inlinable set — re-inlining per consumer would reallocate /
        // leak). The result is game-lifetime with NO auto-free: the flow
        // author owns it, the same ownership contract as the growable
        // collections (flow-codegen#24). On allocation failure we fall back
        // to a safe empty string (`catch ""`), mirroring collections'
        // `catch {}` swallow philosophy.
        //
        // `Format` — printf-style `template` (VERBATIM `std.fmt` syntax)
        // rendered against ordered, typed `arg<N>` value pins (the `Call`
        // arg convention via `countCallArgs`). The author-controlled
        // `template` is escaped by `escapeZigStringBody` (Zig string-literal
        // escaping — quotes/newlines/control bytes) but NOT brace-doubled:
        // its `{d}`/`{s}`/`{}` placeholders are REAL `std.fmt` syntax here
        // and must survive verbatim (unlike a `Log` label, whose braces are
        // doubled by `escapeLogLabel` to print literally).
        .Format => |b| {
            const safe_template = try escapeZigStringBody(scratch, b.template);
            const arity = countCallArgs(ctx.flow, node.id);
            try w.print(
                "    const n{d}_value: []const u8 = std.fmt.allocPrint(game.allocator, \"{s}\", .{{",
                .{ node.id, safe_template },
            );
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                if (i > 0) try w.writeAll(", ");
                var buf: [16]u8 = undefined;
                const pin = std.fmt.bufPrint(&buf, "arg{d}", .{i}) catch unreachable;
                const expr = (try ctx.resolveInput(scratch, node, pin)) orelse
                    try scratch.dupe(u8, "undefined");
                try w.writeAll(expr);
            }
            try w.writeAll("}) catch \"\";\n");
        },
        // `Concat` — join N string `arg<N>` value pins (same `Call` arg
        // convention) via `std.mem.concat`. An unwired arg slot resolves
        // to `undefined` — Zig's type-checker flags a genuinely missing
        // pin at the generated call site (mirrors `Call`).
        .Concat => {
            const arity = countCallArgs(ctx.flow, node.id);
            try w.print(
                "    const n{d}_value: []const u8 = std.mem.concat(game.allocator, u8, &.{{",
                .{node.id},
            );
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                if (i > 0) try w.writeAll(", ");
                var buf: [16]u8 = undefined;
                const pin = std.fmt.bufPrint(&buf, "arg{d}", .{i}) catch unreachable;
                const expr = (try ctx.resolveInput(scratch, node, pin)) orelse
                    try scratch.dupe(u8, "undefined");
                try w.writeAll(expr);
            }
            try w.writeAll("}) catch \"\";\n");
        },
        // `IntToString` / `FloatToString` — render the single `value` data
        // input as decimal text. Zig's `{d}` formats both ints and floats,
        // so the two kinds share one lowering; they stay distinct kinds for
        // editor clarity and future per-type precision controls. A missing
        // `value` input is a `DanglingPin` (a to-string with nothing to
        // render is malformed).
        .IntToString, .FloatToString => {
            const value_expr = (try ctx.resolveInput(scratch, node, "value")) orelse return error.DanglingPin;
            try w.print(
                "    const n{d}_value: []const u8 = std.fmt.allocPrint(game.allocator, \"{{d}}\", .{{{s}}}) catch \"\";\n",
                .{ node.id, value_expr },
            );
        },
    }
}

/// Escape an author-controlled `Log` label into a fragment that is safe
/// to splice into a Zig `std.debug.print` format-string literal
/// (flow-codegen#20). Two hazards are handled:
///
///  1. Zig string-literal syntax — quotes, backslashes, newlines, and
///     other control bytes. Handled by `std.zig.fmtString`, which emits a
///     literal *body* (no surrounding quotes), using `\"`, `\n`, `\xNN`,
///     etc. `fmtString` never emits a brace of its own (control bytes
///     become `\xNN`, not `\u{…}`), so every `{`/`}` in its output came
///     verbatim from the label.
///  2. `std.fmt` placeholder syntax — a `{` or `}` in the label would be
///     read as (the start of) a format argument and break compilation.
///     We double each brace (`{` → `{{`, `}` → `}}`) so it prints
///     literally. This runs AFTER `fmtString`, and only over the label
///     text — the caller appends its own single-brace `{any}` separately,
///     so the real placeholder is never doubled.
pub fn escapeLogLabel(alloc: std.mem.Allocator, label: []const u8) ![]const u8 {
    const lit_escaped = try escapeZigStringBody(alloc, label);
    // Brace-doubling can at most double the length — preallocate for the
    // worst case so a label with braces needs no realloc.
    var out = try std.ArrayList(u8).initCapacity(alloc, lit_escaped.len * 2);
    for (lit_escaped) |c| {
        switch (c) {
            '{' => try out.appendSlice(alloc, "{{"),
            '}' => try out.appendSlice(alloc, "}}"),
            else => try out.append(alloc, c),
        }
    }
    return out.items;
}

/// Zig string-literal-body escaping ONLY — quotes, backslashes,
/// newlines, and other control bytes become `\"`, `\n`, `\xNN`, etc.
/// (no surrounding quotes). This is step 1 of `escapeLogLabel`, factored
/// out so the `Format` node (flow-codegen#26) can reuse it WITHOUT the
/// brace-doubling step 2: a `Format` `template` is VERBATIM `std.fmt`
/// syntax, so its `{d}`/`{s}`/`{}` placeholders must survive as REAL
/// format placeholders (a `Log` label, by contrast, is literal text, so
/// its braces are doubled to print literally). `fmtString` never emits a
/// brace of its own (control bytes become `\xNN`), so every `{`/`}` in
/// the output came verbatim from the template — exactly the placeholders
/// the author wrote.
pub fn escapeZigStringBody(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "{f}", .{std.zig.fmtString(s)});
}

/// Resolve the value supplied for `param` at a `Subflow` call site,
/// honouring the RFC §3 precedence: wired pin → `binding` literal →
/// declared `default`. Returns Zig source text on `alloc`.
pub fn resolveSubflowArg(
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
