# RFC: Plugin `Events` — extending the engine's custom-events substrate to plugins

**Status:** Proposed (reworked)
**Repos affected:** `labelle-engine` (#422 — already shipped),
`labelle-assembler`, `labelle-box2d`, `flow-codegen`
(`labelle-core` is reused as-is)
**Related:** labelle-engine **#422 — Custom Game Events (shipped/closed)**,
RFC-FLOWS-JSONC (`.flow.jsonc` format, `OnEvent` entry),
flow-codegen #50 (graph → Zig codegen), #51 (assembler flow discovery),
flying-platform-labelle #208 (Plugin-Exported Controllers)

## Summary

The engine **already ships** a custom-events substrate (labelle-engine
#422, closed): a game drops event structs into an `events/*.zig`
directory, the assembler scans them and codegens a `GameEvents` tagged
union which is merged into the engine's hook payload union, and
scripts/hook-handler structs receive each event variant through the
existing `HookDispatcher`/`MergeHooks` machinery. `game.emit(...)`
buffers, `game.emitSync(...)` dispatches immediately, and
`game.dispatchEvents()` drains the buffer at end of frame.

This RFC **extends that substrate to plugin-declared events** instead
of standing up a parallel registry:

1. A plugin declares its events in a `pub const Events` struct
   (discovered by the assembler via `@hasDecl(plugin, "Events")` — the
   same convention as `Components`, `Systems`, `GizmoCategories`).
2. The assembler folds every discovered `Events` declaration into a
   `PluginEvents` union and adds it to the *same* `AllHookPayloads`
   merge that already absorbs `GameEvents`.
3. Plugins emit with the existing `game.emit(...)` / `game.emitSync(...)`.
4. Flows / scripts subscribe via hook-handler structs threaded into
   the same `engine.MergeHooks(AllHookPayloads, .{...})` instance the
   assembler already builds for `GameHooks`.

The v1 `OnEvent` (`flow-codegen` `main` `c6f29ef`) — which binds a flow
to a plugin's raw `?*const fn` slot via a hand-written
`module`+`callback`+`params` triple — becomes the **legacy form**. The
new form names an event (`{"type":"OnEvent","name":"box2d.collision_begin"}`)
and codegen reflects its payload type out of the merged union; the
generated flow handler is a hook-handler-struct method, not a raw
callback assigned in `setup`.

This delivers what v1 lacked:

1. **One name, one source of truth.** The flow author writes a name;
   the payload type comes from the plugin's `Events` declaration via
   the merged union. No hand-copied signature.
2. **Multiple listeners per event.** `MergeHooks.emit` already
   `inline for`s every handler struct and calls every match — that *is*
   multi-listener dispatch. Today's single `?*const fn` slot allows
   exactly one binding; a second flow silently clobbers the first.
3. **A unified emit/dispatch model.** Plugin events ride the same
   buffered/sync emit path as `GameEvents`. No new mechanism to learn,
   no second buffer to drain, no second registry to keep in sync.
4. **Flows are event sources too.** A new `Emit` node lowers to
   `game.emit(.{ .<qualified_tag> = .{ ... } })`, so a flow can fire
   events as well as listen to them — without a new mechanism (§8).
   Event *declarations* stay where they already live (`events/*.zig`
   for game events, `pub const Events` for plugins); flows reference
   them by name in both directions.

## Motivation

### v1 `OnEvent` hand-copies a signature onto a single-listener slot

v1 `OnEvent` (`flow-codegen` `main`, `c6f29ef`) lets a flow name a
plugin module, a raw callback variable, and the callback's parameters,
all hand-written (`flow-codegen/src/flow_io.zig:60-66`):

```jsonc
"event": {
  "type": "OnEvent", "module": "box2d",
  "callback": "on_collision_begin",
  "params": [ {"name":"entity_a","type":"u32"}, {"name":"entity_b","type":"u32"} ]
}
```

`renderEventEntry` (`flow-codegen/src/codegen.zig:517-575`) emits a
`flowEvent` handler whose signature matches `params` verbatim and a
`setup()` that does `__event_src.on_collision_begin = &flowEvent`. Three
limitations follow directly:

- **Hand-copied signature.** `params` must match
  `labelle-box2d/src/root.zig:90`'s
  `?*const fn(entity_a: u32, entity_b: u32) void` exactly. A plugin
  change becomes a raw Zig type error at the generated assignment, far
  from the `.flow.jsonc` that caused it.
- **One listener per event.** Two `OnEvent` flows on
  `on_collision_begin` both call `__event_src.on_collision_begin = &flowEvent`
  in their `setup`; the second `setup` wins. No diagnostic.
- **No `game`, no `entity`.** `renderEventEntry` rejects `GetComponent`
  / `SetField` (`anyNodeNeedsEntity`) and `Subflow` nodes
  (`codegen.zig:531-535`) — the callback is `fn(u32,u32) void`, with
  nothing else in scope. An event flow cannot touch ECS state, which is
  most of what a flow is for.

### The engine already solved emit/dispatch for game events (#422)

`labelle-engine#422` is **shipped and closed**. The substrate is:

- **Per-game declaration.** A game puts event structs in `events/*.zig`.
  The assembler scans them
  (`labelle-assembler/src/root.zig:251` —
  `scanner.linkAndScan(..."events", ".zig")`).
- **Codegen.** The assembler emits a `GameEvents` tagged union (one
  variant per scanned event struct) at
  `labelle-assembler/src/main_zig.zig:2755-2775` and merges it into the
  engine's hook payload at lines 2689-2697:

  ```zig
  const GameEvents = union(enum) {
      worker_sleep_start: worker_events.WorkerSleepStart,
      ...
  };
  const AllHookPayloads = engine.core.MergeHookPayloads(.{
      engine.HookPayload(EcsBackend.Entity), GameEvents,
  });
  ```

- **Engine `Game`** (`labelle-engine/src/game.zig:47-71, 208-209,
  444-509`) is generic over `comptime GameEvents: type`. When
  `GameEvents != void` it allocates an `event_buffer:
  std.ArrayList(GameEvents)`, exposes `emit(event)` (buffered, line
  444) / `emitSync(event)` (immediate, line 477), and routes both
  through `emitHook` → `HookDispatcher.emit(payload)`.
  `dispatchEvents()` (line 491) drains the buffer end-of-frame; the
  assembler-emitted main loop calls it every frame
  (`main_zig.zig:2964`, `:2979`).
- **Dispatch** runs through `labelle-core/src/dispatcher.zig`:
  `HookDispatcher`/`MergeHooks` switch on the union tag, look up a
  declaration of the same name on each receiver struct, and call it —
  multi-listener fan-out is free (`dispatcher.zig:53-62`, `:94-112`).
  The assembler wires `GameHooks` as
  `engine.MergeHooks(AllHookPayloads, .{ *hook_a, *hook_b, ... })`
  (`main_zig.zig:2714-2720`).

That is **already** what a "plugin events registry" needs to be. A
parallel `EventRegistry` would duplicate it.

### Plugins already have a declaration convention — events are the gap

A labelle plugin is a comptime-discoverable module. `labelle-box2d`
(`labelle-box2d/src/root.zig`) exports:

- `pub const Components` (`:27`) — auto-wired by
  `engine.ComponentRegistryWithPlugins`.
- `pub const Systems` (`:36`) — auto-dispatched by
  `engine.SystemRegistry` (`labelle-engine/scene/src/system.zig:53,
  68, 81, ...` — every helper walks plugin modules with
  `@hasDecl(mod, "Systems")`).
- `pub const GizmoCategories` (`:73`) — auto-discovered (same file,
  `:213-247`).

Events are the one plugin capability with **no** declaration struct.
They are loose `pub var ?*const fn` slots
(`labelle-box2d/src/root.zig:90-95`). `Events` closes that gap and
makes plugin events a first-class, conventionally-declared plugin
export, exactly like the other three.

## Non-goals

- **No runtime flow interpreter.** Flows stay codegen-to-Zig.
- **No new event *transport*.** This RFC does not change *how*
  `labelle-box2d` detects a collision (`processContacts`,
  `root.zig:493`). It changes how the *resulting event* is declared,
  discovered, and delivered.
- **No new dispatcher.** No parallel `EventRegistry`, no parallel
  buffer, no parallel emit API — everything rides the
  `GameEvents`/`MergeHookPayloads`/`emit`+`dispatchEvents` substrate
  that #422 already ships.
- **No change to `Components` / `Systems` / `GizmoCategories`.** `Events`
  is a fourth peer struct.
- **Engine lifecycle hooks** (`game_init`, `frame_start`, etc., from
  `labelle-engine/src/hooks_types.zig:12-39`) are unchanged.

## Design

### 1. Plugin `Events` declaration

A plugin declares the events it emits in a `pub const Events` struct.
Each declaration **is** the event's payload struct — its fields are the
event's data — and the declaration name is the event's variant name
in the merged union.

```zig
// labelle-box2d/src/root.zig
pub const Events = struct {
    /// Two entities started touching.
    pub const collision_begin = struct { entity_a: u32, entity_b: u32 };
    pub const collision_end = struct { entity_a: u32, entity_b: u32 };
    pub const collision_hit = struct {
        entity_a: u32, entity_b: u32,
        point_x: f32, point_y: f32,
        normal_x: f32, normal_y: f32,
        speed: f32,
    };
    pub const sensor_enter = struct { sensor_entity: u32, visitor_entity: u32 };
    pub const sensor_exit = struct { sensor_entity: u32, visitor_entity: u32 };
};
```

Rationale (**resolves O1** — flat, no `Payload` wrapper):

- **The event declaration is its payload type.** Matches the three
  existing flat plugin conventions (`Components`, `Systems`,
  `GizmoCategories`). `Events` is the fourth and stays consistent — no
  nested `pub const Payload` wrapper.
- **Flat does not forgo metadata.** A Zig struct holds fields *and*
  decls, separated by `@typeInfo`. Docs are `///` comments;
  future metadata (the O2 primary-entity marker, editor hints) is an
  additive `pub const primary_entity = "entity_a";` *beside* the payload
  fields — no wrapper.
- **The declaration name is the merged-union variant.**
  `collision_begin`, not `on_collision_begin` — the `on_` prefix was a
  C-callback-slot convention and a registry name does not need it. It
  doubles as a Zig identifier in generated symbols with no
  sanitization.
- **Discovered by `@hasDecl`**, exactly like `Components`/`Systems`. A
  plugin with no `Events` struct is silently skipped — zero cost.

The plugin keeps emitting from its own systems; it just goes through
`game.emit(...)` instead of a raw slot (§6).

### 2. Assembler discovery: feed the existing pipeline

The assembler **does not** stand up a new registry. It extends the
existing `GameEvents` / `AllHookPayloads` blocks.

Today (`labelle-assembler/src/main_zig.zig:2755-2775, 2689-2697`):

```zig
const GameEvents = union(enum) {
    worker_sleep_start: worker_events.WorkerSleepStart,
    ...
};
const AllHookPayloads = engine.core.MergeHookPayloads(.{
    engine.HookPayload(EcsBackend.Entity), GameEvents,
});
```

After (additive — game events untouched):

```zig
const GameEvents = union(enum) { /* scanned from events/ */ };

// New: walk the plugin module list with @hasDecl(plugin, "Events")
// (same shape as the existing Components/Systems discovery) and emit
// one variant per declaration, plugin-qualified to avoid collision.
const PluginEvents = union(enum) {
    box2d__collision_begin: box2d.Events.collision_begin,
    box2d__collision_end:   box2d.Events.collision_end,
    // ...one variant per (plugin, event-name) pair...
};

const AllHookPayloads = engine.core.MergeHookPayloads(.{
    engine.HookPayload(EcsBackend.Entity),
    GameEvents,
    PluginEvents,
});
```

`PluginEvents` is `void` when no plugin declares `Events` — the same
backward-compat shape `GameEvents` already uses
(`main_zig.zig:2694-2698`). Plugin-qualified variant names
(`<plugin>__<event>` separator TBD; safe candidates: `__`, `_E_`) keep
two plugins from colliding on a shared name like `collision_begin`.

`MergeHookPayloads`
(`labelle-core/src/dispatcher.zig:136-185`) is **unchanged** — its
duplicate-field check already enforces unique variants across the
merged unions and produces a single flat tagged union.

The assembler additionally exposes the list of plugin-event names (for
the GUI flow editor dropdown — O6) and a comptime resolver
(`name → variant-type`) consumed by flow-codegen. Both are derived
from the same `@typeInfo` over the merged union — no new state.

### 3. Assembler discovery: feed the existing handler list

`GameHooks` is built today as
`engine.MergeHooks(AllHookPayloads, .{ *gameHook1, *gameHook2, ... })`
(`main_zig.zig:2714-2720`). A flow that subscribes to a plugin event
is just one more receiver in that tuple.

Flow-codegen emits each `OnEvent` flow as a **hook-handler struct**
with a method named after the resolved event variant. The assembler
collects every flow's handler struct (alongside the existing
`hook_names` walk it already does) and concatenates them onto the
`GameHooks` receiver tuple:

```zig
const GameHooks = engine.MergeHooks(AllHookPayloads, .{
    *user_hook_a, *user_hook_b,
    *flow_collision_logger,   // flow handler struct
    *flow_score_on_hit,        // flow handler struct
    // ...
});
```

Order is the assembler's flow-name sort (deterministic, reproducible —
O3 below), but the order is an unspecified author contract.

### 4. Dispatch: the engine already does it

There is **no new dispatch path**. A plugin emits a
`PluginEvents`-tagged variant through `game.emit(...)` / `emitSync(...)`;
`emit` appends to the existing `event_buffer`; the engine's existing
`dispatchEvents()` (`game.zig:491`) drains it and routes each variant
through `emitHook` → `MergeHooks.emit` — which `inline for`s every
handler struct, finds the matching declaration name, and calls it
(`labelle-core/src/dispatcher.zig:99-111`).

This **inherits** multi-listener fan-out for free. It also inherits
the buffered-vs-sync split:

- `game.emit(...)` — buffered, delivered end-of-frame, the default for
  notification events. This is the path that solves the v1
  one-listener limit.
- `game.emitSync(...)` — immediate, with the caveats already
  documented inline (`game.zig:458-476`: re-entrancy and ordering vs
  the buffered queue). Plugins that need the handler to have run
  before the next statement opt in deliberately.

### 5. `game` access — keep handlers payload-only (open question O7, new)

**The shipped `HookDispatcher`/`MergeHooks` handler signature is
`fn(receiver_self, payload_variant_data)` (`dispatcher.zig:58, :106`)
— no `game`.** The engine works around this by injecting `game_ptr`
into hook structs that declare such a field, at init time
(`game.zig:419-429`):

```zig
const HookType = @typeInfo(Hooks).pointer.child;
if (@hasField(HookType, "game_ptr")) {
    hook_ptr.game_ptr = @ptrCast(self);
}
```

A handler that needs `game` declares `game_ptr: *anyopaque = undefined`
on its struct and reads it inside the body. That is the *existing,
shipped* contract for every hook handler in the engine — game hooks,
plugin hooks, scene hooks.

**Decision (least-invasive):** new-form `OnEvent` flow handlers
follow the same contract — they are receiver-method handlers with no
`game` argument. A flow that needs `game` declares
`game_ptr: *anyopaque = undefined` and the assembler initializes it the
same way it initializes every other hook struct's `game_ptr`. The
generated method body downcasts it to the assembled `Game` and
proceeds.

```zig
// Generated for an `OnEvent` flow on `box2d.collision_begin`.
// The flow's body needs `game` because it calls GetComponent.
const FlowCollisionLogger = struct {
    game_ptr: *anyopaque = undefined,

    pub fn box2d__collision_begin(self: *@This(), payload: box2d.Events.collision_begin) void {
        const game: *AssembledGame = @ptrCast(@alignCast(self.game_ptr));
        // payload.entity_a, payload.entity_b, game in scope
        // → GetComponent / SetField / Subflow lowerable
    }
};
```

Consequences:

- `renderEventEntry`'s rejection of entity-scoped nodes
  (`anyNodeNeedsEntity`, `codegen.zig:531`) and of `Subflow`
  (`codegen.zig:534-535`) is **lifted for new-form flows** — `game` is
  reachable through `game_ptr`. The legacy form keeps both rejections.
- **`entity` is not automatic.** A collision event has two entities;
  there is no single "the entity". The flow reads `payload.entity_a`
  / `payload.entity_b` explicitly. Whether a payload may *mark* one
  field as the primary entity stays open as O2.
- **No invasive dispatcher change.** Reworking `HookDispatcher` to
  thread `game` everywhere would change the signature of every hook
  handler in the shipped engine (game-side and plugin-side). That is
  out of scope here; the `game_ptr`-field convention is already the
  engine's de-facto answer.

**New open question (O7).** Should the engine *eventually* thread a
`game` argument into `HookDispatcher.emit` instead of relying on
`game_ptr` plumbing? It would tighten typing (no `*anyopaque`
downcast) and remove the init-time field-injection special case. It
also breaks every shipped handler signature. **Out of scope for this
RFC** — flagged here so it is not lost; tracked separately if pursued.

### 6. Plugin emit-side change (`labelle-box2d`)

`labelle-box2d`'s `processContacts` / `processSensorEvents`
(`root.zig:493-569`) change from raw-slot calls to `game.emit`:

```zig
// before — root.zig:512
if (on_collision_begin) |cb| cb(entity_a, entity_b);

// after
game.emit(.{ .box2d__collision_begin = .{ .entity_a = entity_a, .entity_b = entity_b } });
```

No new emit API. No new buffer. The variant tag is the
`<plugin>__<event>` qualified name `PluginEvents` declares (§2). The
existing buffer + `dispatchEvents` drain runs unchanged.

The plugin no longer declares `pub var on_collision_begin` etc.; it
declares `pub const Events` (§1) and emits through `game.emit`. See
Migration for the deprecation window.

### 7. flow-codegen resolution

`OnEvent` gains a `name` form; `module`/`callback`/`params` go
optional:

```jsonc
// new form — name-resolved
"event": { "type": "OnEvent", "name": "box2d.collision_begin" }
```

`flow_io.Event.OnEvent` (`flow-codegen/src/flow_io.zig:60-66`) becomes:

```zig
OnEvent: struct {
    /// Plugin-qualified event name (`box2d.collision_begin`) or a
    /// bare name when unambiguous across the merged plugin set.
    /// Resolved by the assembler against the discovered `PluginEvents`
    /// union; the variant tag in the codegen output is the qualified
    /// form (`box2d__collision_begin`).
    name: ?[]const u8 = null,

    // ── legacy / v1 fields — all optional, see Migration ──
    module: ?[]const u8 = null,
    callback: ?[]const u8 = null,
    params: []Param = &.{},
},
```

`buildEvent` (`flow_io.zig:307-313`) accepts either: `name` present →
new form; `module`+`callback` present → v1 form; both present, or
neither, is `error.MalformedFlow`.

Codegen (`renderEventEntry`, `codegen.zig:517-575`):

- **New form.** The event name is resolved through the assembler's
  comptime `name → variant-type` resolver (same pattern as `Subflow`
  resolution in RFC-FLOWS-JSONC §5). The handler is a struct method
  on a generated `FlowEventHandler` struct (§5); its parameter list is
  reflected from the resolved variant's payload struct fields —
  codegen reads `@typeInfo(VariantType).@"struct".fields` instead of a
  hand-written `params` list. An unknown name is `error.UnknownEvent`,
  reported against the `.flow.jsonc`. The flow's generated handler
  struct is appended to the assembler's `GameHooks` receiver tuple
  (§3); there is no `setup()` doing slot assignment.
- **Legacy form.** `renderEventEntry` keeps its current `setup`/
  `flowEvent`/slot-assign behaviour verbatim. Unchanged code path,
  removed in Migration phase 3.

Because the registry-derived signature is the same field set v1
`params` spelled out by hand, the new form is a **strict superset** of
v1. flow-codegen ships a converter pass (parallel to the
`.flow.zon`→`.flow.jsonc` converter shipped by RFC-FLOWS-JSONC) that
rewrites legacy `OnEvent` blocks once it can resolve
`module`+`callback` to a merged-union variant.

### 8. flow-codegen emission: the `Emit` node

Flows are also event *sources*. A new `NodeKind.Emit` lets a flow fire
any event the merged union already carries — game events declared in
`events/*.zig` (#422) or plugin events declared in `pub const Events`
(§1). Event **declarations** stay in those two places; the flow is an
emitter, not a declaration site (this is option A — see "Rejected
alternatives" for the flow-declares-events option, deferred).

```jsonc
{ "id": 7, "type": "Emit",
  "event": "my_game.player_attacked",
  "pos": [400, 200] }
```

- `event` uses the same dotted name resolver phase 1 builds for
  `OnEvent`. An unknown name is `error.UnknownEvent` against the
  `.flow.jsonc`, reported with the same diagnostic as the listener side.
- The node's **input pins are the payload struct's fields**, reflected
  via `@typeInfo(VariantType).@"struct".fields` — the same reflection
  `OnEvent` uses to build its handler signature, just running in the
  opposite direction. An unwired payload field is `error.DanglingPin`.
- `Emit` has no output pin — it lowers to a statement, not an
  expression — and so `discardUnconsumedResult` (`codegen.zig:634-651`)
  skips it the same way it skips `SetField` and a void `Subflow`.

**Codegen** lowers an `Emit` node to a one-liner against `game.emit`:

```zig
// generated body, pin-resolved inputs (n3_value, n5_value, …):
game.emit(.{ .my_game__player_attacked = .{
    .attacker = n3_value,
    .damage   = n5_value,
} });
```

- The variant tag is the same plugin-qualified form phase 1 emits
  (`<plugin>__<event>` for plugin events; the existing field name for
  game `events/*.zig` events, which are already flat in `GameEvents`).
- Calls **`game.emit`**, not `game.emitSync` — buffered/end-of-frame is
  the right default (it is what every #422 use site does), and
  re-entrancy from a flow body emitting mid-tick would compound the
  caveats `emitSync` itself warns about (`game.zig:458-476`). A
  later opt-in `"sync": true` on the `Emit` node is the cheap escape
  hatch when one is wanted; not in this phase.
- Needs `game` in scope. Lifecycle flows (`OnUpdate`/`OnCreate`/
  `OnDestroy`) have it directly; `OnEvent` flows have it through the
  `game_ptr` field-injection (§5). So `Emit` works in every flow type
  — including in an `OnEvent` flow re-emitting a derived event, which
  is the natural way to chain.

**Validation** (`flow_io.zig:validate`):

- `Emit` joins the node-kind switch with no special structural rule
  beyond "every named input pin has an edge" (handled at codegen as
  `DanglingPin`).
- An `Emit` whose `event` does not resolve at codegen is rejected
  there, not in `validate` — the resolver lives in the assembler
  (phase 1) and `validate` runs without it (`flow_io.zig` has no
  registry handle).

This is one new `NodeKind` variant, one validate arm, and one codegen
template — small enough to ship with phase 3 (the rest of the
flow-codegen new-form work).

## Migration

Two independent migrations — flow side and plugin side — staged so
neither breaks current users mid-flight.

### Flow side (`OnEvent` JSONC)

- `OnEvent`'s `module`/`callback`/`params` become **optional**; `name`
  is **added** (§7). A v1 flow file parses and codegens unchanged.
- The legacy `renderEventEntry` path is kept verbatim through one
  release, then the converter rewrites in-tree flows and the legacy
  path is dropped — the same hard-cut RFC-FLOWS-JSONC used for
  `.flow.zon`, justified the same way (very few files exist).
- **Converter.** A `flow-codegen` pass: for a legacy `OnEvent`, look up
  `module`+`callback` against the discovered plugin-event set; on a
  unique match, rewrite to
  `{"type":"OnEvent","name":"<plugin>.<event>"}` and drop `params`. A
  `callback` with no match (a plugin not yet migrated) is left as-is
  and warned.

### Plugin side (`labelle-box2d` callback vars)

`labelle-box2d`'s `on_collision_*` / `on_sensor_*` `pub var`s
(`root.zig:90-95`) cannot vanish without breaking hand-written games
that assign them today. Phased:

1. **Add `pub const Events`** (§1) alongside the existing `pub var`s.
   The plugin emits to *both* `game.emit` and the legacy slot for one
   release — a legacy assignment still fires, a new subscriber also
   fires. No breakage.
2. **Deprecate the `pub var`s** — doc-comment them deprecated; the
   migration guide points at `Events` + `game.emit`.
3. **Remove the `pub var`s** in a later minor — the dual-emit shim in
   `processContacts` collapses to a single `game.emit`.

A hand-written (non-flow) game subscribes by writing its own hook
handler struct and registering it the same way it registers any
existing hook today — either through `game.setHooks(...)` (single
receiver) or by being included in the assembler's `MergeHooks`
receiver tuple. No new engine API required.

## Open questions

1. ~~**`Events` declaration shape.**~~ **Resolved — flat form (§1).**
   The event declaration *is* its payload struct, matching the flat
   `Components`/`Systems`/`GizmoCategories` conventions. Future
   metadata is an additive `pub const` decl beside the payload fields.
2. **Primary-entity convention.** Should an event payload be able to
   *mark* one field as "the entity" so an event flow gets an automatic
   `entity` binding like `OnCreate` does? Useful for single-entity
   events (a future `box2d.body_sleep`); meaningless for symmetric
   two-entity events (`collision_begin`). Possibly an optional
   `pub const primary_entity = "entity_a"` decl.
3. ~~**Dispatch order across flows.**~~ **Resolved — no priority field;
   "all listeners run, order deterministic-but-unspecified."**
   `MergeHooks.emit` already `inline for`s every receiver and calls
   every match (`dispatcher.zig:99-111`), so all listeners run. The
   order is the order the assembler emits the receiver tuple — the
   assembler must sort flow handler structs by flow registry name so
   builds are reproducible. As an author-facing contract the order is
   **unspecified — flows must not depend on it**: event reactions are
   independent side effects; a flow that needs another flow first
   should express that explicitly (a `Subflow` call, or a derived
   event), not rely on a hidden race. This matches ECS systems today,
   which run in `SystemRegistry` order with no per-system priority.
   `priority` stays off the notification flavor; it returns in the
   consumable flavor (O4) where ordering decides which handler
   consumes the event first.
4. ~~**Cancellable / consumable events.**~~ **Resolved — two event
   flavors.** An event declares one of:
   - **notification** (the default — `collision_begin`, `sensor_enter`,
     …): fan-out, every listener runs, `void` handlers, `MergeHooks`
     dispatch unchanged, O3 holds (unspecified order). A notification
     reports something that already happened — there is nothing to
     consume.
   - **consumable** (input-style — a future `ui.click`, `input.key`):
     handlers run in an explicit **priority** order and return a
     "handled" signal; the first handler to mark the event handled
     **stops propagation**.

   The flavor is an additive decl on the flat event struct (O1),
   defaulting to notification:
   `pub const click = struct { x: f32, y: f32, pub const consumable = true; };`.
   The consumable flavor needs a return-aware dispatch path — a
   `bool`-returning handler and an early `break` — which the shipped
   `MergeHooks` (`void`, no break) lacks; that is a `labelle-core`
   `dispatcher.zig` addition. **Scope:** the notification flavor is
   v1; the consumable flavor (the dispatcher change + the `OnEvent`
   `priority` field) is a defined follow-up phase. The notification
   pipeline does not depend on it.
5. ~~**Non-plugin event sources.**~~ **Resolved.** Already shipped by
   labelle-engine #422 (Custom Game Events): a game declares event
   structs in `events/*.zig`, the assembler scans and codegens
   `GameEvents`, scripts emit through `game.emit`. This RFC simply
   unifies plugin-declared events into the *same* merged
   `AllHookPayloads` substrate — game-script event sources need no
   extra work and continue to function unchanged.
6. **Editor support.** The labelle-gui flow editor should offer the
   discovered event names as a dropdown (the assembler exposes the
   `PluginEvents` variant name list, §2) instead of the v1 free-text
   `module`+`callback` fields. Tracked with `labelle-gui` `flow_io.zig`,
   not this RFC.
7. **(New) Thread `game` through `HookDispatcher` instead of
   `game_ptr` field injection?** §5 keeps the shipped
   `fn(receiver_self, payload)` handler signature and reuses the
   `game_ptr` field convention the engine already uses for every hook
   struct (`game.zig:419-429`). A more invasive alternative would
   change `HookDispatcher.emit` to pass `game` as a first argument,
   removing the `*anyopaque` downcast — but it changes the signature
   of every shipped hook handler in the engine (game-side and
   plugin-side). Out of scope for this RFC; flagged so it is not lost.

## Phased implementation plan

Ordered so each phase compiles and ships independently.

1. **`labelle-assembler`** — extend the existing `GameEvents`/
   `AllHookPayloads` codegen blocks (`main_zig.zig:2689-2697`,
   `:2755-2775`) to walk the plugin module list with
   `@hasDecl(plugin, "Events")` and emit a `PluginEvents` union next
   to `GameEvents`, merged into the same `AllHookPayloads`. Expose the
   resulting variant-name list and a comptime resolver for
   flow-codegen.
2. **`labelle-box2d`** — add `pub const Events` (§1); make
   `processContacts`/`processSensorEvents` dual-emit (`game.emit` +
   legacy slot). No removal yet (Migration phase 1).
3. **`flow-codegen`** — `OnEvent` gains `name`;
   `module`/`callback`/`params` go optional (`flow_io.zig`);
   `buildEvent` accepts both forms; `renderEventEntry` resolves the
   new form through the assembler's variant-name resolver, derives
   the handler signature from the resolved variant's struct fields,
   emits a hook-handler struct with the `game_ptr` field for entity-
   scoped nodes, and lifts the entity/`Subflow` rejections for new-form
   flows. Also add the **`Emit` node** (§8): a new `NodeKind` variant
   with payload-field input pins, lowering to `game.emit(.{ .<tag> =
   .{...} })`. Ship the legacy→name converter.
4. **`labelle-assembler`** — collect flow handler structs and append
   them to the `GameHooks` receiver tuple
   (`main_zig.zig:2714-2720`); initialize their `game_ptr` field the
   same way the existing hooks loop does (`game.zig:419-429`).
5. **`labelle-gui`** — `flow_io.zig` reads/writes the `name` form; the
   editor offers the discovered event-name dropdown.
6. **Cleanup** — convert in-tree flows to the `name` form; deprecate
   then remove `labelle-box2d`'s `pub var` callback slots (Migration
   phases 2-3); drop the legacy `renderEventEntry` path.
7. **Consumable event flavor** (follow-up, O4) — add return-aware
   dispatch to `labelle-core/src/dispatcher.zig` (a `bool`-returning
   handler + early `break`); let a plugin event opt in via
   `pub const consumable = true`; add the `OnEvent` `priority` field
   and its receiver-tuple sort. Sequenced after phases 1-6; the
   notification pipeline does not depend on it.

## Rejected alternatives

### A parallel plugin `EventRegistry`

An earlier draft of this RFC proposed a new
`engine.EventRegistry(.{...})` over plugin modules, synthesizing its
own enum + payload union and (optionally) generating a fresh
`HookDispatcher`/`MergeHooks` from them. Rejected: the engine
**already ships** that substrate as labelle-engine #422 (closed) —
`events/*.zig` discovery, `GameEvents` codegen, the
`MergeHookPayloads(.{engine.HookPayload, GameEvents})` merge, the
`emit`/`emitSync`/`dispatchEvents` API on `Game`, and `HookDispatcher`/
`MergeHooks` dispatch — and a parallel registry would be a second
mechanism doing the same job. The win of this RFC is *plugin
discovery* (`@hasDecl(plugin, "Events")`), not a second dispatch path;
§2 simply folds plugin-declared events into the same merged
`AllHookPayloads` and §4 reuses the engine's existing dispatch
unchanged.

### Build a bespoke events-only dispatcher

A dispatcher dedicated to plugin events, separate from
`HookDispatcher`. Rejected for the same reason: the engine already
dispatches `GameEvents` through `HookDispatcher`/`MergeHooks`. A
second mechanism would diverge from "an event fired and N things
listened" semantics for no gain. labelle-tasks already emits through
`HookDispatcher`; plugin events joining it is consistent, not novel.

### Keep raw `?*const fn` slots, allow a slice of them

Make `on_collision_begin` a `[]const *const fn(...)` instead of a
single `?*const fn(...)`. Rejected: fixes the one-listener symptom
and nothing else — the signature is still hand-copied, there is still
no name resolution, no `game`, no discovery, no editor dropdown.

### Flow names the raw callback, codegen wraps it (no plugin change)

Keep `labelle-box2d` exactly as-is; have flow-codegen synthesize a
multiplexer that owns the slot and fans out. Rejected: the
multiplexer would have to live *somewhere* with a stable address the
plugin's `?*const fn` can point at, and be shared across all flows
for that event — which is the registry, just built bottom-up and
undiscoverable. And it still cannot give the handler `game`. The
plugin must participate; §1 makes that a clean, conventional
declaration matching the three existing plugin-export conventions.

### Flow files declare their own events (option B)

The `Emit` node (§8) only references events declared elsewhere
(`events/*.zig` for game events, `pub const Events` for plugins). An
alternative was to let a flow file itself declare an event payload —
a top-level `"events": [...]` block — and have the assembler walk
flow files as a third declaration source. Rejected for v1: it
fragments the source-of-truth for an event's payload across three
discovery sites, complicates the assembler's scanner (it would have
to extract type information from `.flow.jsonc`, not just `.zig`
declarations), and offers no capability the two existing sites do
not. A flow author who needs a custom event creates
`events/my_event.zig` once and references it from any number of
emitters and listeners — the same authoring path scripts already
use. Plausible later add if authors ask for self-contained flow
event declarations; not in scope here.
