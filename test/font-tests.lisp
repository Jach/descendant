(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun ink (font ch) (font:font-ink font (char-code ch)))

(test cell-atlas-shape
  (let ((f (font:read-cell-atlas)))
    (is (= 4 (font:font-width f)))
    (is (= 6 (font:font-height f)))
    (is (= 256 (font:font-count f)))
    (is (= 0 (font:font-first-char f)))
    ;; Every cell is drawn with this, including the high range that .bft text emits.
    (is (font:font-covers? f #xDB))))

(test cell-atlas-key-glyphs
  (let ((f (font:read-cell-atlas)))
    ;; #xDB is the solid block the .bft text path emits for a lit pixel.
    (is (= 24 (font:font-ink f #xDB)))
    (is (equal '("####" "####" "####" "####" "####" "####")
               (font:glyph-lines f #xDB)))
    (is (= 0 (ink f #\Space)))
    ;; '.' is the lightest tone in the art's shading ramp: exactly one pixel.
    (is (= 1 (ink f #\.)))))

(test cell-atlas-density-ladder
  "The art shades by glyph density. These are the glyphs the shipped themes actually
   use, and their ink coverage must stay monotonic or the art misreads. This is the
   acceptance test for any substitute face (PLAN.md D5)."
  (let* ((f (font:read-cell-atlas))
         (ladder '(#\M #\@ #\7 #\Y #\c #\i #\: #\.)))
    (loop for (a b) on ladder while b
          do (is (> (ink f a) (ink f b))
                 "expected ink(~a)=~d > ink(~a)=~d" a (ink f a) b (ink f b)))
    ;; Spot-check the absolute values recovered from dosapp.fon.
    (is (= 12 (ink f #\M)))
    (is (= 12 (ink f #\#)))
    (is (= 11 (ink f #\@)))
    (is (= 2 (ink f #\:)))))

(test bft-dimensions
  "Sizes are those FontFooey was invoked with; see Tools/FontEditor/FontEditor.txt."
  (dolist (spec '(("dsc_font_arial_05.bft" 5 8)
                  ("dsc_font_arial_07.bft" 7 10)
                  ("dsc_font_arial_09.bft" 9 10)
                  ("dsc_font_courier_05.bft" 5 8)
                  ("dsc_font_courier_07.bft" 7 11)
                  ("dsc_font_foo_06.bft" 6 8)
                  ("dsc_font_hud_04.bft" 4 6)
                  ("dsc_font_hud_06.bft" 6 6)
                  ("dsc_font_impact_07.bft" 7 13)
                  ("dsc_font_impact_09.bft" 9 12)
                  ("dsc_font_impact_11.bft" 11 15)))
    (destructuring-bind (file w h) spec
      (let ((f (font:read-bft (paths:font-path file))))
        (is (= w (font:font-width f)) "~a width" file)
        (is (= h (font:font-height f)) "~a height" file)
        (is (= 95 (font:font-count f)) "~a glyph count" file)
        (is (= #x20 (font:font-first-char f)) "~a first char" file)))))

(defun drawn-count (font)
  "Glyphs with more than one lit pixel. A single pixel is the placeholder left by
   characters that were never drawn in the source FNT."
  (loop for c from (font:font-first-char font)
          below (+ (font:font-first-char font) (font:font-count font))
        count (> (font:font-ink font c) 1)))

(test bft-hud-fonts-are-uppercase-only
  "hud_04, hud_06 and foo_06 only ever had A-Z, 0-9 and ':' drawn. Since hud_06 is the
   workhorse for menu/HUD/credits/intro/controls/score, all in-game text is effectively
   uppercase. Text rendering must not assume full ASCII coverage."
  (dolist (file '("dsc_font_hud_04.bft" "dsc_font_hud_06.bft" "dsc_font_foo_06.bft"))
    (let ((f (font:read-bft (paths:font-path file))))
      (is (= 37 (drawn-count f)) "~a should have 37 drawn glyphs" file)
      (dolist (ch '(#\A #\Z #\0 #\9 #\:))
        (is (> (ink f ch) 1) "~a should draw ~a" file ch))
      (dolist (ch '(#\a #\z #\@ #\# #\!))
        (is (<= (ink f ch) 1) "~a should NOT draw ~a" file ch)))))

(test bft-converted-fonts-are-complete
  "The arial/courier/impact families came from real system faces and are near-complete."
  (dolist (spec '(("dsc_font_arial_05.bft" 92)
                  ("dsc_font_courier_07.bft" 94)
                  ("dsc_font_impact_11.bft" 94)))
    (destructuring-bind (file expected) spec
      (is (= expected (drawn-count (font:read-bft (paths:font-path file))))
          "~a drawn glyph count" file))))

(test bft-bit-order
  "The .bft row is LSB-leftmost, the opposite of the cell font. 'A' in hud_04 is the
   canonical check: an unmirrored 3-wide capital."
  (let ((f (font:read-bft (paths:font-path "dsc_font_hud_04.bft"))))
    (is (equal '("###." "#.#." "###." "#.#." "#.#." "....")
               (font:glyph-lines f (char-code #\A))))))
