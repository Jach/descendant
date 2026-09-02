(in-package #:com.thejach.descendant.cheats)

;;;; Typed cheat codes.
;;;;
;;;; ADDED, not ported. The original has no cheat of any kind -- nothing in the C matches
;;;; iddqd or anything like it, and there is no key-sequence buffer anywhere in it. This
;;;; is a DOOM reference bolted on because it is useful for reaching the later parts of a
;;;; level without playing all the way there.
;;;;
;;;; The matcher is a rolling buffer rather than an index into one expected string, so
;;;; codes with repeated prefixes still fire: typing "ididdqd" ends in "iddqd" and
;;;; triggers, where a naive reset-on-mismatch would have given up at the second "i".

(defparameter *buffer-size* 16
  "Longest code we can match. Kept small; this is a ring, not a history.")

(defvar *buffer* (make-string 0)
  "The last few letters typed, oldest first.")

(defvar *codes* '()
  "(code-string . thunk). Populated by DEFINE-CHEAT.")

(defun define-cheat (code action)
  "Register ACTION to run when CODE is typed. Re-registering a code replaces it."
  (let ((code (string-downcase code)))
    (setf *codes* (cons (cons code action)
                        (remove code *codes* :key #'car :test #'string=)))
    code))

(defun reset ()
  (setf *buffer* (make-string 0)))

(defun feed (char)
  "Add one typed character and fire any code it completes. Returns the code that fired,
   or NIL. Never consumes the character -- cheats observe input, they do not eat it, so
   the letters still reach whatever else is listening."
  (let ((char (char-downcase char)))
    (when (alpha-char-p char)
      (setf *buffer*
            (let ((joined (concatenate 'string *buffer* (string char))))
              (if (> (length joined) *buffer-size*)
                  (subseq joined (- (length joined) *buffer-size*))
                  joined)))
      (loop for (code . action) in *codes*
            when (and (<= (length code) (length *buffer*))
                      (string= code *buffer* :start2 (- (length *buffer*) (length code))))
              do (funcall action)
                 (return code)))))

;;; ---------------------------------------------------------------------------
;;; The codes themselves

(defun toggle-invincible ()
  (setf player:*invincible?* (not player:*invincible?*)))

(define-cheat "iddqd" #'toggle-invincible)
