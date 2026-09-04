# Android

The game runs on a phone. Same core, same assets, same 240×120 cell grid letterboxed into
whatever the screen is — and the same Lisp, cross-built for aarch64.

This document is the account of what Android required that the desktop did not. Most of it
is not about graphics or input at all; it is about the fact that an Android app is not a
program that gets run.

## The shape of it

**You cannot ship an executable.** Since targetSdk 29, Android denies `execute` on
everything in an app's data directory. The only place in an APK where code may execute is
`lib/<abi>/*.so`. So the game is a shared library, loaded by the JVM, and it plugs into
SDL's existing Android support rather than replacing it.

```
descendant.apk
├── AndroidManifest.xml       activity = org.libsdl.app.SDLActivity, landscape, arm64 only
├── classes.dex               SDL's own Java classes. None of ours.
├── lib/arm64-v8a/
│   ├── libSDL2.so            NDK builds of all four, though the game uses two
│   ├── libSDL2_mixer.so
│   ├── libSDL2_image.so
│   ├── libSDL2_ttf.so
│   ├── libsbcl.so            the SBCL runtime
│   ├── libmain.so            the C shim, exporting SDL_main
│   └── libsbclcore.so        the game's core. Not an ELF file; see below.
└── assets/                   Themes/ Sounds/ Fonts/ Config/, copied verbatim
```

`SDLActivity` loads `libSDL2.so` and `libmain.so` and dlsyms `SDL_main` out of the latter.
Naming our native module `main` is what buys that, and it is why **this port contains no
Java of its own** — the manifest names SDL's activity directly.

Three consequences follow, and they are the whole difference from the desktop build:

- There is no `main`. Entry is `SDL_main`, on a thread SDL spawns, not the process's
  initial thread.
- **Deploy has no role.** Its job is finding foreign libraries and copying them beside an
  executable; an APK has neither. `src/deployment.lisp` is excluded from the build.
- `stdout` goes nowhere. `android/jni/main/main.c` pumps fds 1 and 2 into logcat, which is
  the difference between debugging and guessing.

`libsbclcore.so` is the core file, named `lib*.so` only because the packager extracts
nothing else out of `lib/<abi>/`. Nothing loads it as an ELF; `main.c` finds it by asking
the linker where `libmain.so` came from and looking next door, because the install path
contains two installation-specific hashes.

## Building

Four stages, deliberately independent.

| | Where | Script |
|---|---|---|
| SDL sources | desktop | `android/setup.sh` |
| SBCL for aarch64 | desktop + phone over adb | `android/build-sbcl.sh` |
| the game's core | phone | `android/build-core.sh` |
| the APK | desktop | `android/build.sh` |

```sh
android/setup.sh                              # once
android/build-sbcl.sh                         # once, ~2 minutes
android/build-core.sh                         # after any Lisp change
DESCENDANT_LISP=1 WITH_ASSETS=1 android/build.sh install
```

**SBCL supports Android upstream.** `make-android.sh`, `Config.arm64-android`,
`android-os.c` and `doc/internals-notes/Android-build.txt` are all in the SBCL tree.
Android is missing from the platform table because nobody publishes binaries for it, which
is not the same as it being unported. The build happens on the desktop with the NDK's
clang; the phone runs only the stages that need target code — header groveling, cold init,
contribs — which `make-android.sh` does over adb into `/data/local/tmp`.

Two of its flags are not optional, and each explains a failure that looks like something
else:

| Flag | Without it |
|---|---|
| `--with-android` | `run-program.c` calls `getdtablesize()`, which bionic lacks; clang 18 makes an implicit declaration a hard error. |
| `--without-gcc-tls` | `arm64-assem.S` uses an initial-exec TLS model bionic does not suit: `undefined symbol: current_thread` at link. |

Note `:android` and `:linux` are **both** in `*features*`. Anything wanting one and not the
other must say `#+(and linux (not android))` — upstream had to do this in two places
itself, and it is the root of the autowrap problem below.

The game's core is built on the device because fasls are target-specific: the whole
dependency tree has to be compiled by the SBCL that will run it.
`android/collect-systems.lisp` asks ASDF what loading the game actually took, so the list
cannot drift from `descendant.asd`.

### Checking a build without a phone

```sh
sbcl --script android/compile-check.lisp
```

This compiles the Android build on the desktop in about forty seconds. It exists because
the most common mistake — naming a package in an `#+android` form whose defining file
comes later in `descendant.asd` — fails at *read* time with "Package X does not exist" and
nothing about the ordering that caused it. It catches misspelled Android-only constants
too, which no desktop build or test would ever see.

It works because nothing Android-specific resolves at compile time: SDL and JNI entry
points are called through CFFI by name at runtime. The code compiles on the desktop; it
simply could not run.

Two things it cannot do the obvious way, both worth knowing before "improving" it.
Pushing `:android` at runtime changes nothing, because reader conditionals are resolved at
compile time. Adding `:force t` fixes that and breaks something else — it recompiles
cl-autowrap, which reads `*features*` to build an architecture triple and produces
`x86_64-pc-linux-android` on an x86-64 host, at which point autowrap reaches for c2ffi and
the check dies having tested none of our code. So it loads the dependencies normally and
compiles only this project's files, by hand, into a scratch directory.

## Four assumptions a saved image makes

These are the interesting failures, and they are all the same underlying fact: **a saved
Lisp image encodes where things were when it was saved.** All four are handled in
`android/build-android.lisp`.

**The architecture triple is wrong.** `autowrap::local-arch` assembles it from reader
conditionals, and with both `:linux` and `:android` present the vendor comes out `-pc`
where Android wants `-unknown`, giving `aarch64-pc-linux-android` — which no spec file is
named after. Overridden outright.

**Two bindings ship no spec for this architecture.** cl-sdl2 carries
`SDL2.aarch64-unknown-linux-android.spec`; cl-sdl2-mixer and cl-sdl2-image carry nothing
for aarch64 at all, not even Linux, so this is an upstream ARM gap rather than an Android
one. They are copied from the x86-64 Linux specs, which is sound *for these two libraries*
and was checked rather than assumed: comparing cl-sdl2's own three specs, aarch64-gnu and
aarch64-android differ in no declaration's size, and x86-64 differs from aarch64 in exactly
two — `__pthread_mutex_s` and `__pthread_rwlock_arch_t`, both libc internals. SDL_image
declares no public struct at all and SDL_mixer declares one, `Mix_Chunk`, 192 bits that lay
out identically on any LP64 target. It would not be a sound way to produce a spec in
general.

**Android has no versioned sonames.** cl-sdl2 asks for `libSDL2-2.0.so.0`; the file is
`libSDL2.so`, and an APK installs nothing else out of `lib/arm64-v8a/`. The library specs
are rewritten before the dump.

**SBCL reopens shared objects by the name the build used.** Rewriting CFFI's specs is
necessary and not sufficient: `SB-IMPL::REINIT` walks SBCL's own list on startup and
reopens each by the namestring it saw at load time, which is the symlink `build-core.sh`
makes in `/data/local/tmp` so the bindings can find anything at all. In the APK that name
does not exist and cannot be made to, so the app died in `REINIT` before a line of Lisp
ran. The fix is to save no shared objects: close them before dumping, and have the
toplevel open them itself from the corrected specs.

The order matters and is easy to get wrong. `define-foreign-library` replaces the registry
entry with a fresh object whose handle is `NIL`, so **closing must happen before the specs
are rewritten** — patch first and CFFI reports nothing loaded, closes nothing, and the core
still ships the versioned name. A build tripwire checks for versioned sonames in
`sb-sys::*shared-objects*` before dumping, because the failure is silent at build time and
loud four steps later.

## The renderer

GLSL ES 3.00 has everything the cell shader needs — `usampler2D`, `texelFetch`,
`gl_VertexID`, integer textures — so the fast renderer works unchanged in substance.
`src/renderer-gl-shaders-es.lisp` is a whole copy of the desktop shader rather than one
string with conditionals threaded through it, chosen by `:if-feature` in the `.asd`, so
diffing the pair is the account of what changed. Three things:

1. `#version 300 es` rather than `#version 330 core`.
2. **Precision qualifiers.** GLSL ES defines no default precision for floats, integers or
   samplers in a fragment shader, and omitting them is a compile error rather than a
   warning — including for `usampler2D`, which is easy to miss.
3. A comment about the drawable rather than about F11.

One thing that is not the shader's fault: cl-opengl resolves anything past core GL 1.1
through a proc-address function, and its fallback on `#+linux` is `glXGetProcAddress` —
GLX, which is X11, which Android does not have. The failure reads as a missing driver.
cl-opengl has a hook for exactly this, and `main.lisp` sets it to SDL's resolver on every
platform, not just Android.

Measured on a Red Magic 8 Pro: `OpenGL ES 3.2`, `GLSL ES 3.20`, Adreno 740, drawable
2480×1116. The 960×720 picture letterboxes into that at 1.55×, pillarboxed rather than
letterboxed, with 496 px bars either side.

## Input

Touch is translated into **synthesized SDL key events**, pushed onto SDL's own queue, so
they arrive at the levels indistinguishable from a keyboard. No level code changed for
Android: the menu, score entry, bestiary and controls screen all work without knowing
touch exists, and a real keyboard still works because anything `translate` does not consume
carries on to the ordinary handlers.

`src/touch.lisp` does two different jobs, and it took two wrong versions to see they were
different.

**Menus want events.** Up means "the next item", once, and again if you keep asking. That
is a keyboard, and the honest translation is a keyboard: past a notch, emit one arrow, then
auto-repeat.

**Flying wants a position.** The first version held an arrow while the finger was off
centre, which gave exactly one turn rate and no small corrections. The second made
deflection a duty cycle — proportional, but still steering an accelerating ship through a
control with no position feedback. What works is neither: **vertically the ship goes where
the finger is.** `player:set-vertical-center-row` places it outright, zeroing vertical
velocity so old momentum cannot drag it past.

Two details that are easy to get backwards, and were:

- The finger anchors the ship's **middle**. `rect-y` is the top edge — a rect spans
  `(y-h, y]` with y counting up — so placing the ship by its rect leaves the sprite hanging
  two rows below the thumb.
- The input is a **picture row**, not a fraction of the play area. The play area is inset,
  so mapping 0–1 across it puts the ship at a proportional position rather than under the
  finger, several rows adrift at mid-screen.

A finger put down far from the ship does not teleport it: beyond six ship-heights it
travels at two rows a tick, about eight tenths of a second to cross the play area. The mode
is a latch, released within two ship-heights, so the ship does not re-enter snapping range
at full speed and jump the last stretch. The landing is still a jump of eight rows,
measured; that is the cost of having a mode, and the alternative — capping ordinary
following — puts lag on every fast swipe.

Horizontally it stays a stick, because there is nowhere to put an absolute x: forward drift
is the game, and a finger cannot hold a position the ship is not allowed to stay at. But
**the centre moves.** A thumb sliding up and down is not asking to go sideways however much
it wanders, so while the movement is mostly vertical the centre follows the finger; only a
movement both sideways enough and far enough pins it and starts pushing.

### Gestures

| | |
|---|---|
| drag | the stick |
| tap | Return — or Escape in the bestiary, which answers to nothing else |
| tap on a menu item | selects it, then Return |
| two fingers | pause; the hidden bestiary in the credits |
| three fingers | FPS readout |
| four fingers | unpace the loop (F9), passing through the other two on the way |
| back button | Escape |
| firing | automatic, always |

Gestures are context-dependent because a gesture that does something everywhere does
something wrong somewhere — the pause key was being typed into the player's name on the
score screen.

A band of 6% at the top and bottom of the screen is ignored entirely: Android hides the
navigation bar and notification shade behind swipes from those edges, and without it
reaching for the back button drives the ship and registers as a tap.

### The keyboard

`SDL_StartTextInput` raises Android's keyboard when the score screen starts taking a name,
and `SDL_TEXTINPUT` events carry the characters — necessary because there is no physical
key to report and the IME may be a swipe or a prediction. The scancode path is `#-android`:
Android's soft keyboard reports every keystroke **twice**, once as a key event and once as
text, which turned "ok" into "ookk".

Two rough edges here, both accepted rather than solved:

- The name-entry block is lifted 48 rows on Android because a landscape keyboard covers
  roughly the bottom half of the screen, and where the block normally sits is exactly what
  gets covered. How tall the keyboard actually is happens to be the one thing Android will
  not tell us without Java — SDL exposes no insets — so the offset is a fixed guess.
- Dismissing the keyboard with the back button used to softlock the screen, because
  `commit-name` refuses an empty name and a tap arrives as Return. A refused commit now
  re-raises the keyboard.

## What is Android-only

Three files, plus one excluded, all selected by `:if-feature` in `descendant.asd`:

| | |
|---|---|
| `src/touch.lisp` | everything above |
| `src/android-assets.lisp` | copying `assets/` out of the APK on first run |
| `src/renderer-gl-shaders-es.lisp` | the ES dialect of the cell shader |
| `src/deployment.lisp` | **excluded** — Deploy has no role, and it reads ELF headers through `sb-posix` |

Everything else is `#+android` inline, and there is little of it: `paths:app-root`, the
GLES context attributes in `main.lisp`, forcing auto-fire on, and the two score-screen
adjustments above.

Assets are copied out of the APK on first run because the game reads them with ordinary
`with-open-file`, and inside an APK there is no such path — `assets/` is a region of a zip.
Rather than teach every reader in the port about that, `SDL_RWFromFile` (which on Android
tries the asset manager first) copies them once into the app's private directory, after
which every path in the game is a real path again. A manifest generated at build time says
what to copy, because enumerating an asset directory is a JNI call with no SDL wrapper.

## Known rough edges

- **Powerups occasionally do not collect when flying backwards.** Reported during testing
  and not reproduced. Ruled out: the player's collider shares its rect object, the sweep
  vector is re-sorted every frame, and `check-collisions` runs after everything has moved.
  A reproduction test is the right next step, not more reading.
- The FPS readout is available (three fingers) but the loop is paced at 62.5 Hz, so the
  number says how much headroom there is, not how fast it runs.
- Tap-to-select is implemented for the main menu only. The options page is laid out in
  columns rather than a row list, so a tap there still means "choose what is highlighted".
- The `hdpi` launcher icon is full-bleed horizontally. The ship is 36×24 and only ever
  scaled by whole numbers, and at 72 px the choice was 2× touching both edges or 1×
  swimming in black.
