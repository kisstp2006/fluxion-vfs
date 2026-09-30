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
//! flags                one byte: sealed, hidden, signed
//! reserved             two bytes of zero
//! salt                 sixteen bytes the keys of a sealed pack are drawn with
//! key check            sixteen bytes that tell a wrong key from a damaged pack
//! reserved             eight bytes of zero, to keep the blobs sixteen-aligned
//! blobs                every entry's chunks, in the order they were added
//! index                a fluxion-data document holding the entries
//! index tag            sixteen bytes: the index's seal, zero when it is in the clear
//! signature            sixty-four bytes over header, index and tag, zero when unsigned
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
//! **An entry is stored in chunks** of `chunk_len` bytes. Each is compressed
//! on its own, and in a sealed pack sealed on its own, so a stream decodes one
//! piece at a time and a damaged piece is caught where it lies instead of
//! after the whole entry has been read. The index keeps each chunk's stored
//! size and its check: the seal's tag in a sealed pack, and otherwise the
//! first half of the SHA-256 of the stored bytes.
//!
//! **A sealed pack keeps its contents from anyone without the key.** Every
//! chunk is AES-256-GCM, with the entry's number and the chunk's as the nonce
//! and the entry's path as associated data, so a chunk cannot be moved to
//! another place in the entry or another entry without the seal breaking. The
//! caller's key is never used as it is: the pack draws its own keys from it and
//! the salt with HKDF, so no two packs share one. A **hidden** pack seals its
//! index too, so without the key not even the names of what is in it can be
//! read. A **signed** pack carries an Ed25519 signature over the header, the
//! index and the index's tag; the index holds every chunk's check, so the
//! signature covers every byte, and a reader given the public key refuses a
//! pack that was changed by anyone without the private one.
//!
//! None of this keeps a pack from the program that has to open it. The key has
//! to be wherever the pack is read, so sealing keeps the contents from tools
//! and casual copying, not from someone who takes the key out of that program.
//!
//! **A pack can be read three ways.** `fromBytes` for one already in memory -
//! `@embedFile`d, or held by the caller. `map` for one on disk, mapped whole
//! and paged in as it is touched, which is the fastest way to open a large
//! one and the only way an entry stored as it is can be handed out as a slice
//! of the file. `openFile` for a target that cannot map, or a pack on a
//! filesystem that will not be: the file stays open, the index is held, and
//! each entry is read from where it lies. `fromFileRegion` is that for a pack
//! that is only part of a file - one written onto the end of a program, or
//! stored inside an archive.
//!
//! **Changing a pack is rewriting it.** There is no in-place update, because
//! one would mean moving every blob after the one that changed and rewriting
//! the index anyway. `Builder.initFrom` starts a new pack from an old one:
//! carry every entry over, take some out, put some in, and the old pack's
//! bytes are copied as they are - never decompressed and compressed again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fxdata = @import("fluxion_data");

const Jobs = @import("fluxion_jobs").Jobs;

const Map = @import("Map.zig");
const Source = @import("Source.zig");
const Stream = @import("Stream.zig");
const vpath = @import("vpath.zig");
const glob_match = @import("fluxion_text").pattern;

const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const Ed25519 = std.crypto.sign.Ed25519;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Pack = @This();

/// The four bytes every pack starts with.
pub const magic = [4]u8{ 'F', 'X', 'P', 'K' };

/// The container's own version, which is not the index's schema. It changes
/// when the framing changes.
pub const format_version: u8 = 2;

/// Magic, version, flags, salt, key check, and the padding after them.
pub const header_size = 48;

/// The index's tag, the signature, and the index offset, at the very end.
pub const footer_size = 88;

/// How many bytes of an entry one chunk holds; the last one holds the rest.
pub const chunk_len = 64 * 1024;

/// What a sealed pack is sealed with.
pub const Key = [32]u8;

/// What a signed pack is checked against: an Ed25519 public key.
pub const PublicKey = [Ed25519.PublicKey.encoded_length]u8;

/// What a pack says about itself, in its header.
pub const Flags = packed struct(u8) {
    /// Every chunk is sealed.
    sealed: bool = false,
    /// The index is sealed too.
    hidden: bool = false,
    /// The footer holds a signature.
    signed: bool = false,
    unused: u5 = 0,
};

/// How an entry's chunks are stored.
pub const Compression = enum(u8) {
    /// As they are.
    none,
    /// Each deflated on its own, in the raw container - a pack has its own
    /// checks and does not need zlib's.
    flate,
};

/// One stored chunk of an entry.
pub const Chunk = struct {
    /// How many bytes it takes in the file.
    stored: u32,
    /// The seal's tag in a sealed pack; the first half of the SHA-256 of the
    /// stored bytes otherwise.
    check: [16]u8,
};

/// What the index says about one entry. The order of these fields is part of
/// the format, because it is what the fingerprint is taken over.
pub const Entry = struct {
    /// Normalized, and unique within the pack.
    path: []const u8,
    /// Where the first chunk begins, from the start of the pack.
    offset: u64,
    /// How many bytes all the chunks take in the file.
    stored: u64,
    /// How many bytes come back out.
    size: u64,
    /// The entry's half of every chunk's nonce, unique within the pack.
    nonce: u64,
    compression: Compression,
    /// One for every `chunk_len` bytes of `size`, and none for an empty entry.
    chunks: []const Chunk,
};

const Index = struct { entries: []const Entry };

pub const Error = Source.Error;

pub const Options = struct {
    /// Check each chunk of a pack that is not sealed against its hash on the
    /// way out. A sealed chunk is always checked: opening the seal is the
    /// check.
    ///
    /// On, because a pack is the thing that arrives over a network or off a
    /// disc, and the alternative to a message is a texture full of noise. Off
    /// for a pack that came from somewhere already checked, or for a profile
    /// run where the hash is the thing being measured.
    verify: bool = true,
    /// What to open a sealed or hidden pack with. Ignored for one that is
    /// neither.
    key: ?Key = null,
    /// Refuse a pack not signed by this key's private half.
    signed_by: ?PublicKey = null,
};

gpa: Allocator,
options: Options,
flags: Flags,
/// The keys drawn from the caller's, for a sealed pack.
keys: ?Keys,
/// Owns the entries and the bytes of their paths.
index: fxdata.Decoded(Index),
storage: Storage,
/// Present when `storage` is memory this pack mapped itself, and must unmap.
mapping: ?Map = null,

pub const Storage = union(enum) {
    /// The pack's bytes. The caller owns them and they must outlive the pack -
    /// or they are part of a mapping the pack owns, when `mapping` is set.
    memory: []const u8,
    /// A file the pack is part of, from `base` on.
    file: struct {
        file: Io.File,
        /// Whether the pack closes the file.
        owned: bool,
        base: u64,
    },
};

/// The keys one pack is sealed with, drawn from the caller's and its salt.
const Keys = struct {
    chunks: Key,
    index: Key,
    check: [16]u8,
};

fn drawKeys(key: Key, salt: [16]u8) Keys {
    const prk = Hkdf.extract(&salt, &key);
    var keys: Keys = undefined;
    Hkdf.expand(&keys.chunks, "fluxion pack: chunks", prk);
    Hkdf.expand(&keys.index, "fluxion pack: index", prk);
    Hkdf.expand(&keys.check, "fluxion pack: key check", prk);
    return keys;
}

fn chunkNonce(entry_nonce: u64, chunk: usize) [Aes.nonce_length]u8 {
    var nonce: [Aes.nonce_length]u8 = undefined;
    std.mem.writeInt(u64, nonce[0..8], entry_nonce, .little);
    std.mem.writeInt(u32, nonce[8..12], @intCast(chunk), .little);
    return nonce;
}

/// The index is sealed with a key of its own, so the nonce that no chunk ever
/// uses is all it needs.
const index_nonce = [_]u8{0} ** Aes.nonce_length;

// -------------------------------------------------------------------------
// Opening
// -------------------------------------------------------------------------

/// Read a pack that is already in memory. `bytes` must outlive the pack.
pub fn fromBytes(gpa: Allocator, bytes: []const u8, options: Options) Error!Pack {
    if (bytes.len < header_size + footer_size) return error.UnsupportedPack;
    const foot = bytes[bytes.len - footer_size ..][0..footer_size];
    const at = try indexOffset(foot, bytes.len);
    const opened = try openIndex(gpa, bytes[0..header_size], foot, bytes[@intCast(at) .. bytes.len - footer_size], at, options);
    return .{
        .gpa = gpa,
        .options = options,
        .flags = opened.flags,
        .keys = opened.keys,
        .index = opened.index,
        .storage = .{ .memory = bytes },
    };
}

/// Map a pack file into memory and read it from there.
///
/// The fastest way to open a large pack, and the only one on which an entry
/// stored as it is costs no copy. `error.Unsupported` on a target with no
/// memory mapping; `openFile` works everywhere.
pub fn map(gpa: Allocator, io: Io, path: []const u8, options: Options) (Error || Map.Error)!Pack {
    var mapping = try Map.open(io, path);
    errdefer mapping.deinit();

    var pack = try fromBytes(gpa, mapping.bytes, options);
    pack.mapping = mapping;
    return pack;
}

/// Open a pack file, keeping it open and holding only the index.
pub fn openFile(gpa: Allocator, io: Io, path: []const u8, options: Options) Error!Pack {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    var pack = try fromFile(gpa, io, file, options);
    pack.storage.file.owned = true;
    return pack;
}

/// Read the index of a file the caller opened and keeps, which is the pack.
pub fn fromFile(gpa: Allocator, io: Io, file: Io.File, options: Options) Error!Pack {
    return fromFileRegion(gpa, io, file, 0, (try file.stat(io)).size, options);
}

/// Read the index of a pack that is `len` bytes of a file the caller opened
/// and keeps, from `start` on: one written onto the end of a program, or one
/// stored as it is inside an archive.
pub fn fromFileRegion(gpa: Allocator, io: Io, file: Io.File, start: u64, len: u64, options: Options) Error!Pack {
    if (len < header_size + footer_size) return error.UnsupportedPack;

    var head: [header_size]u8 = undefined;
    try readExactly(file, io, &head, start);
    var foot: [footer_size]u8 = undefined;
    try readExactly(file, io, &foot, start + len - footer_size);
    const at = try indexOffset(&foot, len);

    const stored_index = try gpa.alloc(u8, @intCast(len - footer_size - at));
    defer gpa.free(stored_index);
    try readExactly(file, io, stored_index, start + at);

    const opened = try openIndex(gpa, &head, &foot, stored_index, at, options);
    return .{
        .gpa = gpa,
        .options = options,
        .flags = opened.flags,
        .keys = opened.keys,
        .index = opened.index,
        .storage = .{ .file = .{ .file = file, .owned = false, .base = start } },
    };
}

pub fn deinit(self: *Pack, io: Io) void {
    freeIndex(self.gpa, self.index);
    switch (self.storage) {
        .file => |held| if (held.owned) held.file.close(io),
        .memory => {},
    }
    if (self.mapping) |*mapping| mapping.deinit();
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
    .open = openPath,
    // A pack is written once by a tool and read many times by a game. Making
    // it writable would mean rewriting the index and moving every blob after
    // the one that changed, which is what `Builder.initFrom` does honestly
    // and the loose directory mount above it avoids entirely.
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

/// An entry stored as it is, as a slice of the pack's own memory, with no
/// copy.
///
/// Only for a pack that is in memory - `fromBytes` or `map` - that is not
/// sealed, and only for an entry that is not compressed; null otherwise, and
/// `read` is the general answer. The slice lives as long as the pack does.
/// Not checked: the caller who wanted that would have had to read the bytes,
/// which is what this avoids.
pub fn slice(self: *const Pack, path: []const u8) ?[]const u8 {
    if (self.flags.sealed) return null;
    const entry = self.find(path) orelse return null;
    if (entry.compression != .none) return null;
    return switch (self.storage) {
        .memory => |bytes| bytes[@intCast(entry.offset)..][0..@intCast(entry.size)],
        .file => null,
    };
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

    const out = try gpa.alloc(u8, @intCast(entry.size));
    errdefer gpa.free(out);

    var reading: ChunkReader = try .init(self, io, gpa, entry);
    defer reading.deinit();
    var at: usize = 0;
    for (0..entry.chunks.len) |i| {
        const piece = try reading.next(i);
        @memcpy(out[at..][0..piece.len], piece);
        at += piece.len;
    }
    return out;
}

fn openPath(ptr: *anyopaque, io: Io, gpa: Allocator, path: []const u8) Error!*Stream {
    const self: *Pack = @ptrCast(@alignCast(ptr));
    const entry = self.find(path) orelse return error.FileNotFound;

    // Stored as it is, and in the clear: the chunks lie end to end and are
    // the bytes, so a stream reads them where they are.
    if (!self.flags.sealed and entry.compression == .none and !self.options.verify) {
        return switch (self.storage) {
            .memory => |bytes| Stream.fromMemory(gpa, bytes[@intCast(entry.offset)..][0..@intCast(entry.size)], entry.size, .none),
            .file => |held| Stream.fromFile(gpa, io, held.file, false, held.base + entry.offset, entry.size, entry.size, .none),
        };
    }

    const reading = try gpa.create(ChunkReader);
    errdefer gpa.destroy(reading);
    reading.* = try .init(self, io, gpa, entry);
    errdefer reading.deinit();
    return Stream.fromPieces(gpa, entry.size, .{
        .ptr = reading,
        .count = entry.chunks.len,
        .next = nextPiece,
        .release = releasePieces,
    });
}

fn nextPiece(ptr: *anyopaque, index: usize) Error![]const u8 {
    const reading: *ChunkReader = @ptrCast(@alignCast(ptr));
    return reading.next(index);
}

fn releasePieces(ptr: *anyopaque, gpa: Allocator) void {
    const reading: *ChunkReader = @ptrCast(@alignCast(ptr));
    reading.deinit();
    gpa.destroy(reading);
}

fn listPaths(ptr: *anyopaque, io: Io, glob: []const u8, into: *Source.Listing) Error!void {
    _ = io;
    const self: *Pack = @ptrCast(@alignCast(ptr));
    for (self.entries()) |entry| {
        if (glob.len != 0 and !glob_match.matchPath(glob, entry.path)) continue;
        try into.add(entry.path);
    }
}

/// Turns one entry's chunks back into its bytes, one chunk at a time.
const ChunkReader = struct {
    pack: *const Pack,
    io: Io,
    gpa: Allocator,
    entry: *const Entry,
    /// Where the next chunk starts, from the start of the pack, and which
    /// one that is - so reading them in order never adds the sizes up again.
    next_at: u64,
    next_index: usize = 0,
    /// A chunk as stored, and as it came out.
    stored: []u8,
    out: []u8,
    /// Deflate's window, for a compressed entry.
    window: []u8 = &.{},

    fn init(pack: *const Pack, io: Io, gpa: Allocator, entry: *const Entry) Error!ChunkReader {
        var largest: usize = 0;
        for (entry.chunks) |chunk| largest = @max(largest, chunk.stored);
        const stored = try gpa.alloc(u8, largest);
        errdefer gpa.free(stored);
        const out = try gpa.alloc(u8, @min(chunk_len, entry.size));
        errdefer gpa.free(out);
        const window: []u8 = if (entry.compression == .flate) try gpa.alloc(u8, std.compress.flate.max_window_len) else &.{};
        return .{
            .pack = pack,
            .io = io,
            .gpa = gpa,
            .entry = entry,
            .next_at = entry.offset,
            .stored = stored,
            .out = out,
            .window = window,
        };
    }

    fn deinit(self: *ChunkReader) void {
        self.gpa.free(self.stored);
        self.gpa.free(self.out);
        if (self.window.len != 0) self.gpa.free(self.window);
    }

    /// Chunk `index`, checked and undone. Borrowed until the next call.
    fn next(self: *ChunkReader, index: usize) Error![]const u8 {
        if (index != self.next_index) {
            // Out of order: find where it starts.
            self.next_at = self.entry.offset;
            for (self.entry.chunks[0..index]) |chunk| self.next_at += chunk.stored;
        }
        const chunk = self.entry.chunks[index];
        const at = self.next_at;
        self.next_at += chunk.stored;
        self.next_index = index + 1;

        const stored = self.stored[0..chunk.stored];
        try self.pack.fetch(self.io, stored, at);

        const pack = self.pack;
        if (pack.flags.sealed) {
            // Opened in place: the stored copy is ours, and GCM runs its
            // counter over the bytes one block at a time.
            Aes.decrypt(stored, stored, chunk.check, self.entry.path, chunkNonce(self.entry.nonce, index), pack.keys.?.chunks) catch
                return error.Corrupt;
        } else if (pack.options.verify) {
            if (!std.mem.eql(u8, &checkOf(stored), &chunk.check)) return error.Corrupt;
        }

        const want = chunkSize(self.entry.size, index);
        switch (self.entry.compression) {
            .none => {
                if (stored.len != want) return error.Corrupt;
                return stored;
            },
            .flate => {
                try inflateInto(self.out[0..want], stored, self.window);
                return self.out[0..want];
            },
        }
    }
};

/// How many bytes chunk `index` of an entry of `size` holds.
fn chunkSize(size: u64, index: usize) usize {
    const start = @as(u64, index) * chunk_len;
    return @intCast(@min(chunk_len, size - start));
}

/// How many chunks an entry of `size` is stored in.
fn chunkCount(size: u64) usize {
    return @intCast((size + chunk_len - 1) / chunk_len);
}

/// The check of a chunk that is not sealed.
fn checkOf(stored: []const u8) [16]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(stored, &digest, .{});
    return digest[0..16].*;
}

/// `into.len` bytes out of one raw deflate stream, and not one more.
fn inflateInto(into: []u8, stored: []const u8, window: []u8) Error!void {
    var input: Io.Reader = .fixed(stored);
    var stream: std.compress.flate.Decompress = .init(&input, .raw, window);
    stream.reader.readSliceAll(into) catch return error.Corrupt;
    // A stream that keeps producing bytes past that is a stream that was
    // not the one the index described.
    var extra: [1]u8 = undefined;
    const more = stream.reader.readSliceShort(&extra) catch return error.Corrupt;
    if (more != 0) return error.Corrupt;
}

/// `into.len` stored bytes, from `at` bytes into the pack.
fn fetch(self: *const Pack, io: Io, into: []u8, at: u64) Error!void {
    switch (self.storage) {
        .memory => |bytes| @memcpy(into, bytes[@intCast(at)..][0..into.len]),
        .file => |held| try readExactly(held.file, io, into, held.base + at),
    }
}

// -------------------------------------------------------------------------
// Checking what was opened
// -------------------------------------------------------------------------

fn checkHeader(head: *const [header_size]u8) Error!Flags {
    if (!std.mem.eql(u8, head[0..4], &magic)) return error.UnsupportedPack;
    if (head[4] != format_version) return error.UnsupportedPack;
    const flags: Flags = @bitCast(head[5]);
    // A flag this build has no name for was set by a build that knew
    // something this one does not.
    if (flags.unused != 0) return error.UnsupportedPack;
    return flags;
}

fn indexOffset(foot: *const [footer_size]u8, len: u64) Error!u64 {
    const at = std.mem.readInt(u64, foot[footer_size - 8 ..][0..8], .little);
    if (at < header_size or at > len - footer_size) return error.Corrupt;
    return at;
}

const Opened = struct {
    flags: Flags,
    keys: ?Keys,
    index: fxdata.Decoded(Index),
};

/// Everything about opening a pack once its header, footer and index are in
/// hand, wherever they came from.
fn openIndex(
    gpa: Allocator,
    head: *const [header_size]u8,
    foot: *const [footer_size]u8,
    stored_index: []const u8,
    at: u64,
    options: Options,
) Error!Opened {
    const flags = try checkHeader(head);

    var keys: ?Keys = null;
    if (flags.sealed or flags.hidden) {
        const key = options.key orelse return error.KeyNeeded;
        const drawn = drawKeys(key, head[8..24].*);
        if (!std.crypto.timing_safe.eql([16]u8, drawn.check, head[24..40].*)) return error.WrongKey;
        keys = drawn;
    }

    const tag = foot[0..16].*;
    if (options.signed_by) |public| {
        if (!flags.signed) return error.NotSigned;
        const key = Ed25519.PublicKey.fromBytes(public) catch return error.NotSigned;
        const signature: Ed25519.Signature = .fromBytes(foot[16..80].*);
        var verifier = signature.verifier(key) catch return error.NotSigned;
        verifier.update(head);
        verifier.update(stored_index);
        verifier.update(&tag);
        verifier.verify() catch return error.NotSigned;
    }

    const index = if (flags.hidden) blk: {
        const plain = try gpa.alloc(u8, stored_index.len);
        defer gpa.free(plain);
        // The key check passed, so a seal that does not open is damage.
        Aes.decrypt(plain, stored_index, tag, head, index_nonce, keys.?.index) catch return error.Corrupt;
        break :blk try readIndex(gpa, plain);
    } else try readIndex(gpa, stored_index);
    errdefer freeIndex(gpa, index);

    try checkEntries(index.value.entries, at, flags);
    return .{ .flags = flags, .keys = keys, .index = index };
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
/// read: sorted, unique, normalized, inside the blob region, and chunked the
/// way its size says.
fn checkEntries(all: []const Entry, blobs_end: u64, flags: Flags) Error!void {
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

        if (entry.chunks.len != chunkCount(entry.size)) return error.Corrupt;
        var stored: u64 = 0;
        for (entry.chunks, 0..) |chunk, c| {
            stored += chunk.stored;
            if (chunk.stored > chunk_len + chunk_len / 2) return error.Corrupt;
            if (entry.compression == .none and chunk.stored != chunkSize(entry.size, c)) return error.Corrupt;
        }
        if (stored != entry.stored) return error.Corrupt;
        if (entry.compression == .none and !flags.sealed and entry.stored != entry.size) return error.Corrupt;
    }
}

fn readExactly(file: Io.File, io: Io, into: []u8, at: u64) Error!void {
    const got = try file.readPositionalAll(io, into, at);
    if (got != into.len) return error.Corrupt;
}

// -------------------------------------------------------------------------
// Building one
// -------------------------------------------------------------------------

/// How many entries `Builder.addAll` prepares at once, and how many bytes of
/// input those may cover. Between them they bound what a parallel build holds
/// beyond the builder itself.
const max_batch_items = 256;
const max_batch_bytes = 64 << 20;

/// Writes a pack, one entry at a time.
///
/// The blobs go out as they arrive, so the memory this needs is the index
/// plus the largest single entry - not the pack.
pub const Builder = struct {
    gpa: Allocator,
    out: *Io.Writer,
    options: Builder.Options,
    header: [header_size]u8,
    keys: ?Keys,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Every path in `entries` and every carried one not yet removed, so a
    /// duplicate is found in constant time whatever the pack's size.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    at: u64 = header_size,
    /// The nonce the next entry gets. Each pack has keys of its own, so a
    /// count is as good as anything random, and cannot repeat.
    next_nonce: u64 = 1,
    /// The pack this one starts from, when it starts from one.
    carried: ?Carried = null,

    const Carried = struct {
        pack: *const Pack,
        io: Io,
        /// Carried entries taken out again, by path.
        dropped: std.StringHashMapUnmanaged(void) = .empty,
    };

    pub const Error = error{
        /// Two entries with the same path. Which one a lookup should find has
        /// no good answer, so it is refused at build time.
        DuplicatePath,
        /// The signing key is not a valid Ed25519 key pair.
        BadSigningKey,
    } || vpath.Error || Io.Writer.Error || Pack.Error;

    /// What the pack is to be.
    pub const Options = struct {
        /// Seal every chunk, and perhaps the index, with this.
        seal: ?Seal = null,
        /// Sign the pack, so a reader holding the public half can tell it
        /// is the one that was built.
        sign: ?Ed25519.KeyPair = null,
    };

    pub const Seal = struct {
        key: Key,
        /// Sixteen fresh random bytes - `io.random` - which the pack's own
        /// keys are drawn with. Never the same twice for one key.
        salt: [16]u8,
        /// Seal the index too, so not even the names can be read without the
        /// key.
        hide_index: bool = true,
    };

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
    pub fn init(gpa: Allocator, w: *Io.Writer, options: Builder.Options) Io.Writer.Error!Builder {
        var header = [_]u8{0} ** header_size;
        @memcpy(header[0..4], &magic);
        header[4] = format_version;
        var flags: Flags = .{ .signed = options.sign != null };
        var keys: ?Keys = null;
        if (options.seal) |seal| {
            flags.sealed = true;
            flags.hidden = seal.hide_index;
            const drawn = drawKeys(seal.key, seal.salt);
            header[8..24].* = seal.salt;
            header[24..40].* = drawn.check;
            keys = drawn;
        }
        header[5] = @bitCast(flags);
        try w.writeAll(&header);
        return .{ .gpa = gpa, .out = w, .options = options, .header = header, .keys = keys };
    }

    /// Start a pack that carries everything in `pack` over, so that a change
    /// to one entry does not mean rebuilding the rest from their sources.
    ///
    /// The carried entries' chunks are copied as they are stored - never
    /// decompressed and compressed again - at `finish`, after whatever was
    /// added. Between a sealed pack and one that is not, or two sealed with
    /// different keys, each chunk is opened and sealed again on the way, but
    /// still not recompressed. `remove` takes one out before it is copied;
    /// `add` of a carried path is a duplicate until it has been removed.
    pub fn initFrom(gpa: Allocator, w: *Io.Writer, options: Builder.Options, pack: *const Pack, io: Io) Builder.Error!Builder {
        var self = try init(gpa, w, options);
        errdefer self.deinit();

        for (pack.entries()) |entry| try self.seen.putNoClobber(gpa, entry.path, {});
        self.carried = .{ .pack = pack, .io = io };
        return self;
    }

    pub fn deinit(self: *Builder) void {
        for (self.entries.items) |entry| {
            self.gpa.free(entry.path);
            self.gpa.free(entry.chunks);
        }
        self.entries.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        if (self.carried) |*carried| carried.dropped.deinit(self.gpa);
        self.* = undefined;
    }

    /// One entry to add. What `addAll` takes.
    pub const Item = struct {
        path: []const u8,
        bytes: []const u8,
        how: How = .auto,
    };

    /// Everything about an entry that can be worked out without touching the
    /// builder: its chunks, compressed when that helped, and sealed or
    /// hashed.
    ///
    /// Separated out because it is all of the expensive part and none of the
    /// shared part, which is what lets `addAll` do it on several threads.
    const Prepared = struct {
        /// The chunks end to end, owned. Null when they are the input as it
        /// is - stored, and not sealed.
        stored: ?[]u8 = null,
        chunks: []Chunk = &.{},
        compression: Compression = .none,
        /// The preparation could not get memory. A job cannot return an
        /// error, so it says so here.
        out_of_memory: bool = false,
        /// What the preparation needs besides the bytes, set before it runs.
        /// Here rather than an argument, which a job keeps small.
        job: Job = undefined,

        fn free(self: Prepared, gpa: Allocator) void {
            if (self.stored) |owned| gpa.free(owned);
            gpa.free(self.chunks);
        }
    };

    /// What `prepare` needs besides the bytes, fixed before any of it runs.
    const Job = struct {
        path: []const u8,
        nonce: u64,
        keys: ?*const Keys,
    };

    /// Chunk `bytes`, deflate them if that is worth doing, and seal or hash
    /// every chunk.
    ///
    /// Touches nothing but `result` and the allocator, so any number of these
    /// may run at once. The allocator must be thread-safe when they do.
    fn prepare(result: *Prepared, bytes: []const u8, how: How, gpa: Allocator) void {
        prepareOrFail(result, bytes, how, result.job, gpa) catch {
            result.free(gpa);
            result.* = .{ .out_of_memory = true };
        };
    }

    fn prepareOrFail(result: *Prepared, bytes: []const u8, how: How, job: Job, gpa: Allocator) Allocator.Error!void {
        const count = chunkCount(bytes.len);
        result.chunks = try gpa.alloc(Chunk, count);

        if (how != .store and bytes.len != 0) {
            const deflated = try deflateChunks(gpa, bytes, result.chunks);
            // Kept only when it saved enough to pay for the decompression on
            // every load - unless the caller asked for it whatever it saved.
            if (how == .deflate or deflated.len + bytes.len / 16 < bytes.len) {
                result.stored = deflated;
                result.compression = .flate;
            } else {
                gpa.free(deflated);
            }
        }
        if (result.compression == .none) {
            for (result.chunks, 0..) |*chunk, i| chunk.stored = @intCast(chunkSize(bytes.len, i));
            // Sealing writes the chunks anew; otherwise they are the input.
            if (job.keys != null) result.stored = try gpa.alloc(u8, bytes.len);
        }

        var at: usize = 0;
        for (result.chunks, 0..) |*chunk, i| {
            const piece_len = chunk.stored;
            if (job.keys) |keys| {
                const plain: []const u8 = if (result.compression == .none) bytes[at..][0..piece_len] else result.stored.?[at..][0..piece_len];
                Aes.encrypt(result.stored.?[at..][0..piece_len], &chunk.check, plain, job.path, chunkNonce(job.nonce, i), keys.chunks);
            } else {
                const stored_piece: []const u8 = if (result.stored) |owned| owned[at..][0..piece_len] else bytes[at..][0..piece_len];
                chunk.check = checkOf(stored_piece);
            }
            at += piece_len;
        }
    }

    /// Add `bytes` under `path`, which is normalized on the way in.
    pub fn add(self: *Builder, path: []const u8, bytes: []const u8, how: How) Builder.Error!void {
        const name = try self.claim(path);
        errdefer self.unclaim(name);

        var result: Prepared = .{ .job = .{ .path = name, .nonce = self.next_nonce, .keys = self.sealKeys() } };
        prepare(&result, bytes, how, self.gpa);
        defer result.free(self.gpa);
        if (result.out_of_memory) return error.OutOfMemory;
        try self.record(name, bytes, &result);
    }

    /// Add many entries, preparing them on `jobs` and writing them in order.
    ///
    /// Deflating and sealing are nearly the whole cost of building a pack,
    /// and each entry is independent of every other, so this is the one place
    /// in this library where more cores are more speed. The bytes still go
    /// into the file in the order they were given: the pack is byte for byte
    /// the one `add` in a loop would have written.
    ///
    /// Entries are prepared in batches, so what this holds beyond the builder
    /// is one batch of prepared output rather than the whole pack. `gpa` must
    /// be thread-safe when `jobs` has workers, which the default allocators
    /// are. A `Jobs` with no workers - a browser build - runs the preparation
    /// on this thread, and everything else is the same.
    pub fn addAll(self: *Builder, jobs: *Jobs, items: []const Item) Builder.Error!void {
        if (items.len == 0) return;

        const batch_len = @min(items.len, max_batch_items);
        const results = try self.gpa.alloc(Prepared, batch_len);
        defer self.gpa.free(results);
        const names = try self.gpa.alloc([]const u8, batch_len);
        defer self.gpa.free(names);

        var at: usize = 0;
        while (at < items.len) {
            // A batch is bounded by count and by bytes, so one enormous file
            // in the middle does not decide how much memory this takes.
            var count: usize = 0;
            var bytes: usize = 0;
            while (at + count < items.len and count < results.len) {
                const size = items[at + count].bytes.len;
                if (count != 0 and bytes + size > max_batch_bytes) break;
                bytes += size;
                count += 1;
            }
            const batch = items[at..][0..count];

            // Named first, in order, so each entry knows its nonce before it
            // is prepared. A name refused stops the batch there: what came
            // before it is still written, as `add` in a loop would have. A
            // name is the builder's once it is recorded, and the batch's until
            // then.
            var named: usize = 0;
            var recorded: usize = 0;
            var refused: ?Builder.Error = null;
            errdefer for (names[recorded..named]) |name| self.unclaim(name);
            for (batch) |item| {
                names[named] = self.claim(item.path) catch |err| {
                    refused = err;
                    break;
                };
                named += 1;
            }

            for (results[0..named], batch[0..named], names[0..named], 0..) |*result, item, name, i| {
                result.* = .{ .job = .{ .path = name, .nonce = self.next_nonce + i, .keys = self.sealKeys() } };
                // A scheduler with no room left is not a failure: the work
                // happens here instead, which is what a scheduler with no
                // workers does with all of it anyway.
                _ = jobs.spawn(prepare, .{ result, item.bytes, item.how, self.gpa }) catch {
                    prepare(result, item.bytes, item.how, self.gpa);
                };
            }
            jobs.waitAll();

            defer for (results[0..named]) |result| result.free(self.gpa);
            for (results[0..named]) |result| if (result.out_of_memory) return error.OutOfMemory;
            // In order, so the file reads the same however it was built.
            for (results[0..named], batch[0..named], names[0..named]) |*result, item, name| {
                try self.record(name, item.bytes, result);
                recorded += 1;
            }
            if (refused) |err| return err;
            at += count;
        }
    }

    fn sealKeys(self: *const Builder) ?*const Keys {
        return if (self.keys) |*keys| keys else null;
    }

    /// Normalize `path`, refuse it if it is taken, and hold it: the owned
    /// name is the key in `seen` until `record` puts it in an entry.
    fn claim(self: *Builder, path: []const u8) Builder.Error![]const u8 {
        var buf: [vpath.max_len]u8 = undefined;
        const name = try vpath.normalize(&buf, path, .portable);
        if (self.seen.contains(name)) return error.DuplicatePath;
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.seen.putNoClobber(self.gpa, owned, {});
        return owned;
    }

    fn unclaim(self: *Builder, name: []const u8) void {
        _ = self.seen.remove(name);
        self.gpa.free(name);
    }

    /// The part that touches the builder: remember it, write it. Takes the
    /// chunk table out of `result`.
    fn record(self: *Builder, name: []const u8, bytes: []const u8, result: *Prepared) Builder.Error!void {
        const stored: []const u8 = result.stored orelse bytes;
        const offset = self.at;
        try self.out.writeAll(stored);
        self.at += stored.len;

        // Last, so a failure before it leaves the name with the caller.
        try self.entries.append(self.gpa, .{
            .path = name,
            .offset = offset,
            .stored = stored.len,
            .size = bytes.len,
            .nonce = self.next_nonce,
            .compression = result.compression,
            .chunks = result.chunks,
        });
        result.chunks = &.{};
        self.next_nonce += 1;
    }

    /// Take `path` out of the pack being built.
    ///
    /// For a carried entry this is free: it is simply not copied. For one
    /// added to this builder the bytes are already in the output and stay
    /// there, unreachable - a pack rewritten to drop them is `initFrom` on the
    /// result. Not an error when the path was never there.
    pub fn remove(self: *Builder, path: []const u8) Builder.Error!void {
        var buf: [vpath.max_len]u8 = undefined;
        const name = try vpath.normalize(&buf, path, .portable);
        if (!self.seen.contains(name)) return;

        for (self.entries.items, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry.path, name)) continue;
            _ = self.seen.remove(name);
            self.gpa.free(entry.path);
            self.gpa.free(entry.chunks);
            _ = self.entries.orderedRemove(i);
            return;
        }
        // Not added here, so it is a carried one; remember not to copy it.
        _ = self.seen.remove(name);
        const carried = &self.carried.?;
        const entry = carried.pack.find(name).?;
        try carried.dropped.put(self.gpa, entry.path, {});
    }

    /// Write the carried entries, the index, its seal, the signature and the
    /// offset that points at the index. The builder is done after this, and
    /// the caller flushes whatever `w` was.
    pub fn finish(self: *Builder) Builder.Error!void {
        if (self.carried) |carried| try self.copyCarried(carried);

        std.mem.sort(Entry, self.entries.items, {}, byPath);

        const index: Index = .{ .entries = self.entries.items };
        const encoded = try fxdata.encodeAlloc(self.gpa, Index, index, .{});
        defer self.gpa.free(encoded);

        var foot = [_]u8{0} ** footer_size;
        const tag = foot[0..16];
        if (self.keys != null and self.options.seal.?.hide_index) {
            Aes.encrypt(encoded, tag, encoded, &self.header, index_nonce, self.keys.?.index);
        }
        if (self.options.sign) |pair| {
            const message = try std.mem.concat(self.gpa, u8, &.{ &self.header, encoded, tag });
            defer self.gpa.free(message);
            const signature = pair.sign(message, null) catch return error.BadSigningKey;
            foot[16..80].* = signature.toBytes();
        }
        std.mem.writeInt(u64, foot[footer_size - 8 ..][0..8], self.at, .little);

        try self.out.writeAll(encoded);
        try self.out.writeAll(&foot);
    }

    /// Copy every carried entry not taken out. As stored when both packs are
    /// in the clear; opened and sealed again when either is sealed.
    fn copyCarried(self: *Builder, carried: Carried) Builder.Error!void {
        const from = carried.pack;
        for (from.entries()) |entry| {
            if (carried.dropped.contains(entry.path)) continue;

            const owned_path = try self.gpa.dupe(u8, entry.path);
            errdefer self.gpa.free(owned_path);
            const chunks = try self.gpa.dupe(Chunk, entry.chunks);
            errdefer self.gpa.free(chunks);
            const nonce = self.next_nonce;

            var chunk_at = entry.offset;
            var largest: usize = 0;
            for (entry.chunks) |chunk| largest = @max(largest, chunk.stored);
            const scratch = try self.gpa.alloc(u8, largest);
            defer self.gpa.free(scratch);

            const start = self.at;
            for (chunks, 0..) |*chunk, i| {
                const piece = scratch[0..chunk.stored];
                try from.fetch(carried.io, piece, chunk_at);
                chunk_at += chunk.stored;

                if (from.flags.sealed) {
                    Aes.decrypt(piece, piece, chunk.check, entry.path, chunkNonce(entry.nonce, i), from.keys.?.chunks) catch
                        return error.Corrupt;
                    if (self.keys == null) chunk.check = checkOf(piece);
                }
                if (self.keys) |keys| {
                    Aes.encrypt(piece, &chunk.check, piece, entry.path, chunkNonce(nonce, i), keys.chunks);
                }
                try self.out.writeAll(piece);
                self.at += piece.len;
            }

            var moved = entry;
            moved.path = owned_path;
            moved.chunks = chunks;
            moved.offset = start;
            moved.nonce = nonce;
            try self.entries.append(self.gpa, moved);
            self.next_nonce += 1;
        }
    }

    fn byPath(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// Deflate each chunk of `bytes` on its own, end to end, writing each one's
/// stored size into `chunks`. Kept whatever it saves: the caller decides.
fn deflateChunks(gpa: Allocator, bytes: []const u8, chunks: []Chunk) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, bytes.len / 2 + 64);
    errdefer out.deinit();

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    // Sized for a chunk that compression makes no smaller, which is the only
    // bound that holds for any input.
    const scratch = try gpa.alloc(u8, chunk_len + chunk_len / 4);
    defer gpa.free(scratch);

    for (chunks, 0..) |*chunk, i| {
        const piece = bytes[i * chunk_len ..][0..chunkSize(bytes.len, i)];
        var sink: Io.Writer = .fixed(scratch);
        var compress = std.compress.flate.Compress.init(&sink, window, .raw, std.compress.flate.Compress.Options.default) catch unreachable;
        compress.writer.writeAll(piece) catch unreachable;
        compress.finish() catch unreachable;
        const written = sink.buffered();
        chunk.stored = @intCast(written.len);
        out.writer.writeAll(written) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// Build a whole pack into fresh memory, for a caller with the entries to
/// hand. The caller frees the result.
pub fn build(gpa: Allocator, items: []const Builder.Item) Builder.Error![]u8 {
    return buildWith(gpa, .{}, items);
}

/// `build`, sealed or signed as `options` say.
pub fn buildWith(gpa: Allocator, options: Builder.Options, items: []const Builder.Item) Builder.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var builder: Builder = try .init(gpa, &out.writer, options);
    defer builder.deinit();

    for (items) |item| try builder.add(item.path, item.bytes, item.how);
    try builder.finish();

    return out.toOwnedSlice();
}
