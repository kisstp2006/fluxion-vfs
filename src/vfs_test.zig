// SPDX-License-Identifier: BSD-2-Clause

//! The library against a real disk and real packs.
//!
//! `vpath` and the listing set are tested where they live, because they are
//! pure functions. Everything here needs a filesystem, a built pack, or both:
//! shadowing between mounts, what a pack refuses, and what a watch does with a
//! file that is still being written.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Dir = @import("Dir.zig");
const Pack = @import("Pack.zig");
const Source = @import("Source.zig");
const Vfs = @import("Vfs.zig");
const Watch = @import("Watch.zig");
const vpath = @import("vpath.zig");

const io = testing.io;
const gpa = testing.allocator;
const one_mb: Io.Limit = .limited(1 << 20);

/// Text that deflates well, for the tests about compression.
const compressible = "the same sentence over and over. " ** 40;

fn put(dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
        dir.createDirPath(io, path[0..cut]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn expectFile(files: *Vfs, path: []const u8, want: []const u8) !void {
    const got = try files.read(io, gpa, path, one_mb);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

// -------------------------------------------------------------------------
// Packs
// -------------------------------------------------------------------------

test "a pack holds what was put into it" {
    const built = try Pack.build(gpa, &.{
        .{ .path = "ui/cursor.png", .bytes = "cursor bytes" },
        .{ .path = "audio/step.wav", .bytes = "step bytes" },
        .{ .path = "levels/one.txt", .bytes = compressible },
    });
    defer gpa.free(built);

    var pack: Pack = try .fromBytes(gpa, built, .{});
    defer pack.deinit(io);

    var source = pack.source();
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "ui/cursor.png", .want = "cursor bytes" },
        .{ .path = "audio/step.wav", .want = "step bytes" },
        .{ .path = "levels/one.txt", .want = compressible },
    }) |item| {
        const got = try source.read(io, gpa, item.path, one_mb);
        defer gpa.free(got);
        try testing.expectEqualStrings(item.want, got);
    }

    // And a path that is not in it says so, rather than saying nothing.
    try testing.expectError(error.FileNotFound, source.read(io, gpa, "nope.png", one_mb));
    try testing.expectEqual(@as(?Source.Stat, null), try source.stat(io, "nope.png"));
}

test "the index is sorted, which is what makes a lookup a search" {
    const built = try Pack.build(gpa, &.{
        .{ .path = "z.txt", .bytes = "z" },
        .{ .path = "a.txt", .bytes = "a" },
        .{ .path = "m.txt", .bytes = "m" },
    });
    defer gpa.free(built);

    var pack: Pack = try .fromBytes(gpa, built, .{});
    defer pack.deinit(io);

    const all = pack.entries();
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("a.txt", all[0].path);
    try testing.expectEqualStrings("m.txt", all[1].path);
    try testing.expectEqualStrings("z.txt", all[2].path);

    try testing.expect(pack.find("m.txt") != null);
    try testing.expect(pack.find("n.txt") == null);
    // Before the first and after the last, where a binary search goes wrong
    // if its bounds are.
    try testing.expect(pack.find("0.txt") == null);
    try testing.expect(pack.find("zz.txt") == null);
}

test "compression is kept only when it pays for itself" {
    // Random bytes do not compress, and a stored entry can be read straight
    // out of a mapped pack.
    var noise: [4096]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(7);
    prng.random().bytes(&noise);

    const built = try Pack.build(gpa, &.{
        .{ .path = "text.txt", .bytes = compressible, .how = .auto },
        .{ .path = "noise.bin", .bytes = &noise, .how = .auto },
        .{ .path = "stored.txt", .bytes = compressible, .how = .store },
    });
    defer gpa.free(built);

    var pack: Pack = try .fromBytes(gpa, built, .{});
    defer pack.deinit(io);

    const text_entry = pack.find("text.txt").?;
    try testing.expectEqual(Pack.Compression.flate, text_entry.compression);
    try testing.expect(text_entry.stored < text_entry.size);

    const noise_entry = pack.find("noise.bin").?;
    try testing.expectEqual(Pack.Compression.none, noise_entry.compression);
    try testing.expectEqual(noise_entry.size, noise_entry.stored);

    const stored_entry = pack.find("stored.txt").?;
    try testing.expectEqual(Pack.Compression.none, stored_entry.compression);

    // Whatever the storage, what comes out is what went in.
    var source = pack.source();
    const back = try source.read(io, gpa, "noise.bin", one_mb);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, &noise, back);
}

test "two entries with the same name have no right answer" {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var builder: Pack.Builder = try .init(gpa, &out.writer, .{});
    defer builder.deinit();

    try builder.add("ui/a.png", "one", .store);
    // The same path, however it was spelled.
    try testing.expectError(error.DuplicatePath, builder.add("ui/./a.png", "two", .store));
    try testing.expectError(error.EscapesRoot, builder.add("../a.png", "two", .store));
}

test "a file that is not a pack, and one from a build that is not this one" {
    try testing.expectError(error.UnsupportedPack, Pack.fromBytes(gpa, "too short", .{}));
    try testing.expectError(error.UnsupportedPack, Pack.fromBytes(gpa, &[_]u8{0} ** 64, .{}));

    const built = try Pack.build(gpa, &.{.{ .path = "a.txt", .bytes = "a" }});
    defer gpa.free(built);

    const bent = try gpa.dupe(u8, built);
    defer gpa.free(bent);

    bent[4] = 99; // a container version from the future
    try testing.expectError(error.UnsupportedPack, Pack.fromBytes(gpa, bent, .{}));
    bent[4] = Pack.format_version;

    bent[5] = 0x80; // a flag this build does not know the meaning of
    try testing.expectError(error.UnsupportedPack, Pack.fromBytes(gpa, bent, .{}));
    bent[5] = 0;

    // An index offset pointing past the end of the file.
    std.mem.writeInt(u64, bent[bent.len - 8 ..][0..8], 1 << 40, .little);
    try testing.expectError(error.Corrupt, Pack.fromBytes(gpa, bent, .{}));
}

test "an index whose entries are a different shape" {
    // A pack whose index is a valid fluxion-data document of the wrong type,
    // which is what a build with one more field on `Entry` would write.
    const fxdata = @import("fluxion_data");
    const OldEntry = struct { path: []const u8, offset: u64, size: u64 };
    const OldIndex = struct { entries: []const OldEntry };

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var head = [_]u8{0} ** Pack.header_size;
    head[0..4].* = Pack.magic;
    head[4] = Pack.format_version;
    try out.writer.writeAll(&head);
    try out.writer.writeAll("a"); // one byte of blob

    const at = Pack.header_size + 1;
    const index = try fxdata.encodeAlloc(gpa, OldIndex, .{
        .entries = &.{.{ .path = "a.txt", .offset = at, .size = 1 }},
    }, .{});
    defer gpa.free(index);
    try out.writer.writeAll(index);

    var foot = [_]u8{0} ** Pack.footer_size;
    std.mem.writeInt(u64, foot[Pack.footer_size - 8 ..][0..8], at, .little);
    try out.writer.writeAll(&foot);

    try testing.expectError(error.UnsupportedPack, Pack.fromBytes(gpa, out.written(), .{}));
}

test "a byte that changed after the pack was written" {
    const built = try Pack.build(gpa, &.{.{ .path = "a.txt", .bytes = "hello there", .how = .store }});
    defer gpa.free(built);

    const bent = try gpa.dupe(u8, built);
    defer gpa.free(bent);
    bent[Pack.header_size] ^= 0xFF;

    var checked: Pack = try .fromBytes(gpa, bent, .{});
    defer checked.deinit(io);
    var checked_source = checked.source();
    try testing.expectError(error.Corrupt, checked_source.read(io, gpa, "a.txt", one_mb));

    // And with the check turned off the damage comes back as bytes, which is
    // the whole reason the check is on by default.
    var unchecked: Pack = try .fromBytes(gpa, bent, .{ .verify = false });
    defer unchecked.deinit(io);
    var unchecked_source = unchecked.source();
    const got = try unchecked_source.read(io, gpa, "a.txt", one_mb);
    defer gpa.free(got);
    try testing.expect(!std.mem.eql(u8, "hello there", got));
}

// -------------------------------------------------------------------------
// Sealing and signing
// -------------------------------------------------------------------------

const key_a: Pack.Key = [_]u8{0xA1} ** 32;
const key_b: Pack.Key = [_]u8{0xB2} ** 32;
const salt_one = [_]u8{1} ** 16;
const salt_two = [_]u8{2} ** 16;

/// Bytes that do not compress, `len` of them.
fn noiseOf(len: usize, seed: u64) ![]u8 {
    const bytes = try gpa.alloc(u8, len);
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(bytes);
    return bytes;
}

test "a sealed pack gives nothing away without its key" {
    const noise = try noiseOf(Pack.chunk_len * 2 + 123, 11);
    defer gpa.free(noise);
    const long_text = compressible ** 12; // several chunks, deflated

    const built = try Pack.buildWith(gpa, .{ .seal = .{ .key = key_a, .salt = salt_one } }, &.{
        .{ .path = "secret/notes.txt", .bytes = compressible },
        .{ .path = "secret/noise.bin", .bytes = noise, .how = .store },
        .{ .path = "secret/long.txt", .bytes = long_text, .how = .deflate },
        .{ .path = "secret/empty.txt", .bytes = "" },
    });
    defer gpa.free(built);

    // Neither the contents nor, with the index hidden, the names.
    try testing.expect(std.mem.indexOf(u8, built, "the same sentence") == null);
    try testing.expect(std.mem.indexOf(u8, built, "secret/") == null);

    try testing.expectError(error.KeyNeeded, Pack.fromBytes(gpa, built, .{}));
    try testing.expectError(error.WrongKey, Pack.fromBytes(gpa, built, .{ .key = key_b }));

    var pack: Pack = try .fromBytes(gpa, built, .{ .key = key_a });
    defer pack.deinit(io);
    var source = pack.source();
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "secret/notes.txt", .want = compressible },
        .{ .path = "secret/noise.bin", .want = noise },
        .{ .path = "secret/long.txt", .want = long_text },
        .{ .path = "secret/empty.txt", .want = "" },
    }) |item| {
        const got = try source.read(io, gpa, item.path, .unlimited);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, item.want, got);

        // And a piece at a time, which opens one chunk at a time.
        var stream = try source.open(io, gpa, item.path);
        defer stream.close(io);
        var pieced: std.ArrayListUnmanaged(u8) = .empty;
        defer pieced.deinit(gpa);
        while (true) {
            const piece = stream.reader.take(1000) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try pieced.appendSlice(gpa, piece);
        }
        const rest = try stream.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(rest);
        try pieced.appendSlice(gpa, rest);
        try testing.expectEqualSlices(u8, item.want, pieced.items);
    }

    // A sealed entry is never handed out as a slice of the pack.
    try testing.expect(pack.slice("secret/noise.bin") == null);
}

test "a sealed pack can leave its names in the clear" {
    const built = try Pack.buildWith(gpa, .{ .seal = .{ .key = key_a, .salt = salt_one, .hide_index = false } }, &.{
        .{ .path = "levels/one.json", .bytes = compressible },
    });
    defer gpa.free(built);

    try testing.expect(std.mem.indexOf(u8, built, "levels/one.json") != null);
    try testing.expect(std.mem.indexOf(u8, built, "the same sentence") == null);

    var pack: Pack = try .fromBytes(gpa, built, .{ .key = key_a });
    defer pack.deinit(io);
    var source = pack.source();
    const got = try source.read(io, gpa, "levels/one.json", one_mb);
    defer gpa.free(got);
    try testing.expectEqualStrings(compressible, got);
}

test "a sealed chunk that changed or moved does not open" {
    const noise = try noiseOf(Pack.chunk_len * 3, 12);
    defer gpa.free(noise);

    const built = try Pack.buildWith(gpa, .{ .seal = .{ .key = key_a, .salt = salt_one } }, &.{
        .{ .path = "a.bin", .bytes = noise, .how = .store },
    });
    defer gpa.free(built);
    const bent = try gpa.dupe(u8, built);
    defer gpa.free(bent);

    // One bit, anywhere in a chunk.
    bent[Pack.header_size + 5000] ^= 1;
    {
        var pack: Pack = try .fromBytes(gpa, bent, .{ .key = key_a });
        defer pack.deinit(io);
        var source = pack.source();
        try testing.expectError(error.Corrupt, source.read(io, gpa, "a.bin", one_mb));
    }

    // Two whole chunks swapped: each is a good seal, in the wrong place.
    @memcpy(bent, built);
    const first = bent[Pack.header_size..][0..Pack.chunk_len];
    const second = bent[Pack.header_size + Pack.chunk_len ..][0..Pack.chunk_len];
    const held = try gpa.dupe(u8, first);
    defer gpa.free(held);
    @memcpy(first, second);
    @memcpy(second, held);
    {
        var pack: Pack = try .fromBytes(gpa, bent, .{ .key = key_a });
        defer pack.deinit(io);
        var source = pack.source();
        try testing.expectError(error.Corrupt, source.read(io, gpa, "a.bin", one_mb));
    }
}

test "a signed pack is refused by a reader that trusts someone else, or once changed" {
    const ours = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{7} ** 32);
    const theirs = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{8} ** 32);
    const trusted = ours.public_key.toBytes();

    for ([_]?Pack.Builder.Seal{ null, .{ .key = key_a, .salt = salt_one } }) |seal| {
        const signed = try Pack.buildWith(gpa, .{ .seal = seal, .sign = ours }, &.{
            .{ .path = "a.txt", .bytes = compressible },
        });
        defer gpa.free(signed);
        const by_someone_else = try Pack.buildWith(gpa, .{ .seal = seal, .sign = theirs }, &.{
            .{ .path = "a.txt", .bytes = compressible },
        });
        defer gpa.free(by_someone_else);
        const unsigned = try Pack.buildWith(gpa, .{ .seal = seal }, &.{
            .{ .path = "a.txt", .bytes = compressible },
        });
        defer gpa.free(unsigned);

        var pack: Pack = try .fromBytes(gpa, signed, .{ .key = key_a, .signed_by = trusted });
        defer pack.deinit(io);
        var source = pack.source();
        const got = try source.read(io, gpa, "a.txt", one_mb);
        defer gpa.free(got);
        try testing.expectEqualStrings(compressible, got);

        try testing.expectError(error.NotSigned, Pack.fromBytes(gpa, by_someone_else, .{ .key = key_a, .signed_by = trusted }));
        try testing.expectError(error.NotSigned, Pack.fromBytes(gpa, unsigned, .{ .key = key_a, .signed_by = trusted }));

        // A byte of the index changed, as a patched check would be.
        const bent = try gpa.dupe(u8, signed);
        defer gpa.free(bent);
        const at = std.mem.readInt(u64, signed[signed.len - 8 ..][0..8], .little);
        bent[@intCast(at + 3)] ^= 1;
        try testing.expectError(error.NotSigned, Pack.fromBytes(gpa, bent, .{ .key = key_a, .signed_by = trusted }));

        // A reader that trusts nobody reads a signed pack like any other.
        var anyone: Pack = try .fromBytes(gpa, signed, .{ .key = key_a });
        anyone.deinit(io);
    }
}

test "a pack that is only part of a file, as one written onto a program" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const built = try Pack.buildWith(gpa, .{ .seal = .{ .key = key_a, .salt = salt_one } }, &.{
        .{ .path = "a.txt", .bytes = "inside" },
        .{ .path = "b.txt", .bytes = compressible },
    });
    defer gpa.free(built);

    const before = "a program of its own " ** 50;
    const after = "and something written after it";
    const whole = try std.mem.concat(gpa, u8, &.{ before, built, after });
    defer gpa.free(whole);
    try put(tmp.dir, "game.exe", whole);

    const file = try tmp.dir.openFile(io, "game.exe", .{});
    defer file.close(io);
    var pack: Pack = try .fromFileRegion(gpa, io, file, before.len, built.len, .{ .key = key_a });
    defer pack.deinit(io);
    var source = pack.source();
    const got = try source.read(io, gpa, "b.txt", one_mb);
    defer gpa.free(got);
    try testing.expectEqualStrings(compressible, got);

    // Mounted the same way, owning the file.
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    const owned = try tmp.dir.openFile(io, "game.exe", .{});
    _ = files.mountPackRegion(io, "", owned, true, before.len, built.len, .{ .key = key_a }) catch |err| {
        owned.close(io);
        return err;
    };
    try expectFile(&files, "a.txt", "inside");
}

test "a rebuilt pack can take another seal, or none" {
    const noise = try noiseOf(Pack.chunk_len + 77, 13);
    defer gpa.free(noise);

    const old = try Pack.buildWith(gpa, .{ .seal = .{ .key = key_a, .salt = salt_one } }, &.{
        .{ .path = "keep.txt", .bytes = compressible ** 3, .how = .deflate },
        .{ .path = "noise.bin", .bytes = noise, .how = .store },
    });
    defer gpa.free(old);
    var before: Pack = try .fromBytes(gpa, old, .{ .key = key_a });
    defer before.deinit(io);

    for ([_]?Pack.Builder.Seal{ .{ .key = key_b, .salt = salt_two }, null }) |seal| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var builder: Pack.Builder = try .initFrom(gpa, &out.writer, .{ .seal = seal }, &before, io);
        defer builder.deinit();
        try builder.add("new.txt", "brand new", .store);
        try builder.finish();

        if (seal != null) {
            try testing.expectError(error.WrongKey, Pack.fromBytes(gpa, out.written(), .{ .key = key_a }));
        }
        var after: Pack = try .fromBytes(gpa, out.written(), .{ .key = key_b });
        defer after.deinit(io);

        // Still deflated: opened and sealed again, never inflated.
        try testing.expectEqual(Pack.Compression.flate, after.find("keep.txt").?.compression);
        var source = after.source();
        const kept = try source.read(io, gpa, "keep.txt", one_mb);
        defer gpa.free(kept);
        try testing.expectEqualStrings(compressible ** 3, kept);
        const moved = try source.read(io, gpa, "noise.bin", one_mb);
        defer gpa.free(moved);
        try testing.expectEqualSlices(u8, noise, moved);
    }
}

test "an entry bigger than the caller will take" {
    const built = try Pack.build(gpa, &.{.{ .path = "big.bin", .bytes = "0123456789" }});
    defer gpa.free(built);

    var pack: Pack = try .fromBytes(gpa, built, .{});
    defer pack.deinit(io);
    var source = pack.source();

    try testing.expectError(error.TooLarge, source.read(io, gpa, "big.bin", .limited(4)));
    const got = try source.read(io, gpa, "big.bin", .limited(10));
    defer gpa.free(got);
    try testing.expectEqualStrings("0123456789", got);
}

test "a pack read out of a file, an entry at a time" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const built = try Pack.build(gpa, &.{
        .{ .path = "a.txt", .bytes = "first" },
        .{ .path = "b.txt", .bytes = compressible },
    });
    defer gpa.free(built);
    try put(tmp.dir, "assets.fxpk", built);

    const file = try tmp.dir.openFile(io, "assets.fxpk", .{});
    defer file.close(io);

    var pack: Pack = try .fromFile(gpa, io, file, .{});
    defer pack.deinit(io);
    var source = pack.source();

    // The bytes are on disk, not in memory: this is the path a shipped game
    // takes for a pack too big to hold.
    const stored = try source.read(io, gpa, "a.txt", one_mb);
    defer gpa.free(stored);
    try testing.expectEqualStrings("first", stored);

    const inflated = try source.read(io, gpa, "b.txt", one_mb);
    defer gpa.free(inflated);
    try testing.expectEqualStrings(compressible, inflated);
}

// -------------------------------------------------------------------------
// Mounting
// -------------------------------------------------------------------------

test "the last mount wins, and unmounting puts back what it hid" {
    var base = testing.tmpDir(.{ .iterate = true });
    defer base.cleanup();
    var patch = testing.tmpDir(.{ .iterate = true });
    defer patch.cleanup();

    try put(base.dir, "ui/cursor.png", "the old cursor");
    try put(base.dir, "ui/panel.png", "the only panel");
    try put(patch.dir, "ui/cursor.png", "the new cursor");

    var base_source: Dir = .adopt(base.dir, .{});
    var patch_source: Dir = .adopt(patch.dir, .{});

    var files: Vfs = .init(gpa);
    defer files.deinit(io);

    _ = try files.mount("", base_source.source());
    const patch_id = try files.mount("", patch_source.source());

    try expectFile(&files, "ui/cursor.png", "the new cursor");
    // What the patch does not have still comes from underneath it.
    try expectFile(&files, "ui/panel.png", "the only panel");

    // And which mount answered is a question with an answer.
    try testing.expectEqual(patch_id, (try files.locate(io, "ui/cursor.png")).?.mount);

    files.unmount(io, patch_id);
    try expectFile(&files, "ui/cursor.png", "the old cursor");
}

test "a mount under a prefix holds only what is under it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "ui/cursor.png", "cursor");

    var source: Dir = .adopt(tmp.dir, .{});
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("textures", source.source());

    try expectFile(&files, "textures/ui/cursor.png", "cursor");
    // Spelled any of the ways that mean the same path.
    try expectFile(&files, "/textures/ui/cursor.png", "cursor");
    try expectFile(&files, "textures//ui/../ui/cursor.png", "cursor");

    // And nothing outside the prefix reaches it.
    try testing.expect(!try files.exists(io, "ui/cursor.png"));
    try testing.expect(!try files.exists(io, "textures-old/ui/cursor.png"));
}

test "a pack under a directory, which is what shipping and patching look like" {
    var patch = testing.tmpDir(.{ .iterate = true });
    defer patch.cleanup();
    try put(patch.dir, "ui/cursor.png", "the patched cursor");

    const built = try Pack.build(gpa, &.{
        .{ .path = "ui/cursor.png", .bytes = "the shipped cursor" },
        .{ .path = "ui/panel.png", .bytes = "the shipped panel" },
    });
    defer gpa.free(built);

    var files: Vfs = .init(gpa);
    defer files.deinit(io);

    _ = try files.mountPackBytes("", built, .{});
    var patch_source: Dir = .adopt(patch.dir, .{});
    _ = try files.mount("", patch_source.source());

    try expectFile(&files, "ui/cursor.png", "the patched cursor");
    try expectFile(&files, "ui/panel.png", "the shipped panel");
}

test "a listing is every path once, whichever mount has it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "ui/cursor.png", "a");
    try put(tmp.dir, "ui/panel.png", "b");
    try put(tmp.dir, "notes.txt", "c");

    const built = try Pack.build(gpa, &.{
        .{ .path = "ui/cursor.png", .bytes = "shipped" },
        .{ .path = "ui/icon.png", .bytes = "shipped" },
    });
    defer gpa.free(built);

    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountPackBytes("", built, .{});
    var loose: Dir = .adopt(tmp.dir, .{});
    _ = try files.mount("", loose.source());

    const everything = try files.list(io, gpa, "");
    defer {
        for (everything) |p| gpa.free(p);
        gpa.free(everything);
    }
    // cursor.png is in both mounts and is named once.
    const want = [_][]const u8{ "notes.txt", "ui/cursor.png", "ui/icon.png", "ui/panel.png" };
    try testing.expectEqual(want.len, everything.len);
    for (want, everything) |a, b| try testing.expectEqualStrings(a, b);

    const pngs = try files.list(io, gpa, "ui/*.png");
    defer {
        for (pngs) |p| gpa.free(p);
        gpa.free(pngs);
    }
    try testing.expectEqual(@as(usize, 3), pngs.len);
}

test "writing goes to the mount that will take it" {
    var read_only = testing.tmpDir(.{ .iterate = true });
    defer read_only.cleanup();
    var saves = testing.tmpDir(.{ .iterate = true });
    defer saves.cleanup();

    try put(read_only.dir, "ui/cursor.png", "cursor");

    var assets: Dir = .adopt(read_only.dir, .{});
    var writable: Dir = .adopt(saves.dir, .{ .writable = true });

    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", assets.source());

    // With nothing writable mounted, a save has nowhere to go, and saying so
    // beats inventing somewhere.
    try testing.expectError(error.ReadOnly, files.write(io, "save/slot1.fxdt", "x"));

    _ = try files.mount("save", writable.source());

    // The directories a save needs are made on the way.
    try files.write(io, "save/deep/slot1.fxdt", "the first slot");
    try expectFile(&files, "save/deep/slot1.fxdt", "the first slot");

    // A path outside the writable mount's prefix still has nowhere to go.
    try testing.expectError(error.ReadOnly, files.write(io, "ui/cursor.png", "no"));

    try files.remove(io, "save/deep/slot1.fxdt");
    try testing.expect(!try files.exists(io, "save/deep/slot1.fxdt"));
    try testing.expectError(error.FileNotFound, files.remove(io, "save/deep/slot1.fxdt"));
}

test "a path that climbs out of the namespace never reaches a source" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "ui/cursor.png", "cursor");

    var source: Dir = .adopt(tmp.dir, .{});
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    try testing.expectError(error.EscapesRoot, files.read(io, gpa, "../../etc/passwd", one_mb));
    try testing.expectError(error.EscapesRoot, files.read(io, gpa, "ui/../../x", one_mb));
    try testing.expectError(error.EmptyPath, files.read(io, gpa, "", one_mb));
    // And the rules apply to writing as well as reading.
    try testing.expectError(error.EscapesRoot, files.write(io, "../x", "no"));
}

test "a directory is not an asset" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "ui/cursor.png", "cursor");

    var source: Dir = .adopt(tmp.dir, .{});
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    try testing.expect(try files.exists(io, "ui/cursor.png"));
    try testing.expect(!try files.exists(io, "ui"));
    try testing.expectError(error.FileNotFound, files.read(io, gpa, "ui", one_mb));
}

// -------------------------------------------------------------------------
// Watching
// -------------------------------------------------------------------------

test "a change is reported once, after it has settled" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "level.txt", "one");

    var source: Dir = .adopt(tmp.dir, .{ .writable = true });
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0; // no waiting, so the test does not either
    try watch.add("level.txt");

    // The first poll finds it, which is news to a watch that had not seen it.
    {
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqual(Watch.Change.Kind.added, changes[0].kind);
        try testing.expectEqualStrings("level.txt", changes[0].path);
    }
    // Nothing happened since, and nothing is reported.
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);

    // A different size is a change whatever the clock's resolution is.
    try put(tmp.dir, "level.txt", "one and then some more");
    {
        // The first poll after a write only notices; the second confirms.
        _ = try watch.poll(&files, io);
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqual(Watch.Change.Kind.changed, changes[0].kind);
    }
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
}

test "a file still being written is not reported yet" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "level.txt", "one");

    var source: Dir = .adopt(tmp.dir, .{ .writable = true });
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = std.time.ns_per_hour;
    try watch.add("level.txt");
    _ = try watch.poll(&files, io); // the `added`

    try put(tmp.dir, "level.txt", "one and then some more");
    // However many times it is asked, a change that has not held still for an
    // hour is not reported.
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);

    // And once the wait is over it is reported exactly once.
    watch.settle = 0;
    try testing.expectEqual(@as(usize, 1), (try watch.poll(&files, io)).len);
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
}

test "a file that goes away, and one that comes back" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "level.txt", "one");

    var source: Dir = .adopt(tmp.dir, .{ .writable = true });
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0;
    try watch.add("level.txt");
    _ = try watch.poll(&files, io);

    try files.remove(io, "level.txt");
    {
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqual(Watch.Change.Kind.removed, changes[0].kind);
        // The path is still readable here, which is what the watch promises.
        try testing.expectEqualStrings("level.txt", changes[0].path);
    }
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);

    // A path the caller named is still watched after it goes, so its return
    // is news.
    try put(tmp.dir, "level.txt", "back again");
    {
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqual(Watch.Change.Kind.added, changes[0].kind);
    }
}

test "a mount appearing over a file is a change, though no file was touched" {
    var base = testing.tmpDir(.{ .iterate = true });
    defer base.cleanup();
    var patch = testing.tmpDir(.{ .iterate = true });
    defer patch.cleanup();

    try put(base.dir, "ui/cursor.png", "the old cursor");
    try put(patch.dir, "ui/cursor.png", "the new cursor");

    var base_source: Dir = .adopt(base.dir, .{});
    var patch_source: Dir = .adopt(patch.dir, .{});

    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", base_source.source());

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0;
    try watch.add("ui/cursor.png");
    _ = try watch.poll(&files, io);
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);

    // Nothing on either disk moved, but the bytes behind the path did.
    const patch_id = try files.mount("", patch_source.source());
    {
        _ = try watch.poll(&files, io);
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqual(Watch.Change.Kind.changed, changes[0].kind);
    }
    try expectFile(&files, "ui/cursor.png", "the new cursor");

    // And taking the patch away is a change in the other direction.
    files.unmount(io, patch_id);
    _ = try watch.poll(&files, io);
    const changes = try watch.poll(&files, io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Watch.Change.Kind.changed, changes[0].kind);
}

test "a glob watches files that did not exist when it was added" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "levels/one.txt", "one");

    var source: Dir = .adopt(tmp.dir, .{ .writable = true });
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0;
    try watch.addGlob("levels/*.txt");

    {
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqualStrings("levels/one.txt", changes[0].path);
    }

    // A file nobody knew about when the glob was written.
    try put(tmp.dir, "levels/two.txt", "two");
    {
        const changes = try watch.poll(&files, io);
        try testing.expectEqual(@as(usize, 1), changes.len);
        try testing.expectEqual(Watch.Change.Kind.added, changes[0].kind);
        try testing.expectEqualStrings("levels/two.txt", changes[0].path);
    }

    // One the glob does not match is not watched at all.
    try put(tmp.dir, "levels/three.png", "three");
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
}

test "a path inside a pack costs nothing to watch" {
    const built = try Pack.build(gpa, &.{.{ .path = "ui/cursor.png", .bytes = "shipped" }});
    defer gpa.free(built);

    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountPackBytes("", built, .{});

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0;
    try watch.add("ui/cursor.png");

    // Found once, and then never again: a pack reports no modification time
    // because it has none.
    try testing.expectEqual(@as(usize, 1), (try watch.poll(&files, io)).len);
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
}

test "forgetting a path stops the reports" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "level.txt", "one");

    var source: Dir = .adopt(tmp.dir, .{ .writable = true });
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0;
    try watch.add("level.txt");
    try watch.add("level.txt"); // twice is once
    try testing.expectEqual(@as(usize, 1), watch.count());

    _ = try watch.poll(&files, io);
    watch.forget("level.txt");
    try testing.expectEqual(@as(usize, 0), watch.count());

    try put(tmp.dir, "level.txt", "one and then some more");
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);
}
