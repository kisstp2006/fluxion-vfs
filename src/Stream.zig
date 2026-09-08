// SPDX-License-Identifier: BSD-2-Clause

//! An asset read a piece at a time.
//!
//! `Vfs.read` hands back the whole thing, which is right for a texture and
//! wrong for a two-gigabyte video. `Vfs.open` hands back one of these instead:
//! a `std.Io.Reader` the caller pulls from at its own pace, over whatever the
//! asset is actually stored in - a file, a range of a pack file, a slice of a
//! mapped pack, or the deflated form of any of those.
//!
//! ```zig
//! var stream = try files.open(io, gpa, "video/intro.ogv");
//! defer stream.close(io);
//! while (try stream.reader.takeDelimiter('\n')) |line| ...
//! ```
//!
//! The pieces are chained rather than copied: a pack entry in a file is a
//! `File.Reader` seeked to the entry, a `Limited` over it that stops at the
//! entry's end, and a `Decompress` over that if the entry was deflated. Each
//! piece keeps a pointer to the one below, which is why a stream lives on the
//! heap and is handed out by pointer - it cannot be moved after it is made.
//!
//! **The checksum is not verified on a stream.** The CRC is over the whole
//! entry, and a stream may be read part-way and closed. A caller that wants
//! the check reads the whole thing with `read`, which does it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Source = @import("Source.zig");

const Stream = @This();

pub const Error = Source.Error;

/// The reader to pull from. Yields `size` bytes and then end of stream.
reader: *Io.Reader,
/// How many bytes `reader` will yield in total.
size: u64,

gpa: Allocator,
/// A file this stream opened and will close. Null for a borrowed file or for
/// a stream over memory.
owned_file: ?Io.File,
backing: Backing,
/// Present when the stored bytes are deflated.
inflate: ?*std.compress.flate.Decompress,
window: []u8,
limit_buffer: []u8,

const Backing = union(enum) {
    file: struct {
        reader: Io.File.Reader,
        buffer: []u8,
        /// Stops the file reader at the end of the entry, for a range of a
        /// pack. Absent for a whole file.
        limited: ?Io.Reader.Limited,
    },
    memory: Io.Reader,
};

/// How the bytes the stream starts from are stored.
pub const Compression = enum { none, flate };

const file_buffer_len = 64 * 1024;
const limit_buffer_len = 4 * 1024;

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

/// A stream over `stored` bytes of `file` starting at `offset`, which yield
/// `size` bytes once undone. `owned` says whether closing the stream closes
/// the file.
pub fn fromFile(
    gpa: Allocator,
    io: Io,
    file: Io.File,
    owned: bool,
    offset: u64,
    stored: u64,
    size: u64,
    compression: Compression,
) Error!*Stream {
    const self = try gpa.create(Stream);
    errdefer gpa.destroy(self);

    const buffer = try gpa.alloc(u8, file_buffer_len);
    errdefer gpa.free(buffer);

    self.* = .{
        .reader = undefined,
        .size = size,
        .gpa = gpa,
        .owned_file = if (owned) file else null,
        .backing = .{ .file = .{
            .reader = .initSize(file, io, buffer, offset + stored),
            .buffer = buffer,
            .limited = null,
        } },
        .inflate = null,
        .window = &.{},
        .limit_buffer = &.{},
    };
    const backing = &self.backing.file;
    backing.reader.seekTo(offset) catch return error.Corrupt;

    var below: *Io.Reader = &backing.reader.interface;
    // A whole file ends where the file does; a range needs telling.
    if (offset != 0 or compression == .flate) {
        self.limit_buffer = try gpa.alloc(u8, limit_buffer_len);
        backing.limited = .init(below, .limited64(stored), self.limit_buffer);
        below = &backing.limited.?.interface;
    }

    try self.finish(below, compression);
    return self;
}

/// A stream over bytes already in memory, which must outlive it.
pub fn fromMemory(
    gpa: Allocator,
    stored: []const u8,
    size: u64,
    compression: Compression,
) Error!*Stream {
    const self = try gpa.create(Stream);
    errdefer gpa.destroy(self);

    self.* = .{
        .reader = undefined,
        .size = size,
        .gpa = gpa,
        .owned_file = null,
        .backing = .{ .memory = .fixed(stored) },
        .inflate = null,
        .window = &.{},
        .limit_buffer = &.{},
    };
    try self.finish(&self.backing.memory, compression);
    return self;
}

/// Put the decompressor on top if there is one, and pick the reader.
fn finish(self: *Stream, below: *Io.Reader, compression: Compression) Error!void {
    switch (compression) {
        .none => self.reader = below,
        .flate => {
            self.window = try self.gpa.alloc(u8, std.compress.flate.max_window_len);
            errdefer self.gpa.free(self.window);
            const inflate = try self.gpa.create(std.compress.flate.Decompress);
            inflate.* = .init(below, .raw, self.window);
            self.inflate = inflate;
            self.reader = &inflate.reader;
        },
    }
}

pub fn close(self: *Stream, io: Io) void {
    const gpa = self.gpa;
    if (self.inflate) |inflate| gpa.destroy(inflate);
    if (self.window.len != 0) gpa.free(self.window);
    if (self.limit_buffer.len != 0) gpa.free(self.limit_buffer);
    switch (self.backing) {
        .file => |backing| gpa.free(backing.buffer),
        .memory => {},
    }
    if (self.owned_file) |file| file.close(io);
    gpa.destroy(self);
}

/// Everything that is left, freshly allocated. For a caller who opened a
/// stream and then decided it wanted the whole thing after all.
pub fn readRemaining(self: *Stream, gpa: Allocator, limit: Io.Limit) Error![]u8 {
    if (self.size > @as(u64, @intFromEnum(limit))) return error.TooLarge;
    return self.reader.allocRemaining(gpa, limit) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.Corrupt,
    };
}
