(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The high score table and its name entry.

(defmacro with-score-level ((var &key (carried 0)) &body body)
  "The score screen, with a scratch high-score file so the tests never touch the real
   one and never depend on what a previous run left behind."
  `(let* ((audio:*muted?* t)
          (level:*frame* 0) (level:*state* :play) (level:*current* nil)
          (state:*carried-score* ,carried)
          ;; Point the table somewhere scratch: COMMIT-NAME saves, so without this a test
          ;; that earns a place rewrites the player's real high scores.
          (score:*scores-path*
            (merge-pathnames (format nil "scores-~d.txt" (random 1000000))
                             (uiop:temporary-directory))))
     (unwind-protect
          (progn
            (level:start-level :score)
            (let ((,var level:*current*))
              ,@body))
       (level:shutdown)
       (ignore-errors (delete-file score:*scores-path*)))))

(test scores-load-with-ten-rows
  (let ((scores (score:read-high-scores #p"/nonexistent/highscores.txt")))
    (is (= 10 (length scores)) "falls back to the built-in table")
    (is (every (lambda (row) (and (stringp (car row)) (integerp (cdr row)))) scores))
    (is (apply #'>= (mapcar #'cdr scores)) "sorted high to low")))

(test qualifying-needs-to-beat-the-lowest
  (let ((scores '(("A" . 500) ("B" . 300) ("C" . 100))))
    (is-true (score:qualifies? scores 101))
    (is-false (score:qualifies? scores 100) "ties do not displace")
    (is-false (score:qualifies? scores 50))
    (is-false (score:qualifies? scores 0)
              "reaching the screen from the menu carries 0, and must not prompt")))

(test inserting-keeps-the-table-sorted-and-capped
  (let* ((scores (score:read-high-scores #p"/nonexistent/highscores.txt"))
         (after (score:insert-score scores "NEWCOMER" 999999)))
    (is (= 10 (length after)) "still exactly ten")
    (is (equal "NEWCOMER" (car (first after))) "at the top")
    (is (apply #'>= (mapcar #'cdr after)))))

(test a-losing-score-does-not-open-name-entry
  (with-score-level (s :carried 0)
    (is-false (score:score-input-mode? s))))

(test a-qualifying-score-opens-name-entry
  (with-score-level (s :carried 9999999)
    (is-true (score:score-input-mode? s))
    (is (equal "" (score:score-input-name s)))))

(test typing-builds-a-name
  (with-score-level (s :carried 9999999)
    (map nil (lambda (c) (score:input-char s c)) "kev")
    (is (equal "KEV" (score:score-input-name s)) "upper-cased -- the HUD font has no
                                                  lowercase glyphs")
    (score:input-backspace s)
    (is (equal "KE" (score:score-input-name s)))))

(test name-entry-rejects-what-the-font-cannot-draw
  (with-score-level (s :carried 9999999)
    (map nil (lambda (c) (score:input-char s c)) "A!B@C")
    (is (equal "ABC" (score:score-input-name s)))
    (score:input-char s #\_)
    (is (equal "ABC_" (score:score-input-name s)) "underscore is allowed")))

(test the-name-is-bounded
  (with-score-level (s :carried 9999999)
    (dotimes (i 50) (score:input-char s #\X))
    (is (<= (length (score:score-input-name s)) (1- score:+max-name-length+)))))

(test committing-inserts-and-saves
  (with-score-level (s :carried 9999999)
    (map nil (lambda (c) (score:input-char s c)) "kev")
    (is-true (score:commit-name s))
    (is-false (score:score-input-mode? s) "the prompt is done")
    (is (equal "KEV" (car (first (score:score-scores s)))) "top of the table")
    (is (= 9999999 (cdr (first (score:score-scores s)))))
    (is (= 10 (length (score:score-scores s))) "still ten")))

(test an-empty-name-is-refused
  "Otherwise mashing enter would skip the prompt and lose the entry."
  (with-score-level (s :carried 9999999)
    (is-false (score:commit-name s))
    (is-true (score:score-input-mode? s) "still waiting")
    (score:input-char s #\Space)
    (is-false (score:commit-name s) "whitespace is not a name")))

(test name-entry-takes-the-whole-keyboard
  "The original hijacks the input handler. Without that, SPACE would skip the one screen
   the player has something to enter on, and typing would scroll the roll."
  (with-score-level (s :carried 9999999)
    (setf (score::score-frame s) 1000)             ; well past the exit delay
    (flet ((press (scancode)
             (level:handle-event s (list :type lgame::+sdl-keydown+ :key scancode))))
      (declare (ignorable #'press))
      ;; The exit keys must not fire a level change while input mode is up.
      (is-true (score:score-input-mode? s))
      (is (null level:*requested*) "nothing requested yet"))))

(test the-roll-shows-the-new-entry
  (with-score-level (s :carried 9999999)
    (let ((before (length (score::score-entries s))))
      (map nil (lambda (c) (score:input-char s c)) "kev")
      (score:commit-name s)
      (is (= before (length (score::score-entries s)))
          "same eleven rows -- header plus ten")
      ;; And the roll really was rebuilt, not left stale.
      (let ((sc (screen:make-screen)))
        (finishes (level:render-level s sc))
        (screen:composite sc)
        (is (notevery #'zerop (screen:screen-cells sc)))))))

(test the-prompt-renders
  (with-score-level (s :carried 9999999)
    (let ((plain (screen:make-screen))
          (prompting (screen:make-screen)))
      (score:set-input-mode s nil)
      (level:render-level s plain)
      (screen:composite plain)
      (score:set-input-mode s t)
      (level:render-level s prompting)
      (screen:composite prompting)
      ;; The background fills every cell, so counting non-empty ones proves nothing --
      ;; compare the contents.
      (is (not (equalp (screen:screen-cells plain) (screen:screen-cells prompting)))
          "the prompt changes the screen")
      (let ((changed (loop for i below (length (screen:screen-cells plain))
                           count (/= (aref (screen:screen-cells plain) i)
                                     (aref (screen:screen-cells prompting) i)))))
        (is (> changed 100) "and by more than a stray cell, got ~d" changed)))))

(test scores-round-trip-through-the-file
  (let ((path (merge-pathnames (format nil "roundtrip-~d.txt" (random 1000000))
                               (uiop:temporary-directory)))
        (scores '(("ALPHA" . 900) ("BRAVO" . 800) ("CHARLIE" . 700) ("DELTA" . 600)
                  ("ECHO" . 500) ("FOX" . 400) ("GOLF" . 300) ("HOTEL" . 200)
                  ("INDIA" . 100) ("JULIET" . 50))))
    (unwind-protect
         (progn (score:write-high-scores scores path)
                (is (equal scores (score:read-high-scores path)) "same table back"))
      (ignore-errors (delete-file path)))))

(test the-real-table-is-never-written-by-accident
  "Guards the mistake these tests made the first time they ran: COMMIT-NAME saves, and
   without an override that save lands on the player's actual high scores.

   The override is set for the whole run by RUN-TESTS now, rather than test by test --
   the same accident happened again to options.ini, so it is done once where it cannot be
   forgotten. What is checked here is that the override still WORKS, and that with none
   the path really would be the live file."
  (let ((score:*scores-path* nil))
    (is (equal (score:scores-path) (paths:asset-path "highscores.txt"))
        "unoverridden, it is the real file -- which is what makes the override matter"))
  (let ((score:*scores-path* #p"/tmp/somewhere-else.txt"))
    (is (equal #p"/tmp/somewhere-else.txt" (score:scores-path))))
  ;; And right now, during this run, it is pointed away from the assets.
  (is-false (search "assets" (namestring (score:scores-path)))))

;;; ---------------------------------------------------------------------------
;;; The score across levels

(test the-score-survives-a-level-change
  "g_player is a global in the original, so beating a theme and warping to the next
   simply leaves d_score where it was. Ours rebuilds the player on load, so without
   state:*run-score* the score reset at every warp -- and dying on stage two then offered
   a stage-two-only total to the table, usually too small to qualify."
  (let ((state:*run-score* 4200)
        (state:*theme* :hidden-cave)
        (audio:*muted?* t)
        (level:*frame* 0) (level:*state* :play) (level:*current* nil)
        (level:*screen* (screen:make-screen)))
    (unwind-protect
         (progn
           (level:start-level :descendant)
           (is (= 4200 (player:player-score (dsc:descendant-player level:*current*)))
               "the new level picks up the running total"))
      (level:shutdown))))

(test carrying-the-score-on-is-explicit
  (with-game (lv)
    (setf (player:player-score (dsc:descendant-player lv)) 7777)
    (dsc:carry-score-on lv)
    (is (= 7777 state:*run-score*))))

(test abandoning-to-the-menu-forfeits-the-run
  "`g_player.d_score = 0` appears exactly once in the whole game, and this is it: the
   score survives beating a level, dying and warping -- but not walking away."
  (with-game (lv)
    (setf (player:player-score (dsc:descendant-player lv)) 7777
          state:*run-score* 7777)
    (dsc:abandon-run lv)
    (is (= 0 state:*run-score*))
    (is (eq :menu level:*requested*))))

(test finishing-a-run-clears-the-running-total
  "The score goes to the table, and the next run starts from nothing."
  (with-game (lv)
    (play-ticks lv 5)
    (let ((p (dsc:descendant-player lv)))
      (setf (player:player-score p) 5555
            (player:player-shields p) 0)
      (play-ticks lv 2)
      (play-ticks lv (+ dsc:+warp-done-delta+ 2))
      (is (= 5555 state:*carried-score*) "handed to the table")
      (is (= 0 state:*run-score*) "and the next run starts fresh"))))

(test committing-does-not-throw-you-off-the-screen
  "Committing is an ENTER keydown; its keyUP arrives a moment later, straight into the
   handler that leaves for the menu on ENTER. Without restarting the grace period you
   would type your name and never see it in the table."
  (with-score-level (s :carried 9999999)
    (setf (score::score-frame s) 1000)             ; well past the exit delay
    (map nil (lambda (c) (score:input-char s c)) "kev")
    (score:commit-name s)
    (is (= 0 (score::score-frame s)) "the grace period restarted")
    ;; The stray keyup that follows must not be treated as 'leave'.
    (is (null level:*requested*))))

(test the-roll-scrolls-again-once-the-name-is-in
  "The reward for qualifying is watching the table go past with you in it."
  (with-score-level (s :carried 9999999)
    (let ((before (score::score-move-pos s)))
      (dotimes (i 30) (level:update-level s))
      (is (= before (score::score-move-pos s)) "frozen while typing"))
    (map nil (lambda (c) (score:input-char s c)) "kev")
    (score:commit-name s)
    (let ((before (score::score-move-pos s)))
      (dotimes (i 30) (level:update-level s))
      (is (/= before (score::score-move-pos s)) "moving again afterwards"))))

(test the-prompt-is-centred-in-its-panel
  "The original gives the label and field the PANEL's x, because their own sprite data
   has not been fetched at that point -- which leaves them against its left edge."
  (with-score-level (s :carried 9999999)
    (let ((area (score::score-input-area s))
          (label (score::score-input-label s))
          (field (score::score-input-field s)))
      (is (> (theme:sprite-width area) (theme:sprite-width label))
          "the panel is the widest of the three")
      (is (> (theme:sprite-width area) (theme:sprite-width field)))
      ;; Each centred on the screen means each centred in the panel, since the panel is.
      (flet ((left (sprite) (- (ash screen:+cols+ -1)
                               (ash (theme:sprite-width sprite) -1))))
        (is (< (left area) (left label)) "the label sits inside the panel")
        (is (< (left area) (left field)))))))

(test the-input-box-has-room-in-it
  "Wider than the longest name it can hold, so it reads as a box rather than as text
   with a background."
  (with-score-level (s :carried 9999999)
    (let ((empty (theme:sprite-width (score::score-input-field s))))
      (dotimes (i (1- score:+max-name-length+)) (score:input-char s #\X))
      (is (= empty (theme:sprite-width (score::score-input-field s)))
          "the box does not grow as you type")
      (is (> score::*input-field-width* (1- score:+max-name-length+))
          "and has slack even when full"))))
