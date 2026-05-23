# RFC: Flow Vocabulary — plugin-extensible nodes, typed pins, events as graph nodes, variables

**Status:** Proposed
**Repos affected:** `labelle-core`, `labelle-assembler`, `flow-codegen`,
`labelle-gui`, `labelle-box2d` (first consumer)
**Related:** RFC-PLUGIN-EVENTS (plugin Events registry — shipped, see
[`flow-codegen#11`](https://github.com/labelle-toolkit/flow-codegen/issues/11)),
RFC-FLOWS-JSONC (`.flow.jsonc` format — shipped)

## Summary

The flow editor today is shaped for programmers. Flows compose raw
`Call` nodes against hand-typed Zig import strings; mutable state lives
in sidecar `.zig` files; events sit invisibly in the flow file's
header; the type system stops at scalars. The bouncing-ball
hit-counter — the canonical example — takes **4 nodes and 3 wires** to
express *"when a collision happens, hits += 1."* That's hostile to the
**16+ audience** the toolkit actually targets (Snap! / Bolt / GameMaker
DnD level — comfortable with typed variables, custom blocks, and
dataflow; not comfortable with Zig modules).

This RFC overhauls the flow vocabulary in four coordinated moves:

1. **`FlowNodes` — fourth plugin convention.** Plugins (and game
   modules) declare a comptime catalog of palette-ready nodes. The
   flow author drags *"Apply Impulse"* from a Box2D palette section
   instead of typing `@import("box2d").applyImpulse(...)`.
2. **Typed pins, no `any`.** Pin types ARE Zig types directly — no
   parallel taxonomy. Wire-fit = Zig type equality + numeric widening
   + declared coercions. Plugins declare `PinStyles` for display
   metadata only.
3. **Events as first-class graph nodes.** The `event:` header
   retires. A flow's trigger is whichever Event node lives in the
   canvas. Multi-trigger flows are natural; zero Event nodes = a
   subgraph.
4. **Variables — typed, scoped to flow (v1).** Top-level `variables`
   block → file-scope `var` in the generated `.zig`. Three node kinds
   (`Get` / `Set` / `Change`), with `Clear` / `HasValue` for the
   nullable form.

Together they collapse the bouncing-ball hit-counter from 4 nodes / 3
wires to **2 nodes** that read as a sentence: *when
`box2d.collision_begin` happens → change `hits` by 1*. The trigger is
visible on the canvas. The counter is a declared variable, not a
sidecar `.zig`. The increment is one block, not three.

## Motivation

### The canonical example is the canonical failure

`bouncing-ball/scripts/flows/hit_counter.flow.jsonc` today:

```jsonc
{
  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
  "nodes": [
    { "id": 1, "type": "Call", "callee": "@import(\"../hits.zig\").currentTotal" },
    { "id": 2, "type": "Literal", "value": 1 },
    { "id": 3, "type": "BinOp", "op": "add" },
    { "id": 4, "type": "Call", "callee": "@import(\"../hits.zig\").setTotal" }
  ],
  "edges": [ /* 3 wires */ ]
}
```

The author has to know, in order to author this:

- The Zig `@import` syntax + the project's file layout + that a sidecar
  `hits.zig` exists at all.
- That `BinOp` produces a value but doesn't mutate; that you need a
  `Call` sink to actually write the new total back.
- The pin names: `result`, `value`, `a`, `b`, `arg0`.
- That the event lives in the file's header, not the canvas.

Every one of these is programmer knowledge. After this RFC the same
flow reads:

```
when  box2d · collision_begin
        ↓
   change  hits  by  1
```

Two nodes. Two clicks from the palette. No `@import`. No knowledge of
`hits.zig`'s file path. The trigger is on the canvas. The counter is
a declared variable visible in a sidebar.

### Plugins as a black box

A labelle plugin is a comptime-discoverable module. `labelle-box2d`
already exports three plugin conventions discovered by the assembler
(`Components`, `Systems`, `GizmoCategories`), with `Events` added in
RFC-PLUGIN-EVENTS. The plugin's *verbs* — the operations a flow author
would want to call — are the one missing capability that still has to
be reached via raw Zig import strings.

This RFC adds `FlowNodes` as the fourth plugin convention. The plugin
curates the verb surface; the flow author consumes it from the
palette; the implementation stays inside the plugin's compiled module.
Plugins genuinely become black boxes — flows talk to them only through
declared `Components` / `Events` / `FlowNodes`, never through Zig
import strings.

### Pin types are Zig types — no `any`

Every pin lowers to a Zig expression at codegen. There is no runtime
type system; flow-codegen emits typed Zig. Introducing an `any` pin
type would force `anyopaque` + runtime dispatch, contradicting the
whole comptime-codegen-to-typed-Zig design. So pin identity is
**exactly the underlying Zig type**, as reflected from the function
signature. This eliminates a parallel type taxonomy and makes
plugin-declared types (`BodyId`, `Color`, `Vec2`) first-class pin
types automatically.

## Non-goals

- **Not a Scratch clone.** Audience is 16+. We keep typed wires, custom
  blocks (`Subflow`), and the dataflow model. We're not flattening to
  action-sequence blocks.
- **Not introducing `any`.** Pins compile to Zig; every pin has a
  concrete Zig type. No generic flow nodes.
- **Not addressing globals or save/load.** Variables in v1 are
  file-scope locals — persistent across handler calls but invisible to
  other flows. Globals + save/load are their own conversation.
- **Not solving the broadcast-visibility problem.** Two-flow
  composition via `Emit` + `OnEvent` works today; the UX gap (which
  flow listens to which event is invisible) is editor-only and out of
  scope here.
- **Not retiring the raw `Call` node.** It survives as a pro-mode
  escape hatch, off the default palette.

## Design

### 1. `labelle-core` contracts

Three new comptime types, alongside the existing `Events` /
`Components` / `Systems` shapes:

```zig
// labelle-core/src/root.zig

/// One palette-ready node a plugin (or game module) contributes.
pub const FlowNode = struct {
    /// Human label; defaults to the decl name, titlecased.
    display_name: ?[]const u8 = null,
    /// Palette section; defaults to the contributing module's name.
    category: ?[]const u8 = null,
    /// Tooltip text in the palette + on the node.
    docs: ?[]const u8 = null,
    /// `command` (mutation, `void` return) or `reporter` (pure,
    /// non-`void`). Defaults inferred from `impl`'s return type;
    /// authors override only for the rare side-effecting reporter.
    kind: ?enum { command, reporter } = null,
    /// Per-pin overrides, keyed by the corresponding param's name.
    /// Anything missing is reflected from `impl`.
    pins: anytype = .{},
    /// The Zig function. First param is `game: anytype` (threaded by
    /// codegen); remaining params become input pins; the return value
    /// (if non-`void`) becomes the output pin.
    impl: anytype,
};

/// Per-pin display metadata. Reflection gives names + types from
/// `impl`; PinSpec lets the plugin override labels and supply defaults.
pub const PinSpec = struct {
    label: ?[]const u8 = null,
    /// Zig source text of the pin's default value, evaluated at
    /// codegen. Only meaningful for primitives and enums; structs must
    /// be wired (§2).
    default: ?[]const u8 = null,
    docs: ?[]const u8 = null,
};

/// Per-type display metadata for the editor. Defaults for primitives
/// (`u32`, `i32`, `f32`, `bool`, `[]const u8`, …) ship in core;
/// plugins override / extend for their own types.
pub const PinStyle = struct {
    label: ?[]const u8 = null,
    color: ?Color = null,
    icon: ?[]const u8 = null,
};
```

A plugin (or game module) declares two new conventions, parallel to
`Events` / `Components` / `Systems`:

```zig
// labelle-box2d/src/root.zig
pub const FlowNodes = struct {
    pub const apply_impulse = labelle.FlowNode{ .impl = applyImpulseImpl };
    pub const get_velocity  = labelle.FlowNode{ .impl = getVelocityImpl };
    pub const set_velocity  = labelle.FlowNode{
        .impl = setVelocityImpl,
        .pins = .{
            .x = .{ .label = "Velocity X" },
            .y = .{ .label = "Velocity Y" },
        },
    };
};

pub const PinStyles = struct {
    pub const BodyId = labelle.PinStyle{ .label = "Body", .color = blue };
};
```

A minimal `FlowNode` is one line. Defaults absorb the verbosity;
reflection on `impl` provides pin names, types, and the
command/reporter kind. Per-pin metadata only when the author wants
nicer labels or supplies defaults.

### 2. Pin types are Zig types

No `PinType` enum. A pin's identity is the underlying Zig type, as
seen by reflection.

- **Aliases** (`pub const EntityId = u32`) collapse: both pins share
  the same underlying type → wire fits automatically.
- **Distinct nominal types** (`pub const BodyId = struct { … }`)
  stay distinct: an `EntityId` pin can't be wired into a `BodyId`
  pin without an explicit conversion.
- **Enums** are first-class: editor renders a dropdown widget on the
  pin; the variable form supports them directly.
- **Structs** can't have inline default widgets — they must be wired.
  Plugins expose constructor nodes (`MakeColor(r, g, b)`,
  `MakeVec2(x, y)`) for them.

**Wire-fit rule:**

1. Zig type equality → fits.
2. Numeric widening (`i32 → i64`, `f32 → f64`, `i32 → f32`, etc. —
   exact list TBD in open question O1) → fits automatically.
3. Declared coercion (a registered `pub fn`, see open question O4) →
   fits.
4. Otherwise → editor refuses the drop, codegen rejects the file as
   `MalformedFlow`.

No `any` escape hatch. The cost: a plugin author wanting to print/log
"any value" overloads per type (`PrintInt`, `PrintBool`,
`PrintString`). The benefit: every flow compiles to concrete typed Zig
with no `anyopaque` or runtime type checks. Snap! and Blueprint accept
the same trade.

### 3. Events as graph nodes

The `event:` header in `flow_io.Flow` retires. A flow's trigger is
whichever Event node it contains:

```jsonc
{ "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] }
```

- **Output pins** are the payload struct's fields, typed by reflection
  (per §2). For `collision_begin = struct { entity_a: u32, entity_b: u32 }`,
  the node has two `u32` (or `EntityId`-aliased) outputs.
- **A flow with multiple Event nodes** is a multi-trigger flow — all
  triggers feed the same downstream graph. Useful for "react to A *or*
  B" patterns.
- **A flow with zero Event nodes** is a subgraph (replaces today's
  `OnCall` discriminator).
- **Manual fires, timers, lifecycle hooks** become Event-node variants
  under one model; no header taxonomy.

flow-codegen lowers a multi-trigger flow to one `FlowEventHandler`
struct with one method per Event node, sharing the downstream node
bodies via a common helper fn (see open question O2 for the exact
shape).

### 4. Variables — typed, file-scope (v1)

A top-level `variables` block in the flow file:

```jsonc
{
  "variables": [
    { "name": "score",  "type": "i32",       "default": 0 },
    { "name": "target", "type": "?EntityId", "default": null },
    { "name": "state",  "type": "GameState", "default": "idle" }
  ],
  "nodes": [ ... ],
  "edges": [ ... ]
}
```

**Codegen target:** a `var <name>: <type> = <default>;` at the
generated `.zig` module's file scope. So "local" means *scoped to the
flow, persistent across handler invocations, invisible to other
flows* — like a C `static`. Without that, the variable would only live
for one handler call and couldn't accumulate, which defeats the point.

Forward-compatible with the eventual globals story: a project-wide
`variables/` folder generates a separate Zig file with `pub var`s
that flows import. The flow-side declaration shape and the Get/Set
node kinds don't change.

**Three node kinds, mirroring Scratch's grammar:**

- `GetVariable { name }` — **reporter**, output pin typed by the
  variable's declared type.
- `SetVariable { name }` — **command**, input pin typed to match.
- `ChangeVariable { name, by }` — command, the increment convenience.
  Numerics + booleans (`!=` toggle). Rejected on enums, strings,
  structs.

**Nullable variables (`?T`)** are supported with two extra operations:

- `ClearVariable { name }` — sets a nullable to `null`. Command.
- `HasValueVariable { name }` — reporter, output pin `bool`.

**Type restriction for v1:** primitives + enums + nullable forms of
those. Structs (`Color`, `Vec2`, `BodyId` if struct-typed) can be
variables, but their initial value must come from a `SetVariable`
after a constructor node — no inline default in the variables sidebar.
That falls out of the §2 rule that structs must be wired.

**Editor sidebar** for variables is **grouped by type**. Declaring
`Variable score: i32` surfaces three palette entries automatically
(`Get score`, `Set score`, `Change score by`); declaring a nullable
adds two more (`Clear target`, `HasValue target`).

### 5. Game scripts as a `FlowNodes` source

Any module in the project tree exporting `pub const FlowNodes` becomes
a palette source — not just plugins. Same `@hasDecl` discovery walk
in the assembler, extended to game-script modules. So
`bouncing-ball/scripts/hits.zig` can declare:

```zig
pub const FlowNodes = struct {
    pub const set_hits = labelle.FlowNode{ .impl = setTotal };
    pub const get_hits = labelle.FlowNode{ .impl = currentTotal };
};
```

…and the flow editor's palette shows them under a `hits` section. Once
that's available, `hit_counter.flow.jsonc` doesn't need raw `Call`
nodes anywhere — it's all declared verbs.

(In the post-RFC steady state, with variables as a first-class
primitive, even `hits.zig` itself is unnecessary — the counter
becomes a `Variable hits: i32`. But the `FlowNodes` discovery still
matters for game-specific helpers that aren't reducible to variables.)

### 6. Command vs reporter visual

- **Command** nodes (mutation, `void` return) are **rectangular**
  with a top-edge execution-flow connector and a bottom-edge
  execution-flow connector.
- **Reporter** nodes (pure value, non-`void` return) are **rounded**
  with only data pins, no execution flow.

The `kind` field on `FlowNode` defaults from `impl`'s return type:
`void` → command, otherwise reporter. Plugin authors override
(`.kind = .command`) for the rare side-effecting reporter, or
vice-versa.

The canvas reads at a glance: rectangular blocks form the execution
sequence; rounded blocks dangle off them as values. Matches Scratch
(stack vs reporter blocks), Snap! (likewise), and Blueprint
(execution wires vs data wires).

### 7. Raw `Call` node — pro-mode escape hatch

The existing `Call` node stays in `flow_io.zig`, but is **off the
default palette**. Available via a *"Add raw call…"* command in the
editor's menu. Never the first thing a kid (or anyone) reaches for.
Survives because every visual system needs an escape hatch — and
because some one-off Zig calls genuinely don't merit a `FlowNode`
declaration.

## Migration

Existing `.flow.jsonc` files (e.g.
`bouncing-ball/scripts/flows/hit_counter.flow.jsonc`) use the
`event:` header and have no `variables` block. flow-codegen ships a
one-shot converter — `zig build convert -- <path>` — mirroring
RFC-PLUGIN-EVENTS phase 3's legacy converter, that:

1. Reads the existing `event:` header.
2. Emits an `Event` node at `[0, 0]` with the matching `name` and
   auto-lays out the existing nodes adjacent.
3. Leaves the `variables` block empty.

In-tree flows convert in one CLI pass. Older flows that ship before
this RFC become a transient "v1" form supported by `buildFlow`'s
migration path for two releases, then dropped.

The `Call` nodes pointing at game-script helpers (`@import("../hits.zig").currentTotal`)
are left intact by the converter — they're still valid post-RFC, just
no longer the canonical pattern. A second-pass converter (separate
ticket) could rewrite them as `CustomNode` references once the
target script declares `FlowNodes`.

## Open questions

1. **Numeric widening — exactly which?** `i32 → i64`, `f32 → f64`,
   `i32 → f32` (lossy), `u32 → i64`, `u32 → f64`? Worth specifying
   before the wire-fit rule's editor implementation. I lean
   "Zig-standard widening only, no lossy conversions" — explicit
   `IntToFloat` / `FloatToInt` nodes for the rest.
2. **Multi-trigger codegen.** If a flow has two Event nodes (e.g.
   `collision_begin` and `level_complete`), how does the generated
   `FlowEventHandler` shape look? One struct, two methods, shared
   downstream-body helper; or two independent dispatch paths? Probably
   the former, but worth nailing.
3. **`PinSpec.default` for nullable variables.** Is `"default": null`
   parsed JSON-null and meaningful, or does null require omitting the
   field? Probably the former for `?T` types.
4. **Plugin-declared coercions.** Syntax — a
   `pub const Coercions = struct { pub fn fromBodyId(b: BodyId) Entity { … } };`
   convention? Editor needs to know they exist to allow the wire;
   codegen needs to call them at emit time.
5. **Constructor nodes for structs — discoverability.** Should
   `FlowNode` carry an `is_constructor: bool` (or a `constructs:
   ?type` field) so the editor knows to suggest these when the user
   creates a Set/Variable of a struct type? Useful UX, modest cost.
6. **`FlowNodes` declared on game scripts — file scoping.** Does
   `flow-codegen` see *every* `.zig` under `scripts/` for `FlowNodes`
   discovery, or only files in specific subfolders? Implication: a
   game's helper file that wasn't intended as a node source might
   accidentally surface in the palette. Probably opt-in via the
   declaration's existence (no `pub const FlowNodes` → not a palette
   source), which is what the proposed design already does — so this
   is more of a documentation point than a real open question.

## Phased implementation plan

Ordered so each phase compiles and ships independently.

1. **`labelle-core`** — add `FlowNode`, `PinSpec`, `PinStyle` types.
   Ship default `PinStyle`s for primitives and `EntityId`. No
   discovery, no consumers yet.
2. **`labelle-assembler`** — extend the existing plugin-discovery
   walk (the one that finds `Components` / `Systems` /  `Events` per
   RFC-PLUGIN-EVENTS phase 1) to also collect `FlowNodes` and
   `PinStyles`. Emit a comptime registry the editor and codegen can
   consume. Walk both plugin modules and game-script modules (§5).
3. **`flow-codegen`** — `flow_io.zig` retires the `event:` header in
   favour of an `Event` `NodeKind`. Adds `Variable*` node kinds
   (`Get` / `Set` / `Change` / `Clear` / `HasValue`), the top-level
   `variables` block, and a `CustomNode` `NodeKind` (for plugin /
   game `FlowNodes`-discovered verbs — `Call` stays as the raw
   escape hatch). Codegen lowers each new shape. Ship the v1 → v2
   converter.
4. **`labelle-gui`** — palette UI sourcing `FlowNodes` + `PinStyles`
   from the assembler-emitted registry. Variables sidebar (grouped
   by type). Inline default widgets for primitives + enums. Wire-fit
   drag-fit per the type system. Command/reporter visual distinction.
   *"Add raw call"* escape hatch in the menu.
5. **`labelle-box2d`** — declare `FlowNodes` for the obvious verbs
   (`apply_impulse`, `get_velocity`, `set_velocity`, `ray_cast`,
   `body_at`, …) plus `PinStyles` for `BodyId` etc. First real
   consumer.
6. **Cleanup** — convert in-tree flows
   (`bouncing-ball/scripts/flows/hit_counter.flow.jsonc` + any
   others) via `zig build convert`; drop the v1 file-format-support
   code from `flow_io.zig` after a two-release deprecation window.

## Rejected alternatives

### A `PinType` enum / parallel type taxonomy

Define a closed set of pin types (`int`, `float`, `bool`, `string`,
`entity`, `vec2`, `color`, …) the editor knows about, with a
Zig-to-PinType mapping. Rejected: it forces a second source of truth
alongside Zig's type system, doesn't extend naturally to
plugin-declared types (`BodyId`, etc.), and offers no benefit over
just using Zig types directly. The "Zig is the type system" decision
falls out cleanly from "every pin compiles to Zig."

### `any` pin type as an escape hatch

Allow pins of unknown type, resolved at codegen against the wired
value. Rejected: every pin compiles to Zig; an `any` pin would need
`anyopaque` + runtime dispatch, contradicting the
comptime-codegen-to-typed-Zig design. We accept the cost — no generic
`Print(any)` — because the alternative bleeds dynamic typing into a
statically-typed codegen pipeline.

### Editor-derived synthetic Event nodes (header stays)

Keep the `event:` header in `flow_io.zig`; have the editor synthesize
a non-stored "trigger node" from it for display only. Rejected:
forces a permanent mismatch between the file and the canvas, doesn't
unify multi-trigger / subgraph / timer / lifecycle, and we're already
changing the format for `variables` and `FlowNodes` anyway. Once you
have to commit to a file-format change, doing the right thing is
cheaper than doing the synthetic-only thing.

### Flow files declaring variables (vs sidecar `variables/` folder)

For v1 we picked **declared at the top of the flow file**, scoped to
that flow. The alternative — a project-wide `variables/*.zig` folder
generating `pub var`s — is the right shape for globals later, but
it's overkill for v1 locals and tangles into save/load semantics we
don't have a story for. Deferred.

### `FlowNodes` discovery restricted to plugins only

We considered restricting `FlowNodes` discovery to plugin modules so
the convention has a clear ownership story (only plugins curate the
palette). Rejected: it forces game-specific helpers (`hits.zig`'s
`setTotal`) into raw `Call` nodes forever — exactly the friction this
RFC is trying to remove. Extending discovery to any module exporting
`FlowNodes` is the right move and matches author expectations that
their own helpers appear in the palette.

### Retire the raw `Call` node entirely

Force every callable to be declared as a `FlowNode` first; remove
`Call` from `flow_io.zig`. Rejected: every visual system needs an
escape hatch, and forcing a one-off Zig call to require a `FlowNode`
declaration adds friction without proportional safety. `Call`
survives, but is off the default palette so it isn't the canonical
shape.
