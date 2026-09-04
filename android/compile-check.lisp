#|
Compile the Android build here, on the desktop, without a device.

    sbcl --script android/compile-check.lisp

Not a substitute for android/build-core.sh -- the fasls are for the wrong machine and are
thrown away. What it is for is the class of mistake that otherwise costs a full
push-and-compile cycle on the phone to find:

  - a package named in an #+android form but defined by a file that comes LATER in
    descendant.asd. A package must exist when a form mentioning it is READ, so this fails
    with "Package X does not exist" and nothing about the ordering that caused it. That
    is a real bug this file was written after hitting.
  - a misspelled lgame or SDL constant behind #+android, invisible to every desktop build
    and every test.
  - a component added under the wrong :if-feature.

It works because nothing Android-specific is resolved at compile time: SDL and JNI entry
points are called through CFFI by name at runtime, and the constants exist in lgame on
every platform. The code compiles here; it simply could not run.

WHY IT DOES NOT JUST PUSH :ANDROID AND CALL LOAD-SYSTEM

Two false starts, both worth recording.

Pushing :ANDROID at runtime changes nothing about already-compiled code, because reader
conditionals are resolved at compile time -- so the obvious version silently tests the
desktop build. Adding :FORCE T fixes that and breaks something else: it recompiles
cl-autowrap, which reads *FEATURES* to build an architecture triple, producing
"x86_64-pc-linux-android" on this host. Nothing is named after that, so autowrap reaches
for c2ffi and the check dies having tested none of our code. Redirecting the fasl cache to
keep the poisoned objects out of the real build has the same effect for the same reason:
an empty cache means everything recompiles, cl-autowrap included.

So the dependencies are loaded normally and left alone, and only THIS project's files are
compiled again, by hand, into a scratch directory. Nothing that ships is rebuilt and no
cache is disturbed.
|#

(require :asdf)

#-quicklisp
(let ((init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file init) (load init)))

(defparameter *here* (uiop:pathname-directory-pathname *load-truename*))
(defparameter *scratch* (merge-pathnames "out/compile-check/" *here*))

(push (merge-pathnames "../" *here*) asdf:*central-registry*)

(format t "~&loading the ordinary build (no :android)...~%")
(finish-output)

(handler-case (handler-bind ((warning #'muffle-warning))
                (asdf:load-system :descendant))
  (error (e)
    (format t "~&~%FAILED before the check began -- the desktop build is broken:~%~a~%" e)
    (uiop:quit 1)))

(defun if-feature (component)
  (asdf::component-if-feature component))

(defun included? (component)
  (let ((feature (if-feature component)))
    (or (null feature) (uiop:featurep feature))))

(defun android-only? (component)
  (eq :android (if-feature component)))

(let* ((system (asdf:find-system "descendant"))
       (module (first (asdf:component-children system)))
       (components (asdf:component-children module)))

  (pushnew :android *features*)
  (ensure-directories-exist *scratch*)

  (format t "~&compiling the Android build on ~a...~%~%" (machine-type))
  (finish-output)

  (let ((compiled 0) (skipped '()))
    (dolist (component components)
      (cond
        ((not (included? component))
         (push (asdf:component-name component) skipped))
        (t
         (let* ((name (asdf:component-name component))
                (source (asdf:component-pathname component))
                (output (make-pathname :name name :type "fasl" :defaults *scratch*)))
           (multiple-value-bind (fasl warnings failure)
               (handler-bind
                   ((warning #'muffle-warning)
                    ;; A constant whose value differs per platform -- LEVEL-SCORE's
                    ;; +INPUT-LIFT+ is 0 on the desktop and 48 on Android -- is redefined
                    ;; when the second variant compiles into an image already holding the
                    ;; first. That is this check's doing and nothing a real build ever
                    ;; sees, since a real build compiles one variant once. Take the new
                    ;; value and carry on.
                    (sb-ext:defconstant-uneql
                        (lambda (condition)
                          (let ((restart (find-restart 'continue condition)))
                            (when restart (invoke-restart restart)))))
                    ;; Anything else: say which file, rather than a hundred frames of
                    ;; backtrace out of COMPILE-FILE.
                    (error (lambda (condition)
                             (format t "~&~%FAILED compiling ~a~%   ~a~%~%~a~%"
                                     name source condition)
                             (uiop:quit 1))))
                 (compile-file source :output-file output :verbose nil :print nil))
             (declare (ignore warnings))
             (when failure
               (format t "~&~%FAILED compiling ~a (see above)~%   ~a~%" name source)
               (uiop:quit 1))
             (incf compiled)
             ;; The android-only files are LOADED as well as compiled, because the files
             ;; after them mention their packages and a package has to exist to be read.
             ;; The rest are only compiled -- loading a second, :ANDROID copy of the whole
             ;; game over the one already in this image would prove nothing and redefine
             ;; a great deal.
             (when (android-only? component)
               (load fasl)))))))

    (format t "~&OK -- ~d files compiled with :android~%" compiled)
    (format t "   android-only: ~{~a~^ ~}~%"
            (mapcar #'asdf:component-name
                    (remove-if-not #'android-only? components)))
    (format t "   left out:     ~{~a~^ ~}~%" (nreverse skipped))))

(uiop:quit 0)
