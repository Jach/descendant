# Assets

Everything under `assets/` is the original's. Nothing was converted, re-exported or
cleaned up — no format was changed to suit the port, and that constraint is the reason
several of the readers look the way they do.

Two deliberate exceptions, both in the text configs and neither touching a binary:
`level_hidden_cave.cfg` and `level_brain_pain.cfg` have lost their `sound_jaguar`
sections, which named a file that was never shipped (see below), and five files that
nothing referenced were dropped. The `.thm`, `.bft` and `.bin` files are untouched.

`paths.lisp` resolves them. In development `app-root` is the ASDF system directory; in a
deployed binary it is `deploy:runtime-directory` — the directory the executable *sits in*,
resolved from argv0, not the working directory. Using the working directory would mean the
game only found its assets when launched from inside its own folder, which is not how
anyone runs a program they have been handed.

## `.thm` — themes

A theme is a palette plus every sprite that draws with it. Verified byte-exact against
every shipped theme:

```
  [0]   char name[16]
  [16]  {u8 r, g, b, pad}[16]     the palette
  [80]  u32 id
  [84]  i32 nSprites
  then nSprites x {
      char name[32]; u32 objID; i32 width, height, nFrames, extraBytes, offset;
      u32 glyphs[nFrames * width * height];
  }
```

The 56-byte sprite header is `sizeof(GameSpriteData)` minus its 8-byte data placeholder,
which is exactly what `dsc_object_manager.c:69` computes. Three of the shipped themes —
`intro.thm`, `menu.thm`, `credits.thm` — carry junk after the last sprite. The original
never notices because it only ever reads `nSprites` entries, so neither do we.

Glyph data is little-endian `u32`, so in a hex editor a glyph reads backwards. If you go
looking at these files by hand, expect `0xD8000023` to appear as `23 00 00 D8`.

## `.bft` and `terminal_4x6.bin` — fonts

Two on-disk formats that normalise to one in-memory structure, and they are **not**
interchangeable — they compose:

- **`terminal_4x6.bin`** maps a character to *pixels*. Extracted from the Windows console
  Terminal face in `dosapp.fon` by `tools/extract_cellfont.py`. Every one of the 28,800
  screen cells is drawn with it.
- **`*.bft`** maps a character to *cells*. These are the game's own fonts for large blocky
  text: a lit pixel emits a `#xDB` cell, an unlit one a space. They were made in 2010 by
  cropping a window out of hand-drawn Windows FNT glyphs.

So `.bft` text produces cells, and those cells are then drawn with the cell font. The two
storage formats also use **opposite bit orders**, which `font.lisp` normalises on load
specifically so that confusion does not reach any call site.

## `.cfg` — configuration

An INI dialect, matching `dsc_configuration.c`:

```
[ section_name ]
key = value
```

Comments run from `#` to end of line and are stripped from the whole buffer *before*
parsing — including inside values, which we reproduce. Section names and keys are trimmed;
values are kept verbatim from the character after `=` to end of line and trimmed by the
consumer. Keys are stored as `"section.key"`.

One deliberate divergence, documented at `config.lisp:13`: the original walks the buffer
with pointers, so a line containing no `=` silently swallows following lines until one
appears. We parse line by line and ignore such lines. No shipped `.cfg` depends on the old
behaviour — after comment stripping, every line is blank, a section header, or a pair.

## The colour-pair encoding

This is the part that will not make sense until it does.

A glyph's top byte is a colour pair. You would reasonably guess it decomposes into two
4-bit palette indices. It does not, and the reason is that the original drew to a Windows
console.

The sprite editor wrote one encoding (`sprite_edit_app.py:1096`):

```
pair = 16*bg + (15 - fg)
```

The game read it back through the Win32 console attribute word, which is a different
thing: both nibbles route through permutation tables, and then red and blue are swapped
because of how `COLORREF` orders its bytes against the console's attribute bits.

It is tempting to call the editor's encoding the authored intent and the Win32 path a bug.
We did not, for one reason: **the Win32 path is what players actually saw.** The artwork
was drawn by people looking at the game, so whatever the editor believed it was writing,
the colours in the shipped screenshots are the truth.

That is settled empirically rather than by argument. Decoding `menu.thm`'s `menu_bg`
through the permutation tables and comparing against a screenshot of the original gives
**99.76% exact pixel agreement**; the remaining 0.24% is the star field, which is a
separate sprite drawn at runtime.

Both encodings are available, and `*colour-mapping*` selects:

```lisp
(defun encode-pair (fg-slot bg-slot)
  "The attribute byte that paints foreground FG-SLOT on background BG-SLOT..."
  (if (eq *colour-mapping* :original)
      (logior (aref *win32-fg-nibbles* fg-slot)
              (ash (aref *win32-bg-nibbles* bg-slot) 4))
      (logior (- 15 fg-slot) (ash bg-slot 4))))
```

If you are writing code that builds glyphs, use `encode-pair` and
`glyph-fg-index`/`glyph-bg-index` rather than manipulating nibbles. Reading the raw nibbles
as palette indices produces something that looks plausible and is wrong — that mistake was
made once already during this port, in an analysis that had to be redone.

## Sounds

WAV effects and MP3 music under `assets/Sounds/`, played through `sdl2-mixer` in place of
the original's FMOD Ex. `audio:load-sound` warns and returns `NIL` for a missing file
rather than signalling, because a level should not fail to load over a sound effect —
which mattered, because the original's configs named `jaguar.wav`, an FMOD sample that was
never shipped with the game. Nothing in the port read those entries, and they have since
been removed from the two configs that carried them.

Music is currently loaded with `Mix_LoadMUS`, which streams from the file for as long as
it plays. That is fine on a local disk and a hazard on a network share — see the residency
discussion in `LGAME-NOTES.md`.
