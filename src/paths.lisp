(in-package #:com.thejach.descendant.paths)

(defvar *deployed* nil
  "NIL during development and when running from a source checkout, in which case assets
   are found relative to the ASDF system directory. The binary build sets this to T
   before dumping the image, after which assets are found relative to the directory the
   binary was launched from.")

(defun local-dev? ()
  (not *deployed*))

#+android
(defun android-root ()
  "The app's own private directory, which on Android is the only place it may write.

   Asked of SDL rather than derived: the path contains the package name and Android is
   free to change where such directories live, and SDL is already talking to the JNI
   side that knows. Called through CFFI by name so this file needs no build-time
   knowledge of SDL -- by the time anything calls APP-ROOT, lgame has loaded it.

   The fallbacks are for running outside an APK, which is how the port is tested on the
   device over adb: there is no JNI environment, SDL returns nothing, and assets sit
   beside the system as they do in development."
  (or (ignore-errors
       (let ((path (cffi:foreign-funcall "SDL_AndroidGetInternalStoragePath" :string)))
         (when (and path (plusp (length path)))
           (pathname (concatenate 'string path "/")))))
      (ignore-errors (asdf:system-source-directory "descendant"))
      *default-pathname-defaults*))

(defun app-root ()
  "Where assets/ lives.

   Deployed, that is the directory the executable SITS IN, not the one it was launched
   from -- DEPLOY:RUNTIME-DIRECTORY resolves argv0 to get there. Using the working
   directory instead would mean the game only found its assets when started from inside
   its own folder, which is not how anybody runs a program they have been given.

   Android has no executable to sit beside and no Deploy, so it answers separately."
  #+android
  (android-root)
  #-android
  (if (local-dev?)
      (asdf:system-source-directory "descendant")
      (deploy:runtime-directory)))

(defun asset-path (&rest components)
  "Build a path under assets/. COMPONENTS are directory names followed by a filename,
   e.g. (asset-path \"Themes\" \"crash_site.thm\")."
  (let ((file (car (last components)))
        (dirs (butlast components)))
    (merge-pathnames
     (make-pathname :directory (list* :relative "assets" dirs)
                    :name (pathname-name file)
                    :type (pathname-type file))
     (app-root))))

;;; The original's directory layout, preserved verbatim (DSC_PATH_* in
;;; dsc_descendant_state.h). Assets are copied from origRef/Resources unmodified.

(defvar *assets-writable* :unknown
  "Cached answer from %ASSETS-WRITABLE?, since it costs a file create and the answer
   cannot change while the game is running. Reset it to :UNKNOWN to ask again.")

(defun %assets-writable? ()
  "Can we write into assets/? Answered by trying, because nothing else is reliable --
   permissions, ownership, read-only mounts and container overlays all disagree about
   what a mode bit means."
  (when (eq *assets-writable* :unknown)
    (setf *assets-writable*
          (let ((probe (asset-path (format nil "write-probe-~36r.tmp" (random (expt 2 32))))))
            (handler-case
                (progn
                  (with-open-file (out probe :direction :output
                                             :if-exists :supersede
                                             :if-does-not-exist :create)
                    (write-char #\x out))
                  (ignore-errors (delete-file probe))
                  t)
              (error () nil)))))
  *assets-writable*)

(defun user-data-path (name)
  "Where a file the GAME WRITES belongs: the high score table, the options.

   assets/ first, beside everything else. Shipping an editable ini next to the game is
   ordinary -- plenty of games do exactly that, and a player who wants to hand-edit one
   should find it where the rest of the game is rather than buried in a dot-directory.

   The XDG data directory is only the fallback, for when assets/ turns out not to be
   writable: installed under /opt or /usr, unpacked read-only, or shared between
   accounts. In that case there is nowhere else to put it, and silently failing to save
   would be worse than saving somewhere less obvious."
  (if (%assets-writable?)
      (asset-path name)
      (let ((path (uiop:xdg-data-home "descendant/" name)))
        (ensure-directories-exist path)
        path)))

(defun theme-path  (name) (asset-path "Themes" name))
(defun font-path   (name) (asset-path "Fonts" name))
(defun config-path (name) (asset-path "Config" name))
(defun sound-path  (name) (asset-path "Sounds" name))
