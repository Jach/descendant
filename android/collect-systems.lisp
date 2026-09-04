#|
Print the source directory of every system the game needs, one per line.

    sbcl --script android/collect-systems.lisp

Used by android/build-core.sh to decide what to stage for the device. Desktop side.

Determined by loading the game and asking ASDF what that took, rather than by reading
dependency lists: ASDF:ALREADY-LOADED-SYSTEMS after a successful load IS the closure,
transitive dependencies and all, with no chance of the list here drifting from the one in
descendant.asd.

SBCL's own contribs are excluded. UIOP, ASDF and sb-* come from the device's SBCL_HOME --
the cross-built ones, compiled for the target -- and pushing the desktop's would be both
wrong and useless.
|#

#-quicklisp
(let ((init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file init) (load init)))

(defparameter *here* (uiop:pathname-directory-pathname *load-truename*))

(push (merge-pathnames "../" *here*) asdf:*central-registry*)

(handler-bind ((warning #'muffle-warning))
  (ql:quickload :descendant :silent t))

;;; Two more that must not be staged, for the same reason as the contribs -- the device
;;; already has a better copy, or no use for one:
;;;
;;;   uiop       ASDF on the device carries its own, and a second copy in the registry is
;;;              a chance for the two to disagree about which is loaded.
;;;   quicklisp  the client itself. It exists to fetch things over a network, and the
;;;              device build has everything already and no network to want.
(defparameter *skip* '("uiop" "quicklisp"))

(defun skip? (dir)
  (let ((name (car (last (pathname-directory dir)))))
    (some (lambda (s)
            (or (string= name s)
                (and (> (length name) (length s))
                     (string= s (subseq name 0 (length s)))
                     (char= #\- (char name (length s))))))
          *skip*)))

(let ((sbcl-home (truename (sb-int:sbcl-homedir-pathname)))
      (dirs '()))
  (dolist (name (asdf:already-loaded-systems))
    (let* ((system (asdf:find-system name nil))
           (dir (and system (ignore-errors (asdf:system-source-directory system)))))
      (when dir
        (let ((dir (truename dir)))
          ;; Anything under SBCL_HOME is a contrib and belongs to the target's own build.
          (unless (or (uiop:subpathp dir sbcl-home) (skip? dir))
            (pushnew dir dirs :test #'equal))))))
  ;; Many systems share one directory -- cffi, cffi-toolchain and cffi-grovel are one
  ;; checkout -- so the list is directories, already deduplicated, not system names.
  (dolist (dir (sort dirs #'string< :key #'namestring))
    (format t "~a~%" (namestring dir))))
