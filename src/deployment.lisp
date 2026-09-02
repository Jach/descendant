(in-package #:com.thejach.descendant)

;;;; What ASDF:MAKE should put in bin/, and what the binary should do when it starts.
;;;;
;;;; Deploy's default is to copy every foreign library CFFI has opened. That is right for
;;;; the ones we ship -- SDL2 and its audio codecs, which a user's machine may not have,
;;;; or may have at the wrong version -- and wrong for the ones belonging to the machine.
;;;; A bundled libGL is the graphics driver of whoever built the binary, and shipping it
;;;; to somebody with a different card produces either a crash or software rendering. The
;;;; window system libraries are the same story.
;;;;
;;;; So the rule is: bundle what the game brings, never what the machine owns.

(deploy:define-hook (:deploy clean 100) (directory)
  "Empty this platform's bundle directory before anything is put in it.

   Deploy writes into whatever is already there, so a library from a previous build
   survives into the next one -- and a bundle that ships one library from a different
   build than the rest is the hardest kind of thing to diagnose. This was not theoretical:
   a Debian-built libSDL2 and a Gentoo-built one sat side by side in bin/ after building
   in both places, each with its own version suffix, both shipped.

   Only ever this platform's own directory -- see BUILD.LISP, where the Linux and Windows
   bundles are given separate ones. Cleaning across platforms is not something to make
   work; it is something to make impossible.

   Priority 100 so it runs before the hooks that fill the directory; they are at zero and
   below, and hooks run highest first."
  (when (probe-file directory)
    (uiop:delete-directory-tree (uiop:ensure-directory-pathname directory)
                                :validate (lambda (path)
                                            ;; Never anything but our own build output. Not a
                                            ;; test on the last component any more: each
                                            ;; platform's bundle sits in its own subdirectory,
                                            ;; so what has to hold is that the target is
                                            ;; somewhere under bin/.
                                            (uiop:subpathp
                                             (uiop:ensure-directory-pathname path)
                                             (merge-pathnames
                                              "bin/"
                                              (asdf:system-source-directory "descendant"))))
                                :if-does-not-exist :ignore))
  (ensure-directories-exist directory))

(deploy:define-hook (:deploy assets) (directory)
  "Copy assets/ into bin/.

   Written out rather than using DEPLOY:DEFINE-RESOURCE-DIRECTORY, which expects the
   hook to be passed the system it belongs to. In this version of Deploy the :deploy
   hooks are called with only :directory and :op, so that argument arrives NIL and the
   merge against it fails. Naming the system here needs no such argument."
  (deploy:copy-directory-tree
   (merge-pathnames "assets/" (asdf:system-source-directory "descendant"))
   directory
   :copy-root T
   ;; The two files the game writes are shipped, but not the developer's copies -- see
   ;; the hook below, which replaces them with defaults.
   :exclude (lambda (path destination)
              (declare (ignore destination))
              (member (file-namestring path) '("highscores.txt" "options.ini")
                      :test #'string=)))
  (%write-default-state (merge-pathnames "assets/" directory)))

(defun %write-default-state (assets)
  "Put a stock highscores.txt and options.ini in the bundle.

   These are meant to be found and edited -- that is why they live in assets/ rather than
   in a dot-directory -- so they ship present and at their defaults rather than absent.
   Generated rather than copied: the working tree's copies carry whatever the last
   playtest left, which would put the developer at the top of everybody's score table and
   hand out their difficulty as the default."
  (ensure-directories-exist assets)
  (score:write-high-scores score:*default-scores*
                           (merge-pathnames "highscores.txt" assets))
  ;; PATHS:*DEPLOYED* bound because the file being written is for a deployed install,
  ;; not for this checkout -- that is what makes it come out fullscreen and fast rather
  ;; than windowed and slow. Safe to bind here: both paths are passed explicitly, so
  ;; nothing consults APP-ROOT while it is set.
  (let ((paths:*deployed* t)
        (settings:*path* (merge-pathnames settings:*file-name* assets)))
    (settings:reset)
    (settings:save-settings)))

;;; ---------------------------------------------------------------------------
;;; Transitive dependencies
;;;
;;; Deploy copies the libraries CFFI opened and nothing else. That is its whole model:
;;; it knows about libSDL2_mixer because we asked CFFI for it, and it has no idea that
;;; libSDL2_mixer in turn wants libxmp, because nothing in Lisp ever mentions libxmp. The
;;; dynamic linker resolves those at load time from the host, so a bundle built where they
;;; exist runs only where they exist -- which showed up the moment a Debian-built bundle
;;; met a machine without libxmp installed.
;;;
;;; So we walk them ourselves. Deploy does have LIBRARY-DEPENDENCIES, but it shells out to
;;; patchelf, which then has to be installed in every build environment; the needed names
;;; are four fields into the ELF header and reading them directly is both fewer moving
;;; parts and usable for diagnosis on a machine that has no patchelf either.

(defun %file-bytes (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

(defun %uint (bytes offset size little-endian)
  (let ((value 0))
    (if little-endian
        (loop for i from (1- size) downto 0
              do (setf value (logior (ash value 8) (aref bytes (+ offset i)))))
        (loop for i from 0 below size
              do (setf value (logior (ash value 8) (aref bytes (+ offset i))))))
    value))

(defun %asciiz (bytes offset)
  (let ((end (position 0 bytes :start offset)))
    (map 'string #'code-char (subseq bytes offset end))))

(defun needed-libraries (path)
  "The sonames PATH records as DT_NEEDED -- its direct dependencies, as the dynamic
   linker will ask for them.

   Handles 32- and 64-bit little-endian ELF, which is every Linux this will meet. Anything
   else, including a file that is not an ELF at all, returns nothing rather than
   complaining: the deploy directory has assets in it too."
  (handler-case
      (let ((b (%file-bytes path)))
        (unless (and (< 64 (length b))
                     (= #x7F (aref b 0)) (= (char-code #\E) (aref b 1))
                     (= (char-code #\L) (aref b 2)) (= (char-code #\F) (aref b 3)))
          (return-from needed-libraries '()))
        (let* ((64bit? (= 2 (aref b 4)))
               (le (= 1 (aref b 5)))
               (word (if 64bit? 8 4))
               (shoff (%uint b (if 64bit? #x28 #x20) word le))
               (shentsize (%uint b (if 64bit? #x3A #x2E) 2 le))
               (shnum (%uint b (if 64bit? #x3C #x30) 2 le)))
          (flet ((sh (i field)
                   ;; (offset . size) per field, by class.
                   (let* ((base (+ shoff (* i shentsize)))
                          (spec (ecase field
                                  (:type (if 64bit? '(4 . 4) '(4 . 4)))
                                  (:offset (if 64bit? '(24 . 8) '(16 . 4)))
                                  (:link (if 64bit? '(40 . 4) '(24 . 4)))
                                  (:size (if 64bit? '(32 . 8) '(20 . 4))))))
                     (%uint b (+ base (car spec)) (cdr spec) le))))
            (let ((dynamic (loop for i below shnum
                                 when (= 6 (sh i :type))   ; SHT_DYNAMIC
                                   return i)))
              (unless dynamic (return-from needed-libraries '()))
              (let ((entries (sh dynamic :offset))
                    (size (sh dynamic :size))
                    (strtab (sh (sh dynamic :link) :offset))
                    (step (if 64bit? 16 8)))
                (loop for offset from entries below (+ entries size) by step
                      for tag = (%uint b offset word le)
                      until (zerop tag)                     ; DT_NULL
                      when (= 1 tag)                        ; DT_NEEDED
                        collect (%asciiz b (+ strtab (%uint b (+ offset word) word le)))))))))
    (error () '())))

(defun library-soname (path)
  "The DT_SONAME a library answers to, which is the name its dependents ask for and is
   not always what the file is called: Deploy copies libSDL2-2.0.so.0.3200.8, and
   everything that needs it asks for libSDL2-2.0.so.0."
  (handler-case
      (let ((b (%file-bytes path)))
        (unless (and (< 64 (length b)) (= #x7F (aref b 0)) (= (char-code #\E) (aref b 1)))
          (return-from library-soname nil))
        (let* ((64bit? (= 2 (aref b 4)))
               (le (= 1 (aref b 5)))
               (word (if 64bit? 8 4))
               (shoff (%uint b (if 64bit? #x28 #x20) word le))
               (shentsize (%uint b (if 64bit? #x3A #x2E) 2 le))
               (shnum (%uint b (if 64bit? #x3C #x30) 2 le)))
          (flet ((sh (i field)
                   (let* ((base (+ shoff (* i shentsize)))
                          (spec (ecase field
                                  (:type '(4 . 4))
                                  (:offset (if 64bit? '(24 . 8) '(16 . 4)))
                                  (:link (if 64bit? '(40 . 4) '(24 . 4)))
                                  (:size (if 64bit? '(32 . 8) '(20 . 4))))))
                     (%uint b (+ base (car spec)) (cdr spec) le))))
            (let ((dynamic (loop for i below shnum when (= 6 (sh i :type)) return i)))
              (when dynamic
                (let ((entries (sh dynamic :offset))
                      (size (sh dynamic :size))
                      (strtab (sh (sh dynamic :link) :offset))
                      (step (if 64bit? 16 8)))
                  (loop for offset from entries below (+ entries size) by step
                        for tag = (%uint b offset word le)
                        until (zerop tag)
                        when (= 14 tag)             ; DT_SONAME
                          return (%asciiz b (+ strtab
                                               (%uint b (+ offset word) word le))))))))))
    (error () nil)))

(defparameter *system-libraries*
  '("ld-linux" "libc." "libm." "libdl." "libpthread." "librt." "libresolv." "libnsl."
    "libutil." "libanl."
    ;; The toolchain runtime. Bundling these is the classic way to break a program on a
    ;; machine whose own libraries are newer than the ones it arrived with.
    "libstdc++" "libgcc_s" "libgomp" "libmvec" "libatomic" "libquadmath"
    ;; Terminal handling, dragged in by fluidsynth's shell. A game has no business
    ;; shipping readline.
    "libreadline" "libtinfo" "libncurses" "libhistory"
    ;; The graphics driver. A bundled one is whoever built the binary's card.
    "libGL." "libGLX" "libGLdispatch" "libEGL" "libOpenGL" "libGLESv"
    "libdrm" "libgbm"
    ;; The display server.
    "libX11" "libxcb" "libXext" "libXcursor" "libXi." "libXrandr" "libXfixes"
    "libXrender" "libXss" "libXxf86vm" "libXau" "libXdmcp" "libxkbcommon" "libwayland"
    "libXtst" "libXinerama" "libXt." "libXmu" "libSM." "libICE."
    ;; Sound servers -- the daemon side is the host's, and versions must match it.
    "libasound" "libpulse" "libjack" "libpipewire" "libsndio"
    ;; The font stack. These arrive through SDL2_ttf, which lgame opens and this game
    ;; never uses -- it draws its own .bft fonts. Bundling them is not merely wasted
    ;; space: the host's fontconfig is loaded into the same process by the display
    ;; stack, and giving it a freetype or harfbuzz of a different vintage than it was
    ;; built against is a well-known way to produce undefined-symbol failures.
    "libfreetype" "libharfbuzz" "libfontconfig" "libgraphite2" "libbrotli"
    "libglib-2.0" "libgobject" "libgmodule" "libpcre2"
    ;; System plumbing, and anything that gets security updates.
    "libudev" "libsystemd" "libdbus" "libcap" "libselinux" "libcrypto" "libssl"
    "libz." "liblzma" "libbz2" "libzstd")
  "Prefixes of libraries that belong to the host and must never be bundled.

   The rule is the same one the whole bundle follows: ship what the game brings, never
   what the machine owns. A driver, a display server, an audio daemon's client library
   and anything that receives security updates all belong to the machine, and replacing
   them with a copy frozen at build time is how a bundle works on exactly one computer.

   Everything not listed here is a codec or a format library -- libxmp, libmpg123,
   libvorbis, libFLAC, libfreetype and their kind -- which is precisely what the game
   brings and what the host has no reason to have.")

(defun system-library-p (soname)
  (let ((name (file-namestring soname)))
    (some (lambda (prefix)
            (and (<= (length prefix) (length name))
                 (string-equal prefix name :end2 (length prefix))))
          *system-libraries*)))

(defun %search-directories ()
  "Where to look for a soname: wherever the libraries we already know about came from,
   then the usual places, which differ between distributions."
  (remove-duplicates
   (append (loop for library in (deploy:list-libraries)
                 for path = (ignore-errors (deploy:library-path library))
                 when path collect (uiop:pathname-directory-pathname path))
           (loop for dir in (uiop:split-string (or (uiop:getenv "LD_LIBRARY_PATH") "")
                                               :separator ":")
                 when (plusp (length dir))
                   collect (uiop:ensure-directory-pathname dir))
           (mapcar #'uiop:ensure-directory-pathname
                   '("/usr/lib/x86_64-linux-gnu/" "/lib/x86_64-linux-gnu/"
                     "/usr/lib64/" "/lib64/" "/usr/lib/" "/lib/" "/usr/local/lib/")))
   :test #'equal))

(defparameter *library-suffix*
  #+windows ".dll"
  #-windows ".so"
  "What a shared library is called here.")

(defun shared-objects (directory)
  "The shared libraries in DIRECTORY.

   Found by looking at whole filenames rather than by globbing *.so*, which does not
   work: Lisp splits libSDL2-2.0.so.0.3200.8 into the name libSDL2-2.0.so.0.3200 and the
   type 8, so a pattern with the type `so*' matches none of the versioned ones -- which
   is all of them."
  (remove-if-not (lambda (path)
                   (let ((name (file-namestring path)))
                     (and name (search *library-suffix* name :test #'char-equal))))
                 (directory (merge-pathnames "*.*" directory))))

(defun elf-identity (path)
  "(class . machine) from an ELF header: 2 and 62 for x86-64, 1 and 3 for i386."
  (handler-case
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((b (make-array 20 :element-type '(unsigned-byte 8))))
          (when (and (= 20 (read-sequence b in))
                     (= #x7F (aref b 0)) (= (char-code #\E) (aref b 1)))
            (cons (aref b 4) (+ (aref b 18) (* 256 (aref b 19)))))))
    (error () nil)))

(defun host-elf-identity ()
  "What this image is, taken from the running executable rather than assumed."
  (or (ignore-errors (elf-identity sb-ext:*runtime-pathname*))
      (ignore-errors (elf-identity #p"/proc/self/exe"))))

(defun %find-library (soname directories)
  "The first candidate that is actually loadable by THIS image.

   The architecture check is not paranoia. A multilib system has the same soname in
   /usr/lib and /usr/lib64 with different word sizes, and picking the wrong one is
   invisible: the loader rejects it as an incompatible ELF class, says nothing, and
   quietly falls back to the host's copy. The bundle then works perfectly on the machine
   that built it and nowhere else. That is exactly what happened here -- a 32-bit
   libSDL2 shipped for weeks inside a 64-bit bundle, doing nothing."
  (let ((host (host-elf-identity)))
    (loop for dir in directories
          for candidate = (probe-file (merge-pathnames soname dir))
          when (and candidate
                    (or (null host) (equal host (elf-identity candidate))))
            return candidate)))

#+unix
(deploy:define-hook (:deploy transitive-libraries -10) (directory)
  "Copy what the bundled libraries themselves need.

   Priority -10 so this runs after Deploy's own FOREIGN-LIBRARIES hook has put the
   directly-known libraries in place -- hooks are sorted highest first, and that one is
   at the default zero.

   Iterated to a fixpoint, because a dependency has dependencies: SDL2_mixer wants
   libxmp, and libxmp may want something else again."
  (let ((directories (%search-directories))
        (copied '())
        ;; Sonames already looked for and not found. Kept so the loop does not ask for
        ;; the same missing library on every pass and never terminate.
        (missing '()))
    (flet ((provided ()
             ;; What the bundle already answers to, by SONAME rather than by filename.
             ;; Deploy copies libSDL2 as libSDL2-2.0.so.0.3200.8 while everything asks
             ;; for libSDL2-2.0.so.0; matching on filename alone would copy the same
             ;; library in a second time under its other name, and then two SDL2s would
             ;; be loaded at once, each with its own state.
             (loop for file in (shared-objects directory)
                   for soname = (library-soname file)
                   when soname collect soname))
           (wanted-by (files have)
             (let ((names '()))
               (dolist (file files names)
                 (dolist (soname (needed-libraries file))
                   (unless (or (system-library-p soname)
                               (member soname names :test #'string=)
                               (member soname missing :test #'string=)
                               (member soname have :test #'string=))
                     (push soname names)))))))
      (loop for pending = (wanted-by (shared-objects directory) (provided))
            while pending
            do (dolist (soname pending)
                 (let ((source (%find-library soname directories)))
                   (cond
                     (source
                      (deploy:status 1 "Bundling dependency ~a" soname)
                      (deploy:copy-file source (merge-pathnames soname directory))
                      (push soname copied))
                     (t
                      ;; Said loudly, because this is precisely the failure the hook
                      ;; exists to prevent and it will not show up until the bundle is
                      ;; run on some other machine.
                      (deploy:status 0 "MISSING: ~a is needed and was not found. The ~
                                        bundle will not run where it is absent." soname)
                      (push soname missing)))))))
    (when copied
      (deploy:status 0 "Bundled ~d transitive librar~:@p." (length copied)))
    (when missing
      (deploy:status 0 "~d dependenc~:@p could not be found: ~{~a~^, ~}"
                     (length missing) missing))))

#+unix
(deploy:define-hook (:deploy verify-architecture -30) (directory)
  "Every bundled library must be loadable by this image, and replace it if not.

   Runs last, after everything else has put files in, because the point is to check the
   result rather than any one hook's contribution -- Deploy's own copy of libSDL2 was the
   32-bit one, and no amount of care in the hooks I wrote would have caught that.

   A wrong-architecture library is the worst kind of packaging bug: the loader refuses it
   without a word and uses the host's copy instead, so the bundle passes every test on the
   machine that built it."
  (let ((host (host-elf-identity))
        (wrong '()))
    (when host
      (dolist (file (shared-objects directory))
        (let ((id (elf-identity file)))
          (when (and id (not (equal id host)))
            (push file wrong))))
      (dolist (file wrong)
        (let* ((soname (or (library-soname file) (file-namestring file)))
               (right (%find-library soname (%search-directories))))
          (cond
            (right
             (deploy:status 1 "Replacing ~a: it was built for another architecture."
                            (file-namestring file))
             (deploy:copy-file right file))
            (t
             (deploy:status 0 "WRONG ARCHITECTURE and no replacement found: ~a. ~
                               The bundle will silently use the host's copy."
                            (file-namestring file))))))
      (unless wrong
        (deploy:status 1 "All bundled libraries match this image's architecture.")))))

;;; ---------------------------------------------------------------------------
;;; Making the bundled libraries findable at runtime
;;;
;;; Copying libxmp.so.4 next to libSDL2_mixer is not enough, which is unintuitive and
;;; cost a build to discover. When the loader opens libSDL2_mixer it resolves that
;;; library's own DT_NEEDED entries by the normal rules -- DT_RUNPATH, LD_LIBRARY_PATH,
;;; the ld.so cache, then the system directories. The directory the .so happens to sit in
;;; is NOT one of them. Deploy gets away with an absolute path for the libraries IT opens;
;;; their dependencies get no such help.
;;;
;;; The usual answers are to stamp DT_RUNPATH=$ORIGIN onto every bundled library, which
;;; needs patchelf at build time, or to launch through a wrapper script that sets
;;; LD_LIBRARY_PATH, which means the executable is no longer the thing you run.
;;;
;;; This takes the third road: open them all ourselves, by absolute path, before anything
;;; asks for them. The loader keys already-loaded objects by SONAME, so once
;;; bin/libxmp.so.4 is open, libSDL2_mixer's request for "libxmp.so.4" is answered by it
;;; rather than by a filesystem search. No external tool, no wrapper, and the executable
;;; stays the thing you run.

;;; Everything from here to the Windows section is about the ELF loader's search rules and
;;; is read only on Unix. Not merely inapplicable elsewhere: SB-POSIX:SYMLINK and
;;; SB-POSIX:SETENV do not exist in a Windows SBCL, so an unguarded reference to them is a
;;; reader error and the file will not compile at all.
;;;
;;; None of it is needed there anyway. Windows searches the directory containing the
;;; executable before anything else, which is the whole problem these hooks exist to solve
;;; -- and it has no soname concept, so a DLL is found under the name it has.

#+unix
(deploy:define-hook (:deploy soname-links -20) (directory)
  "Give every bundled library a name matching its SONAME.

   Deploy copies libSDL2 as libSDL2-2.0.so.0.3200.8, but everything that needs it asks
   the loader for libSDL2-2.0.so.0, and a search -- however it is directed -- looks for
   that name. Without this the bundled SDL2 is invisible to the bundled SDL2_mixer, which
   then silently binds to the host's copy instead.

   A symlink rather than a second copy, and that matters: the loader recognises a file it
   has already mapped by device and inode, so a link resolves to the one object while a
   duplicate file would load a second, independent SDL2 with its own state."
  (dolist (file (shared-objects directory))
    (let ((soname (library-soname file)))
      (when (and soname (not (string= soname (file-namestring file))))
        (let ((link (merge-pathnames soname directory)))
          (unless (probe-file link)
            (handler-case
                (sb-posix:symlink (file-namestring file)
                                  (uiop:native-namestring link))
              (error (e)
                ;; A filesystem without symlinks, or a name clash. Copying is worse but
                ;; better than the library being unfindable.
                (deploy:status 1 "Could not link ~a (~a); copying instead." soname e)
                (deploy:copy-file file link)))))))))

;;; ---------------------------------------------------------------------------
;;; Windows
;;;
;;; Much less to do, because Windows searches the directory containing the executable
;;; before anything else. Deploy puts the DLLs it knows about there and they are found:
;;; no search path to arrange, no re-exec, no sonames, and no separate name for a library
;;; to answer to.
;;;
;;; What is still needed is the DLLs nothing in Lisp ever names -- SDL2_mixer's codecs and
;;; the like, the same gap as on Unix. There the answer was to read the dependencies out
;;; of the ELF headers; here it is simpler to take the whole set, because the SDL project
;;; ships its runtime DLLs together in one directory and they are exactly the ones we
;;; want. So the build copies that directory wholesale.

;;; Deploy declares libwinpthread on every SBCL/Windows build and then insists on finding
;;; it, stopping the deploy with "does not have a known shared library file path".
;;;
;;; This SBCL does not use it. The MSI ships sbcl.exe, sbcl.core and contrib and no
;;; libwinpthread-1.dll at all, so the threading runtime is linked in statically -- and
;;; the library is correspondingly never opened, which is precisely why it has no path to
;;; report. Deploy is being careful on behalf of MinGW builds that do link it dynamically.
;;;
;;; Marked rather than supplied: shipping a libwinpthread-1.dll picked up from somewhere
;;; else would put a second threading runtime beside a binary that already has one.
;;;
;;; FIND-SYMBOL rather than naming DEPLOY::LIBWINPTHREAD outright, so that a Deploy which
;;; no longer defines it does not turn this into a read error.
#+windows
(let ((name (find-symbol "LIBWINPTHREAD" '#:org.shirakumo.deploy)))
  (when name
    (setf (deploy:library-dont-deploy-p (deploy:ensure-library name)) T)))

#+windows
(defparameter *windows-dll-directory* #p"win32/dll/"
  "Where the Windows DLLs to ship live, relative to the system's own directory.
   Populated by win32/setup.sh from the SDL project's runtime archives.")

#+windows
(deploy:define-hook (:deploy windows-dlls -10) (directory)
  "Copy the shipped DLL set beside the executable."
  (let ((source (merge-pathnames *windows-dll-directory*
                                 (asdf:system-source-directory "descendant"))))
    (cond
      ((probe-file source)
       (let ((n 0))
         (dolist (dll (shared-objects source))
           (deploy:copy-file dll (merge-pathnames (file-namestring dll) directory))
           (incf n))
         (deploy:status 1 "Copied ~d DLL~:p from ~a" n source)))
      (t
       ;; Worth stopping for. A Windows bundle without these starts on the build machine,
       ;; where the DLLs are on PATH, and on no other.
       (error "No DLLs at ~a. Run win32/setup.sh before building for Windows."
              source)))))

;;; The binary narrates its own boot -- build time, checksum, every foreign library it
;;; reloads -- to stderr, every launch. That cannot be turned off from here, and it is
;;; worth writing down so nobody tries again: DEPLOY:WARMLY-BOOT assigns
;;; DEPLOY:*STATUS-OUTPUT* unconditionally before it prints, so a value set at build time
;;; is overwritten, and the report is emitted before any hook of ours can run.
;;;
;;; The one switch that silences it is the :DEPLOY-CONSOLE feature, and it is the wrong
;;; switch: it also decides that the Windows build is a console application, which would
;;; give a windowed game a terminal beside it. Not a trade worth making for output that
;;; goes to stderr, appears once, and is invisible unless the game was started from a
;;; terminal in the first place.

;;; Libraries belonging to the host, not to us.
;;;
;;; GL and GLX come from the graphics driver; X11 and Wayland from the display server.
;;; Deploying any of them makes the binary work on exactly one machine -- the one it was
;;; built on -- which is the opposite of the point.

(macrolet ((dont-deploy (&rest names)
             `(progn
                ,@(loop for name in names
                        collect `(when (find-symbol ,(string name) "CL-OPENGL-BINDINGS")
                                   (deploy:define-library
                                       ,(intern (string name) "CL-OPENGL-BINDINGS")
                                     :dont-deploy T))))))
  (dont-deploy "OPENGL"))

;;; Deploy reads this list to decide what never to bundle; adding to it is the supported
;;; way to say "this belongs to the operating system". The GL and X11 names are here
;;; rather than in DEFINE-LIBRARY forms because they are opened by several different
;;; bindings and we want the exemption whichever one got there first.
(set 'cl-user::*foreign-system-libraries*
     (union (when (boundp 'cl-user::*foreign-system-libraries*)
              (symbol-value 'cl-user::*foreign-system-libraries*))
            '(opengl gl glx egl x11 xext wayland-client drm gbm)))

;;; ---------------------------------------------------------------------------
;;; Startup

(defparameter *reexec-marker* "DESCENDANT_LIBRARY_PATH_SET"
  "Set on ourselves before re-execing, so the second run knows not to do it again.")

#+unix
(deploy:define-hook (:boot library-path #.most-positive-fixnum) ()
  "Fix the library path before anything is loaded.

   The priority is the whole point, and it took two tries to get right. Deploy's own
   FOREIGN-LIBRARIES boot hook is registered at (- MOST-POSITIVE-FIXNUM 10) precisely so
   that it runs before everything else, so a priority of 10 -- or any ordinary number --
   is far too late: the libraries are already being opened, the missing dependency has
   already failed, and the process has already given up. The symptom was a bundle that
   could not find libxmp however many copies of libxmp were sitting next to it.

   MOST-POSITIVE-FIXNUM is ten more than Deploy's, which is the only way to get in front
   of it. Read at compile time so it is a constant in the image rather than a symbol
   looked up in whatever package happens to be current."
  (%ensure-library-path)
  (%prefer-bundled-sdl))

#+unix
(defun %prefer-bundled-sdl ()
  "Point SDL_DYNAMIC_API at our own SDL2.

   SDL2 has a mechanism for exactly this problem: whatever copy gets loaded first checks
   SDL_DYNAMIC_API, and if it names a shared library, forwards its entire API to that one
   instead. It exists so a distributor can substitute a fixed or newer SDL underneath a
   program that shipped its own -- Steam does this -- and it works even when the loader
   has already decided on some other copy.

   Which makes it the answer to the one library the search rules will not reliably hand
   us. Everything else in the bundle is found by path; SDL2 is found by SDL2."
  (let ((sdl (merge-pathnames "libSDL2-2.0.so.0" (deploy:runtime-directory))))
    (when (and (probe-file sdl) (not (uiop:getenv "SDL_DYNAMIC_API")))
      (ignore-errors
       (sb-posix:setenv "SDL_DYNAMIC_API" (uiop:native-namestring sdl) 1)))))

#+unix
(defun %ensure-library-path ()
  "Put the runtime directory on LD_LIBRARY_PATH, re-execing once to make it take.

   This is the part that actually makes a bundle self-contained, and it is not optional.
   When the loader opens libSDL2_mixer it resolves that library's own DT_NEEDED entries
   -- libxmp, libmpg123, libvorbisfile -- by the ordinary rules: DT_RUNPATH,
   LD_LIBRARY_PATH, the ld.so cache, the system directories. The directory the .so was
   loaded FROM is not among them. So copying libxmp next to it changes nothing, and the
   bundle quietly runs on the host's libraries until it meets a host that lacks one.

   Measured, not assumed: with the bundle on LD_LIBRARY_PATH every codec resolves inside
   bin/; without it, every one of them resolved to /usr/lib64 even though the bundled
   copies were sitting right beside the library asking for them.

   The alternative is stamping DT_RUNPATH=$ORIGIN on each library with patchelf, which is
   tidier -- no environment, no second exec -- at the cost of requiring patchelf wherever
   the build runs. This way needs nothing but the C library, and the executable stays the
   thing you run rather than a script that runs it.

   Returns without doing anything when not deployed, when already done, or on any
   platform where this is not how libraries are found."
  #+(and unix (not darwin))
  (when (and (deploy:deployed-p)
             (not (uiop:getenv *reexec-marker*)))
    (let* ((dir (uiop:native-namestring (deploy:runtime-directory)))
           (existing (uiop:getenv "LD_LIBRARY_PATH"))
           (path (if (and existing (plusp (length existing)))
                     (format nil "~a:~a" dir existing)
                     dir))
           (argv (uiop:command-line-arguments))
           ;; Not UIOP:ARGV0, which is NIL in a Deploy image. SB-EXT:*RUNTIME-PATHNAME*
           ;; is the executable's own path in a dumped one.
           (self (uiop:native-namestring
                  (or (ignore-errors sb-ext:*runtime-pathname*)
                      (merge-pathnames "descendant" (deploy:runtime-directory))))))
      (handler-case
          (progn
            (sb-posix:setenv "LD_LIBRARY_PATH" path 1)
            (sb-posix:setenv *reexec-marker* "1" 1)
            ;; execv, so there is one process rather than a parent waiting on a child.
            (cffi:with-foreign-object (array :pointer (+ 2 (length argv)))
              (let ((strings (list* self argv)))
                (loop for s in strings
                      for i from 0
                      do (setf (cffi:mem-aref array :pointer i)
                               (cffi:foreign-string-alloc s)))
                (setf (cffi:mem-aref array :pointer (length strings))
                      (cffi:null-pointer)))
              (cffi:foreign-funcall "execv" :string self :pointer array :int)))
        (error (e)
          ;; execv only returns on failure, and a failure here is not fatal: the game
          ;; will run, and will use whatever libraries the host happens to provide.
          (format *error-output*
                  "~&Could not set the library path (~a); continuing with the ~
                   system's libraries.~%" e))))))

(defun toplevel ()
  "The binary's entry point.

   Two things differ from a REPL launch. Assets are found beside the executable rather
   than in the source tree -- see PATHS:APP-ROOT -- and an unhandled error has nowhere to
   print a backtrace to, so it is reported and the process exits rather than dropping into
   a debugger that nobody is looking at."
  (setf paths:*deployed* t)
  (handler-case
      (progn (main) (uiop:quit 0))
    (error (e)
      (format *error-output* "~&The Descendant stopped: ~a~%" e)
      (finish-output *error-output*)
      (uiop:quit 1))))
