(in-package #:com.thejach.descendant.spawner)

;;;; Port of origRef/GamePlay/dsc_spawner.c.
;;;;
;;;; The spawner is driven by *distance*, not time. Each tick it compares the player's
;;;; world X against the furthest column reached so far and calls SPAWN once for every
;;;; new column crossed -- so pushing forward faster produces proportionally more spawn
;;;; attempts, and idling produces none. When the player is not advancing it falls back
;;;; to SPAWN-SPECIAL, which *is* on a frame timer, so hanging back still eventually
;;;; brings trouble.
;;;;
;;;; Each attempt picks a class by weight, checks two gates, then picks an object within
;;;; that class by weight. Placement then depends on the object's orientation, with three
;;;; occupancy bands -- ceiling, centre, floor -- tracked so spawns do not overlap.
;;;;
;;;; The original uses an EdgeTree, a balanced tree over integer ranges, for the weighted
;;;; picks. A cumulative scan over a handful of entries is the same selection and far
;;;; less machinery; the tree earned its keep in C where it was shared with other systems.

(defconstant +min-y+ 4 "SPWN_ENEMY_MIN_Y / SPWN_COLLECT_MIN_Y")

(defparameter *orientations*
  '((-1 . :unknown) (0 . :ceiling) (1 . :center) (2 . :floor)
    (3 . :ceiling-free) (4 . :center-free) (5 . :floor-free))
  "SPWNOrientation. The `-free` variants skip the occupancy checks entirely.")

(defun orientation (n) (or (cdr (assoc n *orientations*)) :unknown))

(defstruct (spawnable (:constructor %make-spawnable))
  (name "" :type string)
  (sprite nil)
  (kind :no-collision :type keyword)
  (orientation :center :type keyword)
  (probability 0 :type fixnum))

(defstruct (spawn-class (:constructor %make-spawn-class))
  (name "" :type string)
  (objects '() :type list)
  (probability 0 :type fixnum)
  (start 0 :type fixnum)
  (delta 0 :type fixnum)
  (last-spawn-x 0 :type fixnum))

(defstruct (spawner (:constructor %make-spawner))
  (classes '() :type list)
  (special nil)
  (special-start 0 :type fixnum)
  (special-delta 0 :type fixnum)
  (special-last-frame 0 :type fixnum)
  ;; Level geometry
  (ceiling-y 0 :type fixnum)
  (ground-y 0 :type fixnum)
  ;; Progress
  (start-x 0 :type fixnum)
  (max-world-x 0 :type fixnum)
  (spawn-world-x 0 :type fixnum)
  ;; Occupancy bands: the rightmost world X each band is claimed to, and its extent.
  (ceiling-right -1 :type fixnum)
  (ceiling-bottom 0 :type fixnum)
  (center-right -1 :type fixnum)
  (center-top 0 :type fixnum)
  (center-bottom 0 :type fixnum)
  (floor-right -1 :type fixnum)
  (floor-top 0 :type fixnum)
  ;; (kind name x y) -> create. The level wires this to the enemy/environment pools.
  (create nil :type (or null function))
  (random-state *random-state*))

;;; ---------------------------------------------------------------------------
;;; Weighted selection

(defun total-weight (items key)
  (reduce #'+ items :key key :initial-value 0))

(defun pick-weighted (items key &optional (random-state *random-state*))
  "Choose one item with probability proportional to its weight. NIL when nothing has
   any weight, which is the `modEdge < 1` early-out."
  (let ((total (total-weight items key)))
    (when (plusp total)
      (let ((roll (random total random-state))
            (acc 0))
        (dolist (item items)
          (incf acc (funcall key item))
          (when (< roll acc)
            (return item)))))))

;;; ---------------------------------------------------------------------------
;;; Loading

(defun load-spawnable (config theme name)
  (flet ((key (suffix) (format nil "~a.~a" name suffix)))
    (let* ((sprite-name (config:config-text config (key "sprite")))
           (sprite (and sprite-name (theme:find-sprite theme sprite-name))))
      (%make-spawnable
       :name name
       :sprite sprite
       :kind (bullets:object-type (config:config-int config (key "type") 0))
       :orientation (orientation (config:config-int config (key "spawn_orient") -1))
       :probability (config:config-int config (key "spawn_prob") 0)))))

(defun load-class (config theme name)
  (flet ((key (suffix) (format nil "~a.~a" name suffix)))
    (%make-spawn-class
     :name name
     :objects (mapcar (lambda (n) (load-spawnable config theme n))
                      (config:config-list config (key "object_list")))
     :probability (config:config-int config (key "probability") 0)
     :start (config:config-int config (key "start_delta") 0)
     :delta (config:config-int config (key "spawn_delta") 0))))

(defun make-spawner (config theme &key create ceiling-y ground-y
                                       (random-state *random-state*))
  "Build from `level_data.spawn_class_list` and the special list."
  (let* ((class-names (config:config-list config "level_data.spawn_class_list"))
         (special-names (config:config-list config "level_data.spawn_special_list"))
         (s (%make-spawner
             :classes (mapcar (lambda (n) (load-class config theme n)) class-names)
             :special-start (config:config-int config "level_data.spawn_special_start" 0)
             :special-delta (config:config-int config "level_data.spawn_special_delta" 0)
             :ceiling-y (or ceiling-y (1- screen:+rows+))
             :ground-y (or ground-y 0)
             :create create
             :random-state random-state)))
    ;; The special list is a bare list of object names sharing one pseudo-class.
    (setf (spawner-special s)
          (%make-spawn-class
           :name "special"
           :objects (mapcar (lambda (n) (load-spawnable config theme n)) special-names)
           :start (spawner-special-start s)
           :delta (spawner-special-delta s)))
    (reset s 0)
    s))

(defun reset (s world-x)
  "initTheme's starting state: no band is claimed, and progress begins here."
  (setf (spawner-start-x s) world-x
        (spawner-max-world-x s) world-x
        (spawner-ceiling-bottom s) screen:+rows+
        (spawner-ceiling-right s) -1
        (spawner-center-top s) (spawner-ground-y s)
        (spawner-center-bottom s) screen:+rows+
        (spawner-center-right s) -1
        (spawner-floor-top s) (spawner-ground-y s)
        (spawner-floor-right s) -1)
  (dolist (c (spawner-classes s)) (setf (spawn-class-last-spawn-x c) 0))
  s)

;;; ---------------------------------------------------------------------------
;;; Placement
;;;
;;; Returns the Y to spawn at, or NIL to abandon this attempt. The three bands each
;;; record how far right they are claimed to, so a new object only goes down once the
;;; previous one in that band has scrolled past -- which is what stops buildings
;;; growing out of each other.

(defun %place-ceiling (s world-x width height)
  (when (> world-x (spawner-ceiling-right s))
    (when (> world-x (spawner-center-right s))
      (setf (spawner-center-top s) (spawner-ground-y s)))
    (let ((pos-y (spawner-ceiling-y s)))
      (when (> pos-y (spawner-center-top s))
        (setf (spawner-ceiling-right s) (+ world-x width 1)
              (spawner-ceiling-bottom s) (- (spawner-ceiling-y s) height))
        pos-y))))

(defun %place-center (s world-x width height)
  (when (> world-x (spawner-center-right s))
    (when (> world-x (spawner-ceiling-right s))
      (setf (spawner-ceiling-bottom s) screen:+rows+))
    (when (> world-x (spawner-floor-right s))
      (setf (spawner-floor-top s) (spawner-ground-y s)))
    (let ((delta (- (spawner-ceiling-bottom s) (spawner-floor-top s))))
      (when (> delta height)
        (decf delta height)
        (let ((pos-y (- (spawner-ceiling-bottom s)
                        (random (max 1 delta) (spawner-random-state s)))))
          (setf (spawner-center-right s) (+ world-x width 1)
                (spawner-center-top s) pos-y
                (spawner-center-bottom s) (- pos-y height))
          pos-y)))))

(defun %place-floor (s world-x width height)
  (when (> world-x (spawner-floor-right s))
    (when (> world-x (spawner-center-right s))
      (setf (spawner-center-bottom s) screen:+rows+))
    (let ((pos-y (+ (spawner-ground-y s) height)))
      (when (< pos-y (spawner-center-bottom s))
        (setf (spawner-floor-right s) (+ world-x width 1)
              (spawner-floor-top s) pos-y)
        pos-y))))

(defun place (s object world-x)
  "Y for a spawn, or NIL if the band is still occupied. The `-free` orientations ignore
   occupancy entirely and always place."
  (let* ((sprite (spawnable-sprite object))
         (width (theme:sprite-width sprite))
         (height (theme:sprite-height sprite)))
    (ecase (spawnable-orientation object)
      (:ceiling (%place-ceiling s world-x width height))
      (:center (%place-center s world-x width height))
      (:floor (%place-floor s world-x width height))
      (:ceiling-free (spawner-ceiling-y s))
      (:center-free
       (let ((delta (- (- (spawner-ceiling-y s) (spawner-ground-y s)) height)))
         (- (spawner-ceiling-y s) (random (max 1 delta) (spawner-random-state s)))))
      (:floor-free (+ (spawner-ground-y s) height))
      (:unknown nil))))

;;; ---------------------------------------------------------------------------
;;; Spawning

(defun handler-kind (kind)
  "Which subsystem owns an object type, from spawn's dispatch switch."
  (case kind
    ((:enemy-ship :enemy-boss :enemy-midboss :enemy-turret) :enemies)
    ((:building :tree :water :mountain) :environment)
    (:collectable :collectables)
    (t nil)))

;;; Spawning is driven by DISTANCE, and distance accrues per tick -- the ship covers
;;; about 6.8 world units every tick whatever the clock is doing. So running the loop at
;;; 62.5 Hz instead of the ~30 the original managed does not just make the ship look
;;; faster: it crosses the whole spawn schedule twice as fast, and meets twice as many
;;; enemies per second.
;;;
;;; Stretching both distances by the same factor the rates use puts the schedule back on
;;; the original's clock. Both numbers have to move together:
;;;
;;;   START  how far in the class begins. Scaling it keeps the level the same LENGTH in
;;;          wall time, so the boss still arrives when it used to.
;;;   DELTA  the minimum gap between two spawns of a class. Scaling it keeps the
;;;          ENCOUNTER RATE right, which is the part that felt too rapid.
;;;
;;; Scaling only one would fix half the problem and distort the other: distance alone
;;; would give the right density over a level that ends twice as soon, and gap alone
;;; would give the right rate over a level with half the content.

(defun scaled-distance (units)
  (state:scale-ticks units))

(defun spawn-ready? (s class world-x)
  "The two gates: the class must have started, and enough distance must have passed
   since it last produced something."
  (and (plusp (total-weight (spawn-class-objects class) #'spawnable-probability))
       (<= (+ (scaled-distance (spawn-class-start class)) (spawner-start-x s)) world-x)
       (<= (+ (scaled-distance (spawn-class-delta class))
              (spawn-class-last-spawn-x class))
           world-x)))

(defun spawn (s world-x)
  "One attempt at column WORLD-X. Returns the spawned object's name, or NIL."
  (let ((class (pick-weighted (spawner-classes s) #'spawn-class-probability
                              (spawner-random-state s))))
    (when (and class (spawn-ready? s class world-x))
      (let ((object (pick-weighted (spawn-class-objects class) #'spawnable-probability
                                   (spawner-random-state s))))
        (when (and object (spawnable-sprite object))
          (let ((pos-y (place s object world-x))
                (handler (handler-kind (spawnable-kind object))))
            (when (and pos-y handler (spawner-create s))
              (funcall (spawner-create s) handler (spawnable-name object)
                       (spawner-spawn-world-x s) pos-y)
              (setf (spawn-class-last-spawn-x class) world-x)
              (spawnable-name object))))))))

(defun spawn-special (s world-x frame)
  "The fallback while the player is not advancing. Unlike SPAWN this is gated on the
   frame counter rather than distance, so holding position still draws fire.

   Its placement ignores the occupancy bands -- specials are ships, not scenery."
  (let ((special (spawner-special s)))
    ;; START is a distance, DELTA is a count of FRAMES -- the one place the spawner
    ;; measures in ticks rather than ground covered. Both convert the same way.
    (when (and special
               (> world-x (scaled-distance (spawner-special-start s)))
               (> frame (+ (spawner-special-last-frame s)
                           (state:scale-ticks (spawner-special-delta s)))))
      (let ((object (pick-weighted (spawn-class-objects special) #'spawnable-probability
                                   (spawner-random-state s))))
        (when (and object (spawnable-sprite object))
          (let ((pos-y (case (spawnable-orientation object)
                         ((:ceiling :ceiling-free) (spawner-ceiling-y s))
                         ((:floor :floor-free) (+ (spawner-ground-y s)
                                                  (theme:sprite-height
                                                   (spawnable-sprite object))))
                         (t (let ((delta (- (spawner-ceiling-bottom s)
                                            (spawner-floor-top s)
                                            (theme:sprite-height
                                             (spawnable-sprite object)))))
                              (when (plusp delta)
                                (- (spawner-ceiling-bottom s)
                                   (random delta (spawner-random-state s))))))))
                (handler (handler-kind (spawnable-kind object))))
            (when (and pos-y handler (spawner-create s))
              (funcall (spawner-create s) handler (spawnable-name object)
                       (spawner-spawn-world-x s) pos-y)
              (setf (spawner-special-last-frame s) frame)
              (spawnable-name object))))))))

(defun update (s world-x frame)
  "One tick. Spawns once per world column newly crossed, or falls back to the special
   timer when the player has not advanced.

   Spawn X starts at the right screen edge and steps right with each column consumed,
   so a burst of columns in one tick fans out rather than stacking in one place."
  (setf (spawner-spawn-world-x s) screen:+cols+)
  (if (>= (spawner-max-world-x s) world-x)
      (spawn-special s world-x frame)
      (loop for x from (1+ (spawner-max-world-x s)) to world-x
            do (spawn s x)
               (incf (spawner-spawn-world-x s))))
  (setf (spawner-max-world-x s) world-x)
  s)
