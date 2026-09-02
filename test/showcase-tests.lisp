(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The enemy parade across the credit roll, and the palette retoning it needs.

;;; ---------------------------------------------------------------------------
;;; Encoding colours back into a pair

(test encode-pair-inverts-the-decoders
  "RECOLOR-SPRITE has to write a pair that paints a chosen palette slot, which is the
   opposite direction from everything else in GLYPH. Both nibbles route through the Win32
   permutation tables, so this is not the identity and is worth pinning."
  (dolist (mapping '(:original :authored))
    (let ((glyph:*colour-mapping* mapping))
      (dotimes (fg 16)
        (dotimes (bg 16)
          (let ((g (glyph:make-glyph 65 (glyph:encode-pair fg bg))))
            (is (= fg (glyph:glyph-fg-index g))
                "~a: fg ~d survived as ~d" mapping fg (glyph:glyph-fg-index g))
            (is (= bg (glyph:glyph-bg-index g))
                "~a: bg ~d survived as ~d" mapping bg (glyph:glyph-bg-index g))))))))

;;; ---------------------------------------------------------------------------
;;; Retoning

(defun %credits-colormap ()
  (theme:theme-colormap (theme:read-theme (paths:theme-path "credits.thm"))))

(test luminance-map-lands-inside-the-target-palette
  (let* ((src (theme:theme-colormap (theme:read-theme (paths:theme-path "crash_site.thm"))))
         (table (theme:luminance-map src (%credits-colormap))))
    (is (= 16 (length table)))
    (loop for i below 16
          do (is (<= 0 (aref table i) 15) "slot ~d maps into range" i))))

(test luminance-map-is-monotone
  "Brighter in, brighter out. This is the property that keeps a sprite's shading -- its
   dark outline and its highlights -- in the same relative order after retoning, which is
   what makes the shape still read."
  (let* ((src (theme:theme-colormap (theme:read-theme (paths:theme-path "brain_pain.thm"))))
         (dst (%credits-colormap))
         (table (theme:luminance-map src dst))
         (order (sort (loop for i below 16 collect i) #'<
                      :key (lambda (i) (theme:color-luminance (theme:colormap-ref src i))))))
    (loop for (a b) on order
          while b
          do (is (<= (theme:color-luminance (theme:colormap-ref dst (aref table a)))
                     (theme:color-luminance (theme:colormap-ref dst (aref table b))))
                 "slot ~d is no brighter than ~d, so their images must not invert" a b))))

(test recoloring-keeps-the-shape
  "Only the colours change: the characters, the transparency and the geometry are what
   make the sprite recognisable and must come through untouched."
  (let* ((th (theme:read-theme (paths:theme-path "brain_pain.thm")))
         (original (theme:find-sprite th "enemy_ship_stealth"))
         (table (theme:luminance-map (theme:theme-colormap th) (%credits-colormap)))
         (toned (theme:recolor-sprite original table)))
    (is (= (theme:sprite-width original) (theme:sprite-width toned)))
    (is (= (theme:sprite-height original) (theme:sprite-height toned)))
    (is (= (theme:sprite-frames original) (theme:sprite-frames toned)))
    (let ((cells 0) (recoloured 0))
      (map nil (lambda (a b)
                 (is (eq (glyph:transparent? a) (glyph:transparent? b))
                     "transparency must not move")
                 (unless (glyph:transparent? a)
                   (incf cells)
                   (is (= (glyph:glyph-char a) (glyph:glyph-char b)) "the character stands")
                   (is (= (glyph:glyph-mod a) (glyph:glyph-mod b)) "so does the mod byte")
                   (unless (= (glyph:glyph-pair a) (glyph:glyph-pair b))
                     (incf recoloured))))
           (theme:sprite-glyphs original) (theme:sprite-glyphs toned))
      (is (plusp cells))
      (is (plusp recoloured) "and something actually changed colour"))))

(test recolor-theme-carries-the-destination-palette
  (let* ((dst (%credits-colormap))
         (toned (theme:recolor-theme
                 (theme:read-theme (paths:theme-path "crash_site.thm")) dst
                 '("enemy_floogle" "enemy_kamikaze"))))
    (is (eq dst (theme:theme-colormap toned)))
    (is (= 2 (length (theme:sprite-names toned))) "NAMES limits the work")
    (is-true (theme:find-sprite toned "enemy_floogle"))
    (is-false (theme:find-sprite toned "warp_hole") "and skips everything else")))

;;; ---------------------------------------------------------------------------
;;; The parade

(defmacro with-showcase ((var) &body body)
  `(let ((,var (showcase:make-showcase (%credits-colormap))))
     (unwind-protect (progn ,@body)
       (showcase:free ,var))))

(test every-roster-entry-resolves
  "A mistyped definition name would cost nothing at load and simply show nothing, so the
   roster is checked against the shipped configs rather than trusted."
  (with-showcase (s)
    (let ((pool (showcase::showcase-enemies s)))
      (dolist (stage showcase:*roster*)
        (destructuring-bind (config theme bullets entries) stage
          (declare (ignore config theme bullets))
          (dolist (spec entries)
            (is-true (enemies:definition pool (first spec))
                     "~s is not a definition in any shipped config" (first spec))))))
    (is (= (loop for stage in showcase:*roster* sum (length (fourth stage)))
           (length (showcase::showcase-entries s)))
        "and every one of them got a name plate")))

(test the-parade-covers-the-whole-roster
  "Round robin, so no enemy is left out however long the roll runs."
  (with-showcase (s)
    (let ((seen (make-hash-table :test #'equal))
          (n (length (showcase::showcase-entries s))))
      ;; Two lanes, so a full sweep takes about half as many cycles as there are entries.
      (dotimes (i (* showcase:+cycle-ticks+ (1+ n)))
        (declare (ignore i))
        (showcase:update s)
        (dolist (slot (showcase:showcase-slots s))
          (let ((e (showcase:slot-entry slot)))
            (when e (setf (gethash (showcase:entry-enemy e) seen) t)))))
      (is (= n (hash-table-count seen))
          "~d of ~d enemies appeared" (hash-table-count seen) n))))

(test the-lanes-do-not-march-in-step
  (with-showcase (s)
    (let ((delays (mapcar #'showcase:slot-delay (showcase:showcase-slots s))))
      (is (= (length delays) (length (remove-duplicates delays)))
          "each lane waits a different time before its first turn")
      (is (find 0 delays) "and one of them starts straight away"))
    ;; The stagger has to survive contact with the update loop, not just construction.
    ;; Phase names are the wrong measure -- the hold is 116 of the 184 ticks, so two lanes
    ;; a half-cycle apart are legitimately both holding. The timers are the real thing.
    (dotimes (i (+ showcase:+cycle-ticks+ 40))
      (declare (ignore i))
      (showcase:update s))
    (let ((timers (mapcar #'showcase:slot-timer (showcase:showcase-slots s))))
      (is (= (length timers) (length (remove-duplicates timers)))
          "the lanes fell into step after a full cycle: ~a" timers)
      (is (> (abs (- (first timers) (second timers))) 20)
          "and they are still meaningfully apart, not just off by a tick: ~a" timers))))

(test projectiles-do-not-accumulate
  "There is no collision world here, so nothing else notices a bullet leaving the screen.
   Without the cull the pool drains and the parade goes quiet after a minute or so."
  (with-showcase (s)
    (dotimes (i (* showcase:+cycle-ticks+ 12))
      (declare (ignore i))
      (showcase:update s))
    (let ((live (length (bullets:pool-live (showcase:showcase-bullets s)))))
      (is (< live 120)
          "~d projectiles still live after twelve cycles" live)
      (is-true (plusp (length (bullets:pool-free (showcase:showcase-bullets s))))
               "and the pool still has slots to fire from"))))

(test the-bosses-are-on-the-bill
  "The roster is the whole cast, not just the rank and file."
  (with-showcase (s)
    (let ((names (loop for e across (showcase::showcase-entries s)
                       collect (showcase:entry-enemy e))))
      (dolist (boss '("boss_Gear" "boss_doomworm" "boss_Battleship"
                      "boss_Omegablaster" "enemy_midboss_bridge" "midboss_HeavyWall"
                      "boss_Chaser"))
        (is-true (member boss names :test #'string=) "~a is missing" boss)))))

(test the-big-ones-take-the-screen-alone
  "The doomworm is 80 rows of an 120-row screen; parked in a lane it would sit on top of
   whatever is in the other one."
  (with-showcase (s)
    (let ((tall (find-if (lambda (e) (string= (showcase:entry-enemy e) "boss_doomworm"))
                         (showcase::showcase-entries s))))
      (is-true tall)
      (is (> (showcase:entry-height tall) (showcase:showcase-solo-height s))
          "the worm counts as oversized"))
    ;; Run long enough for every entry to have had a turn, and check that nothing ever
    ;; shares the screen with a solo act.
    (dotimes (i (* showcase:+cycle-ticks+ (1+ (length (showcase::showcase-entries s)))))
      (declare (ignore i))
      (showcase:update s)
      ;; Anything already out when a solo act arrives is sent off rather than cut, so the
      ;; two do overlap briefly at the right edge while one leaves and the other enters.
      ;; What must never happen is a second enemy still there once the solo act settles.
      (let ((solo (showcase:showcase-solo s)))
        (when (and solo (eq (showcase:slot-phase solo) :hold))
          (dolist (other (showcase:showcase-slots s))
            (unless (eq other solo)
              (is-false (showcase:slot-entry other)
                        "~a was still on screen while ~a held it alone"
                        (showcase:entry-enemy (showcase:slot-entry other))
                        (showcase:entry-enemy (showcase:slot-entry solo))))))))))

(test a-boss-waits-rather-than-cutting-anyone-short
  "Reported: the oversized entries used to shove whatever was on screen into an early
   exit. Every turn now runs its full length; the boss queues up and takes the screen once
   it is free."
  (with-showcase (s)
    (let ((turns (make-hash-table :test #'eq))     ; slot -> ticks of the current turn
          (short '()))
      (dotimes (i (* showcase:+cycle-ticks+ (1+ (length (showcase::showcase-entries s)))))
        (declare (ignore i))
        (showcase:update s)
        (dolist (slot (showcase:showcase-slots s))
          (if (showcase:slot-entry slot)
              (incf (gethash slot turns 0))
              ;; Just ended. Every completed turn should be the same length as every
              ;; other -- the bug was turns cut short to make room for a boss.
              (let ((ran (gethash slot turns 0)))
                (when (plusp ran)
                  (push ran short)
                  (setf (gethash slot turns) 0))))))
      (is (> (length short) (length (showcase:showcase-slots s)))
          "the run was long enough to see several complete turns")
      (is (= 1 (length (remove-duplicates short)))
          "turns ran for differing lengths ~a; a boss cut someone short"
          (sort (remove-duplicates short) #'<)))))

(test the-screen-is-clear-before-a-solo-act-arrives
  (with-showcase (s)
    (let ((waited nil))
      (dotimes (i (* showcase:+cycle-ticks+ (1+ (length (showcase::showcase-entries s)))))
        (declare (ignore i))
        (showcase:update s)
        (when (showcase:showcase-pending s) (setf waited t))
        ;; The moment a solo act begins its entrance, nothing else may be out.
        (let ((solo (showcase:showcase-solo s)))
          (when (and solo (eq (showcase:slot-phase solo) :in))
            (dolist (other (showcase:showcase-slots s))
              (unless (eq other solo)
                (is-false (showcase:slot-entry other)
                          "~a was still on screen as a solo act flew in"
                          (showcase:entry-enemy (showcase:slot-entry other))))))))
      (is-true waited "a boss should have had to queue at least once"))))

(test name-plates-stay-on-screen
  "Placement is pulled up from the lane when an entry is too tall for its name to fit
   underneath -- without that the worm's plate falls off the bottom edge."
  (with-showcase (s)
    (loop for e across (showcase::showcase-entries s)
          do (dolist (slot (showcase:showcase-slots s))
               (let ((row (showcase::%entry-row s slot e)))
                 (is (<= (+ row (showcase:entry-height e)) showcase:+band-bottom+)
                     "~a runs to row ~d" (showcase:entry-enemy e)
                     (+ row (showcase:entry-height e))))))))

(test a-turn-lasts-about-three-seconds
  "Long enough to read the name and watch the pattern travel; the first cut at two was
   too brisk."
  (is (= showcase:+cycle-ticks+ 184))
  (let ((seconds (/ showcase:+cycle-ticks+ 62.5)))
    (is (< 2.5 seconds 3.5) "a turn runs ~,2f seconds" seconds))
  (is (every (lambda (v) (< v showcase::+hold-ticks+)) showcase::*volley-ticks*)
      "every volley falls inside the hold"))

(test enemies-hold-in-the-right-half
  "They are meant to share the screen with the roll, which is indented from the left."
  (with-showcase (s)
    (let ((held 0))
      (dotimes (i (* showcase:+cycle-ticks+ 4))
        (declare (ignore i))
        (showcase:update s)
        (dolist (slot (showcase:showcase-slots s))
          (when (and (eq (showcase:slot-phase slot) :hold)
                     (showcase:slot-entry slot))
            (incf held)
            (is (>= (showcase:slot-x slot) (ash screen:+cols+ -1))
                "an enemy held at x=~d, left of centre" (showcase:slot-x slot)))))
      (is (plusp held) "and some actually held"))))

;;; ---------------------------------------------------------------------------
;;; Wiring into the level

(test the-credits-level-runs-the-showcase
  (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play) (level:*current* nil))
    (unwind-protect
         (progn
           (level:start-level :credits)
           (let ((lv level:*current*)
                 (sc (screen:make-screen)))
             (is-true (credits:credits-showcase lv))
             (dotimes (i (* showcase:+cycle-ticks+ 2))
               (declare (ignore i))
               (level:update-level lv))
             (level:render-level lv sc)
             (screen:composite sc)
             ;; The parade draws under the roll, so the banner still owns its rows.
             (is (< credits::+z-showcase+ credits::+z-roll+))))
      (level:shutdown))))
