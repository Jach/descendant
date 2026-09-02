#|
Build a distributable folder:  sbcl --script build.lisp

Produces a bundle under bin/ beside this file, containing the executable, the foreign
libraries the game brings with it, and assets/. That whole folder is the thing to hand to
somebody -- the executable alone will not run, and is not meant to.

Each platform gets its own subdirectory, so a Linux and a Windows bundle can exist side
by side without either build having to tidy up after the other.

Deploy decides what goes in. See src/deployment.lisp for what is deliberately left out:
anything belonging to the host rather than to us, which is to say the graphics driver
and the display server.
|#

(in-package :cl-user)

#-quicklisp
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))

;;; The heap the binary will start with.
;;;
;;; Deploy passes :SAVE-RUNTIME-OPTIONS T to SAVE-LISP-AND-DIE, which means the dumped
;;; executable inherits the runtime options of the SBCL that built it -- including
;;; --dynamic-space-size. So the way to give the game a bigger heap is to build it with
;;; one; there is nothing to set at runtime and nothing for a launcher to do.
;;;
;;; That would normally mean remembering a flag on every invocation, in every build
;;; script, in every environment. Instead this re-runs itself once with the flag if it
;;; was not started with it, so `sbcl --script build.lisp` is correct however it is
;;; called and the chroot script needs to know nothing about it.

(defparameter *heap-mb* 2048
  "Two gigabytes. Not because the game needs it -- it runs in a fraction of the default
   gigabyte -- but because headroom is what makes collections rare, and a collection is
   the one thing that can drop a frame on a fixed timestep.")

(let ((wanted (* *heap-mb* 1024 1024)))
  (when (and (< (sb-ext:dynamic-space-size) wanted)
             (not (uiop:getenv "DESCENDANT_BUILD_HEAP_SET")))
    (format t "~&Restarting the build with a ~d MB heap.~%" *heap-mb*)
    (finish-output)
    (uiop:quit
     (nth-value 2
                (uiop:run-program
                 (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                       "--dynamic-space-size" (princ-to-string *heap-mb*)
                       "--script" (uiop:native-namestring *load-truename*))
                 :environment (cons "DESCENDANT_BUILD_HEAP_SET=1"
                                    (sb-ext:posix-environ))
                 :output :interactive :error-output :interactive
                 :ignore-error-status t)))))

;; Make this checkout visible to ASDF wherever it has been put -- the chroot build copies
;; the tree somewhere else entirely.
(push (uiop:pathname-directory-pathname
       (uiop:ensure-absolute-pathname *load-truename*))
      asdf:*central-registry*)

;; Force a recompile. The fasl cache is shared with ordinary REPL work, and a build that
;; silently reuses fasls compiled under a different policy -- or from a different commit
;; -- is a build that cannot be reasoned about.
(handler-bind ((warning #'muffle-warning))
  (ql:quickload "descendant" :force t))

;; Each platform's bundle gets its own subdirectory of bin/.
;;
;; They shared bin/ at first, which meant the Windows build had to clear away the Linux
;; one before it could write -- and it cannot: under Wine a Unix symlink resolves to its
;; target's truename, so the soname links the Linux build leaves behind come back as
;; several directory entries all naming one file. The first delete succeeds and the next
;; fails with "File not found". The deeper point is that a Windows build has no business
;; touching .so files at all, and with separate directories it never sees one.
;;
;; DEPLOY:DEPLOY-OP merges the system's build-pathname against bin/, so a directory in
;; that name is all it takes.
(defparameter *bundle-subdirectory*
  (if (uiop:os-windows-p) "windows/" "linux/"))

(setf (asdf/system:component-build-pathname (asdf:find-system "descendant"))
      (concatenate 'string *bundle-subdirectory* "descendant"))

;; No *FEATURES* flag needed to tell the code it is a binary: DEPLOY:DEPLOYED-P answers
;; that at runtime, and TOPLEVEL sets PATHS:*DEPLOYED* from it. A feature pushed at build
;; time would be baked into every fasl in the shared cache, which is how it leaks into
;; the next REPL session.
(asdf:make "descendant")

(let ((bundle (merge-pathnames (concatenate 'string "bin/" *bundle-subdirectory*)
                               *load-truename*)))
  (format t "~&~%Built ~a:~%" bundle)
  (dolist (file (sort (directory (merge-pathnames "*.*" bundle))
                      #'string< :key #'namestring))
    (format t "  ~a~@[  ~:d bytes~]~%"
            (file-namestring file)
            (ignore-errors (with-open-file (s file :element-type '(unsigned-byte 8))
                             (file-length s))))))

(uiop:quit 0)
