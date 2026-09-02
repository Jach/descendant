(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-test-sprite (width height glyphs &optional (frames 1))
  (theme::%make-sprite
   :name "test" :width width :height height :frames frames
   :glyphs (make-array (length glyphs) :element-type '(unsigned-byte 32)
                                       :initial-contents glyphs)))

(defun cells-all-zero? (screen)
  "Wrapped so a failure reports the form, not 28,800 integers."
  (every #'zerop (screen:screen-cells screen)))

(defun solid-sprite (width height glyph)
  (make-test-sprite width height (make-list (* width height) :initial-element glyph)))

(test screen-starts-clear
  (let ((s (screen:make-screen)))
    (is (= (* screen:+cols+ screen:+rows+) (length (screen:screen-cells s))))
    (is-true (cells-all-zero? s))))

(test blit-y-is-measured-from-the-bottom
  "The original computes the top row as (rows - Y), so Y = +rows+ lands at row 0."
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\A) 100)))
    (screen:blit-sprite s (solid-sprite 1 1 g) 5 screen:+rows+)
    (is (= g (screen:cell-ref s 5 0)))
    (screen:clear-screen s)
    (screen:blit-sprite s (solid-sprite 1 1 g) 5 1)
    (is (= g (screen:cell-ref s 5 (1- screen:+rows+))))))

(test blit-transparent-cells-do-not-overwrite
  (let* ((s (screen:make-screen))
         (under (glyph:make-glyph (char-code #\U) 50))
         (over (make-test-sprite 2 1 (list glyph:+transparent+
                                           (glyph:make-glyph (char-code #\O) 60)))))
    (screen:blit-sprite s (solid-sprite 2 1 under) 0 screen:+rows+)
    (screen:blit-sprite s over 0 screen:+rows+)
    (is (= under (screen:cell-ref s 0 0)) "transparent cell left the background alone")
    (is (= (char-code #\O) (glyph:glyph-char (screen:cell-ref s 1 0))))))

(test blit-transparent-background-mod
  "A mod byte of #xFF keeps the background underneath and applies only the foreground.
   Asserted on the colour-pair nibbles directly, since which palette slot each nibble
   selects is the separate concern of glyph:*colour-mapping*."
  (let* ((s (screen:make-screen))
         (under (glyph:make-glyph (char-code #\U) (logior (ash 7 4) 2)))
         (over-glyph (glyph:make-glyph (char-code #\O) (logior (ash 3 4) 5)
                                       glyph:+mod-transparent-bg+)))
    (screen:blit-sprite s (solid-sprite 1 1 under) 0 screen:+rows+)
    (screen:blit-sprite s (solid-sprite 1 1 over-glyph) 0 screen:+rows+)
    (let* ((result (screen:cell-ref s 0 0))
           (pair (glyph:glyph-pair result)))
      (is (= (char-code #\O) (glyph:glyph-char result)) "character comes from the top")
      (is (= 7 (ash pair -4)) "background nibble survives from underneath")
      (is (= 5 (logand pair #x0F)) "foreground nibble comes from the top"))))

(test blit-clips-offscreen-sprites
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\X) 100)))
    ;; Entirely off each edge: nothing drawn, no error.
    (dolist (pos (list (list -10 screen:+rows+) (list (+ screen:+cols+ 5) screen:+rows+)
                       (list 0 (+ screen:+rows+ 50)) (list 0 -10)))
      (screen:clear-screen s)
      (screen:blit-sprite s (solid-sprite 4 4 g) (first pos) (second pos))
      (is-true (cells-all-zero? s) "sprite at ~s drew nothing" pos))))

(test blit-clips-partially-offscreen
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\X) 100)))
    ;; Straddling the left edge: columns -2..1 -> only x = 0, 1 land.
    (screen:blit-sprite s (solid-sprite 4 1 g) -2 screen:+rows+)
    (is (= g (screen:cell-ref s 0 0)))
    (is (= g (screen:cell-ref s 1 0)))
    (is (= 0 (screen:cell-ref s 2 0)))))

(test blit-reaches-the-last-column
  "We fixed the original's off-by-one, so a sprite ending exactly on the last column
   now paints it. PLAN.md section 7."
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\X) 100)))
    (screen:blit-sprite s (solid-sprite 2 1 g) (- screen:+cols+ 2) screen:+rows+)
    (is (= g (screen:cell-ref s (- screen:+cols+ 2) 0)))
    (is (= g (screen:cell-ref s (1- screen:+cols+) 0)))))

(test blit-still-clips-genuinely-overhanging-sprites
  "Fixing the off-by-one must not stop real overhang from being clipped."
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\X) 100)))
    (screen:blit-sprite s (solid-sprite 4 1 g) (- screen:+cols+ 2) screen:+rows+)
    (is (= g (screen:cell-ref s (- screen:+cols+ 2) 0)))
    (is (= g (screen:cell-ref s (1- screen:+cols+) 0)))
    (is-true (loop for y below screen:+rows+
                   always (loop for x below (- screen:+cols+ 2)
                                always (zerop (screen:cell-ref s x y))))
             "nothing drawn outside the sprite's two visible columns")))

(test blit-right-edge-off-by-one-can-be-reproduced
  "The original artifact, kept pinned behind the switch."
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\X) 100))
        (screen:*right-edge-off-by-one* t))
    (screen:blit-sprite s (solid-sprite 2 1 g) (- screen:+cols+ 2) screen:+rows+)
    (is (= g (screen:cell-ref s (- screen:+cols+ 2) 0)))
    (is (= 0 (screen:cell-ref s (1- screen:+cols+) 0))
        "last column dropped by the original's off-by-one")))

(test composite-layer-order
  "Higher z layers draw later and therefore cover lower ones."
  (let* ((s (screen:make-screen))
         (low (glyph:make-glyph (char-code #\L) 10))
         (high (glyph:make-glyph (char-code #\H) 20)))
    (screen:enqueue s (solid-sprite 1 1 low) 0 screen:+rows+ 0)
    (screen:enqueue s (solid-sprite 1 1 high) 0 screen:+rows+ 5)
    (screen:composite s)
    (is (= high (screen:cell-ref s 0 0)))))

(test composite-within-layer-first-enqueued-wins
  "Within one layer the original prepends to a list and walks it head-first, so the
   most recent is drawn first and the earliest ends up on top."
  (let* ((s (screen:make-screen))
         (first-in (glyph:make-glyph (char-code #\1) 10))
         (second-in (glyph:make-glyph (char-code #\2) 20)))
    (screen:enqueue s (solid-sprite 1 1 first-in) 0 screen:+rows+ 3)
    (screen:enqueue s (solid-sprite 1 1 second-in) 0 screen:+rows+ 3)
    (screen:composite s)
    (is (= first-in (screen:cell-ref s 0 0)))))

(test composite-empties-the-queues
  (let ((s (screen:make-screen))
        (g (glyph:make-glyph (char-code #\A) 100)))
    (screen:enqueue s (solid-sprite 1 1 g) 0 screen:+rows+ 0)
    (screen:composite s)
    (screen:composite s)
    (is-true (cells-all-zero? s) "the second composite had nothing queued")))

(test blit-selects-the-right-frame
  (let* ((s (screen:make-screen))
         (a (glyph:make-glyph (char-code #\A) 10))
         (b (glyph:make-glyph (char-code #\B) 20))
         (sprite (make-test-sprite 1 1 (list a b) 2)))
    (screen:blit-sprite s sprite 0 screen:+rows+ 0)
    (is (= a (screen:cell-ref s 0 0)))
    (screen:clear-screen s)
    (screen:blit-sprite s sprite 0 screen:+rows+ 1)
    (is (= b (screen:cell-ref s 0 0)))))

(defun blit-matches-source? (screen sprite &key (max-x screen:+cols+))
  "Every cell left of MAX-X must equal its source glyph, except transparent ones which
   must have been left cleared. Returns T, or a description of the first mismatch."
  (dotimes (y (theme:sprite-height sprite) t)
    (dotimes (x (min max-x (theme:sprite-width sprite)))
      (let* ((g (theme:sprite-ref sprite 0 y x))
             (cell (screen:cell-ref screen x y))
             (expected (if (glyph:transparent? g) 0 g)))
        (unless (= cell expected)
          (return-from blit-matches-source? (list x y :got cell :expected expected)))))))

(defun opaque-count (sprite &key (max-x screen:+cols+))
  (let ((n 0))
    (dotimes (y (theme:sprite-height sprite) n)
      (dotimes (x (min max-x (theme:sprite-width sprite)))
        (unless (glyph:transparent? (theme:sprite-ref sprite 0 y x)) (incf n))))))

(test full-screen-sprite-blits-exactly
  "menu_bg is exactly the cell grid, and with the off-by-one fixed all 240 columns get
   painted. Transparent cells must still be skipped rather than drawn as black."
  (let* ((s (screen:make-screen))
         (th (theme:read-theme (paths:theme-path "menu.thm")))
         (bg (theme:find-sprite th "menu_bg")))
    (is-false screen:*right-edge-off-by-one* "the fix is the default")
    (screen:blit-sprite s bg 0 screen:+rows+)
    (is (eq t (blit-matches-source? s bg)))
    (is (= (opaque-count bg) (count-if-not #'zerop (screen:screen-cells s))))))

(test full-screen-sprite-with-original-off-by-one
  "With the quirk reproduced, column 239 is never painted -- the original's dead stripe."
  (let* ((s (screen:make-screen))
         (th (theme:read-theme (paths:theme-path "menu.thm")))
         (bg (theme:find-sprite th "menu_bg"))
         (drawn (1- screen:+cols+))
         (screen:*right-edge-off-by-one* t))
    (screen:blit-sprite s bg 0 screen:+rows+)
    (is (eq t (blit-matches-source? s bg :max-x drawn)))
    (is (= (opaque-count bg :max-x drawn)
           (count-if-not #'zerop (screen:screen-cells s))))
    (is-true (loop for y below screen:+rows+
                   always (zerop (screen:cell-ref s (1- screen:+cols+) y))))))
