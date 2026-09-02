# Architecture

## The shape of a frame

`main.lisp` holds the loop, and it is short enough to read in one go:

```lisp
(defun game-tick ()
  (lgame.event:do-event (event)
    (unless (handle-global-event event)
      (level:handle-event level:*current* event)))

  (level:tick *screen* *renderer*)

  (level:switch-if-requested)

  (livesupport:update-repl-link)
  (lgame.time:clock-tick (unless *unlimited?* (level:logic-hz)))

  (when (eq level:*state* :quit)
    (lgame.time:clock-stop)))
```

Events first, then one logic step and one present, then any pending level switch, then
pace the loop. `livesupport:update-repl-link` is what keeps a SLIME/SLY connection alive
while the loop is running, so you can redefine `game-tick` — or anything it calls — in a
live game. That is worth more here than it sounds. Most of this port was verified by
recompiling a function and watching the running game change.

**The switch happens between ticks, never inside one.** `level:request-level` only sets
`*requested*` and flips `*state*` to `:switch-level`; `switch-if-requested` does the work
afterwards. That is the original's `gam_state_manager`, and it means a level can ask to
switch from anywhere inside its update without tearing down the objects it is in the
middle of iterating.

### Pacing

The loop runs at **62.5 ticks per second**, not 60. That is `1 / +time-step+`, so one tick
of wall clock equals one tick of simulated time and the original's constants transfer
without scaling.

`level:logic-hz` can go lower — the speed preset uses it — and this does *not* change the
timestep. The game simply advances more slowly in real time, which is what a speed setting
should mean for a fixed-timestep simulation.

F9 (`*unlimited?*`) removes the pacing entirely. The game then runs as fast as the machine
allows, speed and all, which is unplayable on purpose. It is a measuring instrument: with
the FPS readout on, the number tells you the headroom over the 62.5 the game actually
wants. That is how the GL renderer was justified.

## Levels

Everything that occupies the screen is a level, including the menu, the credits and the
high-score table. The protocol is nine generic functions in `level.lisp:59`:

| | |
|---|---|
| `load-level` / `unload-level` | acquire and release assets |
| `init-level` / `deinit-level` | per-entry state, run on every entry |
| `update-level` | one logic tick |
| `render-level` | enqueue sprites; see [rendering.md](rendering.md) |
| `level-colormap` | which palette this level draws with |
| `handle-event` | input the global handler did not claim |

The load/init split matters when a level is re-entered: the menu is entered many times per
session and should not re-read its theme file each time.

The concrete levels are `level-intro`, `level-menu`, `level-controls`, `level-score`,
`level-credits`, `level-descendant` (the game itself, and the largest at 610 lines),
`level-bestiary` and `level-placeholder`.

Three globals carry the state, all in `level.lisp`:

```lisp
(defvar *state* :play "One of :play, :switch-level, :quit.")
(defvar *current* nil "The running level instance.")
(defvar *frame* 0 "g_time.d_nFrame: increments every logic tick, never reset.")
```

`*frame*` never resets, which is not an accident — a great deal of the original's timing
is phrased as `frame mod n`, and resetting it per level would change enemy firing patterns.

## Subsystems

The port is package-per-file, 42 packages under `com.thejach.descendant`, with
package-local nicknames rather than global ones. Most files open by naming the C file they
came from, so `enemies.lisp` starts `Port of origRef/GamePlay/dsc_enemies.c`. Grepping for
`Port of` gives you the whole correspondence.

**Gameplay** — `player`, `enemies` (1180 lines, the biggest thing in the port), `bullets`,
`collectables`, `spawner`, `effects`, `emitter`, `environment`, `collision`, `movement`,
`warp`, `static-field`, `hud`, `cheats`.

**Presentation** — `screen`, `renderer`, `renderer.gl`, `glyph`, `theme`, `font`, `text`,
`field`, `screen-effect`, `wipe`, `showcase`.

**Support** — `paths`, `settings`, `state`, `config`, `binary`, `audio`, `rect`.

A few things worth knowing about specific ones:

**`rect` is not `lgame.box`, deliberately.** The original's `Rect_collide_rect` is a
different predicate from `lgame.box:boxes-intersect?` — measured on identical geometry, 3
of 7 cases disagree. It is half-open in X and requires one top to be strictly above the
other, so two rects sharing a Y never collide. Gameplay was tuned against that. Adopting
the standard closed-interval test would make bullets start hitting things they currently
pass through. The full comparison is in `LGAME-NOTES.md`.

**`state` holds what outlives a level switch** — score, lives, difficulty. Everything else
dies with the level.

**`collision` is a manager, not a pairwise sweep.** Colliders register with a world and a
callback; the player is a collider too, which is how enemies and pickups find it.

**`audio` wraps `sdl2-mixer` and does more than you would expect it to have to.** SDL_mixer
defaults to 8 channels, which this game exhausts in seconds; it also refuses rather than
steals when saturated, and has no per-sound voice cap, so 70 overlapping copies of an
identical waveform become a +17 dB volume ramp rather than a denser texture. All three
have fixes in `audio.lisp`, and all three are argued for upstream promotion in
`LGAME-NOTES.md`.

## Where the port deviates

Files that say `ADDED, not ported.` at the top: `settings.lisp`, `level-bestiary.lisp`,
`showcase.lisp`, `wipe.lisp`. The options screen and the settings behind it are the largest
addition — the original had no persistence of any kind, so difficulty and volume reset
every launch.

The other systematic deviation is that the renderer is pluggable, which the original's
could not be. See [rendering.md](rendering.md).
