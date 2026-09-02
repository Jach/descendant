(in-package #:com.thejach.descendant.text)

;;;; Rendering a string with a .bft font into a sprite: the port of GF_setData /
;;;; GF_getSprite in origRef/Engine/gam_font.c.
;;;;
;;;; Each font PIXEL becomes a whole CELL, so an N-character string in a WxH font
;;;; produces an (N*W) x H sprite. A lit pixel emits the foreground character (#xDB, a
;;;; solid block, by default) and an unlit one the background character (a space).
;;;;
;;;; Attribute word, matching GAM_FONT_ATTR(c, a, b, f):
;;;;   (colour-pair << 24) | (mod << 16) | (bg-char << 8) | fg-char
;;;; A zero fg-char means #xDB and a zero bg-char means #x20, so the common case of
;;;; "white blocks over whatever is underneath" is attribute #x00FF0000 -- pair 0 and
;;;; mod #xFF, i.e. transparent background. That is INTRO_FONT_ATTR.

(defconstant +total-transparency+ #xFFFFFFFF
  "GAM_FONT_ATTR_TOTAL_TRANSPARENCY: every cell becomes fully transparent.")

(defun font-attr (&key (pair 0) (mod 0) (bg-char 0) (fg-char 0))
  (logior (ash pair 24) (ash mod 16) (ash bg-char 8) fg-char))

(defparameter *transparent-bg-attr* (font-attr :pair 0 :mod glyph:+mod-transparent-bg+)
  "INTRO_FONT_ATTR: solid white blocks, background showing through.")

(defun text-width (font string)
  (* (length string) (font:font-width font)))

(defun render-text-into (glyphs font string attributes width &key (offset 0))
  "Write STRING into GLYPHS, a row-major buffer WIDTH cells across, starting OFFSET
   characters from the left. GF_setString's job."
  (let* ((fw (font:font-width font))
         (fh (font:font-height font))
         (attr (if (= attributes +total-transparency+)
                   +total-transparency+
                   (logand attributes #xFFFF0000)))
         (fg (let ((c (ldb (byte 8 0) attributes)))
               (if (zerop c) glyph:+default-fg-char+ c)))
         (bg (let ((c (ldb (byte 8 8) attributes)))
               (if (zerop c) glyph:+default-bg-char+ c))))
    (loop for i below (length string)
          for ch = (char-code (char string i))
          for x0 = (* (+ offset i) fw)
          do (dotimes (y fh)
               (dotimes (x fw)
                 (let ((dst (+ (* y width) x0 x)))
                   (when (< dst (length glyphs))
                     (setf (aref glyphs dst)
                           (if (plusp (font:font-pixel font ch y x))
                               (logior attr fg)
                               (logior attr bg))))))))
    glyphs))

(defun text-sprite (font string &optional (attributes *transparent-bg-attr*))
  "A fresh sprite containing STRING. GF_getSprite's job.

   Beware coverage: hud_04, hud_06 and foo_06 only ever had A-Z, 0-9 and ':' drawn, so
   anything else renders as a single dot. See CHECK-TEXT-COVERAGE."
  (let* ((fw (font:font-width font))
         (fh (font:font-height font))
         (width (* (length string) fw))
         (glyphs (make-array (max 1 (* width fh)) :element-type '(unsigned-byte 32)
                                                  :initial-element 0)))
    (render-text-into glyphs font string attributes width)
    (theme:make-sprite (format nil "text:~a" string) width fh glyphs)))

(defun missing-glyphs (font string)
  "The characters of STRING that FONT never had drawn, which render as a single dot."
  (remove-duplicates
   (remove-if (lambda (ch)
                (or (char= ch #\Space)
                    (> (font:font-ink font (char-code ch)) 1)))
              (coerce string 'list))))

(defun check-text-coverage (font string &key (context "text") (expected '()))
  "Warn about characters the font never had drawn. The HUD fonts are uppercase-only, so a
   stray lowercase string silently renders as a row of dots -- worth catching loudly in
   development rather than squinting at the screen.

   EXPECTED lists characters already known to be absent, which are not worth a warning
   every run. Naming them beats switching the check off: a NEW gap in the same string is
   still reported, and the list says which limitation was accepted and where."
  (let ((missing (set-difference (missing-glyphs font string) expected)))
    (when missing
      (warn "~a: font ~s has no glyph for ~{~s~^, ~} in ~s; these render as dots."
            context (font:font-name font) missing string))
    (null missing)))
