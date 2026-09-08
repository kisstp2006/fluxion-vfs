// SPDX-License-Identifier: BSD-2-Clause

//! The packer. Run it with `zig build pack -- <command> ...`.
//!
//!   `create <pack> <directory>`   put a directory into a pack
//!   `update <pack> <directory>`   put a directory over an existing pack
//!   `list <pack>`                 what is in one, and what it cost
//!   `extract <pack> <directory>`  take it back out
//!
//! It is a real tool and also the shortest honest example: a pack is built by
//! mounting a directory and reading it through the same `Vfs` a game uses, so
//! everything the library says about paths is true of what goes in.

const std = @import("std");
const Io = std.Io;
const vfs = @import("fluxion_vfs");

/// Extensions whose contents are already compressed, so deflating them again
/// buys nothing and costs a decompression on every load.
const already_compressed = [_][]const u8{
    ".png", ".jpg",  ".jpeg", ".gif",  ".webp",
    ".ogg", ".mp3",  ".flac", ".opus", ".mp4",
    ".zip", ".fxpk",
};

const Options = struct {
    command: Command,
    pack: []const u8,
    directory: []const u8 = "",
    /// Only paths matching this go in. Empty means all of them.
    glob: []const u8 = "",
    /// Store everything as it is, for a pack meant to be mapped and read
    /// without a decompressor.
    store: bool = false,

    const Command = enum { create, update, list, extract };

    fn fromArguments(init: std.process.Init, arena: std.mem.Allocator) !?Options {
        const arguments = try init.minimal.args.toSlice(arena);
        if (arguments.len < 3) return null;

        const command = std.meta.stringToEnum(Command, arguments[1]) orelse return null;
        var self: Options = .{ .command = command, .pack = arguments[2] };

        var i: usize = 3;
        while (i < arguments.len) : (i += 1) {
            const argument = arguments[i];
            if (std.mem.eql(u8, argument, "--glob")) {
                if (i + 1 >= arguments.len) return null;
                self.glob = arguments[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argument, "--store")) {
                self.store = true;
            } else if (std.mem.startsWith(u8, argument, "-")) {
                return null;
            } else if (self.directory.len == 0) {
                self.directory = argument;
            } else return null;
        }

        if (command != .list and self.directory.len == 0) return null;
        return self;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    const options = try Options.fromArguments(init, gpa) orelse {
        try usage(out);
        try out.flush();
        return;
    };

    switch (options.command) {
        .create => try create(gpa, io, out, options),
        .update => try update(gpa, io, out, options),
        .list => try list(gpa, io, out, options),
        .extract => try extract(gpa, io, out, options),
    }
    try out.flush();
}

fn usage(out: *Io.Writer) !void {
    try out.writeAll(
        \\usage: fluxion-pack <command> <pack> [directory] [options]
        \\
        \\  create <pack> <directory>   put a directory into a pack
        \\  list <pack>                 what is in one, and what it cost
        \\  extract <pack> <directory>  take it back out
        \\
        \\  --glob <pattern>   only paths matching it, `**` spanning components
        \\  --store            no compression, for a pack meant to be mapped
        \\
    );
}

// -------------------------------------------------------------------------
// create
// -------------------------------------------------------------------------

fn create(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, options: Options) !void {
    // The directory is read through a Vfs, so the paths that go into the pack
    // are the paths a game will ask for, normalized the same way.
    var files: vfs.Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountDir(io, "", options.directory, .{});

    const found = try files.list(io, gpa, options.glob);
    defer {
        for (found) |path| gpa.free(path);
        gpa.free(found);
    }

    var file = try Io.Dir.cwd().createFile(io, options.pack, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);

    var builder: vfs.Pack.Builder = try .init(gpa, &writer.interface);
    defer builder.deinit();

    var raw: u64 = 0;
    for (found) |path| {
        const bytes = try files.read(io, gpa, path, .limited(1 << 30));
        defer gpa.free(bytes);
        raw += bytes.len;
        try builder.add(path, bytes, how(path, options.store));
    }
    try builder.finish();
    try writer.interface.flush();

    const size = (try Io.Dir.cwd().statFile(io, options.pack, .{})).size;
    try out.print("{s}: {d} files, {d} bytes in, {d} bytes out", .{
        options.pack,
        found.len,
        raw,
        size,
    });
    if (raw != 0) try out.print(" ({d}%)", .{size * 100 / raw});
    try out.writeAll("\n");
}

fn how(path: []const u8, store_everything: bool) vfs.Pack.Builder.How {
    if (store_everything) return .store;
    for (already_compressed) |extension| {
        if (std.ascii.endsWithIgnoreCase(path, extension)) return .store;
    }
    return .auto;
}

// -------------------------------------------------------------------------
// update
// -------------------------------------------------------------------------

fn update(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, options: Options) !void {
    var files: vfs.Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountDir(io, "", options.directory, .{});

    const found = try files.list(io, gpa, options.glob);
    defer {
        for (found) |path| gpa.free(path);
        gpa.free(found);
    }

    // The old pack is read while the new one is written, so the new one goes
    // to a file beside it and takes its place only once it is whole.
    var old: vfs.Pack = try .openFile(gpa, io, options.pack, .{});
    defer old.deinit(io);

    const staging = try std.mem.concat(gpa, u8, &.{ options.pack, ".new" });
    defer gpa.free(staging);
    var replaced: usize = 0;
    {
        var file = try Io.Dir.cwd().createFile(io, staging, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);

        // Everything the old pack had is carried as it was stored; what the
        // directory has replaces what it names, and nothing else moves.
        var builder: vfs.Pack.Builder = try .initFrom(gpa, &writer.interface, &old, io);
        defer builder.deinit();

        for (found) |path| {
            const bytes = try files.read(io, gpa, path, .limited(1 << 30));
            defer gpa.free(bytes);
            if (old.find(path) != null) replaced += 1;
            try builder.remove(path);
            try builder.add(path, bytes, how(path, options.store));
        }
        try builder.finish();
        try writer.interface.flush();
    }
    try Io.Dir.cwd().rename(staging, Io.Dir.cwd(), options.pack, io);

    try out.print("{s}: {d} replaced, {d} added, {d} carried\n", .{
        options.pack,
        replaced,
        found.len - replaced,
        old.entries().len - replaced,
    });
}

// -------------------------------------------------------------------------
// list
// -------------------------------------------------------------------------

fn list(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, options: Options) !void {
    var pack: vfs.Pack = try .openFile(gpa, io, options.pack, .{});
    defer pack.deinit(io);

    var raw: u64 = 0;
    var stored: u64 = 0;
    try out.print("{s: <10} {s: >10} {s: >10}  {s}\n", .{ "stored", "size", "on disk", "path" });
    for (pack.entries()) |entry| {
        raw += entry.size;
        stored += entry.stored;
        try out.print("{s: <10} {d: >10} {d: >10}  {s}\n", .{
            @tagName(entry.compression),
            entry.size,
            entry.stored,
            entry.path,
        });
    }
    try out.print("\n{d} files, {d} bytes in {d} stored\n", .{ pack.entries().len, raw, stored });
}

// -------------------------------------------------------------------------
// extract
// -------------------------------------------------------------------------

fn extract(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, options: Options) !void {
    try Io.Dir.cwd().createDirPath(io, options.directory);

    var files: vfs.Vfs = .init(gpa);
    defer files.deinit(io);
    _ = try files.mountPack(io, "", options.pack, .{});
    // The destination is mounted too, so writing goes through the same rules
    // that reading did - including the ones about what a name may be.
    _ = try files.mountDir(io, "out", options.directory, .{ .writable = true });

    const found = try files.list(io, gpa, options.glob);
    defer {
        for (found) |path| gpa.free(path);
        gpa.free(found);
    }

    var count: usize = 0;
    for (found) |path| {
        // The listing includes the destination mount, which is empty on the
        // first run and not on the second.
        if (std.mem.startsWith(u8, path, "out/")) continue;

        const bytes = try files.read(io, gpa, path, .limited(1 << 30));
        defer gpa.free(bytes);

        const destination = try std.mem.concat(gpa, u8, &.{ "out/", path });
        defer gpa.free(destination);
        try files.write(io, destination, bytes);
        count += 1;
    }
    try out.print("{d} files into {s}\n", .{ count, options.directory });
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "already-compressed files are stored as they are" {
    try testing.expectEqual(vfs.Pack.Builder.How.store, how("ui/cursor.PNG", false));
    try testing.expectEqual(vfs.Pack.Builder.How.store, how("audio/step.ogg", false));
    try testing.expectEqual(vfs.Pack.Builder.How.auto, how("levels/one.txt", false));
    try testing.expectEqual(vfs.Pack.Builder.How.auto, how("shaders/quad.fx", false));
    // A name that merely ends in the letters is not an extension.
    try testing.expectEqual(vfs.Pack.Builder.How.auto, how("notes/apng", false));
    try testing.expectEqual(vfs.Pack.Builder.How.store, how("levels/one.txt", true));
}
