(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; Persisted options, and the timing they drive.

(defmacro with-fresh-settings ((&optional path) &body body)
  `(let ((settings:*path* ,path))
     (settings:reset)
     (unwind-protect (progn ,@body)
       (settings:reset))))

(defun %scratch-settings-path ()
  (merge-pathnames (format nil "descendant-options-~d.ini" (random 100000))
                   (uiop:temporary-directory)))

(test settings-start-at-their-defaults
  (with-fresh-settings ()
    (is (= 2 (settings:value :difficulty)))
    (is (= 3 (settings:value :music-volume)) "level_menu.cfg asks for 0.3")
    (is (= 1 (settings:value :effects-volume)) "and 0.1")
    (is-false (settings:value :fullscreen))
    (is-false (settings:value :auto-fire))
    (is-true (settings:value :show-hud))
    (is (eq :slow (settings:value :renderer)))))

(test the-real-options-file-is-never-written-by-accident
  "The suite drives the real menu, and the real menu saves when you leave the options
   screen. Without an override a test that walked to GO BACK wrote the player's own
   options.ini -- and one that had just set difficulty to 3 to check the clamping left it
   there, which is exactly how the shipped default appeared to change. RUN-TESTS points
   this at scratch for the whole run; this is the tripwire if that ever comes undone."
  (is-true settings:*path* "settings are pointed somewhere scratch")
  (is-false (search "assets" (namestring (settings:settings-path)))
            "and that somewhere is not beside the assets: ~a" (settings:settings-path))
  ;; Same for the scores, which had the identical accident earlier.
  (is-true score:*scores-path*)
  (is-false (search "assets" (namestring (score:scores-path)))))

(test the-shipped-defaults-are-what-the-config-asks-for
  "Pinned because they are easy to drift and hard to notice: the options file wins over
   them, so a wrong default only shows on a machine that has never saved one."
  (is (= 2 (settings:setting-default (settings:setting :difficulty)))
      "level_menu.cfg's Difficulty = 2")
  (is (= 3 (settings:setting-default (settings:setting :music-volume)))
      "music_volume = 0.3")
  (is (= 1 (settings:setting-default (settings:setting :effects-volume)))
      "effects_volume = 0.1"))

(test volume-zero-is-silence
  "The shipped game could not be asked for silence: its quietest step was a tenth."
  (is (= 0.0 (settings:volume-fraction 0)))
  (is (= 0.1 (settings:volume-fraction 1)))
  (is (= 0.5 (settings:volume-fraction settings:+max-volume+))
      "and the top of the scale is what the original's loudest was"))

(test settings-round-trip-through-the-file
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (setf (settings:value :difficulty) 3
                 (settings:value :music-volume) 0
                 (settings:value :fullscreen) t
                 (settings:value :auto-fire) t)
           (is-true (settings:save-settings))
           (settings:reset)
           (is (= 2 (settings:value :difficulty)) "reset really did clear them")
           (settings:load-settings)
           (is (= 3 (settings:value :difficulty)))
           (is (= 0 (settings:value :music-volume)) "nought survives the trip")
           (is-true (settings:value :fullscreen))
           (is-true (settings:value :auto-fire)))
      (ignore-errors (delete-file path)))))

(test a-missing-file-is-not-an-error
  "A fresh install has no options file, and that is the normal case rather than a fault."
  (with-fresh-settings ((merge-pathnames "descendant-no-such-options.ini"
                                         (uiop:temporary-directory)))
    (is (null (settings:load-settings)))
    (is (= 2 (settings:value :difficulty)) "still the default")))

(test a-corrupt-file-falls-back-per-key
  "This is a preferences file. Somebody who hand-edits it into nonsense should get the
   game, not a backtrace -- and should keep the keys that still parse."
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "difficulty = 3~%")
             (format out "music_volume = banana~%")
             (format out "effects_volume = 99~%")     ; out of range
             (format out "show_hud = maybe~%")
             (format out "nonsense_key = 4~%")
             (format out "no equals sign here~%"))
           (let ((found (settings:load-settings)))
             (is (equal '(:difficulty) found) "only the one good line was taken"))
           (is (= 3 (settings:value :difficulty)))
           (is (= 3 (settings:value :music-volume)) "unparseable, so the default")
           (is (= 1 (settings:value :effects-volume)) "out of range, so the default")
           (is-true (settings:value :show-hud) "not on or off, so the default"))
      (ignore-errors (delete-file path)))))

(test booleans-are-written-as-on-and-off
  "So the file reads the way the screen looks."
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (setf (settings:value :show-hud) t
                 (settings:value :auto-fire) nil)
           (settings:save-settings)
           (let ((text (uiop:read-file-string path)))
             (is (search "show_hud = on" text))
             (is (search "auto_fire = off" text))))
      (ignore-errors (delete-file path)))))

;;; ---------------------------------------------------------------------------
;;; Choices that are not numbers

(test a-choice-setting-round-trips-by-name
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (is (eq :slow (settings:value :renderer)))
           (is (equal '(:slow :fast) (settings:choice-values :renderer)))
           (is (string= "SLO" (settings:choice-label :renderer :slow)))
           (is (string= "FAST" (settings:choice-label :renderer :fast)))
           (setf (settings:value :renderer) :fast)
           (settings:save-settings)
           (is (search "renderer = fast" (uiop:read-file-string path)))
           (settings:reset)
           (settings:load-settings)
           (is (eq :fast (settings:value :renderer))))
      (ignore-errors (delete-file path)))))

(test an-unknown-renderer-falls-back
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "renderer = vulkan~%"))
           (settings:load-settings)
           (is (eq :slow (settings:value :renderer))))
      (ignore-errors (delete-file path)))))

;;; ---------------------------------------------------------------------------
;;; The loop

(test one-logic-step-per-iteration
  "The loop went briefly to an accumulator so it could run free, and came back. There is
   nothing to interpolate on a cell grid at integer positions, so presenting faster than
   the simulation repeats a frame -- it bought no smoothness, and cost the thing a fixed
   step is for, since a stalled frame would then run several steps at once."
  (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play) (level:*current* nil)
        (sc (screen:make-screen)))
    (unwind-protect
         (progn
           (level:start-level :menu)
           (let ((before level:*frame*))
             (level:advance sc)
             (is (= (1+ before) level:*frame*) "one step is one frame")))
      (level:shutdown))))

(test the-unlimited-toggle-is-off-by-default
  "F9 is a ruler, not a way to play: it unpaces the loop, and the simulation speeds up
   with it."
  (is-false descendant:*unlimited?*)
  (let ((descendant:*unlimited?* nil))
    (descendant:toggle-unlimited)
    (is-true descendant:*unlimited?*)
    (descendant:toggle-unlimited)
    (is-false descendant:*unlimited?*)))

;;; ---------------------------------------------------------------------------
;;; The options screen's side of it

(test leaving-the-options-saves-them
  "Written once per visit rather than on every keypress, and leaving is the moment the
   choices become permanent -- which is when a player would expect it."
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play)
                 (level:*current* nil))
             (unwind-protect
                  (progn
                    (level:start-level :menu)
                    (let ((m level:*current*))
                      (setf (menu::menu-page m) :sub
                            (menu::menu-selection m) :fullscreen)
                      (menu::%adjust m 1)          ; fullscreen ON
                      (is-false (probe-file path) "nothing written yet")
                      (setf (menu::menu-selection m) :go-back)
                      (menu::%activate m)
                      (is-true (probe-file path) "leaving wrote the file")
                      (is (eq :main (menu::menu-page m)))))
               (level:shutdown))))
      (ignore-errors (delete-file path)))))

(test escaping-the-options-saves-them-too
  "Backing out with escape must not quietly lose the changes."
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (with-fresh-settings (path)
           (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play)
                 (level:*current* nil))
             (unwind-protect
                  (progn
                    (level:start-level :menu)
                    (let ((m level:*current*))
                      (setf (menu::menu-page m) :sub
                            (menu::menu-selection m) :difficulty)
                      (menu::%activate-escape m)
                      (is-true (probe-file path))
                      (is (eq :main (menu::menu-page m)))))
               (level:shutdown))))
      (ignore-errors (delete-file path)))))

(test erasing-the-scores-puts-the-stock-table-back
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (let ((score:*scores-path* path))
           (with-open-file (out path :direction :output :if-exists :supersede)
             (format out "[player_one]~%name = ZZZ~%score = 99999~%"))
           (is-true (probe-file path))
           (is-true (score:erase-scores))
           (is-false (probe-file path)
                     "the file is gone, and a missing file already means the stock table")
           ;; Erasing when there is nothing to erase is not a failure.
           (is-true (score:erase-scores)))
      (ignore-errors (delete-file path)))))

(test erasing-says-so-and-steps-off-the-row
  (let ((path (%scratch-settings-path)))
    (unwind-protect
         (let ((score:*scores-path* path)
               (audio:*muted?* t) (level:*frame* 0) (level:*state* :play)
               (level:*current* nil))
           (unwind-protect
                (progn
                  (level:start-level :menu)
                  (let ((m level:*current*))
                    (setf (menu::menu-page m) :sub
                          (menu::menu-selection m) :erase)
                    (is-false (menu:menu-erased? m))
                    (menu::%activate m)
                    (is-true (menu:menu-erased? m) "the row now reads ERASED")
                    (is (eq :go-back (menu::menu-selection m))
                        "and the cursor steps off a row with nothing left to do")))
             (level:shutdown)))
      (ignore-errors (delete-file path)))))

;;; ---------------------------------------------------------------------------
;;; Settings that reach into play

(test auto-fire-holds-both-weapons-down
  "Which is what a player who wants it was doing by hand anyway."
  (with-fresh-settings ()
    (with-game (lv)
      (setf (settings:value :auto-fire) nil)
      (is-false (dsc:held? lv :fire))
      (is-false (dsc:held? lv :bomb))
      (setf (settings:value :auto-fire) t)
      (is-true (dsc:held? lv :fire))
      (is-true (dsc:held? lv :bomb))
      ;; And nothing else is affected -- it is the two weapons, not every key.
      (is-false (dsc:held? lv :up)))))

(test hiding-the-hud-keeps-it-up-to-date
  "Hidden, not switched off, so the meters and the score are right the moment it comes
   back and the pause banner still counts down."
  (with-fresh-settings ()
    (with-game (lv)
      (setf (settings:value :show-hud) nil)
      (play-ticks lv 5)
      (let ((sc (screen:make-screen)))
        (level:render-level lv sc)
        (let ((queued (loop for z below screen:+z-layers+
                            append (coerce (aref (screen::screen-queues sc) z) 'list))))
          (is-false (find (hud:hud-score-sprite (dsc:descendant-hud lv))
                          queued :key #'first)
                    "the score is not drawn")))
      ;; The HUD itself still knows the score.
      (is (= (player:player-score (dsc:descendant-player lv))
             (hud:hud-score (dsc:descendant-hud lv)))))))

(test the-points-pickup-is-worth-less-the-harder-it-gets
  "The one number that decides how long a run can last, since shields are otherwise
   unrecoverable. Scaling it makes difficulty mean something besides tougher enemies."
  (let ((player:*points-shield-refund* 3))
    (is (= 4 (player:points-shield-refund 1)) "a pip more at the easiest")
    (is (= 3 (player:points-shield-refund 2)) "the tuned value at the default")
    (is (= 2 (player:points-shield-refund 3)))
    (is (= 1 (player:points-shield-refund 4)) "and one on the loop's hardest lap")
    ;; Never nothing: a pickup worth crossing the screen for has to be worth something.
    (is (= 1 (player:points-shield-refund 9)))))

(test the-refund-follows-the-live-difficulty
  (with-fresh-settings ()
    (with-game (lv)
      (let ((p (dsc:descendant-player lv))
            (player:*points-shield-refund* 3))
        (setf (player:player-shields p) 1)
        (let ((state:*difficulty* 4))
          (player:apply-collectable p "collect_points")
          (is (= 2 (player:player-shields p)) "one pip at difficulty four"))
        (setf (player:player-shields p) 1)
        (let ((state:*difficulty* 1))
          (player:apply-collectable p "collect_points")
          (is (= 5 (player:player-shields p)) "four at difficulty one"))))))

(test a-reporting-row-draws-no-choices
  "RESTART NEEDED is wider than the label area and runs across where the choices go, so
   the tail of the one underneath showed past the end of it."
  (with-headless-level (lv :menu)
    (let ((settings:*path* "/nonexistent/options.ini"))
      (settings:reset)
      (setf (menu::menu-page lv) :sub
            (menu::menu-selection lv) :renderer)
      (flet ((drawn ()
               (let ((sc (screen:make-screen)))
                 (level:render-level lv sc)
                 (loop for z below screen:+z-layers+
                       append (remove nil
                                      (mapcar (lambda (e)
                                                (and (first e)
                                                     (theme:sprite-name (first e))))
                                              (coerce (aref (screen::screen-queues sc) z)
                                                      'list)))))))
        (is-true (find "text:SLO" (drawn) :test #'string=) "choices show normally")
        (menu::%adjust lv 1)
        (is-true (menu:menu-restart-needed? lv))
        (let ((names (drawn)))
          (is-true (find "text:RESTART NEEDED" names :test #'string=))
          (is-false (find "text:FAST" names :test #'string=)
                    "nothing of the choice is left underneath")
          (is-false (find "text:SLO" names :test #'string=)))))))

(test the-gc-readout-is-a-real-number
  (let ((ms (hud:gc-milliseconds)))
    (is (typep ms 'double-float))
    (is (<= 0 ms) "time spent collecting cannot be negative")))

(test the-gc-readout-shares-the-fps-switch
  (with-game (lv)
    (let ((h (dsc:descendant-hud lv)))
      (is-false (hud:hud-gc-sprite h) "nothing built until it is asked for")
      (hud:toggle-fps h)
      (is-true (hud:hud-fps-sprite h))
      (is-true (hud:hud-gc-sprite h) "both appear together"))))
