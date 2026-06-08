//! Codegen-side error set, shared across the `codegen/*` concern modules.

/// Codegen-side failure modes.
pub const CodegenError = error{
    /// Topo sort couldn't make progress — the graph contains a cycle.
    CycleDetected,
    /// A required input pin has no incoming edge and no default.
    DanglingPin,
    /// An edge names a `to.pin` that isn't an input pin on the
    /// consumer node.
    UnknownPin,
    /// A `GetComponent` / `SetField` references a namespaced type.
    NamespacedComponentType,
    /// A `Subflow` node references a flow name not in the registry.
    UnknownFlowRef,
    /// A `Subflow` reference graph contains a cycle (RFC §4).
    FlowReferenceCycle,
    /// A `Subflow` `binding` names a param the referenced flow does
    /// not declare (RFC §3 — `error.UnknownFlowParam`).
    UnknownFlowParam,
    /// A referenced flow's `param` pin is neither wired, bound, nor
    /// has a declared `default` (RFC §3 precedence rule 3).
    MissingFlowArg,
    /// Two distinct effective flow names sanitize to the same Zig
    /// identifier (e.g. `a-b` and `a_b` both → `a_b`). RFC §5 keeps
    /// effective names unique, but `sanitizeSymbol` is lossy, so a
    /// collision would emit two `fn` definitions with the same name.
    SymbolCollision,
    /// A flow's effective name sanitizes to the bare `_` (an empty or
    /// all-non-identifier name). Zig reserves `_` as the discard
    /// identifier and rejects it as a `fn` name, so such a subgraph
    /// would emit `fn _(...)` and fail to compile.
    InvalidFlowName,
    /// A flow declares a `param` whose sanitized name collides with
    /// another param or with a fixed `fn` parameter (`game`, or the
    /// lifecycle `dt` / `entity` arg) — the emitted signature would
    /// have duplicate parameter identifiers.
    ParamNameCollision,
    /// A `CustomNode` (RFC-FLOW-VOCABULARY §1) names a dotted entry
    /// that is not registered in the `CustomNodeRegistry` passed to
    /// `renderFlowZig` / `renderFlowFile`. The assembler-emitted
    /// `PluginFlowNodes` registry is the source of truth at build
    /// time; an unknown name surfaces here at codegen rather than as
    /// a deferred Zig compile error against the missing decl.
    UnknownFlowNode,
    /// A node OUTSIDE a `ForRange` loop's body scope consumes that
    /// loop's `index` output (flow-codegen#21). The loop var `i_<id>`
    /// is declared only inside the loop body block, so an out-of-scope
    /// read would emit uncompilable Zig ("use of undeclared
    /// identifier"). Rejected at codegen (`validateForRangeIndexScopes`)
    /// rather than deferred to the Zig compiler.
    MalformedFlow,
};
