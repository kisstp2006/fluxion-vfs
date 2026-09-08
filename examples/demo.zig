// SPDX-License-Identifier: BSD-2-Clause

//! A tour of Fluxion VFS. Run it with `zig build example`.
//!
//! It builds a small pack, mounts a patch directory over it, saves a file into
//! a third mount, and then watches one path while changing what is behind it -
//! first on disk, and then by mounting something on top.
//!
//! Everything it needs it makes under `zig-out/demo`, so it can be run twice.

const std = @import("std");
const Io = std.Io;
const vfs = @import("fluxion_vfs");

const root = "zig-out/demo";
const pack_path = root ++ "/assets.fxpk";
const patch_dir = root ++ "/patch";
const save_dir = root ++ "/saves";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    try setUp(gpa, io);

    // --- the mount table ------------------------------------------------

    var files: vfs.Vfs = .init(gpa);
    defer files.deinit(io);

    const shipped = try files.mountPack(io, "", pack_path, .{});
    const patched = try files.mountDir(io, "", patch_dir, .{});
    _ = try files.mountDir(io, "save", save_dir, .{ .writable = true });

    try out.print("--- three mounts, and one namespace ---\n", .{});
    try out.print("{s: <22} {s: >8}  {s}\n", .{ "path", "bytes", "from" });
    for ([_][]const u8{
        "ui/cursor.png",
        "ui/panel.png",
        "levels/one.txt",
    }) |path| {
        const found = (try files.locate(io, path)).?;
        try out.print("{s: <22} {d: >8}  {s}\n", .{
            path,
            found.stat.size,
            if (found.mount == patched) "the patch" else if (found.mount == shipped) "the pack" else "a save",
        });
    }

    // The patch shadows one file and leaves the rest where they were.
    const cursor = try files.read(io, gpa, "ui/cursor.png", .limited(1 << 20));
    try out.print("\nui/cursor.png says: {s}\n", .{cursor});

    // --- listing --------------------------------------------------------

    const pngs = try files.list(io, gpa, "ui/*.png");
    try out.print("\n--- ui/*.png, across every mount, each name once ---\n", .{});
    for (pngs) |path| try out.print("{s}\n", .{path});

    // --- saving ---------------------------------------------------------

    // The only writable mount is `save`, so this is where a save can go and
    // the only place it can.
    try files.write(io, "save/slot1.txt", "level 7, three lives");
    const slot = try files.read(io, gpa, "save/slot1.txt", .limited(1 << 20));
    try out.print("\n--- the one writable mount ---\nsave/slot1.txt: {s}\n", .{slot});

    if (files.write(io, "ui/cursor.png", "no")) |_| {
        try out.print("ui/cursor.png was written, which it should not have been\n", .{});
    } else |err| {
        try out.print("writing ui/cursor.png: {s}\n", .{@errorName(err)});
    }

    // --- what a path may not be -----------------------------------------

    try out.print("\n--- what is not a path ---\n", .{});
    for ([_][]const u8{ "../../etc/passwd", "ui/../../x", "ui/CON", "textures/a:b.png" }) |bad| {
        if (files.read(io, gpa, bad, .limited(1 << 20))) |_| {
            try out.print("{s: <20} was read, which it should not have been\n", .{bad});
        } else |err| {
            try out.print("{s: <20} {s}\n", .{ bad, @errorName(err) });
        }
    }

    // --- the same pack, three ways in ---------------------------------

    try out.print("\n--- one asset, read three ways ---\n", .{});
    // Whole, which is what a texture wants.
    const whole = try files.read(io, gpa, "levels/one.txt", .limited(1 << 20));
    try out.print("read:   {s}\n", .{whole});
    // A piece at a time, which is what a video wants.
    var stream = try files.open(io, gpa, "levels/one.txt");
    defer stream.close(io);
    const first_word = try stream.reader.takeDelimiterExclusive(',');
    try out.print("stream: {s}... ({d} bytes in all)\n", .{ first_word, stream.size });
    // Started now and collected later, which is what a loading screen wants.
    var later = files.readAsync(io, gpa, "ui/panel.png", .limited(1 << 20));
    const panel = try later.await(io);
    try out.print("async:  {s}\n", .{panel});

    if (vfs.Map.supported) {
        // A pack mapped rather than read: opened in the time it takes to
        // read the index, and an uncompressed entry is a slice of the file.
        var mapped: vfs.Pack = try .map(gpa, io, pack_path, .{});
        defer mapped.deinit(io);
        try out.print("mapped: {s} (no copy)\n", .{mapped.slice("ui/panel.png").?});
    }

    // --- hot reload -----------------------------------------------------

    var watch: vfs.Watch = .init(gpa);
    defer watch.deinit();
    // A tenth of a second by default, so an editor's half-written file is not
    // reloaded. Nothing here is half-written, so there is nothing to wait for.
    watch.settle = 0;
    try watch.add("levels/one.txt");

    try out.print("\n--- watching levels/one.txt ---\n", .{});
    try report(out, "the first look", try watch.poll(&files, io));
    try report(out, "nothing happened", try watch.poll(&files, io));

    // An artist saves the file.
    try writeFile(io, patch_dir ++ "/levels/one.txt", "a level, rewritten, and longer than it was");
    _ = try watch.poll(&files, io); // notices
    try report(out, "the file was rewritten", try watch.poll(&files, io));

    // And now nothing on disk moves, but a mount appears on top of it.
    const extra = try files.mountDir(io, "", root ++ "/mod", .{});
    _ = try watch.poll(&files, io);
    try report(out, "a mod was mounted over it", try watch.poll(&files, io));

    const level = try files.read(io, gpa, "levels/one.txt", .limited(1 << 20));
    try out.print("levels/one.txt now says: {s}\n", .{level});

    files.unmount(io, extra);
    _ = try watch.poll(&files, io);
    try report(out, "and the mod was taken away", try watch.poll(&files, io));

    try out.flush();
}

fn report(out: *Io.Writer, what: []const u8, changes: []const vfs.Watch.Change) !void {
    if (changes.len == 0) {
        try out.print("{s: <26} nothing\n", .{what});
        return;
    }
    for (changes) |change| {
        try out.print("{s: <26} {s} {s}\n", .{ what, @tagName(change.kind), change.path });
    }
}

// -------------------------------------------------------------------------
// The files this demo needs
// -------------------------------------------------------------------------

fn setUp(gpa: std.mem.Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    // A previous run's patch would make the tour tell a different story.
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);

    const built = try vfs.Pack.build(gpa, &.{
        .{ .path = "ui/cursor.png", .bytes = "the cursor that shipped" },
        .{ .path = "ui/panel.png", .bytes = "the panel that shipped" },
        .{ .path = "levels/one.txt", .bytes = "a level, as it shipped" },
    });
    defer gpa.free(built);
    try writeFile(io, pack_path, built);

    try writeFile(io, patch_dir ++ "/ui/cursor.png", "the cursor from the patch");
    try writeFile(io, patch_dir ++ "/levels/one.txt", "a level, as it was patched");
    try writeFile(io, root ++ "/mod/levels/one.txt", "a level, as a mod left it");
    try cwd.createDirPath(io, save_dir);
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |cut| {
        try Io.Dir.cwd().createDirPath(io, path[0..cut]);
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a pack built here is a pack that opens" {
    const gpa = std.testing.allocator;
    const built = try vfs.Pack.build(gpa, &.{.{ .path = "ui/cursor.png", .bytes = "x" }});
    defer gpa.free(built);

    var pack: vfs.Pack = try .fromBytes(gpa, built, .{});
    defer pack.deinit(std.testing.io);
    try std.testing.expect(pack.find("ui/cursor.png") != null);
}
