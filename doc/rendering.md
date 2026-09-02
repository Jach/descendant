# Rendering

The original ran in the Windows console. Every pixel you see is a character cell with a
foreground colour, a background colour, and an ASCII character in it — very
Dwarf-Fortress. The port keeps that model exactly, because the assets are authored in it
and there is no way to read them that does not reproduce it.

```
240 cells across x 120 down, each 4x6 pixels  =  960 x 720
```

Those numbers are in `screen.lisp:7`. The 4x6 comes from `GR_initFont`, which searched the
console for a 4x6 raster font; the sprite editor used a size-8 Courier to match. The port
does not compromise on this resolution — everything is authored for 240x120 and a
"fullscreen" mode is SDL2's borderless-desktop scaling on top, not a different layout.

## Glyphs

A cell is one unsigned 32-bit integer:

```
  31           24 23           16 15            8 7             0
  +--------------+---------------+---------------+---------------+
  |  colour pair |      mod      |   (reserved)  |   character   |
  +--------------+---------------+---------------+---------------+
```

```lisp
(defun make-glyph (char pair &optional (mod 0))
  (logior char (ash mod 16) (ash pair 24)))
```

Two special values do most of the work:

- `+transparent+` is `#xFFFFFFFF`. The cell is skipped entirely and whatever was
  underneath stays. This is how sprites get non-rectangular silhouettes.
- A `mod` byte of `#xFF` (`+mod-transparent-bg+`) applies only the foreground, letting the
  background underneath show through. That is one character painted over an existing
  scene rather than a rectangle of its own.

`+default-fg-char+` is `#xDB`, the solid block — the "lit pixel" of bitmap text — and
`+default-bg-char+` is `#x20`, space.

**The colour pair byte is not two palette indices.** It is an index into a 256-entry table
of foreground/background combinations, and the mapping from pair to actual colours goes
through a permutation that only makes sense if you know the Win32 console API. That story
is in [assets.md](assets.md), and it is the single most surprising thing in the port.

## The compositor

`screen.lisp` owns a 240x120 cell buffer and 20 z-layers. During a frame, levels call
`enqueue`; at the end, `composite` draws everything into the buffer and empties the
queues.

Two conventions will bite you if you assume the usual ones.

**Y is measured from the bottom.**

```lisp
(defun enqueue (screen sprite x y z &optional (frame 0))
  "Y is measured from the BOTTOM of the screen: the original computes the top row as
   (rows - Y), so Y = +rows+ puts the sprite's top edge at row 0.")
```

A sprite enqueued at `Y` occupies rows `[rows - Y, rows - Y + height)`. Every coordinate
transcribed from the C counts upward. This is also why the port does not store game
coordinates in `lgame.box`, which is SDL-oriented with Y growing down — `box-y` would mean
the opposite of the C's `d_y` in exactly the code that is hardest to check by eye.

**Within a z-layer, the earliest-enqueued sprite ends up on top.**

```lisp
;; Within a layer the original prepends to a linked list and then walks it head-first,
;; so the most recently enqueued sprite is drawn FIRST and the earliest ends up on top.
;; Pushing onto a list and iterating it reproduces that order exactly.
```

This is backwards from a painter's algorithm within the layer, and it is the kind of
detail that produces a bug you will stare at for an hour. Across layers it behaves
normally: layer 0 first, layer 19 last.

### The back buffer is not a copy

`screen` carries a second buffer (`d_bbDtP` in the C) that is *not* a snapshot of the
composite. It is written unconditionally — transparent glyphs write themselves into it,
where they are skipped in the front buffer — so it diverges. The warp hole snapshots it,
and that divergence is what makes the effect look right. Do not be tempted to make the two
buffers agree.

### The dead column

The original's right-hand clip tests `p_x + width >= maxx` and then sets the offset to
`1 + overflow`, dropping a column that is genuinely on screen. Every full-screen 240-wide
sprite trips it, so the shipped game had a permanent 1-cell — 4-pixel — dead stripe down
the right edge that nobody noticed at the time.

We clip correctly and reclaim the column. `*right-edge-off-by-one*` restores the artifact,
and the test suite binds it to keep the old behaviour pinned.

## Two renderers

The cell buffer has to become pixels, and there are two implementations behind one set of
generic functions (`rasterize`, `present`, `set-palette`, `destroy-renderer`, `save-ppm`).
Options calls them **SLO** and **FAST**.

**SLO** (`renderer.lisp`) expands the 240x120 cell buffer into a 960x720 ARGB pixel buffer
on the CPU and hands it to an `SDL_Renderer` as a streaming texture. It is
straightforward, it has no GPU requirements beyond a window, and it is the fallback.

**FAST** (`renderer-gl.lisp`) follows the design in
[refterm](https://github.com/cmuratori/refterm): upload the cell buffer as an `RGBA8UI`
texture, keep the font as an `R8` atlas, pass the 16-colour palette as a uniform array,
and draw one fullscreen triangle whose fragment shader does the lookup per pixel. The
shader also does the letterboxed scaling, via an `outputSize` uniform, so fullscreen costs
nothing extra.

The two are **pixel-identical** — verified across 4 screens, 3 palettes and both colour
mappings by rendering to arrays and diffing. That was worth establishing before shipping a
setting that switches between them.

### Why switching renderers needs a restart

The options screen says `RESTART NEEDED` next to the render setting, and this is why:

```lisp
;;; The two renderers do not merely draw differently -- they want different windows. The
;;; fast one needs SDL_WINDOW_OPENGL and a context of its own; the slow one wants an
;;; SDL_Renderer, which would create and ...
```

Window flags are fixed at creation. Rebuilding the window mid-session would mean tearing
down and re-acquiring every texture, which is a lot of machinery to avoid restarting a
game that starts in under a second.

### A trap worth naming

`gl:uniformfv` emits `glUniform1fv`, which is invalid for a `vec3[16]` uniform. GL does
not report this as an error at the call site; it silently ignores the upload, the palette
stays all zeros, and you get a black screen with no diagnostic anywhere. The fix is the
right entry point plus a `check-gl` after every call that can fail. If you extend the
shader's uniforms, keep that habit — this cost real time to find.
