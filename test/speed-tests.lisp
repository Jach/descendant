(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; Game speed. ADDED, not ported -- see the commentary in state.lisp for why it has to
;;;; exist at all. The load-bearing claim these tests defend is that the two presets
;;;; produce the SAME pace and differ only in smoothness.

(defmacro with-preset ((name) &body body)
  `(let ((state:*speed-preset* state:*speed-preset*)
         (state:*simulation-hz* state:*simulation-hz*)
         (state:*time-based-rates?* state:*time-based-rates?*))
     (state:set-speed-preset ,name)
     ,@body))

(test presets-set-both-halves
  (with-preset (:smooth)
    (is (= 62.5 state:*simulation-hz*))
    (is-true state:*time-based-rates?*))
  (with-preset (:original)
    (is (= 30.0 state:*simulation-hz*))
    (is-false state:*time-based-rates?* "nothing is converted -- it IS the original")))

(test the-presets-agree-on-pace
  "The point of having both. A duration written in the original's ticks must come out as
   the same number of SECONDS under either preset -- one gets there by converting the
   count, the other by running the clock slower."
  (flet ((seconds (ticks)
           (/ (state:scale-ticks ticks) state:*simulation-hz*)))
    (dolist (ticks '(5 14 30 300))
      (let ((smooth (with-preset (:smooth) (seconds ticks)))
            (original (with-preset (:original) (seconds ticks))))
        (is (< (abs (- smooth original)) 0.02)
            "~d ticks: ~,3fs smooth vs ~,3fs original" ticks smooth original)))))

(test conversion-never-rounds-a-cooldown-to-zero
  "A cooldown of 0 means firing every single tick, which is the failure this exists to
   prevent -- so rounding must never produce one."
  (with-preset (:smooth)
    (dotimes (ticks 40)
      (when (plusp ticks)
        (is (plusp (state:scale-ticks ticks)) "~d ticks must stay positive" ticks))))
  (is (= 0 (state:scale-ticks 0)) "but a genuine zero passes through"))

(test conversion-is-identity-when-off
  (with-preset (:original)
    (dolist (ticks '(0 1 5 30 300))
      (is (= ticks (state:scale-ticks ticks))))))

(test cycling-wraps
  (with-preset (:smooth)
    (is (eq :original (state:cycle-speed-preset)))
    (is (eq :smooth (state:cycle-speed-preset)))))

(test the-loop-rate-follows-the-preset
  (with-preset (:smooth) (is (= 62.5 (level:logic-hz))))
  (with-preset (:original) (is (= 30.0 (level:logic-hz)))))

;;; ---------------------------------------------------------------------------
;;; What is and is not converted

(test enemy-cooldowns-are-converted
  "The reported complaint: enemies firing far faster than the original's pace."
  (let* ((pool (full-enemy-pool))
         (e (enemies:spawn pool "enemy_ship_floogle" 100 60))
         (fired 0))
    (setf (enemies:pool-fire-bullet pool)
          (lambda (&rest r) (declare (ignore r)) (incf fired) t))
    (flet ((shots-per-second (preset)
             (setf fired 0
                   (enemies::enemy-shoot-timers e) (make-array 10 :initial-element 0))
             (with-preset (preset)
               (dotimes (i (round state:*simulation-hz*))   ; one second of ticks
                 (enemies:fire-everything pool e :difficulty 2))
               fired)))
      (let ((smooth (shots-per-second :smooth))
            (original (shots-per-second :original)))
        (is (<= (abs (- smooth original)) 3)
            "same shots per second either way: ~d vs ~d" smooth original)))))

(test powerup-lifetimes-are-converted
  "Otherwise a power-up would last half as long in wall time as it used to."
  (flet ((seconds () (/ (player:powerup-duration) state:*simulation-hz*)))
    (let ((smooth (with-preset (:smooth) (seconds)))
          (original (with-preset (:original) (seconds))))
      (is (< (abs (- smooth original)) 0.1)
          "~,2fs vs ~,2fs" smooth original)
      (is (< 9.0 original 11.0) "about ten seconds, as 300 ticks at 30 Hz is"))))

(test the-player-is-converted-too
  "Scaling only the enemies' cooldowns would quietly hand the player twice the firepower
   relative to the original."
  (let ((p (make-test-player)))
    (with-preset (:smooth)
      (player:update p :bomb? t)
      (let ((smooth (player:player-bomb-limit p)))
        (setf (player:player-bomb-limit p) 0)
        (with-preset (:original)
          (player:update p :bomb? t)
          (is (> smooth (player:player-bomb-limit p))
              "more ticks at the higher rate, for the same wall-clock delay"))))))

(test animation-timing-is-deliberately-left-alone
  "Cosmetic timings are not converted: they look better at the higher rate, and chasing
   every timer in the game to fix a complaint about two of them is what :ORIGINAL is
   for. This pins the decision so it is not undone by accident."
  (with-preset (:smooth)
    (is (= 5 enemies:+animation-delta+))
    (is (= 450 dsc:+boss-death-delta+))
    (is (= 340 dsc:+warp-done-delta+))))
