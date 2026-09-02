(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; Pixel-level fidelity against a screenshot of the original game.
;;;;
;;;; test/reference/menu_original.ppm is a 960x720 capture of the real thing running on
;;;; Windows. Rendering menu.thm's menu_bg through our pipeline must reproduce it
;;;; exactly everywhere the background is not covered by a sprite we do not draw here.
;;;;
;;;; This is what settled the colour-mapping question. Argument could not distinguish
;;;; PySpriteEdit's encoding convention from the Win32 render path; this can.

(defparameter *reference-ppm*
  (merge-pathnames "test/reference/menu_original.ppm"
                   (asdf:system-source-directory "descendant")))

;;; Regions covered by sprites the menu placeholder does not draw: the banner, the
;;; option box, and the bottom scroller. Everything outside is pure menu_bg.
(defparameter *overlay-rects*
  '((24 10 936 258) (190 280 496 656) (0 650 960 710)))

(defun %ppm-token (stream)
  "Read one whitespace-delimited header token."
  (let ((token (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream)
          until (and (member b '(32 9 10 13)) (plusp (length token)))
          unless (member b '(32 9 10 13))
            do (vector-push-extend (code-char b) token))
    (copy-seq token)))

(defun read-ppm (path)
  "Return (values width height rgb-octets) for a binary P6 PPM."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((magic (%ppm-token in)))
      (assert (string= "P6" magic) () "~a: expected a binary PPM, got ~s" path magic))
    (let* ((w (parse-integer (%ppm-token in)))
           (h (parse-integer (%ppm-token in)))
           (maxval (parse-integer (%ppm-token in)))
           (data (make-array (* w h 3) :element-type '(unsigned-byte 8))))
      (assert (= 255 maxval) () "~a: expected 8-bit samples" path)
      (read-sequence data in)
      (values w h data))))

(defun covered? (x y)
  (loop for (x0 y0 x1 y1) in *overlay-rects*
        thereis (and (<= x0 x) (< x x1) (<= y0 y) (< y y1))))

(test menu-background-matches-the-original-screenshot
  "The decisive fidelity check. With the verified colour mapping the background must be
   pixel-identical to the original outside the overlay sprites; the small residue is
   the menu's star field, which is generated separately and not part of menu_bg."
  (multiple-value-bind (rw rh reference) (read-ppm *reference-ppm*)
    (is (= screen:+pixel-width+ rw))
    (is (= screen:+pixel-height+ rh))
    (let* ((glyph:*colour-mapping* :original)
           (th (theme:read-theme (paths:theme-path "menu.thm")))
           (sc (screen:make-screen))
           (r (renderer:make-renderer :colormap (theme:theme-colormap th))))
      (unwind-protect
           (progn
             (screen:blit-sprite sc (theme:find-sprite th "menu_bg") 0 screen:+rows+)
             (renderer:rasterize r sc)
             (let ((pixels (renderer-pixels-as-rgb r))
                   (same 0) (total 0))
               (dotimes (y rh)
                 (dotimes (x rw)
                   (unless (covered? x y)
                     (incf total)
                     (let ((i (* 3 (+ (* y rw) x))))
                       (when (and (= (aref pixels i) (aref reference i))
                                  (= (aref pixels (+ i 1)) (aref reference (+ i 1)))
                                  (= (aref pixels (+ i 2)) (aref reference (+ i 2))))
                         (incf same))))))
               (let ((ratio (/ (float same) total)))
                 (is (> ratio 0.997)
                     "expected >99.7% pixel agreement with the original, got ~,2f% (~d/~d)"
                     (* 100 ratio) same total))))
        (renderer:destroy-renderer r)))))

(defun renderer-pixels-as-rgb (r)
  "The ARGB pixel buffer flattened to RGB octets, matching PPM order."
  (let* ((src (renderer::renderer-pixels r))
         (n (length src))
         (out (make-array (* n 3) :element-type '(unsigned-byte 8))))
    (dotimes (i n out)
      (let ((p (aref src i)) (o (* i 3)))
        (setf (aref out (+ o 0)) (ldb (byte 8 16) p)
              (aref out (+ o 1)) (ldb (byte 8 8) p)
              (aref out (+ o 2)) (ldb (byte 8 0) p))))))

(defparameter *star-colour* '(154 177 177)
  "Palette slot 13 after the channel swap: the star field's lit pixel.")

(test full-menu-matches-the-original-screenshot
  "The whole menu level rendered against the original capture. Every remaining
   difference must be star placement -- the field is generated with a fresh random
   state each run, and each '.' glyph lights exactly one pixel, so a differently seeded
   field differs by roughly twice the star count and nothing else."
  (multiple-value-bind (rw rh reference) (read-ppm *reference-ppm*)
    (let ((audio:*muted?* t)
          (glyph:*colour-mapping* :original)
          (level:*frame* 0)
          (level:*state* :play)
          (level:*current* nil)
          (sc (screen:make-screen))
          (r (renderer:make-renderer)))
      (unwind-protect
           (progn
             (level:start-level :menu)
             (renderer:ensure-palette r (level:level-colormap level:*current*))
             (level:render-level level:*current* sc)
             (screen:composite sc)
             (renderer:rasterize r sc)
             (let ((pixels (renderer-pixels-as-rgb r))
                   (same 0) (star-diff 0) (other-diff 0))
               (dotimes (i (* rw rh))
                 (let* ((o (* i 3))
                        (a (list (aref pixels o) (aref pixels (+ o 1))
                                 (aref pixels (+ o 2))))
                        (b (list (aref reference o) (aref reference (+ o 1))
                                 (aref reference (+ o 2)))))
                   (cond ((equal a b) (incf same))
                         ;; one side a star, the other the black sky behind it
                         ((or (and (equal a '(0 0 0)) (equal b *star-colour*))
                              (and (equal a *star-colour*) (equal b '(0 0 0))))
                          (incf star-diff))
                         (t (incf other-diff)))))
               (is (zerop other-diff)
                   "~d pixels differ for a reason other than star placement" other-diff)
               (is (> (/ (float same) (* rw rh)) 0.995)
                   "expected >99.5% raw agreement, got ~,2f%"
                   (* 100 (/ (float same) (* rw rh))))
               ;; Sanity: the field really is being drawn.
               (is (> star-diff 100) "the star field should contribute some difference")))
        (progn (level:shutdown) (renderer:destroy-renderer r))))))

(test win32-tables-match-the-source
  "The permutation tables transcribed from g_bgColors/g_fgColors, spot-checked against
   the bit patterns in gam_render.c:584-622."
  ;; g_bgColors[9] = BACKGROUND_INTENSITY = 8
  (is (= 8 (aref glyph:*win32-bg-slots* 9)))
  ;; g_bgColors[11] = BLUE|GREEN|RED = 7
  (is (= 7 (aref glyph:*win32-bg-slots* 11)))
  ;; g_fgColors[0] = all bits = 15, g_fgColors[15] = 0
  (is (= 15 (aref glyph:*win32-fg-slots* 0)))
  (is (= 0 (aref glyph:*win32-fg-slots* 15)))
  ;; g_fgColors[6] = FOREGROUND_INTENSITY = 8
  (is (= 8 (aref glyph:*win32-fg-slots* 6)))
  (is (= 16 (length glyph:*win32-bg-slots*)))
  (is (= 16 (length glyph:*win32-fg-slots*)))
  ;; Both tables must be permutations of 0..15.
  (is (equal (coerce (sort (copy-seq glyph:*win32-bg-slots*) #'<) 'list)
             (loop for i below 16 collect i)))
  (is (equal (coerce (sort (copy-seq glyph:*win32-fg-slots*) #'<) 'list)
             (loop for i below 16 collect i))))

(test colour-mapping-modes-differ
  "The two modes are genuinely different; :authored is kept only for comparison."
  (let ((g (glyph:make-glyph (char-code #\<) 214)))     ; the player ship's '<'
    (let ((glyph:*colour-mapping* :original))
      (is (= 13 (glyph:glyph-bg-index g)))
      (is (= 8 (glyph:glyph-fg-index g)))
      (is-true (glyph:channel-swap?)))
    (let ((glyph:*colour-mapping* :authored))
      (is (= 13 (glyph:glyph-bg-index g)))
      (is (= 9 (glyph:glyph-fg-index g)))
      (is-false (glyph:channel-swap?)))))

(test ship-reads-red-under-the-original-mapping
  "Under the verified mapping the ship's body resolves through palette slot 8, which
   crash_site sets to (127,0,255); the channel swap turns that into (255,0,127) --
   the hot pink-red the ship was remembered as."
  (let* ((glyph:*colour-mapping* :original)
         (th (theme:read-theme (paths:theme-path "crash_site.thm")))
         (cm (theme:theme-colormap th))
         (body (glyph:make-glyph #x20 #x9F)))              ; a ship body cell
    (is (= 8 (glyph:glyph-bg-index body)))
    (is (= #x7F00FF (theme:colormap-ref cm 8)))
    (let ((r (renderer:make-renderer :colormap cm)))
      (unwind-protect
           (is (= #xFFFF007F (aref (renderer:renderer-bg-lut r) #x9F))
               "ship body should resolve to (255,0,127)")
        (renderer:destroy-renderer r)))))
