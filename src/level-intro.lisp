(in-package #:com.thejach.descendant.level.intro)

;;;; Port of origRef/GameLevels/dsc_level_intro.c.
;;;;
;;;; Three modes:
;;;;   :movie   play Spla-shit's 52 frames forward, firing two sound cues on the way
;;;;   :banner  scroll the credit stack up from below while the last few movie frames
;;;;            oscillate back and forth to keep the wreck flickering
;;;;   :still   hold, still oscillating, until the timeout or a key press -> menu
;;;;
;;;; The many `//### Magic!` offsets in the original are reproduced as named constants
;;;; below so the layout comes out identical.

(defconstant +end-delta+ 1400 "INTRO_END_DELTA: ticks to hold in :still before the menu.")
(defconstant +start-pos-y+ -4 "Where the credit stack begins, below the screen.")
(defconstant +banner-stop-margin+ 3 "Scrolling stops once the banner is rows-3 up.")

;;; Gaps between the credit-stack elements: each is the PREVIOUS sprite's height plus
;;; a hand-tuned pad (8, 8, 10, 10 in INTRO_initLevel).
(defconstant +pad-after-logo+ 8)
(defconstant +pad-after-and+ 8)
(defconstant +pad-after-hlab+ 10)
(defconstant +pad-after-presents+ 10)

;;; Z-layers, from the RenderZOrder enum: RDR_Z_ONE, RDR_Z_NINE, RDR_Z_TEN.
(defconstant +z-star-field+ 0)
(defconstant +z-movie+ 8)
(defconstant +z-credits+ 9)

(defclass intro (level:level)
  ((theme :accessor intro-theme)
   (config :accessor intro-config)
   (mode :accessor intro-mode :initform :movie)
   ;; sprites
   (star-field :accessor intro-star-field)
   (movie :accessor intro-movie)
   (logo-dp :accessor intro-logo-dp)
   (and-text :accessor intro-and-text)
   (logo-hlab :accessor intro-logo-hlab)
   (presents-text :accessor intro-presents-text)
   (banner :accessor intro-banner)
   ;; layout: element -> (x . y), y measured from the bottom
   (positions :accessor intro-positions :initform (make-hash-table :test #'eq))
   (gaps :accessor intro-gaps :initform (make-hash-table :test #'eq))
   ;; animation
   (movie-frame :accessor intro-movie-frame :initform 0)
   (movie-delta :accessor intro-movie-delta :initform 1)
   (min-movie-frame :accessor intro-min-movie-frame :initform 0)
   (max-movie-frame :accessor intro-max-movie-frame :initform 0)
   (anim-delta :accessor intro-anim-delta :initform 0.15)
   (anim-elapsed :accessor intro-anim-elapsed :initform 0.0)
   (move-delta :accessor intro-move-delta :initform 0.5)
   (move-pos :accessor intro-move-pos :initform (float +start-pos-y+))
   (start-frame :accessor intro-start-frame :initform 0)
   (fire-frame :accessor intro-fire-frame :initform 14)
   (crash-frame :accessor intro-crash-frame :initform 37)
   ;; audio
   (music :accessor intro-music :initform nil)
   (sound-fire :accessor intro-sound-fire :initform nil)
   (sound-crash :accessor intro-sound-crash :initform nil))
  (:default-initargs :name "intro"))

(level:register-level :intro 'intro)

(defun %centered-x (sprite)
  (ash (- screen:+cols+ (theme:sprite-width sprite)) -1))

(defmethod level:load-level ((self intro))
  (let* ((cfg (config:read-config (paths:config-path "level_intro.cfg")))
         (th (theme:read-theme (paths:theme-path "intro.thm")))
         (hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft"))))
    (setf (intro-config self) cfg
          (intro-theme self) th)

    (flet ((sprite (key)
             (let* ((name (config:config-text cfg key))
                    (s (and name (theme:find-sprite th name))))
               (unless s
                 (error "intro: no sprite ~s (from ~a) in intro.thm" name key))
               s)))
      (setf (intro-movie self) (sprite "intro.splash_movie")
            (intro-logo-dp self) (sprite "intro.logo_dp")
            (intro-logo-hlab self) (sprite "intro.logo_hlab")
            (intro-banner self) (sprite "intro.banner")))

    ;; hud_06 is uppercase-only, which is exactly why these strings are uppercase.
    (text:check-text-coverage hud6 "AND" :context "intro")
    (text:check-text-coverage hud6 "PRESENTS" :context "intro")
    (setf (intro-and-text self) (text:text-sprite hud6 "AND")
          (intro-presents-text self) (text:text-sprite hud6 "PRESENTS")
          (intro-star-field self) (field:make-star-field screen:+cols+ screen:+rows+))

    (setf (intro-anim-delta self) (config:config-float cfg "intro.splash_anim_delta" 0.15)
          (intro-move-delta self) (config:config-float cfg "intro.credits_move_delta" 0.5)
          (intro-fire-frame self) (config:config-int cfg "intro.frame_fire" 14)
          (intro-crash-frame self) (config:config-int cfg "intro.frame_crash" 37))

    (let ((volume (config:config-float cfg "intro.sound_volume" 0.5)))
      (audio:set-music-volume volume)
      (audio:set-effects-volume volume))
    (flet ((sound (key)
             (let ((name (config:config-text cfg key)))
               (and name (audio:load-sound (paths:sound-path name) :kind :chunk)))))
      (setf (intro-music self) (sound "intro.sound_bg_music")
            (intro-sound-fire self) (sound "intro.sound_fire")
            (intro-sound-crash self) (sound "intro.sound_crash")))
    t))

(defmethod level:init-level ((self intro))
  (let ((pos (intro-positions self))
        (gaps (intro-gaps self)))
    (clrhash pos)
    (clrhash gaps)
    (setf (gethash :star-field pos) (cons 0 screen:+rows+)
          (gethash :movie pos) (cons 0 screen:+rows+))
    ;; The credit stack, built downward from -4 exactly as INTRO_initLevel does: each
    ;; gap is the previous sprite's height plus its pad.
    (let ((y +start-pos-y+))
      (setf (gethash :logo-dp pos) (cons (%centered-x (intro-logo-dp self)) y))
      (flet ((stack (key sprite gap)
               (setf (gethash key gaps) gap)
               (decf y gap)
               (setf (gethash key pos) (cons (%centered-x sprite) y))))
        (stack :and (intro-and-text self)
               (+ (theme:sprite-height (intro-logo-dp self)) +pad-after-logo+))
        (stack :hlab (intro-logo-hlab self)
               (+ (theme:sprite-height (intro-and-text self)) +pad-after-and+))
        (stack :presents (intro-presents-text self)
               (+ (theme:sprite-height (intro-logo-hlab self)) +pad-after-hlab+))
        (stack :banner (intro-banner self)
               (+ (theme:sprite-height (intro-presents-text self))
                  +pad-after-presents+)))))

  (setf (intro-mode self) :movie
        (intro-movie-frame self) 0
        (intro-movie-delta self) 1
        (intro-max-movie-frame self) (1- (theme:sprite-frames (intro-movie self)))
        (intro-min-movie-frame self) (- (theme:sprite-frames (intro-movie self)) 3)
        (intro-anim-elapsed self) 0.0
        (intro-move-pos self) (float +start-pos-y+)
        (intro-start-frame self) 0)
  (audio:play (intro-music self))
  t)

(defun %oscillate-movie (self)
  "In :banner and :still the last three frames ping-pong, so the wreck keeps flickering."
  (incf (intro-movie-frame self) (intro-movie-delta self))
  (cond
    ((> (intro-movie-frame self) (intro-max-movie-frame self))
     (setf (intro-movie-delta self) -1
           (intro-movie-frame self) (1- (intro-max-movie-frame self))))
    ((< (intro-movie-frame self) (intro-min-movie-frame self))
     (setf (intro-movie-delta self) 1
           (intro-movie-frame self) (1+ (intro-min-movie-frame self))))))

(defun %advance-credits (self)
  (let ((pos (intro-positions self))
        (gaps (intro-gaps self)))
    (incf (intro-move-pos self) (intro-move-delta self))
    (let ((y (truncate (intro-move-pos self))))
      (setf (cdr (gethash :logo-dp pos)) y)
      (dolist (key '(:and :hlab :presents :banner))
        (decf y (gethash key gaps))
        (setf (cdr (gethash key pos)) y)))))

(defmethod level:update-level ((self intro))
  (ecase (intro-mode self)
    (:movie
     (incf (intro-anim-elapsed self) level:+time-step+)
     (when (>= (intro-anim-elapsed self) (intro-anim-delta self))
       (incf (intro-movie-frame self))
       (cond ((= (intro-movie-frame self) (intro-fire-frame self))
              (audio:play (intro-sound-fire self)))
             ((= (intro-movie-frame self) (intro-crash-frame self))
              (audio:play (intro-sound-crash self))))
       (when (> (intro-movie-frame self) (intro-max-movie-frame self))
         (setf (intro-movie-frame self) (1- (intro-max-movie-frame self))
               (intro-mode self) :banner
               (intro-movie-delta self) -1))
       (setf (intro-anim-elapsed self) 0.0)))

    (:banner
     (if (>= (cdr (gethash :banner (intro-positions self)))
             (- screen:+rows+ +banner-stop-margin+))
         (setf (intro-mode self) :still)
         (progn
           (%advance-credits self)
           (incf (intro-anim-elapsed self) level:+time-step+)
           (when (>= (intro-anim-elapsed self) (intro-anim-delta self))
             (%oscillate-movie self)
             (setf (intro-anim-elapsed self) 0.0)))))

    (:still
     (if (>= (intro-start-frame self) +end-delta+)
         (level:request-level :menu)
         (progn
           (incf (intro-anim-elapsed self) level:+time-step+)
           (when (>= (intro-anim-elapsed self) (intro-anim-delta self))
             (%oscillate-movie self)
             (setf (intro-anim-elapsed self) 0.0))))))

  (incf (intro-start-frame self))
  t)

(defmethod level:handle-event ((self intro) event)
  "ESC, SPACE or ENTER skips to the menu, as the original's registered keys did."
  (when (= (lgame.event:event-type event) lgame::+sdl-keyup+)
    (let ((key (lgame.event:key-scancode event)))
      (when (or (= key lgame::+sdl-scancode-escape+)
                (= key lgame::+sdl-scancode-space+)
                (= key lgame::+sdl-scancode-return+))
        (level:request-level :menu)
        t))))

(defmethod level:level-colormap ((self intro))
  (theme:theme-colormap (intro-theme self)))

(defmethod level:render-level ((self intro) screen)
  (let ((pos (intro-positions self)))
    (flet ((draw (key sprite z &optional (frame 0))
             (let ((p (gethash key pos)))
               (screen:enqueue screen sprite (car p) (cdr p) z frame))))
      (draw :star-field (intro-star-field self) +z-star-field+)
      (draw :movie (intro-movie self) +z-movie+ (intro-movie-frame self))
      (draw :logo-dp (intro-logo-dp self) +z-credits+)
      (draw :and (intro-and-text self) +z-credits+)
      (draw :hlab (intro-logo-hlab self) +z-credits+)
      (draw :presents (intro-presents-text self) +z-credits+)
      (draw :banner (intro-banner self) +z-credits+)))
  t)

(defmethod level:unload-level ((self intro))
  (audio:stop-all)
  (dolist (s (list (intro-music self) (intro-sound-fire self) (intro-sound-crash self)))
    (audio:free-sound s))
  (setf (intro-music self) nil
        (intro-sound-fire self) nil
        (intro-sound-crash self) nil
        (intro-theme self) nil)
  t)
