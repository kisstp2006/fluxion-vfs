// SPDX-License-Identifier: BSD-2-Clause

//! One namespace, several sources.
//!
//! A game asks for `textures/ui/cursor.png` and does not care that it came out
//! of a pack on a disc, out of a patch downloaded last night, or out of the
//! folder an artist is saving into right now. The mount table is what makes
//! those the same question.
//!
//! ```zig
//! var files: Vfs = .init(gpa);
//! defer files.deinit(io);
//!
//! _ = try files.mountPack(io, "", "assets.fxpk", .{});   // what shipped
//! _ = try files.mountDir(io, "", "patch", .{});          // what was patched
//! _ = try files.mountDir(io, "save", "saves", .{ .writable = true });
//!
//! const bytes = try files.read(io, gpa, "textures/ui/cursor.png", .limited(1 << 20));
//! ```
//!
//! **The last mount wins.** A lookup walks the table backwards, so a mount
//! added later shadows one added earlier, and the layer a patch or a mod goes
//! in is "on top" in the plain sense of the word. `Located.mount` says which
//! one actually answered, for when the question is why.
//!
//! **A mount has a prefix in the namespace**, and it is matched on component
//! boundaries: a mount at `textures` holds `textures/ui/cursor.png` and knows
//! it as `ui/cursor.png`, and never catches `textures-old/a.png`. The empty
//! prefix is the root and catches everything.
//!
//! **Writing goes to the last mount that can take it.** Most mounts are
//! read-only - a pack always is - so `write` finds the topmost writable mount
//! whose prefix matches, and says `error.ReadOnly` when there is none rather
//! than inventing somewhere to put a save.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Dir = @import("Dir.zig");
const Pack = @import("Pack.zig");
const Source = @import("Source.zig");
const vpath = @import("vpath.zig");

const Vfs = @This();

gpa: Allocator,
mounts: std.ArrayListUnmanaged(Mount) = .empty,
next_id: u32 = 1,
/// How strict to be about the names that go in. See `vpath.Rules`.
rules: vpath.Rules = .portable,

/// Which mount, for unmounting one and for saying which answered.
pub const Id = enum(u32) { _ };

pub const Mount = struct {
    id: Id,
    /// Normalized, and empty for the root.
    prefix: []const u8,
    source: Source,
    /// Whether `deinit` should free the prefix. False for the root's, which
    /// is a constant.
    owns_prefix: bool,
};

/// Where a path was found, and what is there.
pub const Located = struct {
    mount: Id,
    stat: Source.Stat,
};

pub const Error = Source.Error || vpath.Error;

pub fn init(gpa: Allocator) Vfs {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Vfs, io: Io) void {
    for (self.mounts.items) |mount_at| {
        mount_at.source.deinit(io, self.gpa);
        if (mount_at.owns_prefix) self.gpa.free(mount_at.prefix);
    }
    self.mounts.deinit(self.gpa);
    self.* = undefined;
}

// -------------------------------------------------------------------------
// Mounting
// -------------------------------------------------------------------------

/// Put `src` into the namespace under `prefix`, on top of everything already
/// there. The Vfs does not own what is behind `src` unless the source's own
/// vtable says so - see `Dir.owning`.
pub fn mount(self: *Vfs, prefix: []const u8, src: Source) Error!Id {
    var owned: []const u8 = "";
    var owns = false;
    if (prefix.len != 0) {
        var buf: [vpath.max_len]u8 = undefined;
        const normal = vpath.normalize(&buf, prefix, self.rules) catch |err| switch (err) {
            // An empty prefix is the root, however it was spelled.
            error.EmptyPath => "",
            else => return err,
        };
        if (normal.len != 0) {
            owned = try self.gpa.dupe(u8, normal);
            owns = true;
        }
    }
    errdefer if (owns) self.gpa.free(owned);

    const id: Id = @enumFromInt(self.next_id);
    try self.mounts.append(self.gpa, .{
        .id = id,
        .prefix = owned,
        .source = src,
        .owns_prefix = owns,
    });
    self.next_id += 1;
    return id;
}

/// Mount a directory on disk. The Vfs opens it, owns it, and closes it.
pub fn mountDir(
    self: *Vfs,
    io: Io,
    prefix: []const u8,
    path: []const u8,
    options: Dir.Options,
) (Error || Dir.OpenError)!Id {
    const holder = try self.gpa.create(Dir);
    errdefer self.gpa.destroy(holder);
    holder.* = try Dir.open(io, path, options);
    errdefer holder.close(io);

    return self.mount(prefix, holder.owning());
}

/// Mount a pack file. The Vfs opens it, owns it, and closes it.
pub fn mountPack(
    self: *Vfs,
    io: Io,
    prefix: []const u8,
    path: []const u8,
    options: Pack.Options,
) Error!Id {
    const holder = try self.gpa.create(Pack);
    errdefer self.gpa.destroy(holder);
    holder.* = try Pack.openFile(self.gpa, io, path, options);
    errdefer holder.deinit(io);

    return self.mount(prefix, holder.owning());
}

/// Mount a pack that is already in memory - mapped, or `@embedFile`d. The
/// bytes must outlive the mount.
pub fn mountPackBytes(
    self: *Vfs,
    prefix: []const u8,
    bytes: []const u8,
    options: Pack.Options,
) Error!Id {
    const holder = try self.gpa.create(Pack);
    errdefer self.gpa.destroy(holder);
    holder.* = try Pack.fromBytes(self.gpa, bytes, options);
    return self.mount(prefix, holder.owning());
}

/// Take a mount back out, closing whatever it owned. Unknown ids are ignored,
/// so unmounting twice is not an error.
pub fn unmount(self: *Vfs, io: Io, id: Id) void {
    for (self.mounts.items, 0..) |mount_at, i| {
        if (mount_at.id != id) continue;
        mount_at.source.deinit(io, self.gpa);
        if (mount_at.owns_prefix) self.gpa.free(mount_at.prefix);
        // Ordered, because the order is what "the last mount wins" means.
        _ = self.mounts.orderedRemove(i);
        return;
    }
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// What is at `path`, and which mount it came from. Null when no mount has it.
pub fn locate(self: *Vfs, io: Io, path: []const u8) Error!?Located {
    var buf: [vpath.max_len]u8 = undefined;
    const name = try vpath.normalize(&buf, path, self.rules);

    var i = self.mounts.items.len;
    while (i > 0) {
        i -= 1;
        const mount_at = self.mounts.items[i];
        const under = beneath(mount_at.prefix, name) orelse continue;
        if (try mount_at.source.stat(io, under)) |info| {
            return .{ .mount = mount_at.id, .stat = info };
        }
    }
    return null;
}

/// What is at `path`, or null.
pub fn stat(self: *Vfs, io: Io, path: []const u8) Error!?Source.Stat {
    const found = try self.locate(io, path) orelse return null;
    return found.stat;
}

/// Is there anything at `path`? A directory is not anything: only a file is.
pub fn exists(self: *Vfs, io: Io, path: []const u8) Error!bool {
    return try self.locate(io, path) != null;
}

/// The whole of `path`, freshly allocated, from the topmost mount that has it.
///
/// `error.FileNotFound` when no mount does, `error.TooLarge` when it is bigger
/// than `limit`.
pub fn read(
    self: *Vfs,
    io: Io,
    gpa: Allocator,
    path: []const u8,
    limit: Io.Limit,
) Error![]u8 {
    var buf: [vpath.max_len]u8 = undefined;
    const name = try vpath.normalize(&buf, path, self.rules);

    var i = self.mounts.items.len;
    while (i > 0) {
        i -= 1;
        const mount_at = self.mounts.items[i];
        const under = beneath(mount_at.prefix, name) orelse continue;
        return mount_at.source.read(io, gpa, under, limit) catch |err| switch (err) {
            // Not in this one; the next one down may have it.
            error.FileNotFound => continue,
            else => err,
        };
    }
    return error.FileNotFound;
}

/// Every path any mount has that `glob` matches, each one once, sorted. An
/// empty glob means everything. The caller frees each name and then the slice.
///
/// A name being here says the path exists, not which mount will answer for it.
/// That is `locate`'s question.
pub fn list(self: *Vfs, io: Io, gpa: Allocator, glob: []const u8) Error![][]const u8 {
    var found: Source.Listing = .init(gpa);
    errdefer found.deinit();

    // Front to back: the order does not matter to a set, and going forwards
    // keeps a partial failure easier to reason about.
    for (self.mounts.items) |mount_at| {
        found.prefix = mount_at.prefix;
        const under = if (mount_at.prefix.len == 0)
            glob
        else
            beneath(mount_at.prefix, glob) orelse blk: {
                // A glob that does not reach into this mount at all still
                // matches everything in it when it is broad enough to cover
                // the prefix itself.
                break :blk if (std.mem.startsWith(u8, glob, "**")) "" else continue;
            };
        try mount_at.source.list(io, under, &found);
    }
    found.prefix = "";
    return found.toOwnedSlice();
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Put `bytes` at `path`, in the topmost mount that will take it.
///
/// `error.ReadOnly` when no mount whose prefix matches can be written to,
/// which is the usual answer for a game with a pack and no save directory
/// mounted yet.
pub fn write(self: *Vfs, io: Io, path: []const u8, bytes: []const u8) Error!void {
    var buf: [vpath.max_len]u8 = undefined;
    const name = try vpath.normalize(&buf, path, self.rules);

    var i = self.mounts.items.len;
    while (i > 0) {
        i -= 1;
        const mount_at = self.mounts.items[i];
        if (!mount_at.source.writable()) continue;
        const under = beneath(mount_at.prefix, name) orelse continue;
        return mount_at.source.write(io, under, bytes);
    }
    return error.ReadOnly;
}

/// Take `path` out of the topmost writable mount that has it.
pub fn remove(self: *Vfs, io: Io, path: []const u8) Error!void {
    var buf: [vpath.max_len]u8 = undefined;
    const name = try vpath.normalize(&buf, path, self.rules);

    var i = self.mounts.items.len;
    while (i > 0) {
        i -= 1;
        const mount_at = self.mounts.items[i];
        if (!mount_at.source.writable()) continue;
        const under = beneath(mount_at.prefix, name) orelse continue;
        return mount_at.source.remove(io, under) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => err,
        };
    }
    return error.FileNotFound;
}

// -------------------------------------------------------------------------
// Prefixes
// -------------------------------------------------------------------------

/// `path` with `prefix` taken off, or null when it is not under it.
///
/// Matched on a component boundary, so `textures` does not catch
/// `textures-old/a.png` - which a plain `startsWith` would.
fn beneath(prefix: []const u8, path: []const u8) ?[]const u8 {
    if (prefix.len == 0) return path;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len == prefix.len) return null; // the mount point itself, not a file in it
    if (path[prefix.len] != '/') return null;
    return path[prefix.len + 1 ..];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a prefix matches on a component boundary and nowhere else" {
    try testing.expectEqualStrings("ui/a.png", beneath("", "ui/a.png").?);
    try testing.expectEqualStrings("ui/a.png", beneath("textures", "textures/ui/a.png").?);
    try testing.expectEqualStrings("a.png", beneath("textures/ui", "textures/ui/a.png").?);

    try testing.expectEqual(@as(?[]const u8, null), beneath("textures", "textures-old/a.png"));
    try testing.expectEqual(@as(?[]const u8, null), beneath("textures", "texture/a.png"));
    try testing.expectEqual(@as(?[]const u8, null), beneath("textures", "audio/a.png"));
    // The mount point itself names no file.
    try testing.expectEqual(@as(?[]const u8, null), beneath("textures", "textures"));
}
