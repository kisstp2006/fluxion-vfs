// SPDX-License-Identifier: BSD-2-Clause

//! What changed since you last asked.
//!
//! ```zig
//! var watch: Watch = .init(gpa);
//! defer watch.deinit();
//! try watch.add("textures/ui/cursor.png");
//!
//! // once a frame, or once a second - it costs a stat per watched path
//! for (try watch.poll(&files, io)) |change| switch (change.kind) {
//!     .changed, .added => try reload(change.path),
//!     .removed => drop(change.path),
//! };
//! ```
//!
//! **A change is reported once it has stopped happening.** An editor saving a
//! PNG truncates the file, writes it, and closes it, and a watcher that fired
//! on the first thing it noticed would hand the loader half a picture. So a
//! path whose size or timestamp moved is held back until it has been the same
//! for `settle`, and only then reported. The cost is that a reload happens a
//! tenth of a second after the save rather than instantly, which nobody has
//! ever noticed, and the alternative is a decoder error every second or third
//! save, which everybody does.
//!
//! **Which mount answered is part of what changed.** Mount a patch directory
//! over a pack and the bytes behind `textures/ui/cursor.png` are different
//! bytes, though nothing on either disk was touched. A watch that compared
//! only timestamps would miss it.
//!
//! **A pack is never polled.** It reports no modification time, because it has
//! none: it was built once. Paths that resolve into one are checked for having
//! moved to another mount and otherwise cost nothing.
//!
//! **Polling, with the operating system's help where it offers any.** A poll
//! is a stat per watched path, which is well under a millisecond for the few
//! hundred files a game has open during development and not for tens of
//! thousands. Give the watch a `Notify` and it asks the kernel first: when
//! nothing under any watched directory has moved and no mount has changed,
//! the poll does nothing at all. The stats remain the source of truth for
//! what changed and whether it has settled; the notification only says
//! whether there is anything to look at.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Notify = @import("Notify.zig");
const Vfs = @import("Vfs.zig");
const vpath = @import("vpath.zig");

const Watch = @This();

gpa: Allocator,
tracked: std.ArrayListUnmanaged(Tracked) = .empty,
globs: std.ArrayListUnmanaged([]const u8) = .empty,
changes: std.ArrayListUnmanaged(Change) = .empty,
/// Paths reported as removed, kept alive until the poll after the one that
/// reported them, so a `Change.path` is never a dangling pointer.
retired: std.ArrayListUnmanaged([]const u8) = .empty,

/// The kernel's word on whether anything moved, when there is one. See
/// `useNotify`.
notify: ?*Notify = null,
/// The mount table's generation at the last full scan, so a mount or unmount
/// forces one even when the kernel saw nothing.
generation: u64 = std.math.maxInt(u64),
/// Set when a path or glob was added, so the next poll scans whatever the
/// kernel says.
dirty: bool = true,

/// How long a file has to hold still before a change is believed.
///
/// A tenth of a second: longer than the gap between an editor's truncate and
/// its last write, shorter than anyone waiting for their texture to appear.
settle: i96 = 100 * std.time.ns_per_ms,

pub const Error = Vfs.Error;

const Tracked = struct {
    /// Normalized, owned.
    path: []const u8,
    /// Whether the watch keeps this path after it disappears. True for one
    /// the caller named, so its return is noticed; false for one a glob
    /// found, which the glob will find again.
    sticky: bool,
    /// What was last reported, or what was there when it was added.
    at: State,
    /// Something different, first seen at `since`, not yet reported.
    pending: ?State = null,
    since: i96 = 0,
    /// False between a `removed` report and the file coming back.
    present: bool,
};

const State = struct {
    mount: Vfs.Id,
    size: u64,
    /// Zero for a source that has no modification time, which is a pack.
    mtime: i96,

    fn eql(a: State, b: State) bool {
        return a.mount == b.mount and a.size == b.size and a.mtime == b.mtime;
    }
};

pub const Change = struct {
    /// Borrowed from the watch, and valid until the next `poll`.
    path: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// Not there before, there now. Also what a file coming back is.
        added,
        /// Different bytes behind the same path: rewritten, or shadowed by a
        /// mount that was not there before.
        changed,
        /// No mount has it any more.
        removed,
    };
};

pub fn init(gpa: Allocator) Watch {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Watch) void {
    for (self.tracked.items) |item| self.gpa.free(item.path);
    self.tracked.deinit(self.gpa);
    for (self.globs.items) |glob| self.gpa.free(glob);
    self.globs.deinit(self.gpa);
    for (self.retired.items) |path| self.gpa.free(path);
    self.retired.deinit(self.gpa);
    self.changes.deinit(self.gpa);
    self.* = undefined;
}

// -------------------------------------------------------------------------
// What to watch
// -------------------------------------------------------------------------

/// Watch one path. Adding it twice watches it once.
///
/// A path that is not there yet is watched all the same, and reported as
/// `added` when it appears - which is what a loader that failed once and
/// wants to know when the artist fixes it needs.
pub fn add(self: *Watch, path: []const u8) Error!void {
    var buf: [vpath.max_len]u8 = undefined;
    const name = try vpath.normalize(&buf, path, .portable);
    _ = try self.track(name, true);
    self.dirty = true;
}

/// Watch everything a glob matches, including files that appear later.
///
/// This costs a listing of every mount on each poll - a directory walk - so it
/// is for a development build, and `add` is for the paths a shipped game has
/// actually loaded.
pub fn addGlob(self: *Watch, glob: []const u8) Error!void {
    for (self.globs.items) |existing| {
        if (std.mem.eql(u8, existing, glob)) return;
    }
    try self.globs.append(self.gpa, try self.gpa.dupe(u8, glob));
    self.dirty = true;
}

/// Stop watching one path. A path a glob still matches comes back on the next
/// poll, as `added`.
pub fn forget(self: *Watch, path: []const u8) void {
    var buf: [vpath.max_len]u8 = undefined;
    const name = vpath.normalize(&buf, path, .portable) catch return;
    for (self.tracked.items, 0..) |item, i| {
        if (!std.mem.eql(u8, item.path, name)) continue;
        self.gpa.free(item.path);
        _ = self.tracked.swapRemove(i);
        return;
    }
}

/// Let the kernel say when a poll can be skipped. The `Notify` must outlive
/// the watch, and must have been given every directory a watched path can
/// resolve into; one it was not given is a directory whose changes are missed
/// until a mount changes or a path is added.
pub fn useNotify(self: *Watch, notify: *Notify) void {
    self.notify = notify;
    self.dirty = true;
}

/// How many paths are being watched.
pub fn count(self: *const Watch) usize {
    return self.tracked.items.len;
}

// -------------------------------------------------------------------------
// Asking
// -------------------------------------------------------------------------

/// What has changed since the last call.
///
/// The result borrows the watch and is valid until the next `poll` or
/// `deinit`. An empty slice is the usual answer and costs one stat per watched
/// path.
pub fn poll(self: *Watch, files: *Vfs, io: Io) Error![]const Change {
    // Last poll's removed paths have now been seen.
    for (self.retired.items) |path| self.gpa.free(path);
    self.retired.clearRetainingCapacity();
    self.changes.clearRetainingCapacity();

    const now = Io.Timestamp.now(io, .awake).nanoseconds;

    // With the kernel's word that nothing moved and no mount having changed,
    // the only paths worth a look are the ones part-way through settling.
    var everything = self.dirty or files.generation != self.generation;
    if (self.notify) |notify| {
        if (notify.drain()) everything = true;
    } else everything = true;
    self.dirty = false;
    self.generation = files.generation;

    if (everything) try self.scanGlobs(files, io);

    var i: usize = 0;
    while (i < self.tracked.items.len) {
        if (!everything and self.tracked.items[i].pending == null) {
            i += 1;
            continue;
        }
        const gone = try self.check(&self.tracked.items[i], files, io, now);
        if (gone) {
            // The path is reported this poll and freed at the start of the
            // next, so the `Change` pointing at it stays good.
            const item = self.tracked.swapRemove(i);
            try self.retired.append(self.gpa, item.path);
            continue;
        }
        i += 1;
    }
    return self.changes.items;
}

/// Look at one tracked path. Returns true when it should stop being tracked.
fn check(self: *Watch, item: *Tracked, files: *Vfs, io: Io, now: i96) Error!bool {
    const found = files.locate(io, item.path) catch |err| switch (err) {
        // A path that stopped being a path at all - which cannot happen for
        // one this watch normalized - is not a change, it is a mistake, and
        // the caller hears about it from `read`.
        error.PathTooLong, error.EmptyPath, error.EscapesRoot, error.NotUtf8, error.NotPortable => return false,
        else => |remaining| return remaining,
    };

    const at = found orelse {
        if (!item.present) return false;
        item.present = false;
        item.pending = null;
        try self.changes.append(self.gpa, .{ .path = item.path, .kind = .removed });
        return !item.sticky;
    };

    const seen: State = .{
        .mount = at.mount,
        .size = at.stat.size,
        .mtime = if (at.stat.mtime) |t| t.nanoseconds else 0,
    };

    if (!item.present) {
        item.present = true;
        item.at = seen;
        item.pending = null;
        try self.changes.append(self.gpa, .{ .path = item.path, .kind = .added });
        return false;
    }

    if (seen.eql(item.at)) {
        // Whatever was moving has moved back. Nothing happened.
        item.pending = null;
        return false;
    }

    if (item.pending) |waiting| {
        if (!seen.eql(waiting)) {
            // Still being written: start the clock again on what it is now.
            item.pending = seen;
            item.since = now;
            return false;
        }
        if (now - item.since < self.settle) return false;

        item.at = seen;
        item.pending = null;
        try self.changes.append(self.gpa, .{ .path = item.path, .kind = .changed });
        return false;
    }

    item.pending = seen;
    item.since = now;
    return false;
}

/// Add anything a glob matches that is not tracked yet. The `added` report for
/// it comes from `check`, because a file found here has not been seen before
/// and so is not present.
fn scanGlobs(self: *Watch, files: *Vfs, io: Io) Error!void {
    for (self.globs.items) |glob| {
        const found = try files.list(io, self.gpa, glob);
        defer {
            for (found) |path| self.gpa.free(path);
            self.gpa.free(found);
        }
        for (found) |path| _ = try self.track(path, false);
    }
}

/// Track `name` if it is not tracked already. A newly tracked path starts out
/// absent, so the first poll that sees it reports it as `added`.
fn track(self: *Watch, name: []const u8, sticky: bool) Error!bool {
    for (self.tracked.items) |*item| {
        // A path a glob found and the caller then named explicitly should
        // survive being removed, so stickiness only ever goes on.
        if (std.mem.eql(u8, item.path, name)) {
            if (sticky) item.sticky = true;
            return false;
        }
    }

    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    try self.tracked.append(self.gpa, .{
        .path = owned,
        .sticky = sticky,
        .at = .{ .mount = @enumFromInt(0), .size = 0, .mtime = 0 },
        .present = false,
    });
    return true;
}
