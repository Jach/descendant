(in-package #:com.thejach.descendant.level)

;;;; The level state machine, porting gam_state_manager.c + gam_main.c's two loops.
;;;;
;;;; The original's structure:
;;;;
;;;;   gameLoop:  initGame; do { updateGame; updateLoop } while state /= QUIT
;;;;   updateLoop: do { beginFrame; poll; updateFrame; renderFrame; endFrame }
;;;;               while state == PLAY
;;;;
;;;; where updateGame is what actually performs a level transition: deinit/unload the
;;;; outgoing level, then load/init the incoming one. A level asks for a transition by
;;;; setting d_level and d_state, which is REQUEST-LEVEL here.
;;;;
;;;; Timing (sys_time.c): d_timeStep is pinned to a fixed 0.016 s by an `#if 1` that
;;;; disabled the real measurement, and endFrame busy-waits until 15 ms have passed.
;;;; So logic was simulated at 62.5 Hz while wall clock ran at up to ~66 Hz -- a 7%
;;;; mismatch the original simply lived with. We keep the fixed 0.016 step and pace the
;;;; loop at exactly 62.5 Hz so simulated and wall time agree.

(defconstant +time-step+ 0.016
  "g_time.d_timeStep, fixed. Every level's animation timing is written against this.")

(defun logic-hz ()
  "Ticks per second the loop is paced at.

   At the default 62.5 this is 1 / +time-step+, so wall time matches simulated time. The
   speed preset can lower it, which does NOT change the timestep -- the game then advances
   0.016 s of world per 0.033 s of wall clock, running at half speed, exactly as the
   original did on hardware that could not keep up. See state.lisp."
  state:*simulation-hz*)

(defvar *state* :play "One of :play, :switch-level, :quit.")
(defvar *current* nil "The running level instance.")
(defvar *requested* nil "Level keyword requested for the next transition.")
(defvar *frame* 0 "g_time.d_nFrame: increments every logic tick, never reset.")

(defparameter *render-mode* :60-fps
  "RenderMode, i.e. how often the cell buffer is actually presented. Logic always runs
   at the fixed 0.016 s step, so this changes smoothness and nothing else -- game speed
   is identical in every mode.

   The shipped game defaulted to :30-fps (d_videoQuality in gam_parseArgs), presenting
   on even frames only, almost certainly because the console renderer could not keep up.
   Our renderer has no such trouble, so we present every tick -- 62.5 fps, since that is
   what the fixed timestep implies.

     :60-fps   present every tick (62.5 Hz)     <- default
     :30-fps   present on even ticks            <- the original's behaviour
     :20-fps   present every third tick
     :unbound  present every tick, no pacing

   Truly decoupling presentation from logic (vsync, or unlimited with interpolation)
   needs an accumulator loop; see PLAN.md milestone 5 for the options-menu work.")

;;; ---------------------------------------------------------------------------
;;; Levels

(defclass level ()
  ((name :initarg :name :reader level-name :initform "level")))

(defgeneric load-level (level)
  (:documentation "Read configuration and assets. Runs once before INIT-LEVEL.")
  (:method ((level level)) t))

(defgeneric init-level (level)
  (:documentation "Reset per-run state and start audio.")
  (:method ((level level)) t))

(defgeneric update-level (level)
  (:documentation "Advance one fixed 0.016 s tick.")
  (:method ((level level)) t))

(defgeneric render-level (level screen)
  (:documentation "Enqueue sprites onto SCREEN. Compositing happens in the caller.")
  (:method ((level level) screen) (declare (ignore screen)) t))

(defgeneric level-colormap (level)
  (:documentation "The 16-colour palette this level draws with, or NIL to keep the
   current one. The renderer follows this, mirroring the original's
   g_rdr.set_color_map call inside OM_load_theme -- without it every colour resolves
   to black.")
  (:method ((level level)) nil))

(defgeneric handle-event (level event)
  (:documentation "Handle one SDL event.")
  (:method ((level level) event) (declare (ignore event)) nil))

(defgeneric deinit-level (level)
  (:method ((level level)) t))

(defgeneric unload-level (level)
  (:documentation "Release assets. Runs once after DEINIT-LEVEL.")
  (:method ((level level)) t))

(defvar *registry* (make-hash-table :test #'eq)
  "Keyword -> class name, the equivalent of gam_assignLevelFunc's switch.")

(defun register-level (keyword class-name)
  (setf (gethash keyword *registry*) class-name))

(defgeneric item-at (level column row)
  (:documentation
   "What is drawn at cell (COLUMN, ROW), if it is something the player can choose.

    COLUMN and ROW are cells of the 240x120 picture, ROW counting DOWN from the top the
    way a pointer does -- not the bottom-up y SCREEN:ENQUEUE takes, because a caller
    holding a screen position has no reason to know about that.

    Returns an opaque designator to hand back to SELECT-ITEM, or NIL for nothing. NIL by
    default, so a level opts in by knowing where it drew things; a level that does not
    implement this simply cannot be tapped, which is the honest answer for one that has
    no items.")
  (:method ((level t) column row)
    (declare (ignore level column row))
    nil))

(defgeneric select-item (level item)
  (:documentation
   "Move the highlight to ITEM, which came from ITEM-AT. Returns T if it moved.

    Deliberately separate from acting on it: touch selects and then sends Return, so the
    level's own activation path runs and there is exactly one place where choosing an
    option does what it does.")
  (:method ((level t) item)
    (declare (ignore level item))
    nil))

(defun current-key ()
  "The keyword the running level was registered under, or NIL if none is running.

   The registry maps keyword to class, and a level instance knows its class, so this is
   the lookup run backwards. Wanted by anything that has to act differently per level
   without being one -- the touch layer decides what a two-finger tap means that way,
   since the gesture is 'pause' in the game and 'show the bestiary' in the credits."
  (let ((class (and *current* (class-name (class-of *current*)))))
    (when class
      (loop for keyword being the hash-keys of *registry* using (hash-value registered)
            when (eq registered class) return keyword))))

(defun make-level (keyword)
  (let ((class (gethash keyword *registry*)))
    (unless class
      (error "No level registered under ~s. Known: ~s"
             keyword (loop for k being the hash-keys of *registry* collect k)))
    (make-instance class)))

;;; ---------------------------------------------------------------------------
;;; Transitions

(defun request-level (keyword)
  "Ask for a switch to KEYWORD after the current tick finishes."
  (setf *requested* keyword
        *state* :switch-level))

(defun request-quit ()
  (setf *state* :quit))

(defun %switch-to (keyword)
  (when *current*
    (deinit-level *current*)
    (unload-level *current*))
  (let ((level (make-level keyword)))
    (setf *current* level)
    (unless (load-level level)
      (error "Level ~s failed to load." keyword))
    (unless (init-level level)
      (error "Level ~s failed to initialise." keyword))
    (setf *state* :play
          *requested* nil)
    level))

(defun start-level (keyword)
  "Enter KEYWORD as the first level, with nothing to tear down first."
  (%switch-to keyword))

(defun switch-if-requested ()
  "Perform a pending transition. This is gam_state_manager's updateGame: it runs between
   ticks, never in the middle of one, so a level can safely ask to switch from anywhere
   inside its update."
  (when (eq *state* :switch-level)
    (%switch-to *requested*)))

(defun present-this-frame? ()
  "GR_render's frame-skipping: 30 FPS mode renders on even frames, 20 FPS every third."
  (ecase *render-mode*
    (:unbound t)
    (:60-fps t)
    (:30-fps (evenp *frame*))
    (:20-fps (zerop (mod *frame* 3)))))

(defun measured-fps ()
  "g_time.d_FPS: how fast the loop is ACTUALLY running, which is not the same as
   *LOGIC-HZ* -- that is the rate we ask for, this is the rate we get.

   Reads lgame's frame duration, which includes the delay the frame limiter added, so a
   comfortably-idle game reports the limit rather than the uncapped rate. Zero on the
   very first frame, before any duration has been measured."
  (let ((dt (lgame.time:dt)))
    (if (plusp dt) (float (/ 1.0d0 dt) 1.0) 0.0)))

(defvar *screen* nil
  "The cell buffer for the tick in progress, so UPDATE-LEVEL can reach the renderer's
   back buffer the way the original reaches for the g_rdr global. Only the warp hole
   needs it -- it snapshots the previous frame's back buffer during update.")

(defun advance (screen)
  "One logic step. SCREEN is bound for the tick because the warp hole reaches for the
   renderer's back buffer during update, the way the original reaches for g_rdr."
  (let ((*screen* screen))
    (update-level *current*))
  (incf *frame*)
  *state*)

(defun present (screen renderer)
  "Composite the current state and put it on the display.

   Separate from ADVANCE because the two no longer happen in lockstep: the main loop runs
   logic on a fixed step and presents once per iteration, so that the frame rate can be
   whatever the display and the settings want without changing the game."
  (when (present-this-frame?)
    (renderer:ensure-palette renderer (level-colormap *current*))
    (render-level *current* screen)
    (screen:composite screen)
    (renderer:rasterize renderer screen)
    (renderer:present renderer))
  *state*)

(defun tick (screen renderer)
  "One logic step and one present. The shape the loop had before logic and presentation
   were decoupled, kept because it is what the headless helpers and most tests want: they
   have no display to pace against and simply need N steps to happen."
  (advance screen)
  (present screen renderer))

(defun shutdown ()
  (when *current*
    (deinit-level *current*)
    (unload-level *current*)
    (setf *current* nil)))
