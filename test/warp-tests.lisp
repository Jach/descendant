(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The warp hole: dsc_warp_hole.c, plus the end-of-level sequence that drives it.

(defun make-marked-screen (&key (glyph #x41))
  "A screen whose back buffer holds a recognisable pattern, so we can tell whether the
   warp is really recycling the previous frame or inventing content."
  (let ((s (screen:make-screen)))
    (dotimes (i (length (screen:screen-back s)) s)
      (setf (aref (screen:screen-back s) i) (+ glyph (mod i 7))))))

(defun warp-buffer (w)
  (theme:sprite-glyphs (svref (warp:warp-sprites w) (warp:warp-current w))))

(defun run-warp (w screen n)
  "N frames of the entity's update/render pair, in the engine's order."
  (dotimes (i n w)
    (warp:update w screen)
    (warp:render w screen)))

(test warp-begins-inactive
  (let ((w (warp:make-warp)))
    (is (eq :inactive (warp:warp-state w)))
    (is-false (warp:active? w))))

(test warp-begin-sets-up-the-original-geometry
  "beginWarp( cols>>1, rows>>1, 3, 8, 54 ). Both radii are integer-divided by the circle
   count before they become floats, so 8/3 is 2 and not 2.67."
  (let ((w (warp:make-warp)))
    (warp:begin w 120 60 3 8 54)
    (is (eq :no-image (warp:warp-state w)))
    (is-true (warp:active? w))
    (is (= 2.0 (warp:warp-radius w)) "8/3 truncated")
    (is (= 2.0 (warp:warp-init-radius w)) "both radii start together")
    (is (= 1 (warp:warp-active-frame w)) "the original starts the count at one")
    (is (= 2 (length (warp:warp-sprites w))) "double buffered")))

(test warp-seeds-itself-from-the-back-buffer
  "The effect never draws source art. It clears the back buffer, lets one frame compose
   into it, then copies THAT into both of its own buffers -- everything afterwards is a
   transform of what was already on screen."
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    ;; Frame one: update does nothing but count, render asks for the clear.
    (warp:update w s)
    (is (= 2 (warp:warp-active-frame w)))
    (warp:render w s)
    (is-true (screen:screen-clear-back? s) "clear requested")
    (is (eq :snapshot (warp:warp-state w)))
    ;; Frame two: the copy happens, and it is the back buffer that is copied.
    (warp:update w s)
    (is (eq :active (warp:warp-state w)))
    (is (find (aref (screen:screen-back s) 0) (warp-buffer w))
        "the marker pattern made it into the warp's buffers")))

(test warp-boil-only-touches-a-disc
  "Phase one churns a disc around the centre and leaves the rest of the screen alone."
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (run-warp w s 2)                      ; through the seeding
    (let ((before (copy-seq (warp-buffer w))))
      (run-warp w s 1)
      (let ((after (warp-buffer w)))
        ;; A corner is far outside any radius the boil ever reaches.
        (is (= (aref before 0) (aref after 0)) "top-left corner untouched")
        (is (= (aref before (1- (length after))) (aref after (1- (length after))))
            "bottom-right corner untouched")))
    ;; And the disc grows, asymptotically toward max-radius.
    (let ((r (warp:warp-init-radius w)))
      (run-warp w s 1)
      (is (> (warp:warp-init-radius w) r) "the boil widens")
      (is (< (warp:warp-init-radius w) 18.0) "but never reaches 54/3 in 45 frames"))))

(test warp-switches-to-the-swirl-at-frame-45
  "WARP_INITIAL_ANIM_FRAMES. The two phases use different radii, so the disc visibly
   snaps back to its starting size at the changeover -- reproduced, not fixed."
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (run-warp w s 44)
    (is (>= (warp:warp-active-frame w) warp:+boil-frames+))
    (is (> (warp:warp-init-radius w) 10.0) "the boil got most of the way out")
    (is (= 2.0 (warp:warp-radius w)) "while the swirl radius has not moved at all")
    (run-warp w s 1)
    (is (= 2.15 (warp:warp-radius w)) "now it starts growing, at 0.15 a frame")))

(test warp-swirl-grows-to-the-maximum-and-stops
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (run-warp w s 300)
    (is (<= 18.0 (warp:warp-radius w) 18.15) "capped at 54/3")))

(test warp-swirl-rotates-the-image
  "The transform is a rotation, so a cell inside the vortex should generally end up
   holding a glyph from somewhere else."
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (run-warp w s 50)
    (let ((changed 0))
      (let ((before (copy-seq (warp-buffer w))))
        (run-warp w s 1)
        (let ((after (warp-buffer w)))
          (dotimes (i (length after))
            (unless (= (aref before i) (aref after i)) (incf changed)))))
      (is (plusp changed) "the swirl moved something"))))

(test warp-finish-releases-the-buffers
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (run-warp w s 5)
    (warp:finish w)
    (is (eq :inactive (warp:warp-state w)))
    (is-false (warp:warp-sprites w))
    (is (= 0 (warp:warp-active-frame w)))
    ;; Inactive means genuinely inert, not merely hidden.
    (warp:update w s)
    (warp:render w s)
    (is (eq :inactive (warp:warp-state w)))))

(test warp-snapshot-reseeds-from-the-screen
  "snapshot() is how the ship gets swallowed: it folds whatever is on screen -- ship
   included -- back into the warp's buffers."
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (run-warp w s 60)
    (warp:snapshot w)
    (is (eq :clear (warp:warp-state w)))
    ;; The clear is requested and the state advances, same shape as the initial seeding.
    (warp:update w s)
    (warp:render w s)
    (is-true (screen:screen-clear-back? s))
    (is (eq :snapshot (warp:warp-state w)))
    ;; Give it a fresh pattern and confirm it is picked up.
    (fill (screen:screen-back s) #x5A)
    (warp:update w s)
    (is (eq :active (warp:warp-state w)))
    (is (every (lambda (g) (= g #x5A)) (warp-buffer w))
        "reseeded wholesale from the new screen")))

(test warp-render-in-the-snapshot-state-does-not-abort
  "The original returns FALSE here, which the engine treats as a fatal render error and
   quits the game. It is unreachable in normal play -- update always converts :SNAPSHOT
   to :ACTIVE first -- but pausing skips the scene update, so pausing during the warp
   killed it. We draw nothing instead."
  (let ((w (warp:make-warp))
        (s (make-marked-screen)))
    (warp:begin w 120 60 3 8 54)
    (warp:update w s)
    (warp:render w s)
    (is (eq :snapshot (warp:warp-state w)))
    (finishes (warp:render w s))
    (is (eq :snapshot (warp:warp-state w)) "and the state is left alone")))

(test warp-centre-row-artifact-is-switchable
  "The original leaves a band on the nine centre rows unwritten, from a loop that never
   advances its point. Both behaviours must at least run."
  (dolist (artifact '(t nil))
    (let ((warp:*centre-row-artifact* artifact)
          (w (warp:make-warp))
          (s (make-marked-screen)))
      (warp:begin w 120 60 3 8 54)
      (finishes (run-warp w s 60)))))

;;; ---------------------------------------------------------------------------
;;; The end-of-level sequence

(defun kill-the-boss (lv)
  "Reach into the enemy pool the way a fatal hit would, without needing a real boss."
  (player:defeat-boss (dsc:descendant-player lv)))

(test warp-boss-death-starts-the-sequence
  (with-game (lv)
    (play-ticks lv 2)
    (kill-the-boss lv)
    (is (eq :boss-defeated (player:player-status (dsc:descendant-player lv))))
    (play-ticks lv 1)
    (is-true (warp:active? (dsc:descendant-warp lv)) "the vortex opened")
    (is (= 1 (dsc:descendant-trigger-frame lv)))))

(test warp-ship-is-reeled-to-the-centre-and-swallowed
  "The pull starts after 80 idle frames and eases in, floored so it cannot stall. The
   ship is at column 30 and the vortex at 120."
  (with-game (lv)
    (play-ticks lv 2)
    (let* ((p (dsc:descendant-player lv))
           (start-x (rect:rect-x (player:player-rect p))))
      (kill-the-boss lv)
      (play-ticks lv 80)
      (is (= start-x (rect:rect-x (player:player-rect p)))
          "nothing moves during the delay")
      (play-ticks lv 40)
      (is (> (rect:rect-x (player:player-rect p)) start-x) "then it is drawn in")
      ;; It arrives well before the level ends.
      (play-ticks lv 260)
      (is-true (dsc:descendant-swallowed? lv) "the ship reached the vortex")
      (is (< (abs (- 120 (rect:rect-x (player:player-rect p)))) 10)
          "and stopped within the arrival radius"))))

(test warp-hands-over-to-the-next-theme
  "DSC_BOSS_DEATH_DELTA frames after the boss dies, the next theme is requested. The
   themes cycle rather than ending, which is why the shipped game loops forever."
  (with-game (lv)
    (play-ticks lv 2)
    (is (eq :crash-site (dsc:descendant-theme-key lv)))
    (kill-the-boss lv)
    (play-ticks lv 449)
    (is-true (warp:active? (dsc:descendant-warp lv)) "still warping one frame short")
    (is (eq :crash-site (dsc:descendant-theme-key lv)))
    (play-ticks lv 2)
    (is (eq :hidden-cave (dsc:descendant-theme-key lv)) "on to level two")
    (is (eq :descendant level:*requested*) "and the level reloads")
    (is-false (warp:active? (dsc:descendant-warp lv)) "the vortex was torn down")))

(test warp-theme-order-wraps
  "The advance goes through STATE, not the level object: requesting a switch tears the
   instance down and builds a fresh one, so a theme stored on the level would be
   discarded and the game would replay crash_site forever."
  (let ((state:*theme* :crash-site))
    (is (eq :hidden-cave (state:advance-theme)))
    (is (eq :brain-pain (state:advance-theme)))
    (is (eq :crash-site (state:advance-theme))
        "DSC_INITIAL_THEME again -- there is no fourth level")))

(test new-level-instance-picks-up-the-advanced-theme
  "The actual regression: a fresh instance must start on whatever the last one set."
  (let ((state:*theme* :hidden-cave)
        (audio:*muted?* t)
        (level:*frame* 0) (level:*state* :play) (level:*current* nil)
        (level:*screen* (screen:make-screen)))
    (unwind-protect
         (progn
           (level:start-level :descendant)
           (is (eq :hidden-cave (dsc:descendant-theme-key level:*current*))))
      (level:shutdown))))

(test warp-suspends-the-spawner-and-the-scenery
  "Enemies, the spawner and collectables stop for good; bullets, particles and the ship
   keep running, which is what still feeds the swirl.

   'Stop' means stop being ticked, not get destroyed -- the original unregisters the
   entities from the scene and leaves the objects, and their colliders, where they are.
   We do the same, so anything still alive when the boss died simply freezes and stops
   being drawn.

   The scenery is a special case worth being explicit about: it is NOT unregistered, but
   ENV_update returns early on :BOSS-DEFEATED, so the world holds still anyway. The stop
   comes from the state check rather than the scene graph."
  (with-game (lv)
    (play-ticks lv 200)
    (let ((spawned (spawner:spawner-max-world-x (dsc:descendant-spawner lv)))
          (alive (enemies:live-count (dsc:descendant-enemies lv))))
      (kill-the-boss lv)
      (play-ticks lv 100)
      (is (= spawned (spawner:spawner-max-world-x (dsc:descendant-spawner lv)))
          "the spawner is frozen")
      (is (= alive (enemies:live-count (dsc:descendant-enemies lv)))
          "survivors are frozen rather than reaped"))
    (let ((scroll (gethash :fg-01 (environment::environment-scroll
                                   (dsc:descendant-environment lv)))))
      (play-ticks lv 30)
      (is (= scroll (gethash :fg-01 (environment::environment-scroll
                                     (dsc:descendant-environment lv))))
          "the scenery holds still, by its own state check"))))

(test warp-renders-a-whole-frame
  (with-game (lv)
    (play-ticks lv 5)
    (kill-the-boss lv)
    (play-ticks lv 120)
    (let ((s level:*screen*))
      (finishes (level:render-level lv s))
      (screen:composite s)
      (is (notevery #'zerop (screen:screen-cells s)) "something was drawn"))))

;;; ---------------------------------------------------------------------------
;;; The static field and the death sequence

(defun run-static-field (sf screen n)
  (dotimes (i n sf)
    (static-field:update sf screen)
    (static-field:render sf screen)))

(test static-field-is-the-boil-with-a-different-radius
  "dsc_static_field.c is dsc_warp_hole.c with the swirl removed -- its file header still
   says 'Purpose: Warp Hole effect for end of level'. Same state machine, same seeding,
   same kernel; only the radius schedule differs, growing 0.65 a frame from five."
  (let ((sf (static-field:make-static-field))
        (s (make-marked-screen)))
    (static-field:begin sf 30 70 5)
    (is (= 5.0 (static-field:static-field-radius sf)))
    (is (eq :no-image (static-field:state sf)))
    (run-static-field sf s 2)                     ; through the seeding
    (is (eq :active (static-field:state sf)))
    ;; The first frame is :NO-IMAGE and only counts -- there is nothing to churn yet --
    ;; so two frames in there has been exactly one step of growth.
    (is (< (abs (- 5.65 (static-field:static-field-radius sf))) 1e-4))
    (run-static-field sf s 1)
    (is (< (abs (- 6.3 (static-field:static-field-radius sf))) 1e-4)
        "then 0.65 a frame, every frame")))

(test static-field-grows-without-a-cap
  "The warp's radius stops at max; this one never does. The level tears it down on a
   timer instead, which is why its edge is still moving when the screen changes."
  (let ((sf (static-field:make-static-field))
        (s (make-marked-screen)))
    (static-field:begin sf 120 60 5)
    (run-static-field sf s 200)
    (is (> (static-field:static-field-radius sf) 100.0) "still climbing at frame 200")))

(defun positional-screen ()
  "A back buffer where every cell holds its own index, so a boiled cell -- which takes a
   glyph from a random position -- can be told apart from an untouched one."
  (let ((s (screen:make-screen)))
    (dotimes (i (length (screen:screen-back s)) s)
      (setf (aref (screen:screen-back s) i) i))))

(test static-field-blooms-from-where-the-ship-was
  "beginStaticField takes the centre of the ship, not the centre of the screen."
  (let ((sf (static-field:make-static-field))
        (s (positional-screen)))
    ;; The ship starts at column 30; put the field there rather than mid-screen.
    (static-field:begin sf 30 70 5)
    (run-static-field sf s 8)
    (let* ((buf (theme:sprite-glyphs
                 (svref (static-field:sprites sf) (static-field:current sf))))
           (row (- screen:+rows+ 70))
           (base (* row screen:+cols+)))
      (flet ((moved? (col) (/= (aref buf (+ base col)) (+ base col))))
        (is (moved? 30) "the cell the ship died on has churned")
        (is-false (moved? 200) "but one 170 columns away has not")
        (is-false (moved? 120) "not even the middle of the screen")))))

(test player-dies-when-the-shields-run-out
  "Spending the last shield ends the run. The shield check comes BEFORE the respawn
   countdown, so the last explosion is not followed by another respawn."
  (let ((p (make-test-player)))
    (setf (player:player-shields p) 1)
    ;; Fatal damage: explode spends the shield and starts the respawn delay.
    (setf (player:player-health p) 0)
    (player:update p)
    (is (= 0 (player:player-shields p)))
    (is (eq :play (player:player-status p)) "not dead yet -- the check is next tick")
    (player:update p)
    (is (eq :dead (player:player-status p)))
    (is (= 0 (player:player-health p)))
    (is (= 0 (player:player-trigger-frame p)) "and the death clock starts at zero")))

(test player-with-shields-left-respawns-instead
  (let ((p (make-test-player)))
    (setf (player:player-health p) 0)
    (dotimes (i 6) (player:update p))
    (is (eq :play (player:player-status p)) "still playing")
    (is (= 9 (player:player-shields p)) "one shield spent")
    (is (= (player:player-max-health p) (player:player-health p)) "and patched up")))

(test player-dead-state-only-counts
  (let ((p (make-test-player)))
    (setf (player:player-status p) :dead)
    (let ((x (rect:rect-x (player:player-rect p))))
      (dotimes (i 20) (player:update p :up? t :right? t :fire? t))
      (is (= x (rect:rect-x (player:player-rect p))) "no steering once dead")
      (is (= 20 (player:player-trigger-frame p))))))

(test death-sequence-runs-to-the-score-table
  "DSC_WARP_DONE_DELTA frames of static, then the high scores -- carrying the score the
   run earned, which is the one thing the original's g_player global passes across a
   level switch."
  (with-game (lv)
    (play-ticks lv 5)
    (let ((p (dsc:descendant-player lv)))
      (setf (player:player-score p) 12345
            (player:player-shields p) 0)
      (play-ticks lv 1)
      (is (eq :dead (player:player-status p)))
      (play-ticks lv 1)
      (is-true (static-field:active? (dsc:descendant-static-field lv))
               "the static blooms")
      (play-ticks lv 338)
      (is-true (static-field:active? (dsc:descendant-static-field lv))
               "still running one frame short")
      (play-ticks lv 2)
      (is (eq :score level:*requested*) "on to the high scores")
      (is (= 12345 state:*carried-score*) "with the run's score")
      (is-false (static-field:active? (dsc:descendant-static-field lv))
                "and the field is torn down"))))

(test death-sequence-retires-the-enemies-partway
  "DSC_WARP_ALL_DELTA. Until then the enemies keep flying over the growing static, which
   is why the original puts their entity back at frame 2."
  (with-game (lv)
    (play-ticks lv 200)
    (setf (player:player-shields (dsc:descendant-player lv)) 0)
    (play-ticks lv 2)
    (is-false (dsc:descendant-enemies-retired? lv))
    (play-ticks lv 180)
    (is-true (dsc:descendant-enemies-retired? lv))))

(test death-sequence-renders
  (with-game (lv)
    (play-ticks lv 5)
    (setf (player:player-shields (dsc:descendant-player lv)) 0)
    (play-ticks lv 60)
    (let ((s level:*screen*))
      (finishes (level:render-level lv s))
      (screen:composite s)
      (is (notevery #'zerop (screen:screen-cells s))))))

(test score-level-takes-the-carried-score-and-clears-it
  "SCORE_loadLevel reads g_player.d_score and zeroes it, so backing out to the menu and
   returning does not re-offer the same run."
  (let ((state:*carried-score* 4200)
        (level:*current* nil)
        (level:*state* :play)
        (level:*frame* 0)
        (audio:*muted?* t))
    (unwind-protect
         (progn
           (level:start-level :score)
           (is (= 4200 (score:score-player-score level:*current*)))
           (is (= 0 state:*carried-score*) "and it is spent"))
      (level:shutdown))))
