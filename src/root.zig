// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion VFS - one namespace, whatever is behind it.
//!
//!   `Vfs`     the mount table, and the verbs: read, write, list, locate
//!   `Dir`     a directory on disk, as a source
//!   `Pack`    one file holding many, as a source, and the builder that makes one
//!   `Stream`  an asset read a piece at a time
//!   `Watch`   what changed since you last asked
//!   `Notify`  the kernel's word on whether anything did, so a poll can be skipped
//!   `Source`  what any of the above is, so a game can add its own
//!   `vpath`   what a virtual path is, and what it is not
//!
//! ```zig
//! const vfs = @import("fluxion_vfs");
//!
//! var files: vfs.Vfs = .init(gpa);
//! defer files.deinit(io);
//!
//! _ = try files.mountPack(io, "", "assets.fxpk", .{});          // what shipped
//! _ = try files.mountDir(io, "", "patch", .{});                 // what was patched
//! _ = try files.mountDir(io, "save", "saves", .{ .writable = true });
//!
//! const bytes = try files.read(io, gpa, "ui/cursor.png", .limited(1 << 20));
//! defer gpa.free(bytes);
//! ```
//!
//! **A game asks for a path, not for a file.** Where the bytes came from - a
//! pack on a disc, a patch downloaded last night, the folder an artist is
//! saving into right now - is the mount table's business, and changing it is
//! how a patch, a mod, or a development build differs from a shipped one. The
//! loader above does not change at all.
//!
//! **The last mount wins**, so "on top" means what it sounds like. `locate`
//! says which mount actually answered, for when the question is why.
//!
//! **A path is one spelling.** `vpath.normalize` runs on everything coming in:
//! `/`, no `.` or `..` left, and nothing that climbs above the root. Names that
//! work on one filesystem and not another - a colon, a trailing dot, `CON` -
//! are refused on every platform, at the point the path is first seen, rather
//! than on the machine the game ships to.
//!
//! **Nothing here allocates except through the allocator it is handed**, and a
//! lookup allocates nothing at all: the path is normalized into a stack buffer
//! and the mounts are walked in place.
//!
//! It knows nothing about what is in a file. Decoding a PNG is `fluxion-image`,
//! reading a save is `fluxion-data`; this puts the bytes in their hands.

const std = @import("std");

pub const Vfs = @import("Vfs.zig");
pub const Dir = @import("Dir.zig");
pub const Pack = @import("Pack.zig");
pub const Watch = @import("Watch.zig");
pub const Notify = @import("Notify.zig");
pub const Source = @import("Source.zig");
pub const Stream = @import("Stream.zig");
pub const Map = @import("Map.zig");
pub const vpath = @import("vpath.zig");

/// The scheduler a parallel pack build runs on, re-exported so a caller need
/// not depend on it by name. See `Pack.Builder.addAll`.
pub const Jobs = @import("fluxion_jobs").Jobs;

/// Everything a mount table can answer with. See `Source.Error` and
/// `vpath.Error`.
pub const Error = Vfs.Error;

/// Which mount, and what is there. See `Vfs.locate`.
pub const Located = Vfs.Located;

/// What a source says about a path it has. See `Source`.
pub const Stat = Source.Stat;

/// Start an empty mount table. Shorthand for `Vfs.init`.
pub fn init(gpa: std.mem.Allocator) Vfs {
    return .init(gpa);
}

test {
    _ = Vfs;
    _ = Dir;
    _ = Pack;
    _ = Watch;
    _ = Notify;
    _ = Source;
    _ = Stream;
    _ = Map;
    _ = vpath;
    _ = @import("vfs_test.zig");
    _ = @import("later_test.zig");
}
