// SPDX-License-Identifier: BSD-2-Clause

//! Whether anything under a directory tree has changed, from the kernel.
//!
//! `Watch` works by asking the filesystem about every watched path, which is
//! cheap for hundreds and not for tens of thousands. The operating system
//! already knows when something under a directory moves, and this asks it:
//! `ReadDirectoryChangesW` on Windows, `inotify` on Linux. What comes back is
//! deliberately one bit - *something* changed - because the two APIs disagree
//! about everything else: what a rename looks like, whether a write is one
//! event or three, what happens when their buffer overflows. The one bit is
//! what `Watch` needs to skip a poll, and the stats it then does are the
//! source of truth for what actually changed and whether it has settled.
//!
//! ```zig
//! var notify: vfs.Notify = .init(gpa);
//! defer notify.deinit();
//! try notify.add(io, "assets");     // the same path given to mountDir
//! watch.useNotify(&notify);
//! ```
//!
//! On a target with neither - macOS is one, until `std.Io` grows a watch -
//! `supported` is false, `add` says `error.Unsupported`, and `Watch` goes on
//! polling as it did.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Notify = @This();

pub const supported = switch (builtin.os.tag) {
    .windows, .linux => true,
    else => false,
};

pub const Error = error{
    /// This target has no directory notifications this library knows.
    Unsupported,
    /// The kernel would not watch the directory: it does not exist, is not
    /// a directory, or the watch table is full.
    WatchFailed,
} || Allocator.Error;

gpa: Allocator,
inner: Inner,
/// Set by `add`, so the first drain after a new directory reports it dirty
/// and the watch scans once from scratch.
dirty: bool = false,

const Inner = switch (builtin.os.tag) {
    .windows => Windows,
    .linux => Linux,
    else => struct {},
};

pub fn init(gpa: Allocator) Notify {
    return .{ .gpa = gpa, .inner = if (supported) .init(gpa) else .{} };
}

pub fn deinit(self: *Notify) void {
    if (supported) self.inner.deinit();
    self.* = undefined;
}

/// Watch the directory at `path` and everything below it. The same path a
/// `Dir` mount was opened with.
pub fn add(self: *Notify, io: Io, path: []const u8) Error!void {
    if (!supported) return error.Unsupported;
    try self.inner.add(io, path);
    self.dirty = true;
}

/// Has anything under a watched directory changed since the last call?
///
/// A kernel buffer that overflowed is a yes: the answer is then "possibly
/// everything", which is the same word.
pub fn drain(self: *Notify) bool {
    var changed = self.dirty;
    self.dirty = false;
    if (supported) changed = self.inner.drain() or changed;
    return changed;
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------

const Windows = struct {
    gpa: Allocator,
    trees: std.ArrayListUnmanaged(*Tree) = .empty,

    const win = std.os.windows;

    /// One directory handle with one overlapped read always in flight. Lives
    /// on the heap because the kernel holds pointers into it.
    const Tree = struct {
        handle: win.HANDLE,
        event: win.HANDLE,
        overlapped: Overlapped,
        /// What the kernel fills in. Sixty-four kilobytes is the largest a
        /// network directory will take, and more than a local one needs.
        buffer: [64 * 1024]u8 align(4),
    };

    fn init(gpa: Allocator) Windows {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Windows) void {
        for (self.trees.items) |tree| {
            // The read in flight has a pointer into `tree`; it must be gone
            // before the memory is.
            _ = CancelIoEx(tree.handle, &tree.overlapped);
            var got: win.DWORD = 0;
            _ = GetOverlappedResult(tree.handle, &tree.overlapped, &got, 1);
            win.CloseHandle(tree.event);
            win.CloseHandle(tree.handle);
            self.gpa.destroy(tree);
        }
        self.trees.deinit(self.gpa);
    }

    fn add(self: *Windows, io: Io, path: []const u8) Error!void {
        _ = io;
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return error.WatchFailed,
        };
        defer self.gpa.free(wide);

        const handle = CreateFileW(
            wide.ptr,
            file_list_directory,
            file_share_read | file_share_write | file_share_delete,
            null,
            open_existing,
            file_flag_backup_semantics | file_flag_overlapped,
            null,
        );
        if (handle == win.INVALID_HANDLE_VALUE) return error.WatchFailed;
        errdefer win.CloseHandle(handle);

        const event = CreateEventW(null, 1, 0, null) orelse return error.WatchFailed;
        errdefer win.CloseHandle(event);

        const tree = try self.gpa.create(Tree);
        errdefer self.gpa.destroy(tree);
        tree.* = .{
            .handle = handle,
            .event = event,
            .overlapped = .{ .hEvent = event },
            .buffer = undefined,
        };
        try issue(tree);
        try self.trees.append(self.gpa, tree);
    }

    /// Start the next read. The kernel writes into `tree.buffer` and signals
    /// `tree.event` when something has happened.
    fn issue(tree: *Tree) Error!void {
        tree.overlapped.Internal = 0;
        tree.overlapped.InternalHigh = 0;
        const ok = ReadDirectoryChangesW(
            tree.handle,
            &tree.buffer,
            tree.buffer.len,
            1, // and everything below it
            notify_filter,
            null,
            &tree.overlapped,
            null,
        );
        if (ok == 0) return error.WatchFailed;
    }

    fn drain(self: *Windows) bool {
        var changed = false;
        for (self.trees.items) |tree| {
            var got: win.DWORD = 0;
            const done = GetOverlappedResult(tree.handle, &tree.overlapped, &got, 0);
            if (done == 0) {
                // Still waiting is the usual answer. Anything else is a
                // handle that has gone bad, which reads as "changed" so the
                // watch falls back to looking for itself.
                if (@intFromEnum(win.GetLastError()) == error_io_incomplete) continue;
                changed = true;
                continue;
            }
            // Completed. Zero bytes means the buffer overflowed and the
            // kernel gave up listing, which is a change too.
            changed = true;
            _ = ResetEvent(tree.event);
            issue(tree) catch {};
        }
        return changed;
    }

    const Overlapped = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        Offset: win.DWORD = 0,
        OffsetHigh: win.DWORD = 0,
        hEvent: ?win.HANDLE,
    };

    const file_list_directory: win.DWORD = 0x0001;
    const file_share_read: win.DWORD = 0x1;
    const file_share_write: win.DWORD = 0x2;
    const file_share_delete: win.DWORD = 0x4;
    const open_existing: win.DWORD = 3;
    const file_flag_backup_semantics: win.DWORD = 0x0200_0000;
    const file_flag_overlapped: win.DWORD = 0x4000_0000;
    const error_io_incomplete = 996;

    /// Names, sizes, and last-write times: what a file being created,
    /// deleted, renamed or rewritten changes. Not last-access, which every
    /// read would trip.
    const notify_filter: win.DWORD = 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0010 | 0x0040;

    extern "kernel32" fn CreateFileW(
        lpFileName: win.LPCWSTR,
        dwDesiredAccess: win.DWORD,
        dwShareMode: win.DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: win.DWORD,
        dwFlagsAndAttributes: win.DWORD,
        hTemplateFile: ?win.HANDLE,
    ) callconv(.winapi) win.HANDLE;

    extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*anyopaque,
        bManualReset: c_int,
        bInitialState: c_int,
        lpName: ?win.LPCWSTR,
    ) callconv(.winapi) ?win.HANDLE;

    extern "kernel32" fn ResetEvent(hEvent: win.HANDLE) callconv(.winapi) c_int;

    extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: win.HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: win.DWORD,
        bWatchSubtree: c_int,
        dwNotifyFilter: win.DWORD,
        lpBytesReturned: ?*win.DWORD,
        lpOverlapped: ?*Overlapped,
        lpCompletionRoutine: ?*const anyopaque,
    ) callconv(.winapi) c_int;

    extern "kernel32" fn GetOverlappedResult(
        hFile: win.HANDLE,
        lpOverlapped: *Overlapped,
        lpNumberOfBytesTransferred: *win.DWORD,
        bWait: c_int,
    ) callconv(.winapi) c_int;

    extern "kernel32" fn CancelIoEx(
        hFile: win.HANDLE,
        lpOverlapped: ?*Overlapped,
    ) callconv(.winapi) c_int;
};

// -------------------------------------------------------------------------
// Linux
// -------------------------------------------------------------------------

const Linux = struct {
    gpa: Allocator,
    fd: i32 = -1,
    /// Each watch descriptor and the directory it stands for, so a directory
    /// created under a watched one can be watched too.
    dirs: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,

    const linux = std.os.linux;

    fn init(gpa: Allocator) Linux {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Linux) void {
        var it = self.dirs.valueIterator();
        while (it.next()) |path| self.gpa.free(path.*);
        self.dirs.deinit(self.gpa);
        if (self.fd >= 0) _ = linux.close(self.fd);
    }

    fn add(self: *Linux, io: Io, path: []const u8) Error!void {
        if (self.fd < 0) {
            const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return error.WatchFailed;
            self.fd = @intCast(rc);
        }

        // inotify watches one directory, not a tree, so every directory
        // below is added as well - and the ones made later, in `drain`.
        try self.watchOne(path);

        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return error.WatchFailed;
        defer dir.close(io);
        var walker = dir.walk(self.gpa) catch return error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const full = try std.fs.path.join(self.gpa, &.{ path, entry.path });
            defer self.gpa.free(full);
            self.watchOne(full) catch continue;
        }
    }

    fn watchOne(self: *Linux, path: []const u8) Error!void {
        const z = try self.gpa.dupeZ(u8, path);
        errdefer self.gpa.free(z);

        const rc = linux.inotify_add_watch(self.fd, z.ptr, watch_mask);
        if (linux.errno(rc) != .SUCCESS) return error.WatchFailed;
        const wd: i32 = @intCast(rc);

        const slot = try self.dirs.getOrPut(self.gpa, wd);
        if (slot.found_existing) {
            // Already watched, under the same or another name.
            self.gpa.free(z);
            return;
        }
        slot.value_ptr.* = z;
    }

    fn drain(self: *Linux) bool {
        if (self.fd < 0) return false;
        var changed = false;
        var buffer: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (true) {
            const rc = linux.read(self.fd, &buffer, buffer.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return changed,
                // A queue that overflowed, or a descriptor gone bad: both
                // read as "changed" so the watch looks for itself.
                else => return true,
            }
            const got: usize = rc;
            if (got == 0) return changed;
            changed = true;

            var at: usize = 0;
            while (at + @sizeOf(linux.inotify_event) <= got) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
                const name_len: usize = event.len;
                defer at += @sizeOf(linux.inotify_event) + name_len;

                // A new directory under a watched one gets watched too, so
                // files made inside it later are noticed.
                const is_dir = event.mask & linux.IN.ISDIR != 0;
                const appeared = event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
                if (is_dir and appeared and name_len != 0) {
                    const parent = self.dirs.get(event.wd) orelse continue;
                    const raw = buffer[at + @sizeOf(linux.inotify_event) ..][0..name_len];
                    const name = std.mem.sliceTo(raw, 0);
                    const full = std.fs.path.join(self.gpa, &.{ parent, name }) catch continue;
                    defer self.gpa.free(full);
                    self.watchOne(full) catch {};
                }
            }
        }
    }

    /// What a file being created, deleted, renamed or rewritten does, and
    /// the directory itself going away. Not access, which every read trips.
    const watch_mask: u32 = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE |
        linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
        linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a change under a watched directory is noticed, and quiet is quiet" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // A real path, because the kernel wants one. The testing tmp dir lives
    // under .zig-cache/tmp in the working directory.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(path);
    try tmp.dir.createDirPath(io, "levels");

    var notify: Notify = .init(gpa);
    defer notify.deinit();
    try notify.add(io, path);

    // Freshly added is dirty once, so the watch scans from scratch.
    try std.testing.expect(notify.drain());
    try std.testing.expect(!notify.drain());

    try tmp.dir.writeFile(io, .{ .sub_path = "levels/one.txt", .data = "one" });
    // The kernel may take a moment; give it a few tries but not a long wait.
    var seen = false;
    var tries: usize = 0;
    while (!seen and tries < 50) : (tries += 1) {
        seen = notify.drain();
        if (!seen) try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(seen);

    // One write is several events to the kernel, delivered as it pleases, so
    // quiet comes after they have all arrived - and then it stays.
    tries = 0;
    while (notify.drain() and tries < 50) : (tries += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(tries < 50);
    try std.testing.expect(!notify.drain());
}
