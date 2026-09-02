(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The hidden gallery reached with B from the credits, and the wipe that gets there.

;;; ---------------------------------------------------------------------------
;;; The wipe

(defun %a-colormap ()
  (theme:theme-colormap (theme:read-theme (paths:theme-path "crash_site.thm"))))

(test a-wipe-does-nothing-until-started
  (let ((w (wipe:make-wipe (%a-colormap)))
        (sc (screen:make-screen)))
    (is-false (wipe:running? w))
    (wipe:render w sc 12)
    (screen:composite sc)
    (is (zerop (loop for y below screen:+rows+
                     sum (loop for x below screen:+cols+
                               count (plusp (screen:cell-ref sc x y)))))
        "nothing is drawn before the wipe starts")))

(test a-wipe-covers-the-whole-screen
  "The point of it: once it reports covered, what is underneath can be swapped without
   the change being visible."
  (let ((w (wipe:make-wipe (%a-colormap)))
        (sc (screen:make-screen)))
    (wipe:start w)
    (loop repeat (wipe:wipe-ticks w) do (wipe:update w))
    (is-true (wipe:covered? w))
    (wipe:render w sc 12)
    (screen:composite sc)
    (let ((empty (loop for y below screen:+rows+
                       sum (loop for x below screen:+cols+
                                 count (zerop (screen:cell-ref sc x y))))))
      (is (zerop empty) "~d cells were left uncovered" empty))))

(test a-wipe-grows-from-the-centre
  (let ((w (wipe:make-wipe (%a-colormap)))
        (mid-x (floor screen:+cols+ 2))
        (mid-y (floor screen:+rows+ 2)))
    (wipe:start w)
    ;; A single tick paints the middle and nothing near the corners.
    (wipe:update w)
    (let ((sc (screen:make-screen)))
      (wipe:render w sc 12)
      (screen:composite sc)
      (is (plusp (screen:cell-ref sc mid-x mid-y)) "the centre goes first")
      (is (zerop (screen:cell-ref sc 0 0)) "the corner comes last"))))

(test a-wipe-runs-for-its-allotted-time
  (let ((w (wipe:make-wipe (%a-colormap) :ticks 10)))
    (wipe:start w)
    (is (= 0.0 (wipe:progress w)))
    (loop repeat 10 do (is-true (wipe:update w) "still running"))
    (is (= 1.0 (wipe:progress w)))
    (is-false (wipe:update w) "and then it stops")))

(test the-wipe-gradient-follows-the-palette
  "Bands are drawn from the palette in use, sorted dark to light, so the effect reads as a
   gradient in whichever colours the destination happens to have."
  (let* ((cm (%a-colormap))
         (w (wipe:make-wipe cm))
         (ramp (wipe:wipe-ramp w)))
    (is (= 16 (length ramp)))
    (is (= 16 (length (remove-duplicates (coerce ramp 'list))))
        "every slot appears exactly once")
    (loop for i from 1 below 16
          do (is (<= (theme:color-luminance (theme:colormap-ref cm (aref ramp (1- i))))
                     (theme:color-luminance (theme:colormap-ref cm (aref ramp i))))
                 "the ramp is ordered by brightness"))))

;;; ---------------------------------------------------------------------------
;;; Names

(test config-keys-become-readable-names
  (is (string= "FLOOGLE" (bestiary:display-name "enemy_ship_floogle")))
  (is (string= "GEAR" (bestiary:display-name "boss_Gear")))
  (is (string= "DOOMWORM" (bestiary:display-name "boss_doomworm")))
  (is (string= "BRIDGE" (bestiary:display-name "enemy_midboss_bridge")))
  ;; A turret keeps the word: LIGHT on its own names nothing.
  (is (string= "LIGHT TURRET" (bestiary:display-name "turret_light")))
  (is (string= "FAKER TURRET" (bestiary:display-name "turret_faker")))
  ;; And one that already says it is not given it twice.
  (is (string= "TOPFAKER TURRET" (bestiary:display-name "turret_topfaker")))
  (is (search "TURRET" (bestiary:display-name "enemy_turret_faker"))))

;;; ---------------------------------------------------------------------------
;;; The gallery

(defmacro with-bestiary ((var) &body body)
  `(let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play) (level:*current* nil))
     (unwind-protect
          (progn
            (level:start-level :bestiary)
            (let ((,var level:*current*))
              ,@body))
       (level:shutdown))))

(test every-exhibit-is-actually-placed
  "A boss would otherwise be silently missing: SPAWN-ALLOWED? refuses bosses until ten
   midbosses have died, and a gallery has no deaths behind it."
  (with-bestiary (lv)
    (is (= 3 (length (bestiary:bestiary-stages lv))))
    (dolist (stage (bestiary:bestiary-stages lv))
      (is (plusp (length (bestiary:stage-exhibits stage))))
      (dolist (x (bestiary:stage-exhibits stage))
        (is-true (bestiary:exhibit-enemy x)
                 "~a on ~a has no enemy" (bestiary:exhibit-name x)
                 (bestiary:stage-key stage))))
    ;; Specifically the three that the gate would have refused.
    (let ((names (loop for st in (bestiary:bestiary-stages lv)
                       append (mapcar #'bestiary:exhibit-name
                                      (bestiary:stage-exhibits st)))))
      (dolist (boss '("boss_Gear" "boss_doomworm" "boss_Battleship"))
        (is-true (member boss names :test #'string=) "~a is missing" boss)))))

(test the-gallery-fits-on-the-screen
  (with-bestiary (lv)
    (dolist (stage (bestiary:bestiary-stages lv))
      (dolist (x (bestiary:stage-exhibits stage))
        (let* ((e (bestiary:exhibit-enemy x))
               (r (enemies:enemy-rect e))
               (label (bestiary:exhibit-label x))
               (left (bestiary:exhibit-x x))
               (right (+ left (bestiary:exhibit-width x)))
               (bottom (+ (bestiary:exhibit-y x)
                          (rect:rect-h r)
                          2                       ; the label gap
                          (theme:sprite-height label))))
          (is (<= 0 left) "~a starts off the left edge" (bestiary:exhibit-name x))
          (is (<= right screen:+cols+)
              "~a runs past the right edge to ~d" (bestiary:exhibit-name x) right)
          (is (<= bottom screen:+rows+)
              "~a's name plate runs past the bottom to ~d"
              (bestiary:exhibit-name x) bottom))))))

(test exhibits-do-not-overlap
  "The packer is the only thing standing between a config change and two enemies drawn on
   top of each other."
  (with-bestiary (lv)
    (dolist (stage (bestiary:bestiary-stages lv))
      (let ((boxes (mapcar (lambda (x)
                             (let ((e (bestiary:exhibit-enemy x)))
                               (list (bestiary:exhibit-name x)
                                     (bestiary:exhibit-x x)
                                     (bestiary:exhibit-y x)
                                     (bestiary:exhibit-width x)
                                     (+ (rect:rect-h (enemies:enemy-rect e))
                                        2
                                        (theme:sprite-height (bestiary:exhibit-label x))))))
                           (bestiary:stage-exhibits stage))))
        (loop for (a . rest) on boxes
              do (dolist (b rest)
                   (destructuring-bind (name-a ax ay aw ah) a
                     (destructuring-bind (name-b bx by bw bh) b
                       (is-false (and (< ax (+ bx bw)) (< bx (+ ax aw))
                                      (< ay (+ by bh)) (< by (+ ay ah)))
                                 "~a and ~a overlap on ~a"
                                 name-a name-b (bestiary:stage-key stage))))))))))

(test the-chaser-is-exhibited-once
  "It is in all three level configs -- it follows the player everywhere -- so showing each
   roster faithfully would put it on every screen."
  (with-bestiary (lv)
    (let ((count (loop for st in (bestiary:bestiary-stages lv)
                       count (find "boss_Chaser" (bestiary:stage-exhibits st)
                                   :key #'bestiary:exhibit-name :test #'string=))))
      (is (= 1 count) "the chaser appears on ~d stages" count))))

(test the-worm-is-flush-with-the-right-edge
  "It is a slice of a much longer body; parking it clear of the edge shows a blunt end."
  (with-bestiary (lv)
    (let* ((stage (find :hidden-cave (bestiary:bestiary-stages lv)
                        :key #'bestiary:stage-key))
           (worm (find "boss_doomworm" (bestiary:stage-exhibits stage)
                       :key #'bestiary:exhibit-name :test #'string=)))
      (is-true worm)
      (let ((r (enemies:enemy-rect (bestiary:exhibit-enemy worm))))
        (is (= screen:+cols+ (+ (rect:rect-x r) (rect:rect-w r)))
            "its right edge sits at ~d, not the screen edge"
            (+ (rect:rect-x r) (rect:rect-w r)))))))

(test the-gallery-cycles-through-every-stage
  (with-bestiary (lv)
    (let ((seen '()))
      ;; Three stages plus a little, so it must wrap.
      (dotimes (i (* 4 (+ bestiary:+stage-ticks+ wipe:+default-ticks+ 4)))
        (declare (ignore i))
        (level:update-level lv)
        (pushnew (bestiary:stage-key (bestiary:current-stage lv)) seen))
      (is (= 3 (length seen)) "saw ~a" seen))))

(test the-palette-changes-with-the-stage
  "The whole reason this screen exists: each stage is shown in its own colours, which the
   credits parade cannot do because only one palette is uploaded per frame."
  (with-bestiary (lv)
    (let ((first-map (level:level-colormap lv)))
      (bestiary:advance-stage lv)
      (is-false (eq first-map (level:level-colormap lv))
                "a new stage brings a new colormap"))))

(defun %run-past-reveal (lv)
  "The gallery opens with a reveal; run it out so the stage timer starts from zero."
  (loop while (eq (bestiary:bestiary-phase lv) :reveal)
        do (level:update-level lv)))

(test enemies-hold-still-then-fire
  (with-bestiary (lv)
    (%run-past-reveal lv)
    (let ((pool (bestiary:stage-bullets (bestiary:current-stage lv))))
      (dotimes (i (1- bestiary:+settle-ticks+))
        (declare (ignore i))
        (level:update-level lv))
      (is (zerop (bullets:live-count pool)) "still holding")
      (dotimes (i 4) (declare (ignore i)) (level:update-level lv))
      (is (plusp (bullets:live-count pool)) "and then they fire"))))

(test the-guns-do-not-all-open-at-once
  "Firing every exhibit on the same tick reads as one event rather than as each enemy
   doing its own thing."
  (with-bestiary (lv)
    (%run-past-reveal lv)
    (let ((stage (bestiary:current-stage lv)))
      (let ((schedule (mapcar #'bestiary::exhibit-next-fire
                              (bestiary:stage-exhibits stage))))
        (is (= (length schedule) (length (remove-duplicates schedule)))
            "each exhibit has its own moment: ~a" schedule)
        (is (>= (- (reduce #'max schedule) (reduce #'min schedule))
                (* bestiary::+fire-stagger+
                   (1- (length (bestiary:stage-exhibits stage)))))
            "and they are spread, not merely distinct")))))

(test exhibits-fire-more-than-once
  "The screen is up for seven seconds; a single volley leaves most of that a still life."
  (with-bestiary (lv)
    (%run-past-reveal lv)
    (let ((x (first (bestiary:stage-exhibits (bestiary:current-stage lv))))
          (volleys 0)
          (last nil))
      (dotimes (i bestiary:+stage-ticks+)
        (declare (ignore i))
        (when (eq (bestiary:bestiary-phase lv) :show)
          (let ((due (bestiary::exhibit-next-fire x)))
            (when (and last (/= due last)) (incf volleys))
            (setf last due)))
        (level:update-level lv))
      (is (>= volleys 2) "it fired ~d times" (1+ volleys)))))

(test the-gallery-opens-and-closes-with-the-wipe
  "Cover, swap while nothing shows, then run the same shape backwards. Cutting straight
   to a finished screen was the jarring part."
  (with-bestiary (lv)
    (is (eq :reveal (bestiary:bestiary-phase lv)) "it opens by revealing")
    (is (eq :reveal (wipe:wipe-direction (bestiary:bestiary-wipe lv))))
    (%run-past-reveal lv)
    (is (eq :show (bestiary:bestiary-phase lv)))
    ;; Run to the end of the stage and watch the handover.
    (loop until (eq (bestiary:bestiary-phase lv) :cover)
          do (level:update-level lv))
    (is (eq :cover (wipe:wipe-direction (bestiary:bestiary-wipe lv))))
    (let ((before (bestiary:stage-key (bestiary:current-stage lv))))
      (loop until (eq (bestiary:bestiary-phase lv) :reveal)
            do (level:update-level lv))
      (is-false (eq before (bestiary:stage-key (bestiary:current-stage lv)))
                "the stage changed while the screen was hidden")
      (is (eq :reveal (wipe:wipe-direction (bestiary:bestiary-wipe lv)))))))

(test a-reveal-runs-the-cover-backwards
  (let ((w (wipe:make-wipe (%a-colormap) :ticks 10)))
    (wipe:start w :reveal)
    (is (= 1.0 (wipe:progress w)) "a reveal starts with the screen covered")
    (loop repeat 5 do (wipe:update w))
    (is (< 0.4 (wipe:progress w) 0.6) "and shrinks back toward the centre")
    (loop repeat 5 do (wipe:update w))
    (is (= 0.0 (wipe:progress w)))
    (is-false (wipe:covered? w) "a reveal never reports the screen as hidden")))

(test gallery-projectiles-do-not-accumulate
  "Same trap as the credits parade: no collision world, so nothing else reaps a shot that
   has left the screen."
  (with-bestiary (lv)
    (dotimes (i (* 3 (+ bestiary:+stage-ticks+ wipe:+default-ticks+ 4)))
      (declare (ignore i))
      (level:update-level lv))
    (dolist (stage (bestiary:bestiary-stages lv))
      (is (< (bullets:live-count (bestiary:stage-bullets stage)) 200)
          "~a is holding ~d projectiles" (bestiary:stage-key stage)
          (bullets:live-count (bestiary:stage-bullets stage))))))

(test escape-leaves-the-gallery
  (with-bestiary (lv)
    (is (string= "bestiary" (level:level-name lv)))))

;;; ---------------------------------------------------------------------------
;;; Getting there

(test the-music-carries-into-the-gallery-and-back
  "The credits and the gallery behind them are one continuous place. Halting the track at
   the door and restarting it on the way back announces a level change the player is not
   meant to notice."
  (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play)
        (level:*current* nil) (level:*requested* nil)
        (audio:*retained-music* nil))
    (unwind-protect
         (progn
           (level:start-level :credits)
           (let ((track (credits::credits-music level:*current*)))
             ;; Only meaningful if the credits actually have a track to hand on.
             (when track
               (let ((level:*requested* :bestiary))
                 (level:unload-level level:*current*))
               (is (eq track (audio:retained-music))
                   "the track is handed on rather than freed")
               ;; And the credits take it back still playing, without loading a second copy.
               (level:start-level :credits)
               (is (eq track (credits::credits-music level:*current*))
                   "the same track, not a reload")
               (is-false (audio:retained-music) "and it is owned again"))))
      (level:shutdown))))

(test leaving-the-credits-for-anywhere-else-still-stops-the-music
  (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play)
        (level:*current* nil) (level:*requested* nil)
        (audio:*retained-music* nil))
    (unwind-protect
         (progn
           (level:start-level :credits)
           (let ((level:*requested* :menu))
             (level:unload-level level:*current*))
           (is-false (audio:retained-music)))
      (level:shutdown))))

(test the-credits-wipe-hands-over-once-the-screen-is-hidden
  "The transition runs on the credits rather than in the gallery, so that what it covers
   is the credits themselves. The level only changes once nothing of them is visible."
  (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play)
        (level:*current* nil) (level:*requested* nil))
    (unwind-protect
         (progn
           (level:start-level :credits)
           (let* ((lv level:*current*)
                  (w (credits:credits-wipe lv)))
             (is-true w)
             (is-false (wipe:running? w))
             (wipe:start w)
             ;; Nothing should change hands while any of the credits still shows.
             (loop repeat (1- (wipe:wipe-ticks w))
                   do (level:update-level lv)
                      (is-false level:*requested*
                                "handed over while the screen was still partly visible"))
             (level:update-level lv)
             (is (eq :bestiary level:*requested*))))
      (level:shutdown))))
