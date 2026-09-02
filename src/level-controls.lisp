(in-package #:com.thejach.descendant.level.controls)

;;;; Port of origRef/GameLevels/dsc_level_controls.c.
;;;;
;;;; A static reference card, not a rebinding screen -- the original lists the six
;;;; bindings as fixed strings and never edits them. It borrows the credits theme and
;;;; config, which is why everything here reads `credits.*` keys.
;;;;
;;;; A 30-tick grace period ignores the key that got you here, so the ESC or ENTER
;;;; press that opened the screen cannot immediately dismiss it.

(defconstant +exit-delta+ 30 "CONTROLS_EXIT_DELTA")
(defconstant +text-x+ 19 "The left margin the original hardcodes")
(defconstant +row-step+ 10)
(defconstant +music-track-delta+ 10800)

(defconstant +z-star-field+ 0)
(defconstant +z-background+ 1)
(defconstant +z-text+ 6 "RDR_Z_SEVEN")
(defconstant +z-banner+ 9)

(defparameter *font-attr-pair* 112
  "CONTROLS_FONT_ATTR = GAM_FONT_ATTR(112, 0, 0, 0): solid blocks, opaque background.")

(defparameter *lines*
  '("MOVEMENT:    ARROW KEYS"
    "FIRE BULLET: X KEY"
    "FIRE BOMB:   Z KEY"
    "PAUSE GAME:  P KEY"
    "SHOW FPS:    F KEY"
    "QUIT:        ESCAPE KEY")
  "Verbatim from CONTROLS_loadLevel. Uppercase because hud_06 has nothing else.")

(defclass controls (level:level)
  ((theme :accessor controls-theme :initform nil)
   (background :accessor controls-background :initform nil)
   (banner :accessor controls-banner :initform nil)
   (star-field :accessor controls-star-field :initform nil)
   (lines :accessor controls-lines :initform '())
   (music :accessor controls-music :initform nil)
   (frame :accessor controls-frame :initform 0))
  (:default-initargs :name "controls"))

(level:register-level :controls 'controls)

(defmethod level:load-level ((self controls))
  (let* ((cfg (config:read-config (paths:config-path "level_credits.cfg")))
         (th (theme:read-theme (paths:theme-path "credits.thm")))
         (hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft")))
         (attr (text:font-attr :pair *font-attr-pair*)))
    (setf (controls-theme self) th
          (controls-background self)
          (theme:find-sprite th (config:config-text cfg "credits.movie_still"
                                                    "credits_bg"))
          (controls-banner self)
          (theme:find-sprite th (config:config-text cfg "credits.banner" "DSC_logo"))
          ;; Two entries totalling 100%, so unlike the intro's field nothing here is
          ;; transparent -- the background above it does the occluding instead.
          (controls-star-field self)
          (field:make-field screen:+cols+ screen:+rows+
                            (list (field:make-field-entry (char-code #\.) 2 8)
                                  (field:make-field-entry (char-code #\Space) 2 92)))
          (controls-lines self)
          (mapcar (lambda (s)
                    (text:check-text-coverage hud6 s :context "controls")
                    (text:text-sprite hud6 s attr))
                  *lines*))
    (let ((tracks (config:config-list cfg "credits.music_tracks")))
      (when tracks
        (setf (controls-music self)
              (audio:load-sound (paths:sound-path (first tracks)) :kind :music))))
    t))

(defmethod level:init-level ((self controls))
  (setf (controls-frame self) 0)
  (audio:play-music (controls-music self))
  t)

(defmethod level:level-colormap ((self controls))
  (theme:theme-colormap (controls-theme self)))

(defmethod level:update-level ((self controls))
  (incf (controls-frame self))
  t)

(defmethod level:handle-event ((self controls) event)
  "Dismiss on ESC, SPACE or ENTER, but only once the grace period has elapsed."
  (when (and (>= (controls-frame self) +exit-delta+)
             (= (lgame.event:event-type event) lgame::+sdl-keyup+))
    (let ((key (lgame.event:key-scancode event)))
      (when (or (= key lgame::+sdl-scancode-escape+)
                (= key lgame::+sdl-scancode-space+)
                (= key lgame::+sdl-scancode-return+))
        (level:request-level :menu)
        t))))

(defmethod level:render-level ((self controls) screen)
  (screen:enqueue screen (controls-star-field self) 0 screen:+rows+ +z-star-field+)
  (screen:enqueue screen (controls-background self) 0 screen:+rows+ +z-background+)
  (let* ((banner (controls-banner self))
         (banner-height (theme:sprite-height banner)))
    (screen:enqueue screen banner
                    (ash (- screen:+cols+ (theme:sprite-width banner)) -1)
                    (- screen:+rows+ 3) +z-banner+)
    ;; Rows hang below the banner: rows - banner_height - 10n, for n = 1..6.
    (loop for sprite in (controls-lines self)
          for n from 1
          do (screen:enqueue screen sprite +text-x+
                             (- screen:+rows+ banner-height (* +row-step+ n))
                             +z-text+)))
  t)

(defmethod level:unload-level ((self controls))
  (audio:stop-all)
  (audio:free-sound (controls-music self))
  (setf (controls-music self) nil
        (controls-theme self) nil)
  t)
