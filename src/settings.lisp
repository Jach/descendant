(in-package #:com.thejach.descendant.settings)

;;;; ADDED, not ported. The original had no persistent settings at all: the options screen
;;;; wrote into g_dscState for the session and level_menu.cfg supplied the defaults, so
;;;; every launch started from the config file again.
;;;;
;;;; Everything the options screen can change lives here rather than on the menu object,
;;;; for two reasons. The menu is rebuilt from scratch every time it is entered, so it is
;;;; the wrong owner for anything that has to outlive it; and most of these are read far
;;;; from the menu -- the player wants auto-fire, the game level wants show-HUD, the
;;;; window wants fullscreen.
;;;;
;;;; The file is a flat `key = value` list beside the high scores, same shape as the
;;;; shipped .cfg files, so it can be read with the same eyes. A missing file, a missing
;;;; key, or a value out of range all fall back to the default rather than failing: this
;;;; is a preferences file, and a player who hand-edits it into nonsense should get the
;;;; game, not a backtrace.

(defparameter *file-name* "options.ini"
  "Beside highscores.txt in the assets directory -- the two are the same kind of thing,
   state that belongs to the installation rather than to the game.")

(defvar *path* nil
  "Overrides where settings are read from and written to. NIL means the real file.
   Exists so tests can point somewhere scratch, as SCORE:*SCORES-PATH* does.")

(defun settings-path ()
  (or *path* (paths:user-data-path *file-name*)))

;;; ---------------------------------------------------------------------------
;;; The settings themselves

(defconstant +max-volume+ 5
  "Volume runs 0 to 5. The original had five steps shown as 1 to 5 and mapped them to a
   tenth through a half; the added 0 is silence, which the shipped game could not be
   asked for -- the quietest it would go was a tenth.")

(defun volume-fraction (index)
  "A volume step as the fraction AUDIO wants. Step N is N tenths, and 0 is off."
  (if (plusp index) (/ index 10.0) 0.0))

(defstruct (setting (:constructor make-setting (key name default kind
                                                &key range deployed)))
  (key nil)
  (name "" :type string)
  (default nil)
  ;; What a deployed build starts with when it differs, and :SAME when it does not.
  ;; A checkout wants a window it can put a REPL beside and the renderer that is easiest
  ;; to reason about; somebody handed the game wants it filling the screen and fast.
  (deployed :same)
  ;; :integer, :boolean, or :choice for a fixed set of keywords. Booleans are written as
  ;; ON and OFF, which is what the screen shows, so the file reads the way the menu looks.
  (kind :integer :type keyword)
  ;; A (low . high) pair for :integer, a list of the allowed keywords for :choice.
  (range nil))

(defparameter *renderer-labels*
  '((:slow . "SLO") (:fast . "FAST"))
  "How the renderer choice reads on screen. SLO is the cell rasteriser the game has
   always used; FAST is the GL path, which does not exist yet and is offered so the
   switch and its restart notice are in place when it does.")

(defparameter *settings*
  (list (make-setting :difficulty "difficulty" 2 :integer :range '(1 . 3))
        (make-setting :music-volume "music_volume" 3 :integer
                      :range (cons 0 +max-volume+))
        (make-setting :effects-volume "effects_volume" 1 :integer
                      :range (cons 0 +max-volume+))
        (make-setting :fullscreen "fullscreen" nil :boolean :deployed t)
        (make-setting :auto-fire "auto_fire" nil :boolean)
        (make-setting :show-hud "show_hud" t :boolean)
        (make-setting :renderer "renderer" :slow :choice
                      :range '(:slow :fast) :deployed :fast))
  "Every persisted setting, in the order they are written to the file.

   The volume defaults are the shipped ones: level_menu.cfg asks for 0.3 music and 0.1
   effects, which on this scale are 3 and 1.")

(defvar *values* (make-hash-table :test #'eq))

(defun setting (key)
  (or (find key *settings* :key #'setting-key)
      (error "Settings: no such setting ~s" key)))

(defun default (key)
  "What KEY starts as, which is not the same question in a checkout and in a build
   somebody was handed. Falls back to the single default when a setting has no separate
   deployed one, which is most of them."
  (let ((s (setting key)))
    (if (or (paths:local-dev?) (eq :same (setting-deployed s)))
        (setting-default s)
        (setting-deployed s))))

(defun value (key)
  (multiple-value-bind (v present?) (gethash key *values*)
    (if present? v (default key))))

(defun (setf value) (new key)
  (setf (gethash key *values*) new))

(defun reset ()
  "Back to defaults, without touching the file."
  (clrhash *values*)
  (values))

(defun booleanp (key) (eq :boolean (setting-kind (setting key))))

(defun clamp-to-range (key n)
  (let ((range (setting-range (setting key))))
    (if (consp (cdr range))
        n                                       ; a :choice, nothing to clamp between
        (max (car range) (min (cdr range) n)))))

(defun choice-values (key)
  "The values a setting may take, in the order the screen offers them."
  (let ((setting (setting key)))
    (ecase (setting-kind setting)
      (:boolean '(t nil))
      (:choice (setting-range setting))
      (:integer (loop for n from (car (setting-range setting))
                        to (cdr (setting-range setting))
                      collect n)))))

(defun choice-label (key value)
  (ecase (setting-kind (setting key))
    (:boolean (if value "ON" "OFF"))
    (:choice (or (cdr (assoc value *renderer-labels*)) (princ-to-string value)))
    (:integer (princ-to-string value))))

(defun needs-restart? (key)
  "Whether changing this takes effect only on a fresh start. The renderer is chosen when
   the window and its SDL renderer are created, and swapping it means building both
   again -- which would drop every texture the running game is holding."
  (eq key :renderer))

;;; ---------------------------------------------------------------------------
;;; Acting on a change
;;;
;;; Some settings need something done to SDL when they change -- fullscreen and the
;;; volumes do -- and the options screen is the wrong place to know about that. It is also
;;; the wrong place to be able to: the menu is compiled long before the entry point, so it
;;; cannot name anything the entry point owns.
;;;
;;; So the dependency is inverted. Whoever owns the window registers a function here, and
;;; the menu asks for the change to be applied without knowing who will do it. Nothing is
;;; registered in a test run, which is exactly right -- there is no window to change.

(defvar *hooks* (make-hash-table :test #'eq))

(defun on-change (key function)
  "Call FUNCTION with the new value whenever KEY is changed through APPLY-CHANGE."
  (setf (gethash key *hooks*) function))

(defun apply-change (key)
  (let ((hook (gethash key *hooks*)))
    (when hook (funcall hook (value key)))))

(defun apply-all ()
  (dolist (s *settings*) (apply-change (setting-key s))))

;;; ---------------------------------------------------------------------------
;;; Reading and writing

(defun %parse (setting text)
  "TEXT to a value, or NIL if it is not one this setting would accept."
  (let ((text (string-trim '(#\Space #\Tab #\Return) text)))
    (ecase (setting-kind setting)
      (:boolean (cond ((string-equal text "on") t)
                      ((string-equal text "off") nil)
                      (t :invalid)))
      (:choice (or (find text (setting-range setting)
                         :test (lambda (a b) (string-equal a (symbol-name b))))
                   :invalid))
      (:integer (let ((n (parse-integer text :junk-allowed t)))
                  (if (and n (let ((range (setting-range setting)))
                               (or (null range) (<= (car range) n (cdr range)))))
                      n
                      :invalid))))))

(defun %format (setting value)
  (ecase (setting-kind setting)
    (:boolean (if value "on" "off"))
    (:choice (string-downcase (symbol-name value)))
    (:integer (princ-to-string value))))

(defun %apply-line (line)
  "Apply one `key = value` line. Returns the setting's key if it took, NIL if the line is
   blank, a comment, an unknown key, or a value this setting would not accept."
  (let* ((line (subseq line 0 (position #\# line)))
         (eq-pos (position #\= line)))
    (when eq-pos
      (let* ((name (string-trim '(#\Space #\Tab) (subseq line 0 eq-pos)))
             (text (subseq line (1+ eq-pos)))
             (setting (find name *settings* :key #'setting-name :test #'string-equal)))
        (when setting
          (let ((v (%parse setting text)))
            (unless (eq v :invalid)
              (setf (value (setting-key setting)) v)
              (setting-key setting))))))))

(defun load-settings (&optional (path (settings-path)))
  "Read the file over the defaults. Returns the keys that were actually found, so a
   caller can tell a fresh install from a corrupt file if it cares.

   Anything unreadable is skipped rather than signalled -- see the file header."
  (let ((found '()))
    (when (probe-file path)
      (handler-case
          (with-open-file (in path :direction :input :external-format :latin-1)
            (loop for line = (read-line in nil nil)
                  while line
                  ;; Guarded per line, not per file: one unreadable entry must not cost
                  ;; the reader everything written after it.
                  do (handler-case
                         (let ((key (%apply-line line)))
                           (when key (push key found)))
                       (error (e)
                         (warn "Settings: ignoring ~s in ~a: ~a" line path e)))))
        (error (e)
          (warn "Settings: could not read ~a: ~a" path e))))
    (nreverse found)))

(defun save-settings (&optional (path (settings-path)))
  "Write every setting, whether or not it has been changed, so the file is always a
   complete picture of what the game is running with."
  (handler-case
      (with-open-file (out path :direction :output :if-exists :supersede
                                :if-does-not-exist :create :external-format :latin-1)
        (format out "# The Descendant -- options. Written by the game; safe to delete.~%")
        (dolist (s *settings*)
          (format out "~a = ~a~%" (setting-name s)
                  (%format s (value (setting-key s)))))
        t)
    (error (e)
      (warn "Settings: could not write ~a: ~a" path e)
      nil)))
