(defpackage #:com.thejach.descendant.touch
  (:use #:cl)
  (:local-nicknames (#:level #:com.thejach.descendant.level)
                    (#:screen #:com.thejach.descendant.screen))
  (:documentation
   "Touch input. Android only -- the whole file is absent from other builds, see
    descendant.asd.")
  (:export #:translate #:tick #:vertical-row #:text-input))

(in-package #:com.thejach.descendant.touch)

;;;; Two different jobs, and it took two wrong versions to see they were different.
;;;;
;;;; MENUS want events. Up means "the next item", once, and again if you keep asking.
;;;; That is a keyboard, and the honest translation is a keyboard: hold past a threshold
;;;; and get an arrow keypress, with auto-repeat, exactly as a held key behaves.
;;;;
;;;; FLYING wants a position. The first version held an arrow while the finger was off
;;;; centre, which gave exactly one turn rate and no small corrections. The second made
;;;; deflection a duty cycle, which is proportional but still asks the player to steer an
;;;; accelerating ship through a control with no position feedback -- worse, because now
;;;; the response depended on how long they had been holding.
;;;;
;;;; So vertically the ship simply goes where the finger is. PLAYER:SET-VERTICAL-CENTER-ROW
;;;; places it outright. That is more control than a keyboard gives; on a touchscreen the
;;;; alternative is worse.
;;;;
;;;; Horizontally it stays a stick, because there is nowhere to put an absolute x: the
;;;; ship's forward drift is the game, and a finger cannot hold a position the ship is
;;;; not allowed to stay at. But the CENTRE MOVES. A thumb sliding up and down is not
;;;; asking to go sideways, however much it wanders, so while the movement is mostly
;;;; vertical the centre follows the finger. Only a movement that is both sideways enough
;;;; and far enough pins the centre and starts pushing.

;;; ---------------------------------------------------------------------------
;;; Tunables, in fractions of the SHORT screen edge -- see %ASPECT.

(defparameter *deadzone-x* 0.03
  "How far sideways of the moving centre before left or right engages at all.")

(defparameter *saturation-x* 0.13
  "How far sideways before the axis is asking for everything. Short, because horizontal
   is a trim control on a ship that already drifts, and a long throw made it feel dead.")

(defparameter *horizontal-bias* 0.8
  "How much more sideways than vertical a movement must be to count as sideways. Below
   this the centre follows the finger instead, so a wandering vertical drag does not
   accumulate into a lunge.")

(defparameter *menu-step* 0.05
  "Deflection at which a menu axis emits an arrow key.")

(defparameter *menu-first-repeat* 0.35
  "Seconds held before a menu arrow starts repeating -- the pause a keyboard gives you.")

(defparameter *menu-repeat* 0.12
  "Seconds between repeats once it starts.")

(defparameter *tap-seconds* 0.4
  "A press shorter than this, that never asked for anything, is a tap.")

(defparameter *edge-margin* 0.06
  "A band top and bottom where touches are ignored, because Android hides the navigation
   bar and the notification shade behind swipes from those edges. Without it, reaching
   for the back button drives the ship and registers as a tap -- which in the menu
   selects whatever was highlighted.")

;;; ---------------------------------------------------------------------------
;;; Pushing keys

(defparameter *event-size*
  (autowrap:foreign-type-size (autowrap:find-type 'sdl2-ffi:sdl-event)))

(defun %push-key (scancode down?)
  (lgame.event:with-event (event)
    ;; Zeroed first: WITH-EVENT hands back uninitialised stack memory and SDL_PushEvent
    ;; copies the whole struct.
    (cffi:foreign-funcall "memset" :pointer event :int 0 :size *event-size* :pointer)
    (setf (lgame.event:ref event :type)
          (if down? lgame::+sdl-keydown+ lgame::+sdl-keyup+)
          (lgame.event:ref event :key :state) (if down? 1 0)
          (lgame.event:ref event :key :repeat) 0
          (lgame.event:ref event :key :keysym :scancode) scancode)
    (cffi:foreign-funcall "SDL_PushEvent" :pointer event :int)))

(defun %press-and-release (scancode)
  "For gestures that mean something once rather than continuously."
  (%push-key scancode t)
  (%push-key scancode nil))

;;; ---------------------------------------------------------------------------
;;; State

(defvar *finger* nil "The finger driving the stick; the others only count.")
(defvar *fingers* '() "Every finger currently down, so a gesture can count them.")
(defvar *origin-y* 0.0 "Where the finger went down; menus measure from here.")
(defvar *centre-x* 0.0 "The stick's centre, which moves. See the header.")
(defvar *last-x* 0.0)
(defvar *last-y* 0.0)
(defvar *finger-y* nil "Latest finger y, 0..1 down the window, or NIL when lifted.")
(defvar *down-at* 0)
(defvar *asked?* nil "Set once the finger asks for anything; a tap never does.")
(defvar *gesture?* nil
  "Set when a second finger fired a gesture, so lifting does not also fire a tap.

   Without this a two-finger tap in the credits started the bestiary wipe and then
   immediately sent Return, which asks for the menu -- so the gesture appeared not to
   work at all.")

(defvar *rate-x* 0.0 "Signed duty cycle, -1..1.")
(defvar *phase-x* 0.0)
(defvar *down-x* nil)

(defvar *menu-next-x* 0 "Internal-time at which the axis may emit again.")
(defvar *menu-next-y* 0)

(defun %aspect ()
  "Width over height. Finger coordinates are normalised per axis, so on a 2480x1116
   screen the same fraction is 2.2 times further in x than in y."
  (if lgame:*screen*
      (multiple-value-bind (w h) (sdl2:get-window-size lgame:*screen*)
        (if (and w h (plusp h)) (/ (float w) (float h)) 1.0))
      1.0))

(defun %flying? ()
  (eq (level:current-key) :descendant))

;;; ---------------------------------------------------------------------------
;;; Flying: vertical is a position

(defun vertical-row ()
  "Which row of the picture the finger is on, counting down from the top, or NIL if it
   is not touching. Fractional, so the ship moves smoothly rather than in whole cells.

   A row and not a fraction of the play area, because those are not the same thing and
   the difference is visible. The play area is inset -- the ship may not fly into the
   top four rows or the bottom ten -- so mapping 0..1 across it puts the ship at a
   proportional position rather than under the finger, several rows adrift at the middle
   of the screen. A row is where the finger actually is, and PLAYER clamps it.

   The window is not the picture either: 960x720 is letterboxed into the drawable, so
   this goes through the same scale and origin the shader uses."
  (when *finger-y*
    (multiple-value-bind (w h)
        (if lgame:*screen*
            (sdl2:get-window-size lgame:*screen*)
            (values screen:+pixel-width+ screen:+pixel-height+))
      (let* ((w (float (or w screen:+pixel-width+) 1.0))
             (h (float (or h screen:+pixel-height+) 1.0))
             (scale (min (/ w screen:+pixel-width+) (/ h screen:+pixel-height+)))
             (picture (* screen:+pixel-height+ scale))
             (origin (/ (- h picture) 2.0))
             (pixel (/ (- (* *finger-y* h) origin) (max 1e-6 scale))))
        (/ pixel (float screen:+cell-height+ 1.0))))))

;;; ---------------------------------------------------------------------------
;;; Flying: horizontal is a stick whose centre moves

(defun %rate (offset deadzone saturation)
  (let ((magnitude (abs offset)))
    (if (<= magnitude deadzone)
        0.0
        (* (float (signum offset))
           (min 1.0 (/ (- magnitude deadzone) (max 1e-6 (- saturation deadzone))))))))

(defun %aim-horizontal (x y)
  (let* ((aspect (%aspect))
         (offset (* (- x *centre-x*) aspect))
         (step-x (* (- x *last-x*) aspect))
         (step-y (- y *last-y*))
         (sideways? (>= (abs step-x) (* *horizontal-bias* (abs step-y)))))
    (cond
      ;; Not far enough out to mean anything. If the thumb is travelling vertically,
      ;; take its x as the new centre -- that is the whole of "slight movements left or
      ;; right from the y axis their finger is on shouldn't matter".
      ((< (abs offset) *deadzone-x*)
       (unless sideways? (setf *centre-x* x))
       (setf *rate-x* 0.0))
      (t
       (setf *rate-x* (%rate offset *deadzone-x* *saturation-x*))
       (setf *asked?* t)))))

(defun %step-horizontal ()
  "One tick of the horizontal stick: deflection becomes a duty cycle of held arrow.

   Still a duty cycle rather than a position because thrust IS acceleration here --
   holding right for half the ticks accelerates at half the rate, which is what a
   half-pushed stick should do."
  (let ((want nil))
    (cond
      ((< (abs *rate-x*) 1e-6) (setf *phase-x* 0.0))
      (t (incf *phase-x* (abs *rate-x*))
         (when (>= *phase-x* 1.0)
           (decf *phase-x* 1.0)
           (setf want (if (plusp *rate-x*)
                          lgame::+sdl-scancode-right+
                          lgame::+sdl-scancode-left+)))))
    (unless (eql want *down-x*)
      (when *down-x* (%push-key *down-x* nil))
      (when want (%push-key want t))
      (setf *down-x* want))))

;;; ---------------------------------------------------------------------------
;;; Menus: an axis that behaves like a held key

(defun %menu-axis (offset next-place negative positive)
  "Emit an arrow when the finger is past the notch, then repeat as a keyboard would.

   Returns the new next-emit time. Menus move by items, not by distance: a list does not
   scroll twice as fast because the thumb is twice as far out, and asking it to made the
   menu unusable."
  (let ((now (get-internal-real-time)))
    (cond
      ((< (abs offset) *menu-step*) 0)            ; back to centre: ready to fire at once
      ((>= now next-place)
       (%press-and-release (if (plusp offset) positive negative))
       (setf *asked?* t)
       (+ now (round (* (if (zerop next-place) *menu-first-repeat* *menu-repeat*)
                        internal-time-units-per-second))))
      (t next-place))))

(defun %aim-menu (x y)
  (let ((aspect (%aspect)))
    (setf *menu-next-y*
          (%menu-axis (- y *origin-y*) *menu-next-y*
                      lgame::+sdl-scancode-up+ lgame::+sdl-scancode-down+)
          *menu-next-x*
          (%menu-axis (* (- x *centre-x*) aspect) *menu-next-x*
                      lgame::+sdl-scancode-left+ lgame::+sdl-scancode-right+))))

;;; ---------------------------------------------------------------------------
;;; Per-frame

(defun tick ()
  "Called once a frame from GAME-TICK, after the events and before the level updates."
  (when (%flying?) (%step-horizontal)))

(defun %release-all ()
  (setf *rate-x* 0.0 *phase-x* 0.0 *finger-y* nil
        *menu-next-x* 0 *menu-next-y* 0)
  (when *down-x* (%push-key *down-x* nil) (setf *down-x* nil)))

;;; ---------------------------------------------------------------------------
;;; Gestures

(defun %gesture-key (fingers)
  "What FINGERS down at once means, which depends on where you are.

   Nowhere by default: a gesture that does something everywhere does something wrong
   somewhere -- on the score screen the pause key was being typed into the player's name."
  (case (level:current-key)
    ((:descendant) (case fingers
                     (2 lgame::+sdl-scancode-p+)     ; pause
                     (3 lgame::+sdl-scancode-f+)     ; the FPS readout
                     ;; F9 unpaces the loop. Four fingers passes through two and three on
                     ;; the way, which is convenient rather than a nuisance: it pauses,
                     ;; puts the FPS readout up and unlimits, and two fingers then
                     ;; unpauses into a running measurement.
                     (4 lgame::+sdl-scancode-f9+)
                     (t nil)))
    ((:credits) (case fingers
                  (2 lgame::+sdl-scancode-b+)        ; the hidden bestiary
                  (t nil)))
    (t nil)))

(defun %picture-cell (x y)
  "Normalised window coordinates to a cell of the 240x120 picture, or NIL if the touch
   landed on the letterbox rather than the game.

   The same scale and origin the shader uses, for the same reason VERTICAL-FRACTION needs
   them: the window is not the picture."
  (multiple-value-bind (w h)
      (if lgame:*screen*
          (sdl2:get-window-size lgame:*screen*)
          (values screen:+pixel-width+ screen:+pixel-height+))
    (let* ((w (float (or w screen:+pixel-width+) 1.0))
           (h (float (or h screen:+pixel-height+) 1.0))
           (scale (min (/ w screen:+pixel-width+) (/ h screen:+pixel-height+)))
           (px (/ (- (* x w) (/ (- w (* screen:+pixel-width+ scale)) 2.0)) scale))
           (py (/ (- (* y h) (/ (- h (* screen:+pixel-height+ scale)) 2.0)) scale)))
      (when (and (<= 0 px) (< px screen:+pixel-width+)
                 (<= 0 py) (< py screen:+pixel-height+))
        (values (floor px screen:+cell-width+)
                (floor py screen:+cell-height+))))))

(defun %tap-key ()
  "What a tap means, which is Return nearly everywhere.

   The bestiary is the exception: it is left with Escape or B and does not answer to
   Return, so a tap there did nothing and the only way out was the back button."
  (case (level:current-key)
    ((:bestiary) lgame::+sdl-scancode-escape+)
    (t lgame::+sdl-scancode-return+)))

(defun %edge? (y)
  (or (< y *edge-margin*) (> y (- 1.0 *edge-margin*))))

(defun translate (event)
  "Turn a touch or back-button event into key events, or into stick state. Returns T if
   it consumed EVENT; anything else carries on to the level handlers, so a real keyboard
   still works."
  (let ((type (lgame.event:event-type event)))
    (cond
      ((= type lgame::+sdl-fingerdown+)
       (let ((id (lgame.event:ref event :tfinger :finger-id))
             (x (lgame.event:ref event :tfinger :x))
             (y (lgame.event:ref event :tfinger :y)))
         (cond
           ((%edge? y))                           ; the system's gutter: consumed, ignored
           (t
            (pushnew id *fingers*)
            (cond
              ((null *finger*)
               (setf *finger* id
                     *origin-y* y *centre-x* x *last-x* x *last-y* y
                     *finger-y* y
                     *down-at* (get-internal-real-time)
                     *asked?* nil *gesture?* nil
                     *menu-next-x* 0 *menu-next-y* 0))
              (t
               ;; Fired on the count as it becomes two, then three -- so a three-finger
               ;; tap pauses on the way past. Harmless where it happens, and the
               ;; alternative is waiting to see whether a third finger is coming, which
               ;; would make the two-finger gesture feel late.
               (let ((key (%gesture-key (length *fingers*))))
                 (when key (%press-and-release key) (setf *gesture?* t))))))))
       t)

      ((= type lgame::+sdl-fingermotion+)
       (when (eql (lgame.event:ref event :tfinger :finger-id) *finger*)
         (let ((x (lgame.event:ref event :tfinger :x))
               (y (lgame.event:ref event :tfinger :y)))
           (setf *finger-y* y)
           (if (%flying?)
               (progn (%aim-horizontal x y)
                      ;; Vertical needs no aiming: the ship is wherever the finger is,
                      ;; read straight off *FINGER-Y* by the level.
                      (setf *asked?* t))
               (%aim-menu x y))
           (setf *last-x* x *last-y* y)))
       t)

      ((= type lgame::+sdl-fingerup+)
       (setf *fingers* (remove (lgame.event:ref event :tfinger :finger-id) *fingers*))
       (when (eql (lgame.event:ref event :tfinger :finger-id) *finger*)
         (let ((held (/ (float (- (get-internal-real-time) *down-at*))
                        internal-time-units-per-second)))
           (%release-all)
           (when (and (not *asked?*) (not *gesture?*) (< held *tap-seconds*))
             ;; A tap on something choosable picks it first, so the level's own
             ;; activation path still does the choosing.
             (multiple-value-bind (column row)
                 (%picture-cell (lgame.event:ref event :tfinger :x)
                                (lgame.event:ref event :tfinger :y))
               (when column
                 (let ((item (level:item-at level:*current* column row)))
                   (when item (level:select-item level:*current* item)))))
             (%press-and-release (%tap-key))))
         (setf *finger* nil *asked?* nil *gesture?* nil))
       t)

      ;; Android's back button, delivered as a key once SDL_ANDROID_TRAP_BACK_BUTTON is
      ;; set. Escape is what the game calls this.
      ((and (= type lgame::+sdl-keydown+)
            (= (lgame.event:key-scancode event) lgame::+sdl-scancode-ac-back+))
       (%press-and-release lgame::+sdl-scancode-escape+)
       t)
      ((and (= type lgame::+sdl-keyup+)
            (= (lgame.event:key-scancode event) lgame::+sdl-scancode-ac-back+))
       t)

      (t nil))))

;;; ---------------------------------------------------------------------------
;;; The on-screen keyboard

(defun text-input (on?)
  "Raise or dismiss Android's keyboard. Called by the score screen when it starts and
   stops taking a name.

   SDL routes what is typed back as SDL_TEXTINPUT events, which carry characters rather
   than scancodes -- necessary here because there is no physical key to report and the
   IME may be anything at all."
  (if on?
      (cffi:foreign-funcall "SDL_StartTextInput" :void)
      (cffi:foreign-funcall "SDL_StopTextInput" :void)))
