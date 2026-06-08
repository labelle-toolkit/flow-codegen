//! Forward codegen for the Flow editor (`.flow.jsonc` → Zig source).
//!
//! `renderFlowZig` turns a parsed `flow_io.Flow` into a complete `.zig`
//! file: imports + a `pub fn` for the flow's `Event`, plus — when the
//! flow (transitively) references subgraphs — one `fn` per referenced
//! flow. The assembler calls this at `zig build generate` time.
//!
//! ## Pipeline
//!
//! 1. Index nodes by id and build the consumer→producer pin map from
//!    the edge list.
//! 2. Topologically sort the nodes (Kahn's algorithm) so a node's
//!    inputs are always defined before the node itself emits.
//! 3. For each node, in topo order, emit the node's Zig template with
//!    input pins resolved to the producing node's variable, a `param`
//!    argument, a `binding` literal, or a per-kind default.
//!
//! ## Subgraph composition (RFC-FLOWS-JSONC.md §3, §6)
//!
//! A `Subflow` node references another flow by name. `renderFlowFile`
//! resolves those references through a `FlowRegistry`, runs a
//! reference-cycle check (RFC §4 — reported with the full chain), and
//! emits **call-style** code (RFC §6):
//!
//! - each referenced flow becomes its own `fn`, named by a
//!   deterministic symbol derived from its effective name;
//! - each declared `param` is a function parameter; a `Param` node
//!   reads it;
//! - `Output` nodes become the function's return — a single value,
//!   a struct of named results when there is more than one, or `void`
//!   when the flow declares none;
//! - a `Subflow` node lowers to a *call* of that function, every
//!   argument supplied explicitly (wired pin → `binding` literal →
//!   declared `default`).
//!
//! ## Preview pulse (folded from former issue #90)
//!
//! Each emitted node body is preceded by an `emitNodeEntered` pulse
//! guarded by `if (game.preview)` so production builds pay nothing.
//!
//! ## Pin variables
//!
//! Pin values live in `n<node_id>_<pin>` locals. `GetComponent`
//! produces a single `n<id>_value` binding and downstream consumers
//! may ask for any pin name (treated as a field access).
//!
//! ## Module layout
//!
//! The implementation is split by concern across `src/codegen/*.zig`;
//! this file is the slim umbrella that re-exports the public API
//! (`renderFlowZig` / `renderFlowFile`, `Options`, the `*Registry`
//! types, `detectReferenceCycle*`, `wrapEdgeWithCoercion`,
//! `sanitizeSymbol`). The split modules `@import` each other by relative
//! path; the module surface is unchanged.

const errors = @import("codegen/errors.zig");
const registries = @import("codegen/registries.zig");
const cycles = @import("codegen/cycles.zig");
const entry = @import("codegen/entry.zig");
const pins = @import("codegen/pins.zig");

// --- Errors ----------------------------------------------------------
pub const CodegenError = errors.CodegenError;

// --- Caller-facing registries + options ------------------------------
pub const Options = registries.Options;
pub const FlowRegistry = registries.FlowRegistry;
pub const CustomNodeEntry = registries.CustomNodeEntry;
pub const CustomNodeRegistry = registries.CustomNodeRegistry;
pub const CoercionEntry = registries.CoercionEntry;
pub const WireFit = registries.WireFit;
pub const CoercionRegistry = registries.CoercionRegistry;
pub const wrapEdgeWithCoercion = registries.wrapEdgeWithCoercion;

// --- Cycle detection over Subflow references (RFC §4) ----------------
pub const detectReferenceCycle = cycles.detectReferenceCycle;
pub const detectReferenceCycleFlow = cycles.detectReferenceCycleFlow;

// --- Public entry points ---------------------------------------------
pub const renderFlowZig = entry.renderFlowZig;
pub const renderFlowFile = entry.renderFlowFile;

// --- Shared identifier helper (consumed by the assembler / tests) ----
pub const sanitizeSymbol = pins.sanitizeSymbol;
