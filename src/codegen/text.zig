//! Source-text utilities shared between function emission (`entry.zig`)
//! and the control-flow scope walker (`scope.zig`): block re-indentation,
//! whole-identifier detection, and a small byte counter.

const std = @import("std");

/// Prepend `indent` to every non-empty line in `body` so a buffered
/// function body (rendered with the lifecycle handler's `    ` prefix)
/// nests one more level inside the new-form handler's enclosing
/// `pub fn <tag>` block. Empty lines stay empty so the output keeps a
/// clean look.
pub fn indentBlock(w: *std.Io.Writer, body: []const u8, indent: []const u8) !void {
    var it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |line| {
        if (first) {
            first = false;
        } else {
            try w.writeByte('\n');
        }
        if (line.len > 0) {
            try w.writeAll(indent);
            try w.writeAll(line);
        }
    }
}

pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// True when `ident` appears in `src` as a whole identifier token —
/// not flanked by an identifier character on either side. Lets the
/// entry-function renderer tell a referenced parameter from an unused
/// one without a real parser.
pub fn mentionsIdent(src: []const u8, ident: []const u8) bool {
    if (ident.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, ident)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(src[pos - 1]);
        const after = pos + ident.len;
        const after_ok = after >= src.len or !isIdentChar(src[after]);
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

/// Count occurrences of `c` in `s` — the shared length helper between
/// `qualifiedTagFromDotted` (allocating) and the inline `Emit` lowering
/// (allocating on a per-node scratch arena). Hoisted so both call sites
/// agree on the output-length formula `s.len + countByte(s, '.')`.
pub fn countByte(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |b| if (b == c) {
        n += 1;
    };
    return n;
}
