(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun load-theme (name) (theme:read-theme (paths:theme-path name)))

(test theme-sprite-counts
  "Counts verified by parsing every shipped .thm; for these four the last sprite ends
   exactly at EOF, so the 56-byte header size and 84-byte palette block are confirmed."
  (dolist (spec '(("crash_site.thm" 38)
                  ("hidden_cave.thm" 24)
                  ("brain_pain.thm" 32)
                  ("intro.thm" 4)
                  ("menu.thm" 2)
                  ("credits.thm" 5)))
    (destructuring-bind (file n) spec
      (is (= n (hash-table-count (theme:theme-sprites (load-theme file))))
          "~a sprite count" file))))

(test theme-sprite-dimensions
  (let ((crash (load-theme "crash_site.thm"))
        (intro (load-theme "intro.thm"))
        (menu (load-theme "menu.thm")))
    (let ((p (theme:find-sprite crash "player")))
      (is (= 9 (theme:sprite-width p)))
      (is (= 4 (theme:sprite-height p)))
      (is (= 1 (theme:sprite-frames p)))
      (is (= 36 (length (theme:sprite-glyphs p)))))
    ;; The crash-landing intro movie: a full-screen 52-frame animation.
    (let ((s (theme:find-sprite intro "Spla-shit")))
      (is (= 240 (theme:sprite-width s)))
      (is (= 120 (theme:sprite-height s)))
      (is (= 52 (theme:sprite-frames s)))
      (is (= (* 240 120 52) (length (theme:sprite-glyphs s)))))
    ;; A full-screen background is exactly the cell grid.
    (let ((s (theme:find-sprite menu "menu_bg")))
      (is (= screen:+cols+ (theme:sprite-width s)))
      (is (= screen:+rows+ (theme:sprite-height s))))))

(test theme-trailing-junk-is-ignored
  "intro/menu/credits have bytes after the last sprite. The original only ever reads
   nSprites, so loading must succeed and not try to consume the remainder."
  (dolist (file '("intro.thm" "menu.thm" "credits.thm"))
    (finishes (load-theme file))))

(test palette-decoding
  "crash_site's palette, spot-checked. Slot 9 is the red the player ship is built from."
  (let ((cm (theme:theme-colormap (load-theme "crash_site.thm"))))
    (is (string= "crash_site" (theme:colormap-name cm)))
    (is (= #x000000 (theme:colormap-ref cm 0)))
    (is (= #xCA0000 (theme:colormap-ref cm 9)))
    (is (= #x9B9B9B (theme:colormap-ref cm 13)))
    (is (= #xFFFFFF (theme:colormap-ref cm 15)))))

(test hidden-cave-palette-is-the-odd-one-out
  "crash_site and brain_pain share an identical palette; hidden_cave is the only
   outlier, differing at slots 8, 13 and 14. Slots 8 and 13 are stored as browns, and
   the R/B swap is what turns them into the level's blue 'ice cave' on screen -- so
   under the verified mapping the cave renders exactly as it shipped. Slot 14 is only
   the greys shifting down to free slot 13. PLAN.md D1."
  ;; :ice loads the palette exactly as stored; the default :brown pre-swaps slots 8
  ;; and 13, which is a separate concern tested in hidden-cave-palette-option.
  (let* ((theme::*hidden-cave-palette* :ice)
         (crash (theme:theme-colormap (load-theme "crash_site.thm")))
         (brain (theme:theme-colormap (load-theme "brain_pain.thm")))
         (cave (theme:theme-colormap (load-theme "hidden_cave.thm"))))
    (dotimes (i 16)
      (is (= (theme:colormap-ref crash i) (theme:colormap-ref brain i))
          "crash_site and brain_pain should share slot ~d" i)
      (if (member i '(8 13 14))
          (is (/= (theme:colormap-ref crash i) (theme:colormap-ref cave i))
              "slot ~d should differ in hidden_cave" i)
          (is (= (theme:colormap-ref crash i) (theme:colormap-ref cave i))
              "slot ~d should match in hidden_cave" i)))
    ;; The two browns that became the ice cave.
    (is (= #x583213 (theme:colormap-ref cave 8)))
    (is (= #x844946 (theme:colormap-ref cave 13)))
    ;; A grey either way, so the R/B swap could never have touched it.
    (is (= #x9B9B9B (theme:colormap-ref cave 14)))))

(defun dominant-ship-colour (file)
  "The most common displayed background colour of the player sprite, as ARGB."
  (let* ((th (load-theme file))
         (cm (theme:theme-colormap th))
         (p (theme:find-sprite th "player"))
         (r (renderer:make-renderer :colormap cm))
         (counts (make-hash-table)))
    (unwind-protect
         (progn
           (dotimes (y (theme:sprite-height p))
             (dotimes (x (theme:sprite-width p))
               (let ((g (theme:sprite-ref p 0 y x)))
                 (unless (glyph:transparent? g)
                   (incf (gethash (aref (renderer:renderer-bg-lut r)
                                        (glyph:glyph-pair g))
                                  counts 0))))))
           (car (first (sort (alexandria:hash-table-alist counts) #'> :key #'cdr))))
      (renderer:destroy-renderer r))))

(test player-ship-reads-red-in-every-theme
  "The ship must come out red whichever theme is loaded. Under the verified mapping its
   body resolves through palette slot 8, which every game theme sets to (127,0,255);
   the COLORREF swap turns that into (255,0,127), the hot pink-red players remember."
  (let ((glyph:*colour-mapping* :original))
    (dolist (file '("crash_site.thm" "brain_pain.thm"))
      (is (= #xFFFF007F (dominant-ship-colour file))
          "~a: ship should be (255,0,127)" file))
    ;; hidden_cave overrides slot 8, so the ship picks up the cave's tint there. With
    ;; the default :brown fixup that slot is pre-swapped, so the ship reads brown.
    (let ((theme::*hidden-cave-palette* :brown))
      (is (= #xFF583213 (dominant-ship-colour "hidden_cave.thm"))
          "brown cave tints the ship brown"))
    (let ((theme::*hidden-cave-palette* :ice))
      (is (= #xFF133258 (dominant-ship-colour "hidden_cave.thm"))
          "ice cave tints the ship blue"))))

(test glyph-decoding
  "The ship's '<' cell, pair 214 = 0xD6, decoded under both mappings."
  (let ((g (glyph:make-glyph (char-code #\<) 214)))
    (is (= (char-code #\<) (glyph:glyph-char g)))
    (is (= 214 (glyph:glyph-pair g)))
    (is (not (glyph:transparent? g)))
    (let ((glyph:*colour-mapping* :original))
      (is (= 13 (glyph:glyph-bg-index g)) "g_bgColors[13] = 13")
      (is (= 8 (glyph:glyph-fg-index g)) "g_fgColors[6] = FOREGROUND_INTENSITY = 8"))
    (let ((glyph:*colour-mapping* :authored))
      (is (= 13 (glyph:glyph-bg-index g)))
      (is (= 9 (glyph:glyph-fg-index g)) "PySpriteEdit's 15 - (pair & 15)")))
  (is (glyph:transparent? glyph:+transparent+)))
