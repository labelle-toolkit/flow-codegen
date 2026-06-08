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

/// A top-level declared growable LIST collection (flow-codegen#24, v1 —
/// MAPS deferred to a follow-up). Lowers to a file-scope
/// `pub var <name>: std.ArrayList(<element>) = .empty;` in the generated
/// `.zig` module — game-allocator-backed, game-lifetime. Operations
/// (`ListAppend`/`ListGet`/… and `ForEach`) reference it by `name` and
/// allocate on demand through `game.allocator`. There is NO auto-deinit in
/// v1: lists live for the game's lifetime and are reclaimed by the OS at
/// exit; proper deinit-on-teardown is a follow-up.
pub const Collection = struct {
    /// Zig identifier — the collection's symbol in the generated module.
    name: []const u8,
    /// Zig source text of the list's ELEMENT type — e.g. `"u32"`,
    /// `"i32"`, `"f32"`. Emitted verbatim as `std.ArrayList(<element>)`.
    element: []const u8,
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
    /// A list operation node (`ListAppend` / `ListGet` / … / `ForEach`)
    /// names a `collection` not in the top-level `collections` block
    /// (flow-codegen#24).
    UnknownCollection,
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

/// Parse the optional `collections` array (flow-codegen#24). Absent →
/// empty slice (every pre-collections file). Each entry is `{ "name":
/// "<ident>", "element": "<zig type text>" }`.
fn buildCollections(a: std.mem.Allocator, maybe: ?std.json.Value) ![]Collection {
    const v = maybe orelse return &.{};
    if (v != .array) return error.MalformedFlow;
    const items = v.array.items;
    const out = try a.alloc(Collection, items.len);
    for (items, 0..) |it, i| {
        if (it != .object) return error.MalformedFlow;
        const o = it.object;
        const cname = o.get("name") orelse return error.MalformedFlow;
        const celement = o.get("element") orelse return error.MalformedFlow;
        if (cname != .string or celement != .string) return error.MalformedFlow;
        out[i] = .{
            .name = try a.dupe(u8, cname.string),
            .element = try a.dupe(u8, celement.string),
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

/// Parse the optional `exec_edges` array (flow-codegen#8). Absent →
/// empty slice (every pre-control-flow file). Each entry is `{ "from":
/// { "node", "pin" }, "to": { "node" } }`: `from` is a full pin ref
/// (the `Branch`'s `then`/`else` exec output), `to` is a bare node ref
/// — the target node is *entered*, not wired to a named input pin.
fn buildExecEdges(a: std.mem.Allocator, maybe: ?std.json.Value) ![]ExecEdge {
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
fn buildNodeRef(maybe: ?std.json.Value) !u32 {
    const v = maybe orelse return error.MalformedFlow;
    if (v != .object) return error.MalformedFlow;
    const node_v = v.object.get("node") orelse return error.MalformedFlow;
    if (node_v != .integer or node_v.integer < 0) return error.MalformedFlow;
    return std.math.cast(u32, node_v.integer) orelse return error.MalformedFlow;
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

    // Unique local names (issue #23), and no local may collide with a
    // file-scope `variables` name — a function-local shadowing a module
    // global is ambiguous (both resolve to a bare `<name>` in the same
    // scope), so reject it rather than silently shadow.
    for (flow.locals, 0..) |v, i| {
        for (flow.locals[i + 1 ..]) |w| {
            if (std.mem.eql(u8, v.name, w.name)) return error.DuplicateVariableName;
        }
        if (hasVariable(flow.variables, v.name)) return error.DuplicateVariableName;
    }

    // Unique collection names (flow-codegen#24), and no collection may
    // collide with a file-scope `variables` or a `locals` name — all four
    // lower to a bare `<name>` in the same module/function scope, so a
    // collision is ambiguous (reuse the `DuplicateVariableName` error).
    for (flow.collections, 0..) |c, i| {
        for (flow.collections[i + 1 ..]) |d| {
            if (std.mem.eql(u8, c.name, d.name)) return error.DuplicateVariableName;
        }
        if (hasVariable(flow.variables, c.name)) return error.DuplicateVariableName;
        if (hasVariable(flow.locals, c.name)) return error.DuplicateVariableName;
    }

    // Every edge endpoint resolves to a real node.
    for (flow.edges) |e| {
        if (!hasNode(flow.nodes, e.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, e.to.node)) return error.DanglingLink;
    }

    // Exec edges (flow-codegen#8, #21): both endpoints resolve to real
    // nodes, and the `(from kind, from pin)` pair is a valid exec source.
    // A `Branch` routes through `then`/`else`; a `ForRange`/`While` loop
    // routes its single `body` exec output (flow-codegen#21). Any other
    // source kind or pin is malformed — exec edges only originate from a
    // control-flow node's declared exec outputs.
    for (flow.exec_edges) |x| {
        if (!hasNode(flow.nodes, x.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, x.to_node)) return error.DanglingLink;
        const src = findNode(flow.nodes, x.from.node) orelse return error.DanglingLink;
        const ok = switch (src.kind) {
            .Branch => std.mem.eql(u8, x.from.pin, "then") or
                std.mem.eql(u8, x.from.pin, "else"),
            // `ForRange`/`While`/`ForEach` (flow-codegen#21, #24) route
            // their single `body` exec output.
            .ForRange, .While, .ForEach => std.mem.eql(u8, x.from.pin, "body"),
            // A `Switch` routes through its `default` exec output or any
            // `case<N>` exec output (flow-codegen#22) — the N-way analogue
            // of a `Branch`'s `then`/`else`.
            .Switch => std.mem.eql(u8, x.from.pin, "default") or isCaseExecPin(x.from.pin),
            else => false,
        };
        if (!ok) return error.MalformedFlow;
    }

    // A node may be the exec-target of at most one Branch side. A node
    // wired to two exec outputs (both sides of a branch, or different
    // branches) has an ambiguous control scope — it can't lower into a
    // single `if`/`else` arm, and "run on both sides" is better expressed
    // as a top-level (unconditional) node. Reject it rather than silently
    // taking the first matching edge (flow-codegen#8).
    for (flow.exec_edges, 0..) |x, i| {
        for (flow.exec_edges[i + 1 ..]) |y| {
            if (x.to_node == y.to_node) return error.MalformedFlow;
        }
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
            // Variable-touching nodes resolve by name against EITHER the
            // file-scope `variables` or the flow `locals` (issue #23);
            // both lower to the same bare `<name>` reference.
            .GetVariable => |b| {
                if (!hasVariable(flow.variables, b.name) and !hasVariable(flow.locals, b.name)) return error.UnknownVariable;
            },
            .SetVariable => |b| {
                if (!hasVariable(flow.variables, b.name) and !hasVariable(flow.locals, b.name)) return error.UnknownVariable;
            },
            .ChangeVariable => |b| {
                if (!hasVariable(flow.variables, b.name) and !hasVariable(flow.locals, b.name)) return error.UnknownVariable;
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
                const v = findVariable(flow.variables, b.name) orelse
                    findVariable(flow.locals, b.name) orelse return error.UnknownVariable;
                if (v.type.len == 0 or v.type[0] != '?') return error.MalformedFlow;
            },
            .HasValueVariable => |b| {
                const v = findVariable(flow.variables, b.name) orelse
                    findVariable(flow.locals, b.name) orelse return error.UnknownVariable;
                if (v.type.len == 0 or v.type[0] != '?') return error.MalformedFlow;
            },
            // List operation nodes (flow-codegen#24) resolve their
            // `collection` field by name against the top-level
            // `collections` block; an unknown list is `UnknownCollection`.
            .ListAppend => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
            },
            .ListLength => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
            },
            .ListGet => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
            },
            .ListSet => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
            },
            .ListContains => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
            },
            .ListClear => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
            },
            .ForEach => |b| {
                if (!hasCollection(flow.collections, b.collection)) return error.UnknownCollection;
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

fn hasCollection(collections: []const Collection, name: []const u8) bool {
    for (collections) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

fn hasNode(nodes: []const Node, id: u32) bool {
    for (nodes) |n| if (n.id == id) return true;
    return false;
}

fn findNode(nodes: []const Node, id: u32) ?*const Node {
    for (nodes) |*n| if (n.id == id) return n;
    return null;
}

/// True for a `Switch` exec output pin named `case<N>` (`case0`, `case1`,
/// …) — the N-way analogue of a `Branch`'s `then`/`else` (flow-codegen#22).
/// Mirrors codegen's `isCallArgPin` shape: the `case` prefix followed by
/// one-or-more decimal digits.
fn isCaseExecPin(pin: []const u8) bool {
    if (!std.mem.startsWith(u8, pin, "case")) return false;
    const tail = pin[4..];
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
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
            try w.writeAll(", \"element\": ");
            try writeJsonString(w, c.element);
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
        .Branch, .ForRange, .While, .Select, .Switch => {},
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
        .ListAppend,
        .ListLength,
        .ListGet,
        .ListSet,
        .ListContains,
        .ListClear,
        .ForEach,
        => {
            const collection = switch (k) {
                .ListAppend => |b| b.collection,
                .ListLength => |b| b.collection,
                .ListGet => |b| b.collection,
                .ListSet => |b| b.collection,
                .ListContains => |b| b.collection,
                .ListClear => |b| b.collection,
                .ForEach => |b| b.collection,
                else => unreachable,
            };
            try w.writeAll(", \"collection\": ");
            try writeJsonString(w, collection);
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
