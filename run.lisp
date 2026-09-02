#|
Launch the game with:  sbcl --script run.lisp
|#

#-quicklisp
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))

;; Make this checkout visible to ASDF regardless of where it lives.
(push (uiop:pathname-directory-pathname *load-truename*) asdf:*central-registry*)

(ql:quickload :descendant)

(com.thejach.descendant:main)
