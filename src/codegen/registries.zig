//! Caller-facing registries and options for codegen: the `Options`
//! struct, the `FlowRegistry` (Subflow resolution), the `CustomNode*`
//! and `Coercion*` registries (plugin / game-script vocabulary), and the
//! `wrapEdgeWithCoercion` edge helper.

const std = @import("std");
const flow_io = @import("../flow_io.zig");

/// Caller-facing configuration for a single-flow render.
pub const Options = struct {
    flow_name: []const u8,
    /// Optional registry of plugin / game-script `FlowNodes`
    /// (RFC-FLOW-VOCABULARY §1 + §5). Required when the flow uses
    /// `CustomNode` nodes — codegen consults the registry to map
    /// dotted names to qualified `PluginFlowNodes` decls and to pick
    /// the command-vs-reporter lowering shape per the impl's return
    /// type. `null` is equivalent to an empty registry: a flow with no
    /// `CustomNode` nodes renders unchanged; any `CustomNode` reference
    /// is rejected as `UnknownFlowNode`. The assembler fills this from
    /// its phase-2 discovery walk; tests construct it inline.
    custom_nodes: ?*const CustomNodeRegistry = null,

    /// Optional registry of plugin / game-script `Coercions`
    /// (RFC-FLOW-VOCABULARY §2 / O4). Threaded into the wire-fit
    /// lookup so an edge across two pins with different Zig types is
    /// accepted when a registered `(from_zig_type, to_zig_type)` pair
    /// exists; edge codegen then wraps the source expression in
    /// `game_mod.PluginCoercions.<qualified>.convert(<expr>)`. `null`
    /// is equivalent to an empty registry — the wire-fit falls back
    /// to type equality (rule 1) + numeric widening (rule 2 / O1)
    /// only. The assembler fills this from its phase-2 discovery walk;
    /// tests construct it inline.
    coercions: ?*const CoercionRegistry = null,
};

// =====================================================================
// Flow registry — name-keyed map for Subflow resolution (RFC §5)
// =====================================================================

/// A flat, name-keyed registry of flows. `Subflow` references resolve
/// against it (RFC §5 — flows live in their own namespace, distinct
/// from prefabs/scenes). Borrows the `Flow` values from the caller.
pub const FlowRegistry = struct {
    map: std.StringHashMap(flow_io.Flow),

    pub const RegistryError = error{
        /// Two flow files share an effective name (RFC §5 —
        /// `error.DuplicateFlowName`).
        DuplicateFlowName,
    };

    pub fn init(allocator: std.mem.Allocator) FlowRegistry {
        return .{ .map = std.StringHashMap(flow_io.Flow).init(allocator) };
    }

    pub fn deinit(self: *FlowRegistry) void {
        self.map.deinit();
    }

    /// Register `flow` under its effective name. A duplicate effective
    /// name is `error.DuplicateFlowName` (RFC §5).
    pub fn add(self: *FlowRegistry, flow: flow_io.Flow) !void {
        const gop = try self.map.getOrPut(flow.name);
        if (gop.found_existing) return RegistryError.DuplicateFlowName;
        gop.value_ptr.* = flow;
    }

    pub fn get(self: *const FlowRegistry, name: []const u8) ?flow_io.Flow {
        return self.map.get(name);
    }
};

// =====================================================================
// CustomNode registry — name-keyed metadata for plugin / game-script
// FlowNodes (RFC-FLOW-VOCABULARY §1 + §5, flow-codegen#15 item 2)
// =====================================================================

/// One entry per discoverable plugin / game-script `FlowNode`. Built by
/// the assembler from its `PluginFlowNodes` walk (labelle-assembler
/// phase 2, RFC §2) and passed to `renderFlowFile` so codegen can:
///
/// - reject `CustomNode` references to unknown names as
///   `error.UnknownFlowNode` rather than deferring to a vaguer Zig
///   compile error against the missing decl;
/// - emit the **command** lowering (a bare statement) for `void`
///   impls vs the **reporter** lowering (`const n<id>_value = ...;`)
///   for value-returning impls (RFC §6 — command vs reporter shape).
///
/// The reflection on the `impl` decl happens once at assembler time;
/// flow-codegen consumes the precomputed `is_void` flag here. The
/// registry borrows its string slices from the caller.
pub const CustomNodeEntry = struct {
    /// Qualified decl name as it appears on `game_mod.PluginFlowNodes`
    /// (`"box2d__apply_impulse"`). Used directly in the emitted call
    /// site. The dotted form (`"box2d.apply_impulse"`) is what the
    /// `.flow.jsonc` author writes; the assembler maps the two via
    /// `PluginFlowNodes.resolve(...)`.
    qualified: []const u8,
    /// True when the impl's return type is `void` — codegen emits a
    /// bare statement; false when it returns a value — codegen binds
    /// the result to `n<id>_value`. RFC §6 ("Command vs reporter
    /// visual" — defaulted from `impl`'s return type).
    is_void: bool,
};

/// A flat, name-keyed registry of `CustomNode` entries. Empty by
/// default (`CustomNodeRegistry.empty(allocator)`) so callers that
/// don't use `CustomNode` nodes — every pre-RFC-FLOW-VOCABULARY-§1
/// flow — keep an unchanged call signature; an empty registry simply
/// rejects every `CustomNode` reference as `UnknownFlowNode`.
pub const CustomNodeRegistry = struct {
    map: std.StringHashMap(CustomNodeEntry),

    pub fn init(allocator: std.mem.Allocator) CustomNodeRegistry {
        return .{ .map = std.StringHashMap(CustomNodeEntry).init(allocator) };
    }

    pub fn deinit(self: *CustomNodeRegistry) void {
        self.map.deinit();
    }

    /// Register `entry` under its dotted name (`"box2d.apply_impulse"`).
    /// Borrows the slices on `entry` from the caller; the assembler's
    /// arena holds them for the lifetime of the codegen call.
    pub fn add(self: *CustomNodeRegistry, dotted: []const u8, entry: CustomNodeEntry) !void {
        try self.map.put(dotted, entry);
    }

    pub fn get(self: *const CustomNodeRegistry, dotted: []const u8) ?CustomNodeEntry {
        return self.map.get(dotted);
    }
};

// =====================================================================
// CoercionRegistry — type-keyed lookup for plugin-declared coercions
// (RFC-FLOW-VOCABULARY §2 / O4, flow-codegen#15 item 5)
// =====================================================================

/// One entry per discoverable plugin / game-script `Coercion`. Built
/// by the assembler from its `PluginCoercions` walk (parallel to
/// `CustomNodeEntry`). Carries the Zig source text of the `From` and
/// `To` types so wire-fit can match an edge's producer- and
/// consumer-pin types, plus the qualified decl name codegen emits at
/// the call site.
///
/// The strings are borrowed from the caller; the assembler's arena
/// owns them for the lifetime of the codegen call.
pub const CoercionEntry = struct {
    /// Qualified decl name as it appears on `game_mod.PluginCoercions`
    /// (`"box2d__body_to_entity"`). Used directly in the emitted call
    /// site as `game_mod.PluginCoercions.<qualified>.convert(<expr>)`.
    qualified: []const u8,
    /// Zig source text of the impl's single parameter type (e.g.
    /// `"BodyId"`, `"u64"`). The editor's wire-fit matches this
    /// string against the producer pin's declared type; codegen
    /// reuses the same key for its `accepts` lookup.
    from_zig_type: []const u8,
    /// Zig source text of the impl's return type (e.g. `"u32"`,
    /// `"EntityId"`). Matched against the consumer pin's declared
    /// type. The labelle-core factory rejects `void` impls at
    /// comptime, so this field is never empty in practice.
    to_zig_type: []const u8,
};

/// Outcome of a wire-fit lookup (RFC-FLOW-VOCABULARY §2). Returned by
/// `CoercionRegistry.wireFitAccepts`. The three accept cases tell the
/// editor (and any source-text-driven wire-fit caller) which rule
/// applied, so a UI can surface "via numeric widening" vs "via
/// declared coercion `<name>`" diagnostics distinctly.
pub const WireFit = union(enum) {
    /// Rule 1 — Zig type equality. The two type strings match
    /// verbatim.
    exact,
    /// Rule 2 (O1) — numeric widening. Currently only flagged when
    /// the caller hands `wireFitAccepts` two distinct primitive
    /// numeric type names where Zig's implicit widening accepts the
    /// conversion. For now the codegen-side check is a thin sentinel
    /// (the actual numeric-widening matrix lives in
    /// `labelle-core.numericFits` and is consumed at editor compile
    /// time); flow-codegen's runtime caller is the editor.
    numeric_widen,
    /// Rule 3 — a registered plugin coercion bridges the gap. Carries
    /// the qualified decl name flow-codegen wraps the edge in.
    coercion: []const u8,
    /// Refused — no built-in rule matched and no coercion is
    /// registered for `(from, to)`.
    refused,
};

/// A flat registry of plugin coercions keyed by `(from, to)` Zig
/// source-text type names. Empty by default — every flow that doesn't
/// declare cross-type wires keeps its unchanged behaviour; an empty
/// registry simply makes `wireFitAccepts` return `.refused` for any
/// (from, to) the editor's built-in rules don't already accept.
///
/// The key is a heap-allocated `"<from>->><to>"` string so the same
/// `std.StringHashMap` shape powers lookups. Borrows the `entry` values
/// from the caller.
pub const CoercionRegistry = struct {
    /// Composite key: `"<from_zig_type>->><to_zig_type>"`. The `->>`
    /// separator is unambiguous (Zig type names don't contain it) and
    /// avoids the per-pair allocation a `struct{from,to}` key would
    /// need going through a custom HashMap context. Keys live in the
    /// registry's `arena` and are freed by `deinit`.
    map: std.StringHashMap(CoercionEntry),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) CoercionRegistry {
        return .{
            .map = std.StringHashMap(CoercionEntry).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CoercionRegistry) void {
        self.map.deinit();
        self.arena.deinit();
    }

    /// Register `entry` under its `(from, to)` type-name pair. A
    /// duplicate `(from, to)` overwrites the prior entry — same
    /// last-write-wins shape `PluginPinStyles` dedupe uses, surfacing
    /// late-loaded plugin conventions cleanly.
    pub fn add(self: *CoercionRegistry, entry: CoercionEntry) !void {
        const key = try std.fmt.allocPrint(
            self.arena.allocator(),
            "{s}->>{s}",
            .{ entry.from_zig_type, entry.to_zig_type },
        );
        try self.map.put(key, entry);
    }

    /// Look up a coercion for `(from, to)`. Returns `null` when no
    /// entry is registered — the caller falls back to the built-in
    /// wire-fit rules (or refuses the wire).
    pub fn get(self: *const CoercionRegistry, from: []const u8, to: []const u8) ?CoercionEntry {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}->>{s}", .{ from, to }) catch return null;
        return self.map.get(key);
    }

    /// Resolve the wire-fit outcome for a pin pair (RFC-FLOW-VOCABULARY
    /// §2 rule chain):
    ///   1. equality — strings match → `.exact`.
    ///   2. (caller-side: numeric widening — flow-codegen doesn't
    ///       reflect on Zig types from source text; callers that need
    ///       this consult `labelle-core.numericFits` against actual
    ///       Zig `type` values. The `numeric_widen` outcome is
    ///       reserved for the future editor-side check that pairs
    ///       both rules).
    ///   3. registry — a registered `(from, to)` → `.coercion(qualified)`.
    ///   4. otherwise → `.refused`.
    ///
    /// This is the contract the editor and any source-text-driven
    /// codegen consumer consults at edge-validation time.
    pub fn wireFitAccepts(self: *const CoercionRegistry, from: []const u8, to: []const u8) WireFit {
        if (std.mem.eql(u8, from, to)) return .exact;
        if (self.get(from, to)) |entry| return .{ .coercion = entry.qualified };
        return .refused;
    }
};

/// Wrap a Zig source expression in a `<qualified>.convert(<expr>)`
/// call against `game_mod.PluginCoercions`. Edge codegen calls this
/// when the wire-fit lookup returned `.coercion(qualified)`. Returns
/// the wrapped expression on `alloc`; the caller owns the bytes.
///
/// The wrap is shallow on purpose — flow-codegen never threads `game`
/// into the convert call because the labelle-core factory rejects
/// multi-param impls at comptime, so a registered coercion always has
/// a single-arg call site. If a coercion genuinely needs game state,
/// the source plugin must declare a `FlowNode` instead.
pub fn wrapEdgeWithCoercion(
    alloc: std.mem.Allocator,
    qualified: []const u8,
    expr: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "game_mod.PluginCoercions.{s}.convert({s})",
        .{ qualified, expr },
    );
}
