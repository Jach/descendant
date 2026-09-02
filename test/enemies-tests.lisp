(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-enemy-pool (&key world (difficulty 4))
  (let ((pool (enemies:make-pool :world world))
        (cfg (config:read-config (paths:config-path "level_crash_site.cfg")))
        (th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (enemies:load-definitions
     pool cfg th
     (append (config:config-list cfg "level_data.enemy_ships")
             (config:config-list cfg "level_data.turrets"))
     :difficulty difficulty)
    pool))

(test enemy-definitions-from-config
  (let* ((pool (make-enemy-pool))
         (bomber (enemies:definition pool "enemy_ship_bomber")))
    (is-true bomber)
    (is (eq :enemy-ship (enemies:definition-kind bomber)))
    (is (equal '(:follow) (enemies:definition-movements bomber)) "movement = 11")
    (is (equal '(:bomber) (enemies:definition-shots bomber)) "shot = 3")
    (is (< (abs (- 21.51 (enemies:definition-acceleration bomber))) 1e-3))
    (is (< (abs (- 7.2 (enemies:definition-homing bomber))) 1e-3))))

(test enemy-health-scales-with-difficulty
  "addEnemy adds difficulty * 3 to the configured health."
  (let ((easy (make-enemy-pool :difficulty 1))
        (hard (make-enemy-pool :difficulty 4)))
    (is (= (+ 5 3) (enemies:definition-health
                    (enemies:definition easy "enemy_ship_bomber"))))
    (is (= (+ 5 12) (enemies:definition-health
                     (enemies:definition hard "enemy_ship_bomber"))))))

(test enemy-movement-lists-parse
  "`movement = 1,17,2` becomes a cycle the enemy steps through."
  (is (equal '(:infinity :msattack :up-down)
             (mapcar #'enemies:movement-type (enemies:parse-int-list "1,17,2"))))
  (is (equal '(:box :hourglass :zag)
             (mapcar #'enemies:movement-type (enemies:parse-int-list "14,15,16")))))

(test enemy-turret-detection
  "A leading movement of 20 or more retypes the collider to a turret whatever the
   config's `type` said."
  (let* ((pool (make-enemy-pool))
         (heavy (enemies:definition pool "turret_heavy")))
    (when heavy
      (is (eq :enemy-turret (enemies:definition-kind heavy))
          "turrets are non_move (20) or bounce (21)"))))

(test enemy-gun-parsing
  "`0.250,0.250,1,2 - 0.350,0.100,2`: fractions of the sprite plus 1-based shot indices,
   stored zero-based."
  (let ((guns (enemies:parse-guns "0.250,0.250,1,2 - 0.350,0.100,2")))
    (is (= 2 (length guns)))
    (is (< (abs (- 0.25 (enemies:gun-x-fraction (first guns)))) 1e-4))
    (is (equal '(0 1) (enemies:gun-shots (first guns))) "1,2 -> 0,1")
    (is (equal '(1) (enemies:gun-shots (second guns))))))

(test enemy-scroll-step
  "SMove is 1 until the player accelerates hard right, then scales with it."
  (is (= 1 (enemies:scroll-step 0.0)))
  (is (= 1 (enemies:scroll-step 10.0)) "the test is strictly greater than 10")
  (is (= 2 (enemies:scroll-step 25.0)))
  (is (= 5 (enemies:scroll-step 55.0))))

(test enemy-spawn-and-pool
  (let ((pool (make-enemy-pool)))
    (let ((e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
      (is-true e)
      (is (= 1 (enemies:live-count pool)))
      (is (= 200 (rect:rect-x (enemies:enemy-rect e))))
      (is (= 17 (enemies:enemy-health e)) "5 configured + 4 difficulty * 3"))))

(test enemy-straight-movement
  "Straight is the only movement that advances two steps per tick."
  (with-original-rates
    (let* ((pool (make-enemy-pool))
           (e (enemies:spawn pool "enemy_ship_tiefighter" 200 60)))
      (setf (enemies:enemy-movement e) :straight)
      (enemies:update pool :player-rect (rect:make-rect 30 60 9 4))
      (is (= 198 (rect:rect-x (enemies:enemy-rect e))) "-2 per tick at step 1"))))

(test enemies-cross-the-screen-at-the-original-speed
  "Movement is counted in whole cells PER TICK, so like everything else the original
   counts in ticks it was a function of the frame rate: a kamikaze at two cells a tick
   crossed in four seconds at ~30 Hz and two at our 62.5, halving the time to shoot it.
   Corrected, so the crossing takes the same number of SECONDS either way."
  (flet ((seconds-to-cross ()
           (let* ((pool (make-enemy-pool))
                  (e (enemies:spawn pool "enemy_ship_tiefighter" 240 60))
                  (player (rect:make-rect 30 60 9 4)))
             (setf (enemies:enemy-movement e) :straight)
             (loop for tick from 1 to 100000
                   do (enemies:update pool :player-rect player)
                   while (enemies:enemy-rect e)
                   when (<= (rect:rect-x (enemies:enemy-rect e)) 0)
                     do (return (/ tick state:*simulation-hz*))))))
    (let ((smooth (let ((state:*time-based-rates?* t) (state:*simulation-hz* 62.5))
                    (seconds-to-cross)))
          (original (let ((state:*time-based-rates?* nil) (state:*simulation-hz* 30.0))
                      (seconds-to-cross))))
      (is (< (abs (- smooth original)) (* 0.1 original))
          "~,2fs vs ~,2fs" smooth original))))

(test slow-movers-are-not-frozen-by-rounding
  "Most movements are one cell a tick. Rounding the scaled step down would stop them
   dead, so the remainder is carried."
  (let ((state:*time-based-rates?* t)
        (state:*simulation-hz* 62.5))
    (let* ((pool (make-enemy-pool))
           (e (enemies:spawn pool "enemy_ship_kamikaze" 200 60))
           (player (rect:make-rect 30 60 9 4))
           (start 200))
      (setf (enemies:enemy-movement e) :suicide)
      (dotimes (i 40) (enemies:update pool :player-rect player))
      (is (< (rect:rect-x (enemies:enemy-rect e)) start) "it did move")
      (is (> (rect:rect-x (enemies:enemy-rect e)) (- start 40))
          "but at about half the tick rate, not the full one"))))

(test enemy-follow-tracks-the-player
  (let* ((pool (make-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_bomber" 200 100))
         (player (rect:make-rect 30 40 9 4)))
    (setf (enemies:enemy-movement e) :follow)
    (let ((start-y (rect:rect-y (enemies:enemy-rect e))))
      (dotimes (i 20) (enemies:update pool :player-rect player))
      (is (< (rect:rect-y (enemies:enemy-rect e)) start-y)
          "the enemy descends toward a player below it")
      (is (< (rect:rect-x (enemies:enemy-rect e)) 200) "while drifting left"))))

(test enemy-suicide-closes-on-the-players-row
  (with-original-rates
    (let* ((pool (make-enemy-pool))
           (e (enemies:spawn pool "enemy_ship_kamikaze" 200 100))
           (player (rect:make-rect 30 50 9 4)))
      (setf (enemies:enemy-movement e) :suicide)
      ;; It closes one row per tick and starts 50 rows above, so it needs ~50 ticks; the
      ;; deadband is +/-3, so it settles within 4.
      (dotimes (i 60) (enemies:update pool :player-rect player))
      (is (<= (abs (- (rect:rect-y (enemies:enemy-rect e)) 50)) 4)
          "it converges on the player's row"))))

(test enemy-movement-cycles-through-the-list
  "advance-movement steps to the next entry and wraps at the end."
  (let* ((pool (make-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    (setf (enemies::enemy-definition e)
          (enemies::%make-definition :name "test" :sprite
                                     (enemies:definition-sprite
                                      (enemies:definition pool "enemy_ship_bomber"))
                                     :movements '(:up-down :side-side :straight))
          (enemies:enemy-movement e) :up-down)
    (enemies:advance-movement pool e)
    (is (eq :side-side (enemies:enemy-movement e)))
    (enemies:advance-movement pool e)
    (is (eq :straight (enemies:enemy-movement e)))
    (enemies:advance-movement pool e)
    (is (eq :up-down (enemies:enemy-movement e)) "wraps to the first")
    (is (= 0 (enemies:enemy-movement-timer e)) "and resets the timer")))

(test enemy-every-movement-has-an-implementation
  "All seventeen Movement_Types now resolve. An unknown one must still fly straight
   rather than error, since the config is data we do not control."
  (dolist (kind '(:infinity :up-down :side-side :curvey :doom :pursue :follow :straight
                  :suicide :box :hourglass :zag :msattack :divebomb :upcircle
                  :non-move :bounce))
    (is-true (enemies:movement-fn kind) "~a should be implemented" kind))
  (is (null (enemies:movement-fn :not-a-movement)))
  (with-original-rates
    (let* ((pool (make-enemy-pool))
           (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
      (setf (enemies:enemy-movement e) :not-a-movement)
      (finishes (enemies:update pool :player-rect (rect:make-rect 30 60 9 4)))
      (is (< (rect:rect-x (enemies:enemy-rect e)) 200) "it fell back to straight"))))

(test enemy-damage-values
  (let* ((pool (make-enemy-pool))
         (ship (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    (is (= 2 (enemies:damage-for ship :player-bullet)))
    (is (= 10 (enemies:damage-for ship :player-bomb)))
    (is (= 5 (enemies:damage-for ship :player)) "ramming costs the enemy 5")
    (is (= 0 (enemies:damage-for ship :enemy-bullet)) "friendly fire does nothing")))

(test enemy-damage-is-gated-on-player-state
  "Enemy_Ship_Hit's guard, implemented as intended: (ship|midboss|boss) AND
   (playing|invulnerable). The C groups it as A||B||(C&&D)||E because && binds tighter,
   which lets ships take damage while the player is dead and drops turrets into the
   ship damage table whenever the player is invulnerable. PLAN.md section 7."
  (is-true (enemies:ship-damage-enabled? :play))
  (is-true (enemies:ship-damage-enabled? :invulnerable))
  (is-false (enemies:ship-damage-enabled? :dead))
  (is-false (enemies:ship-damage-enabled? :warp))
  (let* ((pool (make-enemy-pool))
         (ship (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    (is (= 2 (enemies:damage-for ship :player-bullet :player-status :play)))
    (is (= 2 (enemies:damage-for ship :player-bullet :player-status :invulnerable)))
    (is (= 0 (enemies:damage-for ship :player-bullet :player-status :dead))
        "a dying player's shots do nothing")
    (is (= 0 (enemies:damage-for ship :player-bomb :player-status :warp)))))

(test turret-damage-ignores-player-state
  "The original's turret branch is an ungated else-if, so turrets keep their own table
   whatever the player is doing -- including while invulnerable, which is exactly where
   the C's precedence bug would have swapped in the ship table."
  (let* ((pool (make-enemy-pool))
         (turret (enemies:spawn pool "turret_heavy" 200 60)))
    (when turret
      (dolist (status '(:play :invulnerable :dead :warp))
        (is (eq :destroy (enemies:damage-for turret :player-bomb :player-status status))
            "a bomb destroys a turret outright regardless of player state (~a)" status)))))

(test turret-damage-differs
  "A bomb destroys a turret outright rather than damaging it, and bullet damage falls
   off with difficulty."
  (let* ((pool (make-enemy-pool))
         (turret (enemies:spawn pool "turret_heavy" 200 60)))
    (when turret
      (is (eq :destroy (enemies:damage-for turret :player-bomb)))
      (is (= 10 (enemies:damage-for turret :player)))
      (is (= 2 (enemies:damage-for turret :player-bullet :difficulty 4)))
      (is (= 0 (enemies:damage-for turret :player-bullet :difficulty 10))
          "at difficulty 10 bullets stop hurting turrets"))))

(test enemy-death-scores-only-for-shots
  "The PLAYER branch of Enemy_Ship_Hit has no score line where the bullet and bomb
   branches do, so ramming an enemy to death earns nothing."
  (let* ((deaths '())
         (pool (make-enemy-pool))
         (e nil))
    (setf (enemies:pool-on-death pool)
          (lambda (enemy score) (declare (ignore enemy)) (push score deaths)))
    (setf e (enemies:spawn pool "enemy_ship_bomber" 200 60))
    (loop repeat 20 until (enemies:enemy-dead? e)
          do (enemies:hit pool e :player-bullet))
    (is-true (enemies:enemy-dead? e))
    (is (= 170 (first deaths)) "definition health 17 * 10"))
  ;; and by ramming
  (let* ((deaths '())
         (pool (make-enemy-pool))
         (e nil))
    (setf (enemies:pool-on-death pool)
          (lambda (enemy score) (declare (ignore enemy)) (push score deaths)))
    (setf e (enemies:spawn pool "enemy_ship_bomber" 200 60))
    (loop repeat 20 until (enemies:enemy-dead? e)
          do (enemies:hit pool e :player))
    (is (= 0 (first deaths)) "ramming scores nothing")))

(test enemy-dead-are-reaped
  (let* ((world (collision:make-world))
         (pool (make-enemy-pool :world world))
         (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    (is (= 1 (collision:count-colliders world)))
    (setf (enemies:enemy-dead? e) t)
    (enemies:update pool :player-rect (rect:make-rect 30 60 9 4))
    (is (= 0 (enemies:live-count pool)))
    (is (= 0 (collision:count-colliders world)))
    (is (member e (enemies:pool-free pool)))))

(test enemy-render-enqueues
  (let ((pool (make-enemy-pool))
        (s (screen:make-screen)))
    (enemies:spawn pool "enemy_ship_bomber" 100 60)
    (enemies:render pool s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)))))

;;; ---------------------------------------------------------------------------
;;; Firing

(test shot-patterns-scale-with-difficulty
  "InterperateShot derives interval and x-gate from difficulty, some with C's
   truncating division."
  (let ((easy (enemies:shot-pattern :straight 1))
        (hard (enemies:shot-pattern :straight 4)))
    (is (= (- 20 3) (enemies:pattern-speed easy)))
    (is (= (- 20 12) (enemies:pattern-speed hard)) "harder means a shorter interval")
    (is (string= "enemy_ship_bullet" (enemies:pattern-bullet easy))))
  ;; 5 - (d * 3) / 2, truncating: d=1 -> 5-1 = 4, d=4 -> 5-6 = -1
  (is (= 4 (enemies:pattern-speed (enemies:shot-pattern :cover 1))))
  (is (= -1 (enemies:pattern-speed (enemies:shot-pattern :cover 4)))
      "a negative interval means it fires every tick"))

(test shot-pattern-spreads
  (is (= 3 (length (enemies:pattern-spread (enemies:shot-pattern :straight 4)))))
  (is (= 2 (length (enemies:pattern-spread (enemies:shot-pattern :cover 4)))))
  (is (= 1 (length (enemies:pattern-spread (enemies:shot-pattern :lazer 4)))))
  (is (= 12 (length (enemies:pattern-spread (enemies:shot-pattern :chaser 4))))
      "the chaser fans twelve bombs")
  ;; Enemy fire travels left, so angles cluster around pi.
  (let ((angle (first (enemies:pattern-spread (enemies:shot-pattern :lazer 4)))))
    (is (< (cos angle) 0) "a lazer shot heads left")))

(test spline-shot-types-carry-a-builder-not-a-spread
  "The seven BulletSpline types are exclusive with the spread mechanism: the original
   sets spread[0] = 0, which terminates the array, and hangs a function off the pattern
   instead."
  (dolist (kind '(:flame :launcher :upcurve :circle :homing :cannon :omega-blast))
    (let ((p (enemies:shot-pattern kind 4)))
      (is-true p "~a should have a pattern" kind)
      (is-true (enemies:pattern-spline p) "~a should carry a builder" kind)
      (is (null (enemies:pattern-spread p)) "~a should carry no spread" kind)))
  ;; And the reverse for an ordinary type.
  (let ((p (enemies:shot-pattern :straight 4)))
    (is (null (enemies:pattern-spline p)))
    (is-true (enemies:pattern-spread p))))

(test spline-shot-builders-produce-usable-paths
  "Every builder must return knot lists cl-catmull-rom-spline will accept -- three knots
   minimum -- and the right number of projectiles."
  (let ((player (rect:make-rect 30 70 9 4)))
    (dolist (spec '((:flame 1) (:launcher 1) (:upcurve 1) (:circle 8)
                    (:homing 5) (:cannon 5) (:omega-blast 15)))
      (destructuring-bind (kind expected) spec
        (let* ((p (enemies:shot-pattern kind 4))
               (shots (funcall (enemies:pattern-spline p) 200.0 60.0 player)))
          (is (= expected (length shots)) "~a fires ~d projectiles" kind expected)
          (dolist (shot shots)
            (is (plusp (car shot)) "~a needs a positive dt" kind)
            (is (>= (length (cdr shot)) 3)
                "~a needs at least three knots, got ~d" kind (length (cdr shot)))
            ;; Every knot must be a live (x . y) of reals.
            (is (every (lambda (k) (and (realp (car k)) (realp (cdr k)))) (cdr shot)))))))))

(test flamer-inserts-a-midpoint-for-the-spline-library
  "The original's flamer has two knots. cl-catmull-rom-spline needs three to have a
   segment, so a midpoint is inserted -- which is geometrically free, since three evenly
   spaced collinear knots describe the same straight line."
  (let ((shots (enemies:bullet-flamer 200.0 60.0 (rect:make-rect 30 70 9 4))))
    (is (= 1 (length shots)))
    (let ((knots (cdr (first shots))))
      (is (= 3 (length knots)))
      (is (equal '(200.0 185.0 170.0) (mapcar #'car knots)) "evenly spaced")
      (is (every (lambda (k) (= 60.0 (cdr k))) knots) "and dead level"))))

(test homing-aims-where-the-ship-is-now
  "Despite the name it does not track: the path is fixed when it is fired, which is why
   sidestepping works."
  (let* ((near (enemies:bullet-homing 200.0 60.0 (rect:make-rect 30 70 9 4)))
         (far (enemies:bullet-homing 200.0 60.0 (rect:make-rect 30 20 9 4))))
    (is (/= (cdr (third (cdr (first near))))
            (cdr (third (cdr (first far)))))
        "the aim point follows the ship's row")
    ;; All five share one path and differ only in speed.
    (is (= 5 (length near)))
    (is (equal (cdr (first near)) (cdr (fifth near))) "same knots")
    (is (< (car (first near)) (car (fifth near))) "increasing delta-t")))

(test omega-blast-stacks-a-wall
  "Fifteen shots three cells apart, all running straight left."
  (let ((shots (enemies:bullet-omega-blast 200.0 60.0 (rect:make-rect 30 70 9 4))))
    (is (= 15 (length shots)))
    (let ((ys (mapcar (lambda (s) (cdr (first (cdr s)))) shots)))
      (is (equal ys (loop for i from 0 below 15 collect (- 60.0 (* i 3.0))))))
    (dolist (s shots)
      (is (every (lambda (k) (= (cdr k) (cdr (first (cdr s))))) (cdr s))
          "each one is level"))))

(test gun-positions-are-sprite-fractions
  "Guns are stored as fractions so they track the sprite, and Y is measured down from
   the top edge."
  (let* ((pool (make-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_bomber" 100 60))
         (gun (enemies:make-gun 0.5 0.5 '(0))))
    (multiple-value-bind (gx gy) (enemies:gun-position e gun)
      (let ((r (enemies:enemy-rect e)))
        (is (= gx (+ 100 (truncate (rect:rect-w r) 2))))
        (is (= gy (- 60 (truncate (rect:rect-h r) 2))))))))

(test enemies-fire-through-the-bullet-pool
  "The pool's fire-bullet hook wired to the projectile pool, which is how the level
   will connect them."
  (let* ((epool (make-enemy-pool))
         (bpool (make-test-pool))
         (e nil))
    (setf (enemies:pool-fire-bullet epool)
          (lambda (name angle x y) (bullets:fire bpool name angle x y)))
    (setf e (enemies:spawn epool "enemy_ship_bomber" 100 60))
    ;; Wind the timer past the interval and update once.
    (dotimes (i 60) (enemies:update epool :player-rect (rect:make-rect 30 60 9 4)))
    (is (plusp (bullets:live-count bpool)) "the bomber shot at something")))

(test enemies-hold-fire-until-far-enough-onscreen
  "The x gate: an enemy still off the right edge stays silent."
  (let* ((epool (make-enemy-pool))
         (fired 0)
         (e nil))
    (setf (enemies:pool-fire-bullet epool)
          (lambda (&rest args) (declare (ignore args)) (incf fired)))
    ;; A bomber's delay at difficulty 4 is 160 - 12 = 148, so it must reach x < 92.
    (setf e (enemies:spawn epool "enemy_ship_bomber" 200 60))
    (dotimes (i 30) (enemies:fire-everything epool e))
    (is (= 0 fired) "too far right to fire")
    (setf (rect:rect-x (enemies:enemy-rect e)) 50)
    (dotimes (i 60) (enemies:fire-everything epool e))
    (is (plusp fired) "once far enough left it opens up")))

(test enemies-without-guns-fire-nothing
  "A shot type with no gun assigned to it produces no bullets, since FireSpread loops
   over guns rather than over shots."
  (let* ((epool (make-enemy-pool))
         (fired 0)
         (e (enemies:spawn epool "enemy_ship_bomber" 50 60)))
    (setf (enemies:pool-fire-bullet epool)
          (lambda (&rest args) (declare (ignore args)) (incf fired)))
    (setf (enemies::definition-guns (enemies:enemy-definition e)) '())
    (dotimes (i 60) (enemies:fire-everything epool e))
    (is (= 0 fired))))

;;; ---------------------------------------------------------------------------
;;; Spline movements

(defun fly (pool e frames &key (player (rect:make-rect 30 70 9 4)))
  "Run the pool and collect the enemy's position each frame."
  (loop repeat frames
        do (enemies:update pool :player-rect player)
        collect (cons (rect:rect-x (enemies:enemy-rect e))
                      (rect:rect-y (enemies:enemy-rect e)))))

(test every-spline-movement-has-a-path
  (dolist (kind '(:box :infinity :hourglass :zag :msattack :divebomb :curvey
                  :upcircle :bounce :doom))
    (is-true (enemies:path-for kind) "~a should have a path" kind))
  (dolist (kind '(:straight :follow :suicide :side-side :up-down :pursue :non-move))
    (is (null (enemies:path-for kind)) "~a moves per-frame, not on a path" kind)))

(test spline-movement-attaches-then-flies
  "The builder runs on the first frame and attaches a path; from then on the enemy is
   moved by the path rather than by the movement function."
  (let* ((pool (make-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    (setf (enemies:enemy-movement e) :box)
    (is (null (enemies:enemy-spline e)))
    (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
    (is-true (enemies:enemy-spline e) "a path was attached")
    (let ((track (fly pool e 60)))
      (is (> (length (remove-duplicates track :test #'equal)) 10)
          "and it actually travelled somewhere"))))

(test box-movement-traces-a-box
  "Knots at (180,40) (120,40) (120,90) (180,90): the path should visit all four corners
   of that rectangle, give or take the curve's overshoot."
  (let* ((pool (make-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    (setf (enemies:enemy-movement e) :box)
    (let* ((track (fly pool e 400))
           (xs (mapcar #'car track))
           (ys (mapcar #'cdr track)))
      (is (< (reduce #'min xs) 130) "reaches the left side")
      (is (> (reduce #'max xs) 170) "and the right")
      (is (< (reduce #'min ys) 50) "reaches the top")
      (is (> (reduce #'max ys) 80) "and the bottom"))))

(test divebomb-aims-at-the-player-when-it-builds
  "Two of the paths read the player's position as they are built, so the run is a swoop
   at where the ship WAS. Sidestepping afterwards works."
  (let ((pool (make-enemy-pool)))
    (flet ((lowest-y (player-y)
             (let ((e (enemies:spawn pool "enemy_ship_bomber" 200 60))
                   (player (rect:make-rect 30 player-y 9 4)))
               (setf (enemies:enemy-movement e) :divebomb)
               (prog1 (reduce #'min (mapcar #'cdr (fly pool e 80 :player player)))
                 (setf (enemies:enemy-dead? e) t)
                 (enemies:update pool :player-rect player)))))
      (is (> (lowest-y 90) (lowest-y 30))
          "a low ship is dived at lower than a high one"))))

(test exhausted-path-is-rebuilt
  "SplineMovement deinits and re-runs the builder when a path runs out, which is what
   makes these loop."
  (let* ((pool (make-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
    ;; Bounce has dt 0.25, ten times the others, so its arc is over in a few frames.
    (setf (enemies:enemy-movement e) :bounce)
    (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
    (let ((first-spline (enemies:enemy-spline e)))
      (is-true first-spline)
      (fly pool e 40)
      (is-true (enemies:enemy-spline e) "still flying something")
      (is (not (eq first-spline (enemies:enemy-spline e)))
          "but a freshly built one, not the original"))))

(test spline-timer-defers-the-changeover
  "Faithful quirk: past +spline-restart-limit+ the movement list advances, but the
   original immediately clobbers the newly installed function back to SplineMovement --
   so the new movement does not take effect until the CURRENT path runs out."
  (let* ((pool (make-enemy-pool))
         ;; This one cycles box -> hourglass -> zag.
         (e (enemies:spawn pool "enemy_ship_boss" 200 60)))
    (when e
      (setf (enemies:enemy-movement e) :box
            (enemies:enemy-movement-timer e) (1+ enemies:+spline-restart-limit+))
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
      ;; The builder ran (no spline yet), so the timer branch has not been reached.
      (is-true (enemies:enemy-spline e))
      (let ((spline (enemies:enemy-spline e)))
        (setf (enemies:enemy-movement-timer e) (1+ enemies:+spline-restart-limit+))
        (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
        (is (not (eq :box (enemies:enemy-movement e))) "the movement advanced")
        (is (eq spline (enemies:enemy-spline e))
            "but the old path is still the one being flown")))))

(test spline-movements-survive-a-long-run
  "Every path, flown long enough to loop several times, must not error or wander off."
  (dolist (kind '(:box :infinity :hourglass :zag :msattack :divebomb :curvey
                  :upcircle :bounce :doom))
    (let* ((pool (make-enemy-pool))
           (e (enemies:spawn pool "enemy_ship_bomber" 200 60)))
      (setf (enemies:enemy-movement e) kind)
      (finishes (fly pool e 600))
      (is-true (enemies:enemy-rect e) "~a: still alive" kind))))

;;; ---------------------------------------------------------------------------
;;; The boss gate

(defun full-enemy-pool (&key (difficulty 4))
  "Includes the bosses, which the ordinary helper leaves out."
  (let ((pool (enemies:make-pool))
        (cfg (config:read-config (paths:config-path "level_crash_site.cfg")))
        (th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (enemies:load-definitions
     pool cfg th
     (append (config:config-list cfg "level_data.enemy_ships")
             (config:config-list cfg "level_data.turrets")
             (config:config-list cfg "level_data.bosses"))
     :difficulty difficulty)
    pool))

(test boss-is-refused-until-the-midbosses-are-cleared
  "The level's whole pacing is three counters: at most ten midbosses ever spawn, and the
   boss is refused until exactly that many have died."
  (let ((pool (full-enemy-pool)))
    (is (null (enemies:spawn pool "boss_Gear" 200 60))
        "no boss at the start of the level")
    ;; Spawn and kill nine midbosses; still no boss.
    (dotimes (i 9)
      (let ((m (enemies:spawn pool "boss_Omegablaster" 200 60)))
        (is-true m "midboss ~d should spawn" i)
        (setf (enemies:enemy-dead? m) t)
        (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))))
    (is (= 9 (enemies:pool-midboss-deaths pool)))
    (is (null (enemies:spawn pool "boss_Gear" 200 60)) "nine is not ten")
    ;; The tenth opens the gate.
    (let ((m (enemies:spawn pool "boss_Omegablaster" 200 60)))
      (setf (enemies:enemy-dead? m) t)
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)))
    (is (= 10 (enemies:pool-midboss-deaths pool)))
    (is-true (enemies:spawn pool "boss_Gear" 200 60) "now the boss may come")))

(test only-one-boss-ever-spawns
  "The guarantee falls out of the same counter: spawning the boss bumps midboss-deaths
   to eleven, and the test is equality, so every later boss is refused."
  (let ((pool (full-enemy-pool)))
    (setf (enemies:pool-midboss-deaths pool) 10)
    (is-true (enemies:spawn pool "boss_Gear" 200 60))
    (is (= 11 (enemies:pool-midboss-deaths pool)))
    (is (null (enemies:spawn pool "boss_Gear" 200 60)) "and no second one")))

(test midboss-spawns-are-capped
  "At most ten are ever admitted, however many the spawner offers. Tested with the
   concurrent cap lifted, so this is asserting the TOTAL gate and nothing else."
  (let ((pool (full-enemy-pool))
        (enemies:*max-concurrent-midbosses* enemies:+max-midboss-instances+)
        (enemies:*max-concurrent-per-definition* 0))
    (dotimes (i 10)
      (is-true (enemies:spawn pool "boss_Omegablaster" (+ 200 i) 60) "midboss ~d" i))
    (is (= 10 (enemies:pool-midboss-count pool)))
    (is (null (enemies:spawn pool "boss_Omegablaster" 200 60)) "the eleventh is refused")))

(test escaping-midboss-counts-toward-the-gate
  "Destroy_Enemy runs however health reached zero, so a midboss that flies off the left
   edge is as good as a kill. Given midbosses fly looping paths this is how the gate
   actually opens in play."
  (let* ((world (collision:make-world))
         (pool (full-enemy-pool)))
    (setf (enemies:pool-world pool) world)
    (let ((m (enemies:spawn pool "boss_Omegablaster" 200 60)))
      ;; movement[0] is infinity (1), which wraps rather than dying -- so force the
      ;; kill path directly to check the accounting rather than the rule.
      (setf (enemies:enemy-dead? m) t)
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
      (is (= 1 (enemies:pool-midboss-deaths pool))))))

(test boss-defeat-fires-however-the-boss-died
  (let ((pool (full-enemy-pool))
        (defeats 0))
    (setf (enemies:pool-on-boss-defeated pool)
          (lambda (e) (declare (ignore e)) (incf defeats))
          (enemies:pool-midboss-deaths pool) 10)
    (let ((b (enemies:spawn pool "boss_Gear" 200 60)))
      (setf (enemies:enemy-dead? b) t)
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
      (is (= 1 defeats)))))

(test boss-defeat-is-suppressed-when-the-player-is-dead
  "A mutual kill is a loss, not a win."
  (let ((pool (full-enemy-pool))
        (defeats 0))
    (setf (enemies:pool-on-boss-defeated pool)
          (lambda (e) (declare (ignore e)) (incf defeats))
          (enemies:pool-midboss-deaths pool) 10
          (enemies:pool-player-status pool) :dead)
    (let ((b (enemies:spawn pool "boss_Gear" 200 60)))
      (setf (enemies:enemy-dead? b) t)
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
      (is (= 0 defeats)))))

(test clearing-the-pool-does-not-advance-the-gate
  "Unloading a level is not the enemies dying."
  (let ((pool (full-enemy-pool))
        (defeats 0))
    (setf (enemies:pool-on-boss-defeated pool)
          (lambda (e) (declare (ignore e)) (incf defeats))
          (enemies:pool-midboss-deaths pool) 10)
    (enemies:spawn pool "boss_Gear" 200 60)
    (enemies:spawn pool "boss_Omegablaster" 210 60)
    (enemies:clear pool)
    (is (= 0 defeats) "no boss defeat announced")
    (is (= 0 (enemies:pool-midboss-deaths pool)) "and the gate is reset")
    (is (= 0 (enemies:pool-midboss-count pool)))))

;;; ---------------------------------------------------------------------------
;;; Leaving the screen

(test offscreen-rules-follow-the-first-movement
  "EnemyShipOffscreen keys off movement[0], not the movement being flown -- so an enemy
   cycling 1,17,2 wraps forever even mid-msattack."
  (let ((pool (full-enemy-pool)))
    (let ((looper (enemies:spawn pool "boss_Omegablaster" 200 60)))   ; movement 1,17,2
      (is (eq :wrap (enemies:offscreen-rule looper)))
      (setf (enemies:enemy-movement looper) :msattack)
      (is (eq :wrap (enemies:offscreen-rule looper))
          "still wraps, whatever it is currently flying"))
    (let ((chaser (enemies:spawn pool "enemy_ship_chaser" 200 60)))
      (when chaser (is (eq :immune (enemies:offscreen-rule chaser)) "pursue is immune")))
    (let ((boss (enemies:spawn pool "boss_Gear" 200 60)))
      (when boss (is (eq :kill (enemies:offscreen-rule boss)) "box is above ten")))))

(test wrapping-enemies-reappear-from-the-right
  (let* ((world (collision:make-world))
         (pool (full-enemy-pool)))
    (setf (enemies:pool-world pool) world)
    (let* ((e (enemies:spawn pool "boss_Omegablaster" 200 60))
           (w (rect:rect-w (enemies:enemy-rect e)))
           ;; Fully past the edge: the test is `x + w < 0`, so x = -w is NOT yet outside.
           (start (- (- w) 1)))
      (setf (rect:rect-x (enemies:enemy-rect e)) start)
      (enemies:offscreen pool e)
      (is-false (enemies:enemy-dead? e) "not reaped")
      (is (= (+ start enemies:+offscreen-wrap-distance+)
             (rect:rect-x (enemies:enemy-rect e)))
          "jumped 320 cells right"))))

(test only-the-left-edge-reaps
  "The handler tests rect.x + rect.w < 0 itself, so being above, below or right of the
   screen does nothing even though the collision manager reports it as outside."
  (let ((pool (full-enemy-pool)))
    ;; A :KILL-rule enemy, so anything that does happen would be visible. (Not a boss --
    ;; the gate would refuse the second spawn.)
    (let ((e (enemies:spawn pool "enemy_ship_bomber" 300 60)))   ; off to the right
      (is (eq :kill (enemies:offscreen-rule e)))
      (enemies:offscreen pool e)
      (is-false (enemies:enemy-dead? e) "right edge is not fatal"))
    (let ((e (enemies:spawn pool "enemy_ship_bomber" 100 -20))) ; below
      (enemies:offscreen pool e)
      (is-false (enemies:enemy-dead? e) "nor is below"))))

;;; ---------------------------------------------------------------------------
;;; Turrets and sounds

(test turrets-hold-still-in-world-space
  "NonMoveMovment slides a turret left by exactly the distance the player advanced --
   `deltaya = playerWorldX - D_enemies.worldX`, the difference since the last tick, not
   the absolute position. Getting that wrong pins turrets off the right edge forever."
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "turret_light" 230 20))
         (player (rect:make-rect 30 70 9 4)))
    (when e
      (is (eq :non-move (enemies:enemy-movement e)))
      ;; The player advances 12 units, so the turret must come 12 cells nearer.
      (enemies:update pool :player-rect player :world-x 0)
      (let ((x (rect:rect-x (enemies:enemy-rect e))))
        (enemies:update pool :player-rect player :world-x 12)
        (is (= (- x 12) (rect:rect-x (enemies:enemy-rect e)))
            "moved by the delta, not the absolute world-x")
        (enemies:update pool :player-rect player :world-x 20)
        (is (= (- x 20) (rect:rect-x (enemies:enemy-rect e)))
            "and keeps tracking it")))))

(test a-standing-player-does-not-move-turrets
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "turret_light" 200 20))
         (player (rect:make-rect 30 70 9 4)))
    (when e
      (enemies:update pool :player-rect player :world-x 500)
      (let ((x (rect:rect-x (enemies:enemy-rect e))))
        (dotimes (i 10) (enemies:update pool :player-rect player :world-x 500))
        (is (= x (rect:rect-x (enemies:enemy-rect e))) "no travel, no scroll")))))

(test turrets-eventually-leave-and-free-their-slot
  "The regression this fixes: turrets that never scroll never die, and fifty of them
   fill the pool so nothing else can spawn."
  (let* ((world (collision:make-world))
         (pool (full-enemy-pool))
         (player (rect:make-rect 30 70 9 4)))
    (setf (enemies:pool-world pool) world)
    (enemies:spawn pool "turret_light" 235 20)
    (is (= 1 (enemies:live-count pool)))
    ;; Walk the player forward far enough to carry it off the left edge.
    (loop for wx from 0 to 400 by 4
          do (enemies:update pool :player-rect player :world-x wx)
             (collision:check-collisions world))
    (is (= 0 (enemies:live-count pool)) "it scrolled off and was reclaimed")))

(test enemy-death-plays-a-sound
  "Enemy_Ship_Hit plays enemy_death from every branch that kills."
  (let* ((audio:*muted?* nil)
         (played '())
         (audio:*play-chunk-fn* (lambda (c l ch) (declare (ignore l ch)) (push c played) 0))
         (audio:*channel-playing-fn* (lambda (c) (declare (ignore c)) nil))
         (pool (full-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_floogle" 200 60)))
    (setf (enemies:pool-sound-death pool)
          (com.thejach.descendant.audio::%make-sound
           :name "enemy_death.wav" :kind :chunk :handle :fake))
    ;; Not yet dead: no sound.
    (enemies:hit pool e :player-bullet)
    (is (null played) "a survivable hit is silent")
    ;; Finish it.
    (loop repeat 40 until (enemies:enemy-dead? e)
          do (enemies:hit pool e :player-bullet))
    (is-true (enemies:enemy-dead? e))
    (is (= 1 (length played)) "exactly one death sound")))

(test enemy-fire-picks-its-sound-by-bullet-name
  "FireSpread keys off the projectile's NAME, so the two named types have sounds and the
   spline types -- flame, super bomb -- fire silently."
  (let* ((audio:*muted?* nil)
         (played '())
         (audio:*play-chunk-fn* (lambda (c l ch) (declare (ignore l ch)) (push c played) 0))
         (audio:*channel-playing-fn* (lambda (c) (declare (ignore c)) nil))
         (pool (full-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_floogle" 100 60)))
    (flet ((mk (name) (com.thejach.descendant.audio::%make-sound
                       :name name :kind :chunk :handle (intern name :keyword))))
      (setf (enemies:pool-sound-fire pool) (mk "enemy_fire.wav")
            (enemies:pool-sound-bomb pool) (mk "enemy_bomb.wav")
            (enemies:pool-fire-bullet pool) (lambda (&rest r) (declare (ignore r)) t)))
    (enemies:fire-spread pool e (enemies:shot-pattern :straight 4) 0)
    (is (= 1 (length played)) "one sound for the whole spread, not one per bullet")
    (setf played '())
    (enemies:fire-spread pool e (enemies:shot-pattern :bomber 4) 0)
    (is (= 1 (length played)) "bombs have their own")
    (setf played '())
    (setf (enemies:pool-fire-spline pool) (lambda (&rest r) (declare (ignore r)) t))
    (enemies:fire-spread pool e (enemies:shot-pattern :flame 4) 0)
    (is (null played) "flame shots are silent")))

;;; ---------------------------------------------------------------------------
;;; Sprite animation

(test single-frame-enemies-never-animate
  "Most sprites have one frame. The original gets this right by decrementing the frame
   count to a max index on load, so its `!=` test never runs past the end."
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_floogle" 200 60)))
    (is (= 1 (theme:sprite-frames
              (enemies:definition-sprite (enemies:enemy-definition e))))
        "the assumption this test rests on")
    (dotimes (i 60) (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)))
    (is (= 0 (enemies:enemy-frame e)) "stays on frame zero")))

(test multi-frame-enemies-loop
  "boss_Gear has two frames and cycles them every five ticks."
  (let* ((pool (full-enemy-pool)))
    (setf (enemies:pool-midboss-deaths pool) 10)
    (let ((e (enemies:spawn pool "boss_Gear" 200 60)))
      (is (= 2 (theme:sprite-frames
                (enemies:definition-sprite (enemies:enemy-definition e)))))
      (let ((seen '()))
        (dotimes (i 40)
          (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
          (pushnew (enemies:enemy-frame e) seen))
        (is (equal '(0 1) (sort seen #'<)) "both frames, and only those")))))

(test animation-steps-every-fifth-tick
  (let* ((pool (full-enemy-pool)))
    (setf (enemies:pool-midboss-deaths pool) 10)
    (let ((e (enemies:spawn pool "boss_Gear" 200 60))
          (changes 0)
          (last 0))
      (dotimes (i 50)
        (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
        (unless (= last (enemies:enemy-frame e))
          (incf changes)
          (setf last (enemies:enemy-frame e))))
      (is (= 10 changes) "fifty ticks at one step per five"))))

(test turrets-animate-once-and-hold
  "A turret walks its frames and stops on the last -- the original omits the wrap. The
   animation is it deploying, so it must not loop."
  (let* ((pool (full-enemy-pool))
         (def (enemies:definition pool "turret_light")))
    (when def
      ;; The shipped turret sprites are single-frame, so give this one frames to walk.
      (let ((e (enemies:spawn pool "turret_light" 100 20)))
        (setf (enemies::enemy-definition e)
              (enemies::%make-definition
               :name "test_turret" :kind :enemy-turret
               :sprite (theme:make-sprite
                        "t" 2 2 (make-array 12 :element-type '(unsigned-byte 32)
                                               :initial-element 0)
                        3)
               :movements '(:non-move)))
        (dotimes (i 100) (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)
                                              :world-x 0))
        (is (= 2 (enemies:enemy-frame e)) "reached the last frame and stopped")))))

(test turrets-stay-asleep-until-the-player-is-near
  "The gate is x < 120, so a turret still off the right edge holds frame zero."
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "turret_light" 200 20)))
    (setf (enemies::enemy-definition e)
          (enemies::%make-definition
           :name "test_turret" :kind :enemy-turret
           :sprite (theme:make-sprite
                    "t" 2 2 (make-array 12 :element-type '(unsigned-byte 32)
                                           :initial-element 0)
                    3)
           :movements '(:non-move)))
    (dotimes (i 60) (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)
                                         :world-x 0))
    (is (= 0 (enemies:enemy-frame e)) "still dormant at x=200")
    ;; Walk it in past the threshold.
    (setf (rect:rect-x (enemies:enemy-rect e)) 100)
    (dotimes (i 60) (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)
                                         :world-x 0))
    (is (plusp (enemies:enemy-frame e)) "and wakes once it is on screen")))

(test respawned-enemies-start-on-frame-zero
  "The pool reuses instances, so a stale frame must not carry over."
  (let* ((pool (full-enemy-pool)))
    (setf (enemies:pool-midboss-deaths pool) 10)
    (let ((e (enemies:spawn pool "boss_Gear" 200 60)))
      (dotimes (i 25) (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)))
      (setf (enemies:enemy-dead? e) t)
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4))
      (let ((e2 (enemies:spawn pool "enemy_ship_floogle" 200 60)))
        (is (= 0 (enemies:enemy-frame e2)))))))

;;; ---------------------------------------------------------------------------
;;; The chaser -- the thing behind you

(test the-chaser-exists-from-the-start
  "DSCEnemies::initTheme creates one directly. It is the only enemy the spawner never
   produces: boss_Chaser is in the config's `bosses` list so its definition loads, but
   in no spawn class's object_list, and its spawn_prob is 0."
  (with-game (lv)
    (let ((chaser (find enemies:*chaser-name*
                        (enemies:pool-live (dsc:descendant-enemies lv))
                        :key (lambda (e)
                               (enemies:definition-name (enemies:enemy-definition e)))
                        :test #'string=)))
      (is-true chaser "spawned at level load")
      (is (eq :pursue (enemies:enemy-movement chaser)))
      (is (> (enemies:enemy-health chaser) 9000)
          "over nine thousand -- 9001 configured, plus the usual difficulty bonus")
      (is (< (rect:rect-x (enemies:enemy-rect chaser)) 0) "waiting off the left edge"))))

(test the-chaser-is-never-reaped
  "Pursue is the one movement EnemyShipOffscreen refuses to touch, which is what lets it
   shadow the player indefinitely."
  (let ((pool (full-enemy-pool)))
    (let ((c (enemies:spawn pool enemies:*chaser-name* -90 120)))
      (is (eq :immune (enemies:offscreen-rule c)))
      (enemies:offscreen pool c)
      (is-false (enemies:enemy-dead? c)))))

(test the-chaser-closes-in-when-the-player-reverses
  "PursueMovement moves it RIGHT whenever the player's horizontal acceleration is
   negative -- so backing up is what brings it in. That is the check on retreating
   indefinitely: you can go back for a missed pickup, but not for ever."
  (with-original-rates
   (let* ((pool (full-enemy-pool))
         (c (enemies:spawn pool enemies:*chaser-name* -50 60))
         (player (rect:make-rect 30 60 9 4)))
    ;; Flying forward: it drifts back to its floor of -90 and stops there.
    (dotimes (i 60) (enemies:update pool :player-rect player :player-accel-x 20.0))
    (is (= -90 (rect:rect-x (enemies:enemy-rect c))) "settles at the floor")
    ;; Reversing: it comes after you.
    (dotimes (i 60) (enemies:update pool :player-rect player :player-accel-x -20.0))
    (is (> (rect:rect-x (enemies:enemy-rect c)) -90) "closing")
    (is (<= (rect:rect-x (enemies:enemy-rect c)) (+ 30 10))
        "but never past the player, which is where PursueMovement stops it"))))

(test the-chaser-is-not-gated-by-the-boss-counter
  "Its type is 4 -- DSC_OBJ_ENEMY_SHIP, not a boss -- despite the name, so the ten-
   midboss gate does not apply to it."
  (let ((pool (full-enemy-pool)))
    (is (eq :enemy-ship
            (enemies:definition-kind (enemies:definition pool enemies:*chaser-name*))))
    (is-true (enemies:spawn pool enemies:*chaser-name* -90 120)
             "spawns with the gate untouched")))

(test init-theme-resets-the-boss-gate
  (let ((pool (full-enemy-pool)))
    (setf (enemies:pool-midboss-count pool) 7
          (enemies:pool-midboss-deaths pool) 7)
    (enemies:init-theme pool)
    (is (= 0 (enemies:pool-midboss-count pool)))
    (is (= 0 (enemies:pool-midboss-deaths pool)))))

;;; ---------------------------------------------------------------------------
;;; Particles

(test enemies-spray-on-every-hit-not-just-the-fatal-one
  "That spray is the feedback telling you your shots are connecting; without it a hit
   that does not kill looks like a miss."
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_floogle" 100 60))
         (bursts '()))
    (setf (enemies:pool-emit pool)
          (lambda (x y type) (declare (ignore x y)) (push type bursts)))
    (enemies:hit pool e :player-bullet)
    (is-false (enemies:enemy-dead? e) "survivable")
    (is (equal '(:enemy) bursts) "and it sprayed anyway")))

(test a-killing-blow-sprays-and-bursts
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_floogle" 100 60))
         (bursts '()))
    (setf (enemies:pool-emit pool)
          (lambda (x y type) (declare (ignore x y)) (push type bursts))
          (enemies:pool-on-death pool)
          (lambda (enemy score) (declare (ignore enemy score)) (push :circle bursts)))
    (loop repeat 40 until (enemies:enemy-dead? e)
          do (enemies:hit pool e :player-bullet))
    (is (member :enemy bursts) "sprayed on the way")
    (is (member :circle bursts) "and burst at the end")))

(test turrets-do-not-spray
  "The turret branch of Enemy_Ship_Hit has no PARTICLE_ENEMY spew, only the burst."
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "turret_light" 100 20))
         (bursts '()))
    (when e
      (setf (enemies:pool-emit pool)
            (lambda (x y type) (declare (ignore x y)) (push type bursts)))
      (enemies:hit pool e :player-bullet)
      (is (null bursts)))))

(test midbosses-are-capped-concurrently
  "CHANGED FROM THE ORIGINAL, which has no concurrent limit: MAX_MIDBOSS_INSTANCE caps
   the total per level and is never decremented, so all ten arrive within about a second
   and stack into one cluster -- they all fly the same `infinity` spline, whose knots are
   absolute screen coordinates."
  (let ((pool (full-enemy-pool))
        (enemies:*max-concurrent-midbosses* 3))
    (dotimes (i 3)
      (is-true (enemies:spawn pool "boss_Omegablaster" (+ 200 i) 60) "midboss ~d" i))
    (is (= 3 (enemies:live-midbosses pool)))
    (is (null (enemies:spawn pool "boss_Omegablaster" 200 60))
        "the fourth waits until one dies")
    ;; Kill one and the next may come.
    (let ((victim (find :enemy-midboss (enemies:pool-live pool)
                        :key (lambda (e) (enemies:definition-kind
                                          (enemies:enemy-definition e))))))
      (setf (enemies:enemy-dead? victim) t)
      (enemies:update pool :player-rect (rect:make-rect 30 70 9 4)))
    (is (= 2 (enemies:live-midbosses pool)))
    (is-true (enemies:spawn pool "boss_Omegablaster" 200 60) "room again")))

(test the-total-of-ten-is-unchanged
  "The concurrent cap must not touch the gate that matters: it is still exactly ten
   midbosses per level, and the boss still waits for all ten to die."
  (let ((pool (full-enemy-pool))
        (enemies:*max-concurrent-midbosses* 2)
        (player (rect:make-rect 30 70 9 4))
        (spawned 0))
    ;; Spawn and immediately kill, over and over.
    (loop repeat 40
          do (when (enemies:spawn pool "boss_Omegablaster" 200 60)
               (incf spawned)
               (dolist (e (enemies:pool-live pool))
                 (setf (enemies:enemy-dead? e) t))
               (enemies:update pool :player-rect player)))
    (is (= enemies:+max-midboss-instances+ spawned) "ten and no more, ever")
    (is (= 10 (enemies:pool-midboss-deaths pool)))
    (is-true (enemies:spawn pool "boss_Gear" 200 60) "and the boss is unlocked")))

(test the-original-behaviour-is-still-available
  "Both concurrency caps lifted gives the original: ten midbosses alive together."
  (let ((pool (full-enemy-pool))
        (enemies:*max-concurrent-midbosses* enemies:+max-midboss-instances+)
        (enemies:*max-concurrent-per-definition* 0))
    (dotimes (i 10)
      (is-true (enemies:spawn pool "boss_Omegablaster" (+ 200 i) 60)))
    (is (= 10 (enemies:live-midbosses pool)) "all ten at once, as the original does")))

(test one-enemy-cannot-fill-the-pool
  "Measured failure: forty-four enemy_ship_floogle stacked at x 150-160. It flies `zag`,
   a spline whose knots are absolute screen coordinates, so every instance converges on
   the same column and parks there until shot -- never going offscreen, never reaped.
   Fifty of those and nothing else can spawn."
  (let ((pool (full-enemy-pool))
        (enemies:*max-concurrent-per-definition* 4))
    (dotimes (i 4)
      (is-true (enemies:spawn pool "enemy_ship_floogle" (+ 200 i) 60) "floogle ~d" i))
    (is (null (enemies:spawn pool "enemy_ship_floogle" 200 60)) "the fifth waits")
    ;; A different definition is unaffected -- the cap is per enemy, not global.
    (is-true (enemies:spawn pool "enemy_ship_bomber" 200 60))))

(test the-stage-three-spike-is-capped
  "The bridge and the stealth both fire shot 12, which bursts into bullets curling
   outward in loops. Several at once ring a player who is already being closed on."
  (is (= 4 (enemies:max-concurrent-for "enemy_midboss_bridge")))
  (is (= 3 (enemies:max-concurrent-for "enemy_ship_stealth")))
  (let ((pool (enemies:make-pool))
        (cfg (config:read-config (paths:config-path "level_brain_pain.cfg")))
        (th (theme:read-theme (paths:theme-path "brain_pain.thm"))))
    (enemies:load-definitions pool cfg th
                              (append (config:config-list cfg "level_data.bosses")
                                      (config:config-list cfg "level_data.enemy_ships")))
    (dotimes (i 3)
      (is-true (enemies:spawn pool "enemy_ship_stealth" (+ 200 i) 60) "stealth ~d" i))
    (is (null (enemies:spawn pool "enemy_ship_stealth" 200 60)) "the fourth waits")
    ;; The cap is on these two, not on everything.
    (is (= enemies:*max-concurrent-per-definition*
           (enemies:max-concurrent-for "boss_Battleship"))
        "everything else keeps the general cap")))

(test throttling-midbosses-must-not-stall-the-boss-gate
  "Tuned by play, and the direction is not the obvious one: throttling harder makes the
   game HARDER. The gate is ten midboss DEATHS, so a low concurrency does not reduce how
   many must be fought, only how slowly they arrive -- and every extra second spent
   clearing them is another second of the ordinary spawns still running."
  (is (> enemies:*max-concurrent-midbosses* 1)
      "more than one midboss may be alive at a time")
  (let ((pool (enemies:make-pool))
        (cfg (config:read-config (paths:config-path "level_brain_pain.cfg")))
        (th (theme:read-theme (paths:theme-path "brain_pain.thm")))
        (cap (min enemies:*max-concurrent-midbosses*
                  (enemies:max-concurrent-for "enemy_midboss_bridge"))))
    (enemies:load-definitions pool cfg th (config:config-list cfg "level_data.bosses"))
    ;; Two limits apply to a midboss and the smaller wins: its own override, and the
    ;; midboss gate that is checked for every midboss whatever the override says.
    (dotimes (i cap)
      (is-true (enemies:spawn pool "enemy_midboss_bridge" (+ 200 i) 60) "bridge ~d" i))
    (is (null (enemies:spawn pool "enemy_midboss_bridge" 200 60))
        "the ~dth is refused" (1+ cap))
    (is (= cap (enemies:pool-midboss-count pool))
        "and each one that got through spent budget toward the gate")))

(test the-two-midboss-limits-interact
  "Raising one without the other does nothing, which is easy to forget and wasted a
   playtest."
  (let ((enemies:*max-concurrent-midbosses* 2)
        (enemies:*max-concurrent-overrides* '(("enemy_midboss_bridge" . 9))))
    (let ((pool (enemies:make-pool))
          (cfg (config:read-config (paths:config-path "level_brain_pain.cfg")))
          (th (theme:read-theme (paths:theme-path "brain_pain.thm"))))
      (enemies:load-definitions pool cfg th (config:config-list cfg "level_data.bosses"))
      (dotimes (i 2) (enemies:spawn pool "enemy_midboss_bridge" (+ 200 i) 60))
      (is (null (enemies:spawn pool "enemy_midboss_bridge" 200 60))
          "the gate binds at 2 even though the override says 9"))))

(test concurrency-overrides-are-per-name
  (is (= enemies:*max-concurrent-per-definition*
         (enemies:max-concurrent-for "enemy_ship_floogle"))
      "a name with no override falls back to the general cap")
  (let ((enemies:*max-concurrent-overrides* '(("enemy_ship_floogle" . 2))))
    (is (= 2 (enemies:max-concurrent-for "enemy_ship_floogle")))))

(test the-per-definition-cap-does-not-consume-the-midboss-budget
  "A refused spawn must not count against the total of ten, or the boss would never
   unlock."
  (let ((pool (full-enemy-pool))
        (enemies:*max-concurrent-per-definition* 2))
    (dotimes (i 2) (enemies:spawn pool "boss_Omegablaster" (+ 200 i) 60))
    (is (= 2 (enemies:pool-midboss-count pool)))
    (dotimes (i 5) (enemies:spawn pool "boss_Omegablaster" 200 60))
    (is (= 2 (enemies:pool-midboss-count pool)) "refusals are not spent budget")))
