(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun hud6 () (font:read-bft (paths:font-path "dsc_font_hud_06.bft")))

(test text-sprite-dimensions
  "One font pixel becomes one cell, so an N-character string in a 6x6 font is 6N x 6."
  (let* ((f (hud6))
         (s (text:text-sprite f "AND")))
    (is (= 18 (theme:sprite-width s)))
    (is (= 6 (theme:sprite-height s)))
    (is (= 1 (theme:sprite-frames s)))
    (is (= 108 (length (theme:sprite-glyphs s))))
    (is (= 18 (text:text-width f "AND")))))

(test text-uses-block-and-space-by-default
  "A lit font pixel emits #xDB (solid block), an unlit one #x20 (space). GAM_DEF_*_CHAR."
  (let* ((f (hud6))
         (s (text:text-sprite f "A"))
         (chars (remove-duplicates
                 (map 'list #'glyph:glyph-char (theme:sprite-glyphs s)))))
    (is (null (set-difference chars (list glyph:+default-fg-char+
                                          glyph:+default-bg-char+))))
    ;; 'A' must actually have some lit cells.
    (is (find glyph:+default-fg-char+ (theme:sprite-glyphs s)
              :key #'glyph:glyph-char))))

(test text-default-attribute-is-transparent-background
  "INTRO_FONT_ATTR is pair 0, mod #xFF: white blocks over whatever is underneath."
  (let* ((f (hud6))
         (s (text:text-sprite f "A")))
    (is (= #x00FF0000 text:*transparent-bg-attr*))
    (is-true (every #'glyph:transparent-bg? (theme:sprite-glyphs s)))
    (is-true (every (lambda (g) (= 0 (glyph:glyph-pair g))) (theme:sprite-glyphs s)))))

(test text-attribute-packing
  "font-attr matches GAM_FONT_ATTR(c, a, b, f)."
  (is (= #x00FF0000 (text:font-attr :pair 0 :mod #xFF)))
  (is (= #x0A0B0C0D (text:font-attr :pair #x0A :mod #x0B :bg-char #x0C :fg-char #x0D))))

(test text-explicit-characters-override-defaults
  (let* ((f (hud6))
         (attr (text:font-attr :pair 3 :mod 0 :bg-char (char-code #\.)
                                      :fg-char (char-code #\#)))
         (s (text:text-sprite f "A" attr))
         (chars (remove-duplicates
                 (map 'list #'glyph:glyph-char (theme:sprite-glyphs s)))))
    (is (null (set-difference chars (list (char-code #\#) (char-code #\.)))))
    (is (every (lambda (g) (= 3 (glyph:glyph-pair g))) (theme:sprite-glyphs s)))))

(test text-glyph-layout-matches-the-font
  "Cell (x, y) of the sprite must be lit exactly when font pixel (x, y) is."
  (let* ((f (hud6))
         (str "AZ09")
         (s (text:text-sprite f str))
         (fw (font:font-width f)))
    (is (eq t (block scan
                (dotimes (i (length str) t)
                  (dotimes (y (font:font-height f))
                    (dotimes (x fw)
                      (let ((lit? (plusp (font:font-pixel f (char-code (char str i)) y x)))
                            (cell (theme:sprite-ref s 0 y (+ (* i fw) x))))
                        (unless (eq lit? (= (glyph:glyph-char cell)
                                            glyph:+default-fg-char+))
                          (return-from scan
                            (list :char (char str i) :pixel (list x y)))))))))))))

(test text-coverage-check-catches-undrawn-glyphs
  "hud_06 is uppercase-only; lowercase would silently render as dots."
  (let ((f (hud6)))
    (is-true (text:check-text-coverage f "AND"))
    (is-true (text:check-text-coverage f "PRESENTS"))
    (is-true (text:check-text-coverage f "SCORE 1234"))
    (handler-bind ((warning #'muffle-warning)
                   (style-warning #'muffle-warning))
      (is-false (text:check-text-coverage f "and"))
      (is-false (text:check-text-coverage f "Hello!")))))
