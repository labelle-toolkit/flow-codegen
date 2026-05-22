# RFC: Flows as `.flow.jsonc` — a composable flow-graph format

**Status:** Accepted
**Repos affected:** `flow-codegen`, `labelle-gui`, `labelle-assembler`
**Related:** RFC #560 (unify scenes and prefabs), #561 (registry scan),
#562 (override merge rules), #569 (shared tree-walker / cycle detection),
#55 (subgraphs / Bolt-style macros), #51 (assembler flow discovery),
#50 (graph → Zig codegen), #44 (pin type-system fidelity)

## Summary

Move flow graphs from `.flow.zon` to **`.flow.jsonc`**, flatten the node
schema, and make subgraph composition work through **named registry
references** — the same mechanism RFC #560 gave scenes and prefabs —
instead of structural nesting or textual file insertion.

Three coupled decisions, already agreed:

1. **Format** — `.flow.jsonc` (JSONC), replacing `.flow.zon`.
2. **Schema** — a flat `nodes` + `edges` graph; no structurally nested
   subgraphs.
3. **Composition** — a subgraph is a *node that references another flow
   by name*, resolved from a flat name-keyed registry. The referenced
   flow publishes a named **parameter** interface; the reference binds
   those parameters by name. Load-time cycle detection.

## Motivation

### ZON has no reference idiom

`.flow.zon` today is an anonymous-struct tree:

```zig
.{
    .event = .{ .OnCreate = .{ .arg_entity = "entity" } },
    .nodes = .{
        .{ .id = 3, .pos = .{ 0, 0 }, .kind = .{ .BinOp = .{ .op = .add } } },
    },
    .links = .{
        .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 3, .pin = "a" } },
    },
}
```

Two problems:

- **Per-node nesting.** `.kind = .{ .BinOp = .{ .op = .add } }` wraps
  every node's data in a tagged-union layer. A node is conceptually
  flat — a type plus parameters — but the format makes it two levels
  deep.
- **No composition.** ZON has no `@import` and no reference idiom. To
  reuse a flow inside another flow you would either inline its whole
  node/edge tree (the nesting problem, multiplied) or hand-roll a
  textual include — fragile, and it breaks node-id uniqueness.

### Flows are the lone ZON content format

RFC #560 already moved scenes and prefabs to `.jsonc`. `project.labelle`
stays ZON because it is *project/build config*. Flows are
*editor-authored content*, like scenes — they belong on the content
side of that line. Keeping them ZON makes flows the odd one out and
denies them the #560 machinery.

### The #560 machinery is exactly what composition needs

RFC #560 built — and #573/#574/#576/#577 implemented — a flat
name-keyed registry, a reference resolver, deep-merge `overrides`
(RFC #562), and a shared tree-walker with **cycle detection** (#569).
A composable flow format needs every one of those, and most of all the
cycle detection: a flow that transitively references itself is an
infinite codegen. Reusing #569 means recursive composition is rejected
at load time with the full chain (`A -> B -> A`) for free.

## Non-goals

- **No runtime flow interpreter.** Flows remain codegen-to-Zig:
  `.flow.jsonc` → flow-codegen → `.zig` → compiled. The shipped game
  never parses a flow file. This RFC does not change that.
- **No change to the node catalog** (#53) or node execution semantics.
- **No change to `project.labelle`** — it stays ZON.

## Why the format choice is low-stakes at runtime

Because flows are build-time only, the on-disk format is read by exactly
two consumers — flow-codegen (the build-time generator) and the GUI
editor (`flow_io.zig`). The shipped game links the *generated Zig*, not
the flow file. So ZON's "parses natively at comptime" property buys
nothing here, and the choice is purely about authoring, tooling, diff
quality, and composition. All of those point to JSONC.

## Design

### 1. Format — `.flow.jsonc`

- File extension `.flow.jsonc`.
- Parsed with the engine's existing JSONC parser (comments, trailing
  commas) — the same one scenes and prefabs use.
- `.flow.zon` is retired (see Migration).

### 2. Schema — flat `nodes` + `edges`

```jsonc
{
  // Registry key — see §5. Optional; defaults to the filename basename.
  "name": "enemy_tick",

  // Entry point. One event per flow (unchanged concept).
  "event": { "type": "OnCreate", "arg_entity": "entity" },

  "nodes": [
    // type + params, flat — no tagged-union wrapper.
    { "id": 1, "type": "GetComponent", "component": "Position", "pos": [0, 0] },
    { "id": 2, "type": "Literal",      "value": "1.0",          "pos": [0, 0] },
    { "id": 3, "type": "BinOp",        "op": "add",             "pos": [0, 0] },
    { "id": 4, "type": "SetField",     "target": "Position.x",  "pos": [0, 0] }
  ],

  "edges": [
    { "from": { "node": 1, "pin": "x" },      "to": { "node": 3, "pin": "a" } },
    { "from": { "node": 2, "pin": "value" },  "to": { "node": 3, "pin": "b" } },
    { "from": { "node": 3, "pin": "result" }, "to": { "node": 4, "pin": "value" } }
  ]
}
```

Changes from `.flow.zon`:

- `kind: { BinOp: { op } }` → `"type": "BinOp", "op": "add"` — the
  per-node nesting layer is gone; a node is one flat object.
- `links` → `edges` (naming only; same `from`/`to` `{node, pin}` shape).
- New optional top-level `"name"` (registry key).
- New optional top-level `"params"` — the subgraph parameter interface
  (§3).
- The graph is **flat**: every node lives in the one `nodes` array.
  There is no nested-subgraph node shape. Composition is §3.

### 3. Composition — subgraph references

A subgraph publishes an explicit, named **parameter interface** — like a
function signature — and a caller binds those parameters by name. The
subgraph's inner node layout stays private.

#### A reusable flow declares `params`

A flow meant to be reused declares an optional top-level `"params"`
list. Each parameter has a name, a type, and a default:

```jsonc
// combat_subgraph.flow.jsonc
{
  "name": "combat_subgraph",
  "params": [
    { "name": "damage", "type": "f32", "default": "10.0" }
  ],
  // A subgraph's entry point is a call, not a lifecycle event.
  "event": { "type": "OnCall" },
  "nodes": [
    // a Param node yields a declared parameter's value as a pin output
    { "id": 2, "type": "Param", "param": "damage", "pos": [0, 0] },
    ...
  ],
  "edges": [ ... ]
}
```

The new **`Param`** node type reads a declared parameter and exposes its
value as a pin output, so inner nodes wire to it like any other source.
A `Param` node naming a parameter the flow does not declare is a
load-time error.

#### A `Subflow` node references and binds

A subgraph is an ordinary node whose `type` is `"Subflow"`:

```jsonc
// enemy_tick.flow.jsonc — the call site
{
  "id": 7,
  "type": "Subflow",
  "flow": "combat_subgraph",          // effective name in the flow registry
  "overrides": { "damage": "25" },     // bind parameters by name
  "pos": [240, 60]
}
```

- **Resolution.** `"flow"` is looked up in the flat name-keyed flow
  registry (§5), via the #560 resolver pointed at the flow registry.
- **Overrides = named-parameter binding.** Each `"overrides"` key is a
  parameter *name* declared in the referenced flow's `params`. The value
  binds that parameter for this call site; an omitted parameter keeps
  its declared `default`. This is **not** RFC #562's structural
  deep-merge — it is a strict, flat, named bind:
  - an `overrides` key that is not a declared parameter is a load-time
    error (`error.UnknownFlowParam`);
  - the value is type-checked against the parameter's declared `type`.
- **Pins.** The referenced flow's `event` inputs and its terminal
  outputs become the `Subflow` node's pins, so it wires into `edges`
  like any other node. Exact pin-projection rule is an open question
  (see below).
- **No id collisions.** Because the reference is by *name*, not textual
  insertion, the referenced flow keeps its own `id` space. Ids are only
  unique within a single file.

Why named parameters and not inner-node overrides: node ids are
file-local and editor-assigned, so a caller patching an inner node by id
would break silently the moment the subgraph is rearranged. A declared
`params` list is a stable, public contract — the subgraph author chooses
what is tunable. See Rejected alternatives.

### 4. Cycle detection

A `Subflow` reference graph is walked by the **#569 shared
tree-walker**. A flow that references itself directly or transitively is
a **load-time / codegen error**, reported with the full chain:

```
error: flow reference cycle: enemy_tick -> combat_subgraph -> enemy_tick
```

This is mandatory, not optional — without it a recursive `Subflow`
reference is an unbounded codegen. The walker already does exactly this
for prefab references; flow-codegen and the GUI both gate on it.

### 5. Registry & naming

- **Effective name** = the top-level `"name"` field if present, else the
  filename basename without `.flow.jsonc` (RFC #561 rule).
- Flows are discovered by recursively scanning `scripts/flows/**` for
  `*.flow.jsonc` — the #561 eager scan, extended to the flow extension.
- **Separate namespace.** Flows are keyed in their own registry map,
  distinct from the prefab/scene registry. A flow and a prefab may share
  a name; references are kind-tagged (`"flow"` vs `"prefab"`), so there
  is no cross-talk. The *scan and resolver machinery* is shared; the
  *map* is not.
- A duplicate effective name across two flow files is a load-time error
  (`error.DuplicateFlowName`), mirroring `DuplicatePrefabName`.

### 6. Codegen

flow-codegen's `renderFlowZig` is updated to:

1. Parse `.flow.jsonc` instead of `.flow.zon`.
2. Resolve `Subflow` references through the flow registry; run the
   cycle check first.
3. Emit each referenced flow as its **own Zig function** — each declared
   `param` becomes a function parameter, a `Param` node reads it. A
   `Subflow` node becomes a *call* to that function; the `overrides`
   bindings are the call arguments. This keeps generated Zig small and
   matches the "flows are just Zig scripts that compile" model — a
   subgraph compiles once, not once per reference site.

(Inlining per reference is a fallback — see open questions.)

## Migration

The blast radius is small — only a handful of `.flow.zon` files exist
today (the `flows-smoke` example plus a couple of fixtures).

- **Converter.** A one-shot `.flow.zon` → `.flow.jsonc` converter
  (script or a `flow-codegen` subcommand): mechanical, since the schema
  maps 1:1 apart from the `kind`-flatten and `links`→`edges` rename.
- **`flow_io.zig`** (labelle-gui) — reader/writer switches to JSONC.
- **flow-codegen** — parser switches to JSONC; `components_import_path`
  logic is unaffected.
- **labelle-assembler** — flow discovery (#51) globs `*.flow.jsonc`.
- **Cut-over.** Given how few files exist, a **hard cut** (convert all
  in-tree files in one PR, drop `.flow.zon` support) is cleaner than a
  deprecation window. No legacy-format reader to carry.

## Open questions

1. **Subgraph codegen — call vs inline.** The Model-B parameter
   interface (§3) makes call-style the natural lowering: each subgraph
   is its own Zig function, each declared `param` a function parameter.
   This is the design §6 assumes. Inlining is kept only as a possible
   fallback for a future `param` that must be comptime-only.
2. **Pin projection across a reference.** Exactly which of a referenced
   flow's `event` inputs and terminal outputs surface as the `Subflow`
   node's pins, and how they are named. Ties into #44 (strict vs
   duck-typed pins).
3. **Editor round-trip.** The GUI must write `.flow.jsonc` that is
   stable under re-save (key order, formatting) so diffs stay small —
   the same concern `project.labelle` pass-through solved for ZON.

## Rejected alternatives

### Overrides that reach inner nodes by id (Model A)

`overrides` keyed by inner node id — `{ "node:5": { "value": "25" } }`,
deep-merged per RFC #562. Rejected: node ids are file-local and
editor-assigned, an implementation detail of how the subgraph was drawn.
A caller pinned to `node:5` breaks silently — wrong value, no error —
the moment the subgraph is rearranged, and it leaks the subgraph's
internal layout to every call site. The prefab-override analogy does not
carry: prefab overrides (RFC #562) key by *component name*, which is
stable and public; node ids are neither. Model B's declared `params` are
the stable public contract Model A lacks.

### No parameterization in v1 (Model C)

Ship `Subflow` references with no `overrides` — a subgraph used exactly
as authored. Rejected as the v1 scope: it undershoots the goal. Reusing
one subgraph with different values would force duplicating the whole
file — the duplication this RFC exists to remove. `params` could be
added backward-compatibly later, but a composition format with no
parameterization is not worth shipping as a milestone.

## Rollout

1. This RFC accepted → tracking issue with sub-tickets.
2. `flow-codegen`: JSONC parser + flat schema + `params`/`Param` +
   `Subflow` resolution + cycle check + call-style codegen.
3. `labelle-gui`: `flow_io.zig` JSONC reader/writer; the editor gains
   `Subflow` and `Param` nodes and a subgraph-`params` editor.
4. `labelle-assembler`: `*.flow.jsonc` discovery.
5. Converter + convert all in-tree `.flow.zon` files; drop `.flow.zon`.
