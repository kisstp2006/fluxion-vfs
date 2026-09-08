# Fluxion VFS

One namespace, whatever is behind it. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Vfs` | The mount table, and the verbs: `read`, `open`, `readAsync`, `write`, `list`, `locate`. |
| `Dir` | A directory on disk, as a source. The only kind that can be written to. |
| `Pack` | One file holding many, as a source, and the builder that makes or rebuilds one, on every core. |
| `Stream` | An asset read a piece at a time, over whatever it is stored in. |
| `Map` | A file as memory: `mmap`, or a section object on Windows. |
| `Watch` | What changed since you last asked. |
| `Notify` | The kernel's word on whether anything did, so a poll can be skipped. |
| `Source` | What any of the above is, so a game can add its own. |
| `vpath` | What a virtual path is, and what it is not. |

```zig
const vfs = @import("fluxion_vfs");

var files: vfs.Vfs = .init(gpa);
defer files.deinit(io);

_ = try files.mountMappedPack(io, "", "assets.fxpk", .{}); // what shipped
_ = try files.mountDir(io, "", "patch", .{});               // what was patched
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

## Three ways to read

```zig
// Whole. A texture, a sound, a level: most things.
const bytes = try files.read(io, gpa, "ui/cursor.png", .limited(1 << 20));

// A piece at a time. A video, a music track, anything that should not
// have to fit in memory to be played.
var stream = try files.open(io, gpa, "video/intro.ogv");
defer stream.close(io);
const chunk = try stream.reader.take(64 * 1024);

// Started now, collected later. A loading screen, a level streaming in.
var pending = files.readAsync(io, gpa, "levels/two.bin", .limited(1 << 26));
// ... the frame goes on ...
const level = try pending.await(io);
```

A stream is a `std.Io.Reader` over whatever the asset is actually stored in: a
file, a range of a pack file, a slice of a mapped pack, or the deflated form
of any of those. The pieces are chained, not copied. The checksum is not
verified on a stream, because a stream may be read part-way and closed; a
caller that wants the check reads the whole thing.

`readAsync` is `std.Io`'s own `async`, so what it does is the Io
implementation's business - a threaded one reads on another thread, a blocking
one reads right there and `await` finds the answer waiting.

## Packs

```bash
zig build pack -- create assets.fxpk assets
zig build pack -- update assets.fxpk patch      # carry everything, replace what patch has
zig build pack -- list assets.fxpk
zig build pack -- extract assets.fxpk out
zig build pack -- create assets.fxpk assets --jobs 0   # one thread, for comparison
```

A pack is built once by a tool and read many times by a game, which is what
lets it answer a lookup with a binary search over an index already in memory,
and lets a watch skip it entirely.

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
whose disk is. Checked on every `read` unless you turn it off.

**A pack can be opened three ways.** `map` maps the file whole and lets the
kernel page it in as it is touched - the fastest open for a large pack, and
the only way an uncompressed entry can be handed out as a slice of the file
with no copy, which is `Pack.slice`. `openFile` keeps the file open, holds the
index, and reads each entry from where it lies, for a target that cannot map.
`fromBytes` is for a pack already in memory, `@embedFile`d or otherwise.

**A pack is built on every core.** Deflating is nearly the whole cost of
building one and each entry is independent of every other, so `Builder.addAll`
prepares them on a [Fluxion Jobs](https://github.com/kisstp2006/fluxion-jobs)
scheduler and writes them in order afterwards. The pack is byte for byte the
one `add` in a loop would have written - the tests check exactly that, against
both a threaded scheduler and one with no workers at all.

Packing this Zig installation's standard library, 552 files and 16 MB, on an
eight-core machine:

| | wall time |
| --- | --- |
| 1 worker | 0.55 s |
| 2 workers | 0.38 s |
| 7 workers | 0.31 s |
| reading and writing alone, no compression | 0.33 s |

The last row is the point: with the compression spread out, building a pack
costs what reading the files costs and nothing more.

**Changing a pack is rebuilding it**, and `Builder.initFrom` makes that cheap:
it starts a new pack from an old one, carries every entry across as it was
stored - never decompressed and compressed again - and lets you take some out
and put some in. What it will not do is pretend to update in place, because
that would mean moving every blob after the one that changed and rewriting the
index anyway.

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
none.

**The kernel can say when there is nothing to look at.** A poll is a stat per
watched path, which is under a millisecond for hundreds and not for tens of
thousands. Give the watch a `Notify` - `ReadDirectoryChangesW` on Windows,
`inotify` on Linux - and a poll on a quiet frame does nothing at all:

```zig
var notify: vfs.Notify = .init(gpa);
defer notify.deinit();
try notify.add(io, "assets");     // the same path given to mountDir
watch.useNotify(&notify);
```

What comes back from the kernel is deliberately one bit - something changed -
because the two APIs disagree about everything else: what a rename looks like,
whether a write is one event or three, what happens when the buffer overflows.
The stats remain the source of truth for what changed and whether it settled;
the notification only says whether there is anything to look at. A mount
changing is not something the kernel can know, and is seen anyway, because the
mount table counts its own changes. On a target with neither API - macOS is
one, until `std.Io` grows a watch - `Notify.supported` is false and the watch
polls as before.

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

Four dependencies come with it, fetched the same way and needing nothing from
you: [Fluxion Text](https://github.com/kisstp2006/fluxion-text) for path
normalizing and glob matching,
[Fluxion Hash](https://github.com/kisstp2006/fluxion-hash) for the CRC-32 on
every pack entry,
[Fluxion Data](https://github.com/kisstp2006/fluxion-data) for the pack index
and the schema fingerprint that dates it, and
[Fluxion Jobs](https://github.com/kisstp2006/fluxion-jobs) for building a pack
on more than one core. Nothing but `Builder.addAll` touches the last one, and
a scheduler with no workers makes it a plain loop.

## Where it sits

The third tier of the Fluxion licence ladder: `BSD-2-Clause`, built on one
tier-one library and three tier-two ones. That tier asks one thing a binary
built from it did not before - the copyright notice reproduced in the
documentation or about-box of what you ship.

## The tests

`vpath` and the listing set are tested where they live, being pure functions.
Everything else needs a real disk or a real pack: paths a mount table must
refuse, shadowing between mounts, a listing that is a set rather than a
concatenation, a save that has nowhere to go, a stream read seven bytes at a
time from every kind of place, a mapped entry checked to be inside the
mapping, a rebuilt pack whose carried entry kept its stored size and checksum,
a pack of six hundred entries built three ways - one at a time, on every core,
and on none - and compared byte for byte, and a watch that hears about a write
through the kernel.

The pack tests are mostly about what a pack is not - a wrong magic, a version
from the future, a flag this build does not know, an index offset past the end
of the file, an index of a different shape, a flipped byte caught by the CRC
and the same byte not caught when the check is turned off. The watch tests
drive the settle window from both sides: a change held back for an hour, and
the same change reported once when the wait is over.

## Build

```bash
zig build test        # run the test suite
zig build example     # mount a pack, patch it, save, stream, and watch a file change
zig build pack        # the packer: create, update, list, extract
zig build docs        # generate API docs into zig-out/docs
```

## Licence

`BSD-2-Clause`. See [LICENSE](LICENSE).
