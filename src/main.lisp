(in-package #:com.thejach.descendant)

;;;; Entry point. Ports gam_main.c's gameLoop/updateLoop pair onto lgame.
;;;;
;;;; The original ran logic at a fixed 0.016 s step, busy-waiting for 15 ms per frame,
;;;; and presented every other tick in its default 30 FPS mode. We keep the fixed step
;;;; and pace at exactly 62.5 Hz so wall time matches simulated time (see level.lisp).

(defparameter *fullscreen?* nil
  "The original ran in a console window. We open windowed at the native 960x720 and let
   F11 toggle SDL's borderless-desktop scaling. Never launch fullscreen.

   F11 rather than F because F belongs to the FPS readout: the controls screen says
   `SHOW FPS:    F KEY` and HUD_update toggles it on key-up. Fullscreen is ours to place,
   so it goes somewhere the original never used.")

(defparameter *start-level* :intro
  "DSC_LEVEL_INTRO, the original's d_initialLevel.")

(defvar *screen* nil)
(defvar *renderer* nil)

(defun apply-fullscreen (on?)
  (setf *fullscreen?* (and on? t))
  (when lgame:*screen*
    (lgame::sdl-set-window-fullscreen
     lgame:*screen*
     (if *fullscreen?* lgame::+sdl-window-fullscreen-desktop+ 0)))
  *fullscreen?*)

(defun toggle-fullscreen ()
  "F11, and the options screen's own switch. Both go through the setting so the two
   cannot disagree about what the window is doing."
  (setf (settings:value :fullscreen) (not (settings:value :fullscreen)))
  (apply-fullscreen (settings:value :fullscreen)))

(defun install-setting-hooks ()
  "Teach SETTINGS how to act on the ones that need something told. The options screen asks
   for a change to be applied without knowing who does it; this is who."
  (settings:on-change :fullscreen #'apply-fullscreen)
  (settings:on-change :music-volume
                      (lambda (v) (audio:set-music-volume (settings:volume-fraction v))))
  (settings:on-change :effects-volume
                      (lambda (v) (audio:set-effects-volume (settings:volume-fraction v))))
  (values))

(defun apply-settings ()
  "Push everything at whatever owns it. Called at startup, once the window exists."
  (install-setting-hooks)
  (settings:apply-all))

(defun %letter-for (scancode)
  "SDL's scancodes for A-Z are contiguous, so this is arithmetic rather than a table."
  (let ((offset (- scancode lgame::+sdl-scancode-a+)))
    (when (<= 0 offset 25)
      (code-char (+ (char-code #\a) offset)))))

(defun handle-global-event (event)
  "Events the whole game responds to regardless of level. Returns T if consumed."
  (let ((type (lgame.event:event-type event)))
    ;; Cheat codes watch every letter and consume nothing, so the same keypress still
    ;; reaches whatever the current level does with it.
    (when (= type lgame::+sdl-keydown+)
      (let ((letter (%letter-for (lgame.event:key-scancode event))))
        (when letter (cheats:feed letter))))
    (cond
      ((= type lgame::+sdl-quit+) (level:request-quit) t)
      ((and (= type lgame::+sdl-keydown+)
            (= (lgame.event:key-scancode event) lgame::+sdl-scancode-f11+))
       (toggle-fullscreen) t)
      ;; F10 cycles the speed preset. Pair it with F, the FPS readout: the number really
      ;; does change between the two, which is the quickest way to see that they differ.
      ((and (= type lgame::+sdl-keydown+)
            (= (lgame.event:key-scancode event) lgame::+sdl-scancode-f10+))
       (state:cycle-speed-preset) t)
      ;; F9 unpaces the loop. Undocumented and deliberately so: it makes the game
      ;; unplayable by design. Pair it with F.
      ((and (= type lgame::+sdl-keydown+)
            (= (lgame.event:key-scancode event) lgame::+sdl-scancode-f9+))
       (toggle-unlimited) t)
      (t nil))))

;;; ---------------------------------------------------------------------------
;;; Timing
;;;
;;; One logic step per iteration, paced to 62.5 Hz, exactly as the original's updateLoop
;;; ran. That makes the frame rate and the simulation rate the same number, which is
;;; usually the sort of coupling worth removing -- and here is not.
;;;
;;; It was removed, briefly, in favour of an accumulator that spent real time in fixed
;;; steps so the loop could run free. The point of that was to allow vsync and an
;;; unlimited frame rate without the game speeding up. But everything is drawn on a
;;; 240x120 cell grid at integer positions: there is nothing to interpolate, so presenting
;;; above the simulation rate repeats a frame rather than showing a new one. It bought no
;;; smoothness at all, and it cost the one thing a fixed step is for -- every tick
;;; identical -- because a stalled frame would then run several steps at once.
;;;
;;; So the loop is back to what it was, and the question it was meant to answer is
;;; answered by F9 instead: stop sleeping and see how fast the machine goes. The
;;; simulation runs fast too, which is fine, because that is a measurement and not a way
;;; to play.

(defvar *unlimited?* nil
  "F9: stop pacing the loop. The game then runs as fast as the machine allows -- speed
   and all -- which is not playable and is not meant to be. It is a ruler: with the FPS
   readout up, the number says how much headroom there is over the 62.5 the game wants,
   which is the before-measurement for the faster renderer.")

(defun toggle-unlimited ()
  (setf *unlimited?* (not *unlimited?*)))

(defun consume-touch (event)
  "On Android, turn touches into key events and say so. Always NIL elsewhere.

   A function rather than a reader conditional inside GAME-TICK, so the loop below reads
   the same on every platform and there is one place to look for what touch does."
  (declare (ignorable event))
  #+android (com.thejach.descendant.touch:translate event)
  #-android nil)

(defun game-tick ()
  (lgame.event:do-event (event)
    ;; Touch first: it consumes finger events and the back button, and pushes key events
    ;; in their place. Everything it does not consume -- including a real keyboard, and
    ;; the keys it just pushed -- carries on to the handlers below untouched.
    (unless (consume-touch event)
      (unless (handle-global-event event)
        (level:handle-event level:*current* event))))

  ;; After the events, before the level ticks: the stick turns its deflection into key
  ;; presses here, and they are picked up by the next frame's poll. One frame of latency
  ;; at 62.5 Hz, for proportional control instead of on-or-off.
  #+android (com.thejach.descendant.touch:tick)

  (level:tick *screen* *renderer*)

  (level:switch-if-requested)

  (livesupport:update-repl-link)
  (lgame.time:clock-tick (unless *unlimited?* (level:logic-hz)))

  (when (eq level:*state* :quit)
    (lgame.time:clock-stop)))

(defvar *gl-context* nil
  "The GL context, when the fast renderer is running. NIL means the SDL_Renderer path.")

(defun %open-window-for (mode)
  "Build the window the chosen renderer needs.

   This is why the RENDER setting says RESTART NEEDED. The two renderers do not merely
   draw differently -- they want different windows. The fast one needs SDL_WINDOW_OPENGL
   and a context of its own; the slow one wants an SDL_Renderer, which would create and
   own a context of its own choosing. Switching in place would mean tearing down the
   window and every texture hanging off it, mid-frame, for a setting nobody changes twice."
  (ecase mode
    (:fast
     ;; Falling back rather than failing. The renderer choice is remembered in
     ;; options.ini, so a machine that cannot give us a 3.3 core context -- an old driver,
     ;; a remote X session where indirect GLX caps out below it -- would otherwise refuse
     ;; to start at all, with the only cure being to hand-edit the file the player cannot
     ;; reach because the game will not open. Whatever the reason, the slow renderer works
     ;; everywhere SDL does, so say what happened and use it.
     (handler-case
         (progn
           ;; Attributes are read when the window is created, so they go first.
           ;;
           ;; Android has no desktop GL at all -- there is no libGL to load, and asking
           ;; for a 3.3 core profile fails at SDL_CreateWindow with "Could not initialize
           ;; OpenGL / GLES library". GLES 3.0 is what the driver offers and what the ES
           ;; shader is written against; this phone reports ES 3.2, so there is headroom.
           (sdl2:gl-set-attr :context-major-version 3)
           #-android (sdl2:gl-set-attr :context-minor-version 3)
           #+android (sdl2:gl-set-attr :context-minor-version 0)
           (sdl2:gl-set-attr :context-profile-mask
                             #-android sdl2-ffi:+sdl-gl-context-profile-core+
                             #+android sdl2-ffi:+sdl-gl-context-profile-es+)
           (sdl2:gl-set-attr :doublebuffer 1)
           ;; The requested size is a formality on Android: the window is the screen, and
           ;; SDL reports the real drawable afterwards. The shader letterboxes 960x720
           ;; into whatever it turns out to be.
           (lgame.display:create-centered-window "The Descendant"
                                                 screen:+pixel-width+ screen:+pixel-height+
                                                 (logior lgame::+sdl-window-shown+
                                                         lgame::+sdl-window-opengl+
                                                         #+android
                                                         lgame::+sdl-window-fullscreen+))
           (setf *gl-context* (sdl2:gl-create-context lgame:*screen*))
           (sdl2:gl-make-current lgame:*screen* *gl-context*)

           ;; Tell cl-opengl how to find GL entry points.
           ;;
           ;; It resolves anything beyond the core 1.1 set through a proc-address
           ;; function, and its fallback on #+linux is glXGetProcAddress -- GLX, which is
           ;; X11, which Android does not have. The failure is "The alien function
           ;; glXGetProcAddress is undefined", from the first shader call, and it reads
           ;; like a missing driver rather than a missing X server.
           ;;
           ;; The hook exists for exactly this and cl-opengl's own comment names SDL as a
           ;; suitable source. Set on every platform rather than #+android: SDL knows how
           ;; to ask whichever GL is actually loaded, which is more nearly right on the
           ;; desktop too, and one code path is easier to trust than two.
           (setf cl-opengl-bindings:*gl-get-proc-address* #'sdl2:gl-get-proc-address)

           (renderer.gl:make-gl-renderer :context *gl-context*))
       (error (e)
         (format *error-output*
                 "~&The FAST renderer could not start (~a).~%Falling back to SLO.~%" e)
         (finish-output *error-output*)
         ;; The half-built window is no use to the other path: it was created with
         ;; SDL_WINDOW_OPENGL, and an SDL_Renderer wants to choose its own.
         (when *gl-context*
           (ignore-errors (sdl2:gl-delete-context *gl-context*))
           (setf *gl-context* nil))
         (when lgame:*screen*
           (ignore-errors (sdl2:destroy-window lgame:*screen*))
           (setf lgame:*screen* nil))
         (%open-window-for :slow))))
    (:slow
     (lgame.display:create-centered-window "The Descendant"
                                           screen:+pixel-width+ screen:+pixel-height+)
     (lgame.display:create-renderer)
     ;; Pixel art: never smooth it.
     (lgame::sdl-set-hint lgame::+sdl-hint-render-scale-quality+ "nearest")
     (lgame.display:set-logical-size screen:+pixel-width+ screen:+pixel-height+
                                     lgame:*renderer* nil)
     (renderer:make-renderer))))

(defun main (&key (start-level *start-level*) (mute? nil))
  (lgame:with-overlays
    (lgame:init)

    ;; Before the settings, and before anything else touches a file. On Android the assets
    ;; start out inside the APK, where OPEN cannot reach them; this copies them out once.
    ;; It needs SDL, hence its position after LGAME:INIT.
    #+android
    (let ((n (com.thejach.descendant.android:ensure-assets)))
      (when (plusp n) (format t "~&extracted ~d asset~:p from the APK~%" n)))

    ;; Settings first: they decide which window to open, and they have to be in place
    ;; before the first level loads anyway -- the menu reads difficulty from here, and the
    ;; enemy loader reads it three levels further on.
    (settings:load-settings)

    #+android
    (progn
      ;; Auto-fire is not a setting on a touchscreen. HELD? already answers yes for both
      ;; weapons when it is on, so forcing it here is the whole of "just force auto-fire"
      ;; -- no level code changes, and the options screen's switch simply has nothing
      ;; left to decide.
      (setf (settings:value :auto-fire) t)
      ;; Without this SDL treats back as "close the app" and never delivers it. The game
      ;; wants it as Escape: leave the level, leave the menu.
      (lgame::sdl-set-hint "SDL_ANDROID_TRAP_BACK_BUTTON" "1"))

    (state:set-difficulty (settings:value :difficulty))

    (setf *renderer* (%open-window-for (settings:value :renderer)))
    (sdl2:hide-cursor)

    (setf audio:*muted?* mute?)
    ;; lgame opens the audio device but leaves SDL_mixer on its default of 8 channels,
    ;; which this game exhausts within seconds of the first firefight.
    (audio:init-channels)

    (apply-settings)

    (setf *screen* (screen:make-screen)
          level:*frame* 0
          level:*state* :play
          level:*current* nil)

    (unwind-protect
         (progn
           (level:start-level start-level)
           (lgame.time:clock-start)
           (loop while (lgame.time:clock-running?)
                 do (livesupport:continuable (game-tick))))
      (quit))))

(defun quit ()
  (ignore-errors (level:shutdown))
  (when *renderer*
    (ignore-errors (renderer:destroy-renderer *renderer*))
    (setf *renderer* nil))
  ;; After the renderer, which has GL objects to delete while the context is still current.
  (when *gl-context*
    (ignore-errors (sdl2:gl-delete-context *gl-context*))
    (setf *gl-context* nil))
  (setf *screen* nil)
  (lgame:quit))

;;; ---------------------------------------------------------------------------
;;; Headless helper, used by the tests and handy at the REPL.

(defun render-level-frames (level-keyword frames &key (into nil) (mute? t))
  "Run LEVEL-KEYWORD for FRAMES logic ticks with no window, returning the renderer.
   If INTO is a directory pathname, dumps a PPM per presented frame."
  (let ((audio:*muted?* mute?)
        (screen (screen:make-screen))
        (renderer (renderer:make-renderer))
        (level:*frame* 0)
        (level:*state* :play)
        (level:*current* nil))
    (unwind-protect
         (progn
           (level:start-level level-keyword)
           (dotimes (i frames renderer)
             (level:update-level level:*current*)
             (when (level:present-this-frame?)
               (renderer:ensure-palette renderer (level:level-colormap level:*current*))
               (level:render-level level:*current* screen)
               (screen:composite screen)
               (renderer:rasterize renderer screen)
               (when into
                 (renderer:save-ppm renderer
                                    (merge-pathnames (format nil "frame~4,'0d.ppm" i)
                                                     into))))
             (incf level:*frame*)
             (level:switch-if-requested)))
      (level:shutdown))))
