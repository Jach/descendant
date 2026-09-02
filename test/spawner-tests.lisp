(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-test-spawner (&key create (seed 1234))
  (let ((cfg (config:read-config (paths:config-path "level_crash_site.cfg")))
        (th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (spawner:make-spawner cfg th
                          :create create
                          :ceiling-y 110
                          :ground-y 5
                          :random-state (sb-ext:seed-random-state seed))))

(defun collecting-spawner (&key (seed 1234))
  "A spawner that records what it would have created instead of creating it.
   Returns the spawner and a thunk yielding the log."
  (let ((entries '()))
    (values (make-test-spawner
             :seed seed
             :create (lambda (handler name x y) (push (list handler name x y) entries)))
            (lambda () (reverse entries)))))

(test spawner-loads-classes-from-config
  (let ((s (make-test-spawner)))
    (is (= 9 (length (spawner:spawner-classes s))) "spawn_class_count = 9")
    (let ((ships (find "spawn_enemy_ship" (spawner:spawner-classes s)
                       :key #'spawner:spawn-class-name :test #'string=)))
      (is-true ships)
      (is (= 3 (spawner:spawn-class-probability ships)))
      (is (= 400 (spawner:spawn-class-start ships)))
      (is (= 60 (spawner:spawn-class-delta ships)))
      (is (= 4 (length (spawner:spawn-class-objects ships)))))))

(test spawner-loads-object-orientation-and-weight
  (let* ((s (make-test-spawner))
         (ships (find "spawn_enemy_ship" (spawner:spawner-classes s)
                      :key #'spawner:spawn-class-name :test #'string=))
         (bomber (find "enemy_ship_bomber" (spawner:spawn-class-objects ships)
                       :key #'spawner:spawnable-name :test #'string=)))
    (is-true bomber)
    (is (eq :center (spawner:spawnable-orientation bomber)) "spawn_orient = 1")
    (is (= 3 (spawner:spawnable-probability bomber)) "spawn_prob = 3")
    (is (eq :enemy-ship (spawner:spawnable-kind bomber)))))

(test spawner-orientation-mapping
  (is (eq :ceiling (spawner:orientation 0)))
  (is (eq :center (spawner:orientation 1)))
  (is (eq :floor (spawner:orientation 2)))
  (is (eq :center-free (spawner:orientation 4)))
  (is (eq :unknown (spawner:orientation -1)))
  (is (eq :unknown (spawner:orientation 99))))

(test spawner-handler-dispatch
  "spawn's switch: object type decides which subsystem owns the new object."
  (is (eq :enemies (spawner:handler-kind :enemy-ship)))
  (is (eq :enemies (spawner:handler-kind :enemy-turret)))
  (is (eq :enemies (spawner:handler-kind :enemy-boss)))
  (is (eq :environment (spawner:handler-kind :building)))
  (is (eq :environment (spawner:handler-kind :mountain)))
  (is (eq :collectables (spawner:handler-kind :collectable)))
  (is (null (spawner:handler-kind :player)) "nothing owns the player")
  (is (null (spawner:handler-kind :no-collision))))

(test weighted-pick-respects-probabilities
  (let ((items '((:a . 3) (:b . 1)))
        (state (sb-ext:seed-random-state 7))
        (counts (make-hash-table)))
    (dotimes (i 4000)
      (let ((pick (spawner:pick-weighted items #'cdr state)))
        (incf (gethash (car pick) counts 0))))
    (let ((a (gethash :a counts)) (b (gethash :b counts)))
      (is (< 2700 a 3300) ":a should win about three quarters, got ~d" a)
      (is (< 700 b 1300) ":b should win about a quarter, got ~d" b))))

(test weighted-pick-with-no-weight-is-nil
  "The `modEdge < 1` early-out: a class whose objects all have zero probability."
  (is (null (spawner:pick-weighted '((:a . 0) (:b . 0)) #'cdr)))
  (is (null (spawner:pick-weighted '() #'cdr))))

(test spawner-gates-on-start-distance
  "A class does not fire before start_delta world columns have passed."
  (with-original-rates
    (let* ((s (make-test-spawner))
           (ships (find "spawn_enemy_ship" (spawner:spawner-classes s)
                        :key #'spawner:spawn-class-name :test #'string=)))
      (is-false (spawner:spawn-ready? s ships 100) "before start_delta 400")
      (is-true (spawner:spawn-ready? s ships 500) "after it"))))

(test spawner-gates-on-delta-since-last
  (with-original-rates
    (let* ((s (make-test-spawner))
           (ships (find "spawn_enemy_ship" (spawner:spawner-classes s)
                        :key #'spawner:spawn-class-name :test #'string=)))
      (setf (spawner:spawn-class-last-spawn-x ships) 1000)
      (is-false (spawner:spawn-ready? s ships 1030) "spawn_delta is 60")
      (is-true (spawner:spawn-ready? s ships 1100)))))

(test spawn-distances-stretch-with-the-clock
  "Distance accrues per TICK, so running at 62.5 Hz crosses the schedule twice as fast
   as the original's ~30 and meets twice as many enemies per second. Both gates stretch
   by the same factor the rates use, which puts the schedule back on the original's
   clock: START keeps the level the same length in wall time, DELTA keeps the encounter
   rate right."
  (let* ((s (make-test-spawner))
         (ships (find "spawn_enemy_ship" (spawner:spawner-classes s)
                      :key #'spawner:spawn-class-name :test #'string=)))
    (with-original-rates
      (is-true (spawner:spawn-ready? s ships 500) "opens at 400 unscaled"))
    (let ((state:*time-based-rates?* t)
          (state:*simulation-hz* 62.5))
      (is-false (spawner:spawn-ready? s ships 500)
                "but not yet when the schedule is stretched")
      (is-true (spawner:spawn-ready? s ships 900) "which takes about twice as far"))))

(test spawner-spawns-while-advancing
  (multiple-value-bind (s entries-of) (collecting-spawner)
    ;; Walk a long way so the gated classes open up.
    (loop for x from 0 to 3000 by 50
          for frame from 0 by 50
          do (spawner:update s x frame))
    (let ((entries (funcall entries-of)))
      (is (plusp (length entries)) "something spawned over 3000 columns")
      (is (every (lambda (e) (member (first e) '(:enemies :environment :collectables)))
                 entries)
          "every spawn went to a real handler"))))

(test spawner-does-not-spawn-while-stationary
  "SPAWN is distance-driven, so standing still produces no ordinary spawns -- only the
   special timer can fire, and only once its own start is passed."
  (multiple-value-bind (s entries-of) (collecting-spawner)
    (spawner:update s 100 0)                       ; establish progress
    (let ((before (length (funcall entries-of))))
      (dotimes (i 50) (spawner:update s 100 i))    ; same column, many frames
      (is (= before (length (funcall entries-of)))
          "no ordinary spawns without forward motion"))))

(test spawner-special-fires-on-a-frame-timer
  "spawn_special_start is 600 and spawn_special_delta 60, and unlike the main path this
   one counts frames, so hanging back still eventually draws enemies."
  (with-original-rates
    (multiple-value-bind (s entries-of) (collecting-spawner)
      (spawner:update s 700 0)                     ; get past special_start
      (let ((before (length (funcall entries-of))))
        (loop for frame from 1 to 400 do (spawner:update s 700 frame))
        (is (> (length (funcall entries-of)) before)
            "the special timer produced spawns while stationary")))))

(test spawner-spawn-x-fans-out-across-columns
  "Spawn X starts at the right screen edge and advances per column consumed, so a burst
   of columns in one tick spreads out instead of stacking."
  (multiple-value-bind (s entries-of) (collecting-spawner)
    (declare (ignore entries-of))
    (spawner:update s 0 0)
    (spawner:update s 10 1)
    (is (= 250 (spawner:spawner-spawn-world-x s))
        "240 plus the ten columns stepped")))

(test spawner-occupancy-blocks-overlapping-floor-spawns
  "The floor band records how far right it is claimed to, so a second floor object
   cannot go down until the first has scrolled past."
  (let* ((s (make-test-spawner))
         (th (theme:read-theme (paths:theme-path "crash_site.thm")))
         (object (spawner::%make-spawnable
                  :name "env_building_01" :sprite (theme:find-sprite th "building_01")
                  :kind :building :orientation :floor :probability 1)))
    (when (spawner:spawnable-sprite object)
      (let ((first-y (spawner:place s object 100)))
        (is-true first-y "the first floor object places")
        (is (null (spawner:place s object 101))
            "a second at the same spot is blocked by the claimed band")
        (is-true (spawner:place s object 10000)
                 "once far enough right the band is free again")))))

(test spawner-free-orientations-ignore-occupancy
  "The `-free` variants skip the band checks and always place."
  (let* ((s (make-test-spawner))
         (th (theme:read-theme (paths:theme-path "crash_site.thm")))
         (object (spawner::%make-spawnable
                  :name "x" :sprite (theme:find-sprite th "player")
                  :kind :enemy-ship :orientation :ceiling-free :probability 1)))
    (is (= 110 (spawner:place s object 100)) "ceiling-free sits at the ceiling")
    (is (= 110 (spawner:place s object 101)) "and again immediately")))

(test spawner-reset-clears-bands-and-progress
  (let ((s (make-test-spawner)))
    (spawner:update s 500 0)
    (spawner:reset s 0)
    (is (= 0 (spawner:spawner-max-world-x s)))
    (is (= -1 (spawner:spawner-ceiling-right s)))
    (is (= -1 (spawner:spawner-center-right s)))
    (is (= -1 (spawner:spawner-floor-right s)))
    (is (every (lambda (c) (zerop (spawner:spawn-class-last-spawn-x c)))
               (spawner:spawner-classes s)))))

(test spawner-is-reproducible-with-a-seed
  (flet ((run-once (seed)
           (multiple-value-bind (s entries-of) (collecting-spawner :seed seed)
             (loop for x from 0 to 2000 by 25
                   for frame from 0 by 25
                   do (spawner:update s x frame))
             (funcall entries-of))))
    (is (equal (run-once 99) (run-once 99)) "the same seed gives the same level")
    (is (not (equal (run-once 99) (run-once 100))) "a different seed does not")))
