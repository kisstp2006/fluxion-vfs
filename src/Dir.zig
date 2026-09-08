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
//!
//! **A listing starts where the glob does.** `levels/*.txt` opens `levels` and
//! walks from there; the rest of the tree is never touched. Only the part of
//! the glob before its first wildcard can be used this way, so `**/*.txt`
//! still walks everything - which is what it asked for.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const text = @import("fluxion_text");
const Source = @import("Source.zig");
const Stream = @import("Stream.zig");
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

/// Open `path` as a mount source. The handle is closed by `close`.
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
    .open = openPath,
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

fn openPath(ptr: *anyopaque, io: Io, gpa: Allocator, path: []const u8) Source.Error!*Stream {
    const self: *Dir = @ptrCast(@alignCast(ptr));

    if (self.options.verify_case and !try self.caseMatches(io, path)) return error.FileNotFound;

    const file = self.handle.openFile(io, path, .{}) catch |err| switch (err) {
        error.NotDir, error.IsDir, error.BadPathName, error.NameTooLong => return error.FileNotFound,
        else => |remaining| return remaining,
    };
    errdefer file.close(io);

    const info = try file.stat(io);
    if (info.kind != .file) return error.FileNotFound;

    return Stream.fromFile(gpa, io, file, true, 0, info.size, info.size, .none);
}

fn listPaths(ptr: *anyopaque, io: Io, glob: []const u8, into: *Source.Listing) Source.Error!void {
    const self: *Dir = @ptrCast(@alignCast(ptr));

    // The part of the glob with no wildcard in it names the directory the
    // walk can start from, so `levels/*.txt` never looks at `textures`.
    const fixed = literalPrefix(glob);
    var start = self.handle;
    var start_owned = false;
    if (fixed.len != 0) {
        start = self.handle.openDir(io, fixed, .{ .iterate = true }) catch |err| switch (err) {
            // Nothing there, so nothing to list - not an error.
            error.FileNotFound, error.NotDir, error.BadPathName, error.NameTooLong => return,
            else => |remaining| return remaining,
        };
        start_owned = true;
    }
    defer if (start_owned) start.close(io);

    var walker = try start.walk(into.gpa);
    defer walker.deinit();

    while (walker.next(io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A directory that went away mid-walk is not a listing failure: it is
        // a listing of what is there now, which is all a listing ever is.
        else => return,
    }) |entry| {
        if (entry.kind != .file) continue;

        // The walker reports the platform's separator; a virtual path has
        // exactly one. And the walk began below the mount's root, so the
        // part it began under goes back on the front.
        var buf: [vpath.max_len]u8 = undefined;
        const total = fixed.len + @intFromBool(fixed.len != 0) + entry.path.len;
        if (total > buf.len) continue;
        var at: usize = 0;
        if (fixed.len != 0) {
            @memcpy(buf[0..fixed.len], fixed);
            buf[fixed.len] = '/';
            at = fixed.len + 1;
        }
        for (entry.path, buf[at..total]) |from, *to| to.* = if (from == '\\') '/' else from;
        const name = buf[0..total];

        if (glob.len != 0 and !text.pattern.matchPath(glob, name)) continue;
        try into.add(name);
    }
}

/// The leading components of `glob` that have no wildcard in them, without a
/// trailing separator. Empty when the first component already has one.
fn literalPrefix(glob: []const u8) []const u8 {
    var end: usize = 0;
    var it = text.path.components(glob);
    while (it.next()) |component| {
        const bytes = component.bytes;
        if (std.mem.indexOfAny(u8, bytes, "*?[") != null) break;
        // The component's position in the glob, found from its pointer.
        const from = @intFromPtr(bytes.ptr) - @intFromPtr(glob.ptr);
        end = from + bytes.len;
    }
    // A glob with no wildcard at all names one file; its directory is the
    // prefix and the file name is left for the match.
    if (end == glob.len) {
        end = std.mem.lastIndexOfScalar(u8, glob, '/') orelse return "";
    }
    return glob[0..end];
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "the part of a glob a walk can start from" {
    try std.testing.expectEqualStrings("levels", literalPrefix("levels/*.txt"));
    try std.testing.expectEqualStrings("levels/one", literalPrefix("levels/one/*.txt"));
    try std.testing.expectEqualStrings("levels", literalPrefix("levels/**/*.txt"));
    try std.testing.expectEqualStrings("", literalPrefix("**/*.txt"));
    try std.testing.expectEqualStrings("", literalPrefix("*.txt"));
    try std.testing.expectEqualStrings("", literalPrefix(""));
    // A glob that is a whole file name starts in its directory.
    try std.testing.expectEqualStrings("levels", literalPrefix("levels/one.txt"));
    try std.testing.expectEqualStrings("", literalPrefix("one.txt"));
    // A character class is a wildcard too.
    try std.testing.expectEqualStrings("ui", literalPrefix("ui/[ab]*.png"));
}
