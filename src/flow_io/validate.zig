//! Validation pass — structural and semantic checks over a built
//! `Flow` (`model.zig`). Run by `parse.zig` after `buildFlow`; rejects
//! malformed graphs with a `ParseError` before they reach codegen.

const std = @import("std");
const model = @import("model.zig");

const Flow = model.Flow;
const Node = model.Node;
const Param = model.Param;
const Variable = model.Variable;
const Collection = model.Collection;
const CollectionKind = model.CollectionKind;
const ParseError = model.ParseError;

pub fn validate(flow: Flow) ParseError!void {
    // Unique, non-zero node ids.
    for (flow.nodes, 0..) |n, i| {
        if (n.id == 0) return error.InvalidNodeId;
        for (flow.nodes[i + 1 ..]) |m| {
            if (m.id == n.id) return error.DuplicateNodeId;
        }
    }

    // Unique param names.
    for (flow.params, 0..) |p, i| {
        for (flow.params[i + 1 ..]) |q| {
            if (std.mem.eql(u8, p.name, q.name)) return error.DuplicateParamName;
        }
    }

    // Unique variable names (RFC-FLOW-VOCABULARY §4).
    for (flow.variables, 0..) |v, i| {
        for (flow.variables[i + 1 ..]) |w| {
            if (std.mem.eql(u8, v.name, w.name)) return error.DuplicateVariableName;
        }
    }

    // Unique local names (issue #23), and no local may collide with a
    // file-scope `variables` name — a function-local shadowing a module
    // global is ambiguous (both resolve to a bare `<name>` in the same
    // scope), so reject it rather than silently shadow.
    for (flow.locals, 0..) |v, i| {
        for (flow.locals[i + 1 ..]) |w| {
            if (std.mem.eql(u8, v.name, w.name)) return error.DuplicateVariableName;
        }
        if (hasVariable(flow.variables, v.name)) return error.DuplicateVariableName;
    }

    // Unique collection names (flow-codegen#24), and no collection may
    // collide with a file-scope `variables` or a `locals` name — all four
    // lower to a bare `<name>` in the same module/function scope, so a
    // collision is ambiguous (reuse the `DuplicateVariableName` error).
    for (flow.collections, 0..) |c, i| {
        for (flow.collections[i + 1 ..]) |d| {
            if (std.mem.eql(u8, c.name, d.name)) return error.DuplicateVariableName;
        }
        if (hasVariable(flow.variables, c.name)) return error.DuplicateVariableName;
        if (hasVariable(flow.locals, c.name)) return error.DuplicateVariableName;
        // Per-shape required type fields (flow-codegen#24): a `.list`
        // needs `element`; a `.map` needs both `key` and `value`. Empty
        // strings (absent on disk) are malformed.
        switch (c.kind) {
            .list => if (c.element.len == 0) return error.MalformedCollection,
            .map => if (c.key.len == 0 or c.value.len == 0) return error.MalformedCollection,
        }
    }

    // Every edge endpoint resolves to a real node.
    for (flow.edges) |e| {
        if (!hasNode(flow.nodes, e.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, e.to.node)) return error.DanglingLink;
    }

    // Exec edges (flow-codegen#8, #21): both endpoints resolve to real
    // nodes, and the `(from kind, from pin)` pair is a valid exec source.
    // A `Branch` routes through `then`/`else`; a `ForRange`/`While` loop
    // routes its single `body` exec output (flow-codegen#21). Any other
    // source kind or pin is malformed — exec edges only originate from a
    // control-flow node's declared exec outputs.
    for (flow.exec_edges) |x| {
        if (!hasNode(flow.nodes, x.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, x.to_node)) return error.DanglingLink;
        const src = findNode(flow.nodes, x.from.node) orelse return error.DanglingLink;
        const ok = switch (src.kind) {
            .Branch => std.mem.eql(u8, x.from.pin, "then") or
                std.mem.eql(u8, x.from.pin, "else"),
            // `ForRange`/`While`/`ForEach`/`MapForEach` (flow-codegen#21,
            // #24) route their single `body` exec output.
            .ForRange, .While, .ForEach, .MapForEach => std.mem.eql(u8, x.from.pin, "body"),
            // A `Switch` routes through its `default` exec output or any
            // `case<N>` exec output (flow-codegen#22) — the N-way analogue
            // of a `Branch`'s `then`/`else`.
            .Switch => std.mem.eql(u8, x.from.pin, "default") or isCaseExecPin(x.from.pin),
            else => false,
        };
        if (!ok) return error.MalformedFlow;
    }

    // A node may be the exec-target of at most one Branch side. A node
    // wired to two exec outputs (both sides of a branch, or different
    // branches) has an ambiguous control scope — it can't lower into a
    // single `if`/`else` arm, and "run on both sides" is better expressed
    // as a top-level (unconditional) node. Reject it rather than silently
    // taking the first matching edge (flow-codegen#8).
    for (flow.exec_edges, 0..) |x, i| {
        for (flow.exec_edges[i + 1 ..]) |y| {
            if (x.to_node == y.to_node) return error.MalformedFlow;
        }
    }

    // `Param` nodes must name a declared parameter (RFC §3); `Output`
    // node names must be unique (RFC §3); Variable-touching nodes must
    // name a declared variable (RFC-FLOW-VOCABULARY §4).
    for (flow.nodes, 0..) |n, i| {
        switch (n.kind) {
            .Param => |b| {
                // A `Param` node names a declared flow param. (Post
                // RFC-PLUGIN-EVENTS phase 6 the legacy
                // `OnEvent.params` callback-arg path is gone; new-form
                // `OnEvent` flows read payload fields through wired
                // pins, not `Param` nodes.)
                if (!hasParam(flow.params, b.param))
                    return error.UnknownParam;
            },
            .Output => |b| {
                for (flow.nodes[i + 1 ..]) |m| {
                    if (m.kind == .Output and
                        std.mem.eql(u8, m.kind.Output.name, b.name))
                        return error.DuplicateOutputName;
                }
            },
            // Variable-touching nodes resolve by name against EITHER the
            // file-scope `variables` or the flow `locals` (issue #23);
            // both lower to the same bare `<name>` reference.
            .GetVariable => |b| {
                if (!hasVariable(flow.variables, b.name) and !hasVariable(flow.locals, b.name)) return error.UnknownVariable;
            },
            .SetVariable => |b| {
                if (!hasVariable(flow.variables, b.name) and !hasVariable(flow.locals, b.name)) return error.UnknownVariable;
            },
            .ChangeVariable => |b| {
                if (!hasVariable(flow.variables, b.name) and !hasVariable(flow.locals, b.name)) return error.UnknownVariable;
            },
            // `ClearVariable` / `HasValueVariable` are the nullable-only
            // operations (RFC-FLOW-VOCABULARY §4). The named variable
            // must exist (`UnknownVariable`) AND its declared `type`
            // must start with `?` — clearing or null-testing a
            // non-nullable variable is a flow-layer type error. The
            // declared `type` text is held verbatim by `Variable.type`
            // (the loader stores it as the raw Zig source), so the
            // check is a literal first-byte sniff.
            .ClearVariable => |b| {
                const v = findVariable(flow.variables, b.name) orelse
                    findVariable(flow.locals, b.name) orelse return error.UnknownVariable;
                if (v.type.len == 0 or v.type[0] != '?') return error.MalformedFlow;
            },
            .HasValueVariable => |b| {
                const v = findVariable(flow.variables, b.name) orelse
                    findVariable(flow.locals, b.name) orelse return error.UnknownVariable;
                if (v.type.len == 0 or v.type[0] != '?') return error.MalformedFlow;
            },
            // List operation nodes (flow-codegen#24) resolve their
            // `collection` field by name AND require it to be a LIST — a
            // list op on a `.map` would lower to the wrong API (bugbot).
            .ListAppend => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            .ListLength => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            .ListGet => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            .ListSet => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            .ListContains => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            .ListClear => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            .ForEach => |b| try requireCollectionKind(flow.collections, b.collection, .list),
            // Map operation nodes (flow-codegen#24, MAPS) — require a
            // MAP-kind collection (a map op on a `.list` is wrong; bugbot).
            .MapSet => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            .MapGet => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            .MapHas => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            .MapRemove => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            .MapClear => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            .MapLength => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            .MapForEach => |b| try requireCollectionKind(flow.collections, b.collection, .map),
            else => {},
        }
    }
}

pub fn hasVariable(variables: []const Variable, name: []const u8) bool {
    for (variables) |v| if (std.mem.eql(u8, v.name, name)) return true;
    return false;
}

/// Look up a declared variable by name — used by the nullable-only
/// validators (`ClearVariable` / `HasValueVariable`) that need to read
/// the declared `type` text. Returns `null` when not found.
pub fn findVariable(variables: []const Variable, name: []const u8) ?Variable {
    for (variables) |v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

pub fn hasCollection(collections: []const Collection, name: []const u8) bool {
    for (collections) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

pub fn findCollection(collections: []const Collection, name: []const u8) ?Collection {
    for (collections) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// A collection-op node must name a collection of the matching kind:
/// unknown name → `UnknownCollection`; right name, wrong kind (a list op
/// on a map or vice versa) → `MalformedCollection` (flow-codegen#24).
fn requireCollectionKind(collections: []const Collection, name: []const u8, kind: CollectionKind) ParseError!void {
    const c = findCollection(collections, name) orelse return error.UnknownCollection;
    if (c.kind != kind) return error.MalformedCollection;
}

pub fn hasNode(nodes: []const Node, id: u32) bool {
    for (nodes) |n| if (n.id == id) return true;
    return false;
}

pub fn findNode(nodes: []const Node, id: u32) ?*const Node {
    for (nodes) |*n| if (n.id == id) return n;
    return null;
}

/// True for a `Switch` exec output pin named `case<N>` (`case0`, `case1`,
/// …) — the N-way analogue of a `Branch`'s `then`/`else` (flow-codegen#22).
/// Mirrors codegen's `isCallArgPin` shape: the `case` prefix followed by
/// one-or-more decimal digits.
pub fn isCaseExecPin(pin: []const u8) bool {
    if (!std.mem.startsWith(u8, pin, "case")) return false;
    const tail = pin[4..];
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn hasParam(params: []const Param, name: []const u8) bool {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}
