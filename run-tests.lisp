#|
Run the test suite:  sbcl --script run-tests.lisp

Exits 0 if everything passed, 1 on any failure, 2 if the system would not even load,
so it works as a CI step or a git hook.

Nothing here needs a display or an audio device: the renderer writes PPMs directly and
the audio layer has a *muted?* switch, so the whole suite runs headless.
|#

#-quicklisp
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))

;; Make this checkout visible to ASDF regardless of where it lives.
(push (uiop:pathname-directory-pathname *load-truename*) asdf:*central-registry*)

(handler-case
    (let ((*standard-output* (make-broadcast-stream)))   ; hush the quickload chatter
      (ql:quickload :descendant/test :verbose nil))
  (error (e)
    (format *error-output* "~&Could not load descendant/test:~%~a~%" e)
    (uiop:quit 2)))

;; Point everything that PERSISTS at scratch files for the whole run.
;;
;; Not a convenience. The suite drives the real menu, and the real menu saves when you
;; leave the options screen -- so a test that walks to GO BACK writes the player's actual
;; options.ini, and one that had just been setting difficulty to 3 to check the clamping
;; left it there. That is exactly how the shipped difficulty default appeared to change.
;; The high score table had the same accident earlier for the same reason, which is why
;; both overrides exist at all; binding them here means no future test has to remember.
(let ((scratch (uiop:temporary-directory)))
  (setf (symbol-value (uiop:find-symbol* "*PATH*" "COM.THEJACH.DESCENDANT.SETTINGS"))
        (merge-pathnames "descendant-test-options.ini" scratch)
        (symbol-value (uiop:find-symbol* "*SCORES-PATH*"
                                         "COM.THEJACH.DESCENDANT.LEVEL.SCORE"))
        (merge-pathnames "descendant-test-highscores.txt" scratch)))

(let ((passed (uiop:symbol-call "COM.THEJACH.DESCENDANT.TEST" "RUN-ALL")))
  (terpri)
  (uiop:quit (if passed 0 1)))
