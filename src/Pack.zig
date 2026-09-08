// SPDX-License-Identifier: BSD-2-Clause

//! One file holding many, as a source.
//!
//! The shipped kind of mount. A pack is built once by a tool and never
//! changed, which is what lets it answer a lookup with a binary search over an
//! index that is already in memory, and lets `Watch` skip it entirely.
//!
//! ```
//! FXPK                 four bytes, so a file that is not one is noticed at once
//! version              one byte: the container's own
//! flags                one byte, none in use yet
//! reserved             two bytes of zero, to keep the blobs eight-aligned
//! blobs                every entry's bytes, in the order they were added
//! index                a fluxion-data document holding the entries
//! index offset         eight bytes, little endian: the last eight in the file
//! ```
//!
//! **The index is a fluxion-data document**, which is where the schema
//! fingerprint comes from. Add a field to `Entry` and every pack written by
//! the old build says `error.UnsupportedPack` instead of being read as
//! something it is not - and that check costs nothing, because it is eight
//! bytes that were going to be read anyway.
//!
//! **The offset is at the end, not the front.** A packer that had to write the
//! index first would have to know every compressed size before compressing
//! anything, and so would have to hold the whole pack in memory. Writing the
//! blobs as they arrive and the index after them means a pack of any size is
//! built with one entry in memory at a time.
//!
//! **A pack can be read from memory or from a file.** `fromBytes` is for one
//! that is already there - mapped, or `@embedFile`d. `openFile` keeps the file
//! open, holds only the index, and reads each entry from where it lies, which
//! is what a multi-gigabyte pack of textures wants.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hashing = @import("fluxion_hash");
const fxdata = @import("fluxion_data");

const Source = @import("Source.zig");
const vpath = @import("vpath.zig");
const glob_match = @import("fluxion_text").pattern;

const Pack = @This();

/// The four bytes every pack starts with.
pub const magic = [4]u8{ 'F', 'X', 'P', 'K' };

/// The container's own version, which is not the index's schema. It changes
/// when the framing changes, which it has not yet.
pub const format_version: u8 = 1;

/// Magic, version, flags, and two bytes that keep the first blob aligned.
pub const header_size = 8;

/// The index offset, at the very end.
pub const footer_size = 8;

/// How an entry's bytes are stored.
pub const Compression = enum(u8) {
    /// As they are.
    none,
    /// Deflated, in the raw container - a pack has its own checksum and does
    /// not need zlib's.
    flate,
};

/// What the index says about one entry. The order of these fields is part of
/// the format, because it is what the fingerprint is taken over.
pub const Entry = struct {
    /// Normalized, and unique within the pack.
    path: []const u8,
    /// Where the stored bytes begin, from the start of the file.
    offset: u64,
    /// How many bytes are in the file.
    stored: u64,
    /// How many bytes come back out.
    size: u64,
    /// CRC-32 of the bytes that come out, not of the ones that go in - so a
    /// pack whose compressor was buggy is caught as well as one whose disk is.
    checksum: u32,
    compression: Compression,
};

const Index = struct { entries: []const Entry };

pub const Error = Source.Error;

pub const Options = struct {
    /// Check each entry's bytes against its checksum on the way out.
    ///
    /// On, because a pack is the thing that arrives over a network or off a
    /// disc, and the alternative to a message is a texture full of noise. Off
    /// for a pack that came from somewhere already checked, or for a profile
    /// run where the CRC is the thing being measured.
    verify: bool = true,
};

gpa: Allocator,
options: Options,
/// Owns the entries and the bytes of their paths.
index: fxdata.Decoded(Index),
storage: Storage,

pub const Storage = union(enum) {
    /// Bytes the caller owns, which must outlive the pack.
    memory: []const u8,
    /// A file this pack opened and will close.
    owned_file: Io.File,
    /// A file the caller opened and will close.
    borrowed_file: Io.File,
};

// -------------------------------------------------------------------------
// Opening
// -------------------------------------------------------------------------

/// Read a pack that is already in memory. `bytes` must outlive the pack.
pub fn fromBytes(gpa: Allocator, bytes: []const u8, options: Options) Error!Pack {
    if (bytes.len < header_size + footer_size) return error.UnsupportedPack;
    try checkHeader(bytes[0..header_size]);

    const at = std.mem.readInt(u64, bytes[bytes.len - footer_size ..][0..8], .little);
    if (at < header_size or at > bytes.len - footer_size) return error.Corrupt;

    const index = try readIndex(gpa, bytes[@intCast(at) .. bytes.len - footer_size]);
    errdefer freeIndex(gpa, index);
    try checkEntries(index.value.entries, at);

    return .{
        .gpa = gpa,
        .options = options,
        .index = index,
        .storage = .{ .memory = bytes },
    };
}

/// Open a pack file, keeping it open and holding only the index.
pub fn openFile(gpa: Allocator, io: Io, path: []const u8, options: Options) Error!Pack {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    var pack = try fromFile(gpa, io, file, options);
    pack.storage = .{ .owned_file = file };
    return pack;
}

/// Read the index of a file the caller opened and keeps.
pub fn fromFile(gpa: Allocator, io: Io, file: Io.File, options: Options) Error!Pack {
    const end = (try file.stat(io)).size;
    if (end < header_size + footer_size) return error.UnsupportedPack;

    var head: [header_size]u8 = undefined;
    try readExactly(file, io, &head, 0);
    try checkHeader(&head);

    var tail: [footer_size]u8 = undefined;
    try readExactly(file, io, &tail, end - footer_size);
    const at = std.mem.readInt(u64, &tail, .little);
    if (at < header_size or at > end - footer_size) return error.Corrupt;

    const encoded = try gpa.alloc(u8, @intCast(end - footer_size - at));
    defer gpa.free(encoded);
    try readExactly(file, io, encoded, at);

    const index = try readIndex(gpa, encoded);
    errdefer freeIndex(gpa, index);
    try checkEntries(index.value.entries, at);

    return .{
        .gpa = gpa,
        .options = options,
        .index = index,
        .storage = .{ .borrowed_file = file },
    };
}

pub fn deinit(self: *Pack, io: Io) void {
    freeIndex(self.gpa, self.index);
    switch (self.storage) {
        .owned_file => |file| file.close(io),
        .memory, .borrowed_file => {},
    }
    self.* = undefined;
}

/// The `Source` view of this pack. The pointer must outlive the source.
pub fn source(self: *Pack) Source {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Source.VTable = .{
    .stat = statPath,
    .read = readPath,
    .list = listPaths,
    // A pack is written once by a tool and read many times by a game. Making
    // it writable would mean rewriting the index and moving every blob after
    // the one that changed, which is what the loose directory mount above it
    // is for.
    .write = null,
    .remove = null,
    .deinit = null,
};

/// A source that owns this `Pack`: closing it closes whatever the pack opened
/// and frees the struct itself. What `Vfs.mountPack` hands out.
pub fn owning(self: *Pack) Source {
    return .{ .ptr = self, .vtable = &owning_vtable };
}

const owning_vtable: Source.VTable = blk: {
    var owning_copy = vtable;
    owning_copy.deinit = destroy;
    break :blk owning_copy;
};

fn destroy(ptr: *anyopaque, io: Io, gpa: Allocator) void {
    const self: *Pack = @ptrCast(@alignCast(ptr));
    self.deinit(io);
    gpa.destroy(self);
}

// -------------------------------------------------------------------------
// Looking things up
// -------------------------------------------------------------------------

/// The entries, sorted by path.
pub fn entries(self: *const Pack) []const Entry {
    return self.index.value.entries;
}

/// The entry at `path`, or null. A binary search, which is what sorting the
/// index at build time buys.
pub fn find(self: *const Pack, path: []const u8) ?*const Entry {
    const all = self.entries();
    var low: usize = 0;
    var high: usize = all.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, all[middle].path, path)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return &all[middle],
        }
    }
    return null;
}

fn statPath(ptr: *anyopaque, io: Io, path: []const u8) Error!?Source.Stat {
    _ = io;
    const self: *Pack = @ptrCast(@alignCast(ptr));
    const entry = self.find(path) orelse return null;
    // No mtime: a pack does not change, and saying so is what lets a watch
    // ignore every path that resolves into one.
    return .{ .size = entry.size, .mtime = null };
}

fn readPath(
    ptr: *anyopaque,
    io: Io,
    gpa: Allocator,
    path: []const u8,
    limit: Io.Limit,
) Error![]u8 {
    const self: *Pack = @ptrCast(@alignCast(ptr));
    const entry = self.find(path) orelse return error.FileNotFound;
    if (entry.size > @as(u64, @intFromEnum(limit))) return error.TooLarge;

    const out = try self.take(gpa, io, entry.*);
    errdefer gpa.free(out);

    if (self.options.verify) {
        var crc: hashing.Crc32 = .init();
        crc.update(out);
        if (crc.final() != entry.checksum) return error.Corrupt;
    }
    return out;
}

fn listPaths(ptr: *anyopaque, io: Io, glob: []const u8, into: *Source.Listing) Error!void {
    _ = io;
    const self: *Pack = @ptrCast(@alignCast(ptr));
    for (self.entries()) |entry| {
        if (glob.len != 0 and !glob_match.matchPath(glob, entry.path)) continue;
        try into.add(entry.path);
    }
}

/// The bytes of one entry, decompressed if they were compressed.
fn take(self: *const Pack, gpa: Allocator, io: Io, entry: Entry) Error![]u8 {
    switch (entry.compression) {
        .none => {
            if (entry.stored != entry.size) return error.Corrupt;
            switch (self.storage) {
                .memory => |bytes| {
                    return gpa.dupe(u8, bytes[@intCast(entry.offset)..][0..@intCast(entry.size)]);
                },
                .owned_file, .borrowed_file => |file| {
                    const out = try gpa.alloc(u8, @intCast(entry.size));
                    errdefer gpa.free(out);
                    try readExactly(file, io, out, entry.offset);
                    return out;
                },
            }
        },
        .flate => {
            // The stored bytes have to be somewhere before they can be
            // inflated, so a file-backed pack pays for one copy of them.
            var stored: []const u8 = undefined;
            var borrowed = true;
            switch (self.storage) {
                .memory => |bytes| {
                    stored = bytes[@intCast(entry.offset)..][0..@intCast(entry.stored)];
                },
                .owned_file, .borrowed_file => |file| {
                    const buffer = try gpa.alloc(u8, @intCast(entry.stored));
                    try readExactly(file, io, buffer, entry.offset);
                    stored = buffer;
                    borrowed = false;
                },
            }
            defer if (!borrowed) gpa.free(stored);

            return inflate(gpa, stored, @intCast(entry.size));
        },
    }
}

fn inflate(gpa: Allocator, stored: []const u8, size: usize) Error![]u8 {
    var input: Io.Reader = .fixed(stored);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var stream: std.compress.flate.Decompress = .init(&input, .raw, window);
    // Bounded by what the index said it would be: a stream that keeps
    // producing bytes past that is a stream to stop reading.
    const out = stream.reader.allocRemaining(gpa, .limited(size + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    errdefer gpa.free(out);
    if (out.len != size) return error.Corrupt;
    return out;
}

// -------------------------------------------------------------------------
// Checking what was opened
// -------------------------------------------------------------------------

fn checkHeader(head: *const [header_size]u8) Error!void {
    if (!std.mem.eql(u8, head[0..4], &magic)) return error.UnsupportedPack;
    if (head[4] != format_version) return error.UnsupportedPack;
    // No flag has a meaning yet, so a pack that sets one was written by a
    // build that knew something this one does not.
    if (head[5] != 0) return error.UnsupportedPack;
    return;
}

fn readIndex(gpa: Allocator, encoded: []const u8) Error!fxdata.Decoded(Index) {
    return fxdata.decode(gpa, Index, encoded) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The index is a different shape than this build knows, which is the
        // whole reason its schema is written down.
        error.SchemaMismatch, error.NotFluxionData, error.UnsupportedVersion => error.UnsupportedPack,
        else => error.Corrupt,
    };
}

fn freeIndex(gpa: Allocator, index: fxdata.Decoded(Index)) void {
    var owned = index;
    owned.deinit(gpa);
}

/// Everything about the index that has to be true before a single entry is
/// read: sorted, unique, normalized, and inside the blob region.
fn checkEntries(all: []const Entry, blobs_end: u64) Error!void {
    var previous: []const u8 = "";
    for (all, 0..) |entry, i| {
        if (i != 0 and std.mem.order(u8, previous, entry.path) != .lt) return error.Corrupt;
        previous = entry.path;

        // A path that is not normalized is a path no lookup could ever ask
        // for, so a pack holding one is wrong rather than merely wasteful.
        if (!vpath.isNormal(entry.path, .lax)) return error.Corrupt;

        if (entry.offset < header_size) return error.Corrupt;
        if (entry.stored > blobs_end - header_size) return error.Corrupt;
        if (entry.offset > blobs_end - entry.stored) return error.Corrupt;
        if (entry.compression == .none and entry.stored != entry.size) return error.Corrupt;
    }
}

fn readExactly(file: Io.File, io: Io, into: []u8, at: u64) Error!void {
    const got = file.readPositionalAll(io, into, at) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    if (got != into.len) return error.Corrupt;
}

// -------------------------------------------------------------------------
// Building one
// -------------------------------------------------------------------------

/// Writes a pack, one entry at a time.
///
/// The blobs go out as they arrive, so the memory this needs is the index
/// plus the largest single entry - not the pack.
pub const Builder = struct {
    gpa: Allocator,
    out: *Io.Writer,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    at: u64 = header_size,
    finished: bool = false,

    pub const Error = error{
        /// Two entries with the same path. Which one a lookup should find has
        /// no good answer, so it is refused at build time.
        DuplicatePath,
    } || vpath.Error || Io.Writer.Error || Allocator.Error;

    /// How to store the next entry.
    pub const How = enum {
        /// As it is. For anything already compressed - a PNG, an Ogg.
        store,
        /// Deflated, whether or not that helps.
        deflate,
        /// Deflated, and kept only if it saved at least a sixteenth. Below
        /// that the decompression on every load is not paid for by the bytes,
        /// and an entry stored as it is can be read straight out of a mapped
        /// pack.
        auto,
    };

    /// Start a pack, writing its header into `w`.
    pub fn init(gpa: Allocator, w: *Io.Writer) Io.Writer.Error!Builder {
        try w.writeAll(&magic);
        try w.writeByte(format_version);
        try w.writeByte(0); // flags
        try w.writeAll(&[_]u8{ 0, 0 }); // reserved, and alignment
        return .{ .gpa = gpa, .out = w };
    }

    pub fn deinit(self: *Builder) void {
        for (self.entries.items) |entry| self.gpa.free(entry.path);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Add `bytes` under `path`, which is normalized on the way in.
    pub fn add(self: *Builder, path: []const u8, bytes: []const u8, how: How) Builder.Error!void {
        var buf: [vpath.max_len]u8 = undefined;
        const name = try vpath.normalize(&buf, path, .portable);

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, name)) return error.DuplicatePath;
        }

        var crc: hashing.Crc32 = .init();
        crc.update(bytes);

        var stored: []const u8 = bytes;
        var compression: Compression = .none;
        var packed_bytes: ?[]u8 = null;
        defer if (packed_bytes) |owned| self.gpa.free(owned);

        if (how != .store and bytes.len != 0) {
            if (try deflate(self.gpa, bytes)) |smaller| {
                packed_bytes = smaller;
                const worth_it = how == .deflate or
                    smaller.len + bytes.len / 16 < bytes.len;
                if (worth_it) {
                    stored = smaller;
                    compression = .flate;
                }
            }
        }

        const owned_path = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_path);
        try self.entries.append(self.gpa, .{
            .path = owned_path,
            .offset = self.at,
            .stored = stored.len,
            .size = bytes.len,
            .checksum = crc.final(),
            .compression = compression,
        });

        try self.out.writeAll(stored);
        self.at += stored.len;
    }

    /// Write the index and the offset that points at it. The builder is done
    /// after this, and the caller flushes whatever `w` was.
    pub fn finish(self: *Builder) Builder.Error!void {
        std.mem.sort(Entry, self.entries.items, {}, byPath);

        const index: Index = .{ .entries = self.entries.items };
        const encoded = try fxdata.encodeAlloc(self.gpa, Index, index, .{});
        defer self.gpa.free(encoded);

        try self.out.writeAll(encoded);
        var tail: [footer_size]u8 = undefined;
        std.mem.writeInt(u64, &tail, self.at, .little);
        try self.out.writeAll(&tail);
        self.finished = true;
    }

    fn byPath(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// Deflate `bytes`, or null when the result would not be smaller.
fn deflate(gpa: Allocator, bytes: []const u8) Allocator.Error!?[]u8 {
    // Sized for the case where compression achieves nothing, which is the
    // only bound that holds for arbitrary input.
    const scratch = try gpa.alloc(u8, bytes.len + 64 * 1024);
    defer gpa.free(scratch);
    var sink: Io.Writer = .fixed(scratch);

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var compress: std.compress.flate.Compress = .init(&sink, window, .raw, .default) catch return null;
    compress.writer.writeAll(bytes) catch return null;
    compress.finish() catch return null;

    const written = sink.buffered();
    if (written.len >= bytes.len) return null;
    return gpa.dupe(u8, written);
}

/// Build a whole pack into fresh memory, for a caller with the entries to
/// hand. The caller frees the result.
pub fn build(
    gpa: Allocator,
    items: []const struct { path: []const u8, bytes: []const u8, how: Builder.How = .auto },
) Builder.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var builder: Builder = try .init(gpa, &out.writer);
    defer builder.deinit();

    for (items) |item| try builder.add(item.path, item.bytes, item.how);
    try builder.finish();

    return out.toOwnedSlice();
}
