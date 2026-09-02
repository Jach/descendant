(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The cross-level state bag, and difficulty reaching the enemies.

(defmacro with-fresh-state (&body body)
  `(let ((state:*difficulty* state:+boot-difficulty+)
         (state:*difficulty-chosen?* nil)
         (state:*carried-score* 0))
     ,@body))

(test difficulty-boots-in-the-middle-of-the-range
  "CHANGED FROM THE ORIGINAL, which boots at 4 -- outside the 1-3 the options screen
   offers, so its default was harder than anything a player could pick. Not subtle
   either: cooldowns are `base - difficulty * k`, and at 4 the cover shot's goes
   negative, meaning it fires every tick instead of every fifth.

   The original could only afford 4 because it used the out-of-range value as its
   'player has not chosen' sentinel; the explicit flag replaces that."
  (with-fresh-state
    (is (= 2 state:+boot-difficulty+))
    (is (<= 1 state:+boot-difficulty+ 3) "inside what the options screen offers")
    (is (= 2 state:*difficulty*))
    (is-false state:*difficulty-chosen?*)))

(test the-cover-shot-no-longer-fires-every-tick-by-default
  "The concrete symptom of booting at 4."
  (is (minusp (enemies:pattern-speed (enemies:shot-pattern :cover 4)))
      "at 4 the cooldown is negative, so `timer > speed` is always true")
  (is (plusp (enemies:pattern-speed
              (enemies:shot-pattern :cover state:+boot-difficulty+)))
      "at the new default it is a real cooldown")
  ;; And no shot type is degenerate anywhere in the selectable range.
  (dolist (kind '(:straight :cover :bomber :boss :lazer :lturret :hturret :chaser))
    (dolist (d '(1 2 3))
      (is (>= (enemies:pattern-speed (enemies:shot-pattern kind d)) 0)
          "~a at difficulty ~d should have a non-negative cooldown" kind d))))

(test difficulty-config-wins-until-the-player-chooses
  "MENU_loadLevel reloads the config every time the menu is entered. Without the guard,
   backing out of the options screen would silently undo the choice just made."
  (with-fresh-state
    (is (= 2 (state:difficulty-from-config 2)) "config applies on a fresh boot")
    (state:set-difficulty 3)
    (is (= 3 (state:difficulty-from-config 2)) "and is ignored afterwards")
    (is (= 3 state:*difficulty*))))

(test difficulty-reaches-the-enemy-pool
  "The whole point: g_dscState.d_difficulty is read three levels away by addEnemy, which
   bakes it into every enemy's health as `health + difficulty*3`."
  (with-fresh-state
    (let ((easy nil) (hard nil))
      (flet ((health-of (difficulty)
               (state:set-difficulty difficulty)
               (let ((audio:*muted?* t)
                     (level:*frame* 0)
                     (level:*state* :play)
                     (level:*current* nil)
                     (level:*screen* (screen:make-screen)))
                 (unwind-protect
                      (progn
                        (level:start-level :descendant)
                        (let ((lv level:*current*))
                          (is (= difficulty (dsc:descendant-difficulty lv))
                              "the level snapshotted the setting")
                          (enemies:definition-health
                           (enemies:definition (dsc:descendant-enemies lv)
                                                "enemy_ship_floogle"))))
                   (level:shutdown)))))
        (setf easy (health-of 1) hard (health-of 3))
        (is (< easy hard) "harder enemies take more killing")
        (is (= 6 (- hard easy)) "exactly difficulty*3, so two steps is six")))))

(test difficulty-is-fixed-once-a-level-has-loaded
  "Enemy definitions are built at load, so changing the setting mid-level does nothing
   until the next one -- true of the original for the same reason."
  (with-fresh-state
    (state:set-difficulty 1)
    (with-game (lv)
      (is (= 1 (dsc:descendant-difficulty lv)))
      (state:set-difficulty 3)
      (play-ticks lv 5)
      (is (= 1 (dsc:descendant-difficulty lv)) "still the value it loaded with"))))

(test state-reset-returns-to-boot
  (with-fresh-state
    (state:set-difficulty 2)
    (setf state:*carried-score* 999)
    (state:reset)
    (is (= state:+boot-difficulty+ state:*difficulty*))
    (is-false state:*difficulty-chosen?*)
    (is (= 0 state:*carried-score*))))

;;; ---------------------------------------------------------------------------
;;; The cave palette cycle

(test cave-alternates-between-cycles
  "ADDED, not ported. The cave was drawn brown and shipped blue; since the game loops the
   same three levels forever anyway, each lap gets a different one."
  (is (eq :ice (state:cave-palette 0)) "blue first -- that is what shipped")
  (is (eq :brown (state:cave-palette 1)) "brown on the second lap")
  (is (eq :ice (state:cave-palette 2)) "and back")
  (is (eq :brown (state:cave-palette 3))))

(test each-lap-of-the-loop-is-harder
  "ADDED. The original looped at a fixed difficulty forever, so beating stage three was
   the end of the game in every sense but the score."
  (let ((state:*theme* :crash-site)
        (state:*cycle* 0)
        (state:*difficulty* 2))
    (state:advance-theme)                 ; -> hidden-cave
    (state:advance-theme)                 ; -> brain-pain
    (is (= 2 state:*difficulty*) "no step until the loop comes round")
    (state:advance-theme)                 ; wraps
    (is (= 3 state:*difficulty*))
    (dotimes (i 3)
      (declare (ignore i))
      (dotimes (j 3) (declare (ignore j)) (state:advance-theme)))
    (is (= state:+max-difficulty+ state:*difficulty*) "and it stops at the cap")
    (is (= 4 state:+max-difficulty+))))

(test the-loop-does-not-touch-the-saved-difficulty
  "The step is runtime only: what the options screen says is what the NEXT run starts
   from, however many laps this one climbed."
  (let ((settings:*path* "/nonexistent/options.ini"))
    (settings:reset)
    (let ((state:*theme* :brain-pain)
          (state:*cycle* 0)
          (state:*difficulty* 2))
      (state:advance-theme)
      (is (= 3 state:*difficulty*))
      (is (= 2 (settings:value :difficulty)) "the setting is untouched"))))

(test a-new-run-comes-back-down-to-the-setting
  "A run that reached the fourth lap must not leave the next one starting there."
  (let ((settings:*path* "/nonexistent/options.ini"))
    (settings:reset)
    (setf (settings:value :difficulty) 1)
    (let ((state:*theme* :brain-pain)
          (state:*cycle* 0)
          (state:*run-score* 0)
          (state:*continue-theme* nil)
          (state:*difficulty* 4))
      (state:begin-new-run)
      (is (= 1 state:*difficulty*))
      ;; And continuing does too -- it already costs the score, and carrying the ramp
      ;; would make it a worse deal than starting over.
      (setf state:*difficulty* 4)
      (state:record-death-at :brain-pain)
      (state:resume-run)
      (is (= 1 state:*difficulty*)))))

(test the-cycle-counts-only-on-wrap
  (let ((state:*theme* :crash-site)
        (state:*cycle* 0))
    (state:advance-theme)                 ; -> hidden-cave
    (state:advance-theme)                 ; -> brain-pain
    (is (= 0 state:*cycle*) "still the first lap")
    (state:advance-theme)                 ; wraps -> crash-site
    (is (= 1 state:*cycle*))
    (is (eq :crash-site state:*theme*))))

(test the-cave-really-loads-differently-per-cycle
  "The fixup happens as the theme's colormap is read, so this is worth checking against
   the actual palette rather than the flag."
  (flet ((slot-8 (palette)
           (let ((theme:*hidden-cave-palette* palette))
             (aref (theme:colormap-colors
                    (theme:theme-colormap
                     (theme:read-theme (paths:theme-path "hidden_cave.thm"))))
                   8))))
    (is (/= (slot-8 :ice) (slot-8 :brown))
        "the two cycles really do produce different colours")))

;;; ---------------------------------------------------------------------------
;;; Balance overrides

(test overrides-apply-without-touching-the-assets
  "The shipped .cfg files are assets and stay untouched; the few numbers we change live
   in one table with their reasons."
  (let ((cfg (config:read-config (paths:config-path "level_crash_site.cfg"))))
    (is (= 100 (config:config-int cfg "spawn_midboss.spawn_delta"))
        "10 in the file -- every other class uses 60 to 1000")
    (is (= 2 (config:config-int cfg "spawn_collectable.probability")))
    (is (= 5 (config:config-int cfg "collect_points.spawn_prob"))
        "biased toward the one that heals")
    ;; The other pickups are untouched.
    (dolist (name '("collect_rapid" "collect_spread" "collect_invuln"))
      (is (= 3 (config:config-int cfg (format nil "~a.spawn_prob" name)))
          "~a keeps its shipped weight" name))))

(test the-shipped-values-are-still-reachable
  (let ((config:*overrides* nil))
    (let ((cfg (config:read-config (paths:config-path "level_crash_site.cfg"))))
      (is (= 10 (config:config-int cfg "spawn_midboss.spawn_delta")))
      (is (= 1 (config:config-int cfg "spawn_collectable.probability")))
      (is (= 3 (config:config-int cfg "collect_points.spawn_prob"))))))

(test overrides-do-not-invent-keys
  "An override for a key the file does not have would silently add configuration."
  (let ((cfg (config:read-config (paths:config-path "level_crash_site.cfg"))))
    (let ((config:*overrides* nil))
      (dolist (entry '("spawn_midboss.spawn_delta"
                       "spawn_collectable.probability"
                       "collect_points.spawn_prob"))
        (is-true (config:config-value cfg entry)
                 "~a must already exist in the shipped file" entry)))))

(test overrides-can-target-one-level
  "Stage two is a real step up -- the original's own step, near-identically -- and its
   answer to the doomworm is to wait out the attack wave for a power-up, so power-up
   timing is that fight's difficulty dial and deserves tuning on its own."
  (let ((cave (config:read-config (paths:config-path "level_hidden_cave.cfg")))
        (site (config:read-config (paths:config-path "level_crash_site.cfg"))))
    (is (= 3 (config:config-int cave "spawn_collectable.probability"))
        "the cave gets more")
    (is (= 900 (config:config-int cave "spawn_collectable.spawn_delta"))
        "and a shorter gap between them")
    (is (= 1800 (config:config-int cave "spawn_collectable.start_delta"))
        "and much less of a run-up before the first")
    ;; Stage one keeps the shipped schedule with only the global weight bump; stage three
    ;; has its own entry and is checked separately.
    (is (= 2 (config:config-int site "spawn_collectable.probability")))
    (is (= 1000 (config:config-int site "spawn_collectable.spawn_delta")))
    (is (= 4000 (config:config-int site "spawn_collectable.start_delta")))))

(test level-overrides-win-over-global-ones
  (let ((cave (config:read-config (paths:config-path "level_hidden_cave.cfg"))))
    ;; The :ALL entry says 2; the cave's own says 3.
    (is (= 3 (config:config-int cave "spawn_collectable.probability")))
    ;; And an :ALL entry with no per-level counterpart still applies.
    (is (= 100 (config:config-int cave "spawn_midboss.spawn_delta")))))

;;; ---------------------------------------------------------------------------
;;; Start and continue

(defmacro with-run-state (&body body)
  `(let ((state:*theme* :crash-site)
         (state:*cycle* 0)
         (state:*run-score* 0)
         (state:*continue-theme* nil))
     ,@body))

(test dying-on-the-first-stage-offers-no-continue
  (with-run-state
    (state:record-death-at :crash-site)
    (is-false (state:continue-available?)
              "there is nothing to skip -- START already puts you there")))

(test dying-later-offers-a-continue
  (with-run-state
    (state:record-death-at :hidden-cave)
    (is-true (state:continue-available?))
    (is (eq :hidden-cave state:*continue-theme*))
    (state:record-death-at :brain-pain)
    (is (eq :brain-pain state:*continue-theme*))))

(test start-always-begins-at-the-first-stage
  "The reported bug: the theme is cross-level state, so dying on stage two and pressing
   START put you straight back on stage two."
  (with-run-state
    (setf state:*theme* :hidden-cave
          state:*cycle* 2
          state:*run-score* 5000)
    (state:record-death-at :hidden-cave)
    (state:begin-new-run)
    (is (eq :crash-site state:*theme*))
    (is (= 0 state:*cycle*) "and the cave is back to its first-lap colours")
    (is (= 0 state:*run-score*))
    (is-false (state:continue-available?) "START consumes the continue")))

(test continue-resumes-where-the-run-ended-but-at-zero
  "It costs the leaderboard rather than nothing: a continued run cannot beat an unbroken
   one."
  (with-run-state
    (setf state:*run-score* 5000)
    (state:record-death-at :brain-pain)
    (is (eq :brain-pain (state:resume-run)))
    (is (eq :brain-pain state:*theme*))
    (is (= 0 state:*run-score*) "the score does not come back")
    (is-false (state:continue-available?) "and it is a one-shot")))

(test continue-does-nothing-when-none-is-outstanding
  (with-run-state
    (is (null (state:resume-run)))
    (is (eq :crash-site state:*theme*))))

(test stage-three-gets-a-smaller-nudge-than-the-cave
  "Weight moves in whole steps -- 2 gives 7.5 a minute and 3 gives 11.3, with nothing in
   between -- so the weight goes up and the GAP becomes the ceiling, which is continuous.
   Measured at 8.8."
  (let ((brain (config:read-config (paths:config-path "level_brain_pain.cfg")))
        (cave (config:read-config (paths:config-path "level_hidden_cave.cfg"))))
    (is (= 3 (config:config-int brain "spawn_collectable.probability")))
    (is (= 1150 (config:config-int brain "spawn_collectable.spawn_delta")))
    (is (> (config:config-int brain "spawn_collectable.spawn_delta")
           (config:config-int cave "spawn_collectable.spawn_delta"))
        "a wider gap than the cave's, so a lower rate despite the same weight")
    (is (= 2500 (config:config-int brain "spawn_collectable.start_delta"))
        "and a shorter run-up, though not as short as the cave's")))
