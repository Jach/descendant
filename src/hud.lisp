(in-package #:com.thejach.descendant.hud)

;;;; Port of origRef/GamePlay/dsc_hud.c.
;;;;
;;;; Health and shield meters, the score, an optional FPS readout and a PAUSED banner,
;;;; all on the top render layer.
;;;;
;;;; The meters are not text -- they are small sprites whose glyphs are rewritten in
;;;; place as the values change. Each is a grid two cells wide per bar and four rows
;;;; tall, with a one-cell border: bars are drawn on every other column, inset by one
;;;; row top and bottom, which is what gives them their ticked look.

(defconstant +z-hud+ 9 "RDR_Z_TEN, above everything.")

(defconstant +shield-bars+ 20 "HUD_BARS_SHIELDS")
(defconstant +health-bars+ 35 "HUD_BARS_HEALTH")
(defconstant +stat-width+ 2 "Cells per bar, so a bar and its gap.")
(defconstant +stat-height+ 4)

;;; RDR_GLYPH_ATTR(pair, 0, char)
(defconstant +glyph-bg+ (glyph:make-glyph #x20 99) "HUD_GLYPH_BG")
(defconstant +glyph-invuln-bg+ (glyph:make-glyph #x20 90) "HUD_GLYPH_INVULN_BG")
(defconstant +glyph-on+ (glyph:make-glyph #xDB 4) "HUD_GLYPH_ON: a lit bar")
(defconstant +glyph-off+ (glyph:make-glyph #xDB 11) "HUD_GLYPH_OFF: a spent bar")

(defparameter *font-attr-pair* 112 "HUD_FONT_ATTR's colour pair")

(defstruct (hud (:constructor %make-hud))
  (health-bar nil)
  (shield-bar nil)
  (shield-label nil)
  (score-sprite nil)
  (fps-sprite nil)
  (gc-sprite nil)
  (pause-sprite nil)
  (font-4 nil)
  (font-6 nil)
  (score 0 :type fixnum)
  (health -1 :type fixnum)
  (shields -1 :type fixnum)
  (fps 0.0 :type single-float)
  (gc 0.0 :type single-float)
  (show-fps? nil :type boolean)
  (paused? nil :type boolean)
  ;; The glyph filling the UNLIT part of both meters. It turns yellow while the player is
  ;; invulnerable -- the meters themselves are the power-up's readout, which is why there
  ;; is no separate indicator for it anywhere on the HUD.
  (stat-bg +glyph-bg+ :type (unsigned-byte 32))
  (status :play :type keyword)
  ;; The shield banner: a countdown to when it disappears, and a shorter one that
  ;; toggles it on and off in the meantime to make it flash.
  (banner-sprite nil)
  (banner-visible? nil :type boolean)
  (banner-delta 0 :type fixnum)
  (banner-flash-delta 0 :type fixnum))

(defun %make-bar (name bars)
  "A meter sprite: BARS bars, two cells wide each, four rows tall, filled with the
   background glyph."
  (let* ((width (* +stat-width+ bars))
         (height +stat-height+)
         (glyphs (make-array (* width height) :element-type '(unsigned-byte 32)
                                              :initial-element +glyph-bg+)))
    (theme:make-sprite name width height glyphs)))

(defun set-bar (sprite max-value current-value)
  "Rewrite a meter in place. Bars occupy every other column, inset one row top and
   bottom -- the original starts writing at width+1 and steps by two."
  (let* ((glyphs (theme:sprite-glyphs sprite))
         (width (theme:sprite-width sprite))
         (bars (ash width -1))
         (rows (- (theme:sprite-height sprite) 2))
         (lit (if (plusp max-value)
                  (truncate (* bars (/ (float current-value) (float max-value))))
                  0))
         (index (+ width 1)))
    (dotimes (row rows sprite)
      (declare (ignore row))
      (dotimes (bar bars)
        (when (< index (length glyphs))
          (setf (aref glyphs index) (if (< bar lit) +glyph-on+ +glyph-off+)))
        (incf index +stat-width+)))))

(defun make-hud (font-4 font-6)
  (let ((h (%make-hud :font-4 font-4 :font-6 font-6)))
    (setf (hud-health-bar h) (%make-bar "HUD Health" +health-bars+)
          (hud-shield-bar h) (%make-bar "HUD Shields" +shield-bars+))
    (let ((attr (text:font-attr :pair *font-attr-pair*
                                :mod glyph:+mod-transparent-bg+)))
      (setf (hud-shield-label h) (text:text-sprite font-4 "SHIELD:" attr)
            (hud-pause-sprite h) (text:text-sprite font-4 "PAUSED" attr)))
    (set-banner h 100)
    (set-score h 0)
    (set-fps h 0.0)
    h))

;;; ---------------------------------------------------------------------------
;;; The shield banner
;;;
;;; Every time the shield count changes, a message flashes across the middle of the
;;; screen for HUD_SHIELD_DELTA ticks, blinking every HUD_SHIELD_FLASH_DELTA. It is the
;;; only thing on the HUD that demands attention, which is the point -- losing a shield
;;; is the only truly irreversible thing that happens to you.
;;;
;;; The original builds the sprite once as "<< SHIELDS AT 100% >>" and then overwrites
;;; just the three characters at offset 14 with the new percentage, so the number is
;;; always three wide and a drop to 90 reads as "090". We rebuild the whole string, which
;;; is the same text and avoids depending on an in-place font write.

(defconstant +banner-flash-delta+ 5 "HUD_SHIELD_FLASH_DELTA: ticks per blink.")
(defconstant +banner-delta+ (* +banner-flash-delta+ 21)
  "HUD_SHIELD_DELTA: how long the banner stays up. Twenty-one blinks.")

(defun set-banner (h percent)
  (setf (hud-banner-sprite h)
        (text:text-sprite (hud-font-6 h)
                          (format nil "<< SHIELDS AT ~3,'0d% >>" percent)
                          (text:font-attr :pair *font-attr-pair*
                                          :mod glyph:+mod-transparent-bg+)))
  h)

(defun flash-shields (h shields max-shields)
  "Raise the banner for a shield change."
  (set-banner h (if (plusp max-shields)
                    (truncate (* 100 shields) max-shields)
                    0))
  (setf (hud-banner-visible? h) t
        (hud-banner-flash-delta h) +banner-flash-delta+
        (hud-banner-delta h) +banner-delta+)
  h)

(defun %tick-banner (h)
  (when (plusp (hud-banner-delta h))
    (decf (hud-banner-delta h))
    (decf (hud-banner-flash-delta h))
    (cond
      ((<= (hud-banner-delta h) 0) (setf (hud-banner-visible? h) nil))
      ((<= (hud-banner-flash-delta h) 0)
       (setf (hud-banner-visible? h) (not (hud-banner-visible? h))
             (hud-banner-flash-delta h) +banner-flash-delta+))))
  h)

(defun set-score (h score)
  "SCORE:00000000: -- eight zero-padded digits, redrawn only when it changes."
  (setf (hud-score h) score
        (hud-score-sprite h)
        (text:text-sprite (hud-font-4 h) (format nil "SCORE:~8,'0d:" score)
                          (text:font-attr :pair *font-attr-pair*
                                          :mod glyph:+mod-transparent-bg+)))
  h)

(defun set-fps (h fps)
  "FPS:0000.00: -- only built when the readout is enabled."
  (setf (hud-fps h) (float fps 1.0)
        (hud-fps-sprite h)
        (text:text-sprite (hud-font-4 h) (format nil "FPS:~7,2,,,'0f:" fps)
                          (text:font-attr :pair *font-attr-pair*
                                          :mod glyph:+mod-transparent-bg+)))
  h)

(defun gc-milliseconds ()
  "Total time this image has spent collecting, in milliseconds.

   SB-EXT:*GC-REAL-TIME* counts internal time units since the image started and only ever
   goes up, so the number itself says little -- what it is for is watching how fast it
   climbs, and whether it jumps at a moment that felt like a hitch. A fixed-step loop
   hides small pauses by catching up afterwards, which makes them easy to miss by eye and
   worth having a number for.

   The only implementation-specific thing in the whole game, so it is guarded rather than
   assumed. A reading of zero elsewhere is honest: the readout is a diagnostic whose
   absolute value already means nothing, and an implementation that cannot answer should
   say so by staying flat rather than by refusing to compile."
  #+sbcl
  (/ (float sb-ext:*gc-real-time* 1.0d0)
     (/ internal-time-units-per-second 1000))
  #-sbcl 0.0)

(defun set-gc (h milliseconds)
  "GC:00000.0: -- sits above the FPS readout and shares its switch."
  (setf (hud-gc h) (float milliseconds 1.0)
        (hud-gc-sprite h)
        (text:text-sprite (hud-font-4 h) (format nil "GC:~8,1,,,'0f:" milliseconds)
                          (text:font-attr :pair *font-attr-pair*
                                          :mod glyph:+mod-transparent-bg+)))
  h)

(defun %fill-bar (sprite glyph)
  "initStatusBar: repaint a whole meter with the background glyph. The lit bars are
   written back over it by the next SET-BAR."
  (fill (theme:sprite-glyphs sprite) glyph)
  sprite)

(defun set-status (h status)
  "Recolour the meters when the player's state changes.

   Only two of the states say anything: :INVULNERABLE repaints both meters, and :PLAY
   repaints them back. Everything else leaves them alone, which is why dying does not
   reset a still-running power-up's colour.

   The asymmetry between the two branches is the effect, and it is easy to miss. Both
   repaint, which wipes the lit bars -- but only :PLAY clears the cached health and
   shields. So coming back to :PLAY forces UPDATE to redraw the bars immediately, while
   going INVULNERABLE does not: the meters are left SOLID YELLOW, with no bars at all,
   until the next time health or shields actually changes. That blanking is what the
   power-up looks like, not a yellow tint behind the bars."
  (unless (eq status (hud-status h))
    (setf (hud-status h) status)
    (case status
      (:invulnerable
       (setf (hud-stat-bg h) +glyph-invuln-bg+)
       (%fill-bar (hud-health-bar h) +glyph-invuln-bg+)
       (%fill-bar (hud-shield-bar h) +glyph-invuln-bg+))
      (:play
       (setf (hud-stat-bg h) +glyph-bg+)
       (%fill-bar (hud-health-bar h) +glyph-bg+)
       (%fill-bar (hud-shield-bar h) +glyph-bg+)
       ;; `d_shields = 0; d_health = 0;` -- the original uses 0 rather than a sentinel,
       ;; which is fine because a player at zero of either is already dying.
       (setf (hud-health h) 0 (hud-shields h) 0))))
  h)

(defun update (h &key score health max-health shields max-shields fps status)
  "Refresh only what changed. The original compares each value against a cached copy
   before rebuilding its sprite, which matters because rebuilding a text sprite
   re-rasterises every cell."
  ;; The banner's countdown runs first and unconditionally, before anything can raise it
  ;; again this tick -- otherwise a shield change would immediately eat one of its ticks.
  (%tick-banner h)
  ;; Before the bars, so a state change repaints the background and the bars go on top.
  (let ((was-invulnerable? (eq (hud-status h) :invulnerable)))
    (when status (set-status h status))
    (when (and score (/= score (hud-score h)))
      (set-score h score))
    (when (and health (/= health (hud-health h)))
      (setf (hud-health h) health)
      (set-bar (hud-health-bar h) (or max-health 1) health))
    (when (and shields (/= shields (hud-shields h)))
      ;; Suppressed while invulnerable -- and the original tests the PREVIOUS status, so
      ;; the tick the power-up lapses on is still quiet.
      (unless was-invulnerable?
        (flash-shields h shields (or max-shields 1)))
      (setf (hud-shields h) shields)
      (set-bar (hud-shield-bar h) (or max-shields 1) shields)))
  (when (and fps (hud-show-fps? h) (> (abs (- fps (hud-fps h))) 0.01))
    (set-fps h fps))
  ;; Tenths, so a collection too small to move the display costs nothing to ignore.
  (when (hud-show-fps? h)
    (let ((ms (gc-milliseconds)))
      (when (> (abs (- ms (hud-gc h))) 0.05)
        (set-gc h ms))))
  h)

(defun render (h screen)
  "Positions from HUD_initTheme. Y counts up from the bottom, so the meters' Y of
   rows-3 and the score's rows-2 both put them near the TOP of the screen: meters and
   shield label upper-right, score upper-left, FPS below the meters, PAUSED centred."
  (let* ((shields (hud-shield-bar h))
         (health (hud-health-bar h))
         (label (hud-shield-label h))
         (score (hud-score-sprite h)))
    (screen:enqueue screen shields
                    (- screen:+cols+ (+ (theme:sprite-width shields) 2))
                    (- screen:+rows+ 3) +z-hud+)
    (screen:enqueue screen health
                    (- screen:+cols+ (+ (theme:sprite-width health) 2))
                    (- screen:+rows+ (+ (theme:sprite-height health) 5)) +z-hud+)
    (screen:enqueue screen label
                    (- screen:+cols+ (+ (theme:sprite-width shields)
                                        (theme:sprite-width label) 3))
                    (- screen:+rows+ 2) +z-hud+)
    (screen:enqueue screen score 2 (- screen:+rows+ 2) +z-hud+)
    (when (and (hud-show-fps? h) (hud-fps-sprite h))
      (let ((fps (hud-fps-sprite h)))
        (screen:enqueue screen fps
                        (- screen:+cols+ (+ (theme:sprite-width fps) 2))
                        (+ (theme:sprite-height fps) 2) +z-hud+)))
    ;; Directly above the FPS line, sharing its switch. Y counts up, so "above" is a
    ;; larger Y by one line plus a row of air.
    (when (and (hud-show-fps? h) (hud-gc-sprite h))
      (let ((gc (hud-gc-sprite h)))
        (screen:enqueue screen gc
                        (- screen:+cols+ (+ (theme:sprite-width gc) 2))
                        (+ (* 2 (theme:sprite-height gc)) 3) +z-hud+)))
    (when (and (hud-banner-visible? h) (hud-banner-sprite h))
      ;; X = (cols - width) >> 1, Y = rows - ((rows - height) >> 1): centred across, and
      ;; a little above the middle once the Y-up convention is unwound.
      (let ((b (hud-banner-sprite h)))
        (screen:enqueue screen b
                        (ash (- screen:+cols+ (theme:sprite-width b)) -1)
                        (- screen:+rows+
                           (ash (- screen:+rows+ (theme:sprite-height b)) -1))
                        +z-hud+)))
    (when (hud-paused? h)
      (let ((p (hud-pause-sprite h)))
        (screen:enqueue screen p
                        (- (truncate screen:+cols+ 2)
                           (truncate (theme:sprite-width p) 2))
                        (truncate screen:+rows+ 2) +z-hud+))))
  h)

(defun toggle-pause (h)
  "HUD_togglePause. A toggle rather than a flag threaded through UPDATE, because UPDATE
   does not run while the level is paused -- the original returns from updateFrame before
   the scene is ticked. A flag would therefore only ever be set, never cleared, and the
   banner would survive un-pausing."
  (setf (hud-paused? h) (not (hud-paused? h)))
  h)

(defun toggle-fps (h)
  (setf (hud-show-fps? h) (not (hud-show-fps? h)))
  (when (hud-show-fps? h)
    (when (null (hud-fps-sprite h)) (set-fps h (hud-fps h)))
    (when (null (hud-gc-sprite h)) (set-gc h (gc-milliseconds))))
  h)
