# Fluxion VFS

One namespace, whatever is behind it. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Vfs` | The mount table, and the verbs: `read`, `write`, `list`, `locate`. |
| `Dir` | A directory on disk, as a source. The only kind that can be written to. |
| `Pack` | One file holding many, as a source, and the builder that makes one. |
| `Watch` | What changed since you last asked. |
| `Source` | What any of the above is, so a game can add its own. |
| `vpath` | What a virtual path is, and what it is not. |

```zig
const vfs = @import("fluxion_vfs");

var files: vfs.Vfs = .init(gpa);
defer files.deinit(io);

_ = try files.mountPack(io, "", "assets.fxpk", .{});   // what shipped
_ = try files.mountDir(io, "", "patch", .{});          // what was patched
_ = try files.mountDir(io, "save", "saves", .{ .writable = true });

const bytes = try files.read(io, gpa, "ui/cursor.png", .limited(1 << 20));
defer gpa.free(bytes);
```

**A game asks for a path, not for a file.** Where the bytes came from is the
mount table's business, and changing it is the whole of what separates a
shipped build from a patched one, a modded one, or the one an artist is
working in. The loader above does not change at all.

**The last mount wins**, so "on top" means what it sounds like. `locate` says
which mount actually answered, for when the question is why.

**A path is one spelling.** `textures//ui/../ui/cursor.png` and
`textures/ui/cursor.png` are the same asset and normalize to the same bytes,
so a cache keyed on one does not miss on the other. Nothing climbs above the
root: `..` that would is an error, not a silent no-op.

**And a name that only works on one machine is refused on all of them.** A
colon, a trailing dot or space, a control byte, `CON` or `COM1` - Windows will
not take them, some of them it silently mangles instead, and Linux takes them
all. Refusing them everywhere means the bug turns up on the machine the asset
was authored on rather than on the machine the game shipped to.

**Case, too, where it is a trap.** Windows and macOS will open
`Textures/Cursor.png` when the file is called `textures/cursor.png`. A debug
build on those systems reads the directory and insists on the spelling asked
for, which is `Dir.Options.verify_case`.

**Nothing here allocates except through the allocator it is handed**, and a
lookup allocates nothing at all: the path is normalized into a stack buffer,
and the mounts are walked in place.

It knows nothing about what is in a file. Decoding a PNG is
[Fluxion Image](https://github.com/kisstp2006/fluxion-image), reading a save
is [Fluxion Data](https://github.com/kisstp2006/fluxion-data); this puts the
bytes in their hands.

## Packs

```bash
zig build pack -- create assets.fxpk assets
zig build pack -- list assets.fxpk
zig build pack -- extract assets.fxpk out
```

A pack is built once by a tool and never changed, which is what lets it answer
a lookup with a binary search over an index already in memory, and lets a watch
skip it entirely.

```
FXPK                 four bytes, so a file that is not one is noticed at once
version              one byte: the container's own
flags                one byte, none in use yet
reserved             two bytes of zero, to keep the blobs eight-aligned
blobs                every entry's bytes, in the order they were added
index                a fluxion-data document holding the entries
index offset         eight bytes, little endian: the last eight in the file
```

**The index is a fluxion-data document**, which is where its schema
fingerprint comes from. Add a field to an entry and every pack written by the
old build says `error.UnsupportedPack` rather than being read as something it
is not - and the check costs nothing, because it is eight bytes that were
going to be read anyway.

**The offset is at the end, not the front.** A packer that wrote the index
first would have to know every compressed size before compressing anything,
and so would have to hold the whole pack in memory. Blobs as they arrive and
the index after them means a pack of any size is built with one entry in
memory at a time.

**Compression is kept only when it pays.** `.auto` deflates an entry and keeps
the result only if it saved at least a sixteenth; below that the decompression
on every load is not worth the bytes, and a stored entry can be read straight
out of a mapped pack. The tool stores `.png`, `.ogg` and the rest of the
already-compressed extensions without trying.

**Every entry carries a CRC-32 of the bytes that come out**, not of the ones
that went in, so a pack whose compressor was buggy is caught as well as one
whose disk is. Checked on every read unless you turn it off.

A pack can be read two ways: `fromBytes` for one already in memory - mapped,
or `@embedFile`d - and `openFile` for one that keeps the file open, holds only
the index, and reads each entry from where it lies.

## Hot reload

```zig
var watch: vfs.Watch = .init(gpa);
defer watch.deinit();
try watch.add("textures/ui/cursor.png");

for (try watch.poll(&files, io)) |change| switch (change.kind) {
    .changed, .added => try reload(change.path),
    .removed => drop(change.path),
};
```

**A change is reported once it has stopped happening.** An editor saving a PNG
truncates the file, writes it, and closes it; a watcher that fired on the first
thing it noticed would hand the loader half a picture. A path that moved is
held back until it has held still for a tenth of a second. The cost is a reload
a tenth of a second late, which nobody notices, against a decoder error every
second or third save, which everybody does.

**Which mount answered is part of what changed.** Mount a patch over a pack and
the bytes behind a path are different bytes, though nothing on either disk was
touched. A watch comparing only timestamps would miss it.

**A pack is never polled**, because it reports no modification time: it has
none. Polling rather than `inotify` or `ReadDirectoryChangesW`, because those
are three APIs with three failure modes, none of them in `std.Io` yet, and a
stat of the few hundred files a game has open in development is well under a
millisecond.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-vfs
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_vfs = .{ .path = "../fluxion-vfs" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_vfs", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_vfs", fluxion.module("fluxion_vfs"));
```

```zig
const vfs = @import("fluxion_vfs");
```

Three dependencies come with it, fetched the same way and needing nothing from
you: [Fluxion Text](https://github.com/kisstp2006/fluxion-text) for path
normalizing and glob matching,
[Fluxion Hash](https://github.com/kisstp2006/fluxion-hash) for the CRC-32 on
every pack entry, and
[Fluxion Data](https://github.com/kisstp2006/fluxion-data) for the pack index
and the schema fingerprint that dates it.

## Where it sits

The third tier of the Fluxion licence ladder: `BSD-2-Clause`, built on one
tier-one library and two tier-two ones. That tier asks one thing a binary
built from it did not before - the copyright notice reproduced in the
documentation or about-box of what you ship.

## The tests

`vpath` and the listing set are tested where they live, being pure functions.
Everything else needs a real disk or a real pack, and is in one file: paths a
mount table must refuse, shadowing between mounts, a listing that is a set
rather than a concatenation, and a save that has nowhere to go.

The pack tests are mostly about what a pack is not - a wrong magic, a version
from the future, a flag this build does not know, an index offset past the end
of the file, an index of a different shape, a flipped byte caught by the CRC
and the same byte not caught when the check is turned off. The watch tests
drive the settle window from both sides: a change held back for an hour, and
the same change reported once when the wait is over.

## Build

```bash
zig build test        # run the test suite
zig build example     # mount a pack, patch it, save, and watch a file change
zig build pack        # the packer: create, list, extract
zig build docs        # generate API docs into zig-out/docs
```

## Licence

`BSD-2-Clause`. See [LICENSE](LICENSE).
