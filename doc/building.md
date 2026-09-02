# Building, testing, distributing

## Running it

```sh
sbcl --script run.lisp
```

That quickloads the system and calls the entry point. For development you want it in a
REPL instead, because the loop keeps the SLIME/SLY link alive (`livesupport:update-repl-link`
in `game-tick`) and you can recompile functions in a running game. Most of this port was
verified that way.

Keys worth knowing: **F9** unlimits the frame rate — the game runs as fast as the machine
allows, speed and all, as a measuring instrument rather than a way to play. **B** on the
credits opens the bestiary.

## Tests

```sh
sbcl --script run-tests.lisp
```

fiveam, currently 5614 checks. Exits 0 if everything passed, 1 on any failure, 2 if the
system would not even load, so it works as a CI step or a git hook. Nothing needs a display
or an audio device — the renderer writes PPMs directly and the audio layer has a `*muted?*`
switch — so the whole suite runs headless.

A good number of the checks are pixel comparisons: levels are run for N ticks and the
renderer's output is diffed, which is how the two renderers were established to be
identical and how the original's quirks stay pinned.

Before running anything, `run-tests.lisp` points both persisting paths at scratch files:

```lisp
(let ((scratch (uiop:temporary-directory)))
  (setf (symbol-value (uiop:find-symbol* "*PATH*" "COM.THEJACH.DESCENDANT.SETTINGS"))
        (merge-pathnames "descendant-test-options.ini" scratch)
        ...))
```

That is not tidiness. The suite drives the real menu, and the real menu saves when you
leave the options screen — so a test that walks to GO BACK writes the player's actual
`options.ini`, and one that had just set difficulty to 3 to check clamping left it there.
It presented as the game changing its own settings between sessions, and took a while to
connect back to the test suite. The high score table had the same accident earlier, which
is why both overrides exist. Setting them here means no future test has to remember to.

## Bundles

`build.lisp` produces a distributable folder using
[Deploy](https://github.com/Shinmera/deploy). The executable alone will not run and is not
meant to — the folder is the deliverable.

```sh
sbcl --script build.lisp        # -> bin/linux/  or  bin/windows/
```

Each platform gets its own subdirectory. They shared `bin/` at first, which meant a Windows
build had to clear away a Linux one, and under Wine it cannot: a Unix symlink resolves to
its target's truename there, so the soname links a Linux build leaves behind come back as
several directory entries naming one file. Separate directories make cross-platform
cleaning impossible rather than merely careful.

The script re-executes itself with `--dynamic-space-size 2048` if it was not started that
way. Deploy passes `:save-runtime-options T` to `save-lisp-and-die`, so the built binary
inherits the runtime options of the SBCL that built it — the way to give the game a 2 GB
heap is to *build* it with one. Headroom makes collections rare, and a collection is the
one thing that can drop a frame on a fixed timestep.

### What Deploy does and does not do

`src/deployment.lisp` is the interesting file, and most of it exists because Deploy does
not bundle transitive dependencies. Only its shrinkwrap path does, and that shells out to
`patchelf`.

On Unix the hooks copy the libraries, create the soname symlinks, and verify architecture.
That last one earned its place: on a multilib Gentoo the bundle picked up a **32-bit**
`libSDL2`, and the loader silently fell back to the host's 64-bit copy rather than
complaining, so the bundle appeared to work and would not have worked anywhere else.

The loader's search order is `DT_RPATH` → `LD_LIBRARY_PATH` → `DT_RUNPATH` → `ld.so.cache`
→ system directories. **A shared object's own directory is never searched**, which is why
there is a boot hook that re-executes the binary with `LD_LIBRARY_PATH` set. It has to run
before every other boot hook, hence the priority of `#.most-positive-fixnum` — Deploy's own
is `(- most-positive-fixnum 10)`, and getting that wrong made the re-exec happen too late,
twice.

Windows needs none of that machinery: it searches the executable's directory first. The
Windows hook copies `win32/dll/*` and errors if the directory is missing.

One Deploy declaration has to be turned off. Deploy defines `libwinpthread` on every
SBCL/Windows build and insists on finding it; this SBCL links its threading runtime
statically and never opens it, so it has no path to report. It is marked `:dont-deploy`
rather than supplied, because sourcing that DLL from somewhere else would put a second
threading runtime beside a binary that already has one.

## Windows builds

There is no cross-compiler. SBCL cannot target another platform, so a Windows executable
requires a Windows SBCL, and Wine is how that happens on Linux.

Two scripts do it — one to fetch the toolchain, one to run the build:

```sh
win32/setup.sh      # fetch SBCL's MSI and the SDL runtime DLLs; run once
win32/build.sh      # run the Windows SBCL under Wine
```

They may not be in this repository; they hardcode paths on the author's machine. What
follows is what they do and, more usefully, the things that went wrong while writing
them — all of which apply to any other way of driving the same build.

Everything lives under `win32/` — its own Wine prefix, its own Quicklisp — so it cannot
disturb any Wine setup you already have, and deleting the directory undoes all of it.
`setup.sh` unpacks the MSI with `msitools`, no installer and no clicking.

Two things that are easy to get wrong here:

**Take the whole SBCL directory out of the MSI, not `sbcl.exe` and `sbcl.core`.** The
contribs are separate fasls under `SBCL_HOME`, and Quicklisp wants `sb-bsd-sockets` before
it can fetch anything. Extracting two files by name produces `Don't know how to REQUIRE
SB-BSD-SOCKETS` at the first download, which reads like a networking fault and is not one.

**The DLLs must be findable at build time, not just at run time.** CFFI calls
`LoadLibrary` when the bindings load, so compiling lgame opens `SDL2.dll` then and there.
`build.sh` stages them next to `sbcl.exe`, which is the directory Windows searches first.

`opengl32.dll` is deliberately not bundled. It belongs to Windows and to Wine, and shipping
it would replace the user's graphics driver with ours — the same mistake as shipping
`libGL` on Linux. The `32` in the name is not a word size; it is left over from the
Win16-to-Win32 transition, and the 64-bit DLL has the same name.

## Building in the Debian chroot

These scripts are the most machine-specific of the lot and are the least likely to be in
this repository — they run as root, mount filesystems, and name a chroot at an absolute
path. Recorded here for the reasoning, which transfers to any equivalent setup.

The Linux bundle is built against Debian's older glibc so it runs on more distributions
than a Gentoo build would.

The Windows bundle has no such dependency — it is built by a Windows SBCL and every DLL
comes from libsdl-org's own archives — but it is built in the chroot anyway, for a
different reason. SBCL records the source path of everything it compiles, so a bundle built
in a home directory carries several hundred copies of that path inside the executable.
Built in the chroot they read `Z:/lisp-build/...`.

```sh
./build_linux_and_windows_in_chroot.sh
```

Order is load-bearing: the Linux script replaces the whole of `bin/`, so it goes first; the
Windows script touches only `bin/windows/`. Reversed, the Linux build deletes the Windows
bundle.

`build-win32-in-chroot.sh` runs `win32/setup.sh` outside the chroot as the tree's owner —
as root it would leave root-owned files behind and break the next ordinary build — then
copies the project in, `chown`s it to root, and builds. The `chown` is not cosmetic: wine
refuses to create a prefix in a directory it does not own, and `rsync -a` run as root
preserves the host uid on everything it writes.

It finishes by scanning the bundle for the build user's name and reporting what it finds.
Both path leaks discovered so far turned up somewhere nobody had thought to look — first
the compiler recording source paths, then Wine naming `drive_c/users/<name>` after `$USER`
— so the script reports what is actually there rather than asserting it is clean.
