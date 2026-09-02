(in-package #:com.thejach.descendant.level.credits)

;;;; Port of origRef/GameLevels/dsc_level_credits.c.
;;;;
;;;; A vertically scrolling credit roll. The original builds the stack once in
;;;; CREDITS_initLevel by walking an ordered list and accumulating a running gap, then
;;;; scrolls the whole thing each tick by recomputing every Y from a single moving
;;;; origin. We keep exactly that: each entry stores the gap that precedes it, and
;;;; LAYOUT-Y sums them from the current scroll position.
;;;;
;;;; Entry kinds differ only in indent and trailing pad:
;;;;   :logo     centred, +8      :section  x=11, +5
;;;;   :header   x=15,     +3     :item     x=19, +3
;;;;   :space    contributes 8 to the following gap and draws nothing
;;;;
;;;; The roll restarts once the last copyright line clears the ceiling.

(defconstant +exit-delta+ 30 "CREDITS_EXIT_DELTA")
(defconstant +ceiling-margin+ 30 "d_cieling = rows - 30")
(defconstant +music-track-delta+ 10800)
(defconstant +start-y+ -1 "posY's initial value")

(defconstant +z-star-field+ 0)
(defconstant +z-background+ 1)
(defconstant +z-showcase+ 4
  "ADDED. Above the still, below the roll -- so the enemy parade passes behind the logos
   and the copyright block instead of colliding with them. The logos are wide (DigiPen is
   200 of 240 columns), so there is no lane that avoids them anyway.")
(defconstant +z-roll+ 6 "RDR_Z_SEVEN")
(defconstant +z-snippet+ 8 "RDR_Z_NINE: the strip that hides the roll behind the banner")
(defconstant +z-banner+ 9)
(defconstant +z-wipe+ 12 "ADDED. Above everything, including the banner.")

(defparameter *font-attr-pair* 112 "CREDITS_FONT_ATTR = GAM_FONT_ATTR(112, 0, 0, 0)")

(defun %rot13 (s)
  (map 'string
       (lambda (c)
         (let ((base (cond ((char<= #\A c #\Z) (char-code #\A))
                           ((char<= #\a c #\z) (char-code #\a)))))
           (if base
               (code-char (+ base (mod (+ (- (char-code c) base) 13) 26)))
               c)))
       s))

(defun %roll-text (text)
  "A roll entry's text: a plain string, or (:rot13 s) for one held rotated in source.

   Every name in the original roll is rotated, along with DIGIPEN CREDITS and the
   copyright block. The team were credited in 2010 and nobody asked them about a port
   published decades later; one of them may no longer be alive to ask. The DigiPen lines
   are rotated for the same reason rather than any other -- the README says plainly where
   this game came from, and the course it was made for.

   ROT13 is not concealment and is not offered as any. It keeps the strings from being
   what a search for those names turns up, which is the entire intent. The credits render
   identically, and (%ROT13 \"...\") at the REPL reads any of them back.

   Left plain: the port's own preface, and job titles like PRESIDENT, which identify
   nobody."
  (if (consp text) (%rot13 (second text)) text))

(defparameter *port-mark*
  '(" #     #     # "
    "  #    #    #  "
    "   ##  #  ##   "
    "     # # #     "
    "###############"
    "     # # #     "
    "   ##  #  ##   "
    "  #    #    #  "
    " #     #     # ")
  "A generic eight-spoke starburst, drawn here rather than loaded from a theme.

   Deliberately not anyone's logo. The FMOD mark came out of this roll for exactly that
   reason and it would be poor form to put another company's trademark back in its place.
   An asterisk is an asterisk.

   The spokes are spaced 3:2 horizontally against vertically because cells are 4x6
   pixels, so equal cell counts would lean the diagonals rather than run them at 45.")

(defun %mark-sprite (name picture &optional (pair *font-attr-pair*))
  "A sprite drawn from PICTURE, a list of equal-length strings in which any non-space
   cell is ink.

   Uses the same lit/unlit convention as TEXT:TEXT-SPRITE -- a solid block for ink, a
   space for the rest, both in PAIR -- so it sits in the roll looking as though the same
   font produced it."
  (let* ((height (length picture))
         (width (length (first picture)))
         (glyphs (make-array (* width height) :element-type '(unsigned-byte 32))))
    (loop for row in picture
          for y from 0
          do (assert (= (length row) width) ()
                     "~a: row ~d is ~d cells wide, expected ~d" name y (length row) width)
             (dotimes (x width)
               (setf (aref glyphs (+ (* y width) x))
                     (glyph:make-glyph (if (char= #\Space (char row x))
                                           glyph:+default-bg-char+
                                           glyph:+default-fg-char+)
                                       pair))))
    (theme:make-sprite name width height glyphs)))

(defparameter *roll*
  ;; (kind font text-or-sprite-key)
  ;;
  ;; ADDED: a short preface for the port, ahead of the original roll. Courier because it
  ;; is the only shipped face with lowercase drawn -- the HUD fonts have A-Z, 0-9 and ':'
  ;; and nothing else, so a mixed-case string in one renders as a row of dots.
  ;;
  ;; Mind the width. Courier is SEVEN CELLS per character, not seven pixels, so a line
  ;; gets 32 characters at the :section indent and 31 at :item before it runs off the
  ;; 240-cell screen. The year sits on its own :header line, which also gives the block
  ;; the same 11/15/19 stagger the rest of the roll has.
  '((:section :cour7 "Common Lisp Modernization Port")
    (:header  :cour7 "(2026)")
    (:item    :cour7 "Claude Opus 5 driven by Jach")
    (:logo    nil    :port-mark)
    (:item    :cour7 "(Try pressing B!)")
    (:space   nil    nil)
    (:section :cour7 "Original The Descendant Credits")
    (:space   nil    nil)
    (:logo    nil    "DP_logo")
    (:section :hud4  (:rot13 "QVTVCRA PERQVGF"))
    (:header  :hud4  "PRESIDENT")
    (:item    :hud6  (:rot13 "PYNHQR PBZNVE"))
    (:header  :hud4  "EXECUTIVE PRODUCERS")
    (:item    :hud6  (:rot13 "QBHT FPUVYYVAT"))
    (:item    :hud6  (:rot13 "RYVR NOV PUNUVAR"))
    (:space   nil    nil)
    (:logo    nil    "HLAB_logo")
    (:section :hud4  "TEAM HLAB CREDITS")
    (:header  :hud4  "PRODUCER")
    (:item    :hud6  (:rot13 "OEVNA YVIVATFGBA"))
    (:header  :hud4  "TECHNICAL DIRECTOR")
    (:item    :hud6  (:rot13 "XRIVA FRPERGNA"))
    (:header  :hud4  "DESIGNER")
    (:item    :hud6  (:rot13 "ZNEX RYYVAT"))
    (:header  :hud4  "PRODUCT MANAGER")
    (:item    :hud6  (:rot13 "FGRIRA PBIREG-OBJYQF"))
    (:space   nil    nil)
    (:header  :hud4  "PROGRAMMING : ART")
    (:item    :hud6  (:rot13 "OEVNA YVIVATFGBA"))
    (:item    :hud6  (:rot13 "XRIVA FRPERGNA"))
    (:item    :hud6  (:rot13 "ZNEX RYYVAT"))
    (:item    :hud6  (:rot13 "FGRIRA PBIREG-OBJYQF"))
    (:space   nil    nil)
    (:space   nil    nil)
    ;; The FMOD logo sat between these spaces, and the original was obliged to show it.
    ;; This port does not use FMOD -- SDL_mixer stands in for it -- so crediting Firelight
    ;; would now be simply inaccurate, quite apart from redistributing their mark. The
    ;; sprite is still in credits.thm; nothing draws it. All four surrounding :space
    ;; entries are kept, so the gap the logo sat in is still there.
    (:space   nil    nil)
    (:space   nil    nil)
    ;; Courier rather than a HUD font: these are the only mixed-case strings, and the
    ;; HUD faces have no lowercase drawn.
    (:item    :cour7 (:rot13 "Nyy pbagrag Pbclevtug 2010:"))
    (:item    :cour7 (:rot13 "QvtvCra (HFN) Pbecbengvba:"))
    (:item    :cour7 (:rot13 "nyy evtugf erfreirq."))
    (:space   nil    nil))
  "g_spriteOrder, with the port's preface prepended and the FMOD logo removed.")

(defstruct (entry (:constructor make-entry (sprite kind gap x)))
  sprite kind (gap 0) (x 0))

(defclass credits (level:level)
  ((theme :accessor credits-theme :initform nil)
   (background :accessor credits-background :initform nil)
   (banner :accessor credits-banner :initform nil)
   (star-field :accessor credits-star-field :initform nil)
   (star-snippet :accessor credits-star-snippet :initform nil)
   (entries :accessor credits-entries :initform '())
   (move-pos :accessor credits-move-pos :initform (float +start-y+))
   (move-delta :accessor credits-move-delta :initform 0.13)
   (music :accessor credits-music :initform nil)
   (showcase :accessor credits-showcase :initform nil)
   ;; The transition into the hidden gallery. It runs here rather than there so that what
   ;; it covers is the credits themselves; the gallery only takes over once the screen is
   ;; fully painted and the change cannot be seen.
   (wipe :accessor credits-wipe :initform nil)
   ;; True when this entry came back from the gallery with the music still running.
   (resumed? :accessor credits-resumed? :initform nil)
   (frame :accessor credits-frame :initform 0))
  (:default-initargs :name "credits"))

(level:register-level :credits 'credits)

(defun %kind-pad (kind height)
  (ecase kind
    (:logo (+ height 8))
    (:section (+ height 5))
    ((:header :item) (+ height 3))))

(defun %kind-x (kind sprite)
  (ecase kind
    (:logo (ash (- screen:+cols+ (theme:sprite-width sprite)) -1))
    (:section 11)
    (:header 15)
    (:item 19)))

(defmethod level:load-level ((self credits))
  (let* ((cfg (config:read-config (paths:config-path "level_credits.cfg")))
         (th (theme:read-theme (paths:theme-path "credits.thm")))
         (fonts (list :hud4 (font:read-bft (paths:font-path "dsc_font_hud_04.bft"))
                      :hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft"))
                      :cour7 (font:read-bft (paths:font-path "dsc_font_courier_07.bft"))))
         (attr (text:font-attr :pair *font-attr-pair*)))
    (setf (credits-theme self) th
          (credits-background self)
          (theme:find-sprite th (config:config-text cfg "credits.movie_still"
                                                    "credits_bg"))
          (credits-banner self)
          (theme:find-sprite th (config:config-text cfg "credits.banner" "DSC_logo"))
          (credits-move-delta self)
          (config:config-float cfg "credits.credits_move_delta" 0.13))

    ;; Opaque two-entry field, as the credits and controls screens both use.
    (let ((entries (list (field:make-field-entry (char-code #\.) 2 8)
                         (field:make-field-entry (char-code #\Space) 2 92))))
      (setf (credits-star-field self)
            (field:make-field screen:+cols+ screen:+rows+ entries)
            ;; The original copies the field's top 10 rows into a separate strip and
            ;; draws it above the roll, so credits do not show through the banner.
            (credits-star-snippet self)
            (field:make-field screen:+cols+ 10 entries)))

    ;; Build the stack. GAP is the space before an entry; :space adds to the next gap.
    (let ((gap 0) (entries '()))
      (dolist (spec *roll*)
        (destructuring-bind (kind font-key text) spec
          (setf text (%roll-text text))
          (if (eq kind :space)
              (incf gap 8)
              (let ((sprite (if font-key
                                (let ((f (getf fonts font-key)))
                                  ;; The HUD faces have no hyphen drawn, and one of the
                                  ;; credited names has one. Nothing to be done about it
                                  ;; without editing the shipped fonts, so it is named
                                  ;; here rather than reported every run.
                                  (text:check-text-coverage f text :context "credits"
                                                                   :expected '(#\-))
                                  (text:text-sprite f text attr))
                                ;; A keyword names a sprite this file draws; a string
                                ;; names one in credits.thm.
                                (if (keywordp text)
                                    (ecase text
                                      (:port-mark (%mark-sprite "port-mark" *port-mark*)))
                                    (theme:find-sprite th text)))))
                (unless sprite (error "credits: no sprite ~s" text))
                ;; Warn on a line that will not fit. The layout tests check Y only, so an
                ;; over-wide line is silently clipped at the right edge and reads as a
                ;; sentence that stops mid-word -- which is how the port's own preface
                ;; first went in. Courier is 7 CELLS per character, which is easy to
                ;; mistake for 7 pixels when counting by eye.
                (let ((x (%kind-x kind sprite)))
                  (when (> (+ x (theme:sprite-width sprite)) screen:+cols+)
                    (warn "credits: ~s is ~d cells at x=~d, ~d past the ~d-cell screen"
                          text (theme:sprite-width sprite) x
                          (- (+ x (theme:sprite-width sprite)) screen:+cols+)
                          screen:+cols+))
                  (push (make-entry sprite kind gap x) entries))
                (setf gap (%kind-pad kind (theme:sprite-height sprite)))))))
      (setf (credits-entries self) (nreverse entries)))

    ;; The enemies come from the three level themes and are toned into this one's palette
    ;; on the way in; see SHOWCASE.
    (setf (credits-showcase self)
          (showcase:make-showcase (theme:theme-colormap th)
                                  :font (getf fonts :hud4)
                                  :attr attr))

    (setf (credits-wipe self) (wipe:make-wipe (theme:theme-colormap th)))

    ;; Coming back from the gallery, the track is still playing: take it back rather than
    ;; loading a second copy.
    (let ((held (audio:take-retained-music)))
      (setf (credits-resumed? self) (and held t))
      (setf (credits-music self)
            (or held
                (let ((tracks (config:config-list cfg "credits.music_tracks")))
                  (when tracks
                    (audio:load-sound (paths:sound-path (first tracks)) :kind :music))))))
    t))

(defmethod level:init-level ((self credits))
  (setf (credits-move-pos self) (float +start-y+)
        (credits-frame self) 0)
  ;; Restarting a track that never stopped would jump it back to the beginning, which is
  ;; the very seam this is meant to hide.
  (if (credits-resumed? self)
      (setf (credits-resumed? self) nil)
      (audio:play-music (credits-music self)))
  t)

(defmethod level:level-colormap ((self credits))
  (theme:theme-colormap (credits-theme self)))

(defun layout-y (self)
  "Y for each entry, top to bottom, from the current scroll origin."
  (let ((y (truncate (credits-move-pos self))))
    (loop for e in (credits-entries self)
          do (decf y (entry-gap e))
          collect y)))

(defun %last-y (self)
  (car (last (layout-y self))))

(defmethod level:update-level ((self credits))
  ;; Restart once the final copyright line has risen past the ceiling.
  (if (>= (%last-y self) (- screen:+rows+ +ceiling-margin+))
      (setf (credits-move-pos self) (float +start-y+))
      (incf (credits-move-pos self) (credits-move-delta self)))
  (when (credits-showcase self) (showcase:update (credits-showcase self)))
  ;; Once the wipe has the screen entirely covered, hand over.
  (let ((w (credits-wipe self)))
    (when (and w (wipe:running? w))
      (wipe:update w)
      (when (wipe:covered? w)
        (wipe:stop w)
        (level:request-level :bestiary))))
  (incf (credits-frame self))
  t)

(defmethod level:handle-event ((self credits) event)
  (when (and (>= (credits-frame self) +exit-delta+)
             (= (lgame.event:event-type event) lgame::+sdl-keyup+))
    (let ((key (lgame.event:key-scancode event)))
      (cond
        ;; Undocumented: B opens the gallery. Ignored once a wipe is already running, so
        ;; leaning on the key cannot restart the transition part way through.
        ((= key lgame::+sdl-scancode-b+)
         (let ((w (credits-wipe self)))
           (when (and w (not (wipe:running? w)))
             (wipe:start w)))
         t)
        ((or (= key lgame::+sdl-scancode-escape+)
             (= key lgame::+sdl-scancode-space+)
             (= key lgame::+sdl-scancode-return+))
         (level:request-level :menu)
         t)))))

(defmethod level:render-level ((self credits) screen)
  (screen:enqueue screen (credits-star-field self) 0 screen:+rows+ +z-star-field+)
  (screen:enqueue screen (credits-background self) 0 screen:+rows+ +z-background+)
  (when (credits-showcase self)
    (showcase:render (credits-showcase self) screen +z-showcase+))
  (loop for e in (credits-entries self)
        for y in (layout-y self)
        do (screen:enqueue screen (entry-sprite e) (entry-x e) y +z-roll+))
  (screen:enqueue screen (credits-star-snippet self) 0 screen:+rows+ +z-snippet+)
  (let ((banner (credits-banner self)))
    (screen:enqueue screen banner
                    (ash (- screen:+cols+ (theme:sprite-width banner)) -1)
                    (- screen:+rows+ 3) +z-banner+))
  (when (credits-wipe self)
    (wipe:render (credits-wipe self) screen +z-wipe+))
  t)

(defmethod level:unload-level ((self credits))
  ;; The gallery is a detour from this screen rather than a different place, so the track
  ;; goes with it and comes back still playing. Anywhere else gets silence as before.
  (if (eq level:*requested* :bestiary)
      (audio:retain-music (credits-music self))
      (progn
        (audio:stop-all)
        (audio:free-sound (credits-music self))))
  (when (credits-showcase self) (showcase:free (credits-showcase self)))
  (setf (credits-music self) nil
        (credits-showcase self) nil
        (credits-wipe self) nil
        (credits-theme self) nil)
  t)
