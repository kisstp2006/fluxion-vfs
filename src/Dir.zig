// SPDX-License-Identifier: BSD-2-Clause

//! A directory on disk, as a source.
//!
//! The loose kind of mount: what an editor writes, what a hot reload watches,
//! and the only kind that can be written to. A virtual path becomes a path
//! under this directory and nothing else - the separators are already `/`,
//! and `vpath.normalize` has already taken the `..` out, so nothing a caller
//! asks for can name a file outside the mount.
//!
//! **Case is checked, in debug builds, on the systems where it is a trap.**
//! Windows and macOS will happily open `Textures/Cursor.png` when the file is
//! called `textures/cursor.png`, and Linux will not - so a game developed on
//! one and shipped to the other breaks on a path that was wrong all along.
//! `verify_case` reads the directory and insists the name on disk is spelled
//! the way it was asked for. It costs a directory listing per component, which
//! is why it is a debug default and not a release one.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const text = @import("fluxion_text");
const Source = @import("Source.zig");
const vpath = @import("vpath.zig");

const Dir = @This();

/// The directory everything is relative to.
handle: Io.Dir,
/// Whether closing this source should close the handle. False for a handle
/// the caller opened and still owns.
owns_handle: bool,
options: Options,

pub const Options = struct {
    /// Whether `write` and `remove` do anything but return `error.ReadOnly`.
    writable: bool = false,
    /// Insist that a name on disk is spelled the way it was asked for.
    ///
    /// On by default in debug builds on Windows and macOS, whose filesystems
    /// are case-insensitive and will otherwise hide the bug until the game is
    /// on a case-sensitive one. Off elsewhere, where the filesystem already
    /// answers the question for free.
    verify_case: bool = builtin.mode == .Debug and
        (builtin.os.tag == .windows or builtin.os.tag == .macos),
};

pub const OpenError = Io.Dir.OpenError;

/// Open `path` as a mount source. The handle is closed by `deinit`.
pub fn open(io: Io, path: []const u8, options: Options) OpenError!Dir {
    const handle = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    return .{ .handle = handle, .owns_handle = true, .options = options };
}

/// Use a directory handle the caller opened and keeps. It must have been
/// opened with `.iterate = true` for `list` to work.
pub fn adopt(handle: Io.Dir, options: Options) Dir {
    return .{ .handle = handle, .owns_handle = false, .options = options };
}

pub fn close(self: *Dir, io: Io) void {
    if (self.owns_handle) self.handle.close(io);
    self.* = undefined;
}

/// The `Source` view of this directory. The pointer must outlive the source.
pub fn source(self: *Dir) Source {
    return .{ .ptr = self, .vtable = &vtable, .writable = self.options.writable };
}

const vtable: Source.VTable = .{
    .stat = statPath,
    .read = readPath,
    .list = listPaths,
    .write = writePath,
    .remove = removePath,
    .deinit = null,
};

/// A source that owns this `Dir`: closing it closes the handle and frees the
/// struct itself. What `Vfs.mountDir` hands out, and what a caller who holds
/// its own `Dir` must not use.
pub fn owning(self: *Dir) Source {
    return .{ .ptr = self, .vtable = &owning_vtable, .writable = self.options.writable };
}

const owning_vtable: Source.VTable = blk: {
    var owning_copy = vtable;
    owning_copy.deinit = destroy;
    break :blk owning_copy;
};

fn destroy(ptr: *anyopaque, io: Io, gpa: Allocator) void {
    const self: *Dir = @ptrCast(@alignCast(ptr));
    self.close(io);
    gpa.destroy(self);
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

fn statPath(ptr: *anyopaque, io: Io, path: []const u8) Source.Error!?Source.Stat {
    const self: *Dir = @ptrCast(@alignCast(ptr));

    const info = self.handle.statFile(io, path, .{}) catch |err| switch (err) {
        // Every way of saying "there is nothing there" is one answer here,
        // so a lookup can move on to the next mount.
        error.FileNotFound, error.NotDir, error.BadPathName, error.NameTooLong => return null,
        else => |remaining| return remaining,
    };
    // A directory is not an asset. Saying so here is what keeps `exists`
    // honest about a path that names a folder.
    if (info.kind != .file) return null;
    if (self.options.verify_case and !try self.caseMatches(io, path)) return null;

    return .{ .size = info.size, .mtime = info.mtime };
}

fn readPath(
    ptr: *anyopaque,
    io: Io,
    gpa: Allocator,
    path: []const u8,
    limit: Io.Limit,
) Source.Error![]u8 {
    const self: *Dir = @ptrCast(@alignCast(ptr));

    if (self.options.verify_case and !try self.caseMatches(io, path)) return error.FileNotFound;

    return self.handle.readFileAlloc(io, path, gpa, limit) catch |err| switch (err) {
        // A directory is not an asset, and neither is a path that could not
        // name one: all of them are the same "not here" a lookup moves past.
        error.NotDir, error.IsDir, error.BadPathName, error.NameTooLong => error.FileNotFound,
        error.StreamTooLong => error.TooLarge,
        else => |remaining| remaining,
    };
}

fn listPaths(ptr: *anyopaque, io: Io, glob: []const u8, into: *Source.Listing) Source.Error!void {
    const self: *Dir = @ptrCast(@alignCast(ptr));

    var walker = try self.handle.walk(into.gpa);
    defer walker.deinit();

    while (walker.next(io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A directory that went away mid-walk is not a listing failure: it is
        // a listing of what is there now, which is all a listing ever is.
        else => return,
    }) |entry| {
        if (entry.kind != .file) continue;

        // The walker reports the platform's separator; a virtual path has
        // exactly one.
        var buf: [vpath.max_len]u8 = undefined;
        if (entry.path.len > buf.len) continue;
        const name = buf[0..entry.path.len];
        for (entry.path, name) |from, *to| to.* = if (from == '\\') '/' else from;

        if (glob.len != 0 and !text.pattern.matchPath(glob, name)) continue;
        try into.add(name);
    }
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

fn writePath(ptr: *anyopaque, io: Io, path: []const u8, bytes: []const u8) Source.Error!void {
    const self: *Dir = @ptrCast(@alignCast(ptr));
    if (!self.options.writable) return error.ReadOnly;

    // The directories a save goes in may not exist on a fresh machine, and a
    // caller who has to make them itself will forget on one of the paths.
    if (text.path.dirname(path)) |parent| {
        self.handle.createDirPath(io, parent.bytes) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => return error.FileNotFound,
        };
    }

    self.handle.writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| switch (err) {
        error.NotDir, error.BadPathName, error.NameTooLong => return error.FileNotFound,
        else => |remaining| return remaining,
    };
}

fn removePath(ptr: *anyopaque, io: Io, path: []const u8) Source.Error!void {
    const self: *Dir = @ptrCast(@alignCast(ptr));
    if (!self.options.writable) return error.ReadOnly;

    return self.handle.deleteFile(io, path) catch |err| switch (err) {
        error.NotDir, error.BadPathName, error.NameTooLong => error.FileNotFound,
        else => |remaining| remaining,
    };
}

// -------------------------------------------------------------------------
// Case
// -------------------------------------------------------------------------

/// Is every component of `path` spelled on disk the way it is spelled here?
///
/// One directory listing per component, which is why this is behind an option.
/// A path that is not there at all is not a case failure - the caller's stat
/// or read will say so in its own words.
fn caseMatches(self: *Dir, io: Io, path: []const u8) Source.Error!bool {
    var parent = self.handle;
    var parent_owned = false;
    defer if (parent_owned) parent.close(io);

    var walk = text.path.components(path);
    var pending: ?[]const u8 = walk.next().?.bytes;

    while (pending) |component| {
        const next = walk.next();
        if (!try hasExactly(parent, io, component)) return false;
        pending = if (next) |n| n.bytes else null;
        if (pending == null) break;

        // Descend, and take ownership of every handle but the mount's own.
        const child = parent.openDir(io, component, .{ .iterate = true }) catch return false;
        if (parent_owned) parent.close(io);
        parent = child;
        parent_owned = true;
    }
    return true;
}

/// Does `parent` hold an entry whose name is exactly these bytes?
fn hasExactly(parent: Io.Dir, io: Io, name: []const u8) Source.Error!bool {
    var it = parent.iterate();
    while (it.next(io) catch return false) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}
