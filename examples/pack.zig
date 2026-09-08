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
    /// How many worker threads compress with. Null is one per spare core;
    /// zero is this thread alone, which is what a browser build has.
    jobs: ?u32 = null,

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
            } else if (std.mem.eql(u8, argument, "--jobs")) {
                if (i + 1 >= arguments.len) return null;
                self.jobs = std.fmt.parseInt(u32, arguments[i + 1], 10) catch return null;
                i += 1;
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
        \\  --jobs <n>         compress on n threads; 0 for this one alone
        \\
    );
}

// -------------------------------------------------------------------------
// Feeding the builder
// -------------------------------------------------------------------------

/// How much is read from disk and compressed at a time. Bounded so that
/// packing a directory of any size costs the same memory as packing a small
/// one.
const batch_items = 256;
const batch_bytes = 64 << 20;

/// Read every path and hand it to `builder`, a batch at a time, compressing
/// each batch across `jobs`.
///
/// The reading is one file at a time and the compressing is all of them at
/// once, which is the right way round: reading is the disk to answer for and
/// compressing is the machine to answer for.
fn feed(
    gpa: std.mem.Allocator,
    io: Io,
    files: *vfs.Vfs,
    builder: *vfs.Pack.Builder,
    jobs: *vfs.Jobs,
    paths: []const []const u8,
    options: Options,
    replaced: ?*usize,
    old_pack: ?*const vfs.Pack,
) !u64 {
    var batch: std.ArrayListUnmanaged(vfs.Pack.Builder.Item) = .empty;
    defer batch.deinit(gpa);
    var held: usize = 0;
    var total: u64 = 0;

    for (paths) |path| {
        const bytes = try files.read(io, gpa, path, .limited(1 << 30));
        total += bytes.len;

        if (old_pack) |pack| {
            if (pack.find(path) != null) {
                // Replacing a carried entry: take the old one out first, or
                // adding it is a duplicate.
                try builder.remove(path);
                if (replaced) |count| count.* += 1;
            }
        }

        try batch.append(gpa, .{ .path = path, .bytes = bytes, .how = how(path, options.store) });
        held += bytes.len;

        if (batch.items.len >= batch_items or held >= batch_bytes) {
            try flush(gpa, builder, jobs, &batch);
            held = 0;
        }
    }
    try flush(gpa, builder, jobs, &batch);
    return total;
}

fn flush(
    gpa: std.mem.Allocator,
    builder: *vfs.Pack.Builder,
    jobs: *vfs.Jobs,
    batch: *std.ArrayListUnmanaged(vfs.Pack.Builder.Item),
) !void {
    defer {
        // The paths belong to the listing; only the contents were read here.
        for (batch.items) |item| gpa.free(item.bytes);
        batch.clearRetainingCapacity();
    }
    try builder.addAll(jobs, batch.items);
}

fn startJobs(gpa: std.mem.Allocator, io: Io, options: Options) !vfs.Jobs {
    return vfs.Jobs.init(gpa, .{
        .io = io,
        .workers = if (options.jobs) |n| .{ .count = n } else .auto,
        // One batch in flight, and a little room to spare.
        .capacity = batch_items + 8,
    });
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

    var jobs = try startJobs(gpa, io, options);
    defer jobs.deinit();

    var file = try Io.Dir.cwd().createFile(io, options.pack, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);

    var builder: vfs.Pack.Builder = try .init(gpa, &writer.interface);
    defer builder.deinit();

    const raw = try feed(gpa, io, &files, &builder, &jobs, found, options, null, null);
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
    try out.print(", {d} workers\n", .{jobs.workerCount()});
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
        var jobs = try startJobs(gpa, io, options);
        defer jobs.deinit();

        var file = try Io.Dir.cwd().createFile(io, staging, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);

        // Everything the old pack had is carried as it was stored; what the
        // directory has replaces what it names, and nothing else moves.
        var builder: vfs.Pack.Builder = try .initFrom(gpa, &writer.interface, &old, io);
        defer builder.deinit();

        _ = try feed(gpa, io, &files, &builder, &jobs, found, options, &replaced, &old);
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
