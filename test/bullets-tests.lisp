(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-test-pool (&key world (max 64))
  (let ((pool (bullets:make-pool :world world :max max))
        (cfg (config:read-config (paths:config-path "level_crash_site.cfg")))
        (th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (bullets:load-definitions pool cfg th
                              (config:config-list cfg "level_data.bombs_bullets"))
    pool))

(test bullets-definitions-come-from-config
  "Each `[name] sprite= type=` section becomes a definition; the type number maps onto
   the DSCObjectType enum."
  (let ((pool (make-test-pool)))
    (let ((d (bullets:definition pool "player_ship_bullet")))
      (is-true d)
      (is (eq :player-bullet (bullets:definition-kind d)))
      (is (= 2 (theme:sprite-width (bullets:definition-sprite d)))))
    (is (eq :player-bomb
            (bullets:definition-kind (bullets:definition pool "player_ship_bomb"))))
    (is (eq :enemy-bullet
            (bullets:definition-kind (bullets:definition pool "enemy_ship_bullet"))))
    (is (eq :enemy-bomb
            (bullets:definition-kind (bullets:definition pool "enemy_ship_bomb"))))))

(test bullets-object-type-mapping
  (is (eq :no-collision (bullets:object-type 0)))
  (is (eq :player (bullets:object-type 1)))
  (is (eq :enemy-boss (bullets:object-type 14)))
  (is (eq :enemy-midboss (bullets:object-type 15)))
  (is (eq :no-collision (bullets:object-type 99)) "unknown numbers are inert"))

(test bullets-fire-and-travel
  "A bullet's velocity is set once and never changes: acceleration at speed 10000 with
   dt 0.016 through a drag of 1.0 copies straight into velocity, giving 2.56 cells per
   tick along the angle."
  (with-original-rates
    (let* ((pool (make-test-pool))
           (p (bullets:fire pool "player_ship_bullet" 0.0 50 60)))
      (is-true p)
      (is (= 1 (bullets:live-count pool)))
      (is (= 50 (rect:rect-x (bullets:projectile-rect p))))
      (bullets:update pool)
      (is (= 52 (rect:rect-x (bullets:projectile-rect p)))
          "2.56 cells per tick, truncated")
      (bullets:update pool)
      (is (= 55 (rect:rect-x (bullets:projectile-rect p)))))))

(defun %seconds-to-cross (name)
  (let* ((pool (make-test-pool))
         (p (bullets:fire pool name 0.0 0 60)))
    (loop for tick from 1 to 100000
          do (bullets:update pool)
          while (bullets:projectile-rect p)
          when (>= (rect:rect-x (bullets:projectile-rect p)) 200)
            do (return (/ tick state:*simulation-hz*)))))

(test enemy-bullets-cross-at-the-original-speed
  "A projectile advances by velocity * timestep per TICK, so at 62.5 Hz it covered twice
   the ground per second it did at the ~30 the original managed. Enemy fire arriving in
   half the time is most of what makes a dense pattern unreadable -- stage two's cannon
   throws five heavy shots a volley and was simply unreadable."
  (let ((smooth (let ((state:*time-based-rates?* t) (state:*simulation-hz* 62.5))
                  (%seconds-to-cross "enemy_ship_bullet")))
        (original (let ((state:*time-based-rates?* nil) (state:*simulation-hz* 30.0))
                    (%seconds-to-cross "enemy_ship_bullet"))))
    (is (< (abs (- smooth original)) (* 0.1 original))
        "~,2fs vs ~,2fs" smooth original)))

(test the-players-own-shots-are-exempt
  "Deliberately asymmetric, and NOT the original's behaviour -- there, everything moved
   at whatever the frame rate gave. Slowing the player's shots along with the enemies'
   reads as a nerf rather than a fix: the shot leaves the nose at half the speed, so it
   takes longer to reach anything, and the game feels less responsive even though the
   fire rate is unchanged."
  (let ((state:*time-based-rates?* t)
        (state:*simulation-hz* 62.5))
    (let ((player (%seconds-to-cross "player_ship_bullet"))
          (enemy (%seconds-to-cross "enemy_ship_bullet")))
      (is (< player enemy)
          "the player's shot arrives sooner: ~,2fs vs ~,2fs" player enemy)))
  ;; And the exemption is switchable.
  (let ((state:*time-based-rates?* t)
        (state:*simulation-hz* 62.5)
        (bullets:*slow-player-shots?* t))
    (let ((player (%seconds-to-cross "player_ship_bullet"))
          (enemy (%seconds-to-cross "enemy_ship_bullet")))
      (is (< (abs (- player enemy)) 0.05)
          "with the flag set, both are treated alike"))))

(test bullets-angle-affects-direction
  (let* ((pool (make-test-pool))
         (up (bullets:fire pool "player_ship_bullet" (float (/ pi 4) 1.0) 50 60)))
    (dotimes (i 5) (bullets:update pool))
    (is (> (rect:rect-y (bullets:projectile-rect up)) 60)
        "a positive angle sends the bullet upward")))

(test bullets-pool-is-bounded
  "Firing past the pool size drops the shot rather than growing."
  (let ((pool (make-test-pool :max 3)))
    (dotimes (i 5) (bullets:fire pool "player_ship_bullet" 0.0 10 60))
    (is (= 3 (bullets:live-count pool)))
    (is (null (bullets:pool-free pool)))))

(test bullets-unknown-name-warns
  (let ((pool (make-test-pool)))
    (handler-bind ((warning #'muffle-warning))
      (is (null (bullets:fire pool "no_such_bullet" 0.0 10 10))))))

(test bullets-die-offscreen-and-are-recycled
  (let* ((world (collision:make-world))
         (pool (make-test-pool :world world))
         (p (bullets:fire pool "player_ship_bullet" 0.0 (- screen:+cols+ 2) 60)))
    (dotimes (i 5)
      (collision:check-collisions world)
      (bullets:update pool))
    (is (= 0 (bullets:live-count pool)) "the bullet left the world and was reaped")
    (is (member p (bullets:pool-free pool)) "its slot went back to the free list")
    (is (= 0 (collision:count-colliders world)) "and its collider was unregistered")))

(test bullets-collision-rules
  "COLLIDE_hit: projectiles pass through each other and through collectables, and never
   die on their own side."
  ;; player shots
  (is-true (bullets:should-die? :player-bullet :enemy-ship))
  (is-true (bullets:should-die? :player-bomb :building))
  (is-false (bullets:should-die? :player-bullet :player) "player shots ignore the player")
  (is-false (bullets:should-die? :player-bullet :enemy-bullet) "shots pass through shots")
  (is-false (bullets:should-die? :player-bullet :collectable))
  ;; enemy shots
  (is-true (bullets:should-die? :enemy-bullet :player))
  (is-true (bullets:should-die? :enemy-bullet :building))
  (is-false (bullets:should-die? :enemy-bullet :enemy-ship) "enemy shots ignore enemies")
  (is-false (bullets:should-die? :enemy-bomb :enemy-boss))
  (is-false (bullets:should-die? :enemy-bullet :no-collision)))

(test bullets-hit-marks-dead
  (let* ((pool (make-test-pool))
         (p (bullets:fire pool "player_ship_bullet" 0.0 50 60)))
    (bullets:hit p :enemy-bullet)
    (is-false (bullets:projectile-dead? p) "passes through another projectile")
    (bullets:hit p :enemy-ship)
    (is-true (bullets:projectile-dead? p))
    (bullets:update pool)
    (is (= 0 (bullets:live-count pool)) "reaped on the next update")))

(test bombs-follow-a-spline
  "A bomb walks its Catmull-Rom path a step at a time rather than moving ballistically."
  (let* ((pool (make-test-pool))
         (arc (loop for i from 0 below 13
                    collect (cons (+ 50.0 (* i 7.0)) (- 60.0 (* i i 0.5)))))
         (b (bullets:fire-spline pool "player_ship_bomb" arc 0.135)))
    (is-true b)
    (is-true (bullets:projectile-spline b))
    (let ((start-x (rect:rect-x (bullets:projectile-rect b))))
      (dotimes (i 10) (bullets:update pool))
      (is (> (rect:rect-x (bullets:projectile-rect b)) start-x)
          "the bomb advanced along its arc"))))

(test bombs-die-at-the-end-of-the-spline
  "next-point returns a zero vector once the path is exhausted, and the original treats
   a non-positive X as the end."
  (let* ((pool (make-test-pool))
         (arc (loop for i from 0 below 13 collect (cons (+ 50.0 (* i 3.0)) 60.0)))
         (b (bullets:fire-spline pool "player_ship_bomb" arc 0.5)))
    (declare (ignore b))
    (loop repeat 200
          until (zerop (bullets:live-count pool))
          do (bullets:update pool))
    (is (= 0 (bullets:live-count pool)) "the bomb reached the end and was reaped")))

(test bombs-use-the-players-arc
  "player:bomb-arc feeds fire-spline directly, so the two agree on shape."
  (let* ((pool (make-test-pool))
         (th (theme:read-theme (paths:theme-path "crash_site.thm")))
         (p (player:make-player (theme:find-sprite th "player")))
         (arc (player:bomb-arc p nil nil))
         (b (bullets:fire-spline pool "player_ship_bomb" arc 0.135)))
    (is (= 13 (length arc)))
    (is-true b)
    (finishes (dotimes (i 20) (bullets:update pool)))))

(test bullets-render-enqueues-live-projectiles
  (let ((pool (make-test-pool))
        (s (screen:make-screen)))
    (bullets:fire pool "player_ship_bullet" 0.0 50 60)
    (bullets:render pool s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)))))

(test player-firing-drives-the-pool
  "The player's fire-bullet hook wired to the pool: pressing fire creates projectiles."
  (let* ((pool (make-test-pool))
         (th (theme:read-theme (paths:theme-path "crash_site.thm")))
         (p (player:make-player (theme:find-sprite th "player"))))
    (setf (player:player-fire-bullet p)
          (lambda (name angle x y) (bullets:fire pool name angle x y)))
    (player:update p :fire? t)
    (is (= 1 (bullets:live-count pool)))
    ;; With spread up, one press yields seven.
    (setf (player:player-spread p) 100
          (player:player-laser-limit p) 0)
    (player:update p :fire? t)
    (is (= 8 (bullets:live-count pool)) "1 + 7")))
