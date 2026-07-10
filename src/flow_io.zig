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
//!
//! ## Module layout (flow-codegen#40)
//!
//! This file is the slim umbrella over the `flow_io/` package: it
//! re-exports the public model types and parse/render entry points.
//! Implementation lives in:
//!   - `flow_io/model.zig`    — the typed structs/enums + `ParseError`.
//!   - `flow_io/parse.zig`    — JSONC → typed `Flow` (load/parse).
//!   - `flow_io/validate.zig` — structural/semantic validation pass.
//!   - `flow_io/write.zig`    — typed `Flow` → `.flow.jsonc` (render/save).

const std = @import("std");

const model = @import("flow_io/model.zig");
const parse = @import("flow_io/parse.zig");
const write = @import("flow_io/write.zig");

// ---------------------------------------------------------------------
// Model types (flow_io/model.zig)
// ---------------------------------------------------------------------
pub const Event = model.Event;
pub const BinOpKind = model.BinOpKind;
pub const CompareKind = model.CompareKind;
pub const LogicKind = model.LogicKind;
pub const Pos = model.Pos;
pub const Literal = model.Literal;
pub const Param = model.Param;
pub const Binding = model.Binding;
pub const NodeKind = model.NodeKind;
pub const Node = model.Node;
pub const PinRef = model.PinRef;
pub const Edge = model.Edge;
pub const Link = model.Link;
pub const ExecEdge = model.ExecEdge;
pub const Variable = model.Variable;
pub const Collection = model.Collection;
pub const Flow = model.Flow;
pub const LoadedFlow = model.LoadedFlow;
pub const ParseError = model.ParseError;

// ---------------------------------------------------------------------
// Parse / load entry points (flow_io/parse.zig)
// ---------------------------------------------------------------------
pub const loadFromFile = parse.loadFromFile;
pub const parseFlow = parse.parseFlow;
pub const parseFlowNamed = parse.parseFlowNamed;
pub const displayNameFromPath = parse.displayNameFromPath;

// ---------------------------------------------------------------------
// Render / save entry points (flow_io/write.zig)
// ---------------------------------------------------------------------
pub const renderFlowJsonc = write.renderFlowJsonc;
pub const saveFlow = write.saveFlow;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(model);
    std.testing.refAllDecls(parse);
    std.testing.refAllDecls(write);
    std.testing.refAllDecls(@import("flow_io/validate.zig"));
}
