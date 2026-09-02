(in-package #:com.thejach.descendant.level.menu)

;;;; Port of origRef/GameLevels/dsc_level_menu.c.
;;;;
;;;; Two option lists sharing one screen. The main list is START / OPTIONS / CONTROLS /
;;;; HIGH SCORES / CREDITS / EXIT; choosing OPTIONS swaps in DIFFICULTY / MUSIC VOL /
;;;; EFFECTS VOL / VIDEO QLTY / GO BACK, where left and right adjust the value under the
;;;; cursor. Both wrap around, which the original did with a circular linked list.
;;;;
;;;; Layout constants are the original's: options start at column 50, the first row is
;;;; MENU_Y_OFFSET up from the bottom, and each subsequent row is 10 cells lower.

(defconstant +y-offset+ 50 "MENU_Y_OFFSET")
(defconstant +option-x+ 50 "posX")
(defconstant +sub-x+ 120 "d_posSubX: where the value lists are drawn")
(defconstant +row-step+ 10 "Vertical gap between option rows")
(defconstant +value-step+ 12 "Cell gap between entries in a value list")

;;; The options page's own geometry. Two columns, so the single column the original drew
;;; at x=50 moves left to make room. Widths are what the longest label in each place
;;; actually measures in hud_06 at six cells a character: EFFECTS VOL is 66, the six
;;; volume choices with gaps are 66, AUTO FIRE is 54, ON/OFF is 36.
(defconstant +sub-label-x+ 3 "Left column labels.")
(defconstant +sub-value-x+ 76
  "Left column choices. EFFECTS VOL and FRAME LIMIT are both eleven characters, so the
   labels reach 69; this leaves a clear gap rather than butting the two together.")
(defconstant +sub2-label-x+ 146 "Right column labels.")
(defconstant +sub2-value-x+ 190
  "Right column choices. Further left than the left column's, because RENDER's are words
   -- SLO and FAST need 46 cells between them, where a switch needs 34. RENDER is a short
   label for exactly this reason.")
(defconstant +choice-gap+ 4
  "Cells between one choice and the next. Four rather than six because six volume steps
   at six cells each plus the gaps has to fit beside an eleven-character label.")

(defconstant +sub-panel-x+ 1)
(defconstant +sub-panel-width+ 136)
(defconstant +sub-value-panel-x+ 74)
(defconstant +sub-value-panel-width+ 62)
(defconstant +sub2-panel-x+ 144)
(defconstant +sub2-panel-width+ 94)
(defconstant +sub2-value-panel-x+ 188)
(defconstant +sub2-value-panel-width+ 50)

;;; Colours built rather than looked up, now that GLYPH:ENCODE-PAIR can express "this
;;; foreground on that background" directly. Measured against menu_bg: slots 11 and 12 are
;;; the blues the earth is drawn with, and 13 is the lightest grey the menu never uses.
(defconstant +earth-blue-slot+ 12
  "The current setting's colour when its row is not selected. Slot 11 is the earth's more
   common blue but is too dark to read on the black strip the choices sit on; 12 is the
   same family and legible.")
(defconstant +disabled-slot+ 13
  "Background for a row that cannot be changed right now.")

(defparameter *value-strip* :none
  "Where the darker strip goes on the options page.

     :values  behind the choices, as the original put it
     :labels  behind the names instead
     :none    nowhere; the whole row sits on the panel

   The blue that marks the current choice reads better on the panel than on black, so
   :none is the default. Kept as a switch because the three are worth comparing again if
   the palette ever changes.")
(defconstant +music-track-delta+ 10800 "DSC_MUSIC_TRACK_DELTA, ~3 minutes")

;;; Z-layers from RenderZOrder: ONE, TWO, THREE, FOUR, TEN.
(defconstant +z-star-field+ 0)
(defconstant +z-background+ 1)
(defconstant +z-select-area+ 2)
(defconstant +z-select-box+ 3)
(defconstant +z-text+ 9)

;;; Fill glyphs, RDR_GLYPH_ATTR(pair, 0, char).
(defconstant +select-glyph-pair+ 38 "MENU_SELECT_GLYPH: the highlight bar")
(defconstant +area-glyph-pair+ 182 "MENU_SELECT_AREA_GLYPH: the panel behind the list")
(defconstant +sub-area-glyph-pair+ 2 "MENU_SUB_SELECT_AREA_GLYPH: behind the values")

(defparameter *format-break* "=<=<=<=$=T=h=e=D=e=s=c=e=n=d=a=n=t=$=>=>=>="
  "MENU_FORMAT_BREAK, the scroller along the bottom. Drawn in arial_05 rather than a
   HUD font precisely because it contains lowercase, which the HUD fonts never had.")

(defparameter *main-options*
  '((:start "START") (:continue "CONTINUE") (:options "OPTIONS") (:controls "CONTROLS")
    (:scores "HIGH SCORES") (:credits "CREDITS") (:exit "EXIT"))
  "CONTINUE is ADDED, not ported, and is conditional -- see %OPTIONS. Everything else is
   the original's list in its order.")

;;; ---------------------------------------------------------------------------
;;; The options page
;;;
;;; Two columns. The left one is settings, each with its choices laid out beside it; the
;;; right one is the things that are not about the display -- the way out, wiping the
;;; scores, and the two switches that belong to play rather than to presentation.
;;;
;;; The original had one column of five and drew the marker only on the row the cursor was
;;; on, so you could not see what anything else was set to without visiting it. Every row
;;; now shows its own value: highlighted, that is the select bar the original used;
;;; otherwise the current choice is drawn in the blue the earth uses in the background,
;;; which reads as "this one" without competing with the cursor.

(defparameter *sub-columns*
  '(((:difficulty  "DIFFICULTY"      :difficulty)
     (:music-vol   "MUSIC VOL"       :music-volume)
     (:effects-vol "EFFECTS VOL"     :effects-volume)
     (:fullscreen  "FULLSCREEN"      :fullscreen)
     (:auto-fire   "AUTOFIRE"        :auto-fire)
     (:show-hud    "SHOW HUD"        :show-hud))
    ((:renderer    "RENDER"          :renderer)
     (:erase       "ERASE HI SCORES")
     (:go-back     "GO BACK")))
  "(key label &optional setting) per row, per column. A row with no setting is an action.

   GO BACK is last, where the way out belongs. RENDER is short on purpose: it is the one
   row whose choices are words rather than digits, so the label gives up the width its
   values need.")

(defparameter *erased-label* "ERASED"
  "What ERASE HI SCORES becomes once it has been used, so the screen says what happened
   rather than leaving you to guess whether the key registered.")

(defparameter *restart-label* "RESTART NEEDED"
  "What RENDER becomes once it has been changed. The renderer is chosen when the window is
   built, so the switch is a note to self rather than something that happens now.")

(defun %sub-rows (&optional (columns *sub-columns*))
  "Every options row as (column row key label setting)."
  (loop for column in columns
        for c from 0
        append (loop for spec in column
                     for r from 0
                     collect (list c r (first spec) (second spec) (third spec)))))

(defun %sub-row (key)
  (find key (%sub-rows) :key #'third))

(defun %row-setting (key) (fifth (%sub-row key)))

(defun row-enabled? (key)
  "Whether the cursor may land on a row and change it. Nothing is disabled at the moment;
   the hook is kept because the layout and the navigation both already honour it, and the
   next setting that depends on another will want it."
  (declare (ignore key))
  t)

;;; What each setting offers, as (value . label). Booleans read ON and OFF because that
;;; is what a switch says; numbers are shown as themselves, so the value on screen is
;;; literally the value stored.

(defun choices-for (setting-key)
  (when setting-key
    (loop for value in (settings:choice-values setting-key)
          collect (cons value (settings:choice-label setting-key value)))))

(defclass menu (level:level)
  ((theme :accessor menu-theme :initform nil)
   (config :accessor menu-config :initform nil)
   ;; sprites
   (background :accessor menu-background :initform nil)
   (banner :accessor menu-banner :initform nil)
   (star-field :accessor menu-star-field :initform nil)
   (line-break :accessor menu-line-break :initform nil)
   ;; The same scroller with a row of background on top; see %EXTEND-UP.
   (labels* :accessor menu-labels :initform (make-hash-table :test #'eq))
   (select-area-main :accessor menu-select-area-main :initform nil)
   ;; Row count -> panel sprite. See %MAIN-AREA-FOR.
   (main-areas :accessor menu-main-areas :initform '())
   (select-box-main :accessor menu-select-box-main :initform nil)
   ;; Choice width -> marker sprite. The original had one size because every choice was a
   ;; single digit; ON and OFF are not the same width.
   (choice-boxes :accessor menu-choice-boxes :initform (make-hash-table :test #'eql))
   ;; Bar width -> sprite. Rows differ in how much of themselves the cursor should cover.
   (select-bars :accessor menu-select-bars :initform (make-hash-table :test #'eql))
   ;; setting key -> vector of (value label-sprite blue-sprite x-offset width)
   (choices :accessor menu-choices :initform (make-hash-table :test #'eq))
   (sub-areas :accessor menu-sub-areas :initform '())
   (disabled-bar :accessor menu-disabled-bar :initform nil)
   ;; Whether the scores have been wiped during this visit, which is all the ERASED label
   ;; means -- it is a receipt, not a state worth persisting.
   (erased? :accessor menu-erased? :initform nil)
   ;; Likewise a receipt: the renderer has been changed and will take effect next launch.
   (restart-needed? :accessor menu-restart-needed? :initform nil)
   ;; state
   (page :accessor menu-page :initform :main)
   (selection :accessor menu-selection :initform :start)
   (difficulty :accessor menu-difficulty :initform 2)
   ;; audio
   (tracks :accessor menu-tracks :initform '())
   (track-index :accessor menu-track-index :initform 0)
   (scroll :accessor menu-scroll :initform nil)
   (select :accessor menu-select :initform nil))
  (:default-initargs :name "menu"))

(level:register-level :menu 'menu)

(defun %main-area-for (self)
  "The main panel, sized to the rows currently showing and cached per size -- there are
   only two, and rebuilding five thousand cells every frame to find that out would be
   silly."
  (let* ((rows (length (%options self)))
         (cached (assoc rows (menu-main-areas self))))
    (or (cdr cached)
        (let ((sprite (%fill-sprite "area1" +main-area-width+ (%main-area-height rows)
                                    +area-glyph-pair+ (char-code #\-))))
          (push (cons rows sprite) (menu-main-areas self))
          sprite))))

(defun %options (self)
  "The rows actually on screen. CONTINUE is dropped unless a run ended past stage one, so
   the menu is the original's exactly until there is something to resume -- and because
   the row list drives both layout and navigation, everything below it simply shifts down
   when it appears."
  (ecase (menu-page self)
    (:main (if (state:continue-available?)
               *main-options*
               (remove :continue *main-options* :key #'first)))
    ;; The options page is laid out in columns and does not have a single row list; see
    ;; %SUB-ROWS and %NAVIGABLE.
    (:sub '())))

(defun %option-row (self key)
  "Index of KEY within the main list."
  (position key (%options self) :key #'first))

(defun %y-offset (rows)
  "Where the option list starts, raised when there are more rows than the original had.

   Growing the panel downward alone is not enough: the shipped six already end just above
   the scrolling ticker, so a seventh pushes EXIT onto it.

   Six rows of lift per extra option, not the full ten. Ten would put the last option
   exactly where the six-row layout has it, but the panel top would then run up under the
   banner; six is as much as the banner leaves room for once it has itself moved up two."
  (- +y-offset+ (* (- rows +base-main-options+) +extra-row-lift+)))

(defun %option-y (row &optional (rows +base-main-options+))
  "Rows count up from the bottom, so later options sit lower on screen."
  (- screen:+rows+ (+ (%y-offset rows) (* row +row-step+))))

(defconstant +main-area-width+ 74)
(defconstant +base-main-options+ 6
  "Rows the original's panel was drawn for: START, OPTIONS, CONTROLS, HIGH SCORES,
   CREDITS, EXIT.")
(defconstant +base-main-area-height+ 62 "Its height, for those six.")

(defun %main-area-height (rows)
  "The panel has to cover however many rows are showing. With CONTINUE present EXIT fell
   off the bottom of the shipped 62 and sat on bare starfield."
  (+ +base-main-area-height+ (* (- rows +base-main-options+) +row-step+)))

(defconstant +extra-row-lift+ 6
  "How far the option list rises per extra option. See %Y-OFFSET.

   Six, not the ten that would put EXIT exactly where the six-row layout has it: the
   panel grows upward as the list rises, and more than six runs its top edge up under the
   banner. Six is what the banner leaves room for, and the panel is deep enough at that
   point to reach the scroller, so nothing shows through beneath the last option.")

(defun %fill-sprite (name width height pair &optional (char #x20))
  (let ((g (glyph:make-glyph char pair)))
    (theme:make-sprite name width height
                       (make-array (* width height) :element-type '(unsigned-byte 32)
                                                    :initial-element g))))

(defun %centered-x (sprite)
  (ash (- screen:+cols+ (theme:sprite-width sprite)) -1))

(defmethod level:load-level ((self menu))
  (let* ((cfg (config:read-config (paths:config-path "level_menu.cfg")))
         (th (theme:read-theme (paths:theme-path "menu.thm")))
         (hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft")))
         (arial5 (font:read-bft (paths:font-path "dsc_font_arial_05.bft"))))
    (setf (menu-config self) cfg
          (menu-theme self) th
          (menu-background self) (theme:find-sprite th "menu_bg")
          (menu-banner self) (theme:find-sprite th "DSC_logo")
          (menu-star-field self) (field:make-star-field screen:+cols+ screen:+rows+))

    ;; Option labels. All uppercase, which is what hud_06 can actually draw.
    (flet ((label (key text)
             (text:check-text-coverage hud6 text :context "menu")
             (setf (gethash key (menu-labels self)) (text:text-sprite hud6 text))))
      (dolist (spec *main-options*)
        (label (first spec) (second spec)))
      (dolist (row (%sub-rows))
        (label (third row) (fourth row)))
      ;; Built up front so pressing the key does not have to rasterise anything.
      (label :erased *erased-label*)
      (label :restart *restart-label*))

    ;; Every choice, twice: once in the ordinary colour and once in the earth's blue for
    ;; the row that is not selected. Laid out left to right here rather than at render
    ;; time, because the widths differ -- ON is two characters and OFF is three.
    (let ((blue (text:font-attr :pair (glyph:encode-pair +earth-blue-slot+ 0)
                                :mod glyph:+mod-transparent-bg+)))
      (dolist (row (%sub-rows))
        (let ((setting (fifth row)))
          (when (and setting (null (gethash setting (menu-choices self))))
            (let ((x 0))
              (setf (gethash setting (menu-choices self))
                    (map 'vector
                         (lambda (choice)
                           (destructuring-bind (value . text) choice
                             (let* ((plain (text:text-sprite hud6 text))
                                    (width (theme:sprite-width plain))
                                    (entry (list value plain
                                                 (text:text-sprite hud6 text blue)
                                                 x width)))
                               (incf x (+ width +choice-gap+))
                               ;; A marker for each width that turns up, with a cell of
                               ;; air either side as the original's had.
                               (unless (gethash width (menu-choice-boxes self))
                                 (setf (gethash width (menu-choice-boxes self))
                                       (%fill-sprite (format nil "boxs~d" width)
                                                     (+ width 2) 10
                                                     +select-glyph-pair+)))
                               entry)))
                         (choices-for setting))))))))

    ;; The scroller: pair 9, background character 'M' so the gaps read as texture
    ;; rather than blank. GAM_FONT_ATTR(9, 0, 'M', 0).
    ;;
    (setf (menu-line-break self)
          (text:text-sprite arial5 *format-break*
                            (text:font-attr :pair 9 :mod 0
                                            :bg-char (char-code #\M) :fg-char 0)))

    ;; Panels and highlight bars, filled with a single repeated glyph. new_GameSprite
    ;; takes (name, height, width), hence the transposed-looking numbers here.
    (setf (menu-select-area-main self) (%main-area-for self)
          (menu-select-box-main self)  (%fill-sprite "box1" 70 10 +select-glyph-pair+)
          ;; A bar the width of a choice list, for greying a row that cannot be changed.
          (menu-disabled-bar self)
          (%fill-sprite "boxd" +sub2-value-panel-width+ 8
                        (glyph:encode-pair 0 +disabled-slot+)))

    ;; One panel per column, sized to the rows it holds, plus the darker strip the
    ;; choices sit on. Built once and kept, since neither can change.
    (setf (menu-sub-areas self)
          (loop for column in *sub-columns*
                for c from 0
                for rows = (length column)
                ;; Sized the way the main page's panel is, so the two pages have the same
                ;; margins around their lists.
                for height = (%main-area-height rows)
                collect (list c
                              (%fill-sprite (format nil "subarea~d" c)
                                            (if (zerop c)
                                                +sub-panel-width+
                                                +sub2-panel-width+)
                                            height +area-glyph-pair+ (char-code #\-))
                              ;; One row tall, drawn only where a row actually has
                              ;; choices. A full-height strip would run behind GO BACK
                              ;; and ERASE HI SCORES, which have no value to sit on it.
                              (%fill-sprite (format nil "subvals~d" c)
                                            (ecase *value-strip*
                                              ((:values :none)
                                               (if (zerop c)
                                                   +sub-value-panel-width+
                                                   +sub2-value-panel-width+))
                                              (:labels
                                               (if (zerop c)
                                                   (- +sub-value-x+ +sub-label-x+ 3)
                                                   (- +sub2-value-x+ +sub2-label-x+ 3))))
                                            +row-step+ +sub-area-glyph-pair+))))

    ;; The config only wins if the player has not chosen. MENU_loadLevel is reached every
    ;; time the menu is entered and reloads the file each time, so without this a choice
    ;; made in the options screen would be undone by backing out of it. The original does
    ;; the same thing by stashing the value across the reload when it is `!= 4`.
    (setf (menu-difficulty self)
          (state:difficulty-from-config (settings:value :difficulty)))
    (setf (settings:value :difficulty) (menu-difficulty self))
    ;; The saved settings are already in place by now -- MAIN loads them before the first
    ;; level -- so the volumes only need pushing at the mixer, not deciding.
    (audio:set-music-volume (settings:volume-fraction (settings:value :music-volume)))
    (audio:set-effects-volume
     (settings:volume-fraction (settings:value :effects-volume)))

    (setf (menu-tracks self)
          (remove nil (mapcar (lambda (name)
                                (audio:load-sound (paths:sound-path name) :kind :music))
                              (config:config-list cfg "intro_menu.music_tracks")))
          (menu-scroll self) (audio:load-sound (paths:sound-path "menu_scroll.wav")
                                               :kind :chunk)
          (menu-select self) (audio:load-sound (paths:sound-path "menu_select.wav")
                                               :kind :chunk))
    t))

(defmethod level:init-level ((self menu))
  (setf (menu-page self) :main
        (menu-selection self) :start)
  (when (menu-tracks self)
    (setf (menu-track-index self) (random (length (menu-tracks self))))
    (audio:play-music (nth (menu-track-index self) (menu-tracks self))))
  t)

(defmethod level:level-colormap ((self menu))
  (theme:theme-colormap (menu-theme self)))

;;; ---------------------------------------------------------------------------
;;; Update

(defun %navigable (self)
  "The rows the cursor may land on, in the order up and down walk them. On the options
   page that is both columns end to end, so pressing down off the bottom of the first
   arrives at the top of the second; disabled rows are left out entirely."
  (if (eq (menu-page self) :main)
      (mapcar #'first (%options self))
      (loop for row in (%sub-rows)
            when (row-enabled? (third row))
              collect (third row))))

(defun %advance-selection (self delta)
  (let* ((keys (%navigable self))
         (i (or (position (menu-selection self) keys) 0)))
    (setf (menu-selection self) (nth (mod (+ i delta) (length keys)) keys))
    (audio:play (menu-scroll self))))

(defun %choice-index (self setting)
  "Which choice is current, by value."
  (let ((choices (gethash setting (menu-choices self)))
        (current (settings:value setting)))
    (or (position current choices :key #'first :test #'eql) 0)))

(defun %apply-setting (self key)
  "Push a changed setting at whatever actually owns the behaviour. Everything here is a
   side effect the setting alone cannot perform."
  (case key
    ;; Difficulty goes into the shared state, as the original writes
    ;; g_dscState.d_difficulty: the enemy loader reads it three levels away at load.
    (:difficulty (setf (menu-difficulty self)
                       (state:set-difficulty (settings:value :difficulty))))
    (:music-volume
     (audio:set-music-volume (settings:volume-fraction (settings:value key))))
    (:effects-volume
     (audio:set-effects-volume (settings:volume-fraction (settings:value key))))
    (:fullscreen (settings:apply-change :fullscreen))
    (:renderer
     ;; Nothing to apply: the renderer is built with the window. Say so and step away, so
     ;; the row is not left looking as though it did something.
     (setf (menu-restart-needed? self) t
           (menu-selection self) :go-back))))

(defun %adjust (self delta)
  "Left and right step through a row's choices. Actions have none and ignore it."
  (let* ((key (menu-selection self))
         (setting (%row-setting key))
         (choices (and setting (gethash setting (menu-choices self)))))
    (when (and choices (row-enabled? key))
      (let* ((i (%choice-index self setting))
             ;; Clamped rather than wrapped: a two-choice switch that wraps is a toggle
             ;; whichever way you press, which makes left and right meaningless.
             (n (max 0 (min (1- (length choices)) (+ i delta)))))
        (unless (= n i)
          (setf (settings:value setting) (first (aref choices n)))
          (%apply-setting self setting)
          (audio:play (menu-scroll self)))))))

(defun %activate (self)
  (audio:play (menu-select self))
  (case (menu-selection self)
    ;; START always means crash_site. The theme is cross-level state, so without this it
    ;; would still be wherever the last run left it -- dying on stage two and pressing
    ;; START put you straight back on stage two.
    (:start (state:begin-new-run)
            (level:request-level :descendant))
    ;; Move the cursor off CONTINUE before consuming it. RESUME-RUN clears the flag that
    ;; puts the row on screen, and the menu still renders a frame or two before the switch
    ;; happens -- with the selection pointing at a row that no longer exists, whose
    ;; position is NIL.
    (:continue (setf (menu-selection self) :start)
               (state:resume-run)
               (level:request-level :descendant))
    (:options (setf (menu-page self) :sub
                    (menu-selection self) :difficulty))
    (:controls (level:request-level :controls))
    (:scores (level:request-level :score))
    (:credits (level:request-level :credits))
    (:exit (level:request-quit))
    (:go-back (%leave-options self))
    (:erase (%erase-scores self))
    (t nil)))

(defun %leave-options (self)
  "Back to the main list, saving on the way out. Saving here rather than on every
   keypress means the file is written once per visit, and means leaving is the moment the
   choices become permanent -- which is the moment a player would expect."
  (settings:save-settings)
  (setf (menu-page self) :main
        (menu-selection self) :options))

(defun %erase-scores (self)
  "Wipe the table back to the stock names. Destructive and unasked-for-twice, which is
   worth a word: the row is in the second column with the other things that are not
   settings, it takes a deliberate ENTER, and it says ERASED afterwards so there is no
   doubt it happened."
  (when (score:erase-scores)
    (setf (menu-erased? self) t)
    ;; Nothing left to do on a row that now reads ERASED, so step off it.
    (setf (menu-selection self) :go-back)))

(defun %activate-escape (self)
  "Escape backs out one level rather than always quitting. Quitting from the options
   screen -- somewhere you go to change a setting and come back -- loses the run for a
   keypress that everywhere else means 'not this one'."
  (if (eq (menu-page self) :main)
      (level:request-quit)
      ;; Through GO BACK's own path, so it sounds the same as choosing it and saves the
      ;; same way -- backing out with escape must not quietly lose the changes.
      (progn (setf (menu-selection self) :go-back)
             (%activate self))))

(defmethod level:update-level ((self menu))
  ;; Rotate the background music every ~3 minutes, as the original did.
  (when (and (menu-tracks self)
             (plusp level:*frame*)
             (zerop (mod level:*frame* +music-track-delta+)))
    (setf (menu-track-index self)
          (mod (1+ (menu-track-index self)) (length (menu-tracks self))))
    (audio:play-music (nth (menu-track-index self) (menu-tracks self))))
  t)

(defmethod level:handle-event ((self menu) event)
  (when (= (lgame.event:event-type event) lgame::+sdl-keydown+)
    (let ((key (lgame.event:key-scancode event)))
      (cond
        ((= key lgame::+sdl-scancode-up+) (%advance-selection self -1) t)
        ((= key lgame::+sdl-scancode-down+) (%advance-selection self 1) t)
        ((= key lgame::+sdl-scancode-left+) (%adjust self -1) t)
        ((= key lgame::+sdl-scancode-right+) (%adjust self 1) t)
        ((or (= key lgame::+sdl-scancode-return+)
             (= key lgame::+sdl-scancode-space+))
         (%activate self) t)
        ;; Escape backs out one level rather than always quitting. Quitting from the
        ;; options screen -- a screen you enter to change a setting and leave again --
        ;; loses the run for a keypress that everywhere else means "not this one".
        ((= key lgame::+sdl-scancode-escape+) (%activate-escape self) t)
        (t nil)))))

;;; ---------------------------------------------------------------------------
;;; Render

(defun %column-x (column) (if (zerop column) +sub-label-x+ +sub2-label-x+))
(defun %column-value-x (column) (if (zerop column) +sub-value-x+ +sub2-value-x+))

(defun %select-bar (self column &optional label-width)
  "The highlight bar for a row. Without LABEL-WIDTH it is the column's label area; with
   one it is that label plus a cell of air, for rows whose name is all they have."
  (let ((width (if label-width
                   (+ label-width 2)
                   (- (%column-value-x column) (%column-x column) 3))))
    (or (gethash width (menu-select-bars self))
        (setf (gethash width (menu-select-bars self))
              (%fill-sprite (format nil "bar~d" width) width 10 +select-glyph-pair+)))))

(defun %reporting? (self key)
  "Whether a row has replaced its name with a message about what just happened."
  (or (and (eq key :erase) (menu-erased? self))
      (and (eq key :renderer) (menu-restart-needed? self))))

(defun %row-label (self key)
  "The sprite for a row's name. Two rows report back in place of their own name: ERASE HI
   SCORES once it has been used, and RENDER once it has been changed."
  (gethash (cond ((and (eq key :erase) (menu-erased? self)) :erased)
                 ((and (eq key :renderer) (menu-restart-needed? self)) :restart)
                 (t key))
           (menu-labels self)))

(defun %render-options-page (self screen)
  ;; Strips before panels, deliberately: within a z-layer the compositor walks the queue
  ;; head-first, so the EARLIEST enqueued sprite ends up on top. The darker strip the
  ;; choices sit on has to go down first to be seen at all.
  (unless (eq *value-strip* :none)
    (dolist (row (%sub-rows))
      (destructuring-bind (column r key label setting) row
        (declare (ignore key label))
        (when setting
          (screen:enqueue screen (third (assoc column (menu-sub-areas self)))
                          (ecase *value-strip*
                            (:values (if (zerop column)
                                         +sub-value-panel-x+
                                         +sub2-value-panel-x+))
                            (:labels (%column-x column)))
                          (+ (%option-y r) 2)
                          +z-select-area+)))))
  (loop for (column sprite nil) in (menu-sub-areas self)
        do (screen:enqueue screen sprite
                           (if (zerop column) +sub-panel-x+ +sub2-panel-x+)
                           (- screen:+rows+ (- +y-offset+ 3))
                           +z-select-area+))

  (dolist (row (%sub-rows))
    (destructuring-bind (column r key label setting) row
      (declare (ignore label))
      (let* ((y (%option-y r))
             (selected? (eq key (menu-selection self)))
             (enabled? (row-enabled? key)))
        ;; A row that cannot be changed is greyed where its choices would be, so the row
        ;; and the reason it is inert are both still on screen.
        (unless enabled?
          (screen:enqueue screen (menu-disabled-bar self)
                          (%column-value-x column) (+ y 1) +z-select-box+))
        (when selected?
          ;; The bar covers the label. On a row with choices that is the label area, so
          ;; the choice's own marker is the only cursor beside it; on a row without, the
          ;; label is all there is and may be wider than that area -- ERASE HI SCORES
          ;; runs well past it, and a bar that stopped short looked like a mistake.
          (screen:enqueue screen (%select-bar self column
                                              (if setting
                                                  nil
                                                  (theme:sprite-width
                                                   (%row-label self key))))
                          (%column-x column) (+ y 2) +z-select-box+))
        (screen:enqueue screen (%row-label self key) (%column-x column) y +z-text+)
        ;; The choices, and then the current one again in a colour that says so. Every
        ;; row shows its own value, not just the one under the cursor.
        ;; A row that has replaced its name with a message draws no choices. RESTART
        ;; NEEDED is wider than the label area and runs across them, so the tail of the
        ;; one underneath showed past the end of it.
        (let ((choices (and setting
                            (not (%reporting? self key))
                            (gethash setting (menu-choices self)))))
          (when choices
            (let ((current (%choice-index self setting)))
              (loop for entry across choices
                    for i from 0
                    do (destructuring-bind (value plain blue offset width) entry
                         (declare (ignore value))
                         (let ((x (+ (%column-value-x column) offset)))
                           (screen:enqueue screen (if (and (= i current)
                                                           (not selected?)
                                                           enabled?)
                                                      blue
                                                      plain)
                                           x y +z-text+)
                           ;; On the selected row the marker is the box the original
                           ;; used, so the cursor still reads as the cursor.
                           (when (and (= i current) selected?)
                             (screen:enqueue screen
                                             (gethash width (menu-choice-boxes self))
                                             (1- x) (+ y 2) +z-select-box+)))))))))))
  t)

(defmethod level:render-level ((self menu) screen)
  (let* ((main? (eq (menu-page self) :main))
         (rows (if main? (length (%options self)) +base-main-options+)))
    ;; Backdrop
    (screen:enqueue screen (menu-star-field self) 0 screen:+rows+ +z-star-field+)
    (screen:enqueue screen (menu-background self) 0 screen:+rows+ +z-background+)

    (if main?
        (progn
          ;; The panel behind the option list, sized to the rows on screen rather than
          ;; fixed, so CONTINUE appearing does not leave EXIT hanging off the bottom edge
          ;; on bare starfield.
          (screen:enqueue screen (%main-area-for self)
                          (1- +option-x+) (- screen:+rows+ (- (%y-offset rows) 3))
                          +z-select-area+)
          ;; Skipped rather than assumed: a selection can name a row that is not currently
          ;; on screen, and drawing nothing for a frame beats dying over a cursor.
          (let ((row (%option-row self (menu-selection self))))
            (when row
              (screen:enqueue screen (menu-select-box-main self)
                              +option-x+ (+ (%option-y row rows) 2)
                              +z-select-box+)))
          (loop for (key nil) in (%options self)
                for row from 0
                do (screen:enqueue screen (gethash key (menu-labels self))
                                   +option-x+ (%option-y row rows) +z-text+)))
        (%render-options-page self screen))

    ;; Banner and the bottom scroller. Both sit where the original put them, on every
    ;; page and whatever the option count -- these are the frame the menu lives in, and a
    ;; frame that shifts when you step into the options and back is worse than a tight
    ;; fit. The list and its panel move instead; they are what the extra option is about.
    (let ((banner (menu-banner self)))
      (screen:enqueue screen banner (%centered-x banner)
                      (- screen:+rows+ 3) +z-text+))
    (let ((lb (menu-line-break self)))
      (screen:enqueue screen lb (%centered-x lb)
                      (+ (theme:sprite-height lb) 2) +z-text+)))
  t)

(defmethod level:unload-level ((self menu))
  (audio:stop-all)
  (mapc #'audio:free-sound (menu-tracks self))
  (audio:free-sound (menu-scroll self))
  (audio:free-sound (menu-select self))
  (setf (menu-tracks self) '()
        (menu-scroll self) nil
        (menu-select self) nil
        (menu-theme self) nil)
  t)
