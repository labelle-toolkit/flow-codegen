# RFC: Flows as `.flow.jsonc` — a composable flow-graph format

**Status:** Proposed
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
   flow publishes a named **parameter** interface; each parameter is an
   input pin on the reference node — wired from upstream graph data, or
   given a literal `binding`, or left to its declared default. Load-time
   cycle detection.

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
name-keyed registry, a reference resolver, and a shared tree-walker with
**cycle detection** (#569). A composable flow format reuses the
registry, the resolver, and most of all the cycle detection: a flow that
transitively references itself is an infinite codegen, and #569 rejects
it at load time with the full chain (`A -> B -> A`) for free. (Flows do
*not* reuse #562's structural deep-merge — parameter binding is a
simpler, flat, named bind; see §3.)

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
    { "id": 2, "type": "Literal",      "value": 1.0,            "pos": [0, 0] },
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
- New optional top-level `"params"` — the subgraph input interface (§3).
- New node types `Param`, `Output`, and `Subflow` — the composition
  interface (§3).
- The graph is **flat**: every node lives in the one `nodes` array.
  There is no nested-subgraph node shape. Composition is §3.

### 3. Composition — subgraph references

A subgraph publishes an explicit, named interface — like a function
signature. Its declared `params` are its **input pins**; its `Output`
nodes are its **output pins**. A reference node projects exactly those
pins, so it wires into `edges` like any other node. The subgraph's inner
layout stays private.

#### A reusable flow declares `params` and `Output`s

```jsonc
// combat_subgraph.flow.jsonc
{
  "name": "combat_subgraph",
  // Inputs. `type` is a Zig type name; `default` is a JSON-native
  // literal of that type.
  "params": [
    { "name": "damage", "type": "f32", "default": 10.0 }
  ],
  // A subgraph's entry point is a call, not a lifecycle event.
  "event": { "type": "OnCall" },
  "nodes": [
    // a Param node yields a declared parameter's value as a pin output
    { "id": 2, "type": "Param",  "param": "damage", "pos": [0, 0] },
    // ...
    // an Output node names one of the subgraph's result pins
    { "id": 9, "type": "Output", "name": "dealt",   "pos": [0, 0] }
  ],
  "edges": [ /* ... */ ]
}
```

Two node types make the interface concrete:

- **`Param`** reads a declared parameter and exposes its value as a pin
  output, so inner nodes wire to it like any other source. A `Param`
  node naming an undeclared parameter is a load-time error.
- **`Output`** consumes a value on a pin input and names it as one of
  the subgraph's results. The set of `Output` node names *is* the
  subgraph's output-pin set; duplicate names are a load-time error.

#### A `Subflow` node references and binds

A subgraph is an ordinary node whose `type` is `"Subflow"`. Its pins are
**projected directly** from the referenced flow's interface — one input
pin per declared `param`, one output pin per `Output` node:

```jsonc
// enemy_tick.flow.jsonc — the call site
{
  "id": 7,
  "type": "Subflow",
  "flow": "combat_subgraph",       // effective name in the flow registry
  "bindings": { "damage": 25.0 },  // literal value for an unwired param pin
  "pos": [240, 60]
}
```

Each `param` input pin gets its value in this precedence order:

1. **Wired** — an `edge` into that pin from an upstream node. This is
   how dynamic, graph-computed values reach a parameter.
2. **`bindings`** — a JSON-native literal for a pin left unwired. Each
   key is a parameter *name*; an unknown key is a load-time error
   (`error.UnknownFlowParam`), and the value is type-checked against the
   parameter's declared `type`.
3. **`default`** — a param pin that is neither wired nor bound uses its
   declared `default`. A param with no `default`, left unwired and
   unbound, is a load-time error.

`bindings` is thus only the static-literal case of supplying a param
pin — **not** a structural merge. It is deliberately not RFC #562's
`overrides`: no deep-merge, no `null`-removal, no nesting.

- **Resolution.** `"flow"` is looked up in the flat name-keyed flow
  registry (§5), via the #560 resolver pointed at the flow registry.
- **No id collisions.** The reference is by *name*, not textual
  insertion — the referenced flow keeps its own `id` space. Ids are
  unique only within a single file.

Why a declared interface and not inner-node overrides: node ids are
file-local and editor-assigned, so a caller patching an inner node by id
would break silently the moment the subgraph is rearranged. `params` and
`Output` nodes are a stable, public contract — the subgraph author
chooses what is tunable and what is exposed. See Rejected alternatives.

### 4. Cycle detection

A `Subflow` reference graph is walked by the **#569 shared
tree-walker**. A flow that references itself directly or transitively is
a **load-time / codegen error**, reported with the full chain:

```
error: flow reference cycle: enemy_tick -> combat_subgraph -> enemy_tick
```

This is mandatory, not optional — without it a recursive `Subflow`
reference is an unbounded codegen.

The check runs over every `Subflow` reference reachable from each flow
in the registry, so a cycle is caught regardless of which flow is the
build entry point. flow-codegen and the GUI run the **same** walker and
emit the **same** chain diagnostic — the editor flags a cycle before a
build is ever attempted.

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
3. Emit each referenced flow as its **own Zig function**: each declared
   `param` is a function parameter; a `Param` node reads it; the
   `Output` nodes become the function's return — a single value, or a
   struct of named results when there is more than one. The function
   symbol is derived deterministically from the flow's effective name
   (sanitized to a valid Zig identifier); effective names are already
   unique per §5, so symbols do not collide.
4. Lower each `Subflow` node to a *call* of that function. Every `param`
   argument is supplied explicitly at the call site — the wired pin's
   expression, else the `bindings` literal, else the declared `default`.
   Because the call site always passes a concrete value, the generated
   function needs no Zig-level default parameters.

A subgraph thus compiles **once** and is called from each reference
site, which keeps generated Zig small and matches the "flows are just
Zig scripts that compile" model. (Inlining per reference is a fallback —
see open questions.)

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

1. **Subgraph codegen — call vs inline.** The parameter interface (§3)
   makes call-style the natural lowering, and §6 specifies it. Inlining
   is kept only as a possible fallback for a future `param` that must be
   comptime-only.
2. **Param type vocabulary.** Which Zig types a `param` may declare —
   primitives only, or component/struct types too — and how a non-scalar
   `default` is written as a JSON-native literal. Ties into #44 (pin
   type-system fidelity).
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

Ship `Subflow` references with no parameters at all — a subgraph used
exactly as authored, with no `params`, `bindings`, or `Output` results.
Rejected as the v1 scope: it undershoots the goal. Reusing
one subgraph with different values would force duplicating the whole
file — the duplication this RFC exists to remove. `params` could be
added backward-compatibly later, but a composition format with no
parameterization is not worth shipping as a milestone.

## Rollout

1. This RFC accepted → tracking issue with sub-tickets.
2. `flow-codegen`: JSONC parser + flat schema + `params`/`Param` +
   `Subflow` resolution + cycle check + call-style codegen.
3. `labelle-gui`: `flow_io.zig` JSONC reader/writer; the editor gains
   `Subflow`, `Param`, and `Output` nodes and a subgraph-`params` editor.
4. `labelle-assembler`: `*.flow.jsonc` discovery.
5. Converter + convert all in-tree `.flow.zon` files; drop `.flow.zon`.
