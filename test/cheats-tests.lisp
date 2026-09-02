(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; Cheat codes and the two other player additions. None of this is in the original --
;;;; the tests exist to pin behaviour we invented, not fidelity.

(defmacro with-clean-cheats (&body body)
  `(let ((cheats:*buffer* "")
         (cheats:*codes* cheats:*codes*)
         (player:*invincible?* nil))
     ,@body))

(test cheat-fires-on-the-exact-sequence
  (with-clean-cheats
    (is-false player:*invincible?*)
    (map nil #'cheats:feed "iddqd")
    (is-true player:*invincible?* "iddqd toggles invincibility")))

(test cheat-toggles-off-again
  (with-clean-cheats
    (map nil #'cheats:feed "iddqd")
    (map nil #'cheats:feed "iddqd")
    (is-false player:*invincible?*)))

(test cheat-tolerates-a-false-start
  "A rolling buffer rather than an index into the expected string, so a repeated prefix
   does not break the match: 'ididdqd' still ends in 'iddqd'."
  (with-clean-cheats
    (map nil #'cheats:feed "ididdqd")
    (is-true player:*invincible?*)))

(test cheat-ignores-intervening-typing
  (with-clean-cheats
    (map nil #'cheats:feed "iddq")
    (cheats:feed #\x)
    (cheats:feed #\d)
    (is-false player:*invincible?* "the sequence was broken")))

(test cheat-ignores-non-letters
  "Arrow keys and the fire button must not disturb a code in progress."
  (with-clean-cheats
    (map nil #'cheats:feed "idd")
    (cheats:feed #\Space)
    (cheats:feed #\1)
    (map nil #'cheats:feed "qd")
    (is-true player:*invincible?*)))

(test cheat-buffer-does-not-grow
  (with-clean-cheats
    (dotimes (i 500) (cheats:feed #\a))
    (is (<= (length cheats:*buffer*) cheats:*buffer-size*))))

(test cheat-is-case-insensitive
  (with-clean-cheats
    (map nil #'cheats:feed "IDDQD")
    (is-true player:*invincible?*)))

(test cheat-feed-reports-what-fired
  (with-clean-cheats
    (is (null (cheats:feed #\i)))
    (map nil #'cheats:feed "ddq")
    (is (equal "iddqd" (cheats:feed #\d)))))

(test invincibility-suppresses-damage-outright
  "Unlike the power-up, which lets the hit land and rolls it back. Suppressing means the
   damage particles never fire and the HUD never goes yellow, so the readouts stay
   honest about what is happening."
  (with-clean-cheats
    (let ((p (make-test-player))
          (bursts 0))
      (setf (player:player-emit p)
            (lambda (&rest r) (declare (ignore r)) (incf bursts)))
      (setf player:*invincible?* t)
      (player:hit p :enemy-ship)
      (player:hit p :enemy-boss)
      (is (= 150 (player:player-health p)) "no damage at all")
      (is (= 10 (player:player-shields p)) "and no shield spent")
      (is (= 0 bursts) "and no damage particles"))))

(test invincibility-does-not-block-pickups
  (with-clean-cheats
    (let ((p (make-test-player)))
      (setf player:*invincible?* t)
      (player:hit p :collectable :collectable-name "collect_spread")
      (is (plusp (player:player-spread p)) "power-ups still apply"))))

(test invincible-player-never-dies
  (with-clean-cheats
    (let ((p (make-test-player)))
      (setf player:*invincible?* t)
      (dotimes (i 200) (player:hit p :enemy-ship) (player:update p))
      (is (eq :play (player:player-status p)))
      (is (= 10 (player:player-shields p))))))

;;; ---------------------------------------------------------------------------
;;; The points pickup's shield refund

(test points-pickup-restores-shields
  "ADDED, not ported. Shields are otherwise unrecoverable -- you start with ten and only
   ever lose them -- so a long run ends on attrition however well it is played."
  (let ((p (make-test-player)))
    (setf (player:player-shields p) 4)
    (player:apply-collectable p "collect_points")
    (is (= 9000 (player:player-score p)) "still worth the points")
    (is (= (+ 4 (player:points-shield-refund)) (player:player-shields p)))))

(test points-pickup-cannot-overfill
  (let ((p (make-test-player)))
    (is (= 10 (player:player-shields p)) "starts full")
    (player:apply-collectable p "collect_points")
    (is (= 10 (player:player-shields p)) "capped at the maximum")))

(test points-refund-can-be-turned-off
  "Zero restores the original's score-only behaviour."
  (let ((player:*points-shield-refund* 0)
        (p (make-test-player)))
    (setf (player:player-shields p) 4)
    (player:apply-collectable p "collect_points")
    (is (= 4 (player:player-shields p)))))

;;; ---------------------------------------------------------------------------
;;; The FPS readout

(test fps-readout-updates
  "Reported bug: the readout never changed. The level was never passing a value at all,
   so the HUD had nothing to show."
  (let ((h (make-test-hud)))
    (hud:toggle-fps h)
    (hud:update h :fps 61.0)
    (let ((first (hud:hud-fps-sprite h)))
      (is (< (abs (- 61.0 (hud:hud-fps h))) 0.01))
      (hud:update h :fps 42.5)
      (is (< (abs (- 42.5 (hud:hud-fps h))) 0.01) "a new reading is taken")
      (is (not (eq first (hud:hud-fps-sprite h))) "and the sprite is rebuilt"))))

(test fps-readout-ignores-noise
  "The original only rebuilds when the value actually differs, and rebuilding a text
   sprite re-rasterises every cell."
  (let ((h (make-test-hud)))
    (hud:toggle-fps h)
    (hud:update h :fps 60.0)
    (let ((sprite (hud:hud-fps-sprite h)))
      (hud:update h :fps 60.0)
      (is (eq sprite (hud:hud-fps-sprite h)) "same reading, same sprite"))))

;;; ---------------------------------------------------------------------------
;;; Power-ups during invulnerability

(test the-points-pickup-heals-through-invulnerability
  "Invulnerability rolls DAMAGE back rather than preventing it, by restoring the health
   and shields it saw before the hit. The original can do that unconditionally because
   its collectable branch never touches either -- but ours heals now, so an unconditional
   rollback quietly ate the pickup. Which is exactly when you are most likely to be flying
   through things to grab it."
  (let ((p (make-test-player)))
    (setf (player:player-shields p) 4
          (player:player-invuln p) 300
          (player:player-status p) :invulnerable)
    (is-true (player:invulnerable? p))
    (player:hit p :collectable :collectable-name "collect_points")
    (is (= (+ 4 (player:points-shield-refund)) (player:player-shields p))
        "the shields stuck")
    (is (= 9000 (player:player-score p)) "and so did the score")))

(test damage-is-still-rolled-back-during-invulnerability
  (let ((p (make-test-player)))
    (setf (player:player-invuln p) 300
          (player:player-status p) :invulnerable)
    (player:hit p :enemy-boss)
    (is (= 150 (player:player-health p)))
    (is (= 10 (player:player-shields p)))))

(test other-powerups-still-apply-during-invulnerability
  (let ((p (make-test-player)))
    (setf (player:player-invuln p) 300
          (player:player-status p) :invulnerable)
    (player:hit p :collectable :collectable-name "collect_rapid")
    (is (plusp (player:player-rapid p)))))

(test the-cheat-also-lets-the-points-pickup-heal
  (with-clean-cheats
    (let ((p (make-test-player)))
      (setf player:*invincible?* t
            (player:player-shields p) 4)
      (player:hit p :collectable :collectable-name "collect_points")
      (is (= (+ 4 (player:points-shield-refund)) (player:player-shields p))))))
