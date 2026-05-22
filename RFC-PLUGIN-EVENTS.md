# RFC: Plugin `Events` registry — a name-resolved, multi-listener event convention

**Status:** Proposed
**Repos affected:** `labelle-core`, `labelle-engine`, `labelle-box2d`,
`labelle-assembler`, `flow-codegen`
**Related:** RFC-FLOWS-JSONC (`.flow.jsonc` format, `OnEvent` entry),
flow-codegen #50 (graph → Zig codegen), #51 (assembler flow discovery),
flying-platform-labelle #208 (Plugin-Exported Controllers)

## Summary

Add a **`pub const Events`** comptime-discoverable struct to the plugin
declaration convention — parallel to the existing `Components`,
`Systems`, and `GizmoCategories` structs. An `Events` declaration names
each event a plugin emits and gives it a typed **payload struct**. The
assembler discovers `Events` from every plugin and exposes a
**name-keyed event registry**; flow-codegen's `OnEvent` then resolves an
event by *name* (`{"type":"OnEvent","name":"collision_begin"}`) and
derives the handler signature from the registry instead of from a
hand-written `params` list bound to a raw `?*const fn` slot.

This buys three things the v1 `OnEvent` lacks:

1. **One name, one source of truth.** The flow author writes a name; the
   payload type comes from the plugin. No hand-copied signature to drift.
2. **Multiple listeners per event.** A registry dispatches to every
   subscribed flow/script — today a `pub var on_collision_begin:
   ?*const fn(...)` slot holds exactly one handler, so a second flow
   binding the same callback silently clobbers the first.
3. **`game` access.** A registry-dispatched handler can receive `game`,
   so an event flow can read/write components — today a plugin callback
   carries neither `game` nor `entity`.

This RFC is a **design** proposal. It does not change `OnEvent`
semantics for already-shipped flows beyond a backward-compatible
superset (see Migration).

## Motivation

### v1 `OnEvent` hand-copies a signature onto a single-listener slot

`flow-codegen` `main` (commit `c6f29ef`) added `OnEvent`. A flow names a
plugin module, a raw callback variable, and the callback's parameter
signature, all hand-written
(`flow-codegen/src/flow_io.zig:60-66`):

```jsonc
"event": {
  "type": "OnEvent", "module": "box2d",
  "callback": "on_collision_begin",
  "params": [ {"name":"entity_a","type":"u32"}, {"name":"entity_b","type":"u32"} ]
}
```

`renderEventEntry` (`flow-codegen/src/codegen.zig:517-575`) emits a
`flowEvent` handler whose signature is `params` *verbatim* and a
`setup()` that does `__event_src.on_collision_begin = &flowEvent`. Three
limitations follow directly from that shape:

- **The signature is hand-copied.** `params` must match
  `labelle-box2d/src/root.zig:90`'s
  `?*const fn(entity_a: u32, entity_b: u32) void` exactly. If the plugin
  ever changes the callback, every flow that named it breaks — and
  nothing connects the two, so the break is a raw Zig type error at the
  generated assignment, far from the `.flow.jsonc` that caused it.
- **One listener per event.** `setup()` *assigns* the slot. Two
  `OnEvent` flows on `on_collision_begin` produce two `setup()`s; the
  script-runner calls both; the second wins. There is no diagnostic.
- **No `game`, no `entity`.** `renderEventEntry` rejects `GetComponent`
  / `SetField` (`anyNodeNeedsEntity`) and `Subflow` nodes — a plugin
  callback is `fn(u32,u32) void`, with nothing else in scope. An event
  flow cannot touch ECS state, which is most of what a flow is for.

### Plugins already have a declaration convention — events are the gap

A labelle plugin is a comptime-discoverable module. `labelle-box2d`
(`labelle-box2d/src/root.zig`) exports:

- `pub const Components` (`:27`) — auto-wired by
  `engine.ComponentRegistryWithPlugins`.
- `pub const Systems` (`:36`) — auto-dispatched by
  `engine.SystemRegistry`.
- `pub const GizmoCategories` (`:73`) — auto-discovered by the debug
  inspector.

The assembler discovers all three by `@hasDecl` over the plugin module
list (`labelle-assembler/src/main_zig.zig:2797-2856`;
`labelle-engine/scene/src/system.zig:29-247` — `SystemRegistry` walks
`@hasDecl(mod,"Systems")`, `gizmoCategories()` walks
`@hasDecl(mod,"GizmoCategories")`).

Events are the one plugin capability with **no** declaration struct.
They are loose `pub var ?*const fn` slots
(`labelle-box2d/src/root.zig:90-95`). Nothing discovers them, nothing
type-checks a binding, nothing prevents two writers. `Events` closes
that gap and makes events a first-class, registry-resolved plugin
export, exactly like components and systems.

## Non-goals

- **No runtime flow interpreter.** Flows stay codegen-to-Zig. The
  registry is a comptime construct; dispatch is comptime-resolved (see
  §4). The shipped game links generated Zig, not a flow file.
- **No new event *transport*.** This RFC does not change *how*
  `labelle-box2d` detects a collision (`processContacts`,
  `root.zig:493`). It changes how the *resulting event* is declared,
  discovered, and delivered.
- **No change to `Components` / `Systems` / `GizmoCategories`.** `Events`
  is a fourth peer struct, added alongside them.
- **Engine lifecycle events** (`OnCreate`/`OnUpdate`/`OnDestroy`) are
  unchanged — they are not plugin events.

## Design

### 1. Plugin `Events` declaration

A plugin declares the events it emits in a `pub const Events` struct.
Each declaration **is** the event's payload struct — its fields are the
event's data — and the declaration name is the event's **registry
name**.

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

Rationale for the shape (**resolves open question O1** — flat, no
`Payload` wrapper):

- **The event declaration is its payload type.** This matches the
  toolkit's three existing plugin conventions, which are all flat
  `pub const X = …`: `Components` (`pub const RigidBody = PhysicsBody;`),
  `Systems`, and `GizmoCategories`. `Events` is the fourth and stays
  consistent — no nested `pub const Payload` wrapper.
- **Flat does not forgo metadata.** A Zig struct holds fields *and*
  decls, reported separately by `@typeInfo` (`.fields` vs `.decls`).
  Documentation is a plain `///` doc comment on the declaration; a
  future marker (the O2 primary-entity field) is an additive
  `pub const primary_entity = "entity_a";` beside the payload fields —
  no wrapper, no migration. Editor-facing metadata (display name,
  category, tooltip — what Unity/Unreal attach to events, almost
  entirely for editor tooling) is the same shape: additive decls, owned
  by the labelle-gui flow editor (O6), not modelled by the registry now.
- **The handler parameters are the payload struct's fields** —
  `@typeInfo(EventType).@"struct".fields`. The v1 `params: []Param`
  list is recovered for free this way, and the struct passes by value
  to a dispatcher (§4) as one coherent unit that survives a field
  rename.
- **The declaration name is the event name.** `collision_begin`, not
  `on_collision_begin` — the `on_` prefix was a C-callback-slot
  convention; a registry name does not need it. It is a valid Zig
  identifier, so it doubles as a codegen symbol fragment with no
  sanitization.
- **Discovered by `@hasDecl`**, exactly like `Components`/`Systems`. A
  plugin with no `Events` struct is silently skipped — zero cost, no
  opt-in, same backward-compat property as the Controller discovery in
  flying-platform-labelle #208.

The plugin keeps emitting events from its own systems; it just routes
through the registry instead of a raw slot (see §6, Migration).

### 2. Assembler discovery + wiring

The assembler already builds `PluginSystems = engine.SystemRegistry(...)`
over the plugin module list
(`labelle-assembler/src/main_zig.zig:2839-2846`). It gains a parallel
**event registry** block:

```zig
const PluginEvents = engine.EventRegistry(.{
    @import("labelle-gfx"),
    @import("box2d"),
    // ...one entry per plugin, same list as PluginSystems
});
```

`engine.EventRegistry` (new, in `labelle-engine`, alongside
`SystemRegistry` in `labelle-engine/scene/src/system.zig`) walks the
module list with `@hasDecl(mod, "Events")`, exactly as
`gizmoCategories()` walks `GizmoCategories`
(`system.zig:213-247`). It produces:

- **A flat, name-keyed comptime lookup.** `EventRegistry.resolve("box2d.collision_begin")`
  → `{ module, event_name, Payload }`. Names are **plugin-qualified**
  (`box2d.collision_begin`) so two plugins may both export
  `collision_begin` without collision; a flow may also use the bare name
  when it is unambiguous across the discovered plugin set (a bare name
  matching two plugins is a load-time error,
  `error.AmbiguousEventName`).
- **A per-event subscription point** — the dispatcher of §4.
- **`event_count` / an event-name list** for the GUI editor and for
  flow-codegen to validate an `OnEvent` name against (the editor offers
  a dropdown rather than a free-text callback field).

A duplicate event *declaration* name within one plugin is already a Zig
compile error (duplicate decl). A duplicate plugin-qualified name across
plugins cannot occur — the plugin name is the prefix.

### 3. flow-codegen resolution

`OnEvent` gains a `name` form and `module`/`callback`/`params` become
derivable rather than required:

```jsonc
// new form — name-resolved
"event": { "type": "OnEvent", "name": "box2d.collision_begin" }
```

`flow_io.Event.OnEvent` (`flow-codegen/src/flow_io.zig:60-66`) becomes:

```zig
OnEvent: struct {
    /// Registry name of the event — plugin-qualified
    /// (`box2d.collision_begin`) or a bare name when unambiguous.
    name: ?[]const u8 = null,

    // ── legacy / v1 fields — all optional, see Migration ──
    module: ?[]const u8 = null,
    callback: ?[]const u8 = null,
    params: []Param = &.{},
},
```

`buildEvent` (`flow_io.zig:307-313`) accepts either: if `name` is
present it is the new form; if `module`+`callback` are present it is the
v1 form; both present, or neither, is `error.MalformedFlow`.

Codegen (`renderEventEntry`, `codegen.zig:517-575`):

- **New form.** The event name is resolved through the assembler's
  `EventRegistry` (the same name-keyed-registry pattern RFC-FLOWS-JSONC
  §5 uses for `Subflow`). The handler signature is derived from
  `Payload`'s fields — codegen reflects the struct rather than reading a
  hand-written `params` list. An unknown name is
  `error.UnknownEvent`, reported against the `.flow.jsonc` file.
- **Legacy form.** `renderEventEntry` keeps its current behaviour
  verbatim — emit a `flowEvent` matching `params`, assign `&flowEvent`
  to the raw slot. Unchanged code path.

Because the *only* on-disk difference is `name` vs
`module`+`callback`+`params`, and the registry-derived signature is the
same field set the v1 `params` spelled out by hand, the new form is a
**strict superset**: every v1 `OnEvent` flow has an equivalent new-form
flow with `params` dropped. flow-codegen ships a converter pass (as
RFC-FLOWS-JSONC shipped `.flow.zon`→`.flow.jsonc`) that rewrites legacy
`OnEvent` blocks once it can resolve `module`+`callback` to a registry
name (§7 phase 4).

### 4. Multi-listener dispatch

Today the plugin owns a single `?*const fn` slot and `setup()` assigns
it — the structural cause of the one-listener limit. The registry
inverts ownership: the **plugin emits into the registry**, and any
number of flows/scripts **subscribe**.

This is the problem `zig-utils`'s `HookDispatcher`
(`zig-utils/src/hook_dispatcher.zig`) already solves — a comptime,
zero-overhead dispatcher — and specifically what `MergeHooks`
(`hook_dispatcher.zig:125-200`) does: it fans one emitted event out to
*every* matching handler across multiple handler structs, in order, with
`inline for` and no runtime cost. That is exactly multi-listener
dispatch.

**Decision: build on `HookDispatcher`, do not fork it.** The plugin
`Events` registry should *generate a `HookDispatcher`/`MergeHooks`
instance*, not a parallel mechanism:

- One event = one `HookEnum` tag; the per-event `Payload` struct is that
  tag's variant in the `PayloadUnion`. `EventRegistry` synthesizes both
  the enum and the union from the discovered `Events` declarations.
- Each `OnEvent` flow's generated handler is a `pub fn <event_name>`
  in the flow's handler struct. The assembler collects every flow
  handler struct and feeds them to `MergeHooks` — the same fan-out
  `MergeHooks` already does for game+plugin hooks.
- The plugin emits with `PluginEvents.emit(.{ .collision_begin = .{...} })`
  in place of `if (on_collision_begin) |cb| cb(...)`
  (`labelle-box2d/src/root.zig:512`).

This keeps one dispatch mechanism in the toolkit and inherits its
comptime-resolution and "no handler is a no-op" properties for free.
`labelle-tasks` already emits through `HookDispatcher`; plugin events
joining it is consistent, not novel.

Dispatch order is settled by O3: all listeners run; the assembler emits
handler structs sorted by flow registry name (reproducible builds), but
the order is an unspecified contract — flows must not depend on it.

### 5. `game` / `entity` access

A v1 `OnEvent` handler is a bare `fn(u32,u32) void` — no `game`. With
registry dispatch, the dispatcher *owns the call site*, so it can pass
`game` in. Proposed handler signature for a new-form `OnEvent` flow:

```zig
// generated for a `box2d.collision_begin` flow
pub fn collision_begin(game: anytype, payload: box2d.Events.collision_begin) void {
    // payload.entity_a, payload.entity_b in scope
    // game in scope → GetComponent / SetField / Subflow now lowerable
}
```

Consequences:

- `renderEventEntry`'s rejection of `GetComponent`/`SetField`
  (`anyNodeNeedsEntity`, `codegen.zig:531`) and of `Subflow`
  (`codegen.zig:534-535`) is **lifted for new-form flows** — `game` is
  in scope, so entity-scoped nodes and subgraph calls lower exactly as
  they do for an `OnUpdate` flow. The legacy form keeps both rejections.
- **`entity` is not automatic.** A collision event has *two* entities;
  there is no single "the entity". A flow reads `payload.entity_a` /
  `payload.entity_b` explicitly via `Identifier`/`GetComponent`-on-a-pin
  nodes. Whether to also expose a convenience binding (e.g. an event may
  *mark* one payload field as the primary entity) is open question O2.
- The dispatcher passes `game` by the same `anytype` the engine threads
  everywhere (`Systems.tick(game: anytype, ...)`,
  `root.zig:45`); no new type plumbing.

### 6. Plugin emit-side change (`labelle-box2d`)

`labelle-box2d`'s `processContacts` / `processSensorEvents`
(`root.zig:493-569`) change from raw-slot calls to registry emits:

```zig
// before — root.zig:512
if (on_collision_begin) |cb| cb(entity_a, entity_b);

// after
game.events.emit(.{ .collision_begin = .{ .entity_a = entity_a, .entity_b = entity_b } });
```

The plugin no longer declares `pub var on_collision_begin` etc.; it
declares `pub const Events` (§1) and emits through the registry handle
the engine threads on `game` (parallel to `game.renderer`,
`root.zig:489`). See Migration for the deprecation window.

## Migration

Two independent migrations — the flow side and the plugin side — staged
so neither breaks current users mid-flight.

### Flow side (`OnEvent` JSONC)

- `OnEvent`'s `module`/`callback`/`params` become **optional**; `name`
  is **added** (§3). A v1 flow file parses and codegens unchanged.
- The legacy `renderEventEntry` path is kept verbatim through one
  release, then the converter (below) rewrites in-tree flows and the
  legacy path is dropped — the same hard-cut RFC-FLOWS-JSONC used for
  `.flow.zon`, justified the same way (very few files exist).
- **Converter.** A `flow-codegen` pass: for a legacy `OnEvent`, look up
  `module`+`callback` against the `EventRegistry`; on a unique match,
  rewrite to `{"type":"OnEvent","name":"<plugin>.<event>"}` and drop
  `params`. A `callback` with no registry match (a plugin not yet
  migrated) is left as-is and warned.

### Plugin side (`labelle-box2d` callback vars)

`labelle-box2d`'s `on_collision_*` / `on_sensor_*` `pub var`s
(`root.zig:90-95`) cannot vanish without breaking hand-written games
that assign them today. Phased:

1. **Add `pub const Events`** (§1) alongside the existing `pub var`s.
   The plugin emits to *both* the registry and the legacy slot for one
   release — a legacy assignment still fires, a new subscriber also
   fires. No breakage.
2. **Deprecate the `pub var`s** — doc-comment them deprecated; the
   migration guide points at `Events`.
3. **Remove the `pub var`s** in a later minor — the dual-emit shim in
   `processContacts` collapses to a single `events.emit`.

A hand-written (non-flow) game subscribes to the new registry through a
small engine API (`game.events.subscribe(...)` or a handler struct fed
to the same `MergeHooks` the assembler uses) — design detail deferred to
the engine work item, not blocking this RFC.

## Open questions

1. ~~**`Events` declaration shape.**~~ **Resolved — flat form (see
   §1).** The event declaration *is* its payload struct
   (`pub const collision_begin = struct { entity_a: u32, entity_b: u32 };`),
   matching the flat `Components`/`Systems`/`GizmoCategories`
   conventions. The "loses a home for metadata" concern does not hold: a
   Zig struct carries fields *and* decls separately, so documentation is
   a `///` doc comment and any future metadata (the O2 marker, editor
   hints) is an additive `pub const` decl beside the payload fields — no
   nested `Payload` wrapper needed. Prior art: Unreal and Unity both
   attach event metadata, but almost entirely for editor tooling
   (categories, tooltips, display names), which here is a labelle-gui
   concern (O6), not a registry one.
2. **Primary-entity convention.** Should an event payload be able to
   *mark* one field as "the entity" so an event flow gets an automatic
   `entity` binding like `OnCreate` does? Useful for single-entity
   events (a future `box2d.body_sleep`); meaningless for symmetric
   two-entity events (`collision_begin`). Possibly an optional
   `pub const primary_entity = "entity_a"` decl.
3. ~~**Dispatch order across flows.**~~ **Resolved — no priority field;
   "all listeners run, order deterministic-but-unspecified."**
   `MergeHooks.emit` `inline for`s the handler structs and calls every
   one that declares the hook (`hook_dispatcher.zig:148-163`), so all
   listeners always run. The order is the order the assembler emits
   those handler structs — **the assembler must sort flow handlers by
   flow registry name** so builds are reproducible. As an author-facing
   contract the order is **unspecified — flows must not depend on it**:
   event reactions are independent side effects (count / sound /
   particle); a flow that needs another flow to have run first should
   express that explicitly (a `Subflow` call, or a derived event), not
   rely on a hidden race. This matches ECS systems today, which run in
   `SystemRegistry` order with no per-system priority. An explicit
   `priority` is deliberately kept *off* the notification flavor —
   those reactions are independent. Priority **is** introduced, but
   scoped to the **consumable** event flavor (O4, resolved), where
   ordering decides which handler consumes the event first.
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
     **stops propagation** — later listeners are skipped.

   The flavor is an additive decl on the flat event struct (O1),
   defaulting to notification:
   `pub const click = struct { x: f32, y: f32, pub const consumable = true; };`.
   The consumable flavor needs a return-aware dispatch path — a
   `bool`-returning handler and an early `break` — which `MergeHooks`
   (`void`, no break) lacks; that is a `zig-utils` `HookDispatcher`
   addition. **Scope:** the notification flavor is v1; the consumable
   flavor (the dispatcher change + the `OnEvent` `priority` field) is a
   defined follow-up phase, sequenced after the notification registry
   ships. Prior art: browsers (`stopPropagation`), Unity (`Event.Use`),
   and Unreal (input "consumed") all separate fan-out notifications from
   consumable input this way.
5. **Non-plugin event sources.** Could a *game script* (not a plugin)
   declare `pub const Events` and emit its own events for flows to
   listen to? The discovery is the same `@hasDecl` walk; the only
   question is whether the assembler scans script modules for `Events`
   too. Plausible follow-up, not v1.
6. **Editor support.** The GUI flow editor should offer the discovered
   event names as a dropdown (§2 exposes the list) instead of the v1
   free-text `module`+`callback` fields. Tracked with the
   `labelle-gui` `flow_io.zig` work, not this RFC.

## Phased implementation plan

Ordered so each phase compiles and ships independently.

1. **`labelle-core` / `labelle-engine`** — define the `Events`
   declaration convention (the documented struct shape) and implement
   `engine.EventRegistry`: `@hasDecl`-walk plugin modules, synthesize the
   `HookEnum` + `PayloadUnion`, build on `HookDispatcher`/`MergeHooks`.
   Thread an `events` handle onto `game`.
2. **`labelle-box2d`** — add `pub const Events` (§1); make
   `processContacts`/`processSensorEvents` dual-emit (registry + legacy
   slot). No removal yet — Migration phase 1.
3. **`labelle-assembler`** — emit the `PluginEvents = engine.EventRegistry(.{...})`
   block next to `PluginSystems`
   (`main_zig.zig:2839`); collect `OnEvent` flow handler structs and
   feed them to `MergeHooks`; expose the event-name list.
4. **`flow-codegen`** — `OnEvent` gains `name`; `module`/`callback`/
   `params` go optional (`flow_io.zig`); `buildEvent` accepts both
   forms; `renderEventEntry` resolves the new form through the registry,
   derives the signature from `Payload`, threads `game`, and lifts the
   entity/`Subflow` rejections for new-form flows. Ship the legacy→name
   converter pass.
5. **`labelle-gui`** — `flow_io.zig` reads/writes the `name` form; the
   editor offers the discovered event-name dropdown.
6. **Cleanup** — convert in-tree flows to the `name` form; deprecate
   then remove `labelle-box2d`'s `pub var` callback slots (Migration
   phases 2–3); drop the legacy `renderEventEntry` path.
7. **Consumable event flavor** (follow-up, O4) — add return-aware
   dispatch to `zig-utils` `HookDispatcher` (a `bool`-returning handler
   + early `break`); let a plugin event opt in via
   `pub const consumable = true`; add the `OnEvent` `priority` field and
   its registry sort. Sequenced after phases 1–6; the notification
   registry does not depend on it.

## Rejected alternatives

### A separate, events-only dispatcher

Build a bespoke event dispatcher for plugin events rather than reusing
`HookDispatcher`. Rejected: `HookDispatcher`/`MergeHooks`
(`zig-utils/src/hook_dispatcher.zig`) already is a comptime,
zero-overhead, multi-handler fan-out dispatcher, and `labelle-tasks`
already emits through it. A second mechanism would be two things to
learn, two things to maintain, and divergent semantics for "an event
fired and N things listened" — for no gain. §4 builds on it instead.

### Keep raw `?*const fn` slots, allow a slice of them

Make `on_collision_begin` a `[]const *const fn(...)` instead of a single
`?*const fn(...)`, so multiple flows can append. Rejected: it fixes only
the one-listener symptom and none of the rest — the signature is still
hand-copied, there is still no name resolution, no `game`, no
discovery, no editor dropdown. It also pushes registration order and
storage onto every plugin by hand. The registry solves the whole set.

### Flow names the raw callback, codegen wraps it (no plugin change)

Keep `labelle-box2d` exactly as-is; have flow-codegen synthesize a
multiplexer that owns the slot and fans out. Rejected: the multiplexer
would have to live *somewhere* with a stable address the plugin's
`?*const fn` can point at, and be shared across all flows for that
event — which is the registry, just built bottom-up and undiscoverable.
And it still cannot give the handler `game`, because the plugin
callback's signature (`root.zig:90`) has no room for it. The plugin
must participate; §1 makes that participation a clean, conventional
declaration rather than an ad-hoc shim.
