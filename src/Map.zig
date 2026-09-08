// SPDX-License-Identifier: BSD-2-Clause

//! A file, as memory.
//!
//! `std.Io` has no memory mapping yet, so this talks to the operating system
//! directly: `mmap` where there is one, and a section object on Windows. What
//! comes back is a read-only slice the kernel pages in as it is touched, which
//! is what lets a pack of any size be opened in the time it takes to read its
//! index, and lets an entry stored without compression be handed out as a
//! slice of the file rather than a copy of it.
//!
//! `supported` is false on targets that have neither - WASI among them - and
//! `open` returns `error.Unsupported` there rather than failing to compile, so
//! a caller can fall back to `Pack.openFile` with one `if`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Map = @This();

/// The mapped file. Read-only; writing to it is a fault.
bytes: []const u8,
/// What the platform needs to take the mapping down again.
handle: Handle,

pub const supported = switch (builtin.os.tag) {
    .windows, .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .haiku => true,
    else => false,
};

pub const Error = error{
    /// This target has no way to map a file.
    Unsupported,
    /// The file has no bytes, and a mapping of nothing is an error on every
    /// platform.
    Empty,
    /// The platform refused. Out of address space, or a file on a filesystem
    /// that cannot be mapped.
    MappingFailed,
} || Io.File.OpenError || Io.File.StatError;

const Handle = switch (builtin.os.tag) {
    .windows => struct { section: std.os.windows.HANDLE },
    else => struct {},
};

/// Map the whole of the file at `path`.
///
/// The file is closed again before this returns: a mapping keeps what it needs
/// alive on its own, on every platform that has one.
pub fn open(io: Io, path: []const u8) Error!Map {
    if (!supported) return error.Unsupported;

    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return fromFile(io, file);
}

/// Map an open file. The caller may close `file` once this returns.
pub fn fromFile(io: Io, file: Io.File) Error!Map {
    if (!supported) return error.Unsupported;

    const size = (try file.stat(io)).size;
    if (size == 0) return error.Empty;
    if (size > std.math.maxInt(usize)) return error.MappingFailed;
    const len: usize = @intCast(size);

    switch (builtin.os.tag) {
        .windows => {
            const section = CreateFileMappingW(file.handle, null, page_readonly, 0, 0, null) orelse
                return error.MappingFailed;
            errdefer std.os.windows.CloseHandle(section);
            const base = MapViewOfFile(section, file_map_read, 0, 0, len) orelse
                return error.MappingFailed;
            return .{ .bytes = base[0..len], .handle = .{ .section = section } };
        },
        else => {
            const bytes = std.posix.mmap(
                null,
                len,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            ) catch return error.MappingFailed;
            return .{ .bytes = bytes, .handle = .{} };
        },
    }
}

pub fn deinit(self: *Map) void {
    switch (builtin.os.tag) {
        .windows => {
            _ = UnmapViewOfFile(self.bytes.ptr);
            std.os.windows.CloseHandle(self.handle.section);
        },
        else => {
            if (supported) std.posix.munmap(@alignCast(self.bytes));
        },
    }
    self.* = undefined;
}

// -------------------------------------------------------------------------
// Windows
// -------------------------------------------------------------------------
//
// Declared here because `std.os.windows` no longer carries the Win32 file
// mapping calls. These are the documented kernel32 entry points and have not
// changed since Windows NT.

const page_readonly: std.os.windows.DWORD = 0x02;
const file_map_read: std.os.windows.DWORD = 0x0004;

extern "kernel32" fn CreateFileMappingW(
    hFile: std.os.windows.HANDLE,
    lpAttributes: ?*anyopaque,
    flProtect: std.os.windows.DWORD,
    dwMaximumSizeHigh: std.os.windows.DWORD,
    dwMaximumSizeLow: std.os.windows.DWORD,
    lpName: ?std.os.windows.LPCWSTR,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: std.os.windows.HANDLE,
    dwDesiredAccess: std.os.windows.DWORD,
    dwFileOffsetHigh: std.os.windows.DWORD,
    dwFileOffsetLow: std.os.windows.DWORD,
    dwNumberOfBytesToMap: std.os.windows.SIZE_T,
) callconv(.winapi) ?[*]const u8;

extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: *const anyopaque,
) callconv(.winapi) c_int;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a mapped file is the file" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.bin", .data = "mapped bytes, read through the page cache" });

    const file = try tmp.dir.openFile(io, "a.bin", .{});
    var map = try fromFile(io, file);
    file.close(io); // the mapping outlives the handle
    defer map.deinit();

    try std.testing.expectEqualStrings("mapped bytes, read through the page cache", map.bytes);
}

test "a file with nothing in it cannot be mapped, and says so" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.bin", .data = "" });

    const file = try tmp.dir.openFile(io, "empty.bin", .{});
    defer file.close(io);
    try std.testing.expectError(error.Empty, fromFile(io, file));
}
