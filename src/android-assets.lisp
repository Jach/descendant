(defpackage #:com.thejach.descendant.android
  (:use #:cl)
  (:local-nicknames (#:paths #:com.thejach.descendant.paths))
  (:documentation
   "Getting assets/ out of the APK and onto the filesystem, once, on first run.

    Android only, and the whole file is absent from other builds -- see descendant.asd.")
  (:export #:ensure-assets))

(in-package #:com.thejach.descendant.android)

;;;; The game reads its assets with ordinary CL file operations: WITH-OPEN-FILE on a
;;;; pathname under PATHS:APP-ROOT. Inside an APK there is no such pathname. assets/ is a
;;;; region of the .apk zip, reachable only through the Android asset manager, and no
;;;; amount of pathname arithmetic will make OPEN find it.
;;;;
;;;; Rather than teach every reader in the port about that -- theme.lisp, font.lisp,
;;;; config.lisp, audio.lisp, and the score table and options that get WRITTEN -- the
;;;; files are copied out once, on first run, into the app's private directory. After
;;;; that every path in the game is a real path again and nothing else needs to know this
;;;; happened.
;;;;
;;;; SDL is what does the reading. SDL_RWFromFile on Android tries the asset manager
;;;; before the filesystem, so a relative path names the copy inside the APK, and no JNI
;;;; of our own is needed.

(defconstant +chunk+ (* 64 1024))

(defun %sdl-error ()
  (or (ignore-errors (cffi:foreign-funcall "SDL_GetError" :string)) "?"))

(defun %read-asset (name)
  "The APK's assets/NAME as a byte vector, or NIL if it is not there."
  (let ((rw (cffi:foreign-funcall "SDL_RWFromFile" :string name :string "rb" :pointer)))
    (when (cffi:null-pointer-p rw)
      (return-from %read-asset nil))
    (unwind-protect
         (let* ((size (cffi:foreign-funcall "SDL_RWsize" :pointer rw :int64))
                (out (make-array (max 0 size) :element-type '(unsigned-byte 8)))
                (got 0))
           (cffi:with-foreign-object (buf :unsigned-char +chunk+)
             (loop
               (let ((n (cffi:foreign-funcall "SDL_RWread"
                                              :pointer rw :pointer buf
                                              :size 1 :size +chunk+ :size)))
                 (when (zerop n) (return))
                 ;; SDL_RWsize can only be trusted as a hint for a compressed asset, so
                 ;; the vector grows if the file turns out to be longer than advertised.
                 (when (< (length out) (+ got n))
                   (let ((bigger (make-array (+ got n) :element-type '(unsigned-byte 8))))
                     (replace bigger out)
                     (setf out bigger)))
                 (dotimes (i n)
                   (setf (aref out (+ got i)) (cffi:mem-aref buf :unsigned-char i)))
                 (incf got n))))
           (if (= got (length out)) out (subseq out 0 got)))
      (cffi:foreign-funcall "SDL_RWclose" :pointer rw :int))))

(defun %write-file (path bytes)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede :if-does-not-exist :create)
    (write-sequence bytes out))
  path)

(defun %manifest ()
  "The list of asset paths, as written by android/build.sh.

   A manifest rather than a directory walk because the asset manager cannot be asked
   what it contains through SDL -- AAssetDir is JNI-side, and adding a JNI call to
   enumerate a list we already know at build time would be work for its own sake."
  (let ((bytes (%read-asset "MANIFEST")))
    (unless bytes
      (error "no MANIFEST in the APK's assets; android/build.sh should have written one"))
    (let ((text (map 'string #'code-char bytes))
          (lines '()))
      (with-input-from-string (in text)
        (loop for line = (read-line in nil)
              while line
              do (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
                   (when (plusp (length trimmed)) (push trimmed lines)))))
      (nreverse lines))))

(defun ensure-assets (&key force)
  "Copy assets/ out of the APK into the app's private directory, unless it is there.

   Returns the number of files written. Cheap on every run after the first: it stats each
   destination and does nothing when they all exist.

   The two files the game itself writes -- options.ini and the score table -- are never
   overwritten. They live in the same directory as the assets by PATHS:USER-DATA-PATH's
   design, and a reinstall restoring the shipped defaults over somebody's settings and
   high scores would be a poor way to thank them for playing."
  (let ((written 0))
    (dolist (name (%manifest) written)
      (let ((destination (merge-pathnames name (paths:app-root))))
        (when (or force (not (probe-file destination)))
          (let ((bytes (%read-asset name)))
            (cond
              ((null bytes)
               (warn "asset ~a is in the manifest but not in the APK: ~a"
                     name (%sdl-error)))
              (t (%write-file destination bytes)
                 (incf written)))))))))
