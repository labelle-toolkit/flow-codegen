//! One-shot `.flow.zon` → `.flow.jsonc` converter (flow-codegen#2).
//!
//! Per RFC `RFC-FLOWS-JSONC.md` §2 + the Migration section, the schema
//! maps 1:1 apart from two mechanical changes:
//!
//!   - The `kind`-tagged-union wrapper is flattened: a node's
//!     `.kind = .{ .BinOp = .{ .op = .add } }` becomes the flat pair
//!     `"type": "BinOp", "op": "add"`.
//!   - The `links` array is renamed to `edges` (same `from`/`to`
//!     `{ node, pin }` shape).
//!
//! The `event` tagged union is flattened the same way as `kind`
//! (`{ "type": "OnCreate", "arg_entity": "entity" }`) — §2's example
//! event object shows the flattened form.
//!
//! This is a build-time / migration tool, not part of the shipped
//! game. It reuses `flow_io`'s ZON parser (which validates id
//! uniqueness and link integrity) so a malformed input is rejected
//! before any JSONC is written.
//!
//! The RFC mandates a *hard cut*: once converted, `.flow.zon` support
//! is dropped. This module only performs the rewrite; deleting the
//! old files is the caller's job (the `convert` subcommand does it
//! when asked).

const std = @import("std");
const flow_io = @import("flow_io.zig");

/// Convert a parsed flow to `.flow.jsonc` source text. Caller owns the
/// returned bytes (`allocator.free`).
///
/// Output is deterministic: nodes are emitted sorted by `id`, edges
/// sorted by `(from.node, from.pin, to.node, to.pin)` — the same
/// canonical ordering `flow_io.renderFlowZon` uses, so a convert pass
/// produces stable diffs.
///
/// `flow_name`, when non-null and non-empty, is written as the
/// top-level `"name"` registry key (RFC §5). Pass the source file's
/// basename stem; callers typically derive it via
/// `flow_io.displayNameFromPath`. A null/empty name omits the field —
/// the RFC says `"name"` is optional and defaults to the filename
/// basename.
pub fn flowToJsonc(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    flow_name: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\n");

    if (flow_name) |name| {
        if (name.len > 0) {
            try w.writeAll("  // Registry key (RFC \xc2\xa75). Defaults to the filename basename.\n");
            try w.writeAll("  \"name\": ");
            try writeJsonString(w, name);
            try w.writeAll(",\n");
        }
    }

    // Entry point — the `event` tagged union, flattened to a flat
    // object with a `"type"` discriminator.
    try w.writeAll("  \"event\": ");
    try writeEvent(w, flow.event);
    try w.writeAll(",\n");

    // Nodes, sorted by id for deterministic output.
    const sorted_nodes = try allocator.dupe(flow_io.Node, flow.nodes);
    defer allocator.free(sorted_nodes);
    std.mem.sort(flow_io.Node, sorted_nodes, {}, lessThanNode);

    try w.writeAll("  \"nodes\": [");
    if (sorted_nodes.len == 0) {
        try w.writeAll("]");
    } else {
        try w.writeAll("\n");
        for (sorted_nodes, 0..) |n, i| {
            try writeNode(w, n);
            if (i + 1 != sorted_nodes.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ]");
    }
    try w.writeAll(",\n");

    // Edges (the `.flow.zon` `links` array, renamed).
    const sorted_edges = try allocator.dupe(flow_io.Link, flow.links);
    defer allocator.free(sorted_edges);
    std.mem.sort(flow_io.Link, sorted_edges, {}, lessThanLink);

    try w.writeAll("  \"edges\": [");
    if (sorted_edges.len == 0) {
        try w.writeAll("]");
    } else {
        try w.writeAll("\n");
        for (sorted_edges, 0..) |l, i| {
            try writeEdge(w, l);
            if (i + 1 != sorted_edges.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ]");
    }
    try w.writeAll("\n}\n");

    return aw.toOwnedSlice();
}

// Node/edge ordering is the single canonical sort defined in
// `flow_io` — reused here (not re-implemented) so the converter and
// `flow_io.renderFlowZon` cannot drift apart.
const lessThanNode = flow_io.lessThanNode;
const lessThanLink = flow_io.lessThanLink;

/// `event` tagged union → flat object with a `"type"` discriminator.
/// e.g. `.{ .OnCreate = .{ .arg_entity = "entity" } }` becomes
/// `{ "type": "OnCreate", "arg_entity": "entity" }`.
fn writeEvent(w: *std.Io.Writer, ev: flow_io.Event) !void {
    switch (ev) {
        .OnUpdate => |b| {
            try w.writeAll("{ \"type\": \"OnUpdate\", \"arg_dt\": ");
            try writeJsonString(w, b.arg_dt);
            try w.writeAll(" }");
        },
        .OnCreate => |b| {
            try w.writeAll("{ \"type\": \"OnCreate\", \"arg_entity\": ");
            try writeJsonString(w, b.arg_entity);
            try w.writeAll(" }");
        },
        .OnDestroy => |b| {
            try w.writeAll("{ \"type\": \"OnDestroy\", \"arg_entity\": ");
            try writeJsonString(w, b.arg_entity);
            try w.writeAll(" }");
        },
    }
}

/// One flow node → a single flat JSON object. The `.kind` tagged-union
/// layer is dropped: the variant tag becomes `"type"` and the variant
/// body's fields are spliced in alongside it. `id` and `pos` are
/// preserved verbatim.
fn writeNode(w: *std.Io.Writer, n: flow_io.Node) !void {
    try w.print("    {{ \"id\": {d}, \"type\": ", .{n.id});
    switch (n.kind) {
        .GetComponent => |b| {
            try w.writeAll("\"GetComponent\", \"component\": ");
            try writeJsonString(w, b.type);
        },
        .SetField => |b| {
            try w.writeAll("\"SetField\", \"target\": ");
            try writeJsonString(w, b.target);
        },
        .BinOp => |b| {
            try w.writeAll("\"BinOp\", \"op\": ");
            try writeJsonString(w, @tagName(b.op));
        },
        .Literal => |b| {
            try w.writeAll("\"Literal\", \"value\": ");
            try writeLiteralValue(w, b.value);
        },
        .Identifier => |b| {
            try w.writeAll("\"Identifier\", \"name\": ");
            try writeJsonString(w, b.name);
        },
        .Call => |b| {
            try w.writeAll("\"Call\", \"callee\": ");
            try writeJsonString(w, b.callee);
        },
    }
    try w.print(", \"pos\": [{d}, {d}] }}", .{ n.pos[0], n.pos[1] });
}

/// One `link` → one `edge`. Field shape is unchanged (`from`/`to`
/// each a `{ node, pin }`); only the containing array's name differs.
fn writeEdge(w: *std.Io.Writer, l: flow_io.Link) !void {
    try w.print("    {{ \"from\": {{ \"node\": {d}, \"pin\": ", .{l.from.node});
    try writeJsonString(w, l.from.pin);
    try w.print(" }}, \"to\": {{ \"node\": {d}, \"pin\": ", .{l.to.node});
    try writeJsonString(w, l.to.pin);
    try w.writeAll(" } }");
}

/// Emit `s` as a double-quoted JSON string literal. `std.json`'s
/// string encoder handles the escaping (`"`, `\`, control chars) so
/// an identifier with an embedded quote round-trips as valid JSON.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// Emit a `Literal` node's `value` as a JSON-native literal when the
/// verbatim Zig text denotes one — a number (`1.0`, `42`), a boolean
/// (`true`/`false`), or `null` — matching RFC §2's example
/// (`"value": 1.0`, unquoted). Anything else (a Zig string literal,
/// an identifier-like expression) is emitted as a quoted JSON string
/// so the source text round-trips intact.
fn writeLiteralValue(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null"))
    {
        try w.writeAll(s);
        return;
    }
    if (isJsonNumber(s)) {
        try w.writeAll(s);
        return;
    }
    try writeJsonString(w, s);
}

/// True when `s` is a valid JSON number per RFC 8259 §6, so it can be
/// emitted unquoted. Rejects forms JSON disallows even though Zig
/// accepts them (leading `+`, leading zeros, leading/trailing `.`,
/// `_` digit separators, hex/octal/binary prefixes) — those fall back
/// to a quoted string.
fn isJsonNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;

    // Optional minus sign.
    if (s[i] == '-') i += 1;
    if (i == s.len) return false;

    // Integer part: a single `0`, or a non-zero digit run.
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    } else {
        return false;
    }

    // Optional fraction.
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == frac_start) return false; // `.` with no digits
    }

    // Optional exponent.
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == exp_start) return false; // exponent with no digits
    }

    return i == s.len;
}

/// `.flow.zon` → `.flow.jsonc` path rewrite. Swaps the trailing
/// extension; a path that does not end in `.flow.zon` is returned
/// unchanged-but-suffixed so the caller still gets a `.flow.jsonc`
/// output. Caller owns the returned bytes.
pub fn jsoncPathFromZon(allocator: std.mem.Allocator, zon_path: []const u8) ![]u8 {
    const zon_ext = ".flow.zon";
    const jsonc_ext = ".flow.jsonc";
    if (std.mem.endsWith(u8, zon_path, zon_ext)) {
        const stem = zon_path[0 .. zon_path.len - zon_ext.len];
        return std.mem.concat(allocator, u8, &.{ stem, jsonc_ext });
    }
    return std.mem.concat(allocator, u8, &.{ zon_path, jsonc_ext });
}

/// Read a `.flow.zon` file, convert it, and write the `.flow.jsonc`
/// result next to it. Returns the path of the file written (caller
/// owns the bytes). When `delete_source` is set, the original
/// `.flow.zon` is removed after a successful write — the RFC's
/// "hard cut" (convert + drop `.flow.zon`).
///
/// Rejects any input not ending in `.flow.zon` with
/// `error.NotAFlowZonFile` *before* touching the filesystem. This
/// guards the `delete_source` path: were a stray `foo.txt` accepted,
/// the output `foo.txt.flow.jsonc` would differ from the input and
/// the hard cut would delete the unrelated `foo.txt`.
pub fn convertFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    zon_path: []const u8,
    delete_source: bool,
) ![]u8 {
    if (!std.mem.endsWith(u8, zon_path, ".flow.zon")) {
        return error.NotAFlowZonFile;
    }

    var loaded = try flow_io.loadFromFile(io, allocator, zon_path);
    defer loaded.deinit();

    const name = flow_io.displayNameFromPath(zon_path);
    const jsonc = try flowToJsonc(allocator, loaded.flow, name);
    defer allocator.free(jsonc);

    const out_path = try jsoncPathFromZon(allocator, zon_path);
    errdefer allocator.free(out_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = jsonc });

    if (delete_source and !std.mem.eql(u8, out_path, zon_path)) {
        try std.Io.Dir.cwd().deleteFile(io, zon_path);
    }

    return out_path;
}
