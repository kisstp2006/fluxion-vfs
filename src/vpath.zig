// SPDX-License-Identifier: BSD-2-Clause

//! What a virtual path is, and what it is not.
//!
//! Every path that goes into this library goes through `normalize` first, and
//! what comes out is the one spelling that path has: components separated by
//! `/`, no `.` or `..` left in it, no repeated separators, no leading or
//! trailing one. `"textures//ui/../ui/cursor.png"` and `"textures/ui/cursor.png"`
//! are the same asset, and a cache keyed on the second will not miss on the
//! first.
//!
//! **A virtual path is always relative to the root of the namespace**, so a
//! leading `/` is accepted and dropped rather than meaning something else.
//! There is nothing above the root, so a `..` that would climb past it is an
//! error - almost always a path built by joining something to a string that
//! already ended in a separator.
//!
//! **And it is checked for being a file name somewhere else, too.** A path
//! that works on the machine it was authored on and fails on the machine the
//! game ships to is the expensive kind of bug, so the characters Windows will
//! not take, the device names it reserves, and the trailing dots and spaces it
//! silently strips are refused here, on every platform, at the point the path
//! is first seen. See `Rules`.

const std = @import("std");
const text = @import("fluxion_text");

/// The longest a normalized path may be.
///
/// Not a filesystem's limit - it is this library's, chosen so a path fits in
/// a stack buffer at every level and no lookup needs the heap.
pub const max_len = 1024;

pub const Error = error{
    /// Longer than `max_len` once normalized.
    PathTooLong,
    /// Empty, or nothing but separators and `.` components.
    EmptyPath,
    /// A `..` that would climb above the root of the namespace.
    EscapesRoot,
    /// Not valid UTF-8. A name that is not text will not survive being
    /// written into a pack on one machine and taken out on another.
    NotUtf8,
    /// A character, a component, or an ending that some filesystem this may
    /// one day run on will not take. See `Rules`.
    NotPortable,
};

/// How strict to be about names that only work on some platforms.
pub const Rules = enum {
    /// Refuse anything that would not be a file name on Windows as well as on
    /// a Unix: the characters `<>:"|?*`, control bytes, the reserved device
    /// names (`CON`, `NUL`, `COM1` and the rest), and a component ending in a
    /// dot or a space.
    ///
    /// The default, and on Windows as well as elsewhere: a path is refused on
    /// the machine it is authored on rather than on the machine it ships to.
    portable,
    /// Refuse only what this library cannot represent: a NUL byte, and bytes
    /// that are not UTF-8.
    lax,
};

/// A normalized path held inline, for a caller that needs to keep one without
/// an allocator.
pub const Buffer = struct {
    bytes: [max_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *Buffer, p: []const u8, rules: Rules) Error!void {
        self.len = (try normalize(&self.bytes, p, rules)).len;
    }
};

/// Normalize `p` into `buf`, returning the part of `buf` that was written.
///
/// The result borrows `buf`, so it lives exactly as long as the caller's
/// buffer does. Give it one of `max_len` bytes and no input can overflow it.
pub fn normalize(buf: []u8, p: []const u8, rules: Rules) Error![]const u8 {
    if (!text.utf8.validate(p)) return error.NotUtf8;

    // A leading separator is dropped rather than being made meaningful: there
    // is nothing above the root to be absolute against.
    var start: usize = 0;
    while (start < p.len and text.path.isSeparator(p[start])) start += 1;

    const written = text.path.normalizeBuf(buf, p[start..]) catch |err| switch (err) {
        error.NoSpace => return error.PathTooLong,
        error.EscapesRoot => return error.EscapesRoot,
    };
    if (written.len > max_len) return error.PathTooLong;
    if (written.len == 0 or std.mem.eql(u8, written, ".")) return error.EmptyPath;

    // A relative path keeps its leading `..`, which for a namespace with
    // nothing above its root means the same thing as escaping it.
    if (std.mem.eql(u8, written, "..") or std.mem.startsWith(u8, written, "../")) {
        return error.EscapesRoot;
    }

    try check(written, rules);
    return written;
}

/// Is `p` already exactly what `normalize` would produce?
///
/// For an assertion at a boundary where the path came from somewhere that
/// should already have normalized it, without paying for a second pass in a
/// release build.
pub fn isNormal(p: []const u8, rules: Rules) bool {
    var buf: [max_len]u8 = undefined;
    const written = normalize(&buf, p, rules) catch return false;
    return std.mem.eql(u8, written, p);
}

/// Check an already-normalized path against `rules`.
fn check(p: []const u8, rules: Rules) Error!void {
    var it = text.path.components(p);
    while (it.next()) |component| {
        const name = component.bytes;
        for (name) |c| {
            if (c == 0) return error.NotPortable;
            if (rules == .lax) continue;
            // The characters Windows refuses in a name, minus the separators,
            // which are not in a component to begin with.
            if (c < 0x20 or c == '<' or c == '>' or c == ':' or
                c == '"' or c == '|' or c == '?' or c == '*')
            {
                return error.NotPortable;
            }
        }
        if (rules == .lax) continue;

        // Windows strips a trailing dot or space and then opens a different
        // file than the one that was asked for.
        const last = name[name.len - 1];
        if (last == '.' or last == ' ') return error.NotPortable;

        if (isReservedName(name)) return error.NotPortable;
    }
}

/// The device names Windows reserves, which open a device rather than a file
/// whatever directory they are in and whatever extension follows.
fn isReservedName(name: []const u8) bool {
    // The name is reserved up to the first dot: `NUL.txt` is the null device.
    const stem_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const base = name[0..stem_end];
    if (base.len < 3 or base.len > 4) return false;

    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
        if (base.len == 3 and std.ascii.eqlIgnoreCase(base, reserved)) return true;
    }
    if (base.len == 4 and (std.ascii.eqlIgnoreCase(base[0..3], "COM") or
        std.ascii.eqlIgnoreCase(base[0..3], "LPT")))
    {
        return base[3] >= '1' and base[3] <= '9';
    }
    return false;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn expectNormal(want: []const u8, from: []const u8) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(want, try normalize(&buf, from, .portable));
}

test "one path has one spelling" {
    try expectNormal("textures/ui/cursor.png", "textures/ui/cursor.png");
    try expectNormal("textures/ui/cursor.png", "/textures/ui/cursor.png");
    try expectNormal("textures/ui/cursor.png", "textures//ui///cursor.png");
    try expectNormal("textures/ui/cursor.png", "textures/ui/../ui/cursor.png");
    try expectNormal("textures/ui/cursor.png", "./textures/./ui/cursor.png");
    try expectNormal("textures/ui/cursor.png", "textures/ui/cursor.png/");
    // A backslash is a separator on the way in and never on the way out.
    try expectNormal("textures/ui/cursor.png", "textures" ++ [_]u8{0x5C} ++ "ui/cursor.png");
    try expectNormal("a", "a");
}

test "what there is no path for" {
    var buf: [max_len]u8 = undefined;
    try testing.expectError(error.EmptyPath, normalize(&buf, "", .portable));
    try testing.expectError(error.EmptyPath, normalize(&buf, "/", .portable));
    try testing.expectError(error.EmptyPath, normalize(&buf, ".", .portable));
    try testing.expectError(error.EmptyPath, normalize(&buf, "a/..", .portable));
    // Nothing above the root, so a `..` that reaches it is an error rather
    // than a quiet no-op.
    try testing.expectError(error.EscapesRoot, normalize(&buf, "..", .portable));
    try testing.expectError(error.EscapesRoot, normalize(&buf, "../etc/passwd", .portable));
    try testing.expectError(error.EscapesRoot, normalize(&buf, "a/../../b", .portable));
    try testing.expectError(error.EscapesRoot, normalize(&buf, "/../a", .portable));
}

test "a path longer than the buffer it has to fit in" {
    var buf: [max_len]u8 = undefined;
    var long: [max_len + 10]u8 = undefined;
    @memset(&long, 'a');
    try testing.expectError(error.PathTooLong, normalize(&buf, &long, .portable));

    // And a small buffer says the same thing, rather than writing past it.
    var small: [8]u8 = undefined;
    try testing.expectError(error.PathTooLong, normalize(&small, "textures/ui/cursor.png", .portable));
}

test "a name that is not text" {
    var buf: [max_len]u8 = undefined;
    try testing.expectError(error.NotUtf8, normalize(&buf, &[_]u8{ 'a', 0xFF, 'b' }, .portable));
    try testing.expectError(error.NotUtf8, normalize(&buf, &[_]u8{ 0xC3, 0x28 }, .portable));
    // Text that happens not to be ASCII is fine, and stays as it was.
    try expectNormal("textúrák/kurzor.png", "textúrák/kurzor.png");
}

test "a name that only works on the machine it was authored on" {
    var buf: [max_len]u8 = undefined;
    for ([_][]const u8{
        "textures/a:b.png",
        "textures/what?.png",
        "textures/star*.png",
        "textures/pipe|.png",
        "ui/CON",
        "ui/nul.txt",
        "ui/COM1.png",
        "ui/LPT9",
        "trailing./a.png",
        "trailing /a.png",
    }) |bad| {
        try testing.expectError(error.NotPortable, normalize(&buf, bad, .portable));
    }

    // Names that only look reserved.
    try expectNormal("ui/CONSOLE.png", "ui/CONSOLE.png");
    try expectNormal("ui/COM0.png", "ui/COM0.png");
    try expectNormal("ui/nulls.txt", "ui/nulls.txt");

    // And `lax` takes them all, because some namespace somewhere is not a
    // filesystem at all.
    try testing.expectEqualStrings("ui/CON", try normalize(&buf, "ui/CON", .lax));
    try testing.expectEqualStrings("a:b.png", try normalize(&buf, "a:b.png", .lax));
    // A NUL byte is refused whatever the rules, because it is where a C
    // string ends and this library cannot promise what happens after it.
    try testing.expectError(error.NotPortable, normalize(&buf, &[_]u8{ 'a', 0, 'b' }, .lax));
}

test "isNormal agrees with normalize" {
    try testing.expect(isNormal("textures/ui/cursor.png", .portable));
    try testing.expect(!isNormal("/textures/ui/cursor.png", .portable));
    try testing.expect(!isNormal("textures//cursor.png", .portable));
    try testing.expect(!isNormal("", .portable));
    try testing.expect(!isNormal("ui/CON", .portable));
    try testing.expect(isNormal("ui/CON", .lax));
}

test "a path held inline needs no allocator" {
    var held: Buffer = .{};
    try held.set("/textures/../textures/ui/cursor.png", .portable);
    try testing.expectEqualStrings("textures/ui/cursor.png", held.slice());
}
