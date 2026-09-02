(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(test field-dimensions
  (let ((s (field:make-star-field screen:+cols+ screen:+rows+)))
    (is (= screen:+cols+ (theme:sprite-width s)))
    (is (= screen:+rows+ (theme:sprite-height s)))
    (is (= (* screen:+cols+ screen:+rows+) (length (theme:sprite-glyphs s))))))

(test star-field-composition
  "The intro's field is '.' in colour pair 2 at 8% frequency; everything else is
   transparent so the movie behind it shows through."
  (let* ((s (field:make-star-field screen:+cols+ screen:+rows+))
         (glyphs (theme:sprite-glyphs s))
         (stars (count-if-not #'glyph:transparent? glyphs)))
    (is-true (every (lambda (g)
                      (or (glyph:transparent? g)
                          (and (= (char-code #\.) (glyph:glyph-char g))
                               (= 2 (glyph:glyph-pair g)))))
                    glyphs)
             "every non-transparent cell is a '.' in pair 2")
    ;; 8% of 28800 is 2304; allow generous slack for randomness.
    (is (< 1800 stars 2900) "expected roughly 8% stars, got ~d of ~d"
        stars (length glyphs))))

(test field-frequencies-are-respected
  "A single entry at 100% fills every cell; at 0% it fills none."
  (let ((all (field:make-field 40 20 (list (field:make-field-entry (char-code #\#) 5 100))))
        (none (field:make-field 40 20 (list (field:make-field-entry (char-code #\#) 5 0)))))
    (is (notany #'glyph:transparent? (theme:sprite-glyphs all)))
    (is (every #'glyph:transparent? (theme:sprite-glyphs none)))))

(test field-multiple-entries-partition-the-range
  "Entries claim consecutive percentage bands; the remainder is transparent."
  (let* ((s (field:make-field 100 100
                              (list (field:make-field-entry (char-code #\A) 1 30)
                                    (field:make-field-entry (char-code #\B) 2 20))))
         (glyphs (theme:sprite-glyphs s))
         (a (count-if (lambda (g) (and (not (glyph:transparent? g))
                                       (= (glyph:glyph-char g) (char-code #\A))))
                      glyphs))
         (b (count-if (lambda (g) (and (not (glyph:transparent? g))
                                       (= (glyph:glyph-char g) (char-code #\B))))
                      glyphs))
         (clear (count-if #'glyph:transparent? glyphs)))
    (is (= 10000 (+ a b clear)))
    (is (< 2600 a 3400) "~a should be near 30%" a)
    (is (< 1700 b 2300) "~a should be near 20%" b)
    (is (< 4600 clear 5400) "~a should be near 50%" clear)))

(test field-rejects-impossible-distributions
  "The original logged 'Invalid frequency distribution' and bailed."
  (signals error
    (field:make-field 10 10 (list (field:make-field-entry (char-code #\A) 1 60)
                                  (field:make-field-entry (char-code #\B) 2 60)))))

(test field-is-reproducible-with-a-seeded-state
  (flet ((gen () (field:make-star-field 40 20
                                        :random-state (sb-ext:seed-random-state 1234))))
    (is (equalp (theme:sprite-glyphs (gen)) (theme:sprite-glyphs (gen))))))
