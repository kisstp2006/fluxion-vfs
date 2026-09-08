// SPDX-License-Identifier: BSD-2-Clause

//! Where bytes come from.
//!
//! A source answers three questions about a normalized virtual path - is it
//! here, how big is it, and give it to me - and optionally two more, for a
//! source that can be written to. `Dir` and `Pack` are the two that ship;
//! anything with the same five functions is one as well.
//!
//! This is a vtable rather than a duck-typed comptime interface, because a
//! mount table holds sources of different kinds in one list and is built at
//! run time from what the game found on disk. Where the set is known at
//! compile time - a resolver, a hash - this family uses duck typing instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Source = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// What a source can say about a path that is in it.
pub const Stat = struct {
    /// The size the caller will get from `read`, after any decompression.
    size: u64,
    /// When it last changed, for a source where that is a question worth
    /// asking. Null for a pack, whose contents are fixed when it is built -
    /// which is what lets `Watch` skip it entirely.
    mtime: ?Io.Timestamp = null,
};

/// Everything that can go wrong below the mount table.
///
/// The filesystem's own error sets are in here whole rather than mapped onto
/// a smaller set of this library's own: a caller who wants to tell a missing
/// file from a full disk should not have to guess which of them was folded
/// into which. `error.FileNotFound` is the one answer for "not here",
/// whether the source is a directory or a pack.
pub const Error = error{
    /// The mount that path belongs to cannot be written to.
    ReadOnly,
    /// Bigger than the limit the caller gave.
    TooLarge,
    /// A pack whose bytes do not match what its index says they are.
    Corrupt,
    /// A pack this build does not know how to read: the wrong magic, a
    /// container version from the future, or an index whose schema has moved.
    UnsupportedPack,
} || Io.File.OpenError ||
    Io.File.ReadError ||
    Io.File.WriteError ||
    Io.Dir.StatFileError ||
    Io.Dir.DeleteFileError ||
    Io.Dir.ReadFileAllocError ||
    Allocator.Error;

pub const VTable = struct {
    /// What is at `path`, or null when nothing is. `path` is normalized.
    stat: *const fn (ptr: *anyopaque, io: Io, path: []const u8) Error!?Stat,

    /// The whole of `path`, freshly allocated. `error.FileNotFound` when it
    /// is not here, so a lookup can move on to the next mount.
    read: *const fn (
        ptr: *anyopaque,
        io: Io,
        gpa: Allocator,
        path: []const u8,
        limit: Io.Limit,
    ) Error![]u8,

    /// Every path in this source that `glob` matches, appended to `into`.
    /// An empty glob means everything.
    list: *const fn (ptr: *anyopaque, io: Io, glob: []const u8, into: *Listing) Error!void,

    /// Put `bytes` at `path`, making whatever directories it needs. Null for
    /// a read-only source, which is what makes `Vfs.write` able to say
    /// `error.ReadOnly` without trying.
    write: ?*const fn (ptr: *anyopaque, io: Io, path: []const u8, bytes: []const u8) Error!void = null,

    /// Take `path` out. Null for a read-only source.
    remove: ?*const fn (ptr: *anyopaque, io: Io, path: []const u8) Error!void = null,

    /// Give back whatever the source is holding. Null for one that holds
    /// nothing of its own.
    deinit: ?*const fn (ptr: *anyopaque, io: Io, gpa: Allocator) void = null,
};

// -------------------------------------------------------------------------
// Calling one
// -------------------------------------------------------------------------

pub fn stat(self: Source, io: Io, path: []const u8) Error!?Stat {
    return self.vtable.stat(self.ptr, io, path);
}

pub fn read(self: Source, io: Io, gpa: Allocator, path: []const u8, limit: Io.Limit) Error![]u8 {
    return self.vtable.read(self.ptr, io, gpa, path, limit);
}

pub fn list(self: Source, io: Io, glob: []const u8, into: *Listing) Error!void {
    return self.vtable.list(self.ptr, io, glob, into);
}

pub fn writable(self: Source) bool {
    return self.vtable.write != null;
}

pub fn write(self: Source, io: Io, path: []const u8, bytes: []const u8) Error!void {
    const put = self.vtable.write orelse return error.ReadOnly;
    return put(self.ptr, io, path, bytes);
}

pub fn remove(self: Source, io: Io, path: []const u8) Error!void {
    const take = self.vtable.remove orelse return error.ReadOnly;
    return take(self.ptr, io, path);
}

pub fn deinit(self: Source, io: Io, gpa: Allocator) void {
    if (self.vtable.deinit) |release| release(self.ptr, io, gpa);
}

// -------------------------------------------------------------------------
// Collecting names
// -------------------------------------------------------------------------

/// The names a listing found, each one once.
///
/// The set is the point. A mount table is layers, and the same path in two
/// layers is one asset with one name - the caller wants to know that
/// `ui/cursor.png` exists, not that it exists twice. Which layer it will
/// actually come from is `Vfs.read`'s answer, not this one's.
pub const Listing = struct {
    gpa: Allocator,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Prefixed to every name a source offers, so a mount at `textures`
    /// reports the paths the caller would use to read them back.
    prefix: []const u8 = "",

    pub fn init(gpa: Allocator) Listing {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Listing) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.* = undefined;
    }

    /// The names found, sorted, borrowed until `deinit`.
    pub fn items(self: *Listing) []const []const u8 {
        std.mem.sort([]const u8, self.paths.items, {}, lessThan);
        return self.paths.items;
    }

    /// Hand over the names, sorted, and keep nothing. The caller frees each
    /// one and then the slice.
    pub fn toOwnedSlice(self: *Listing) Allocator.Error![][]const u8 {
        _ = self.items();
        self.seen.deinit(self.gpa);
        self.seen = .empty;
        return self.paths.toOwnedSlice(self.gpa);
    }

    /// Offer a name. A second offer of the same name is dropped, and neither
    /// offer keeps the caller's memory.
    pub fn add(self: *Listing, name: []const u8) Allocator.Error!void {
        var full: []const u8 = name;
        if (self.prefix.len != 0) {
            full = try std.mem.concat(self.gpa, u8, &.{ self.prefix, "/", name });
        }
        errdefer if (self.prefix.len != 0) self.gpa.free(full);

        const slot = try self.seen.getOrPut(self.gpa, full);
        if (slot.found_existing) {
            if (self.prefix.len != 0) self.gpa.free(full);
            return;
        }
        errdefer _ = self.seen.remove(full);

        const owned = if (self.prefix.len != 0) full else try self.gpa.dupe(u8, full);
        errdefer if (self.prefix.len == 0) self.gpa.free(owned);

        // The key borrows the copy the list owns, so there is one allocation
        // for each name and not two.
        slot.key_ptr.* = owned;
        try self.paths.append(self.gpa, owned);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a listing holds each name once, sorted" {
    var found: Listing = .init(testing.allocator);
    defer found.deinit();

    try found.add("ui/cursor.png");
    try found.add("audio/step.wav");
    try found.add("ui/cursor.png");
    try found.add("ui/panel.png");

    const want = [_][]const u8{ "audio/step.wav", "ui/cursor.png", "ui/panel.png" };
    const got = found.items();
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
}

test "a listing puts the mount's prefix back on" {
    var found: Listing = .init(testing.allocator);
    defer found.deinit();
    found.prefix = "textures";

    try found.add("ui/cursor.png");
    try found.add("ui/cursor.png");

    try testing.expectEqual(@as(usize, 1), found.items().len);
    try testing.expectEqualStrings("textures/ui/cursor.png", found.items()[0]);
}

test "a listing hands over what it found and keeps nothing" {
    var found: Listing = .init(testing.allocator);
    try found.add("b.png");
    try found.add("a.png");

    const owned = try found.toOwnedSlice();
    defer {
        for (owned) |p| testing.allocator.free(p);
        testing.allocator.free(owned);
    }
    found.deinit();

    try testing.expectEqualStrings("a.png", owned[0]);
    try testing.expectEqualStrings("b.png", owned[1]);
}
