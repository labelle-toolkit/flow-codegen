//! Second-pass converter: rewrite raw `Call` nodes as `CustomNode`
//! references against a project's flow catalog sidecar
//! (flow-codegen#18, RFC-FLOW-VOCABULARY *Migration* section).
//!
//! Phase 2 (labelle-assembler `f7c6191`) walks plugin modules + game
//! scripts for `pub const FlowNodes` declarations and ships the
//! resolved registry as a project-level sidecar
//! (`<project>/.labelle/flow_catalog.json`). Once a script declares a
//! `FlowNode` for an existing helper, every `Call` node that already
//! invokes that helper in raw form is a candidate for in-place
//! conversion to the `CustomNode` form — same lowering, but no longer
//! tied to the raw-call escape hatch (RFC §7).
//!
//! ## Operation
//!
//! `convertFlow(allocator, flow, catalog)` walks `flow.nodes`. For each
//! `Call` node:
//!
//! 1. Parse the `callee` text — strip the leading `@import("...").`
//!    prefix if present; the dotted tail is what we match against the
//!    catalog. Identifiers under `std.*`, `@builtin.*`, `@import("std..."
//!    or `@import("@builtin..."`, and `engine.*` are skipped — the
//!    raw-call escape hatch is permanent (RFC §7).
//! 2. Split the trailing dotted form into `(prefix?, symbol)`. Resolve
//!    against the catalog's flattened (plugin, qualified, last_part)
//!    table: a match requires `symbol`'s normalized snake_case form to
//!    equal the catalog entry's last-part (the verb), and — if the
//!    callee carries a `prefix` — for that prefix's snake_case form to
//!    equal the catalog plugin name.
//! 3. A unique match rewrites the node to a `CustomNode` carrying the
//!    catalog's `qualified` name. No match leaves the node alone (the
//!    escape hatch). Multiple matches surface as an `Ambiguous`
//!    diagnostic; the converter emits a `// TODO: ambiguous match`
//!    comment on the driver's stderr and leaves the node alone.
//!
//! Edges keep their `argN` pin convention — `Call` and `CustomNode`
//! both use it (see `flow-codegen/src/codegen.zig`'s `isCallArgPin`)
//! so the on-disk graph stays structurally identical apart from the
//! `type` discriminator + `name`/`callee` field swap.
//!
//! ## Out of scope
//!
//! - Multi-flow rewrites or registry generation — the converter is a
//!   pure function on `(flow, catalog)`.
//! - `Call` nodes pointing at non-FlowNode helpers (`std.math.sin`,
//!   `@builtin.@compileError`, `engine.dt`) — skipped explicitly.

const std = @import("std");
const flow_io = @import("flow_io.zig");

// =====================================================================
// Catalog — the parsed `<project>/.labelle/flow_catalog.json` subset
// =====================================================================

/// Minimum slice of a catalog FlowNode entry the converter needs —
/// `qualified` is the dotted name we write into `CustomNode.name`, and
/// the parsed plugin + verb halves are what we match against.
pub const CatalogEntry = struct {
    /// `"box2d.apply_impulse"` — written verbatim into `CustomNode.name`
    /// on a match.
    qualified: []const u8,
    /// The leading dotted segment of `qualified` (the plugin name).
    /// Borrowed from `qualified`; not owned separately.
    plugin: []const u8,
    /// The trailing dotted segment of `qualified` (the verb / decl
    /// name). Borrowed from `qualified`; not owned separately.
    verb: []const u8,
};

/// Parsed flow catalog — just the per-plugin FlowNode list flattened
/// into one slice. Owns its arena; caller frees via `deinit()`.
pub const Catalog = struct {
    arena: *std.heap.ArenaAllocator,
    entries: []CatalogEntry,

    pub fn deinit(self: *Catalog) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub const CatalogError = error{
    /// The JSON file does not match the expected catalog shape (missing
    /// `plugins` array, or a `flow_nodes` entry without a string
    /// `qualified` field).
    MalformedCatalog,
};

/// Parse a `.labelle/flow_catalog.json` source. Tolerates unknown keys
/// (the catalog format evolves with each plugin metadata feature) — only
/// the `plugins[].flow_nodes[].qualified` field is required.
pub fn parseCatalog(allocator: std.mem.Allocator, raw: []const u8) !Catalog {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch {
        return error.MalformedCatalog;
    };

    if (parsed != .object) return error.MalformedCatalog;
    const root = parsed.object;

    const plugins_v = root.get("plugins") orelse return error.MalformedCatalog;
    if (plugins_v != .array) return error.MalformedCatalog;

    var out: std.ArrayList(CatalogEntry) = .empty;
    errdefer out.deinit(a);

    for (plugins_v.array.items) |plugin_v| {
        if (plugin_v != .object) return error.MalformedCatalog;
        const plugin_obj = plugin_v.object;
        const fn_v = plugin_obj.get("flow_nodes") orelse continue;
        if (fn_v != .array) return error.MalformedCatalog;
        for (fn_v.array.items) |entry_v| {
            if (entry_v != .object) return error.MalformedCatalog;
            const eo = entry_v.object;
            const q_v = eo.get("qualified") orelse return error.MalformedCatalog;
            if (q_v != .string) return error.MalformedCatalog;
            const qualified = try a.dupe(u8, q_v.string);
            const dot = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse continue;
            try out.append(a, .{
                .qualified = qualified,
                .plugin = qualified[0..dot],
                .verb = qualified[dot + 1 ..],
            });
        }
    }

    return .{ .arena = arena, .entries = try out.toOwnedSlice(a) };
}

// =====================================================================
// Conversion
// =====================================================================

/// One per-node outcome — produced for every `Call` node the converter
/// considered. The driver consumes the slice to emit diagnostics
/// (ambiguous matches → stderr `// TODO`).
pub const NodeOutcome = struct {
    /// The `id` of the original `Call` node.
    node_id: u32,
    /// The raw `callee` source text — preserved so the driver can
    /// surface it in stderr messages without re-walking the flow.
    callee: []const u8,
    /// What the converter did with the node.
    status: Status,

    pub const Status = union(enum) {
        /// Rewritten to a `CustomNode` carrying `qualified`.
        rewritten: []const u8,
        /// Skipped — the callee is an escape-hatch identifier
        /// (`std.*`, `@builtin.*`, `engine.*`).
        skipped_escape_hatch,
        /// Skipped — no catalog entry matched the callee.
        skipped_no_match,
        /// Skipped — more than one catalog entry matched. The driver
        /// emits a diagnostic; the on-disk node is unchanged.
        ambiguous: []const []const u8, // qualified names of the matches
    };
};

/// Result of `convertFlow` — the rewritten flow (owns its own arena
/// via `LoadedFlow.deinit`) plus per-node outcomes the driver uses for
/// diagnostics + exit-status decisions.
pub const ConvertResult = struct {
    loaded: flow_io.LoadedFlow,
    outcomes: []NodeOutcome,

    pub fn deinit(self: *ConvertResult) void {
        // The outcomes slice + every borrowed `[]const u8` it holds
        // live on the loaded flow's arena.
        self.loaded.deinit();
    }

    /// True when at least one node was rewritten to a `CustomNode`.
    pub fn anyRewritten(self: ConvertResult) bool {
        for (self.outcomes) |o| if (o.status == .rewritten) return true;
        return false;
    }
};

/// Convert an already-parsed v2 flow against a catalog. Returns a new
/// `LoadedFlow` (with its own arena) carrying the rewritten graph plus
/// per-`Call`-node outcomes. The input `flow` is read-only — the
/// caller still owns it and is responsible for deinit'ing the original
/// `LoadedFlow` separately.
pub fn convertFlow(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    catalog: Catalog,
) !ConvertResult {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var new_nodes = try a.alloc(flow_io.Node, flow.nodes.len);
    var outcomes: std.ArrayList(NodeOutcome) = .empty;
    errdefer outcomes.deinit(a);

    for (flow.nodes, 0..) |n, i| {
        // Always deep-copy the node payload onto the result arena —
        // non-Call kinds pass through unchanged but with arena-owned
        // strings so the original flow can be freed independently.
        new_nodes[i] = try cloneNode(a, n);

        if (n.kind != .Call) continue;
        const callee = n.kind.Call.callee;
        const outcome_status = try resolveCallee(a, callee, catalog);

        // Carry the raw callee on the outcome — borrowed from the
        // arena-owned clone (`new_nodes[i].kind.Call.callee` still
        // points at the original-cloned text, which is on the same
        // arena as `outcomes`).
        const callee_on_arena = new_nodes[i].kind.Call.callee;
        try outcomes.append(a, .{
            .node_id = n.id,
            .callee = callee_on_arena,
            .status = outcome_status,
        });

        switch (outcome_status) {
            .rewritten => |qualified| {
                new_nodes[i].kind = .{ .CustomNode = .{ .name = qualified } };
            },
            else => {},
        }
    }

    // Deep-copy edges + the rest of the flow onto the result arena so
    // the returned `LoadedFlow` is fully self-contained.
    const new_edges = try a.alloc(flow_io.Edge, flow.edges.len);
    for (flow.edges, 0..) |e, i| {
        new_edges[i] = .{
            .from = .{ .node = e.from.node, .pin = try a.dupe(u8, e.from.pin) },
            .to = .{ .node = e.to.node, .pin = try a.dupe(u8, e.to.pin) },
        };
    }
    // Control-flow edges (flow-codegen#8) pass through untouched — the
    // converter only rewrites `Call` data nodes; exec wiring is unrelated.
    const new_exec_edges = try a.alloc(flow_io.ExecEdge, flow.exec_edges.len);
    for (flow.exec_edges, 0..) |x, i| {
        new_exec_edges[i] = .{
            .from = .{ .node = x.from.node, .pin = try a.dupe(u8, x.from.pin) },
            .to_node = x.to_node,
        };
    }
    const new_params = try a.alloc(flow_io.Param, flow.params.len);
    for (flow.params, 0..) |p, i| {
        new_params[i] = .{
            .name = try a.dupe(u8, p.name),
            .type = try a.dupe(u8, p.type),
            .default = if (p.default) |d|
                flow_io.Literal{ .zig_text = try a.dupe(u8, d.zig_text) }
            else
                null,
        };
    }
    const new_variables = try a.alloc(flow_io.Variable, flow.variables.len);
    for (flow.variables, 0..) |v, i| {
        new_variables[i] = .{
            .name = try a.dupe(u8, v.name),
            .type = try a.dupe(u8, v.type),
            .default = .{ .zig_text = try a.dupe(u8, v.default.zig_text) },
        };
    }

    // Locals (flow-codegen#23) and collections (#24) must be carried
    // through the Call→CustomNode conversion too — both default to empty
    // on `Flow`, so omitting them here silently drops the flow's local
    // vars / lists (bugbot, #24).
    const new_locals = try a.alloc(flow_io.Variable, flow.locals.len);
    for (flow.locals, 0..) |v, i| {
        new_locals[i] = .{
            .name = try a.dupe(u8, v.name),
            .type = try a.dupe(u8, v.type),
            .default = .{ .zig_text = try a.dupe(u8, v.default.zig_text) },
        };
    }

    const new_collections = try a.alloc(flow_io.Collection, flow.collections.len);
    for (flow.collections, 0..) |c, i| {
        new_collections[i] = .{
            .name = try a.dupe(u8, c.name),
            .kind = c.kind,
            .element = try a.dupe(u8, c.element),
            .key = try a.dupe(u8, c.key),
            .value = try a.dupe(u8, c.value),
        };
    }

    const new_event: flow_io.Event = switch (flow.event) {
        .subgraph => .subgraph,
        .OnEvent => |b| .{ .OnEvent = .{
            .name = if (b.name) |n| try a.dupe(u8, n) else null,
            .priority = b.priority,
        } },
    };

    const out_flow: flow_io.Flow = .{
        .name = try a.dupe(u8, flow.name),
        .event = new_event,
        .params = new_params,
        .variables = new_variables,
        .locals = new_locals,
        .collections = new_collections,
        .nodes = new_nodes,
        .edges = new_edges,
        .exec_edges = new_exec_edges,
    };

    return .{
        .loaded = .{ .arena = arena, .flow = out_flow },
        .outcomes = try outcomes.toOwnedSlice(a),
    };
}

fn cloneNode(a: std.mem.Allocator, n: flow_io.Node) !flow_io.Node {
    const kind: flow_io.NodeKind = switch (n.kind) {
        .GetComponent => |b| .{ .GetComponent = .{ .type = try a.dupe(u8, b.type) } },
        .SetField => |b| .{ .SetField = .{ .target = try a.dupe(u8, b.target) } },
        .BinOp => |b| .{ .BinOp = .{ .op = b.op } },
        .Compare => |b| .{ .Compare = .{ .op = b.op } },
        .Logic => |b| .{ .Logic = .{ .op = b.op } },
        .Literal => |b| .{ .Literal = .{ .value = try a.dupe(u8, b.value) } },
        .Identifier => |b| .{ .Identifier = .{ .name = try a.dupe(u8, b.name) } },
        .Call => |b| .{ .Call = .{ .callee = try a.dupe(u8, b.callee) } },
        .Param => |b| .{ .Param = .{ .param = try a.dupe(u8, b.param) } },
        .Output => |b| .{ .Output = .{
            .name = try a.dupe(u8, b.name),
            .type = try a.dupe(u8, b.type),
        } },
        .Subflow => |b| blk: {
            const bindings = try a.alloc(flow_io.Binding, b.bindings.len);
            for (b.bindings, 0..) |bd, i| {
                bindings[i] = .{
                    .param = try a.dupe(u8, bd.param),
                    .value = .{ .zig_text = try a.dupe(u8, bd.value.zig_text) },
                };
            }
            break :blk .{ .Subflow = .{
                .flow = try a.dupe(u8, b.flow),
                .bindings = bindings,
            } };
        },
        .Emit => |b| .{ .Emit = .{ .event = try a.dupe(u8, b.event) } },
        .Event => |b| .{ .Event = .{ .name = try a.dupe(u8, b.name) } },
        .GetVariable => |b| .{ .GetVariable = .{ .name = try a.dupe(u8, b.name) } },
        .SetVariable => |b| .{ .SetVariable = .{ .name = try a.dupe(u8, b.name) } },
        .ChangeVariable => |b| .{ .ChangeVariable = .{
            .name = try a.dupe(u8, b.name),
            .by = try a.dupe(u8, b.by),
        } },
        .ClearVariable => |b| .{ .ClearVariable = .{ .name = try a.dupe(u8, b.name) } },
        .HasValueVariable => |b| .{ .HasValueVariable = .{ .name = try a.dupe(u8, b.name) } },
        .CustomNode => |b| .{ .CustomNode = .{ .name = try a.dupe(u8, b.name) } },
        // `Branch` carries no payload (flow-codegen#8); `ForRange`/`While`
        // loops are payload-free too (flow-codegen#21).
        .Branch => .{ .Branch = .{} },
        .ForRange => .{ .ForRange = .{} },
        .While => .{ .While = .{} },
        // `Once` carries no payload; `Cooldown` carries only its inline
        // `seconds` f64 (a plain copy, no allocation) (flow-codegen#47).
        .Once => .{ .Once = .{} },
        .Cooldown => |b| .{ .Cooldown = .{ .seconds = b.seconds } },
        // `Delay` carries only its inline `seconds` f64 (a plain copy, no
        // allocation) (flow-codegen#48).
        .Delay => |b| .{ .Delay = .{ .seconds = b.seconds } },
        // `Select`/`Switch` carry no payload (flow-codegen#22).
        .Select => .{ .Select = .{} },
        .Switch => .{ .Switch = .{} },
        // `Log` carries only its inline `label` (flow-codegen#20); the
        // `value` input is a data edge.
        .Log => |b| .{ .Log = .{ .label = try a.dupe(u8, b.label) } },
        // String reporters (flow-codegen#26): `Format` carries only its
        // inline `template` (dupe it like `Log`'s label); the others are
        // payload-free (their value inputs are data edges).
        .Format => |b| .{ .Format = .{ .template = try a.dupe(u8, b.template) } },
        .Concat => .{ .Concat = .{} },
        .IntToString => .{ .IntToString = .{} },
        .FloatToString => .{ .FloatToString = .{} },
        // Input reporters (labelle-gui#208 Option A). The key-taking ones
        // carry an inline `key` (the bare `KeyboardKey` enum-tag name) —
        // dupe it like other string payloads. The mouse reporters are
        // payload-free.
        .IsKeyDown => |b| .{ .IsKeyDown = .{ .key = try a.dupe(u8, b.key) } },
        .IsKeyPressed => |b| .{ .IsKeyPressed = .{ .key = try a.dupe(u8, b.key) } },
        .IsKeyReleased => |b| .{ .IsKeyReleased = .{ .key = try a.dupe(u8, b.key) } },
        .IsMouseButtonDown => |b| .{ .IsMouseButtonDown = .{ .button = try a.dupe(u8, b.button) } },
        .IsMouseButtonPressed => |b| .{ .IsMouseButtonPressed = .{ .button = try a.dupe(u8, b.button) } },
        .IsMouseButtonReleased => |b| .{ .IsMouseButtonReleased = .{ .button = try a.dupe(u8, b.button) } },
        .GetMouseX => .{ .GetMouseX = .{} },
        .GetMouseY => .{ .GetMouseY = .{} },
        .GetMouseWheel => .{ .GetMouseWheel = .{} },
        // Gamepad reporters (labelle-assembler#250 Phase 3) carry an inline
        // `button`/`axis` (the bare `GamepadButton`/`GamepadAxis` enum-tag
        // name) — dupe it like other string payloads.
        .IsGamepadButtonDown => |b| .{ .IsGamepadButtonDown = .{ .button = try a.dupe(u8, b.button) } },
        .IsGamepadButtonPressed => |b| .{ .IsGamepadButtonPressed = .{ .button = try a.dupe(u8, b.button) } },
        .IsGamepadButtonReleased => |b| .{ .IsGamepadButtonReleased = .{ .button = try a.dupe(u8, b.button) } },
        .GetGamepadAxisValue => |b| .{ .GetGamepadAxisValue = .{ .axis = try a.dupe(u8, b.axis) } },
        // List operation nodes (flow-codegen#24) carry only the list
        // `collection` name — dupe it like other string payloads.
        .ListAppend => |b| .{ .ListAppend = .{ .collection = try a.dupe(u8, b.collection) } },
        .ListLength => |b| .{ .ListLength = .{ .collection = try a.dupe(u8, b.collection) } },
        .ListGet => |b| .{ .ListGet = .{ .collection = try a.dupe(u8, b.collection) } },
        .ListSet => |b| .{ .ListSet = .{ .collection = try a.dupe(u8, b.collection) } },
        .ListContains => |b| .{ .ListContains = .{ .collection = try a.dupe(u8, b.collection) } },
        .ListClear => |b| .{ .ListClear = .{ .collection = try a.dupe(u8, b.collection) } },
        .ForEach => |b| .{ .ForEach = .{ .collection = try a.dupe(u8, b.collection) } },
        // Map operation nodes (flow-codegen#24, MAPS) carry only a
        // `collection` name — dupe it like the list ops.
        .MapSet => |b| .{ .MapSet = .{ .collection = try a.dupe(u8, b.collection) } },
        .MapGet => |b| .{ .MapGet = .{ .collection = try a.dupe(u8, b.collection) } },
        .MapHas => |b| .{ .MapHas = .{ .collection = try a.dupe(u8, b.collection) } },
        .MapRemove => |b| .{ .MapRemove = .{ .collection = try a.dupe(u8, b.collection) } },
        .MapClear => |b| .{ .MapClear = .{ .collection = try a.dupe(u8, b.collection) } },
        .MapLength => |b| .{ .MapLength = .{ .collection = try a.dupe(u8, b.collection) } },
        .MapForEach => |b| .{ .MapForEach = .{ .collection = try a.dupe(u8, b.collection) } },
    };
    return .{ .id = n.id, .pos = n.pos, .kind = kind };
}

// =====================================================================
// Callee resolution
// =====================================================================

/// Resolve a callee source text against the catalog. Returns the
/// per-node status the converter will record + use to rewrite (or not).
fn resolveCallee(
    a: std.mem.Allocator,
    callee: []const u8,
    catalog: Catalog,
) !NodeOutcome.Status {
    // 1. Strip a leading `@import("...").` wrapper if present.
    const tail = stripImportWrapper(callee);

    // 2. Escape hatch — `std.*`, `@builtin.*`, `engine.*`. We also catch
    //    `@import("std")...` and `@import("@builtin")...` via the
    //    `stripImportWrapper` extracting the trailing segment.
    if (isEscapeHatch(callee, tail)) return .skipped_escape_hatch;

    // 3. Split the dotted tail into (prefix?, symbol). The symbol is
    //    always the last component; the prefix (if any) is everything
    //    before the last `.`.
    const dot = std.mem.lastIndexOfScalar(u8, tail, '.');
    const symbol = if (dot) |d| tail[d + 1 ..] else tail;
    const prefix = if (dot) |d| tail[0..d] else "";

    if (symbol.len == 0) return .skipped_no_match;

    // 4. Walk the catalog. A candidate matches when the (normalized)
    //    verb equals the symbol and — if the callee has a prefix —
    //    the (normalized) plugin matches it.
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(a);

    for (catalog.entries) |e| {
        if (!verbMatches(symbol, e.verb)) continue;
        if (prefix.len != 0 and !pluginMatches(prefix, e.plugin)) continue;
        try matches.append(a, e.qualified);
    }

    if (matches.items.len == 0) return .skipped_no_match;
    if (matches.items.len == 1) return .{ .rewritten = matches.items[0] };
    return .{ .ambiguous = try matches.toOwnedSlice(a) };
}

/// Drop a leading `@import("...").` wrapper from a callee text. Returns
/// the tail (`<dotted-path>`) on a successful strip, or the input
/// unchanged when no wrapper is present.
fn stripImportWrapper(callee: []const u8) []const u8 {
    const prefix = "@import(";
    if (!std.mem.startsWith(u8, callee, prefix)) return callee;
    // Find the closing `)` of the @import call. We assume well-formed
    // input — a single string literal arg with no embedded `)`. If the
    // shape is unexpected, return the callee unchanged (the resolver
    // will fall through to "no match" downstream).
    const close_paren = std.mem.indexOfScalar(u8, callee, ')') orelse return callee;
    if (close_paren + 1 >= callee.len) return callee;
    if (callee[close_paren + 1] != '.') return callee;
    return callee[close_paren + 2 ..];
}

/// Recognize raw-call escape-hatch identifiers — `std.*`, `@builtin.*`,
/// `engine.*` (RFC §7). Checks both the raw callee (for `@import(...)`
/// wrappers around `std`) and the stripped tail (the dotted-path form).
fn isEscapeHatch(callee: []const u8, tail: []const u8) bool {
    // Direct `std.foo`, `engine.bar`, `@builtin.compileError` forms.
    if (startsWithSegment(tail, "std")) return true;
    if (startsWithSegment(tail, "engine")) return true;
    if (std.mem.startsWith(u8, tail, "@builtin.")) return true;
    if (std.mem.eql(u8, tail, "@builtin")) return true;

    // `@import("std").math.sin` style — `stripImportWrapper` returned
    // the post-`).` tail; double-check the raw too in case the import
    // text itself names `std` (`@import("std")` even without a `.tail`).
    if (std.mem.startsWith(u8, callee, "@import(\"std\")")) return true;
    if (std.mem.startsWith(u8, callee, "@import(\"builtin\")")) return true;
    return false;
}

fn startsWithSegment(s: []const u8, seg: []const u8) bool {
    if (!std.mem.startsWith(u8, s, seg)) return false;
    if (s.len == seg.len) return true;
    return s[seg.len] == '.';
}

/// Two verb names match when their normalized snake_case forms are
/// equal. Normalization: lowercases ASCII + inserts `_` before each
/// non-leading uppercase letter, so `applyImpulse` and `apply_impulse`
/// both reduce to `apply_impulse`.
fn verbMatches(a: []const u8, b: []const u8) bool {
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    const na = normalizeIdent(&buf_a, a) catch return false;
    const nb = normalizeIdent(&buf_b, b) catch return false;
    return std.mem.eql(u8, na, nb);
}

/// Plugin matching is verb matching — we treat the prefix the same way
/// (catalog plugin names are always lowercase, but a user could
/// hypothetically spell the prefix differently in source).
fn pluginMatches(a: []const u8, b: []const u8) bool {
    return verbMatches(a, b);
}

/// snake_case-lowercase an identifier into `buf`. Returns the
/// populated slice (a view into `buf`). Truncates with
/// `error.BufferTooSmall` if the input is longer than the buffer can
/// hold post-conversion — for our purposes (identifiers under 64
/// chars) the 128-byte stack buffer is more than enough.
fn normalizeIdent(buf: []u8, ident: []const u8) ![]u8 {
    var i: usize = 0;
    for (ident, 0..) |c, idx| {
        if (c >= 'A' and c <= 'Z') {
            // Insert a `_` before every uppercase letter except the
            // first character (`Foo` → `foo`, `myVerb` → `my_verb`).
            if (idx != 0) {
                if (i >= buf.len) return error.BufferTooSmall;
                buf[i] = '_';
                i += 1;
            }
            if (i >= buf.len) return error.BufferTooSmall;
            buf[i] = c + 32;
            i += 1;
        } else {
            if (i >= buf.len) return error.BufferTooSmall;
            buf[i] = c;
            i += 1;
        }
    }
    return buf[0..i];
}

// =====================================================================
// Tests — the full golden-file suite (resolver internals + end-to-end
// flow rewriting) lives in `test/call_to_customnode_test.zig`.
// =====================================================================

test {
    std.testing.refAllDecls(@This());
}
