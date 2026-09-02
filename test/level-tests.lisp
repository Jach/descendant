(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(test fixed-timestep-matches-the-original
  "sys_time.c pins d_timeStep to 0.016 via an #if 1 that disabled the real measurement.
   Every level's animation timing is written against that number -- and because it is
   fixed, the loop's PACE decides how fast the world moves in wall time."
  (is (= 0.016 level:+time-step+))
  (let ((state:*simulation-hz* 62.5))
    (is (= 62.5 (level:logic-hz)))
    (is (< (abs (- 1.0 (* level:+time-step+ (level:logic-hz)))) 1d-6)
        "at the default pace, wall time equals simulated time"))
  (let ((state:*simulation-hz* 30.0))
    (is (< (abs (- 0.48 (* level:+time-step+ (level:logic-hz)))) 1d-6)
        "and at 30 Hz the world runs at roughly half speed, as the original did on
         hardware that could not keep up")))

(test default-render-mode-is-unlocked
  "The original defaulted to 30 FPS because the console renderer could not keep up.
   We present every tick; game speed is unchanged because the timestep is fixed."
  (is (eq :60-fps level:*render-mode*)))

(test render-mode-frame-skipping
  "GR_render skips presenting on odd frames at 30 FPS and two frames in three at 20."
  (let ((level:*render-mode* :30-fps))
    (let ((level:*frame* 0)) (is-true (level:present-this-frame?)))
    (let ((level:*frame* 1)) (is-false (level:present-this-frame?)))
    (let ((level:*frame* 2)) (is-true (level:present-this-frame?))))
  (let ((level:*render-mode* :20-fps))
    (let ((level:*frame* 0)) (is-true (level:present-this-frame?)))
    (let ((level:*frame* 1)) (is-false (level:present-this-frame?)))
    (let ((level:*frame* 3)) (is-true (level:present-this-frame?))))
  (let ((level:*render-mode* :60-fps))
    (let ((level:*frame* 7)) (is-true (level:present-this-frame?)))))

(test level-registry
  (is (eq 'com.thejach.descendant.level.intro::intro (gethash :intro level::*registry*)))
  (is (eq 'com.thejach.descendant.level.menu::menu (gethash :menu level::*registry*)))
  (signals error (level:make-level :no-such-level)))

(defmacro with-headless-level ((var keyword) &body body)
  "Load KEYWORD with audio muted and no window, binding VAR to the level instance."
  `(let ((audio:*muted?* t)
         (level:*frame* 0)
         (level:*state* :play)
         (level:*current* nil))
     (unwind-protect
          (progn
            (level:start-level ,keyword)
            (let ((,var level:*current*))
              ,@body))
       (level:shutdown))))

(test intro-loads-its-assets
  (with-headless-level (lv :intro)
    (is (= 52 (theme:sprite-frames (intro::intro-movie lv))))
    (is (= 240 (theme:sprite-width (intro::intro-movie lv))))
    ;; "AND" and "PRESENTS" rendered from hud_06 at 6 px per character.
    (is (= 18 (theme:sprite-width (intro::intro-and-text lv))))
    (is (= 48 (theme:sprite-width (intro::intro-presents-text lv))))
    (is (= screen:+cols+ (theme:sprite-width (intro::intro-star-field lv))))
    (is (eq :movie (intro::intro-mode lv)))))

(test intro-config-parses-c-float-suffixes
  "level_intro.cfg writes `splash_anim_delta = 0.15f`, which the CL reader would reject."
  (let ((cfg (config:read-config (paths:config-path "level_intro.cfg"))))
    (is (< (abs (- 0.15 (config:config-float cfg "intro.splash_anim_delta"))) 1e-6))
    (is (< (abs (- 0.5 (config:config-float cfg "intro.credits_move_delta"))) 1e-6))
    (is (= 14 (config:config-int cfg "intro.frame_fire")))
    (is (= 37 (config:config-int cfg "intro.frame_crash")))))

(test intro-credit-stack-layout
  "Positions built downward from -4 with the original's hand-tuned pads. The banner
   lands at -215, which is what INTRO_initLevel's arithmetic produces."
  (with-headless-level (lv :intro)
    (let ((pos (intro::intro-positions lv)))
      (is (= -4 (cdr (gethash :logo-dp pos))))
      (is (= -75 (cdr (gethash :and pos))))
      (is (= -89 (cdr (gethash :hlab pos))))
      (is (= -199 (cdr (gethash :presents pos))))
      (is (= -215 (cdr (gethash :banner pos))))
      ;; Everything in the stack is horizontally centred.
      (dolist (key '(:logo-dp :and :hlab :presents :banner))
        (is (>= (car (gethash key pos)) 0) "~a x" key)))))

(test intro-mode-timeline
  "Landmarks derived from the original's constants: 52 movie frames at 0.15 s each is
   520 ticks at a 0.016 s step; scrolling stops once the banner reaches rows-3; and
   INTRO_END_DELTA is 1400 ticks in :still before the menu."
  (with-headless-level (lv :intro)
    (let ((banner-mode-at nil) (still-mode-at nil) (switch-at nil))
      (dotimes (n 3000)
        (case (intro::intro-mode lv)
          (:banner (unless banner-mode-at (setf banner-mode-at n)))
          (:still (unless still-mode-at (setf still-mode-at n))))
        (level:update-level lv)
        (incf level:*frame*)
        (when (and (eq level:*state* :switch-level) (not switch-at))
          (setf switch-at n)
          (return)))
      (is (= 520 banner-mode-at) "movie should end after 52 frames x 10 ticks")
      (is (= 1185 still-mode-at))
      (is (= 1400 switch-at) "INTRO_END_DELTA")
      (is (eq :menu level:*requested*))
      (is (= (- screen:+rows+ 3)
             (cdr (gethash :banner (intro::intro-positions lv))))
          "banner settles exactly at rows-3"))))

(test intro-movie-oscillates-in-the-final-modes
  "Once the movie ends the last three frames ping-pong so the wreck keeps flickering."
  (with-headless-level (lv :intro)
    (loop repeat 700 do (level:update-level lv) (incf level:*frame*))
    (is (eq :banner (intro::intro-mode lv)))
    (let ((seen '()))
      (loop repeat 200
            do (level:update-level lv)
               (incf level:*frame*)
               (pushnew (intro::intro-movie-frame lv) seen))
      (is (every (lambda (f) (<= (intro::intro-min-movie-frame lv)
                                 f
                                 (intro::intro-max-movie-frame lv)))
                 seen)
          "frames stayed in the oscillation window: ~s" (sort seen #'<))
      (is (> (length seen) 1) "the movie frame actually changed"))))

(test intro-escape-skips-to-the-menu
  (with-headless-level (lv :intro)
    (is (eq :play level:*state*))
    ;; Drive the transition directly; synthesising SDL events needs no window but the
    ;; event struct is awkward to fabricate, and the handler is a one-line dispatch.
    (level:request-level :menu)
    (is (eq :switch-level level:*state*))
    (is (eq :menu level:*requested*))))

(test menu-level-loads
  (with-headless-level (lv :menu)
    (is (string= "menu" (level:level-name lv)))
    (is (= screen:+cols+ (theme:sprite-width
                          (com.thejach.descendant.level.menu::menu-background lv))))))

(test level-transition-tears-down-and-brings-up
  (with-headless-level (lv :intro)
    (declare (ignore lv))
    (level:request-level :menu)
    (level:switch-if-requested)
    (is (eq :play level:*state*))
    (is (null level:*requested*))
    (is (string= "menu" (level:level-name level:*current*)))))

(test levels-supply-their-palette
  "Regression: without this the renderer keeps its all-black default palette and the
   window renders solid black while audio and input carry on working normally. The
   original applies the theme's colormap from OM_load_theme."
  (dolist (keyword '(:intro :menu))
    (with-headless-level (lv keyword)
      (let ((cm (level:level-colormap lv)))
        (is (typep cm 'theme:colormap) "~a must supply a colormap" keyword)
        (is (notevery #'zerop (theme:colormap-colors cm))
            "~a's palette must not be all black" keyword)))))

(test ticking-a-level-uploads-its-palette
  "End-to-end guard on the same bug: after one tick the renderer's palette must match
   the level's theme rather than the black default."
  (with-headless-level (lv :intro)
    (let ((r (renderer:make-renderer)))
      (unwind-protect
           (progn
             (is (null (renderer:renderer-colormap r)) "starts with no palette")
             (is (every (lambda (c) (= c #xFF000000)) (renderer:renderer-palette r))
                 "the default palette is opaque black")
             (renderer:ensure-palette r (level:level-colormap lv))
             (is (eq (level:level-colormap lv) (renderer:renderer-colormap r)))
             ;; intro.thm slot 15 is stored as (235,235,220); the verified mapping
             ;; swaps red and blue on the way to the screen, so it displays as
             ;; (220,235,235). Assert the displayed value.
             (is (= #xFFDCEBEB (aref (renderer:renderer-palette r) 15)))
             (is (= #xFF000000 (aref (renderer:renderer-palette r) 0)))
             (is (notevery (lambda (c) (= c #xFF000000)) (renderer:renderer-palette r))))
        (renderer:destroy-renderer r)))))

(test audio-tolerates-missing-files
  "jaguar.wav is referenced by two level configs but was never shipped. Loading it must
   warn and return NIL rather than fail the level, and playing NIL must be harmless."
  (let ((audio:*muted?* t))
    (let ((sound (handler-bind ((warning #'muffle-warning))
                   (audio:load-sound (paths:sound-path "jaguar.wav")))))
      (is (null sound))
      (finishes (audio:play sound))
      (finishes (audio:play-music sound))
      (finishes (audio:free-sound sound)))))

;;; ---------------------------------------------------------------------------
;;; Menu

(test menu-navigation-wraps
  "Up and down cycle through the page, wrapping at both ends as the original's
   circular linked list did."
  (with-headless-level (lv :menu)
    (is (eq :start (menu::menu-selection lv)))
    (menu::%advance-selection lv 1)
    (is (eq :options (menu::menu-selection lv)))
    (menu::%advance-selection lv -1)
    (is (eq :start (menu::menu-selection lv)))
    ;; up from the first entry wraps to the last
    (menu::%advance-selection lv -1)
    (is (eq :exit (menu::menu-selection lv)))
    (menu::%advance-selection lv 1)
    (is (eq :start (menu::menu-selection lv)))))

(test menu-options-page-round-trip
  "OPTIONS swaps in the second list; GO BACK returns with OPTIONS selected."
  (with-headless-level (lv :menu)
    (setf (menu::menu-selection lv) :options)
    (menu::%activate lv)
    (is (eq :sub (menu::menu-page lv)))
    (is (eq :difficulty (menu::menu-selection lv)))
    (setf (menu::menu-selection lv) :go-back)
    (menu::%activate lv)
    (is (eq :main (menu::menu-page lv)))
    (is (eq :options (menu::menu-selection lv)))))

(test menu-value-adjustment-clamps
  "Left and right walk a row's choices and stop at the ends. Clamped rather than wrapped:
   a two-choice switch that wraps is a toggle whichever way you press, which makes left
   and right mean the same thing."
  (with-headless-level (lv :menu)
    (let ((settings:*path* "/nonexistent/options.ini"))
      (settings:reset)
      (setf (menu::menu-page lv) :sub
            (menu::menu-selection lv) :difficulty)
      (dotimes (i 10) (menu::%adjust lv -1))
      (is (= 1 (settings:value :difficulty)))
      (dotimes (i 10) (menu::%adjust lv 1))
      (is (= 3 (settings:value :difficulty)))
      (setf (menu::menu-selection lv) :music-vol)
      (dotimes (i 10) (menu::%adjust lv -1))
      (is (= 0 (settings:value :music-volume)) "nought is reachable, and is silence")
      (dotimes (i 10) (menu::%adjust lv 1))
      (is (= settings:+max-volume+ (settings:value :music-volume)))
      ;; A switch has two choices and holding a direction does not flip back and forth.
      (setf (menu::menu-selection lv) :show-hud)
      (dotimes (i 5) (menu::%adjust lv 1))
      (is-false (settings:value :show-hud))
      (dotimes (i 5) (menu::%adjust lv -1))
      (is-true (settings:value :show-hud)))))

(test changing-the-renderer-asks-for-a-restart
  "It is chosen when the window is built, so the row reports back instead of pretending
   something happened, and steps away to the way out."
  (with-headless-level (lv :menu)
    (let ((settings:*path* "/nonexistent/options.ini"))
      (settings:reset)
      (setf (menu::menu-page lv) :sub
            (menu::menu-selection lv) :renderer)
      (is (eq :slow (settings:value :renderer)) "the only one that exists yet")
      (is-false (menu:menu-restart-needed? lv))
      (menu::%adjust lv 1)
      (is (eq :fast (settings:value :renderer)))
      (is-true (menu:menu-restart-needed? lv) "the row now reads RESTART NEEDED")
      (is (eq :go-back (menu::menu-selection lv)))
      (is-true (settings:needs-restart? :renderer))
      (is-false (settings:needs-restart? :fullscreen)
                "the others take effect at once"))))

(test the-options-cursor-runs-down-one-column-and-into-the-next
  (with-headless-level (lv :menu)
    (let ((settings:*path* "/nonexistent/options.ini"))
      (settings:reset)
      (setf (menu::menu-page lv) :sub
            (menu::menu-selection lv) :show-hud)
      (is (eq :show-hud
              (third (car (last (remove 0 (menu::%sub-rows)
                                        :key #'first :test-not #'eql)))))
          "show hud really is the bottom of the first column")
      (menu::%advance-selection lv 1)
      (is (eq :renderer (menu::menu-selection lv)) "down from the bottom crosses over")
      (menu::%advance-selection lv -1)
      (is (eq :show-hud (menu::menu-selection lv)) "and up comes back")
      ;; GO BACK is last, where the way out belongs.
      (is (eq :go-back (car (last (menu::%navigable lv))))))))

(test every-options-row-shows-its-own-value
  "The original marked only the row the cursor was on, so you could not see what anything
   else was set to without visiting it."
  (with-headless-level (lv :menu)
    (let ((settings:*path* "/nonexistent/options.ini"))
      (settings:reset)
      (setf (menu::menu-page lv) :sub
            (menu::menu-selection lv) :difficulty)
      (let ((sc (screen:make-screen)))
        (level:render-level lv sc)
        (let ((queued (loop for z below screen:+z-layers+
                            append (coerce (aref (screen::screen-queues sc) z) 'list))))
          ;; Every choice of every setting row is drawn, not just the selected row's.
          (dolist (row (menu::%sub-rows))
            (let ((setting (fifth row)))
              (when setting
                (let ((choices (menu:choices-for setting)))
                  (dolist (choice choices)
                    (is-true (find-if (lambda (entry)
                                        (and (first entry)
                                             (search (cdr choice)
                                                     (theme:sprite-name (first entry)))))
                                      queued)
                             "~a's choice ~s is not on screen"
                             (third row) (cdr choice))))))))))))

(test menu-destinations-are-all-registered
  "Every option that switches level must have somewhere to go, placeholder or not."
  (dolist (keyword '(:descendant :controls :score :credits))
    (is (gethash keyword level::*registry*) "~a should be registered" keyword)))

(test menu-start-requests-the-game
  (with-headless-level (lv :menu)
    (setf (menu::menu-selection lv) :start)
    (menu::%activate lv)
    (is (eq :switch-level level:*state*))
    (is (eq :descendant level:*requested*))))

(test menu-exit-quits
  (with-headless-level (lv :menu)
    (setf (menu::menu-selection lv) :exit)
    (menu::%activate lv)
    (is (eq :quit level:*state*))))

(test hidden-cave-palette-option
  "Level 2's browns can render as the intended brown cave or the ice cave that shipped."
  (let ((theme::*hidden-cave-palette* :brown))
    (let ((cm (theme:theme-colormap
               (theme:read-theme (paths:theme-path "hidden_cave.thm")))))
      ;; pre-swapped on load, so the render-time swap restores (88,50,19)
      (is (= #x133258 (theme:colormap-ref cm 8)))))
  (let ((theme::*hidden-cave-palette* :ice))
    (let ((cm (theme:theme-colormap
               (theme:read-theme (paths:theme-path "hidden_cave.thm")))))
      (is (= #x583213 (theme:colormap-ref cm 8)))))
  ;; Other themes are untouched under either setting.
  (dolist (setting '(:brown :ice))
    (let ((theme::*hidden-cave-palette* setting))
      (let ((cm (theme:theme-colormap
                 (theme:read-theme (paths:theme-path "crash_site.thm")))))
        (is (= #x7F00FF (theme:colormap-ref cm 8)) "crash_site untouched (~a)" setting)))))

(test controls-screen-loads
  "A static reference card borrowing the credits theme and config."
  (with-headless-level (lv :controls)
    (is (= 6 (length (com.thejach.descendant.level.controls::controls-lines lv))))
    (is (= screen:+cols+
           (theme:sprite-width
            (com.thejach.descendant.level.controls::controls-background lv))))
    ;; The field has two entries summing to 100%, so nothing is transparent.
    (is (notany #'glyph:transparent?
                (theme:sprite-glyphs
                 (com.thejach.descendant.level.controls::controls-star-field lv))))))

(test controls-ignores-input-during-the-grace-period
  "CONTROLS_EXIT_DELTA stops the keypress that opened the screen from dismissing it."
  (with-headless-level (lv :controls)
    (is (= 0 (com.thejach.descendant.level.controls::controls-frame lv)))
    (dotimes (i 40) (level:update-level lv))
    (is (>= (com.thejach.descendant.level.controls::controls-frame lv) 30))))

(test controls-overrides-the-placeholder
  "The real level must win the :controls registration."
  (is (eq 'com.thejach.descendant.level.controls::controls
          (gethash :controls level::*registry*))))

;;; ---------------------------------------------------------------------------
;;; High scores

(test score-defaults-when-no-file
  "With no highscores.txt the built-in table stands in, sorted high to low."
  (let ((scores (score:read-high-scores #p"/nonexistent/highscores.txt")))
    (is (= 10 (length scores)))
    (is (string= "MARK" (car (first scores))))
    (is (= 7000 (cdr (first scores))))
    (is (= 0 (cdr (car (last scores)))))
    ;; monotonically non-increasing
    (is-true (loop for (a b) on scores while b always (>= (cdr a) (cdr b))))))

(test score-row-formatting
  "sprintf(\" :%12s :::%010d:\") -- right-aligned name, zero-padded score, 29 chars."
  (let ((row (score:format-row "MARK" 7000)))
    (is (= 29 (length row)))
    (is (string= " :        MARK :::0000007000:" row)))
  (is (string= " :     FLOOGLE :::0000004000:" (score:format-row "FLOOGLE" 4000)))
  ;; An empty name still occupies its twelve columns.
  (is (= 29 (length (score:format-row "" 0)))))

(test score-qualification-and-insertion
  (let ((scores (score:read-high-scores #p"/nonexistent/highscores.txt")))
    (is-false (score:qualifies? scores 0) "zero never qualifies")
    (is-true (score:qualifies? scores 50) "anything above the last row qualifies")
    (let ((updated (score:insert-score scores "NEW" 6500)))
      (is (= 10 (length updated)) "the table stays ten rows")
      (is (string= "NEW" (car (second updated))) "6500 slots between 7000 and 6000")
      (is (= 6500 (cdr (second updated)))))))

(test score-round-trips-through-a-file
  (let ((path (merge-pathnames "descendant-score-test.txt"
                               (uiop:temporary-directory))))
    (unwind-protect
         (let ((original (score:insert-score
                          (score:read-high-scores #p"/nonexistent/x.txt") "ZED" 9999)))
           (score:write-high-scores original path)
           (is-true (probe-file path))
           (let ((reloaded (score:read-high-scores path)))
             (is (equal (mapcar #'cdr original) (mapcar #'cdr reloaded)))
             (is (string= "ZED" (car (first reloaded))))))
      (ignore-errors (delete-file path)))))

(test score-level-loads-and-scrolls
  (with-headless-level (lv :score)
    ;; header plus ten rows
    (is (= 11 (length (score::score-entries lv))))
    (is (= 10 (length (score::score-scores lv))))
    (let ((before (score::layout-y lv)))
      (dotimes (i 20) (level:update-level lv))
      (is (/= (first before) (first (score::layout-y lv)))
          "the roll should have moved"))))

(test score-overrides-the-placeholder
  (is (eq 'com.thejach.descendant.level.score::score (gethash :score level::*registry*)))
  (is (eq 'com.thejach.descendant.level.credits::credits
          (gethash :credits level::*registry*))))

(test credits-roll-layout
  "The roll is one stack: gaps accumulate downward, so every Y is below the last."
  (with-headless-level (lv :credits)
    (let ((ys (com.thejach.descendant.level.credits:layout-y lv)))
      ;; 40 ordered entries, 9 of which are :space and contribute a gap rather than a
      ;; sprite, leaving 31 drawn.
      ;;
      ;; Was 26 for the original roll. The FMOD logo came out (the port uses SDL_mixer,
      ;; so the credit was inaccurate as well as being someone else's mark to ship), and
      ;; the port's own preface went in ahead of it.
      (is (= 31 (length ys)) "drawn entries, with the :space kinds folded into gaps")
      (is-true (loop for (a b) on ys while b always (> a b))
               "each entry sits below the previous"))))
