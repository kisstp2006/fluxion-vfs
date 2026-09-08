// SPDX-License-Identifier: BSD-2-Clause

//! The things that were left out of the first cut, against a real disk.
//!
//! Streams, memory mapping, rebuilding a pack from another, reads that finish
//! later, listings that start where their glob does, and a watch that takes
//! the kernel's word for when it can skip a poll.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Dir = @import("Dir.zig");
const Map = @import("Map.zig");
const Notify = @import("Notify.zig");
const Pack = @import("Pack.zig");
const Vfs = @import("Vfs.zig");
const Watch = @import("Watch.zig");

const io = testing.io;
const gpa = testing.allocator;
const one_mb: Io.Limit = .limited(1 << 20);

/// Text that deflates well.
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

/// The testing tmp dir as a path the kernel will take, relative to the
/// working directory the tests run in.
fn tmpPath(tmp: *const testing.TmpDir) ![]u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

// -------------------------------------------------------------------------
// Streams
// -------------------------------------------------------------------------

test "an asset read a piece at a time, from every kind of place" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "loose.txt", compressible);

    const built = try Pack.build(gpa, &.{
        .{ .path = "stored.txt", .bytes = compressible, .how = .store },
        .{ .path = "packed.txt", .bytes = compressible, .how = .deflate },
    });
    defer gpa.free(built);
    try put(tmp.dir, "assets.fxpk", built);

    var loose: Dir = .adopt(tmp.dir, .{});
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountPackBytes("", built, .{});
    _ = try files.mount("", loose.source());

    // A stream reads in pieces, and the pieces add up to the file.
    for ([_][]const u8{ "loose.txt", "stored.txt", "packed.txt" }) |path| {
        var stream = try files.open(io, gpa, path);
        defer stream.close(io);
        try testing.expectEqual(@as(u64, compressible.len), stream.size);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        while (true) {
            const piece = stream.reader.take(7) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try out.appendSlice(gpa, piece);
        }
        // The tail, shorter than a piece.
        const rest = try stream.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(rest);
        try out.appendSlice(gpa, rest);
        try testing.expectEqualStrings(compressible, out.items);
    }

    // And from a pack on disk, read from where the entry lies rather than
    // from a copy of the pack.
    const dir_path = try tmpPath(&tmp);
    defer gpa.free(dir_path);
    const pack_path = try std.fs.path.join(gpa, &.{ dir_path, "assets.fxpk" });
    defer gpa.free(pack_path);

    var on_disk: Pack = try .openFile(gpa, io, pack_path, .{});
    defer on_disk.deinit(io);
    var disk_source = on_disk.source();
    var stream = try disk_source.open(io, gpa, "packed.txt");
    defer stream.close(io);
    const whole = try stream.readRemaining(gpa, one_mb);
    defer gpa.free(whole);
    try testing.expectEqualStrings(compressible, whole);

    try testing.expectError(error.FileNotFound, files.open(io, gpa, "nope.txt"));
}

// -------------------------------------------------------------------------
// Mapping
// -------------------------------------------------------------------------

test "a mapped pack hands out a stored entry without a copy" {
    if (!Map.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const built = try Pack.build(gpa, &.{
        .{ .path = "stored.bin", .bytes = "as it is", .how = .store },
        .{ .path = "packed.txt", .bytes = compressible, .how = .deflate },
    });
    defer gpa.free(built);
    try put(tmp.dir, "assets.fxpk", built);

    const dir_path = try tmpPath(&tmp);
    defer gpa.free(dir_path);
    const pack_path = try std.fs.path.join(gpa, &.{ dir_path, "assets.fxpk" });
    defer gpa.free(pack_path);

    var pack: Pack = try .map(gpa, io, pack_path, .{});
    defer pack.deinit(io);

    // A slice into the mapping itself: inside the mapped range, no copy.
    const direct = pack.slice("stored.bin").?;
    try testing.expectEqualStrings("as it is", direct);
    const base = @intFromPtr(pack.mapping.?.bytes.ptr);
    try testing.expect(@intFromPtr(direct.ptr) >= base);
    try testing.expect(@intFromPtr(direct.ptr) < base + pack.mapping.?.bytes.len);

    // A compressed entry cannot be a slice, and says so rather than guessing.
    try testing.expect(pack.slice("packed.txt") == null);
    var source = pack.source();
    const inflated = try source.read(io, gpa, "packed.txt", one_mb);
    defer gpa.free(inflated);
    try testing.expectEqualStrings(compressible, inflated);

    // And the whole thing mounts like any other pack.
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountMappedPack(io, "", pack_path, .{});
    try expectFile(&files, "stored.bin", "as it is");
}

// -------------------------------------------------------------------------
// Rebuilding
// -------------------------------------------------------------------------

test "a pack rebuilt from another carries what it had, as it was stored" {
    const old = try Pack.build(gpa, &.{
        .{ .path = "keep.txt", .bytes = compressible, .how = .deflate },
        .{ .path = "drop.txt", .bytes = "goes away" },
        .{ .path = "replace.txt", .bytes = "the old one" },
    });
    defer gpa.free(old);
    var before: Pack = try .fromBytes(gpa, old, .{});
    defer before.deinit(io);
    const kept_before = before.find("keep.txt").?.*;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var builder: Pack.Builder = try .initFrom(gpa, &out.writer, &before, io);
    defer builder.deinit();

    // A carried path is taken, until it is removed.
    try testing.expectError(error.DuplicatePath, builder.add("replace.txt", "the new one", .store));
    try builder.remove("replace.txt");
    try builder.add("replace.txt", "the new one", .store);
    try builder.remove("drop.txt");
    try builder.remove("never-was.txt"); // not an error
    try builder.add("new.txt", "brand new", .store);
    try builder.finish();

    var after: Pack = try .fromBytes(gpa, out.written(), .{});
    defer after.deinit(io);

    try testing.expectEqual(@as(usize, 3), after.entries().len);
    try testing.expect(after.find("drop.txt") == null);

    // The carried entry kept its compression and its stored size: the bytes
    // were copied, not inflated and deflated again.
    const kept_after = after.find("keep.txt").?.*;
    try testing.expectEqual(kept_before.compression, kept_after.compression);
    try testing.expectEqual(kept_before.stored, kept_after.stored);
    try testing.expectEqual(kept_before.checksum, kept_after.checksum);

    var source = after.source();
    for ([_]struct { path: []const u8, want: []const u8 }{
        .{ .path = "keep.txt", .want = compressible },
        .{ .path = "replace.txt", .want = "the new one" },
        .{ .path = "new.txt", .want = "brand new" },
    }) |item| {
        const got = try source.read(io, gpa, item.path, one_mb);
        defer gpa.free(got);
        try testing.expectEqualStrings(item.want, got);
    }
}

// -------------------------------------------------------------------------
// Later
// -------------------------------------------------------------------------

test "a read that finishes when it is asked for" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "levels/two.bin", "the second level");

    var source: Dir = .adopt(tmp.dir, .{});
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var pending = files.readAsync(io, gpa, "levels/two.bin", one_mb);
    var missing = files.readAsync(io, gpa, "levels/nine.bin", one_mb);

    const got = try pending.await(io);
    defer gpa.free(got);
    try testing.expectEqualStrings("the second level", got);
    try testing.expectError(error.FileNotFound, missing.await(io));
}

// -------------------------------------------------------------------------
// Listing
// -------------------------------------------------------------------------

test "a listing starts where its glob does, and still names the whole path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "levels/one.txt", "1");
    try put(tmp.dir, "levels/deep/two.txt", "2");
    try put(tmp.dir, "textures/a.png", "a");

    var source: Dir = .adopt(tmp.dir, .{});
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    const one_level = try files.list(io, gpa, "levels/*.txt");
    defer {
        for (one_level) |p| gpa.free(p);
        gpa.free(one_level);
    }
    try testing.expectEqual(@as(usize, 1), one_level.len);
    try testing.expectEqualStrings("levels/one.txt", one_level[0]);

    const all_levels = try files.list(io, gpa, "levels/**/*.txt");
    defer {
        for (all_levels) |p| gpa.free(p);
        gpa.free(all_levels);
    }
    try testing.expectEqual(@as(usize, 2), all_levels.len);

    const exact = try files.list(io, gpa, "levels/deep/two.txt");
    defer {
        for (exact) |p| gpa.free(p);
        gpa.free(exact);
    }
    try testing.expectEqual(@as(usize, 1), exact.len);
    try testing.expectEqualStrings("levels/deep/two.txt", exact[0]);

    // A directory the glob names but that does not exist lists nothing.
    const none = try files.list(io, gpa, "audio/*.wav");
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

// -------------------------------------------------------------------------
// Watching, with the kernel
// -------------------------------------------------------------------------

test "a watch with the kernel's help sees the same things" {
    if (!Notify.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "level.txt", "one");
    const dir_path = try tmpPath(&tmp);
    defer gpa.free(dir_path);

    var source: Dir = .adopt(tmp.dir, .{ .writable = true });
    var files: Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mount("", source.source());

    var notify: Notify = .init(gpa);
    defer notify.deinit();
    try notify.add(io, dir_path);

    var watch: Watch = .init(gpa);
    defer watch.deinit();
    watch.settle = 0;
    watch.useNotify(&notify);
    try watch.add("level.txt");

    try testing.expectEqual(@as(usize, 1), (try watch.poll(&files, io)).len);
    try testing.expectEqual(@as(usize, 0), (try watch.poll(&files, io)).len);

    // A write on disk reaches the watch through the kernel, in its own time.
    try put(tmp.dir, "level.txt", "one and then some more");
    var reported: usize = 0;
    var tries: usize = 0;
    while (reported == 0 and tries < 100) : (tries += 1) {
        reported = (try watch.poll(&files, io)).len;
        if (reported == 0) try io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(@as(usize, 1), reported);

    // A mount changing is not something the kernel can know, and is seen
    // anyway, because the mount table counts its own changes.
    var other = testing.tmpDir(.{ .iterate = true });
    defer other.cleanup();
    try put(other.dir, "level.txt", "from another mount entirely");
    var over: Dir = .adopt(other.dir, .{});
    _ = try files.mount("", over.source());
    _ = try watch.poll(&files, io);
    const changes = try watch.poll(&files, io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Watch.Change.Kind.changed, changes[0].kind);
}
