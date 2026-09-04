#|
Build the game's core. Runs ON THE DEVICE, under the cross-built SBCL.

    adb shell "cd /data/local/tmp/descendant && sbcl --load build-android.lisp"

Driven by android/build-core.sh, which pushes the sources first. It is here rather than in
build.sh because fasls are target-specific: the game and its whole dependency tree have to
be compiled by the SBCL that will run them.

Two things have to be put right before anything can be loaded, both in cl-autowrap's
neighbourhood and neither our fault. See the two sections below.
|#

(in-package :cl-user)

;;; First, and on its own line, because LOAD reads and evaluates one form at a time and
;;; every form below mentions a UIOP or ASDF symbol. A bare core has neither -- they are
;;; contribs, loaded from SBCL_HOME -- so without this the file fails while being READ,
;;; with "Package UIOP does not exist", before a line of it has run.
(require :asdf)

(pushnew :android *features*)

;;; cl-opengl opens libGL at load time, and there is no libGL here -- Android has
;;; libGLESv2.so and nothing else. Its own :CL-OPENGL-NO-PRELOAD feature turns that
;;; off, which is better than letting the load fail and patching afterwards, because
;;; there is no afterwards: USE-FOREIGN-LIBRARY runs while the file is being loaded.
;;; The library is renamed and opened further down, once everything is in.
(pushnew :cl-opengl-no-preload *features*)

;;; ---------------------------------------------------------------------------
;;; Where the sources are
;;;
;;; No Quicklisp. It exists to fetch things, and everything is already here -- pushed by
;;; build-core.sh. Plain ASDF over a directory of checkouts has no network to want and
;;; nothing to resolve.

;; This file sits at the top of the staged tree, with systems/ beside it -- flat, because
;; the device copy is a staging area rather than a checkout and nesting it only gave the
;; push somewhere to go wrong.
(defparameter *root* (uiop:pathname-directory-pathname *load-truename*))
(defparameter *tree* *root*)

;; Everything staged flat under systems/, the game and lgame included -- they are systems
;; like any other and giving them a special case would only be somewhere for the two paths
;; to disagree. android/collect-systems.lisp decided the list.
(let ((dirs (directory (merge-pathnames "systems/*/" *tree*))))
  (when (null dirs)
    (error "no systems staged under ~a -- run android/build-core.sh, not this directly"
           (merge-pathnames "systems/" *tree*)))
  (dolist (dir dirs)
    (pushnew dir asdf:*central-registry* :test #'equal))
  (format t "~&~d system directories on the registry~%" (length dirs)))

;;; ---------------------------------------------------------------------------
;;; Fix 1: cl-autowrap picks the wrong architecture triple on Android
;;;
;;; AUTOWRAP::LOCAL-ARCH assembles a triple from four functions, each a pile of reader
;;; conditionals. On this target both :LINUX and :ANDROID are in *FEATURES* -- SBCL's own
;;; Android notes flag the same trap, and had to write #+(and linux (not android)) in two
;;; places for it -- and LOCAL-VENDOR asks only about :LINUX:
;;;
;;;     #+(or linux windows) "-pc"          ; fires
;;;     #+(not (or linux windows darwin)) "-unknown"
;;;
;;; so the vendor comes out "-pc" where Android wants "-unknown", while LOCAL-ENVIRONMENT
;;; gets "-android" right by accident of ordering. The result is
;;;
;;;     aarch64-pc-linux-android
;;;
;;; which is in nobody's *KNOWN-ARCHES* and has no spec anywhere. autowrap then reaches
;;; for c2ffi to generate one, does not find it, and gives up.
;;;
;;; Overriding LOCAL-ARCH outright rather than patching LOCAL-VENDOR: the triple we want
;;; is a known constant, and stating it is clearer than repairing the derivation of it.

(asdf:load-system :cl-autowrap)

(defparameter *arch* "aarch64-unknown-linux-android")

(let ((got (funcall (find-symbol "LOCAL-ARCH" :autowrap))))
  (format t "~&autowrap says the arch is ~s~%" got)
  (unless (string= got *arch*)
    (format t "   overriding with ~s~%" *arch*)
    (setf (fdefinition (find-symbol "LOCAL-ARCH" :autowrap))
          (lambda () *arch*))))

;;; ---------------------------------------------------------------------------
;;; Fix 2: two bindings ship no spec for this architecture
;;;
;;; cl-sdl2 carries SDL2.aarch64-unknown-linux-android.spec. cl-sdl2-mixer and
;;; cl-sdl2-image carry nothing for aarch64 at all -- not Android, not even Linux -- so
;;; this is an upstream ARM gap rather than an Android one.
;;;
;;; They are copied from the x86-64 Linux specs rather than generated, because for these
;;; two libraries the architecture makes no difference. Comparing cl-sdl2's own three
;;; specs, which do exist for all of x86-64 Linux, aarch64 Linux and aarch64 Android:
;;;
;;;   aarch64 gnu vs aarch64 android : no declaration differs in size
;;;   x86-64 gnu vs aarch64 gnu      : exactly two differ, __pthread_mutex_s and
;;;                                    __pthread_rwlock_arch_t
;;;
;;; Both are libc internals. SDL_image declares no public struct whatsoever, and
;;; SDL_mixer declares one -- Mix_Chunk, 192 bits, an int, a pointer, a Uint32 and a
;;; Uint8, which lays out identically on any LP64 target. Neither embeds a mutex.
;;;
;;; So the copy is sound for these two libraries specifically. It would not be a sound
;;; way to produce a spec in general, and if either library ever exposes a struct
;;; containing a lock, this stops being true.

(defun spec-directory (system)
  "Quicklisp checkouts keep their version in the directory name -- cl-sdl2-mixer is
   staged as cl-sdl2-mixer-20241012-git -- so this globs rather than assuming."
  (first (directory (merge-pathnames (format nil "systems/~a*/src/spec/" system) *tree*))))

(defun ensure-spec (system header)
  (let ((dir (spec-directory system)))
    (cond
      ((null dir) (warn "~a: no spec directory under systems/~a*/" header system))
      (t
       (let ((from (merge-pathnames (format nil "~a.x86_64-pc-linux-gnu.spec" header) dir))
             (to   (merge-pathnames (format nil "~a.~a.spec" header *arch*) dir)))
         (cond
           ((probe-file to) (format t "~&~a: spec already present~%" header))
           ((probe-file from)
            (uiop:copy-file from to)
            (format t "~&~a: copied the x86-64 spec to ~a~%" header *arch*))
           (t (warn "~a: nothing to copy from at ~a" header from))))))))

(dolist (spec '(("cl-sdl2-mixer" . "SDL_mixer")
                ("cl-sdl2-image" . "SDL_image")))
  (ensure-spec (car spec) (cdr spec)))

;;; ---------------------------------------------------------------------------
;;; Build

(format t "~&~%loading descendant (this compiles the whole tree, once)~%")
(finish-output)

(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :descendant))

(format t "~&loaded.~%")
(finish-output)

;;; ---------------------------------------------------------------------------
;;; Fix 4: SBCL reopens shared objects by the name the BUILD used
;;;
;;; Rewriting CFFI's specs (below) is necessary and not sufficient. SBCL keeps its own
;;; list of what it dlopened, and SB-IMPL::REINIT walks it on startup, reopening each by
;;; the namestring it saw at load time. Here that is "libSDL2-2.0.so.0" -- the symlink
;;; build-core.sh makes in /data/local/tmp so the bindings can find the library at all.
;;; The APK has no such name and no way to make one, so REINIT dies before a line of Lisp
;;; runs.
;;;
;;; So: save no shared objects. Closing them empties SBCL's list, REINIT has nothing to
;;; do, and TOPLEVEL opens them itself from the corrected specs.
;;;
;;; THIS HAS TO HAPPEN BEFORE THE SPECS ARE REWRITTEN. DEFINE-FOREIGN-LIBRARY replaces
;;; the registry entry with a fresh object whose handle is NIL; the open handle belongs to
;;; the object it displaced. Patch first and CFFI reports nothing loaded, closes nothing,
;;; and the core still ships SBCL's record of the versioned name -- which is exactly the
;;; core that failed with "dlopen failed: library libSDL2-2.0.so.0 not found".

(defvar *reopen-libraries* nil
  "Foreign libraries for TOPLEVEL to open, closed here so the core saves none.")

(setf *reopen-libraries*
      (mapcar #'cffi:foreign-library-name (cffi:list-foreign-libraries :loaded-only t)))

(format t "~&closing ~d foreign libraries so the core saves none:~%"
        (length *reopen-libraries*))
(dolist (name *reopen-libraries*)
  (handler-case (progn (cffi:close-foreign-library name)
                       (format t "   ~a~%" name))
    (error (e) (warn "closing ~a: ~a" name e))))
(finish-output)

;;; ---------------------------------------------------------------------------
;;; Fix 3: Android has no versioned sonames
;;;
;;; cl-sdl2 asks for "libSDL2-2.0.so.0", then "libSDL2.so.0.2", then a bare "libSDL2"
;;; that dlopen takes verbatim and so never finds. Android has no concept of a versioned
;;; soname -- the file is exactly libSDL2.so -- and an APK only installs names matching
;;; lib*.so out of lib/arm64-v8a/, so there is nothing to rename and nowhere to put a
;;; symlink. The build gets by on symlinks in /data/local/tmp, but the APK cannot.
;;;
;;; So the specs are rewritten here, after loading and before the dump, which is what
;;; makes the saved core right: SAVE-LISP-AND-DIE keeps CFFI's registry, and on restart
;;; CFFI reopens each library from its spec. Patching before loading would not survive,
;;; because each library.lisp defines its own spec as it loads and would overwrite ours.

;;; Re-evaluating DEFINE-FOREIGN-LIBRARY rather than reaching into the library object:
;;; CFFI::FOREIGN-LIBRARY-SPEC is a reader with no SETF, and the macro is the supported
;;; way to replace a definition -- it re-registers under the same symbol.
(defun %relibrary (package name candidates)
  (let ((sym (find-symbol (string-upcase name) (find-package package))))
    (cond
      ((null sym) (warn "no library ~a in ~a; skipping" name package))
      (t
       (eval `(cffi:define-foreign-library ,sym
                (:unix (:or ,@candidates))
                (t (:default ,(first candidates)))))
       (format t "~&   ~a -> ~{~a~^, ~}~%" sym candidates)))))

(format t "~&pointing the foreign libraries at Android sonames:~%")
(%relibrary :sdl2 "libsdl2" '("libSDL2.so" "libSDL2-2.0.so.0"))
(%relibrary :sdl2-mixer "libsdl2-mixer" '("libSDL2_mixer.so" "libSDL2_mixer-2.0.so.0"))
(%relibrary :sdl2-image "libsdl2-image" '("libSDL2_image.so" "libSDL2_image-2.0.so.0"))
(%relibrary :lgame.font.ffi "lgame-sdl2-ttf" '("libSDL2_ttf.so" "libSDL2_ttf-2.0.so.0"))

;; GL is a rename rather than a version fix: the desktop's libGL does not exist on
;; Android at all, and GLES 3.0 -- everything renderer-gl.lisp needs -- is exported by
;; libGLESv2.so. Opened now rather than left to the first call, so a mistake here shows
;; up in this build rather than as a missing symbol mid-frame on the phone.
(%relibrary :cl-opengl-bindings "opengl" '("libGLESv2.so" "libGLESv3.so"))

;; GL is not opened here, and is added to the reopen list by hand.
;;
;; Not opened because the libraries were closed a moment ago so that the core saves none,
;; and opening one now would put it straight back. By hand because :CL-OPENGL-NO-PRELOAD
;; meant it was never opened during the load either, so it was not in the list of open
;; libraries there was anything to close.
(pushnew (find-symbol "OPENGL" :cl-opengl-bindings) *reopen-libraries*)
(finish-output)

;;; ---------------------------------------------------------------------------
;;; Before dumping, check that Fix 4 actually took
;;;
;;; A build tripwire rather than a comment, because the failure it catches is silent here
;;; and loud four steps later, in an APK, as a dlopen of a name nothing has used since the
;;; build. Getting the close and the patch the wrong way round produced exactly that, and
;;; the build reported "closing 0 foreign libraries" as though it had done its job.

;;; What matters is not whether anything is saved, but whether what is saved can be
;;; reopened on Android. A versioned soname cannot: the platform has no such concept, the
;;; files are plain libFoo.so, and an APK installs nothing else out of lib/arm64-v8a/.
;;; Anything else -- libc.so and friends, which something in the dependency tree opens
;;; directly through SB-ALIEN rather than through CFFI, so the close above never saw it --
;;; is a system library that dlopen finds by name in any process.
(let* ((names (mapcar #'sb-alien::shared-object-namestring sb-sys::*shared-objects*))
       (versioned (remove-if-not (lambda (n) (search ".so." n)) names)))
  (when versioned
    (error "~d shared object(s) would be saved under versioned sonames, which Android ~
            cannot reopen:~%~{   ~a~%~}~
            Either something opened a library after the close, or the close ran after ~
            the specs were rewritten -- DEFINE-FOREIGN-LIBRARY orphans the open handle, ~
            so the close has to come first."
           (length versioned) versioned))
  (format t "~&shared objects saved: ~:[none~;~:*~{~a~^ ~}~] (all resolvable on Android)~%"
          names)
  (format t "TOPLEVEL opens ~d more on startup~%" (length *reopen-libraries*)))

;;; ---------------------------------------------------------------------------
;;; Dump
;;;
;;; A plain core with a toplevel, not an executable and not a shared library. libsbcl.so
;;; is the runtime, main.c passes --core, and SAVE-LISP-AND-DIE :TOPLEVEL supplies the
;;; entry point -- so none of :EXECUTABLE, :CALLABLE-EXPORTS or a linkable runtime is
;;; needed. See PLAN.md 5.2.

(defun toplevel ()
  ;; Open the foreign libraries. They are deliberately absent from the saved core -- see
  ;; the section above the dump -- so this is not a refresh, it is the only time they are
  ;; opened in the app at all, and it has to happen before anything calls into SDL.
  ;;
  ;; Not CFFI:RELOAD-FOREIGN-LIBRARIES, which only refreshes libraries that are currently
  ;; open and therefore does nothing to a closed one.
  (dolist (name *reopen-libraries*)
    (handler-case (cffi:load-foreign-library name)
      (error (e) (format *error-output* "~&could not open ~a: ~a~%" name e))))
  (setf (symbol-value (find-symbol "*DEPLOYED*" :com.thejach.descendant.paths)) t)
  (funcall (find-symbol "MAIN" :com.thejach.descendant)))

(let ((out (merge-pathnames "descendant.core" *root*)))
  (format t "~&dumping ~a~%" out)
  (finish-output)
  (sb-ext:save-lisp-and-die out :toplevel #'toplevel :executable nil))
