# Documentation

The Descendant is a 2010 student game, about 28,000 lines of ANSI C, written to run
inside the Windows console. This is a port of it to Common Lisp on
[lgame](https://github.com/Jach/lgame), and these documents are meant to be read either
before the source or beside it.

They are not a tutorial and not an API reference. What they try to give you is the shape
of the thing and the reasoning behind the parts that look strange — because a fair number
of parts do look strange, and almost all of them look that way because the original did.
Working out which oddities are load-bearing and which are ours took longer than writing
the code, so it is written down here rather than left for the next person to rediscover.

## Reading order

| | |
|---|---|
| [architecture.md](architecture.md) | The frame loop, the level protocol, and what all 42 packages are for. Start here. |
| [rendering.md](rendering.md) | Cells, glyphs, the compositor, and the two renderers. The heart of the port. |
| [assets.md](assets.md) | The original's binary formats, read unmodified, and the colour bug we had to keep. |
| [building.md](building.md) | Running it, testing it, and producing the Linux and Windows bundles. |

If you only want to change gameplay, `architecture.md` plus the level you care about is
enough. If you want to touch anything that draws, read `rendering.md` first — the
coordinate conventions are not the ones you expect.

## A note on fidelity

The rule for the port was that the original assets ship in their original formats, and that the game
plays the way it played in 2010. That rule decides a surprising number of arguments. The
right-hand column of the screen was dead in the original because of an off-by-one in the
clipping test; the colour-pair encoding the sprite editor wrote is not the encoding the
game read back. In both cases the question "what is correct?" has no useful answer, and
the question "what did players see?" has exactly one.

Where we deviate, it is deliberate and marked. Several files open with `ADDED, not
ported.` — the options screen, the persistent settings, the credits showcase, the
bestiary, the screen wipe. The original had no persistent settings at all.

Where the original was simply wrong in a way nobody could see, we usually fixed it and
left a switch to put it back, because the test suite pins the old behaviour:

```lisp
(defparameter *right-edge-off-by-one* nil
  "...Bind it to T to reproduce the original artifact (the test suite does...)")
```

## The original is not in this repository

Almost every file in `src/` opens by naming the C file it came from:

```lisp
;;;; Port of origRef/GamePlay/dsc_enemies.c.
```

That path will not resolve here. `origRef/` was the original 2010 source tree, used
throughout the port as the reference, and it is not published — it is a DigiPen student
project with four authors and a pile of third-party SDK binaries in it, none of which are
ours to redistribute. The headers are left in place because they say where each piece came
from and what it is answerable to, which is worth more than a path that resolves. Grepping
for `Port of` still gives the whole correspondence, and the files marked `ADDED, not
ported.` are the ones with no counterpart.

For the same reason, the build scripts that produce the Linux and Windows bundles may not
be here either: they hardcode paths on the author's machine. [building.md](building.md)
describes what they do, which is the part worth keeping.

## Conventions in these documents

Source references are `file:line` against `src/`, and they were accurate when written; the
line numbers will drift, the file names will not. Numbers quoted as measurements are
measurements — where you see a frame rate or a percentage, it came from running something,
and the document says what.
