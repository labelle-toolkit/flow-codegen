//! Minimal JSONC → JSON preprocessor.
//!
//! The RFC (`RFC-FLOWS-JSONC.md` §1) specifies that `.flow.jsonc` is
//! parsed "with the engine's existing JSONC parser (comments, trailing
//! commas)". `flow-codegen` is a standalone package — it cannot reach
//! into `labelle-engine` — so this module provides an equivalent: it
//! strips `//` line comments, `/* … */` block comments, and trailing
//! commas, leaving plain JSON that `std.json` accepts.
//!
//! The transform is purely lexical and string-aware: characters inside
//! a JSON string literal (including escaped quotes) are copied
//! verbatim, so a `//` or `,` that happens to live inside a string is
//! never mistaken for syntax.
//!
//! Comment bytes are replaced with spaces rather than deleted so byte
//! offsets are preserved — a parse error from `std.json` still points
//! at the right column.

const std = @import("std");

/// Rewrite `src` (JSONC) into plain JSON on `allocator`. The result is
//  the same length as the input; caller owns the returned slice.
pub fn strip(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, src.len);
    errdefer allocator.free(out);
    @memcpy(out, src);

    var i: usize = 0;
    while (i < out.len) {
        const c = out[i];
        if (c == '"') {
            // Copy a string literal verbatim, honouring `\"` escapes.
            i += 1;
            while (i < out.len) : (i += 1) {
                if (out[i] == '\\') {
                    i += 1; // skip the escaped char
                    continue;
                }
                if (out[i] == '"') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            // Line comment — blank to end of line.
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '*') {
            // Block comment — blank through the closing `*/`.
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            while (i < out.len) : (i += 1) {
                const end = out[i] == '*' and i + 1 < out.len and out[i + 1] == '/';
                if (out[i] != '\n') out[i] = ' ';
                if (end) {
                    out[i + 1] = ' ';
                    i += 2;
                    break;
                }
            }
            continue;
        }
        i += 1;
    }

    // Second pass: drop trailing commas — a `,` followed (modulo
    // whitespace) by `}` or `]`. Replaced with a space so offsets hold.
    i = 0;
    while (i < out.len) {
        if (out[i] == '"') {
            i += 1;
            while (i < out.len) : (i += 1) {
                if (out[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (out[i] == '"') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (out[i] == ',') {
            var j = i + 1;
            while (j < out.len and std.ascii.isWhitespace(out[j])) : (j += 1) {}
            if (j < out.len and (out[j] == '}' or out[j] == ']')) {
                out[i] = ' ';
            }
        }
        i += 1;
    }

    return out;
}

test "strips line comments" {
    const a = std.testing.allocator;
    const out = try strip(a, "{ \"a\": 1 // hi\n}");
    defer a.free(out);
    try std.testing.expectEqualStrings("{ \"a\": 1       \n}", out);
}

test "strips block comments" {
    const a = std.testing.allocator;
    const out = try strip(a, "{ /* x */ \"a\": 1 }");
    defer a.free(out);
    try std.testing.expectEqualStrings("{         \"a\": 1 }", out);
}

test "strips trailing commas" {
    const a = std.testing.allocator;
    const out = try strip(a, "[1, 2, ]");
    defer a.free(out);
    try std.testing.expectEqualStrings("[1, 2  ]", out);
}

test "leaves comment-like text inside strings alone" {
    const a = std.testing.allocator;
    const out = try strip(a, "{ \"u\": \"http://x\", \"c\": \"a,]\" }");
    defer a.free(out);
    try std.testing.expectEqualStrings("{ \"u\": \"http://x\", \"c\": \"a,]\" }", out);
}
