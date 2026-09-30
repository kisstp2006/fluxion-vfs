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
//! A pack entry is stored in chunks, and a stream over one works them out one
//! at a time - opened when sealed, checked, and inflated when deflated - so it
//! holds one chunk however large the entry is, and a damaged chunk stops the
//! stream where it lies.

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
    pieces: PieceReader,
};

/// Bytes worked out a piece at a time by whoever made the stream - a pack
/// entry's chunks.
pub const Pieces = struct {
    ptr: *anyopaque,
    count: usize,
    /// Piece `index`, borrowed until the next call. Asked for in order.
    next: *const fn (ptr: *anyopaque, index: usize) Error![]const u8,
    /// Give back whatever `ptr` holds, when the stream is closed.
    release: *const fn (ptr: *anyopaque, gpa: Allocator) void,
};

const PieceReader = struct {
    pieces: Pieces,
    interface: Io.Reader,
    buffer: []u8,
    index: usize = 0,
    /// What is left of the piece being read.
    current: []const u8 = &.{},
    /// Why the stream stopped, when a piece could not be worked out. The
    /// reader can only say that it failed.
    failure: ?Error = null,

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *PieceReader = @alignCast(@fieldParentPtr("interface", r));
        while (self.current.len == 0) {
            if (self.index == self.pieces.count) return error.EndOfStream;
            self.current = self.pieces.next(self.pieces.ptr, self.index) catch |err| {
                self.failure = err;
                return error.ReadFailed;
            };
            self.index += 1;
        }
        const n = try w.write(limit.sliceConst(self.current));
        self.current = self.current[n..];
        return n;
    }
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

/// A stream over `pieces`, which yield `size` bytes between them. The stream
/// owns `pieces` from here on, and releases them when it is closed.
pub fn fromPieces(gpa: Allocator, size: u64, pieces: Pieces) Error!*Stream {
    const self = try gpa.create(Stream);
    errdefer gpa.destroy(self);
    const buffer = try gpa.alloc(u8, piece_buffer_len);

    self.* = .{
        .reader = undefined,
        .size = size,
        .gpa = gpa,
        .owned_file = null,
        .backing = .{ .pieces = .{
            .pieces = pieces,
            .interface = .{ .vtable = &.{ .stream = PieceReader.stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .buffer = buffer,
        } },
        .inflate = null,
        .window = &.{},
        .limit_buffer = &.{},
    };
    self.reader = &self.backing.pieces.interface;
    return self;
}

const piece_buffer_len = 4 * 1024;

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
        .pieces => |backing| {
            gpa.free(backing.buffer);
            backing.pieces.release(backing.pieces.ptr, gpa);
        },
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
        error.ReadFailed => self.failure() orelse error.Corrupt,
    };
}

/// Why the stream stopped, when the reader said only that it failed.
pub fn failure(self: *const Stream) ?Error {
    return switch (self.backing) {
        .pieces => |backing| backing.failure,
        .file, .memory => null,
    };
}
