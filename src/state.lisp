(in-package #:com.thejach.descendant.state)

;;;; The handful of values that outlive a level switch.
;;;;
;;;; Port of the live parts of `struct DescendantState` (dsc_descendant_state.h) plus the
;;;; one field of g_player that crosses the same boundary. In the original these are file
;;;; -scope globals, which is why nothing has to pass them anywhere: the menu writes
;;;; g_dscState.d_difficulty and the enemy loader reads it three levels away. Our
;;;; subsystems are owned by the level and rebuilt when it reloads, so anything that has
;;;; to survive that needs a home here.
;;;;
;;;; Deliberately small. Volumes are NOT here -- they live in the audio layer's own
;;;; globals, which are already process-wide, and duplicating them would just create two
;;;; sources of truth. Nor is the theme, which the game level owns and cycles itself.

(defconstant +boot-difficulty+ 2
  "The difficulty before anything has set one. CHANGED FROM THE ORIGINAL, which uses 4
   (`d_difficulty = 4; //### magic! fix` -- the comment is theirs).

   4 is outside the 1-3 range the options screen offers, so the shipped default was
   harder than anything a player could choose. It is not a subtle difference: shot
   cooldowns are `base - difficulty * k`, and at 4 the cover shot's works out negative,
   which means it fires EVERY tick instead of every fifth.

   The original relied on 4 being out of range as a sentinel for 'the player has not
   chosen'; *DIFFICULTY-CHOSEN?* below says that outright instead, so the value is free
   to be a sane one. 2 is the middle of the range, and matches what the shipped
   level_menu.cfg sets anyway -- so in practice this only changes the brief window
   before the menu has loaded.")

(defvar *difficulty* +boot-difficulty+
  "g_dscState.d_difficulty. Read when enemy definitions are loaded: health is
   `health + difficulty*3`, and every bullet pattern's speed and delay are scaled by it.
   So it takes effect on the next level load, not immediately -- same as the original.")

(defvar *difficulty-chosen?* nil
  "Whether the player has picked a difficulty, in which case the menu's config file must
   not overwrite it.

   The original expresses this without a flag: MENU_loadLevel stashes the difficulty if
   it is `!= 4`, reloads the config over it, and puts the stash back. That works because
   4 is the boot value and the options screen clamps to 1-3, so `!= 4` means exactly
   'the player has been here'. Same behaviour, said out loud -- and saying it out loud is
   what lets +BOOT-DIFFICULTY+ be a playable number.")

;;; What difficulty actually does, since it is not obvious from the options screen:
;;;
;;;   Enemy health    `health + difficulty * 3`, applied when definitions load.
;;;   Shot cooldown   `base - difficulty * k`, in ticks between volleys. LOWER is
;;;                   faster, so higher difficulty fires more often -- and the
;;;                   subtraction is not floored, so a high enough difficulty makes it
;;;                   negative and the enemy fires every single tick.
;;;   Shot gate       `base - difficulty * k`, compared against `x < 240 - gate`. Lower
;;;                   means the enemy starts shooting from further right, so it gets
;;;                   more shots in as it crosses.
;;;
;;; Every one of those makes a step of difficulty worth a lot. Between 1 and 3 the
;;; straight shot's cooldown goes 17 -> 11 ticks, so the same enemy fires half again as
;;; often, on top of taking more hits to kill.

(defparameter *themes* '(:crash-site :hidden-cave :brain-pain)
  "DSC_THEME_CRASH_SITE, _HIDDEN_CAVE, _BRAIN_PAIN, in enum order.")

(defvar *theme* :crash-site
  "g_dscState.d_theme. DSC_INITIAL_THEME is crash_site.

   This has to live out here rather than on the game level, because the level that
   advances it is torn down and rebuilt by the switch that acts on it -- the outgoing
   instance sets the next theme, and a fresh instance reads it. Keeping it on the level
   meant the advance was thrown away and the same level played forever.")

(defvar *cycle* 0
  "How many times the theme list has wrapped. ADDED, not ported -- the original just
   loops the three themes identically forever.")

(defconstant +max-difficulty+ 4
  "How hard the loop may get. ADDED, not ported.

   Four because that is where the shot cooldowns stop meaning anything: they are
   `base - difficulty * k` and are not floored, so by four several are already negative
   and those enemies fire every tick. Enemy health would keep climbing past it -- it is
   `health + difficulty * 3` with no ceiling -- but a fifth lap of nothing but tougher
   enemies is arithmetic rather than a fight, so the ramp stops here.

   Also four because it is the value the original booted at, which nothing could select
   and which its own author marked `//### magic! fix`. See +BOOT-DIFFICULTY+.")

(defun advance-theme ()
  "The themes cycle; there is no end. Past the last one it wraps to DSC_INITIAL_THEME,
   which is why the shipped game is three levels that loop rather than a campaign.

   Each lap is harder than the last. ADDED: the original looped at a fixed difficulty
   forever, so beating stage three was the end of the game in every sense except the
   score. The step is runtime only -- the options setting is what a new run starts from
   and is not written to."
  (let ((next (second (member *theme* *themes*))))
    (cond (next (setf *theme* next))
          (t (incf *cycle*)
             (setf *theme* (first *themes*))
             (setf *difficulty* (min +max-difficulty+ (1+ *difficulty*)))))
    ;; Returns the theme, which callers use -- the difficulty step must not become the
    ;; value of the wrap branch.
    *theme*))

(defparameter *cave-palettes* '(:ice :brown)
  "ADDED, not ported. The cave was drawn brown and shipped blue -- the palette's two
   custom slots go through a COLORREF R/B swap on the way to the screen (PLAN.md D1).
   Both looks are real: one is what the level was meant to be, the other is what a
   generation of players actually saw.

   Since the game loops the same three levels forever anyway, the cycle picks a different
   one each time round rather than choosing between them. Blue first, because that is the
   one that shipped.")

(defun cave-palette (&optional (cycle *cycle*))
  (nth (mod cycle (length *cave-palettes*)) *cave-palettes*))

;;; ---------------------------------------------------------------------------
;;; Game speed
;;;
;;; ADDED, not ported, and the reason it is needed takes a paragraph.
;;;
;;; Every gameplay quantity in the original is counted in TICKS against a timestep that
;;; is hardcoded: `d_timeLastTick = 0.016f` sits under an `#if 1` that compiles out the
;;; real measurement, and timeEndFrame only busy-waits to 15 ms when frame-binding is on.
;;; So the game advances a fixed notional 16 ms per frame no matter how long the frame
;;; actually took -- a machine managing 30 fps ran the entire world at half speed, and
;;; that is the speed it was play-tested and balanced at.
;;;
;;; We hit 62.5 Hz comfortably, so we get the same game at roughly twice the rate. Shot
;;; cooldowns are the part you feel: the cover shot's is 2 ticks, which is 15 shots a
;;; second on the original's hardware and 31 on ours, from each of forty-odd enemies.
;;;
;;; Two ways out, and they are worth having both because they trade different things:
;;;
;;;   :SMOOTH    run at 62.5 Hz and multiply the tick-counted RATES by 62.5/30, so they
;;;              come out at the original's wall-clock pace while movement stays smooth.
;;;              Costs exactness: the ratio between firing and movement is no longer the
;;;              original's, and only the durations listed below are converted.
;;;
;;;   :ORIGINAL  run the whole loop at 30 Hz and leave every count alone. Exact in every
;;;              ratio because nothing is converted -- it IS the original, on the
;;;              hardware it was written for -- at the price of looking choppy.
;;;
;;; :SMOOTH is the default because it is the better game; :ORIGINAL is there to compare
;;; against, and is the honest reference when the two disagree.

(defconstant +tuned-hz+ 30.0
  "The rate the original's per-tick constants were effectively tuned at. A judgement
   call -- the code targets 60 and never says what it achieved -- but it is the figure
   that makes the shot rates match how the game is remembered.")

(defvar *simulation-hz* 62.5
  "Ticks per second the loop is paced at. Lowering this slows EVERYTHING uniformly,
   because the timestep stays fixed at 0.016 whatever the real frame time -- exactly how
   the original behaved on a machine that could not keep up.")

(defvar *time-based-rates?* t
  "Whether tick-counted durations are scaled to real time. See SCALE-TICKS for the list
   of what is converted and what deliberately is not.")

(defun rate-scale ()
  "Ticks here per tick the original assumed. 1.0 when conversion is off."
  (if *time-based-rates?* (/ *simulation-hz* +tuned-hz+) 1.0))

(defun scale-ticks (ticks)
  "Convert a duration written in the original's ticks into ours.

   Applied to the durations a player actually feels -- shot cooldowns, both the player's
   and the enemies', and power-up lifetimes. NOT applied to animation timing, effect
   frames or the level's own sequencing: those are cosmetic or structural, they look
   better at the higher rate, and converting them would mean touching every timer in the
   game to fix a complaint about two of them. :ORIGINAL is the exhaustive answer.

   Never rounds a positive duration down to zero -- a cooldown of 0 means firing every
   single tick, which is the failure this exists to prevent."
  (if (plusp ticks)
      (max 1 (round (* ticks (rate-scale))))
      ticks))

(defparameter *speed-presets*
  '((:smooth   :hz 62.5 :time-based t)
    (:original :hz 30.0 :time-based nil))
  "Both presets produce the same gameplay PACE; they differ in how smooth it looks.")

(defvar *speed-preset* :smooth)

(defun set-speed-preset (name)
  (let ((preset (assoc name *speed-presets*)))
    (when preset
      (setf *speed-preset* name
            *simulation-hz* (float (getf (cdr preset) :hz) 1.0)
            *time-based-rates?* (getf (cdr preset) :time-based))
      name)))

(defun cycle-speed-preset ()
  "Next preset in the list, wrapping."
  (let ((names (mapcar #'car *speed-presets*)))
    (set-speed-preset (or (second (member *speed-preset* names)) (first names)))))

(defvar *continue-theme* nil
  "The theme a run ended on, if it was not the first. ADDED, not ported -- the original
   has no continue at all; START always begins at crash_site and dying sends you back to
   it with nothing kept.

   Reaching stage three takes long enough that replaying stage one every time to practise
   a later fight is its own obstacle. CONTINUE resumes where you fell, but with a score of
   zero, so it costs the leaderboard rather than nothing: a continued run cannot beat an
   unbroken one.")

(defun record-death-at (theme)
  "Offer a continue if the run got past the first theme."
  (setf *continue-theme* (unless (eq theme (first *themes*)) theme)))

(defun continue-available? () (and *continue-theme* t))

(defun begin-new-run ()
  "START: always crash_site, nothing carried, no continue outstanding.

   Difficulty comes back to whatever the options screen says, undoing however many laps
   the last run climbed. A run that reached the fourth lap must not leave the next one
   starting there."
  (setf *theme* (first *themes*)
        *cycle* 0
        *run-score* 0
        *continue-theme* nil
        *difficulty* (settings:value :difficulty)))

(defun resume-run ()
  "CONTINUE: back to where the run ended, at zero.

   Difficulty resets too. Continuing already costs the score; carrying the ramp as well
   would make it a worse deal than starting over, which is not what it is for."
  (when *continue-theme*
    (setf *theme* *continue-theme*
          *run-score* 0
          *continue-theme* nil
          *difficulty* (settings:value :difficulty))
    *theme*))

(defvar *run-score* 0
  "The score so far in the current run, across level changes.

   The original needs nothing here: g_player is a global, so beating a level and warping
   to the next simply leaves d_score where it was. `g_player.d_score = 0` appears exactly
   once in the whole game, in the ESC-to-menu handler. Our player belongs to the level and
   is rebuilt on load, so without this the score resets at every warp -- which also meant
   dying on stage two offered a stage-two-only total to the high score table, usually too
   small to qualify.")

(defvar *carried-score* 0
  "g_player.d_score, at the moment a run ends.

   The original needs no equivalent: g_player is a global that outlives the level switch,
   so SCORE_loadLevel simply reads d_score and zeroes it. Our player belongs to the level
   and is rebuilt on load, so the value has to be parked between the two.")

(defun difficulty-from-config (value)
  "Apply a config file's difficulty, unless the player has already chosen one."
  (unless *difficulty-chosen?*
    (setf *difficulty* value))
  *difficulty*)

(defun set-difficulty (value)
  "Apply the player's choice, and remember that they made one."
  (setf *difficulty* value
        *difficulty-chosen?* t)
  value)

(defun reset ()
  "Back to a fresh boot. For tests, and for a future 'restore defaults'."
  (setf *difficulty* +boot-difficulty+
        *difficulty-chosen?* nil
        *theme* (first *themes*)
        *cycle* 0
        *run-score* 0
        *continue-theme* nil
        *carried-score* 0)
  (set-speed-preset :smooth))
