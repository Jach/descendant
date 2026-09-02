(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The game level: does everything actually connect?

;;; WITH-GAME now lives in packages.lisp, which is the first file compiled -- test files
;;; earlier in the load order than this one were otherwise compiling it as a function
;;; call, since the macro did not exist yet.

(defun play-ticks (lv n &rest held)
  "Run N ticks with HELD actions pressed."
  (dolist (action held) (setf (gethash action (dsc:descendant-held lv)) t))
  (dotimes (i n)
    (level:update-level lv)
    (incf level:*frame*)))

(test descendant-replaces-the-placeholder
  "The real level must win the :descendant registration, so START from the menu now
   reaches a game rather than a stub."
  (is (eq 'com.thejach.descendant.level.descendant::descendant
          (gethash :descendant level::*registry*))))

(test descendant-builds-every-subsystem
  (with-game (lv)
    (is-true (dsc:descendant-player lv))
    (is-true (dsc:descendant-bullets lv))
    (is-true (dsc:descendant-enemies lv))
    (is-true (dsc:descendant-spawner lv))
    (is-true (dsc:descendant-environment lv))
    (is-true (dsc:descendant-collectables lv))
    (is-true (dsc:descendant-effects lv))
    (is-true (dsc:descendant-emitter lv))
    (is-true (dsc:descendant-hud lv))
    (is-true (dsc:descendant-world lv))))

(test descendant-player-band-comes-from-the-environment
  "The player is clamped to the environment's playable band, not the whole screen -- so
   the cave's ceiling actually confines the ship."
  (with-game (lv)
    (let ((p (dsc:descendant-player lv))
          (env (dsc:descendant-environment lv)))
      (is (>= (player:player-min-y p) (environment:floor-y env))
          "cannot fly into the ground")
      (is (< (player:player-max-y p) (environment:ceiling-y env))
          "cannot fly through the ceiling"))))

(test descendant-firing-reaches-the-bullet-pool
  "The player's fire hook is wired to the projectile pool."
  (with-game (lv)
    (is (= 0 (bullets:live-count (dsc:descendant-bullets lv))))
    (play-ticks lv 10 :fire)
    (is (plusp (bullets:live-count (dsc:descendant-bullets lv)))
        "holding fire produced projectiles")))

(test descendant-advancing-spawns-things
  "The spawner is distance-driven, so flying right eventually populates the level."
  (with-game (lv)
    (play-ticks lv 600 :right)
    (is (plusp (environment:scenery-count (dsc:descendant-environment lv)))
        "scenery appeared")
    (is (plusp (truncate (movement:movement-world-x
                          (player:player-move (dsc:descendant-player lv)))))
        "the player advanced")))

(test descendant-enemies-appear-and-can-be-killed
  "A long run with the trigger held should score, which requires the whole chain:
   spawner -> enemies -> collision -> bullets -> enemy death -> player score."
  (with-game (lv)
    (play-ticks lv 1500 :right :fire)
    (is (plusp (player:player-score (dsc:descendant-player lv)))
        "something died and paid out")))

(test descendant-collisions-are-registered
  "Everything that can be hit shares one collision world."
  (with-game (lv)
    (play-ticks lv 400 :right :fire)
    (is (plusp (collision:count-colliders (dsc:descendant-world lv)))
        "colliders are in the world")
    (is-true (player:player-collider (dsc:descendant-player lv))
             "including the player, so enemies and pickups can find it")))

(test descendant-pause-freezes-the-world
  (with-game (lv)
    (play-ticks lv 200 :right)
    (let ((before (truncate (movement:movement-world-x
                             (player:player-move (dsc:descendant-player lv))))))
      (dsc:toggle-pause lv)
      (dotimes (i 100) (level:update-level lv) (incf level:*frame*))
      (is (= before (truncate (movement:movement-world-x
                               (player:player-move (dsc:descendant-player lv)))))
          "nothing advanced while paused")
      (is-true (hud:hud-paused? (dsc:descendant-hud lv)) "and the banner is up")
      ;; Reported bug: the banner stayed up after unpausing.
      (dsc:toggle-pause lv)
      (is-false (dsc:descendant-paused? lv))
      (is-false (hud:hud-paused? (dsc:descendant-hud lv)) "and it comes back down")
      (play-ticks lv 10 :right)
      (is (/= before (truncate (movement:movement-world-x
                                (player:player-move (dsc:descendant-player lv)))))
          "and the world starts moving again"))))

(test descendant-hud-follows-the-player
  (with-game (lv)
    (play-ticks lv 300 :right :fire)
    (let ((p (dsc:descendant-player lv))
          (h (dsc:descendant-hud lv)))
      (is (= (player:player-score p) (hud:hud-score h)))
      (is (= (player:player-health p) (hud:hud-health h))))))

(test descendant-renders-a-full-frame
  (with-game (lv)
    (play-ticks lv 500 :right :fire)
    (let ((s (screen:make-screen)))
      (level:render-level lv s)
      (screen:composite s)
      (is (notevery #'zerop (screen:screen-cells s)))
      ;; The ground strip runs along the bottom of the screen.
      (is (notevery #'zerop (loop for x below screen:+cols+
                                  collect (screen:cell-ref s x (1- screen:+rows+))))
          "the ground drew"))))

(test descendant-all-three-themes-load
  "Each game theme has to supply a player sprite and its own config. This is what the
   warp hole will switch between."
  (dolist (key '(:crash-site :hidden-cave :brain-pain))
    (multiple-value-bind (theme-file config-file) (dsc:theme-files key)
      (let ((th (theme:read-theme (paths:theme-path theme-file)))
            (cfg (config:read-config (paths:config-path config-file))))
        (is-true (theme:find-sprite th "player") "~a has a player sprite" key)
        (is-true (config:config-list cfg "level_data.enemy_ships")
                 "~a lists enemies" key)))))

(test descendant-survives-a-long-run
  "A soak: nothing should error and no pool should run away over 3000 ticks."
  (with-game (lv)
    (finishes (play-ticks lv 3000 :right :fire))
    (is (<= (bullets:live-count (dsc:descendant-bullets lv)) 512)
        "the projectile pool stayed bounded")
    (is (<= (enemies:live-count (dsc:descendant-enemies lv)) 50)
        "the enemy pool stayed bounded")))
