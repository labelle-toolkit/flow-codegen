//! Flow data model — the typed structs/enums a `.flow.jsonc` file
//! parses into (`parse.zig`), is validated against (`validate.zig`), and
//! is rendered back from (`write.zig`). `codegen.zig` consumes a `Flow`
//! and emits a Zig source file.
//!
//! Ownership: a heap-allocated arena owns every slice the `Flow`
//! references; the caller frees both via `LoadedFlow.deinit()`.

const std = @import("std");

/// Event entry point for a flow. Per RFC-FLOW-VOCABULARY §3, a flow's
/// trigger is determined entirely from its graph: event-driven flows
/// declare their trigger as one or more in-graph `Event` nodes and the
/// loader synthesizes `Flow.event = .{ .OnEvent = ... }` from the node's
/// name (so downstream consumers — assembler `flow_scanner`, codegen's
/// `FlowEventHandler` path — keep working unchanged); a flow with ZERO
/// `Event` nodes is a *subgraph* (`.subgraph`), the entry point invoked
/// by a `Subflow` node rather than dispatched by an event.
///
/// The legacy file-level `event:` header — including the retired
/// `OnCall` discriminator (flow-codegen#17) — is no longer accepted; any
/// top-level `event:` key is rejected by `buildFlow`.
pub const Event = union(enum) {
    /// Subgraph entry point (RFC §3). Synthesized by `buildFlow` for any
    /// flow that declares no in-graph `Event` node — the mechanism that
    /// superseded the retired `OnCall` header (flow-codegen#17).
    subgraph,
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
    /// `Branch` — control-flow `if`/then-else (flow-codegen#8). The first
    /// control-flow node: it consumes a single `cond` **data** input pin
    /// (a `bool`) and exposes two **exec** outputs, `then` and `else`,
    /// which route control flow rather than carry values. The exec wiring
    /// lives in `Flow.exec_edges`, NOT in the data `edges` list — exec
    /// edges don't participate in the data topo sort. Codegen lowers a
    /// `Branch` to a Zig `if (<cond>) { … } else { … }` and sinks each
    /// side's commands/reporters into the matching block (see codegen's
    /// scope model). Carries no per-kind payload — the `then`/`else`
    /// targets are the exec edges, and the `cond` source is a data edge.
    Branch: struct {},
    /// `ForRange` — count loop (flow-codegen#21). Consumes three **data**
    /// input pins — `start`, `end`, `step` (all unwired-defaultable) — and
    /// exposes a single **exec** output pin `body`, wired through
    /// `Flow.exec_edges` exactly like a `Branch` side. Its `index` output
    /// pin is the loop variable, readable only by body nodes (codegen
    /// special-cases the read — see `resolveInput`). Codegen lowers it to a
    /// scoped Zig `while` with an explicit `i32` loop var:
    /// `{ var i_<id>: i32 = <start>; while (i_<id> < <end>) : (i_<id> +=
    /// <step>) { <body> } }`. Carries no per-kind payload — every input is
    /// a data edge, the body target is an exec edge.
    ForRange: struct {},
    /// `While` — condition loop (flow-codegen#21). Consumes one **data**
    /// input pin `cond` (a `bool`) and exposes a single **exec** output
    /// pin `body`. Unlike `Branch`, a `while` re-checks its condition every
    /// iteration; codegen therefore deep-inlines the `cond` reporter
    /// subtree into the loop header so it recomputes each pass (a binding
    /// reference would freeze the once-bound value — see codegen's
    /// `deepInlineExpr`). Carries no per-kind payload.
    While: struct {},
    /// `Once` — exec-gate that passes control the FIRST time only, ever
    /// (flow-codegen#47). The single-output analogue of `Branch`: it sits on
    /// an exec edge, runs synchronously, and exposes a single **exec** output
    /// pin `body` wired through `Flow.exec_edges` exactly like a `ForRange`
    /// side — there is no `else`. It consumes NO data inputs; its gate is a
    /// per-node persistent bool emitted at module scope by codegen as
    /// `pub var __once_<flowfn>_n<id>: bool = false;` (the `__` prefix is
    /// RESERVED for generated state; `<flowfn>` is the flow's function name,
    /// so the same node id in two flows gets distinct slots — node ids are
    /// only unique within a flow). Codegen lowers it to a guarded scope that
    /// flips the flag and runs the body exactly once:
    /// `if (!__once_<flowfn>_n<id>) { __once_<flowfn>_n<id> = true; <body> }`.
    /// Carries no per-kind payload — the body target is an exec edge and the
    /// state is keyed by (flow, node id).
    Once: struct {},
    /// `Cooldown` — exec-gate that passes control, then blocks re-entry for
    /// `seconds` (flow-codegen#47). Like `Once`, it is the single-output
    /// analogue of `Branch`: an exec edge feeds it, it runs synchronously,
    /// and it routes control through a single **exec** output pin `body`
    /// (wired in `Flow.exec_edges`, no `else`). Its gate is a per-node
    /// persistent `f64` last-fired timestamp emitted at module scope as
    /// `pub var __cd_<flowfn>_n<id>: f64 = -1e18;` (the `__` prefix is RESERVED
    /// for generated state; `<flowfn>` is the flow's function name so the same
    /// node id in two flows gets distinct slots; the sentinel guarantees the
    /// gate opens on first entry). Codegen compares the host game clock against
    /// it and lowers to:
    /// `if (game.elapsedSeconds() - __cd_<flowfn>_n<id> >= <seconds>) {`
    /// `    __cd_<flowfn>_n<id> = game.elapsedSeconds(); <body> }`. The `seconds`
    /// field is emitted as an `f64` literal; `game.elapsedSeconds()` is a
    /// host accessor provided by labelle-engine.
    Cooldown: struct { seconds: f64 = 0 },
    /// `Delay` — deferred-subflow exec node (flow-codegen#48, Stage 2 of
    /// #25). Like the other exec-gates (`Once`/`Cooldown`) it sits on an
    /// exec edge and routes control through a single **exec** output pin
    /// `body` (wired in `Flow.exec_edges`, no `else`). UNLIKE them, `Delay`
    /// does NOT run its body synchronously: it SNAPSHOTS the body's input
    /// arguments into a heap capture struct, registers a (scaled,
    /// pause-aware) timer on the engine's runtime `Scheduler`, and lets the
    /// body run later, off a generated trampoline (labelle-engine#605).
    ///
    /// Its `body` exec output MUST connect to exactly ONE node, and that
    /// node MUST be a `Subflow` (validated in `flow_io.validate` —
    /// `MalformedFlow` otherwise). The Subflow's wired input pins are
    /// resolved at the Delay site (the normal data-edge path) and
    /// snapshotted into the capture struct, whose FIELDS are the referenced
    /// flow's declared input params (names + types). The capture is
    /// `game.allocator.create`'d at the Delay site; the scheduler OWNS and
    /// frees it exactly once after firing/skip/deinit, so the trampoline
    /// must not free it.
    ///
    /// Codegen emits, per Delay node (namespaced by the flow's function
    /// name `<flowfn>`, exactly like the `Once`/`Cooldown` gate state, since
    /// node ids are unique only WITHIN a flow):
    ///   - a module-level capture struct
    ///     `const __DelayCap_<flowfn>_n<id> = struct { <arg>: <type>, … };`
    ///   - a module-level trampoline
    ///     `fn __delay_tramp_<flowfn>_n<id>(game_ctx: *anyopaque, ctx:
    ///     *anyopaque) void { … <subflow>(game, cap.<arg>, …); }`
    ///   - at the Delay site, a `game.allocator.create` + field snapshot +
    ///     `game.scheduler.after(<seconds>, <entity-or-null>, __cap_n<id>,
    ///     &__delay_tramp_<flowfn>_n<id>);`.
    ///
    /// The `seconds` field is emitted as an `f64` literal. The `entity`
    /// argument binds the flow's in-scope entity when the flow has one
    /// (a Delay bound to an entity is auto-cancelled if that entity dies
    /// before firing); post-Phase 6 flows have no lifecycle `entity`
    /// identifier in scope, so it is `null` there (see `emitDelay`).
    Delay: struct { seconds: f64 = 0 },
    /// `Select` — pure-expression multi-way value picker (flow-codegen#22).
    /// The dataflow analogue of a `switch` *expression*: it consumes a
    /// `selector` **data** input (an integer) plus positional `case<N>`
    /// **data** value inputs (`case0`, `case1`, … — counted like `Call`'s
    /// `arg<N>`) and a `default` **data** value input, and binds a single
    /// `result` output. No exec edges — it lowers inline to a Zig `switch`
    /// EXPRESSION (`switch (<selector>) { 0 => <case0>, …, else =>
    /// <default> }`). Unwired `selector` defaults to `0`; unwired `default`
    /// falls back to a sensible compiling value (the last wired case, or
    /// `0`). Carries no per-kind payload — every input is a data edge.
    Select: struct {},
    /// `Switch` — control-flow N-way branch (flow-codegen#22). The
    /// multi-way generalisation of `Branch`: it consumes a single
    /// `selector` **data** input (an integer) and exposes N labeled **exec**
    /// outputs `case0`, `case1`, … plus a `default` exec output, wired
    /// through `Flow.exec_edges` exactly like a `Branch`'s `then`/`else`
    /// sides. Codegen lowers it to a Zig `switch` STATEMENT, one block per
    /// wired case side plus an `else` from the `default` side (emitting an
    /// empty `else => {}` when `default` is unwired, so the switch stays
    /// exhaustive). The case count is derived from the distinct `case<N>`
    /// exec pins wired. Carries no per-kind payload — the `selector` source
    /// is a data edge and the side targets are exec edges.
    Switch: struct {},
    /// `Log` — debug-print command (flow-codegen#20). The first-class
    /// promotion of the `log_i32` CustomNode: prints a labeled value to
    /// the console in Debug builds. Consumes a single optional `value`
    /// **data** input pin and carries an inline `label` string. Codegen
    /// lowers it to a Debug-gated `std.debug.print`, mirroring
    /// `ChangeVariable`'s hard-wired debug side effect:
    /// `if (@import("builtin").mode == .Debug) std.debug.print("<label>:
    /// {any}\n", .{<value>});` when `value` is wired, or the label-only
    /// form (`"<label>\n"`, no args) when it is not. The `label` is
    /// author-controlled text — codegen escapes it in two steps so it
    /// can't break the generated source: `std.zig.fmtString` for Zig
    /// string-literal escaping (quotes / newlines), then a `{`→`{{` /
    /// `}`→`}}` doubling pass so a brace in the label prints literally
    /// instead of being read as a `std.fmt` placeholder. Defaults to
    /// `""` when omitted.
    Log: struct { label: []const u8 = "" },
    /// `Format` — string-formatting reporter (flow-codegen#26). Renders a
    /// printf-style `template` against ordered, typed value pins
    /// (`arg0`, `arg1`, … — the same positional `arg<N>` convention as
    /// `Call`) and binds the resulting `[]const u8` to its `value` output
    /// pin. The `template` is VERBATIM Zig `std.fmt` syntax (`{d}`, `{s}`,
    /// `{}`) — the same convention the `Log` node uses for its `label`.
    /// Codegen escapes it with `escapeZigStringBody` (Zig string-literal
    /// escaping for quotes/newlines/control bytes) but, unlike `Log`,
    /// does NOT double its braces — they are real `std.fmt` placeholders
    /// here. Defaults to `""` when omitted (a valid, argument-free
    /// template).
    ///
    /// REPORTER allocation contract (flow-codegen#26): the result is
    /// allocated via `game.allocator`, game-lifetime, with NO auto-free —
    /// the flow author owns the string, exactly like the growable
    /// collections (flow-codegen#24). On allocation failure codegen falls
    /// back to a safe empty string (`catch ""`), mirroring collections'
    /// `catch {}` swallow philosophy. Because it allocates, codegen emits
    /// it EXACTLY ONCE bound to `n<id>_value` (like `Call`/`GetComponent`)
    /// rather than inlining per consumer — it is deliberately NOT in
    /// `inline.zig`'s pure-inlinable set.
    /// Lowers to `const n<id>_value: []const u8 =
    /// std.fmt.allocPrint(game.allocator, "<template>", .{ <arg0>, … })
    /// catch "";`.
    Format: struct { template: []const u8 = "" },
    /// `Concat` — string-join reporter (flow-codegen#26). Joins N string
    /// value pins (`arg0`, `arg1`, … — the positional `arg<N>` convention
    /// shared with `Call`/`Format`) into a single `[]const u8` bound to
    /// its `value` output pin. Carries no per-kind payload — every input
    /// is a data edge. Same REPORTER allocation contract as `Format`
    /// (game-lifetime via `game.allocator`, no auto-free, `catch ""` on
    /// failure, bound-once). Lowers to `const n<id>_value: []const u8 =
    /// std.mem.concat(game.allocator, u8, &.{ <a>, <b>, … }) catch "";`.
    Concat: struct {},
    /// `IntToString` — integer-stringify reporter (flow-codegen#26).
    /// Renders the single wired integer `value` data input as decimal
    /// text, binding the `[]const u8` result to its `value` output pin.
    /// Carries no per-kind payload. Same REPORTER allocation contract as
    /// `Format` (game-lifetime via `game.allocator`, no auto-free, `catch
    /// ""` on failure, bound-once). Lowers to `const n<id>_value: []const
    /// u8 = std.fmt.allocPrint(game.allocator, "{d}", .{<v>}) catch "";`.
    IntToString: struct {},
    /// `FloatToString` — float-stringify reporter (flow-codegen#26).
    /// Renders the single wired float `value` data input as decimal text,
    /// binding the `[]const u8` result to its `value` output pin. Carries
    /// no per-kind payload. Same REPORTER allocation contract as `Format`
    /// (game-lifetime via `game.allocator`, no auto-free, `catch ""` on
    /// failure, bound-once). Lowers to the same `{d}` `allocPrint` form as
    /// `IntToString` — Zig's `{d}` formats both ints and floats, so the
    /// two share a template (the node kinds stay distinct for editor
    /// clarity and future per-type precision controls).
    FloatToString: struct {},
    /// `IsKeyDown` — input reporter (labelle-gui#208 Option A). The
    /// held-state complement to the input EVENT nodes: pure value
    /// reporter (output pin `value: bool`, no exec pins) read inside a
    /// per-frame flow (`engine.tick` / `OnEvent` handler), e.g.
    /// `Branch(cond = IsKeyDown("w")) → move`. Lowers to the GAME INPUT
    /// MIXIN method `game.isKeyDown(.<key>)` (labelle-engine
    /// `src/game/input_mixin.zig`).
    ///
    /// `key` is the BARE enum-tag name of a `KeyboardKey` (e.g. `"space"`,
    /// `"w"`, `"left"`) — NOT a wired pin. Codegen emits it as a Zig ENUM
    /// LITERAL — `game.isKeyDown(.<key>)` — so it infers to `KeyboardKey`
    /// without the generated module importing the enum (mirrors how
    /// `engine.KeyboardKey.space` is referenced elsewhere). `validate`
    /// checks the tag is non-empty and a plausible Zig identifier;
    /// AstGen CANNOT verify the tag is a real `KeyboardKey` member — that
    /// is resolved by Sema at game compile, surfacing as an
    /// `enum '…' has no member named '…'` error there.
    IsKeyDown: struct { key: []const u8 = "" },
    /// `IsKeyPressed` — input reporter (labelle-gui#208 Option A). The
    /// rising-edge sibling of `IsKeyDown`: true only on the frame the key
    /// transitions to down. Output pin `value: bool`, no exec pins.
    /// Lowers to the mixin method `game.isKeyPressed(.<key>)`. Same
    /// enum-literal `key` encoding, validation, and Sema-deferred
    /// tag-checking caveat as `IsKeyDown`.
    IsKeyPressed: struct { key: []const u8 = "" },
    /// `IsKeyReleased` — input reporter (labelle-gui#208). The falling-edge
    /// sibling of `IsKeyDown`/`IsKeyPressed`: true only on the frame the key
    /// transitions to up. Output pin `value: bool`, no exec pins. Lowers to
    /// the mixin method `game.isKeyReleased(.<key>)` (labelle-engine
    /// `feat/input-mixin-accessors`). Same enum-literal `key` encoding,
    /// validation, and Sema-deferred tag-checking caveat as `IsKeyDown`.
    IsKeyReleased: struct { key: []const u8 = "" },
    /// `IsMouseButtonDown` — input reporter (labelle-gui#208). Held-state
    /// reporter for a mouse button: pure value reporter (output pin
    /// `value: bool`, no exec pins). Lowers to the mixin method
    /// `game.isMouseButtonDown(.<button>)` (labelle-engine
    /// `feat/input-mixin-accessors`).
    ///
    /// `button` is the BARE enum-tag name of a `MouseButton` (`"left"`,
    /// `"right"`, `"middle"`) — NOT a wired pin. Codegen emits it as a Zig
    /// ENUM LITERAL — `game.isMouseButtonDown(.<button>)` — via
    /// `std.zig.fmtId` (so a keyword-named tag still parses), mirroring how
    /// `IsKeyDown` encodes `key`. `validate` checks the tag is non-empty and
    /// a plausible Zig identifier; AstGen CANNOT verify the tag is a real
    /// `MouseButton` member — that is resolved by Sema at game compile,
    /// surfacing as an `enum '…' has no member named '…'` error there.
    IsMouseButtonDown: struct { button: []const u8 = "" },
    /// `IsMouseButtonPressed` — input reporter (labelle-gui#208). The
    /// rising-edge sibling of `IsMouseButtonDown`: true only on the frame the
    /// button transitions to down. Output pin `value: bool`, no exec pins.
    /// Lowers to `game.isMouseButtonPressed(.<button>)`. Same enum-literal
    /// `button` encoding, validation, and Sema-deferred tag-checking caveat
    /// as `IsMouseButtonDown`.
    IsMouseButtonPressed: struct { button: []const u8 = "" },
    /// `IsMouseButtonReleased` — input reporter (labelle-gui#208). The
    /// falling-edge sibling of `IsMouseButtonDown`: true only on the frame
    /// the button transitions to up. Output pin `value: bool`, no exec pins.
    /// Lowers to `game.isMouseButtonReleased(.<button>)`. Same enum-literal
    /// `button` encoding, validation, and Sema-deferred tag-checking caveat
    /// as `IsMouseButtonDown`.
    IsMouseButtonReleased: struct { button: []const u8 = "" },
    /// `GetMouseX` — input reporter (labelle-gui#208 Option A). Pure value
    /// reporter (output pin `value: f32`, no exec pins, no payload).
    /// Lowers to the mixin method `game.getMouseX()` — the mouse cursor's
    /// X position in window pixels for the current frame.
    GetMouseX: struct {},
    /// `GetMouseY` — input reporter (labelle-gui#208 Option A). Pure value
    /// reporter (output pin `value: f32`, no exec pins, no payload).
    /// Lowers to the mixin method `game.getMouseY()` — the mouse cursor's
    /// Y position in window pixels for the current frame.
    GetMouseY: struct {},
    /// `GetMouseWheel` — input reporter (labelle-gui#208 Option A). Pure
    /// value reporter (output pin `value: f32`, no exec pins, no payload).
    /// Lowers to the mixin method `game.getMouseWheelMove()` — the mouse
    /// wheel delta for the current frame (positive = forward/up).
    GetMouseWheel: struct {},
    /// `ListAppend` — command (flow-codegen#24). Appends the wired
    /// `value` data input to the named growable list. Lowers to
    /// `<name>.append(game.allocator, <value>) catch {};`.
    ListAppend: struct { collection: []const u8 },
    /// `ListLength` — reporter (flow-codegen#24). Binds the list's
    /// current length (`usize`) to its `value` output pin —
    /// `const n<id>_value = <name>.items.len;`.
    ListLength: struct { collection: []const u8 },
    /// `ListGet` — reporter (flow-codegen#24). Reads the element at the
    /// wired `index` data input — `const n<id>_value =
    /// <name>.items[<index>];`. Direct index: an out-of-range read
    /// panics in safe builds (a bounds-checked variant is a follow-up).
    ListGet: struct { collection: []const u8 },
    /// `ListSet` — command (flow-codegen#24). Writes the wired `value`
    /// into the element at the wired `index` —
    /// `<name>.items[<index>] = <value>;`. Same direct-index caveat as
    /// `ListGet`.
    ListSet: struct { collection: []const u8 },
    /// `ListContains` — reporter (flow-codegen#24). Binds a `bool` —
    /// whether any element equals the wired `value`. Lowered with a
    /// Zig for-else: `const n<id>_value = for (<name>.items) |__e| { if
    /// (__e == <value>) break true; } else false;`.
    ListContains: struct { collection: []const u8 },
    /// `ListClear` — command (flow-codegen#24). Empties the list while
    /// keeping its capacity — `<name>.clearRetainingCapacity();`.
    ListClear: struct { collection: []const u8 },
    /// `ForEach` — control-flow loop over a list (flow-codegen#24,
    /// pairs with flow-codegen#21's loop family). Exposes a single
    /// **exec** output pin `body` (wired through `Flow.exec_edges` like
    /// a `ForRange`'s `body`) plus two data **output** pins — `item`
    /// (the element) and `index` (the 0-based `usize` position) —
    /// readable only by body nodes (codegen special-cases the read in
    /// `resolveInput`, mirroring `ForRange.index`). Lowers to
    /// `for (<name>.items, 0..) |item_<id>, idx_<id>| { <body> }`.
    /// Carries no per-kind payload beyond the list `collection` name.
    ForEach: struct { collection: []const u8 },
    /// `MapSet` — command (flow-codegen#24, MAPS). Writes the wired
    /// `value` data input under the wired `key` into the named map.
    /// Lowers to `<name>.put(game.allocator, <key>, <value>) catch {};`.
    MapSet: struct { collection: []const u8 },
    /// `MapGet` — reporter (flow-codegen#24, MAPS). Reads the value at
    /// the wired `key`, falling back to the wired `default` when absent:
    /// `const n<id>_value = <name>.get(<key>) orelse <default>;`. The
    /// `default` data input defaults to `0` when unwired (mirroring
    /// `ListGet`); author wires a real default for non-numeric values.
    MapGet: struct { collection: []const u8 },
    /// `MapHas` — reporter (flow-codegen#24, MAPS). Binds a `bool` —
    /// whether the named map contains the wired `key`:
    /// `const n<id>_value = <name>.contains(<key>);`.
    MapHas: struct { collection: []const u8 },
    /// `MapRemove` — command (flow-codegen#24, MAPS). Removes the wired
    /// `key` from the named map (no-op if absent), discarding the
    /// `bool` result: `_ = <name>.remove(<key>);`.
    MapRemove: struct { collection: []const u8 },
    /// `MapClear` — command (flow-codegen#24, MAPS). Empties the map
    /// while keeping its capacity — `<name>.clearRetainingCapacity();`.
    MapClear: struct { collection: []const u8 },
    /// `MapLength` — reporter (flow-codegen#24, MAPS). Binds the map's
    /// entry count (`usize`) — `const n<id>_value = <name>.count();`.
    MapLength: struct { collection: []const u8 },
    /// `MapForEach` — control-flow loop over a map (flow-codegen#24,
    /// MAPS; the map analogue of `ForEach`). Exposes a single **exec**
    /// output pin `body` (wired through `Flow.exec_edges`) plus two data
    /// **output** pins — `key` and `value` — readable only by body nodes
    /// (codegen special-cases the read in `resolveInput`, mirroring
    /// `ForEach.item`/`index`). Lowers to a `std.HashMap` iterator loop:
    /// `var it_<id> = <name>.iterator(); while (it_<id>.next()) |entry_<id>|
    /// { <body> }`, where `key` reads `entry_<id>.key_ptr.*` and `value`
    /// reads `entry_<id>.value_ptr.*`. Carries no per-kind payload beyond
    /// the map `collection` name.
    MapForEach: struct { collection: []const u8 },
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

/// A control-flow (execution) edge (flow-codegen#8). Distinct from a
/// data `Edge`: where a data edge wires a producer pin's *value* into a
/// consumer pin, an exec edge wires a `Branch`'s `then`/`else` exec
/// output to the *node that runs* on that side. `from` is the source
/// exec pin — `{ .node = <branch id>, .pin = "then" | "else" }` — and
/// `to_node` is the id of the command/`Branch` node that executes when
/// control reaches that side.
///
/// On disk (RFC-FLOWS-JSONC, `.flow.jsonc`): a separate `exec_edges`
/// array, each entry `{ "from": { "node": 1, "pin": "then" }, "to": {
/// "node": 2 } }` — note `to` is a bare node ref (no `pin`), since the
/// target node is *entered*, not wired to a specific input pin.
pub const ExecEdge = struct {
    from: PinRef,
    to_node: u32,
};

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

/// Discriminates a `Collection`'s shape (flow-codegen#24). `.list` is the
/// growable-array default (back-compat: pre-MAPS files omit `kind` and a
/// missing discriminator parses as `.list`); `.map` is the hash-map shape.
pub const CollectionKind = enum { list, map };

/// A top-level declared growable collection (flow-codegen#24). A `.list`
/// lowers to a file-scope `pub var <name>: std.ArrayList(<element>) =
/// .empty;`; a `.map` lowers to `pub var <name>:
/// std.AutoHashMapUnmanaged(<key>, <value>) = .empty;`. Both are
/// game-allocator-backed and game-lifetime. Operations
/// (`ListAppend`/`MapSet`/… and `ForEach`/`MapForEach`) reference the
/// collection by `name` and allocate on demand through `game.allocator`.
/// There is NO auto-deinit in v1: collections live for the game's lifetime
/// and are reclaimed by the OS at exit; proper deinit-on-teardown is a
/// follow-up.
pub const Collection = struct {
    /// Zig identifier — the collection's symbol in the generated module.
    name: []const u8,
    /// Which shape this is. Defaults to `.list` so pre-MAPS files (which
    /// omit `kind`) round-trip unchanged.
    kind: CollectionKind = .list,
    /// LIST only — Zig source text of the element type — e.g. `"u32"`.
    /// Emitted verbatim as `std.ArrayList(<element>)`. Empty for maps.
    element: []const u8 = "",
    /// MAP only — Zig source text of the key type — e.g. `"u32"`.
    /// Emitted verbatim as the first `std.AutoHashMapUnmanaged` arg.
    /// Empty for lists.
    key: []const u8 = "",
    /// MAP only — Zig source text of the value type — e.g. `"i32"`.
    /// Emitted verbatim as the second `std.AutoHashMapUnmanaged` arg.
    /// Empty for lists.
    value: []const u8 = "",
};

/// A fully parsed flow. Every slice is owned by the surrounding
/// `LoadedFlow.arena`. `name` is the effective registry key (RFC §5).
pub const Flow = struct {
    /// Effective name (RFC §5): the top-level `"name"` field, else the
    /// filename basename. Empty when neither is available.
    name: []const u8 = "",
    /// The flow's trigger, derived from the graph (RFC-FLOW-VOCABULARY
    /// §3): `.{ .OnEvent = ... }` synthesized from the first in-graph
    /// `Event` node, or `.subgraph` when the flow declares no `Event`
    /// node. There is no file-level `event:` header — `buildFlow`
    /// rejects any top-level `event:` key (flow-codegen#17).
    event: Event,
    params: []Param = &.{},
    /// Top-level declared variables (RFC-FLOW-VOCABULARY §4). Each
    /// entry lowers to a file-scope `var <name>: <type> = <default>;`
    /// in the generated `.zig` module. Empty for flows that declare
    /// none — the default. Optional in the source file; absence is
    /// indistinguishable from `"variables": []`.
    variables: []Variable = &.{},
    /// Per-flow local (temporary) variables (issue #23). Each entry
    /// lowers to a `var <name>: <type> = <default>;` at the TOP of the
    /// generated handler function body — function-scoped, re-initialized
    /// on every handler invocation, NOT a module-level `pub var`. Shares
    /// the `Variable` shape and the variable-node name resolution with
    /// `variables`; a local name may not collide with a file-scope
    /// `variables` name (`DuplicateVariableName`). Empty for flows that
    /// declare none — the default. Optional in the source file; absence
    /// is indistinguishable from `"locals": []`.
    locals: []Variable = &.{},
    /// Top-level declared growable LIST collections (flow-codegen#24, v1).
    /// Each entry lowers to a file-scope
    /// `pub var <name>: std.ArrayList(<element>) = .empty;` in the
    /// generated `.zig` module (parallel to `variables`). A collection
    /// name may not collide with another collection, a `variables`, or a
    /// `locals` name (`DuplicateVariableName`). Empty for flows that
    /// declare none — the default. Optional in the source file; absence is
    /// indistinguishable from `"collections": []`. MAPS are deferred to a
    /// follow-up.
    collections: []Collection = &.{},
    nodes: []Node,
    /// Renamed from `links` per RFC §2; the field keeps the name
    /// `edges` to match the on-disk schema.
    edges: []Edge,
    /// Control-flow (execution) edges (flow-codegen#8). Empty for every
    /// flow that declares no `Branch` node — the default, and the only
    /// shape that existed before control flow. Optional in the source
    /// file; absence is indistinguishable from `"exec_edges": []`.
    exec_edges: []ExecEdge = &.{},

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
    /// A top-level `event:` header is present. Post-flow-codegen#17 the
    /// file-level `event:` header (including the retired `OnCall`
    /// discriminator) is no longer accepted — a flow's trigger is derived
    /// from its in-graph `Event` nodes, and a flow with none is a
    /// subgraph. Any `event:` key is rejected with this error.
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
    /// Reserved — formerly returned when a flow declared both an
    /// `event:` header and an in-graph `Event` node, or neither
    /// (RFC-FLOW-VOCABULARY §3). Post-flow-codegen#17 the header is gone
    /// (`UnknownEventType` rejects any `event:` key) and a flow with no
    /// `Event` node is a subgraph, so this is no longer returned. Kept in
    /// the public error set so downstream exhaustive switches still
    /// compile.
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
    /// A collection operation node (`ListAppend` / `ListGet` / … /
    /// `ForEach`, or `MapSet` / `MapGet` / … / `MapForEach`) names a
    /// `collection` not in the top-level `collections` block
    /// (flow-codegen#24).
    UnknownCollection,
    /// A declared collection is malformed for its `kind` (flow-codegen#24):
    /// a `.list` is missing `element`, or a `.map` is missing `key` or
    /// `value`.
    MalformedCollection,
};
