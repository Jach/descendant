(in-package #:com.thejach.descendant.level.score)

;;;; Port of origRef/GameLevels/dsc_level_score.c.
;;;;
;;;; The high score table, scrolling the same way the credits do: a header and ten rows
;;;; laid out once with a running gap, then scrolled from a single moving origin and
;;;; restarted when the last row clears the ceiling.
;;;;
;;;; Scores persist in highscores.txt beside the assets, in the same INI dialect as the
;;;; level configs ([player_one] / name= / score=). When the file is missing the
;;;; original falls back to a built-in table, which we keep verbatim.
;;;;
;;;; NOT YET WIRED: the name-entry mode. The original enters it when the player dies
;;;; with a qualifying score (SCORE_keyPress hijacks the input handler). Reaching this
;;;; screen from the menu always carries a score of 0, so that path is unreachable
;;;; until gameplay lands; QUALIFIES? and the entry plumbing are here ready for it.

(defconstant +exit-delta+ 30 "SCORE_EXIT_DELTA")
(defconstant +ceiling-margin+ 30)
(defconstant +max-scores+ 10 "MAX_HIGH_SCORES")
(defconstant +max-name-length+ 12 "MAX_NAME_LEN")

(defconstant +z-star-field+ 0)
(defconstant +z-background+ 1)
(defconstant +z-roll+ 6)
(defconstant +z-snippet+ 8)
(defconstant +z-banner+ 9)
;;; The panel and the text it carries are on DIFFERENT layers -- RDR_Z_NINE and
;;; RDR_Z_TEN -- which matters here: within one layer the compositor draws the earliest
;;; enqueued last, so an opaque panel queued alongside its own label would bury it.
(defconstant +z-input-area+ 9 "RDR_Z_NINE.")
(defconstant +z-input+ 10 "RDR_Z_TEN, over the panel.")

(defconstant +header-x+ 15)
(defconstant +item-x+ 19)

(defparameter *font-attr-pair* 112 "SCORE_FONT_ATTR")
(defparameter *input-attr-pair* 67 "SCORE_INPUT_ATTR: the prompt's own colours.")

;;; The prompt is three stacked sprites, not one. SCORE_INPUT_AREA is a solid 180x23
;;; block of `RDR_GLYPH_ATTR(182, 0, '-')` that blanks the scrolling roll behind it; the
;;; label and the field are drawn over it in a different pair. All three share an X,
;;; taken from the AREA's width -- so the text is left-aligned to the box rather than
;;; centred on itself, which is what gives the panel its offset look.
(defconstant +input-area-width+ 180)
(defconstant +input-area-height+ 23)
(defconstant +input-area-glyph-char+ (char-code #\-))
(defconstant +input-area-pair+ 182)
(defconstant +input-area-y+ 62 "### Magic!, in the original's own words.")
(defconstant +input-label-y+ 60)
(defconstant +input-field-y+ 50)

(defconstant +input-lift+
  #+android 48
  #-android 0
  "Rows to raise the name-entry block by, on a platform whose keyboard eats the screen.

   Android's landscape keyboard covers roughly the bottom half, and the one this was
   tested against has no preview of its own -- so the player types blind into a field
   they cannot see. Where the block normally sits, rows 58 to 81 counting down from the
   top, is precisely what gets covered.

   Lifting it clear is a guess, but an informed one, and it is the only kind available:
   how tall the keyboard is happens to be the one thing Android will not tell us without
   Java. SDL exposes no inset or IME height, so the alternative to a fixed offset is a
   JNI shim reading WindowInsets, for a screen the player sees once a run.

   Note Y counts UP from the bottom here, as SCREEN:ENQUEUE does, so adding moves it up.")

(defparameter *player-keys*
  '("player_one" "player_two" "player_three" "player_four" "player_five"
    "player_six" "player_seven" "player_eight" "player_nine" "player_ten")
  "g_playerKeys: the section names in highscores.txt, in file order.")

(defparameter *default-scores*
  '(("MARK" . 7000) ("KEVIN" . 6000) ("BRIAN" . 5000) ("FLOOGLE" . 4000)
    ("BOOGER" . 3000) ("VIRUS" . 2000) ("DORKUS" . 1000) ("ROCKO" . 500)
    ("STEVEN" . 100) ("" . 0))
  "The table baked into SCORE_loadLevel, used when highscores.txt is absent.")

(defvar *scores-path* nil
  "Overrides where the table is read from and written to. NIL means the real file beside
   the assets.

   Exists so tests can point somewhere scratch: COMMIT-NAME saves, and a test that earns
   a place would otherwise rewrite the player's actual high scores -- which is exactly
   what happened the first time these tests ran.")

(defun scores-path ()
  (or *scores-path* (paths:user-data-path "highscores.txt")))

(defun erase-scores ()
  "Put the table back to the names baked into SCORE_loadLevel.

   Deleting the file rather than writing the defaults into it: the game already treats a
   missing file as 'use the stock table', so removing it is both the smaller operation
   and the one that leaves nothing behind to go stale if *DEFAULT-SCORES* ever changes.
   Returns true whether the file was there or not -- the table is stock either way, which
   is what the caller asked for."
  (let ((path (scores-path)))
    (handler-case
        (progn (when (probe-file path) (delete-file path))
               t)
      (error (e)
        (warn "Scores: could not erase ~a: ~a" path e)
        nil))))

(defstruct (entry (:constructor make-entry (sprite gap x)))
  sprite (gap 0) (x 0))

(defclass score (level:level)
  ((theme :accessor score-theme :initform nil)
   (background :accessor score-background :initform nil)
   (banner :accessor score-banner :initform nil)
   (star-field :accessor score-star-field :initform nil)
   (star-snippet :accessor score-star-snippet :initform nil)
   (entries :accessor score-entries :initform '())
   (scores :accessor score-scores :initform '())
   (move-pos :accessor score-move-pos :initform -1.0)
   (move-delta :accessor score-move-delta :initform 0.13)
   (music :accessor score-music :initform nil)
   ;; Name entry, when the run that just ended earned a place.
   (input-mode? :accessor score-input-mode? :initform nil)
   (input-name :accessor score-input-name :initform "")
   (input-area :accessor score-input-area :initform nil)
   (input-label :accessor score-input-label :initform nil)
   (input-field :accessor score-input-field :initform nil)
   (font-4 :accessor score-font-4 :initform nil)
   (font-6 :accessor score-font-6 :initform nil)
   (player-score :accessor score-player-score :initform 0
    :documentation "g_levelDt.d_playerScore: what the run that just ended was worth.
                    Reaching this screen from the menu carries a 0, which is why the
                    name-entry path is unreachable from there.")
   (frame :accessor score-frame :initform 0))
  (:default-initargs :name "score"))

(level:register-level :score 'score)

;;; ---------------------------------------------------------------------------
;;; Persistence

(defun read-high-scores (&optional (path (scores-path)))
  "Load the table, falling back to the built-in defaults when the file is absent or
   unreadable. Always returns exactly +max-scores+ entries, sorted high to low."
  (let ((pairs
          (if (probe-file path)
              (handler-case
                  (let ((cfg (config:read-config path)))
                    (loop for key in *player-keys*
                          for name = (config:config-text
                                      cfg (format nil "~a.name" key))
                          for value = (config:config-int
                                       cfg (format nil "~a.score" key) -1)
                          when (and name (>= value 0))
                            collect (cons name value)))
                (error (e)
                  (warn "Score: could not read ~a (~a); using defaults." path e)
                  nil))
              nil)))
    (setf pairs (or pairs (copy-alist *default-scores*)))
    ;; Pad short tables the way the original does, then sort.
    (loop while (< (length pairs) +max-scores+)
          do (setf pairs (append pairs (list (cons " ... " 0)))))
    (subseq (sort (copy-list pairs) #'> :key #'cdr) 0 +max-scores+)))

(defun write-high-scores (scores &optional (path (scores-path)))
  "Persist in the same INI dialect the loader reads."
  (handler-case
      (with-open-file (out path :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
        (loop for key in *player-keys*
              for (name . value) in scores
              do (format out "[ ~a ]~%name=~a~%score=~d~%" key name value))
        path)
    (error (e)
      (warn "Score: could not write ~a: ~a" path e)
      nil)))

(defun qualifies? (scores value)
  "Whether VALUE earns a place in the table.

   The original compares against d_nMinScore, which it tracks as it loads the rows, so
   this is `beats the lowest entry` -- and a table with a 0 in it means any score at all
   gets in. Zero itself never does: reaching this screen from the menu carries a 0, and
   that path must not offer name entry."
  (and (plusp value)
       (> value (cdr (car (last scores))))))

(defun insert-score (scores name value)
  "Return the table with (NAME . VALUE) inserted, truncated to +max-scores+."
  (subseq (sort (cons (cons name value) (copy-list scores)) #'> :key #'cdr)
          0 +max-scores+))

(defun format-row (name value)
  "sprintf(\" :%12s :::%010d:\", name, score) -- 29 characters."
  (format nil " :~12@a :::~10,'0d:" (or name "") value))

(defun rebuild-entries (self)
  "Header, a gap, then the ten rows. Same accumulate-a-gap walk as the credits, and
   rebuilt whole after a name is entered so the new row appears in place."
  ;; No transparency mod. SCORE_FONT_ATTR is GAM_FONT_ATTR(112, 0, 0, 0), the same as the
  ;; controls screen's, so every row paints its own solid pair-112 background and the roll
  ;; reads as blue plates sliding over the planet. With the mod on, only the foreground is
  ;; drawn and the rows sit on whatever happens to be behind them -- which is black.
  (let* ((attr (text:font-attr :pair *font-attr-pair*))
         (header (text:text-sprite (score-font-4 self) "HIGH SCORES" attr))
         (gap (+ (theme:sprite-height header) 3 8))  ; +8 for the SCORE_TYPE_SPACE entry
         (built (list (make-entry header 0 +header-x+))))
    (loop for (name . value) in (score-scores self)
          for sprite = (text:text-sprite (score-font-6 self) (format-row name value) attr)
          do (push (make-entry sprite gap +item-x+) built)
             (setf gap (+ (theme:sprite-height sprite) 3)))
    (setf (score-entries self) (nreverse built))))

;;; ---------------------------------------------------------------------------

(defmethod level:load-level ((self score))
  ;; SCORE_loadLevel's first act: take the run's score and clear it, so backing out to
  ;; the menu and coming here again does not re-offer the same run.
  (setf (score-player-score self) state:*carried-score*
        state:*carried-score* 0)
  (let* ((cfg (config:read-config (paths:config-path "level_score.cfg")))
         (th (theme:read-theme (paths:theme-path "credits.thm")))
         (hud4 (font:read-bft (paths:font-path "dsc_font_hud_04.bft")))
         (hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft")))
         (attr (text:font-attr :pair *font-attr-pair*)))
    (setf (score-theme self) th
          (score-background self)
          (theme:find-sprite th (config:config-text cfg "score.movie_still"
                                                    "credits_bg"))
          (score-banner self)
          (theme:find-sprite th (config:config-text cfg "score.banner" "DSC_logo"))
          (score-move-delta self)
          (config:config-float cfg "score.score_move_delta" 0.13)
          (score-scores self) (read-high-scores))

    (let ((entries (list (field:make-field-entry (char-code #\.) 2 8)
                         (field:make-field-entry (char-code #\Space) 2 92))))
      (setf (score-star-field self)
            (field:make-field screen:+cols+ screen:+rows+ entries)
            (score-star-snippet self)
            (field:make-field screen:+cols+ 10 entries)))

    (setf (score-font-4 self) hud4
          (score-font-6 self) hud6)
    (rebuild-entries self)

    (let ((tracks (config:config-list cfg "score.music_tracks")))
      (when tracks
        (setf (score-music self)
              (audio:load-sound (paths:sound-path (first tracks)) :kind :music))))

    ;; Name entry, if the run that just ended earned a place. The label carries no
    ;; transparency mod, so it paints its own darker background over the panel.
    (setf (score-input-label self)
          (text:text-sprite hud6 "ENTER THE HALL OF FAME"
                            (text:font-attr :pair *input-attr-pair*))
          (score-input-area self) (%input-area-sprite)
          (score-input-name self) "")
    (set-input-mode self (qualifies? (score-scores self) (score-player-score self)))
    t))

;;; ---------------------------------------------------------------------------
;;; Name entry
;;;
;;; The original hijacks the whole input handler while this is up (`g_input.Hijack`), so
;;; the usual keys stop working until a name is committed. We do the same by checking the
;;; flag first in HANDLE-EVENT, which also keeps ESC and SPACE from skipping past the one
;;; screen where the player has something to say.

(defconstant +max-name-length+ 12 "MAX_NAME_LEN")

(defun %input-area-sprite ()
  "The solid panel the prompt sits on. Opaque on purpose: it is what hides the roll
   scrolling behind it."
  (let ((glyphs (make-array (* +input-area-width+ +input-area-height+)
                            :element-type '(unsigned-byte 32)
                            :initial-element (glyph:make-glyph +input-area-glyph-char+
                                                               +input-area-pair+))))
    (theme:make-sprite "Input Area" +input-area-width+ +input-area-height+ glyphs)))

(defparameter *input-field-width* 18
  "Characters of box the name is typed into. Wider than the name it can hold
   (+max-name-length+ - 1 = 11), so the field reads as a box with room in it rather than
   as text that happens to have a background. Centred, so the name grows from the middle.")

(defun %input-field-sprite (self)
  "The typed name in its box. Padded to a fixed width so the box does not grow as you
   type, and centred within it. No transparency mod, so it paints its own darker
   background over the panel."
  (let* ((name (score-input-name self))
         (pad (max 0 (- *input-field-width* (length name))))
         (left (floor pad 2)))
    (text:text-sprite (score-font-6 self)
                      (concatenate 'string
                                   (make-string left :initial-element #\Space)
                                   name
                                   (make-string (- pad left) :initial-element #\Space))
                      (text:font-attr :pair *input-attr-pair*))))

(defun set-input-mode (self on?)
  (setf (score-input-mode? self) (and on? t))
  (when on?
    (setf (score-input-field self) (%input-field-sprite self)))
  ;; A phone has no keyboard until something asks for one, and it stays up until
  ;; something says otherwise -- so the request belongs here, where entry begins and
  ;; ends, rather than at either call site.
  #+android (com.thejach.descendant.touch:text-input (and on? t))
  self)

(defun input-char (self char)
  "One typed character. A-Z, 0-9 and underscore only, upper-cased -- the HUD font has no
   lowercase glyphs, so anything else would render as dots."
  (when (and (score-input-mode? self)
             (< (length (score-input-name self)) (1- +max-name-length+))
             (or (alphanumericp char) (char= char #\_)))
    (setf (score-input-name self)
          (concatenate 'string (score-input-name self) (string (char-upcase char)))
          (score-input-field self) (%input-field-sprite self))
    t))

(defun input-backspace (self)
  (when (and (score-input-mode? self) (plusp (length (score-input-name self))))
    (setf (score-input-name self)
          (subseq (score-input-name self) 0 (1- (length (score-input-name self))))
          (score-input-field self) (%input-field-sprite self))
    t))

(defun commit-name (self)
  "ENTER: insert, rebuild the roll, save, and drop out of input mode.

   Refused on an empty name, as the original refuses -- so the player cannot skip past
   the prompt by mashing enter and lose the entry."
  (let ((name (string-trim " " (score-input-name self))))
    (when (and (score-input-mode? self) (plusp (length name)))
      (setf (score-scores self)
            (insert-score (score-scores self) name (score-player-score self)))
      (rebuild-entries self)
      (set-input-mode self nil)
      (write-high-scores (score-scores self))
      ;; Restart the exit grace period. Committing is an ENTER keydown, and its keyUP
      ;; arrives a moment later -- straight into the handler that leaves for the menu on
      ;; ENTER. Without this you would type your name and be thrown off the screen before
      ;; seeing it in the table. Resetting the frame count also gives the roll its normal
      ;; run-up, so the reward for qualifying is watching it scroll past with you in it.
      (setf (score-frame self) 0)
      t)))

(defmethod level:init-level ((self score))
  (setf (score-move-pos self) -1.0
        (score-frame self) 0)
  (audio:play-music (score-music self))
  t)

(defmethod level:level-colormap ((self score))
  (theme:theme-colormap (score-theme self)))

(defun layout-y (self)
  (let ((y (truncate (score-move-pos self))))
    (loop for e in (score-entries self)
          do (decf y (entry-gap e))
          collect y)))

(defmethod level:update-level ((self score))
  ;; The roll holds still while a name is being entered -- the original's update scrolls
  ;; only in the ELSE of `if (d_inputMode)`. A table sliding about behind the prompt is
  ;; both distracting and misleading, since the row being typed is not in it yet.
  (unless (score-input-mode? self)
    (if (>= (car (last (layout-y self))) (- screen:+rows+ +ceiling-margin+))
        (setf (score-move-pos self) -1.0)
        (incf (score-move-pos self) (score-move-delta self))))
  (incf (score-frame self))
  t)

(defun %typed-char (scancode)
  "Scancode to character for the ranges name entry accepts. A-Z and 1-9 are each
   contiguous in SDL; 0 sits after 9 rather than before 1."
  (let ((letter (- scancode lgame::+sdl-scancode-a+))
        (digit (- scancode lgame::+sdl-scancode-1+)))
    (cond
      ((<= 0 letter 25) (code-char (+ (char-code #\a) letter)))
      ((<= 0 digit 8) (code-char (+ (char-code #\1) digit)))
      ((= scancode lgame::+sdl-scancode-0+) #\0)
      ((= scancode lgame::+sdl-scancode-minus+) #\_))))

(defun %text-input-active? ()
  "Whether SDL is reporting typing as SDL_TEXTINPUT, and so whether key events for the
   same keystrokes are duplicates to be ignored.

   Asked of SDL rather than tracked here, because it is switched from both ends: video
   init turns it on without being asked, and on Android the player can dismiss the
   keyboard with the back button at any moment. It is only ever a question about SDL's
   state, so SDL is the one to ask."
  (plusp (cffi:foreign-funcall "SDL_IsTextInputActive" :int)))

(defmethod level:handle-event ((self score) event)
  ;; Input mode takes the keyboard entirely, as the original's g_input.Hijack does --
  ;; otherwise SPACE and ESC would skip past the one screen where the player has
  ;; something to enter, and typing a name would scroll the roll instead.
  (when (score-input-mode? self)
    (return-from level:handle-event
      (let ((type (lgame.event:event-type event)))
        (cond
          ;; SDL_TEXTINPUT carries characters rather than scancodes, which is the only
          ;; thing an on-screen keyboard can report: there is no physical key, and the
          ;; IME may be a swipe, a prediction or another alphabet entirely. Accepted on
          ;; every platform, not just Android -- SDL starts text input at video init on
          ;; the desktop, so this is the branch an ordinary keyboard goes through too.
          ((= type lgame::+sdl-textinput+)
           ;; SDL_TextInputEvent.text is a fixed char[32], NUL-terminated, and may carry
           ;; more than one character at a time. INPUT-CHAR itself filters to the glyphs
           ;; the HUD font actually has, so anything exotic an IME sends is dropped there
           ;; rather than needing a second opinion here.
           (loop for i from 0 below 32
                 for code = (lgame.event:ref event :text :text i)
                 until (zerop code)
                 do (input-char self (code-char code)))
           t)
          ((= type lgame::+sdl-keydown+)
           (let ((key (lgame.event:key-scancode event)))
             (cond
               ((= key lgame::+sdl-scancode-return+)
                ;; COMMIT-NAME refuses an empty name, as the original does. On a phone
                ;; that refusal is a dead end: the player dismissed the keyboard with the
                ;; back button before typing anything, a tap arrives here as Return, and
                ;; there is no other way to ask for the keyboard back -- the screen simply
                ;; stops responding. So a refused commit re-raises it. Asking when it is
                ;; already up is harmless; SDL_StartTextInput is idempotent.
                (or (commit-name self)
                    #+android
                    (com.thejach.descendant.touch:text-input t))
                t)
               ((= key lgame::+sdl-scancode-backspace+) (input-backspace self) t)
               (t
                ;; Only where there is no text input to do it properly.
                ;;
                ;; A keystroke is reported TWICE whenever text input is active: once as
                ;; a key event, once as SDL_TEXTINPUT. Reading both turns "ok" into
                ;; "ookk". Return and backspace above are safe because they are not text
                ;; and arrive only as keys.
                ;;
                ;; The condition is whether text input is on, not which platform this is
                ;; -- an earlier #-android here was the reason the desktop doubled every
                ;; character. SDL_VideoInit turns text input on everywhere, suppressing
                ;; only the on-screen keyboard, because it "wants to allow text input
                ;; from other mechanisms". So the branch above is the live one on every
                ;; platform, and this is a fallback for having been switched off.
                (unless (%text-input-active?)
                  (let ((char (%typed-char key)))
                    (when char (input-char self char) t)))))))))))

  (when (and (>= (score-frame self) +exit-delta+)
             (= (lgame.event:event-type event) lgame::+sdl-keyup+))
    (let ((key (lgame.event:key-scancode event)))
      (when (or (= key lgame::+sdl-scancode-escape+)
                (= key lgame::+sdl-scancode-space+)
                (= key lgame::+sdl-scancode-return+))
        (level:request-level :menu)
        t))))

(defmethod level:render-level ((self score) screen)
  (screen:enqueue screen (score-star-field self) 0 screen:+rows+ +z-star-field+)
  (screen:enqueue screen (score-background self) 0 screen:+rows+ +z-background+)
  (loop for e in (score-entries self)
        for y in (layout-y self)
        do (screen:enqueue screen (entry-sprite e) (entry-x e) y +z-roll+))
  (screen:enqueue screen (score-star-snippet self) 0 screen:+rows+ +z-snippet+)
  (let ((banner (score-banner self)))
    (screen:enqueue screen banner
                    (ash (- screen:+cols+ (theme:sprite-width banner)) -1)
                    (- screen:+rows+ 3) +z-banner+))
  ;; The prompt. The original gives all three the SAME x -- it reuses the panel's width
  ;; for the label and field too, because their own sprite data has not been fetched at
  ;; that point -- which leaves the text jammed against the panel's left edge. Centring
  ;; each within the panel instead; the panel itself stays where it was.
  (when (score-input-mode? self)
    (flet ((centred (sprite y z)
             (when sprite
               (screen:enqueue screen sprite
                               (- (ash screen:+cols+ -1)
                                  (ash (theme:sprite-width sprite) -1))
                               y z))))
      (centred (score-input-area self) (+ +input-area-y+ +input-lift+) +z-input-area+)
      (centred (score-input-label self) (+ +input-label-y+ +input-lift+) +z-input+)
      (centred (score-input-field self) (+ +input-field-y+ +input-lift+) +z-input+)))
  t)

(defmethod level:unload-level ((self score))
  (audio:stop-all)
  (audio:free-sound (score-music self))
  (setf (score-music self) nil
        (score-theme self) nil)
  t)
