(in-package #:com.thejach.descendant.enemies)

;;;; Port of origRef/GamePlay/dsc_enemies.c -- first slice.
;;;;
;;;; IN THIS SLICE: enemy definitions loaded from config, the instance pool, the core
;;;; movement behaviours, damage and death scoring.
;;;;
;;;; DEFERRED to a later slice, and deliberately so -- they are self-contained and this
;;;; file is already the largest in GamePlay/ at 2,176 lines:
;;;;   * firing: the gun table, the shot-type dispatch and the seven bullet patterns
;;;;   * the spline-driven and exotic movements (box, hourglass, zag, infinity, curvey,
;;;;     upcircle, divebomb, msattack, DOOM, bounce)
;;;;   * boss and midboss sequencing
;;;; MOVEMENT-FN returns NIL for those, and instances fall back to :straight, so an
;;;; unported movement flies harmlessly rather than erroring.
;;;;
;;;; Movement is per-tick and integer, not physics: each behaviour nudges the enemy by
;;;; a step derived from the player's *acceleration*, which is the game's proxy for how
;;;; fast the world is scrolling. Faster the player pushes right, faster enemies sweep
;;;; left past them.

(defconstant +z-enemy+ 7 "RDR_Z_EIGHT, the same layer as the player.")
(defconstant +max-enemies+ 50 "MAX_ENEMIES_BASE")

;;; Movement_Types. Anything >= 20 is a turret: addEnemy retypes those colliders to
;;; ENEMY_TURRET regardless of what the config's `type` said.
(defparameter *movement-types*
  '((1 . :infinity) (2 . :up-down) (3 . :side-side) (4 . :curvey) (5 . :doom)
    (10 . :pursue) (11 . :follow) (12 . :straight) (13 . :suicide)
    (14 . :box) (15 . :hourglass) (16 . :zag) (17 . :msattack)
    (18 . :divebomb) (19 . :upcircle)
    (20 . :non-move) (21 . :bounce)))

(defconstant +turret-movement-threshold+ 20
  "movement[0] > 19 makes the enemy a turret. Note the original tests > 19 rather than
   >= 20, which is the same thing for integers but is how the source reads.")

(defparameter *shot-types*
  '((1 . :straight) (2 . :cover) (3 . :bomber) (4 . :boss) (5 . :lazer)
    (6 . :lturret) (7 . :hturret) (8 . :chaser) (9 . :flame) (10 . :launcher)
    (11 . :upcurve) (12 . :circle) (13 . :homing) (14 . :cannon) (15 . :omega-blast)))

(defun movement-type (n) (cdr (assoc n *movement-types*)))
(defun shot-type (n) (cdr (assoc n *shot-types*)))

(defstruct (gun (:constructor make-gun (x-fraction y-fraction shots)))
  "A firing point as a fraction of the sprite's extent, plus which shot indices use it.
   Config form: `0.300,0.800,1 - 0.250,0.750,1,2`."
  (x-fraction 0.0 :type single-float)
  (y-fraction 0.0 :type single-float)
  (shots '() :type list))

(defstruct (definition (:constructor %make-definition))
  (name "" :type string)
  (sprite nil)
  (kind :enemy-ship :type keyword)
  (acceleration 0.0 :type single-float)
  (homing 0.0 :type single-float)
  (health 1 :type fixnum)
  (movements '() :type list)
  (shots '() :type list)
  (guns '() :type list)
  (spawn-probability 0 :type fixnum)
  (spawn-orientation 0 :type fixnum))

(defstruct (enemy (:constructor %make-enemy))
  (definition nil)
  (rect nil :type (or null rect:rect))
  (collider nil)
  (health 1 :type fixnum)
  (movement :straight :type keyword)
  (movement-timer 0 :type fixnum)
  ;; The path currently being flown, or NIL. Ten of the seventeen movements are one-shot
  ;; spline builders; see the commentary above *SPLINE-PATHS*.
  (spline nil)
  (shoot-timers (make-array 10 :initial-element 0) :type simple-vector)
  (frame 0 :type fixnum)
  ;; Carried fractions of movement; see the commentary above %MOVE-AT-RATE.
  (move-debt-x 0.0 :type single-float)
  (move-debt-y 0.0 :type single-float)
  (dead? nil :type boolean))

(defstruct (pool (:constructor %make-pool))
  (definitions (make-hash-table :test #'equal) :type hash-table)
  (live '() :type list)
  (free '() :type list)
  (world nil)
  ;; D_enemies.worldX: how far the level has scrolled. Stationary turrets subtract this
  ;; each tick, which is what makes them hold position in world space while the view moves.
  ;; D_enemies.worldX: the player's world position as of the END of the last update, and
  ;; the difference against this one. Only turrets use it, but they use it every frame.
  (world-x 0 :type fixnum)
  (scroll-delta 0 :type fixnum)
  ;; The player's horizontal acceleration this tick. Only PursueMovement reads it, but
  ;; it reads it every frame and the behaviour is meaningless without it.
  (player-accel-x 0.0 :type single-float)
  ;; Kept current by the level each tick, so collision callbacks can consult it without
  ;; reaching for a global player.
  (player-status :play :type keyword)
  (difficulty 4 :type fixnum)
  (on-death nil :type (or null function))
  ;; (name angle x y) -> spawn a projectile. Wired to the bullet pool by the level.
  (fire-bullet nil :type (or null function))
  ;; createSplineObject, for the seven spline-driven shot types.
  (fire-spline nil :type (or null function))
  ;; The boss gate; see the commentary above SPAWN-ALLOWED?.
  (midboss-count 0 :type fixnum)
  (midboss-deaths 0 :type fixnum)
  (on-boss-defeated nil :type (or null function))
  ;; g_particle_emitter.spew, called from Enemy_Ship_Hit. Takes (x y type).
  (emit nil :type (or null function))
  ;; The three the original registers: enemy_death, enemy_fire, enemy_bomb.
  (sound-death nil)
  (sound-fire nil)
  (sound-bomb nil))

;;; ---------------------------------------------------------------------------
;;; Loading

(defun parse-int-list (text)
  (when text
    (remove nil (mapcar (lambda (s) (parse-integer s :junk-allowed t))
                        (split-on text #\,)))))

(defun split-on (text char)
  (let ((parts '()) (start 0))
    (dotimes (i (length text))
      (when (char= (char text i) char)
        (push (subseq text start i) parts)
        (setf start (1+ i))))
    (push (subseq text start) parts)
    (mapcar (lambda (s) (string-trim '(#\Space #\Tab) s)) (nreverse parts))))

(defun parse-guns (text)
  "`0.250,0.250,1,2 - 0.350,0.100,2` -> a list of guns. The first two numbers are
   fractions of the sprite's width and height; the rest are 1-based shot indices,
   stored zero-based."
  (when (and text (plusp (length text)))
    (remove nil
            (mapcar (lambda (group)
                      (let ((fields (parse-float-list group)))
                        (when (>= (length fields) 3)
                          (make-gun (float (first fields) 1.0)
                                    (float (second fields) 1.0)
                                    (mapcar (lambda (n) (1- (truncate n)))
                                            (cddr fields))))))
                    (split-on text #\-)))))

(defun parse-float-list (text)
  (remove nil (mapcar (lambda (s)
                        (let ((n (com.thejach.descendant.config::%parse-leading-float s)))
                          (and n (float n 1.0))))
                      (split-on text #\,))))

(defun load-definition (pool config theme name difficulty)
  "One `[enemy_*]` section. Health scales with difficulty exactly as addEnemy does."
  (flet ((key (suffix) (format nil "~a.~a" name suffix)))
    (let* ((sprite-name (config:config-text config (key "sprite")))
           (sprite (and sprite-name (theme:find-sprite theme sprite-name)))
           (movements (mapcar #'movement-type
                              (parse-int-list (config:config-text config (key "movement")))))
           (kind (bullets:object-type (config:config-int config (key "type") 4))))
      (cond
        ((null sprite)
         (warn "Enemies: no sprite ~s for ~s, skipping." sprite-name name)
         nil)
        (t
         ;; A leading movement of 20 or above makes this a turret whatever `type` said.
         (let ((first-movement (config:config-int config (key "movement") 0)))
           (when (> first-movement (1- +turret-movement-threshold+))
             (setf kind :enemy-turret)))
         (setf (gethash name (pool-definitions pool))
               (%make-definition
                :name name
                :sprite sprite
                :kind kind
                :acceleration (config:config-float config (key "acceleration") 0.0)
                :homing (config:config-float config (key "homing") 0.0)
                :health (+ (config:config-int config (key "health") 1) (* difficulty 3))
                :movements (or (remove nil movements) '(:straight))
                :shots (remove nil (mapcar #'shot-type
                                           (parse-int-list
                                            (config:config-text config (key "shot")))))
                :guns (parse-guns (config:config-text config (key "guns")))
                :spawn-probability (config:config-int config (key "spawn_prob") 0)
                :spawn-orientation (config:config-int config (key "spawn_orient") 0))))))))

(defun load-definitions (pool config theme names &key (difficulty 4))
  (dolist (name names pool)
    (load-definition pool config theme name difficulty)))

(defun definition (pool name) (gethash name (pool-definitions pool)))

(defun make-pool (&key world (max +max-enemies+) on-death (difficulty 4))
  (let ((p (%make-pool :world world :on-death on-death :difficulty difficulty)))
    (setf (pool-free p) (loop repeat max collect (%make-enemy)))
    p))

(defun live-count (pool) (length (pool-live pool)))

;;; ---------------------------------------------------------------------------
;;; Movement

(defun scroll-step (player-accel-x)
  "SMove: 1 by default, scaled up while the player accelerates hard to the right. This
   is how enemies appear to sweep past faster when the level is scrolling faster."
  (if (> player-accel-x 10)
      (max 1 (truncate player-accel-x 10))
      1))

(defun %move (pool enemy dx dy)
  (let ((r (enemy-rect enemy)))
    (if (and (pool-world pool) (enemy-collider enemy))
        (collision:move (pool-world pool) (enemy-collider enemy) dx dy)
        (rect:move-ip r dx dy))))

;;; Enemy movement is counted in whole cells PER TICK -- `d_rdr.d_X -= SMove` and so on.
;;; Like everything else the original counts in ticks, that makes it a function of the
;;; frame rate: a kamikaze crossing the screen at two cells a tick takes four seconds at
;;; the ~30 Hz the original managed and two at our 62.5, halving the time you have to
;;; shoot it before it reaches you.
;;;
;;; Dividing by RATE-SCALE puts the crossing time back. Cells are integers, so the
;;; remainder is carried per enemy rather than rounded -- rounding down would freeze
;;; anything moving one cell a tick, which is most of them.
;;;
;;; Two movements deliberately do NOT go through this:
;;;
;;;   :NON-MOVE  turrets track the world, and the world's scroll is already measured in
;;;              distance travelled rather than ticks. Scaling them would slide them
;;;              against the scenery they are standing on.
;;;   splines    driven by a delta-t per tick rather than a step, so they are corrected
;;;              by scaling that instead -- see BUILD-SPLINE.

(defun %move-at-rate (pool enemy dx dy)
  "%MOVE, but at the original's wall-clock speed rather than its tick speed."
  (let ((scale (/ 1.0 (float (state:rate-scale) 1.0))))
    (incf (enemy-move-debt-x enemy) (* dx scale))
    (incf (enemy-move-debt-y enemy) (* dy scale))
    ;; TRUNCATE rather than FLOOR: debts can be negative, and rounding toward zero keeps
    ;; a leftward and a rightward step symmetrical.
    (multiple-value-bind (whole-x rest-x) (truncate (enemy-move-debt-x enemy))
      (multiple-value-bind (whole-y rest-y) (truncate (enemy-move-debt-y enemy))
        (setf (enemy-move-debt-x enemy) (float rest-x 1.0)
              (enemy-move-debt-y enemy) (float rest-y 1.0))
        (when (or (/= 0 whole-x) (/= 0 whole-y))
          (%move pool enemy whole-x whole-y))))))

(defun advance-movement (pool enemy)
  "RandomizeMovment: step to the next movement in the definition's list, wrapping."
  (let* ((movements (definition-movements (enemy-definition enemy)))
         (i (position (enemy-movement enemy) movements))
         (next (if (and i (< (1+ i) (length movements)))
                   (nth (1+ i) movements)
                   (first movements))))
    (setf (enemy-movement enemy) next
          (enemy-movement-timer enemy) 0))
  enemy)

(defun move-straight (pool enemy step &key player-rect)
  (declare (ignore player-rect))
  (%move-at-rate pool enemy (* -2 step) 0))

(defun move-follow (pool enemy step &key player-rect)
  "Closes to a band around the player and then holds station, drifting left."
  (let* ((r (enemy-rect enemy))
         (dx (- (rect:rect-x r) (rect:rect-x player-rect)))
         (dy (- (rect:rect-y r) (rect:rect-y player-rect))))
    (cond
      ((and (< dx 80) (> dy 30) (> dx -10)) (%move-at-rate pool enemy (- step) 0))
      ((and (< dx 80) (> dx -10)) (%move-at-rate pool enemy (- step) 1))
      ((> dy 9) (%move-at-rate pool enemy (- step) -1))
      ((< dy -9) (%move-at-rate pool enemy (- step) 1))
      (t (%move-at-rate pool enemy (- step) 0)))))

(defun move-suicide (pool enemy step &key player-rect)
  "Drives left while tracking the player's row tightly."
  (let* ((r (enemy-rect enemy))
         (dy (- (rect:rect-y r) (rect:rect-y player-rect))))
    (cond
      ((> dy 3) (%move-at-rate pool enemy (- step) -1))
      ((< dy -3) (%move-at-rate pool enemy (- step) 1))
      (t (%move-at-rate pool enemy (- step) 0)))))

(defun move-side-side (pool enemy step &key player-rect)
  (declare (ignore player-rect))
  (cond
    ((<= (enemy-movement-timer enemy) 200) (%move-at-rate pool enemy (- step) 0))
    ((< (rect:rect-x (enemy-rect enemy)) 180) (%move-at-rate pool enemy step 0))
    (t (advance-movement pool enemy))))

(defun move-up-down (pool enemy step &key player-rect)
  (declare (ignore player-rect))
  ;; Drift in from the right edge first, then oscillate.
  (when (> (rect:rect-x (enemy-rect enemy)) 210)
    (%move-at-rate pool enemy (- step) 0))
  (let ((timer (enemy-movement-timer enemy)))
    (cond
      ((< timer 10) (%move-at-rate pool enemy 0 step))
      ((< timer 20) (%move-at-rate pool enemy 0 (- step)))
      (t (advance-movement pool enemy)))))

(defconstant +pursue-floor+ -90
  "How far behind the player a pursuer will fall back to, and no further. Also the x the
   chaser is created at, so it starts exactly at its own limit.")

(defun move-pursue (pool enemy step &key player-rect)
  "Closes only while the player is DECELERATING; otherwise falls back to its floor.

   The acceleration test is the whole behaviour and it is easy to drop: without it the
   thing simply chases, which is a different and much worse enemy. With it, flying
   forward leaves it parked off the left edge out of sight, and reversing is what brings
   it in -- see the commentary on *CHASER-NAME*."
  (declare (ignore step))
  (let ((r (enemy-rect enemy)))
    (if (and (minusp (pool-player-accel-x pool))
             (< (rect:rect-x r) (+ (rect:rect-x player-rect) 10)))
        (%move-at-rate pool enemy 1 0)
        (when (> (rect:rect-x r) +pursue-floor+)
          (%move-at-rate pool enemy -1 0)))))

(defun move-non-move (pool enemy step &key player-rect)
  "Turrets sit still in WORLD space, so in screen space they slide left by exactly the
   distance the player advanced this frame.

   The original computes `deltaya = playerWorldX - D_enemies.worldX` -- the distance
   since the last tick, not the absolute position -- and stores the new value at the end
   of update. POOL-SCROLL-DELTA is that difference."
  (declare (ignore step player-rect))
  (%move pool enemy (- (pool-scroll-delta pool)) 0))

;;; ---------------------------------------------------------------------------
;;; Spline movements
;;;
;;; Ten of the seventeen movements are not per-frame movers at all. Each is a one-shot
;;; builder: it grabs a spline, loads a fixed knot list, and replaces the enemy's
;;; movement function with SplineMovement, which from then on just asks the spline where
;;; to be next. So the exotic paths are data, and the code below is the data plus one
;;; interpreter.
;;;
;;; Two of them -- MSATTACK and DIVEBOMB -- read the player's position when they build,
;;; so the run they fly is aimed at wherever the ship was at that instant and does not
;;; track it afterwards. That is what makes a divebomb feel committed: it is a swoop at
;;; where you were, and sidestepping it works.
;;;
;;; Knot coordinates are absolute screen cells, which is why most of these paths only
;;; make sense on the right-hand side of the screen: the enemy is yanked to the first
;;; knot rather than easing into it.

(defstruct (path (:constructor make-path (dt knots)))
  "DT is the spline's step per frame, so smaller is slower and smoother. KNOTS is a
   function of (enemy player-rect) returning the control points."
  (dt 0.025 :type single-float)
  (knots nil :type function))

(defmacro define-path (dt &body knot-forms)
  "Knot forms are evaluated with X and Y bound to the enemy's current cell, and PX and PY
   to the player's. The first knot is always the enemy's own position -- every one of
   these paths starts with it, so it is implied rather than repeated."
  `(make-path ,dt
              (lambda (enemy player-rect)
                (declare (ignorable player-rect))
                (let* ((r (enemy-rect enemy))
                       (x (float (rect:rect-x r) 1.0))
                       (y (float (rect:rect-y r) 1.0))
                       (px (float (rect:rect-x player-rect) 1.0))
                       (py (float (rect:rect-y player-rect) 1.0)))
                  (declare (ignorable x y px py))
                  (list* (cons x y) (list ,@knot-forms))))))

(defparameter *spline-paths*
  (list
   :box (define-path 0.02
          (cons 180.0 40.0) (cons 120.0 40.0) (cons 120.0 90.0) (cons 180.0 90.0))
   :infinity (define-path 0.025
               (cons 180.0 70.0) (cons 140.0 40.0) (cons 100.0 70.0)
               (cons 140.0 100.0) (cons 160.0 85.0))
   ;; The last knot repeats the middle one, which is what pinches the waist.
   :hourglass (define-path 0.025
                (cons 190.0 40.0) (cons 130.0 40.0) (cons 160.0 70.0)
                (cons 190.0 100.0) (cons 130.0 100.0) (cons 160.0 70.0))
   :zag (define-path 0.025
          (cons 160.0 20.0) (cons 150.0 40.0) (cons 160.0 60.0) (cons 150.0 80.0)
          (cons 160.0 100.0) (cons 150.0 100.0) (cons 160.0 80.0) (cons 150.0 60.0)
          (cons 160.0 30.0))
   ;; Aimed at the player at build time: a feint past, a pass through, and a peel away.
   :msattack (define-path 0.035
               (cons (- x 20.0) y)
               (cons (+ px 80.0) (+ py 10.0))
               (cons (- px 5.0) py)
               (cons (+ px 60.0) (- py 10.0))
               (cons 140.0 70.0) (cons 150.0 80.0) (cons 140.0 90.0))
   :divebomb (define-path 0.035
               (cons (- x 50.0) y)
               (cons (+ px 80.0) (+ py 10.0))
               (cons (+ px 20.0) (+ py 10.0))
               (cons (+ px 20.0) (- py 10.0))
               (cons (+ px 55.0) (- py 5.0))
               (cons (+ px 80.0) (+ py 5.0)))
   ;; Relative to wherever the enemy is: a shallow S drifting 120 cells left.
   :curvey (define-path 0.035
             (cons (- x 30.0) (+ y 10.0))
             (cons (- x 60.0) y)
             (cons (- x 90.0) (- y 10.0))
             (cons (- x 120.0) y))
   :upcircle (define-path 0.02
               (cons 120.0 87.0) (cons 100.0 95.0) (cons 120.0 115.0) (cons 160.0 110.0))
   ;; dt of 0.25 is ten times the others, so this is a hop rather than a glide -- the
   ;; whole arc is over in a handful of frames, and then it rebuilds and hops again.
   :bounce (define-path 0.25
             (cons (- x 6.0) (+ y 15.0))
             (cons (- x 12.0) (+ y 30.0))
             (cons (- x 18.0) (+ y 15.0))
             (cons (- x 24.0) y))
   ;; The slowest of the lot at 0.01, and a tiny loop: it lurks near the ceiling.
   :doom (define-path 0.01
           (cons 175.0 110.0) (cons 165.0 105.0) (cons 165.0 100.0) (cons 175.0 105.0)))
  "Movement kind -> the path it flies. Order and values are straight from the C.")

(defconstant +spline-restart-limit+ 500
  "Frames on one spline before the movement list advances.")

(defun path-for (kind) (getf *spline-paths* kind))

(defun build-spline (enemy player-rect)
  "Install the path for the enemy's current movement. Called on the frame a spline
   movement becomes current, and again each time a path runs out -- which is what makes
   these loop, and why a path built from the enemy's own position drifts a little
   further each lap."
  (let ((path (path-for (enemy-movement enemy))))
    (when path
      ;; A spline advances by DT per tick rather than by a step in cells, so it is
      ;; corrected by slowing the parameter rather than by %MOVE-AT-RATE -- and it comes
      ;; out smoother for it, since the path is simply sampled more finely.
      (let ((spline (make-instance 'spline:spline
                                   :dt (/ (path-dt path)
                                          (float (state:rate-scale) 1.0)))))
        (dolist (knot (funcall (path-knots path) enemy player-rect))
          (spline:add-knot spline (vector (car knot) (cdr knot))))
        (setf (enemy-spline enemy) spline)))))

(defun move-spline-setup (pool enemy step &key player-rect)
  "The builder half. The original swaps in a different function pointer here; we just
   attach the spline, and the dispatcher prefers a spline when one is attached."
  (declare (ignore pool step))
  (build-spline enemy player-rect))

(defun advance-spline (pool enemy &key player-rect)
  "SplineMovement. Ask the path where to be and go there.

   Faithful quirk in the restart: when the timer runs out the original calls
   RandomizeMovment -- which picks the next movement AND installs its function -- and
   then immediately clobbers that function back to SplineMovement. The new movement
   therefore does not take effect until the CURRENT path runs out, however long that is.
   We get the same behaviour for free by preferring an attached spline over the movement
   kind, so the changeover is deferred in exactly the same way."
  (multiple-value-bind (point done?) (spline:next-point (enemy-spline enemy))
    (if done?
        ;; Exhausted: drop it, and the dispatcher rebuilds from here next frame.
        (setf (enemy-spline enemy) nil)
        (let ((r (enemy-rect enemy)))
          (%move pool enemy
                 (- (truncate (aref point 0)) (rect:rect-x r))
                 (- (truncate (aref point 1)) (rect:rect-y r))))))
  (when (> (enemy-movement-timer enemy) +spline-restart-limit+)
    (advance-movement pool enemy))
  enemy)

(defparameter *movement-functions*
  (list :straight #'move-straight
        :follow #'move-follow
        :suicide #'move-suicide
        :side-side #'move-side-side
        :up-down #'move-up-down
        :pursue #'move-pursue
        :non-move #'move-non-move
        :box #'move-spline-setup
        :infinity #'move-spline-setup
        :hourglass #'move-spline-setup
        :zag #'move-spline-setup
        :msattack #'move-spline-setup
        :divebomb #'move-spline-setup
        :curvey #'move-spline-setup
        :upcircle #'move-spline-setup
        :bounce #'move-spline-setup
        :doom #'move-spline-setup))

(defun movement-fn (kind)
  "NIL for a movement with no implementation; callers fall back to :straight."
  (getf *movement-functions* kind))

;;; ---------------------------------------------------------------------------
;;; Spawning and damage

;;; The boss gate.
;;;
;;; This is the whole of the level's pacing, and it is three counters.
;;;
;;; A level admits at most +max-midboss-instances+ midbosses, ever. The boss is refused
;;; until exactly that many midbosses have DIED -- so the run is "clear ten midbosses,
;;; then fight the boss", enforced at the spawn call rather than by any script.
;;;
;;; The one-boss guarantee falls out of the same counter: spawning the boss increments
;;; midboss-deaths again, pushing it to eleven, and the test is equality. Every later
;;; boss spawn is refused, and so is any that would follow a further midboss death.
;;;
;;; The spawner keeps offering bosses regardless; it has no idea about any of this.

(defconstant +max-midboss-instances+ 10 "MAX_MIDBOSS_INSTANCE")

(defparameter *max-concurrent-midbosses* 5
  "How many midbosses may be alive at once. CHANGED FROM THE ORIGINAL, which has no such
   limit -- MAX_MIDBOSS_INSTANCE caps the TOTAL per level and is never decremented.

   Five, tuned by play rather than argument, and the direction is not the obvious one:
   throttling harder makes the game HARDER. One was worse than three; three was still
   worse than none.

   The mechanism is the power-up cycle, not the arithmetic of the gate. The answer to a
   crowd is to back off -- drifting left stalls the scroll and lets the wave slide past --
   and wait for a rapid or a shotgun; a rapid then melts everything on screen at once.
   Five midbosses plus the ordinary swarm is a lot to survive but not enough to be
   unavoidable, so a careful player rides it out and cashes one power-up to clear the
   board. Spreading the same ten arrivals thinner does not make any single moment safer;
   it makes the waiting game longer, and the waiting is where health goes. Cost is paid
   per second survived rather than per enemy present.

   So the number to reach for here is concurrency, not the bridge's cooldown or its
   health. Making each midboss individually gentler lengthens the stall as surely as
   spacing them out does.

   Measured, because the difference is not marginal: spawn_midboss has `spawn_delta = 10`
   where every other class uses 60 to 1000, so once the class opens it is ready almost
   every column. All ten arrive within about a second and all ten are alive together --
   and since they all fly the same `infinity` spline, whose knots are absolute screen
   coordinates, they converge into a single cluster mid-screen. Ten of them at two bombs
   every seven ticks is not an encounter, it is a wall.

   Capping the concurrent count turns the dump into a staged fight without touching the
   gate that matters: it is still exactly ten midbosses, and the boss still waits for all
   ten to die. Set this to +MAX-MIDBOSS-INSTANCES+ for the original's behaviour.

   Worth recording the suspicion rather than acting on it: `spawn_delta = 10` looks like a
   typo for 100 or 1000, both of which would have spread the ten out by themselves. The
   line above it carries a commented-out alternative (`start_delta = 8000 #10000`), so
   these numbers were being fiddled with late.")

(defparameter *max-concurrent-per-definition* 4
  "How many of any ONE enemy may be alive at once. ADDED, not ported.

   The original needs no such rule because it has a pool of fifty and assumes things
   leave. Several do not. An enemy flying a looping spline never goes offscreen, and its
   knots are absolute screen coordinates, so every instance converges on the same patch
   and parks there until shot. Measured: forty-four enemy_ship_floogle stacked in the
   column at x 150-160, filling the pool and stopping everything else spawning -- the
   same failure the frozen turrets caused, by a different route.

   This is the general form of the midboss cap below, and it would have covered that case
   too; the midboss one is kept separate because it is tighter and because it guards a
   gate the game's pacing depends on.")

(defparameter *max-concurrent-overrides*
  '(("enemy_midboss_bridge" . 4)
    ("enemy_ship_stealth" . 3))
  "Per-definition caps, separate from *MAX-CONCURRENT-PER-DEFINITION*. ADDED, not ported.

   Both of these are stage three, and both fire shot 12 -- the one that bursts into
   bullets curling outward in loops rather than flying off in a direction. Several at
   once put overlapping rings of fire around a player who is already being closed on,
   which is the stage's difficulty spike.

   Not one. Cutting the bridge to a single instance backfires: it is a midboss, and the
   boss gate opens on +MAX-MIDBOSS-INSTANCES+ deaths, so throttling how many can be alive
   only draws out a fight that is already one of attrition.

   Note that the bridge's 4 does nothing on its own. The effective limit is the smaller of
   this and *MAX-CONCURRENT-MIDBOSSES*, which is 3, and the midboss gate is checked for
   every midboss regardless of what is written here. Raising this past 3 only takes effect
   if that one is raised too.")

(defun live-midbosses (pool)
  (count :enemy-midboss (pool-live pool)
         :key (lambda (e) (definition-kind (enemy-definition e)))))

(defun live-of-definition (pool name)
  (count name (pool-live pool)
         :key (lambda (e) (definition-name (enemy-definition e)))
         :test #'string=))

(defun max-concurrent-for (name)
  "How many of one definition may be alive at once."
  (or (cdr (assoc name *max-concurrent-overrides* :test #'string=))
      *max-concurrent-per-definition*))

(defun spawn-allowed? (pool kind &optional name)
  "Whether a spawn of KIND may proceed, updating the gate's counters if so."
  (let ((cap (and name (max-concurrent-for name))))
    (when (and cap (plusp cap) (>= (live-of-definition pool name) cap))
      (return-from spawn-allowed? nil)))
  (case kind
    (:enemy-midboss
     (when (and (< (pool-midboss-count pool) +max-midboss-instances+)
                (< (live-midbosses pool) *max-concurrent-midbosses*))
       (incf (pool-midboss-count pool))
       t))
    (:enemy-boss
     (when (= (pool-midboss-deaths pool) +max-midboss-instances+)
       (incf (pool-midboss-deaths pool))
       t))
    (t t)))

(defun spawn (pool name x y &key force)
  "FORCE skips the pacing gates -- the per-definition cap, the midboss budget, and the
   boss's requirement that the midbosses be dead first. Nothing in the game should pass
   it: those gates are the pacing. It exists for screens that display enemies rather than
   fight them, where a boss has to appear without ten midbosses having died for it."
  (let ((def (definition pool name)))
    (cond
      ((null def) (warn "Enemies: unknown enemy ~s" name) nil)
      ((null (pool-free pool)) nil)
      ((and (not force) (not (spawn-allowed? pool (definition-kind def) name))) nil)
      (t
       (let* ((e (pop (pool-free pool)))
              (sprite (definition-sprite def))
              (rect (rect:make-rect x y (theme:sprite-width sprite)
                                    (theme:sprite-height sprite))))
         (setf (enemy-definition e) def
               (enemy-rect e) rect
               (enemy-health e) (definition-health def)
               (enemy-movement e) (first (definition-movements def))
               (enemy-movement-timer e) 0
               ;; Enemies are pooled and reused, so an old path must not be inherited.
               (enemy-spline e) nil
               (enemy-move-debt-x e) 0.0
               (enemy-move-debt-y e) 0.0
               (enemy-dead? e) nil
               (enemy-shoot-timers e) (make-array 10 :initial-element 0)
               (enemy-frame e) 0
               (enemy-collider e)
               (collision:make-collider rect (definition-kind def)
                                        :data e
                                        :on-hit (lambda (self other)
                                                  (declare (ignore self))
                                                  (hit pool e
                                                       (collision:collider-kind other)
                                                       :difficulty (pool-difficulty pool)
                                                       :player-status
                                                       (pool-player-status pool)))
                                        :on-offscreen (lambda (self)
                                                        (declare (ignore self))
                                                        (offscreen pool e))))
         (when (pool-world pool)
           (collision:add (pool-world pool) (enemy-collider e)))
         (push e (pool-live pool))
         e)))))

(defun turret? (enemy)
  (eq (definition-kind (enemy-definition enemy)) :enemy-turret))

;;; ---------------------------------------------------------------------------
;;; The thing behind you

(defparameter *chaser-name* "boss_Chaser"
  "The one enemy the spawner never produces. DSCEnemies::initTheme creates it directly,
   once per level, and everything about its config says what it is for:

     sprite     Behind_Boss
     movement   10, pursue -- the only movement EnemyShipOffscreen refuses to reap, so
                it can sit off the left edge indefinitely
     health     9001
     spawn_prob 0

   PursueMovement closes the gap whenever the player's horizontal acceleration goes
   NEGATIVE, and otherwise creeps left to a floor of -90. So it shadows you just out of
   sight, and reversing is what brings it in. It is a check on backing up for ever: the
   ship can retreat to collect a missed pickup, but not indefinitely, because something
   unkillable with a twelve-angle spread is waiting back there.

   Spawned at (-90, 120): as far left as PursueMovement will ever let it go, at the top
   of the screen.")

(defparameter *chaser-spawn* '(-90 120) "initTheme's createObject arguments.")

(defun init-theme (pool)
  "DSCEnemies::initTheme. Reset the boss gate and put the chaser behind the player.

   Note this is the ONE enemy created outside the spawner, which is why it is easy to
   miss: boss_Chaser appears in the config's `bosses` list, so its definition loads, but
   in no spawn class's `object_list`, so nothing ever picks it."
  (setf (pool-midboss-count pool) 0
        (pool-midboss-deaths pool) 0)
  (when (definition pool *chaser-name*)
    (apply #'spawn pool *chaser-name* *chaser-spawn*)))

;;; ---------------------------------------------------------------------------
;;; Leaving the screen
;;;
;;; EnemyShipOffscreen has three outcomes, chosen by the FIRST entry in the definition's
;;; movement list -- not the movement currently being flown, so an enemy cycling 1,17,2
;;; wraps forever even while it is halfway through an msattack run.
;;;
;;;   movement[0] < 10   wrap: jump 320 cells right and keep going. The looping paths
;;;                      (infinity, up_down, side_side, curvey, DOOM) are meant to
;;;                      patrol, so they come back around rather than being spent.
;;;   movement[0] = 10   pursue: immune. It is chasing the player and is allowed to fall
;;;                      as far behind as it likes.
;;;   movement[0] > 10   killed.
;;;
;;; Only the LEFT edge counts. The handler tests `rect.x + rect.w < 0` itself, so an
;;; enemy above, below or right of the screen is left alone even though the collision
;;; manager reports it as outside.
;;;
;;; Being killed this way is indistinguishable from being shot: it runs the same
;;; Destroy_Enemy, so an escaping midboss counts toward the boss gate below.

(defconstant +offscreen-wrap-distance+ 320
  "How far right a wrapping enemy jumps. Wider than the 240-cell screen, so it reappears
   after a pause rather than immediately.")

(defun offscreen-rule (enemy)
  "One of :WRAP, :IMMUNE or :KILL."
  (let ((first-movement (first (definition-movements (enemy-definition enemy)))))
    (case first-movement
      ((:infinity :up-down :side-side :curvey :doom) :wrap)
      (:pursue :immune)
      (t :kill))))

(defun offscreen (pool enemy)
  (let ((r (enemy-rect enemy)))
    ;; Left edge only.
    (when (and r (< (+ (rect:rect-x r) (rect:rect-w r)) 0))
      (ecase (offscreen-rule enemy)
        (:wrap (%move pool enemy +offscreen-wrap-distance+ 0))
        (:immune nil)
        (:kill (setf (enemy-dead? enemy) t)))))
  enemy)

(defparameter *vulnerable-player-states* '(:play :invulnerable)
  "The player states during which ships, midbosses and bosses can be damaged.")

(defun ship-damage-enabled? (player-status)
  "Enemy_Ship_Hit's guard, as intended rather than as written.

   The source reads

       if (A || B || C && D || E)          A/B/C: ship, midboss, boss
                                           D/E:   player playing, invulnerable

   and the layout says 'one of these enemy types AND one of these player states'. But
   && binds tighter than || in C, so it actually groups as

       A || B || (C && D) || E

   which has two consequences. Ships and midbosses pass on A or B alone, so the player
   state never gates them -- only the boss is gated. And E stands alone at the end, so
   *any* enemy passes while the player is invulnerable, including turrets, which then
   take the ship damage table instead of their own. For those 300 ticks a bomb stops
   destroying turrets outright and merely takes 10 health off them.

   We implement the evident intent, (A || B || C) && (D || E). Deliberate deviation --
   see PLAN.md section 7. Turrets keep their own table unconditionally, matching the
   original's ungated `else if` branch."
  (member player-status *vulnerable-player-states*))

(defun damage-for (enemy other-kind &key (difficulty 4) (player-status :play))
  "Enemy_Ship_Hit's damage, split by whether this is a turret.

   Two faithful details kept: a boss takes nothing from ramming the player, and a bomb
   destroys a turret outright rather than damaging it."
  (if (turret? enemy)
      (case other-kind
        (:player-bomb :destroy)
        (:player 10)
        (:player-bullet (- 2 (truncate difficulty 5)))
        (t 0))
      (if (not (ship-damage-enabled? player-status))
          0
          (case other-kind
            (:player (if (eq (definition-kind (enemy-definition enemy)) :enemy-boss) 0 5))
            (:player-bullet 2)
            (:player-bomb 10)
            (t 0)))))

(defun score-for (enemy other-kind)
  "Killing with a shot scores; ramming does not. The PLAYER branch of the ship case has
   no score line where the bullet and bomb branches do -- reproduced as written."
  (if (or (turret? enemy) (member other-kind '(:player-bullet :player-bomb)))
      (* (definition-health (enemy-definition enemy)) 10)
      0))

(defun %centre (enemy)
  (let ((r (enemy-rect enemy)))
    (values (+ (rect:rect-x r) (truncate (rect:rect-w r) 2))
            (- (rect:rect-y r) (truncate (rect:rect-h r) 2)))))

(defun hit (pool enemy other-kind &key (difficulty 4) (player-status :play))
  (let ((damage (damage-for enemy other-kind :difficulty difficulty
                                             :player-status player-status)))
    (cond
      ((eq damage :destroy) (setf (enemy-health enemy) 0))
      ((plusp damage) (decf (enemy-health enemy) damage))
      (t (return-from hit enemy)))
    ;; Enemy_Ship_Hit spews on EVERY hit that lands, not just the fatal one -- that
    ;; spray is the feedback telling you your shots are connecting. Turrets are the
    ;; exception: their branch has no :ENEMY spew, only the burst when they go.
    (when (and (pool-emit pool) (not (turret? enemy)))
      (multiple-value-bind (cx cy) (%centre enemy)
        (funcall (pool-emit pool) cx cy :enemy)))
    (when (<= (enemy-health enemy) 0)
      (setf (enemy-dead? enemy) t)
      ;; Enemy_Ship_Hit plays this from every branch that kills, so it marks a kill by
      ;; the player specifically -- an enemy that leaves the screen goes quietly.
      (audio:play (pool-sound-death pool))
      (when (pool-on-death pool)
        (funcall (pool-on-death pool) enemy (score-for enemy other-kind)))))
  enemy)

;;; ---------------------------------------------------------------------------
;;; Firing
;;;
;;; InterperateShot turns each shot type into a firing pattern: which projectile to
;;; spawn, how often, at what angles, and how far onto the screen the enemy must be
;;; before it will shoot. Everything scales with difficulty.
;;;
;;; Angles cluster around pi because enemy fire travels LEFT toward the player -- pi is
;;; straight back, and the fractions either side fan the spread.
;;;
;;; Note the original stores each spread as a zero-terminated array, so an angle of
;;; exactly 0 could never be part of a pattern. None of the real patterns need one, but
;;; it is why the seven spline-driven types set spread[0] = 0: that is how they say
;;; "no plain spread, use the spline function instead".

(defconstant +fire-x-limit+ 240
  "FireEverything gates on d_X < 240 - delay, so a larger delay keeps the enemy quiet
   until it is further onto the screen.")

(defstruct (pattern (:constructor make-pattern (bullet speed spread delay &key spline)))
  (bullet "" :type string)
  (speed 0 :type fixnum)
  (spread '() :type list)
  (delay 0 :type fixnum)
  (spline nil))

(defun %pi* (numerator denominator)
  (float (* pi (/ numerator denominator)) 1.0))

(defun %scaled (base multiplier difficulty &optional (divisor 1))
  "base - (difficulty * multiplier) / divisor, with C's truncating division. Can go
   negative at high difficulty, which makes the enemy fire every tick."
  (- base (truncate (* difficulty multiplier) divisor)))

;;; ---------------------------------------------------------------------------
;;; Spline-driven shots
;;;
;;; Seven shot types do not fire along a spread at all: they build one or more
;;; Catmull-Rom paths and launch projectiles that fly them. Each builder below takes the
;;; gun's muzzle and the player's rect, and returns a list of (dt . knots) -- one entry
;;; per projectile, so a single trigger pull can produce fifteen of them.
;;;
;;; Knots are absolute cells and are laid out by walking leftward from the muzzle, which
;;; is why every one of these travels left regardless of where the enemy is pointing.

(defun %walk-left (x y step deltas)
  "Knots marching left by STEP, with DELTAS applied cumulatively to Y. The original
   writes these out one line at a time as `points[n].d_y = points[n-1].d_y + k`."
  (let ((cx x) (cy y))
    (cons (cons cx cy)
          (loop for d in deltas
                do (decf cx step) (incf cy d)
                collect (cons cx cy)))))

(defun bullet-flamer (gx gy player-rect)
  "A short lick of flame: two knots, 30 cells left.

   The original passes two knots, which cl-catmull-rom-spline rejects -- it needs three
   to have a segment to interpolate. A midpoint is inserted, which changes nothing
   geometrically: three collinear, evenly spaced knots describe the same straight line."
  (declare (ignore player-rect))
  (list (cons 0.135 (list (cons gx gy)
                          (cons (- gx 15.0) gy)
                          (cons (- gx 30.0) gy)))))

(defun bullet-launcher (gx gy player-rect)
  "Lobs downward then peels up hard -- nine knots, 12 cells apart."
  (declare (ignore player-rect))
  (list (cons 0.135 (%walk-left gx gy 12.0 '(10.0 5.0 -10.0 -10.0 -15.0 -15.0 -20.0 -20.0)))))

(defun bullet-upcurve (gx gy player-rect)
  "The launcher mirrored: dips first, then climbs away."
  (declare (ignore player-rect))
  (list (cons 0.135 (%walk-left gx gy 12.0 '(-10.0 -5.0 10.0 10.0 15.0 15.0 20.0 20.0)))))

(defun bullet-circle (gx gy player-rect)
  "Eight petals: four quadrants, two curls each, thrown from the same point.

   The two curls differ in which axis leads -- one swings out in Y then pulls back in X,
   the other the reverse -- and the quadrant flips the signs. Together they read as a
   ring blooming outward."
  (declare (ignore player-rect))
  (loop for (mx my) in '((1.0 1.0) (1.0 -1.0) (-1.0 -1.0) (-1.0 1.0))
        append (list
                (cons 0.235
                      (list (cons gx gy)
                            (cons (- gx (* 5.0 mx)) (+ gy (* 5.0 my)))
                            (cons (- gx (* 10.0 mx)) (+ gy (* 10.0 my)))
                            (cons (- gx (* 15.0 mx)) (+ gy (* 7.0 my)))
                            (cons (- gx (* 20.0 mx)) (+ gy (* 4.0 my)))
                            (cons (- gx (* 10.0 mx)) (+ gy (* 1.0 my)))
                            (cons gx (+ gy (* 5.0 my)))))
                (cons 0.235
                      (list (cons gx gy)
                            (cons (- gx (* 5.0 mx)) (+ gy (* 5.0 my)))
                            (cons (- gx (* 10.0 mx)) (+ gy (* 10.0 my)))
                            (cons (- gx (* 7.0 mx)) (+ gy (* 15.0 my)))
                            (cons (- gx (* 4.0 mx)) (+ gy (* 20.0 my)))
                            (cons (- gx (* 1.0 mx)) (+ gy (* 10.0 my)))
                            (cons (+ gx (* 3.0 mx)) gy))))))

(defun bullet-homing (gx gy player-rect)
  "Five shots on the same path at staggered speeds, aimed where the ship is NOW.

   Not homing at all despite the name -- the path is fixed when it is fired. The five
   differing delta-ts are what makes it read as a stream rather than one projectile."
  (let* ((px (float (rect:rect-x player-rect) 1.0))
         (py (float (rect:rect-y player-rect) 1.0))
         (knots (list (cons gx gy)
                      (cons (- gx 10.0) gy)
                      (cons (- px 5.0) py)
                      (cons (- px 45.0) (- py 5.0)))))
    (loop for i from 1 to 5
          collect (cons (+ 0.100 (* 0.01 i)) knots))))

(defun bullet-cannon (gx gy player-rect)
  "Five heavy shots straight left, stacked on the same line.

   The original asks for nine knots from a six-element array, so three of them are
   whatever was on the stack -- and it fires five projectiles down that same garbage
   path. We use the six knots that actually exist. The overread is not reproducible and
   would not be worth reproducing: it is undefined behaviour, not a design."
  (declare (ignore player-rect))
  (loop repeat 5 collect (cons 0.325 (%walk-left gx gy 25.0 '(0.0 0.0 0.0 0.0 0.0)))))

(defun bullet-omega-blast (gx gy player-rect)
  "Fifteen shots stacked three cells apart, all running straight left: a wall."
  (declare (ignore player-rect))
  (loop for i from 0 below 15
        collect (cons 0.325 (%walk-left gx (- gy (* i 3.0)) 35.0 '(0.0 0.0 0.0 0.0 0.0)))))

(defun shot-pattern (kind difficulty)
  "The InterperateShot table: shot type -> what to fire, how fast, how often, and how far
   onto the screen the enemy must be before it will."
  (ecase kind
    (:straight
     (make-pattern "enemy_ship_bullet" (%scaled 20 3 difficulty)
                   (list (%pi* 1 1) (%pi* 15 16) (%pi* 17 16))
                   (%scaled 20 3 difficulty)))
    (:cover
     (make-pattern "enemy_ship_bullet" (%scaled 5 3 difficulty 2)
                   (list (%pi* 5 6) (%pi* 7 6))
                   (%scaled 120 3 difficulty)))
    (:bomber
     (make-pattern "enemy_ship_bomb" (%scaled 35 3 difficulty)
                   (list (%pi* 3 2) (%pi* 13 8) (%pi* 5 4))
                   (%scaled 160 3 difficulty)))
    (:boss
     (make-pattern "enemy_ship_bullet" (%scaled 10 2 difficulty)
                   (list (%pi* 31 32) (%pi* 33 32))
                   (%scaled 50 3 difficulty)))
    (:lazer
     (make-pattern "enemy_ship_bomb" (%scaled 10 3 difficulty 2)
                   (list (%pi* 1 1))
                   (%scaled 30 3 difficulty 2)))
    (:lturret
     (make-pattern "enemy_ship_bullet" (%scaled 20 5 difficulty)
                   (list (%pi* 3 4))
                   (%scaled 120 5 difficulty)))
    (:hturret
     (make-pattern "enemy_ship_bullet" (%scaled 20 5 difficulty)
                   (list (%pi* 3 4) (%pi* 1 2) (%pi* 1 4))
                   (%scaled 120 5 difficulty)))
    (:chaser
     (make-pattern "enemy_ship_bomb" (%scaled 30 3 difficulty)
                   (list (%pi* 7 4) (%pi* 5 3) (%pi* 19 12) (%pi* 3 2) (%pi* 17 12)
                         (%pi* 4 3) (%pi* 5 4) (%pi* 7 6) (%pi* 13 12) (%pi* 1 1)
                         (%pi* 11 12) (%pi* 25 24))
                   (%scaled 130 3 difficulty)))
    ;; The seven spline-driven types. Each carries no spread at all -- the original sets
    ;; spread[0] = 0, which terminates the array -- and a BulletSpline function instead.
    (:flame
     (make-pattern "enemy_flame_shot" (%scaled 10 3 difficulty) '()
                   (%scaled 160 3 difficulty) :spline #'bullet-flamer))
    (:launcher
     (make-pattern "enemy_ship_bomb" (%scaled 15 3 difficulty) '()
                   (%scaled 150 3 difficulty) :spline #'bullet-launcher))
    (:upcurve
     (make-pattern "enemy_ship_bomb" (%scaled 15 3 difficulty) '()
                   (%scaled 140 3 difficulty) :spline #'bullet-upcurve))
    (:circle
     (make-pattern "enemy_flame_shot" (%scaled 10 2 difficulty) '()
                   (%scaled 170 3 difficulty) :spline #'bullet-circle))
    (:homing
     (make-pattern "enemy_ship_bomb" (%scaled 20 3 difficulty) '()
                   (%scaled 110 3 difficulty) :spline #'bullet-homing))
    (:cannon
     (make-pattern "enemy_super_bomb" (%scaled 50 5 difficulty) '()
                   (%scaled 40 3 difficulty) :spline #'bullet-cannon))
    (:omega-blast
     (make-pattern "enemy_super_bomb" (%scaled 50 5 difficulty) '()
                   (%scaled 30 3 difficulty) :spline #'bullet-omega-blast))))

(defun gun-position (enemy gun)
  "A gun's firing point, as fractions of the sprite's extent. X grows right from the
   left edge; Y is measured DOWN from the top, matching the original's
   `rect.y - height * y_fraction`."
  (let ((r (enemy-rect enemy)))
    (values (+ (rect:rect-x r) (truncate (* (rect:rect-w r) (gun-x-fraction gun))))
            (- (rect:rect-y r) (truncate (* (rect:rect-h r) (gun-y-fraction gun)))))))

(defun fire-spread (pool enemy pattern shot-index &key player-rect)
  "FireSpread: every gun assigned to this shot fires.

   A pattern is one or the other, never both: with a spline builder the gun produces
   however many spline-flying projectiles that builder returns, otherwise one straight
   bullet per spread angle."
  (let ((fire (pool-fire-bullet pool))
        (fire-spline (pool-fire-spline pool))
        (guns (definition-guns (enemy-definition enemy)))
        (count 0))
    (dolist (gun guns)
      (when (member shot-index (gun-shots gun))
        (multiple-value-bind (gx gy) (gun-position enemy gun)
          (cond
            ((pattern-spline pattern)
             (when fire-spline
               (dolist (shot (funcall (pattern-spline pattern)
                                      (float gx 1.0) (float gy 1.0)
                                      (or player-rect (rect:make-rect 0 0 1 1))))
                 (funcall fire-spline (pattern-bullet pattern) (cdr shot) (car shot))
                 (incf count))))
            (fire
             (dolist (angle (pattern-spread pattern))
               (funcall fire (pattern-bullet pattern) angle gx gy)
               (incf count)))))))
    ;; FireSpread picks the sound by bullet NAME, once per call rather than per shot, and
    ;; has nothing to say about the other three projectile types -- so flame, super bomb
    ;; and anything else fire silently. Faithful; those are the spline shots, which are
    ;; loud enough in other ways.
    (when (plusp count)
      (let ((name (pattern-bullet pattern)))
        (cond
          ((string= name "enemy_ship_bullet") (audio:play (pool-sound-fire pool)))
          ((string= name "enemy_ship_bomb") (audio:play (pool-sound-bomb pool))))))
    count))

(defun fire-everything (pool enemy &key (difficulty 4) player-rect)
  "FireEverything: each of the enemy's shots has its own timer and its own x gate."
  (let ((shots (definition-shots (enemy-definition enemy)))
        (fired 0))
    (loop for kind in shots
          for i from 0
          for pattern = (shot-pattern kind difficulty)
          when pattern
            do (let ((timer (aref (enemy-shoot-timers enemy) i)))
                 ;; The cooldown is the one number a player really feels here, so it is
                 ;; converted from the original's ticks to ours. The DELAY beside it is
                 ;; not: it gates on screen position, not elapsed time.
                 (when (and (> timer (state:scale-ticks (pattern-speed pattern)))
                            (< (rect:rect-x (enemy-rect enemy))
                               (- +fire-x-limit+ (pattern-delay pattern))))
                   (incf fired (fire-spread pool enemy pattern i :player-rect player-rect))
                   (setf (aref (enemy-shoot-timers enemy) i) 0))
                 (incf (aref (enemy-shoot-timers enemy) i))))
    fired))

;;; ---------------------------------------------------------------------------
;;; Update

(defun %reap (pool e)
  "Destroy_Enemy. Note this runs however the enemy's health reached zero -- shot, rammed,
   or simply having left the screen -- which is why an escaping midboss still counts
   toward the boss gate, and why a boss that drifts off the left edge ends the level."
  (let ((kind (definition-kind (enemy-definition e))))
    (case kind
      (:enemy-midboss (incf (pool-midboss-deaths pool)))
      (:enemy-boss
       ;; Guarded on the player not already being dead, so a mutual kill is a loss.
       (when (and (pool-on-boss-defeated pool)
                  (not (eq (pool-player-status pool) :dead)))
         (funcall (pool-on-boss-defeated pool) e)))))
  (when (and (pool-world pool) (enemy-collider e))
    (collision:remove-collider (pool-world pool) (enemy-collider e)))
  (setf (enemy-collider e) nil
        (enemy-rect e) nil
        (enemy-spline e) nil)
  (push e (pool-free pool)))

(defun update (pool &key player-rect (player-accel-x 0.0) world-x)
  "Advance every live enemy. PLAYER-RECT drives the tracking behaviours, PLAYER-ACCEL-X
   sets the scroll step, and WORLD-X is the player's world position -- turrets need the
   distance travelled since the last tick to hold still in world space."
  (when world-x
    (setf (pool-scroll-delta pool) (- world-x (pool-world-x pool))))
  (setf (pool-player-accel-x pool) (float player-accel-x 1.0))
  (let ((step (scroll-step player-accel-x))
        (survivors '()))
    (dolist (e (pool-live pool))
      (if (enemy-dead? e)
          (%reap pool e)
          (let ((pr (or player-rect (rect:make-rect 0 0 1 1))))
            ;; An attached spline outranks the movement kind -- see ADVANCE-SPLINE.
            (if (enemy-spline e)
                (advance-spline pool e :player-rect pr)
                (funcall (or (movement-fn (enemy-movement e)) #'move-straight)
                         pool e step :player-rect pr))
            (fire-everything pool e :difficulty (pool-difficulty pool) :player-rect pr)
            (incf (enemy-movement-timer e))
            ;; After the increment, as the original does -- so the first animated frame
            ;; lands on tick 5 rather than tick 0.
            (advance-frame e)
            (push e survivors))))
    (setf (pool-live pool) (nreverse survivors))
    ;; Stored at the end, as the original does, so next tick's delta is measured from
    ;; here rather than from wherever the player was when this tick started.
    (when world-x (setf (pool-world-x pool) world-x))
    (length (pool-live pool))))

(defconstant +animation-delta+ 5 "A frame every five movement ticks.")
(defconstant +turret-wake-x+ 120
  "A turret only animates once it is this far onto the screen -- the animation is it
   noticing the player, so it must not play out while the turret is still off-screen.")

(defun advance-frame (enemy)
  "One step of the sprite animation, if this tick is one of the every-fifth ones.

   Two rules, and the difference is the whole point. An ordinary enemy LOOPS: engines
   flicker, wings beat. A turret does not -- it walks its frames once and stops on the
   last one, so the animation reads as deploying and staying deployed.

   The original expresses the turret's version by simply omitting the `else` that would
   wrap it, and it phases both off Movement_Timer, so changing movement restarts the
   animation too.

   Note the original stores a frame COUNT and then decrements it on load
   (`d_nFrames -= 1; /* cause 0 = 1 this is the number of frames */`), turning it into a
   maximum index. Without that its `!=` test would run one frame past the end of the
   sprite; with it, a single-frame sprite correctly never animates at all."
  (let* ((frames (theme:sprite-frames (definition-sprite (enemy-definition enemy))))
         (last (1- frames)))
    (when (and (plusp last)
               (zerop (mod (enemy-movement-timer enemy) +animation-delta+)))
      (if (turret? enemy)
          (when (and (< (rect:rect-x (enemy-rect enemy)) +turret-wake-x+)
                     (< (enemy-frame enemy) last))
            (incf (enemy-frame enemy)))
          (setf (enemy-frame enemy)
                (if (< (enemy-frame enemy) last) (1+ (enemy-frame enemy)) 0)))))
  enemy)

(defun render (pool screen)
  (dolist (e (pool-live pool) pool)
    (let ((r (enemy-rect e)))
      (when r
        (screen:enqueue screen (definition-sprite (enemy-definition e))
                        (rect:rect-x r) (rect:rect-y r) +z-enemy+
                        (enemy-frame e))))))

(defun clear (pool)
  ;; Bypass %reap: clearing is not the enemies dying, so it must not advance the boss
  ;; gate or announce a boss defeat.
  (dolist (e (copy-list (pool-live pool)))
    (when (and (pool-world pool) (enemy-collider e))
      (collision:remove-collider (pool-world pool) (enemy-collider e)))
    (setf (enemy-collider e) nil
          (enemy-rect e) nil
          (enemy-spline e) nil)
    (push e (pool-free pool)))
  (setf (pool-live pool) '()
        (pool-midboss-count pool) 0
        (pool-midboss-deaths pool) 0)
  pool)
