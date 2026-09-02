(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-test-player ()
  (let ((th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (player:make-player (theme:find-sprite th "player"))))

(test player-starts-where-the-original-puts-it
  "player_init_theme: x = cols >> 3, y = (rows >> 1) + 10, size from the sprite."
  (let ((p (make-test-player)))
    (is (= 30 (rect:rect-x (player:player-rect p))) "240 >> 3")
    (is (= 70 (rect:rect-y (player:player-rect p))) "(120 >> 1) + 10")
    (is (= 9 (rect:rect-w (player:player-rect p))))
    (is (= 4 (rect:rect-h (player:player-rect p))))
    ;; minY = sprite height + 10, maxY = rows - 4
    (is (= 14 (player:player-min-y p)))
    (is (= 116 (player:player-max-y p)))
    (is (= 150 (player:player-health p)))
    (is (= 10 (player:player-shields p)))))

(test player-drifts-forward-with-no-input
  "PLAYER_DRIFT is added every tick regardless of input, so the ship always creeps
   right even when nothing is held."
  (let* ((p (make-test-player))
         (before (movement:movement-world-x (player:player-move p))))
    (dotimes (i 10) (player:update p))
    (is (> (movement:movement-world-x (player:player-move p)) before)
        "the ship should have moved right")))

(test player-up-and-down-move-vertically
  (let ((up (make-test-player))
        (down (make-test-player)))
    (dotimes (i 30)
      (player:update up :up? t)
      (player:update down :down? t))
    (is (> (rect:rect-y (player:player-rect up)) 70) "up increases Y")
    (is (< (rect:rect-y (player:player-rect down)) 70) "down decreases Y")))

(test player-y-is-clamped-to-the-play-area
  (let ((p (make-test-player)))
    (dotimes (i 400) (player:update p :up? t))
    (is (<= (rect:rect-y (player:player-rect p)) (player:player-max-y p)))
    (dotimes (i 800) (player:update p :down? t))
    (is (>= (rect:rect-y (player:player-rect p)) (player:player-min-y p)))))

(test player-left-flips-the-steering-angle
  "The original's 'cheap fix for backwards upward movement': reversing thrust while
   steering flips the vertical component so up still means up."
  (multiple-value-bind (dir speed) (player::%steer t nil nil nil)
    (is (< (abs (- player::+up+ dir)) 1e-6))
    (is (= 0.0 speed)))
  (multiple-value-bind (dir speed) (player::%steer t nil t nil)
    (is (< (abs (- player::+down+ dir)) 1e-6) "up + left flips to down")
    (is (= player::+backward-accel+ speed))))

(test player-laser-cooldown
  "Firing sets the cooldown; it only ticks down on frames the key is released."
  (with-original-rates
    (let ((p (make-test-player))
          (shots 0))
      (setf (player:player-fire-bullet p)
            (lambda (&rest args) (declare (ignore args)) (incf shots)))
      (dotimes (i 12) (player:update p :fire? t))
      (is (= 2 shots) "12 frames of held fire at a 5-frame cooldown gives 2 shots"))))

(test player-rapid-fire-bypasses-the-cooldown
  (let ((p (make-test-player))
        (shots 0))
    (setf (player:player-fire-bullet p)
          (lambda (&rest args) (declare (ignore args)) (incf shots))
          (player:player-rapid p) 100)
    (dotimes (i 10) (player:update p :fire? t))
    (is (= 10 shots) "rapid fire shoots every frame")))

(test player-spread-fires-seven-bullets
  (let ((p (make-test-player))
        (angles '()))
    (setf (player:player-fire-bullet p)
          (lambda (name angle x y) (declare (ignore name x y)) (push angle angles)))
    (player:fire-laser p)
    (is (= 1 (length angles)) "one bullet without the power-up")
    (setf angles '() (player:player-spread p) 100)
    (player:fire-laser p)
    (is (= 7 (length angles)) "straight ahead plus six spread angles")
    (is (member 0.0 angles :test #'=))))

(test player-bomb-arc-has-thirteen-knots
  "fire_bomb builds a 13-point spline whose downspeed decreases by 4 per knot."
  (let* ((p (make-test-player))
         (arc (player:bomb-arc p nil nil)))
    (is (= 13 (length arc)))
    ;; X advances by a constant step
    (let ((xs (mapcar #'car arc)))
      (is (every (lambda (d) (< (abs (- d 7)) 1e-4))
                 (loop for (a b) on xs while b collect (- b a)))))
    ;; Y turns over: rises then falls, since downspeed decreases each knot
    (let ((ys (mapcar #'cdr arc)))
      (is (> (first ys) (car (last ys))) "the bomb ends below where it started"))))

(test player-bomb-cooldown-depends-on-rapid
  (with-original-rates
    (let ((p (make-test-player))
          (bombs 0))
      (setf (player:player-fire-bomb p)
            (lambda (&rest args) (declare (ignore args)) (incf bombs)))
      (player:update p :bomb? t)
      (is (= 30 (player:player-bomb-limit p)))
      (setf (player:player-bomb-limit p) 0
            (player:player-rapid p) 100)
      (player:update p :bomb? t)
      (is (= 5 (player:player-bomb-limit p)) "rapid shortens the bomb cooldown"))))

(test player-damage-table-reproduces-the-fallthrough
  "The original's switch is missing breaks, so MIDBOSS falls through TURRET, BOMB and
   BULLET and the costs accumulate. Almost certainly a bug, but it is what the game was
   balanced against, so it is reproduced deliberately."
  (is (equal '(100 0) (multiple-value-list (player:damage-for :enemy-ship))))
  (is (equal '(200 1) (multiple-value-list (player:damage-for :enemy-boss))))
  (is (equal '(215 1) (multiple-value-list (player:damage-for :enemy-midboss)))
      "200 + 7 + 5 + 3")
  (is (equal '(15 0) (multiple-value-list (player:damage-for :enemy-turret)))
      "7 + 5 + 3")
  (is (equal '(8 0) (multiple-value-list (player:damage-for :enemy-bomb))) "5 + 3")
  (is (equal '(3 0) (multiple-value-list (player:damage-for :enemy-bullet))))
  (is (equal '(0 0) (multiple-value-list (player:damage-for :building)))
      "types not in the switch do nothing"))

(test player-takes-damage
  "The original's figures, with our contact scaling turned off."
  (with-original-rates
    (let ((p (make-test-player)))
      (player:hit p :enemy-bullet)
      (is (= 147 (player:player-health p)) "a bullet lands once and is gone")
      (player:hit p :enemy-ship)
      (is (= 47 (player:player-health p)))
      (player:hit p :enemy-ship)
      (is (= 0 (player:player-health p)) "health floors at zero, never negative"))))

(test contact-damage-is-frame-rate-independent
  "The collision manager calls `hit` on EVERY frame two rects overlap -- no debounce, no
   notion of a collision starting. Projectiles land once because they die on impact, but
   a body does not, so ramming costs its damage per FRAME. That made contact scale
   directly with the frame rate: the same overlap cost twice as much at 62.5 Hz as at the
   ~30 the original managed."
  (flet ((damage-over (ticks)
           (let ((p (make-test-player))
                 (player:*contact-damage-scale* 1.0))
             (setf (player:player-health p) 100000
                   (player:player-max-health p) 100000)
             (dotimes (i ticks) (player:hit p :enemy-ship))
             (- 100000 (player:player-health p)))))
    ;; One second of continuous contact, at each preset's tick rate.
    (let ((smooth (let ((state:*time-based-rates?* t) (state:*simulation-hz* 62.5))
                    (damage-over 62)))
          (original (let ((state:*time-based-rates?* nil) (state:*simulation-hz* 30.0))
                      (damage-over 30))))
      (is (< (abs (- smooth original)) (* 0.05 original))
          "a second of contact costs the same either way: ~d vs ~d" smooth original))))

(test contact-damage-carries-its-remainder
  "Dividing by the rate leaves fractions. Rounding down would make light contact free;
   rounding up would undo the correction. The remainder is carried instead."
  (let ((p (make-test-player))
        (player:*contact-damage-scale* 1.0)
        (state:*time-based-rates?* t)
        (state:*simulation-hz* 62.5))
    (setf (player:player-health p) 100000 (player:player-max-health p) 100000)
    ;; 3 damage per bullet is not a contact kind, but a turret at 15/frame over the
    ;; 2.083 factor gives 7.2 -- a fraction that must not be lost.
    (dotimes (i 100) (player:hit p :enemy-turret))
    (let ((taken (- 100000 (player:player-health p))))
      (is (< (abs (- taken 720)) 5) "100 frames of turret contact, got ~d" taken))))

(test contact-damage-can-be-scaled-down
  "Ramming costs 100 of 150 health, so brushing an enemy is close to fatal at any frame
   rate. The multiplier is separate from the frame-rate correction."
  (flet ((one-hit (scale)
           (let ((p (make-test-player))
                 (player:*contact-damage-scale* scale)
                 (state:*time-based-rates?* nil))
             (player:hit p :enemy-ship)
             (- 150 (player:player-health p)))))
    (is (= 100 (one-hit 1.0)) "the original's number")
    (is (= 50 (one-hit 0.5)) "halved")))

(test projectiles-are-not-contact
  "A bullet dies on impact, so it lands exactly once and must not be rescaled."
  (is (null (member :enemy-bullet player:*contact-kinds*)))
  (is (null (member :enemy-bomb player:*contact-kinds*)))
  (let ((p (make-test-player))
        (state:*time-based-rates?* t))
    (player:hit p :enemy-bullet)
    (is (= 147 (player:player-health p)) "full 3, whatever the rate")))

(test player-invulnerability-rolls-damage-back
  "pow_invuln does not prevent the hit; it restores health and shields afterwards."
  (let ((p (make-test-player)))
    (setf (player:player-invuln p) 100)
    (player:hit p :enemy-boss)
    (is (= 150 (player:player-health p)))
    (is (= 10 (player:player-shields p)))))

(test player-ignores-hits-while-dying
  (let ((p (make-test-player)))
    (setf (player:player-death-limit p) 2)
    (player:hit p :enemy-ship)
    (is (= 150 (player:player-health p)))))

(test player-collectables
  (with-original-rates
    (let ((p (make-test-player)))
      (player:hit p :collectable :collectable-name "collect_points")
      (is (= 9000 (player:player-score p)))
      (player:hit p :collectable :collectable-name "collect_spread")
      (is (= 300 (player:player-spread p)))
      (player:hit p :collectable :collectable-name "collect_invuln")
      (is (= 300 (player:player-invuln p)))
      (is (eq :invulnerable (player:player-status p)))
      ;; A collectable never costs health.
      (is (= 150 (player:player-health p))))))

(test player-powerups-expire
  (let ((p (make-test-player)))
    (setf (player:player-invuln p) 2
          (player:player-status p) :invulnerable)
    (player:update p)
    (is (= 1 (player:player-invuln p)))
    (player:update p)
    (is (= 0 (player:player-invuln p)))
    (is (eq :play (player:player-status p)) "status returns to play when it lapses")))

(test player-death-and-respawn
  (let ((p (make-test-player)))
    (setf (player:player-health p) 0)
    (player:update p)
    (is (= 9 (player:player-shields p)) "dying costs a shield")
    (is (plusp (player:player-death-limit p)))
    (dotimes (i 5) (player:update p))
    (is (= 0 (player:player-death-limit p)))
    (is (= 150 (player:player-health p)) "health restored after the death delay")))

(test player-dead-zone-pushes-the-ship-forward
  "The camera never scrolls backwards: max-x only grows, and a ship that falls more
   than DSC_MAX_DEAD_ZONE behind is pushed along to keep up."
  (let ((p (make-test-player)))
    (setf (player:player-max-x p) 5000)
    (setf (movement:movement-world-x (player:player-move p)) 1000.0)
    (player::%scroll-x p)
    (is (> (movement:movement-world-x (player:player-move p)) 1000.0)
        "the ship is dragged forward")
    (is (= 5000 (player:player-max-x p)) "max-x is unchanged by the push")))

(test player-cannot-reverse-past-the-start
  (let ((p (make-test-player)))
    (setf (movement:movement-world-x (player:player-move p)) -50.0
          (player:player-start-x p) 0)
    (player::%scroll-x p)
    (is (= 0.0 (movement:movement-world-x (player:player-move p))))
    (is (= 0.0 (movement:movement-vx (player:player-move p))))))

(test player-renders-at-its-rect
  (let ((p (make-test-player))
        (s (screen:make-screen)))
    (player:render p s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)) "the ship drew something")))

(test player-vertical-speed-is-independent-of-thrust
  "Reported bug: holding up+right climbed twice as fast as up alone.

   The original derives both axes from one direction and one scalar speed, and speed
   grows when left or right is held, so the vertical component grows with it. Decoupled
   by default: vertical depends only on up/down."
  (let ((player:*couple-vertical-to-thrust* nil))
    (flet ((ay (&rest held)
             (nth-value 1 (player:steer-acceleration
                           (member :up held) (member :down held)
                           (member :left held) (member :right held) 0.016))))
      (let ((up (ay :up)))
        (is (plusp up) "up climbs")
        (is (< (abs (- up (ay :up :right))) 1e-5) "up+right climbs at the same rate")
        (is (< (abs (- up (ay :up :left))) 1e-5) "and so does up+left")
        (is (< (abs (+ up (ay :down))) 1e-5) "down mirrors up")
        (is (< (abs (ay)) 1e-5) "no vertical input, no vertical motion")))))

(test player-horizontal-thrust-still-varies
  "Only the vertical was decoupled -- left and right must still change forward speed,
   and climbing must still cost a little of it.

   PLAYER_UP is 0.2*pi, a 36 degree tilt rather than straight up, so the original's
   `cos(direction)` leaves 81% of the thrust on the X axis while the ship climbs. That
   is symmetric between up and down and is not the reported bug, so it is kept: the fix
   is confined to the vertical component."
  (let ((player:*couple-vertical-to-thrust* nil))
    (flet ((ax (&rest held)
             (nth-value 0 (player:steer-acceleration
                           (member :up held) (member :down held)
                           (member :left held) (member :right held) 0.016))))
      (is (plusp (ax)) "drift alone still carries the ship forward")
      (is (> (ax :right) (ax)) "right accelerates")
      (is (minusp (ax :left)) "left reverses")
      (is (< (abs (- (ax :up) (* (cos player::+up+) (ax)))) 1e-5)
          "climbing tilts the thrust vector, as it always did")
      (is (< (abs (- (ax :up) (ax :down))) 1e-5) "and up and down cost the same"))))

(test player-original-coupling-can-be-restored
  "The original behaviour is kept available, and is exactly a doubling."
  (let ((player:*couple-vertical-to-thrust* t))
    (flet ((ay (&rest held)
             (nth-value 1 (player:steer-acceleration
                           (member :up held) (member :down held)
                           (member :left held) (member :right held) 0.016))))
      (is (< (abs (- (* 2 (ay :up)) (ay :up :right))) 1e-4)
          "up+right climbs at exactly twice the rate of up alone"))))

(test player-diagonal-still-moves-both-ways
  "Whichever mode, up+left must go up AND left -- the sign trap the original's
   'cheap fix' was there to avoid."
  (dolist (coupled '(nil t))
    (let ((player:*couple-vertical-to-thrust* coupled))
      (multiple-value-bind (ax ay)
          (player:steer-acceleration t nil t nil 0.016)
        (is (minusp ax) "up+left travels left (coupled=~a)" coupled)
        (is (plusp ay) "and upward (coupled=~a)" coupled)))))
