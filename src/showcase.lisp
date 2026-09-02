(in-package #:com.thejach.descendant.showcase)

;;;; ADDED, not ported. The original credits are text and logos on a movie still; this
;;;; parades the cast across them.
;;;;
;;;; Each enemy flies in from the right edge, holds while it fires the shot pattern it
;;;; actually uses in the game, then leaves the same way, with its name in small type
;;;; underneath. Two lanes run half a cycle apart so the screen is never empty and never
;;;; marching in step. Nothing here scrolls with the roll.
;;;;
;;;; The enemies are the real thing: the shipped .cfg definitions, their real guns and
;;;; their real shot patterns, fired through a real projectile pool. Only the movement is
;;;; invented -- a scripted slide, in place of the movement types, which are written for
;;;; a scrolling level and would carry the enemy off the wrong edge.
;;;;
;;;; Two things need care.
;;;;
;;;; COLOUR. The renderer uploads one palette per frame, the level's own, so enemy art
;;;; put on the credits screen is painted with the credits palette. The slot indices
;;;; survive; their meanings do not, and a green floogle arrives blue. THEME:RECOLOR-THEME
;;;; retones the sprites by luminance on the way in, which keeps the shading that reads as
;;;; shape and makes them look like part of the still rather than pasted onto it.
;;;;
;;;; LIFETIME. Everything else in the game runs projectiles inside a collision world,
;;;; which is what notices a bullet leaving the screen and kills it. There is no world
;;;; here -- there is nothing to collide with -- so this file culls its own strays. Skip
;;;; that and the pool drains in about a minute and the parade goes quiet.

(defconstant +fly-in-ticks+ 34)
(defconstant +hold-ticks+ 116)
(defconstant +fly-out-ticks+ 34)
(defconstant +cycle-ticks+ (+ +fly-in-ticks+ +hold-ticks+ +fly-out-ticks+)
  "184 ticks, a shade under three seconds at 62.5 Hz -- long enough to read the name and
   watch a whole shot pattern travel.")

(defconstant +hold-x+ 150 "Where an enemy stops. Right of centre, clear of the roll's indent.")
(defconstant +label-gap+ 2 "Rows between an enemy's feet and its name.")

(defconstant +band-top+ 44
  "First row clear of the title banner, which owns rows 3 to 43.")
(defconstant +band-bottom+ 119
  "Last row a name plate may occupy.")

(defparameter *volley-ticks* '(4 42 84)
  "Ticks into the hold at which the guns fire. Several volleys read better than one: the
   first arrives as the enemy settles, the rest while it is still on screen.")

(defparameter *difficulty* 3
  "The shot patterns are difficulty-scaled. The showcase is not a fight, so it shows the
   busiest version of each pattern.")

(defparameter *lanes* '((54 0) (84 92))
  "(top-row start-delay). Both sit below the banner and clear of the copyright block; the
   delay holds the second lane back half a cycle so they do not march in step.")

(defparameter *roster*
  ;; (config theme bullet-definitions ((enemy-definition label) ...))
  '(("level_crash_site.cfg" "crash_site.thm"
     ("enemy_ship_bullet" "enemy_ship_bomb")
     (("enemy_ship_floogle"    "FLOOGLE")
      ("enemy_ship_tiefighter" "TIEFIGHTER")
      ("enemy_ship_bomber"     "BOMBER")
      ("enemy_ship_kamikaze"   "KAMIKAZE")
      ("turret_light"          "LIGHT TURRET")
      ("turret_heavy"          "HEAVY TURRET")
      ("boss_Chaser"           "CHASER")
      ("boss_Omegablaster"     "OMEGABLASTER")
      ("boss_Gear"             "GEAR")))
    ("level_hidden_cave.cfg" "hidden_cave.thm"
     ("enemy_ship_bullet" "enemy_ship_bomb" "enemy_super_bomb")
     (("enemy_ship_Cannon"     "CANNONEER")
      ("enemy_ship_spider"     "SPIDER")
      ("turret_faker"          "FAKER TURRET")
      ("midboss_HeavyWall"     "HEAVY WALL")
      ;; The worm is a section of a much longer body: in the level it arrives with its
      ;; tail still off the right edge, and parking it clear of that edge exposes a blunt
      ;; end that never reads as the end of anything.
      ("boss_doomworm"         "DOOMWORM" :flush-right)))
    ("level_brain_pain.cfg" "brain_pain.thm"
     ("enemy_ship_bullet" "enemy_ship_bomb" "enemy_flame_shot")
     (("enemy_ship_Launcher"   "LAUNCHER")
      ("enemy_ship_flamer"     "FLAMER")
      ("enemy_ship_boxorz"     "BOXORZ")
      ("enemy_ship_stealth"    "STEALTH")
      ("enemy_ship_snake"      "SNAKE")
      ("enemy_midboss_bridge"  "BRIDGE")
      ("boss_Battleship"       "BATTLESHIP")))))

;;; A roster entry, resolved: the enemy definition name, the pre-rendered name plate, and
;;; how many rows the pair needs. HEIGHT decides placement, and whether this one is big
;;; enough to want the screen to itself.
(defstruct (entry (:constructor make-entry (enemy label height &optional flush-right?)))
  (enemy "" :type string)
  (label nil)
  (height 0 :type fixnum)
  ;; Hold with the right edge against the screen edge rather than centred on +HOLD-X+.
  (flush-right? nil :type boolean))

;;; One lane. PHASE is :in, :hold, :out, or :idle when the lane is empty and waiting.
;;; TIMER counts ticks within the current turn; DELAY holds the lane back before its first.
(defstruct (slot (:constructor make-slot (row delay)))
  (row 0 :type fixnum)
  (delay 0 :type fixnum)
  (timer 0 :type fixnum)
  (entry nil)
  (enemy nil)
  (x 0 :type fixnum)
  (phase :idle :type keyword)
  (fired 0 :type fixnum))

(defclass showcase ()
  ((entries :accessor showcase-entries :initform (make-array 0 :adjustable t :fill-pointer t))
   (slots :accessor showcase-slots :initform '())
   (enemies :accessor showcase-enemies :initform nil)
   (bullets :accessor showcase-bullets :initform nil)
   (themes :accessor showcase-themes :initform '())
   ;; Round-robin cursor into ENTRIES, so every enemy gets a turn.
   (next :accessor showcase-next :initform 0)
   ;; The slot currently running an entry too big to share the screen, or NIL.
   (solo :accessor showcase-solo :initform nil)
   ;; The slot that has reserved the screen for an oversized entry and is waiting for the
   ;; other lanes to finish what they are already showing.
   (pending :accessor showcase-pending :initform nil)
   ;; An entry taller than this would reach into the neighbouring lane, so it takes the
   ;; whole screen for its turn instead. Derived from how far apart the lanes sit.
   (solo-height :accessor showcase-solo-height :initform most-positive-fixnum)))

(defun %virtual-player ()
  "Homing and cover shots aim at the player. There is no player here, so they aim at
   where one would be: left of centre, which sends the shots across the screen."
  (rect:make-rect 24 (ash screen:+rows+ -1) 9 4))

(defun make-showcase (colormap &key (font (font:read-bft (paths:font-path "dsc_font_hud_04.bft")))
                                    (attr (text:font-attr :pair 112)))
  "Load every enemy in *ROSTER*, toned into COLORMAP. FONT is the 4x6 name plate face --
   the smallest that is more than a single cell."
  (let ((self (make-instance 'showcase))
        (enemy-pool (enemies:make-pool :world nil :difficulty *difficulty*))
        (bullet-pool (bullets:make-pool :world nil)))
    (setf (enemies:pool-fire-bullet enemy-pool)
          (lambda (name direction x y) (bullets:fire bullet-pool name direction x y))
          (enemies:pool-fire-spline enemy-pool)
          (lambda (name points speed) (bullets:fire-spline bullet-pool name points speed))
          (showcase-enemies self) enemy-pool
          (showcase-bullets self) bullet-pool)

    (dolist (stage *roster*)
      (destructuring-bind (config-name theme-name bullet-names entries) stage
        (let* ((cfg (config:read-config (paths:config-path config-name)))
               (toned (theme:recolor-theme (theme:read-theme (paths:theme-path theme-name))
                                           colormap)))
          (push toned (showcase-themes self))
          (bullets:load-definitions bullet-pool cfg toned bullet-names)
          (enemies:load-definitions enemy-pool cfg toned (mapcar #'first entries)
                                    :difficulty *difficulty*)
          (dolist (spec entries)
            (destructuring-bind (enemy-name label &optional placement) spec
              (text:check-text-coverage font label :context "showcase")
              (let* ((plate (text:text-sprite font label attr))
                     (def (enemies:definition enemy-pool enemy-name))
                     (art (and def (enemies:definition-sprite def))))
                (vector-push-extend
                 (make-entry enemy-name plate
                             (+ (if art (theme:sprite-height art) 0)
                                +label-gap+ (theme:sprite-height plate))
                             (eq placement :flush-right))
                 (showcase-entries self))))))))

    (setf (showcase-slots self)
          (loop for (row offset) in *lanes* collect (make-slot row offset)))
    ;; The tightest gap between lanes is how tall an entry may be before it would reach
    ;; into its neighbour.
    (let ((rows (sort (mapcar #'first *lanes*) #'<)))
      (setf (showcase-solo-height self)
            (if (rest rows)
                (loop for (a b) on rows while b minimize (- b a))
                most-positive-fixnum)))
    ;; Each lane owns ONE pooled enemy for the whole roll, re-pointed at a new definition
    ;; every cycle. Spawning and reaping per cycle would be the natural thing, but
    ;; releasing a slot means running ENEMIES:UPDATE, and that fires every live enemy's
    ;; guns -- the parade would shoot on its own schedule as well as ours.
    (when (plusp (length (showcase-entries self)))
      (let ((seed (entry-enemy (aref (showcase-entries self) 0))))
        (dolist (s (showcase-slots self))
          (setf (slot-enemy s)
                (enemies:spawn enemy-pool seed screen:+cols+
                               (- screen:+rows+ (slot-row s)))))))
    self))

(defun %solo? (self entry)
  (> (entry-height entry) (showcase-solo-height self)))

(defun %entry-row (self slot entry)
  "The screen row an entry's art starts at. Normally its lane, but pulled up far enough
   that the name plate still lands above the bottom edge -- which for the big ones means
   well above their lane."
  (declare (ignore self))
  (min (slot-row slot) (- +band-bottom+ (entry-height entry))))

(defun %others-busy? (self slot)
  (some (lambda (other) (and (not (eq other slot)) (slot-entry other)))
        (showcase-slots self)))

(defun %advance-entry (self slot)
  "Try to give SLOT the next enemy in the roster, parked off the right edge. Returns the
   entry, or NIL if this lane has to wait. The rect is rebuilt each time because the new
   sprite is almost never the same size as the last."
  (let* ((entries (showcase-entries self))
         (n (length entries))
         (e (slot-enemy slot)))
    (when (or (zerop n) (null e)) (return-from %advance-entry nil))
    ;; While an oversized entry holds the screen -- or is queued for it -- everyone else
    ;; stays out of the way.
    (let ((holder (or (showcase-solo self) (showcase-pending self))))
      (when (and holder (not (eq holder slot)))
        (return-from %advance-entry nil)))
    (let* ((entry (aref entries (mod (showcase-next self) n)))
           (solo? (%solo? self entry)))
      ;; An oversized entry books the screen and then waits for it. Cutting the enemy
      ;; already out there short of its full turn is the obvious alternative and it looks
      ;; wrong -- a turn that ends early reads as a glitch, where a brief lull before a
      ;; boss reads as staging. The cursor is deliberately not advanced here, so the same
      ;; entry is reconsidered on the next tick.
      (when (and solo? (%others-busy? self slot))
        (setf (showcase-pending self) slot)
        (return-from %advance-entry nil))
      (let ((def (enemies:definition (showcase-enemies self) (entry-enemy entry))))
        (incf (showcase-next self))
        (unless def (return-from %advance-entry nil))
        (let ((sprite (enemies:definition-sprite def)))
          (setf (enemies:enemy-definition e) def
                (enemies:enemy-rect e)
                (rect:make-rect screen:+cols+
                                (- screen:+rows+ (%entry-row self slot entry))
                                (theme:sprite-width sprite)
                                (theme:sprite-height sprite))))
        (setf (slot-entry slot) entry
              (slot-fired slot) 0
              (showcase-pending self) nil)
        (when solo? (setf (showcase-solo self) slot))
        entry))))

(defun %retire (self slot)
  "End this enemy's turn. The pooled enemy object stays put and is reused."
  (when (eq (showcase-solo self) slot)
    (setf (showcase-solo self) nil))
  (setf (slot-entry slot) nil))

(defun %slot-width (slot)
  (let ((e (slot-enemy slot)))
    (if e (rect:rect-w (enemies:enemy-rect e)) 0)))

(defun %hold-target (slot)
  "Where this lane's enemy comes to rest."
  (let ((w (%slot-width slot))
        (entry (slot-entry slot)))
    (if (and entry (entry-flush-right? entry))
        (- screen:+cols+ w)
        (- +hold-x+ (ash w -1)))))

(defun %place (slot x)
  "Move the slot's enemy to X, keeping its rect the single source of position."
  (let ((e (slot-enemy slot)))
    (when e
      (let ((r (enemies:enemy-rect e)))
        (rect:move-ip r (- x (rect:rect-x r)) 0))))
  (setf (slot-x slot) x))

(defun %fire (self slot)
  "Fire every shot the definition owns, through the real pattern and the real guns."
  (let* ((e (slot-enemy slot))
         (shots (and e (enemies:definition-shots (enemies:enemy-definition e))))
         (player (%virtual-player)))
    (loop for kind in shots
          for i from 0
          for pattern = (enemies:shot-pattern kind *difficulty*)
          when pattern
            do (enemies:fire-spread (showcase-enemies self) e pattern i
                                    :player-rect player))))

(defun %update-slot (self slot)
  ;; Hold the lane back before its first turn, which is what staggers the two of them.
  (when (plusp (slot-delay slot))
    (decf (slot-delay slot))
    (setf (slot-phase slot) :idle)
    (return-from %update-slot nil))
  ;; An empty lane retries every tick rather than once a cycle, so a lane that has been
  ;; waiting for the screen to clear starts the moment it can.
  (when (null (slot-entry slot))
    (if (%advance-entry self slot)
        (setf (slot-timer slot) 0)
        (progn (setf (slot-phase slot) :idle)
               (return-from %update-slot nil))))
  (let* ((t* (slot-timer slot))
         (start-x screen:+cols+))
    (cond
      ;; Fly in.
      ((< t* +fly-in-ticks+)
       (setf (slot-phase slot) :in)
       (let* ((target (%hold-target slot))
              (progress (/ t* (float +fly-in-ticks+))))
         (%place slot (round (+ start-x (* progress (- target start-x)))))))
      ;; Hold and fire.
      ((< t* (+ +fly-in-ticks+ +hold-ticks+))
       (setf (slot-phase slot) :hold)
       (let ((into (- t* +fly-in-ticks+)))
         (when (and (member into *volley-ticks*) (slot-entry slot))
           (%fire self slot)
           (incf (slot-fired slot)))))
      ;; Fly out.
      (t
       (setf (slot-phase slot) :out)
       (let* ((target (%hold-target slot))
              (progress (/ (- t* +fly-in-ticks+ +hold-ticks+) (float +fly-out-ticks+))))
         (%place slot (round (+ target (* progress (- start-x target))))))))
    (setf (slot-timer slot) (mod (1+ t*) +cycle-ticks+))
    ;; Wrapping to zero ends this enemy's turn.
    (when (zerop (slot-timer slot)) (%retire self slot))))

(defun %cull-strays (self)
  "No collision world means nothing is watching for projectiles leaving the screen, so
   they would live forever and drain the pool. Kill anything well outside the frame."
  (let ((pool (showcase-bullets self))
        (margin 24))
    (dolist (p (bullets:pool-live pool))
      (let ((r (bullets:projectile-rect p)))
        (when (and r (or (< (rect:rect-x r) (- margin))
                         (> (rect:rect-x r) (+ screen:+cols+ margin))
                         (< (rect:rect-y r) (- margin))
                         (> (rect:rect-y r) (+ screen:+rows+ margin))))
          (setf (bullets:projectile-dead? p) t))))))

(defun update (self)
  (dolist (s (showcase-slots self)) (%update-slot self s))
  (bullets:update (showcase-bullets self))
  (%cull-strays self)
  t)

(defun render (self screen z)
  "Draw at layer Z. Kept below the roll so the parade passes BEHIND the logos and text
   rather than fighting them for the same rows."
  (dolist (s (showcase-slots self))
    (let ((e (slot-enemy s))
          (entry (slot-entry s)))
      (when (and e entry)
        (let* ((r (enemies:enemy-rect e))
               (sprite (enemies:definition-sprite (enemies:enemy-definition e)))
               (label (entry-label entry)))
          (screen:enqueue screen sprite (rect:rect-x r) (rect:rect-y r) z)
          (when label
            ;; Centred under the sprite. Y counts up from the bottom, so dropping below
            ;; the sprite's feet means subtracting its height and the gap.
            (screen:enqueue screen label
                            (+ (rect:rect-x r)
                               (ash (- (rect:rect-w r) (theme:sprite-width label)) -1))
                            (- (rect:rect-y r) (rect:rect-h r) +label-gap+)
                            z))))))
  (dolist (p (bullets:pool-live (showcase-bullets self)))
    (let ((r (bullets:projectile-rect p)))
      (when r
        (screen:enqueue screen
                        (bullets:definition-sprite (bullets:projectile-definition p))
                        (rect:rect-x r) (rect:rect-y r) z))))
  t)

(defun free (self)
  (bullets:clear (showcase-bullets self))
  (dolist (s (showcase-slots self)) (%retire self s))
  (setf (showcase-themes self) '()
        (showcase-slots self) '())
  t)
