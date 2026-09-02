(in-package #:com.thejach.descendant.config)

;;;; The .cfg format, matching dsc_configuration.c:
;;;;
;;;;   [ section_name ]
;;;;   key = value
;;;;
;;;; Comments run from '#' to end of line and are stripped from the whole buffer before
;;;; parsing (removeComments, line 358) -- including inside values, which we reproduce.
;;;; Section names and keys are trimmed on both sides; values are kept verbatim from the
;;;; character after '=' to end of line, and the *consumer* trims them (see the header
;;;; comment on struct DSCConfiguration). Keys are stored as "section.key".
;;;;
;;;; Deliberate divergence: the original walks the buffer with pointers, so a line with
;;;; no '=' silently swallows the following lines until one appears. We parse line by
;;;; line and ignore such lines instead. No shipped .cfg relies on that behaviour --
;;;; after comment stripping every line is blank, a section header, or a key/value pair.
;;;; Backslash escapes are left in the value, as the original also never unescapes them.

(defparameter *whitespace* '(#\Space #\Tab #\Return #\Newline))

(defstruct (config (:constructor %make-config))
  (table (make-hash-table :test #'equal) :type hash-table)
  (source nil))

(defun %trim (s)
  (string-trim *whitespace* s))

(defun %strip-comments (text)
  "Remove '#' to end of line, keeping the line break."
  (with-output-to-string (out)
    (let ((in-comment nil))
      (loop for ch across text do
        (cond ((char= ch #\#) (setf in-comment t))
              ((or (char= ch #\Newline) (char= ch #\Return))
               (setf in-comment nil)
               (write-char ch out))
              ((not in-comment) (write-char ch out)))))))

(defun %split-lines (text)
  (let ((lines '()) (start 0))
    (dotimes (i (length text))
      (when (or (char= (char text i) #\Newline) (char= (char text i) #\Return))
        (push (subseq text start i) lines)
        (setf start (1+ i))))
    (push (subseq text start) lines)
    (nreverse lines)))

(defun read-config (path)
  (let ((table (make-hash-table :test #'equal))
        (section ""))
    (dolist (raw (%split-lines (%strip-comments (bin:read-file-string path))))
      (let ((line (%trim raw)))
        (cond
          ((zerop (length line)))                                  ; blank
          ((and (char= (char line 0) #\[) (find #\] line))
           (setf section (%trim (subseq line 1 (position #\] line)))))
          ((find #\= line)
           (let* ((eq (position #\= line))
                  (key (%trim (subseq line 0 eq)))
                  ;; Value taken from the untrimmed line so leading spaces survive,
                  ;; exactly as the original stores them.
                  (value (subseq raw (1+ (position #\= raw)))))
             (when (plusp (length key))
               (setf (gethash (format nil "~a.~a" section key) table) value)))))))
    (%make-config :table table :source path)))

;;; ---------------------------------------------------------------------------
;;; Accessors. KEY is the full "section.key". Values are trimmed on the way out,
;;; which is the trimming the original pushed onto each consumer.

;;; Balance overrides.
;;;
;;; The shipped .cfg files are assets and we do not edit them -- the port is meant to run
;;; against the originals untouched. But a few of their numbers are unplayable at our
;;; frame rate or look like slips, and burying those adjustments in the code that reads
;;; them would scatter the deviations across five files. They live here instead, in one
;;; table, each with the reason attached.
;;;
;;; Set *OVERRIDES* to NIL to run against the shipped values exactly.

(defparameter *overrides*
  '((:all
     ;; Every other spawn class uses a gap of 60 to 1000 world units; this one uses 10,
     ;; so once it opens it is ready on almost every column and all ten midbosses arrive
     ;; within a second. Almost certainly a typo -- the line above it carries a
     ;; commented-out alternative, so these were being fiddled with late.
     ("spawn_midboss.spawn_delta" . "100")

     ;; Power-ups were worth score and nothing else in the original, so their rarity did
     ;; not matter much. Now that the points pickup also returns shields they are the
     ;; only way to recover. Doubling the class weight makes them findable without making
     ;; the rapid-plus-spread overlap -- the best thing in the game -- something you can
     ;; hold permanently.
     ("spawn_collectable.probability" . "2")

     ;; And bias the mix toward the one that heals. The other three are all still 3.
     ("collect_points.spawn_prob" . "5"))

    ("level_hidden_cave.cfg"
     ;; Stage two is a real step up, and it is the original's own step: measured against
     ;; the shipped values a drifting player survives about 33 s there against 64 s on
     ;; stage one, near-identically in both. Its intended answer to the doomworm is to
     ;; hang out of the attack wave and wait for a power-up, then tank and burst -- so
     ;; power-up timing IS that fight's difficulty dial, and it deserves tuning separately
     ;; from enemy density.
     ;;
     ;; The lever that matters most here is the run-up, not the rate. At the shipped 4000
     ;; units the opening two thirds of a typical stage-two life had no pick-ups in it at
     ;; all -- a long time to be told to wait for something that is not coming yet -- so
     ;; 1200 gets the first one into the part of the level you actually survive to.
     ;;
     ;; Measured, because the three levers compound: moving all of them together took the
     ;; rate from 7.5 a minute to 20, which is not "slightly more", it is a different
     ;; game. The other two stay at a modest bump and the run-up does the work.
     ("spawn_collectable.probability" . "3")
     ("spawn_collectable.spawn_delta" . "900")
     ("spawn_collectable.start_delta" . "1800"))

    ("level_brain_pain.cfg"
     ;; Stage three wanted a smaller nudge than the cave: 7.5 a minute up to 8 or 9,
     ;; not to 11.
     ;;
     ;; The two levers do not behave the same way, and that is what the numbers are for.
     ;; Weight moves in whole steps -- 2 gives 7.5 and 3 gives 11.3, with nothing in
     ;; between to choose. So the weight goes to 3 and the GAP becomes the ceiling, which
     ;; is continuous: measured, the rate tracks 1/gap closely once the gap binds, so
     ;; 11.3 * 900/1150 predicts about 8.8. Solved from measurements rather than from the
     ;; spawn arithmetic, which has the rate-scale stretch in it and is easy to
     ;; double-count -- a first guess of 1450 from that arithmetic came out at 6.3.
     ("spawn_collectable.probability" . "3")
     ("spawn_collectable.spawn_delta" . "1150")
     ;; And a shorter run-up, for the same reason the cave got one: at the shipped 4000
     ;; units a stage-three life that lasts 24 seconds sees its first pick-up at about
     ;; 20 -- a measured 2.5 a minute in practice against a nominal 7.5. The run-up, not
     ;; the rate, is what a player actually feels here.
     ("spawn_collectable.start_delta" . "2500")))
  "Balance overrides, grouped by the config file they apply to.

   :ALL entries apply everywhere; a filename's entries apply to that file only and win
   over :ALL, so a stage can be tuned without disturbing the others.")

(defun %overrides-for (config)
  "The entries in play for CONFIG, most specific first."
  (let* ((name (and (config-source config)
                    (file-namestring (config-source config))))
         (specific (and name (assoc name *overrides* :test #'string=))))
    (append (cdr specific) (cdr (assoc :all *overrides*)))))

(defun config-value (config key)
  "The raw, untrimmed value, or NIL if absent."
  (let ((override (assoc key (%overrides-for config) :test #'string=)))
    (if override
        (cdr override)
        (gethash key (config-table config)))))

(defun config-text (config key &optional default)
  (let ((v (config-value config key)))
    (if v (%trim v) default)))

(defun config-int (config key &optional (default 0))
  (let ((v (config-text config key)))
    (or (and v (parse-integer v :junk-allowed t)) default)))

(defun %parse-leading-float (s)
  "Parse a leading decimal number and ignore any trailing junk, the way C's atof does.
   Needed because several values are written with a C float suffix, e.g.
   `splash_anim_delta = 0.15f` in level_intro.cfg, which the CL reader would choke on."
  (let ((i 0) (n (length s)) (sign 1) (int 0) (frac 0) (scale 1) (any nil))
    (when (and (< i n) (member (char s i) '(#\+ #\-)))
      (when (char= (char s i) #\-) (setf sign -1))
      (incf i))
    (loop while (and (< i n) (digit-char-p (char s i)))
          do (setf int (+ (* int 10) (digit-char-p (char s i))) any t) (incf i))
    (when (and (< i n) (char= (char s i) #\.))
      (incf i)
      (loop while (and (< i n) (digit-char-p (char s i)))
            do (setf frac (+ (* frac 10) (digit-char-p (char s i)))
                     scale (* scale 10)
                     any t)
               (incf i)))
    (when any
      (* sign (+ int (/ (float frac 1.0) scale))))))

(defun config-float (config key &optional (default 0.0))
  (let ((v (config-text config key)))
    (or (and v (plusp (length v)) (%parse-leading-float v))
        default)))

(defun config-bool (config key &optional default)
  (let ((v (config-text config key)))
    (cond ((null v) default)
          ((member v '("1" "true" "TRUE" "True" "yes" "YES") :test #'string=) t)
          ((member v '("0" "false" "FALSE" "False" "no" "NO") :test #'string=) nil)
          (t default))))

(defun config-list (config key)
  "Split a comma-separated value, trimming each element and dropping empties.
   Used for the many `foo_list = a, b, c` keys."
  (let ((v (config-text config key)))
    (when v
      (let ((items '()) (start 0))
        (dotimes (i (length v))
          (when (char= (char v i) #\,)
            (push (%trim (subseq v start i)) items)
            (setf start (1+ i))))
        (push (%trim (subseq v start)) items)
        (remove "" (nreverse items) :test #'string=)))))

(defun config-keys (config)
  (loop for k being the hash-keys of (config-table config) collect k))
