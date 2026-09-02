(in-package #:com.thejach.descendant.field)

;;;; Randomised full-screen fields -- the intro's star field and the levels' ambient
;;;; background/ground decoration. Port of dsc_envCreateField in dsc_environment.c.
;;;;
;;;; The original builds an edge tree over 0..99 and rolls rand()%100 per cell. Each
;;;; entry claims FREQ consecutive percentage points; whatever is left over becomes
;;;; fully transparent. So the intro's single entry ('.', colour pair 2, frequency 8)
;;;; means 8% of cells are stars and 92% are see-through.
;;;;
;;;; A flat cumulative-frequency scan is equivalent to the edge tree here and far less
;;;; machinery; the tree existed because the original also used it for weighted spawn
;;;; selection, which we will need separately later.

(defstruct (field-entry (:constructor make-field-entry (char pair frequency)))
  (char 0 :type (unsigned-byte 8))
  (pair 0 :type (unsigned-byte 8))
  (frequency 0 :type (integer 0 100)))

(defun entries-from-config (chars colors freqs)
  "Build entries from the parallel CHARS/COLORS/FREQS the .cfg files express, e.g.
   env_bg_field_chars = '.', env_bg_field_color = 2, env_bg_field_freq = 8."
  (loop for ch across chars
        for i from 0
        collect (make-field-entry (char-code ch)
                                  (elt colors i)
                                  (elt freqs i))))

(defun make-field (width height entries &key (random-state *random-state*))
  "A WIDTH x HEIGHT sprite of randomly scattered glyphs.

   Signals an error if the entries claim more than 100 percentage points, which is what
   the original logged as 'Invalid frequency distribution'."
  (let* ((total (reduce #'+ entries :key #'field-entry-frequency :initial-value 0))
         (glyphs (make-array (* width height) :element-type '(unsigned-byte 32))))
    (assert (<= total 100) (total)
            "Field frequencies sum to ~d, which exceeds 100." total)
    (dotimes (i (* width height))
      (let ((roll (random 100 random-state))
            (acc 0)
            (chosen glyph:+transparent+))
        (dolist (e entries)
          (incf acc (field-entry-frequency e))
          (when (< roll acc)
            (setf chosen (glyph:make-glyph (field-entry-char e) (field-entry-pair e)))
            (return)))
        (setf (aref glyphs i) chosen)))
    (theme:make-sprite "field" width height glyphs)))

(defun make-star-field (width height &key (random-state *random-state*))
  "The intro's star field: 8% of cells are a '.' in colour pair 2, the rest transparent.
   Values taken from INTRO_initLevel."
  (make-field width height (list (make-field-entry (char-code #\.) 2 8))
              :random-state random-state))
