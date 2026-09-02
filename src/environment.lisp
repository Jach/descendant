(in-package #:com.thejach.descendant.environment)

;;;; Port of origRef/GamePlay/dsc_environment.c.
;;;;
;;;; Two quite different things live here:
;;;;
;;;;   *ambient fields* -- the ground strip, the optional ceiling strip, and the
;;;;   background starfield. These are full-width randomised fields generated once at
;;;;   load, drawn at the bottom layer, and never move. They also define the level's
;;;;   playable band: the ground's height becomes the floor, and the ceiling's height is
;;;;   subtracted from the top. That is what dsc_getFloor/dsc_getCieling report, and
;;;;   what the spawner needs to place things.
;;;;
;;;;   *scenery* -- buildings, trees and mountains, spawned by the spawner and scrolled
;;;;   left as the player advances. They sit on three parallax layers, each moving at
;;;;   0.85x the speed of the one in front, which is what gives the horizon depth.
;;;;
;;;; Scrolling is driven by the player's velocity rather than a fixed rate, and the
;;;; whole system freezes while the player is dead or has beaten a boss.

(defconstant +parallax-factor+ 0.85 "ENV_PARALLAX_FACTOR")
(defconstant +dead-delta+ -800
  "ENVIRONMENT_DEAD_DELTA = -DSC_MAX_DEAD_ZONE. Scenery is dropped once this far left.")

;;; Render levels, front to back, and their z-layers (RDR_Z_FOUR/THREE/TWO).
(defparameter *layer-z* '((:fg-01 . 3) (:bg-01 . 2) (:bg-02 . 1)))
(defparameter *layers* '(:fg-01 :bg-01 :bg-02))
(defconstant +z-ambient+ 0 "RDR_Z_ONE: below everything.")

(defun render-level (n)
  (case n (0 :fg-01) (1 :bg-01) (2 :bg-02) (t :fg-01)))

(defstruct (definition (:constructor %make-definition))
  (name "" :type string)
  (sprite nil)
  (kind :no-collision :type keyword)
  (layer :fg-01 :type keyword))

(defstruct (scenery (:constructor make-scenery (definition x y)))
  (definition nil)
  (x 0 :type fixnum)
  (y 0 :type fixnum))

(defstruct (environment (:constructor %make-environment))
  (definitions (make-hash-table :test #'equal) :type hash-table)
  ;; layer keyword -> list of scenery
  (layers (make-hash-table :test #'eq) :type hash-table)
  ;; layer keyword -> accumulated float scroll, and the integer part last applied
  (scroll (make-hash-table :test #'eq) :type hash-table)
  (scrolled (make-hash-table :test #'eq) :type hash-table)
  (ground nil)
  (ceiling nil)
  (background nil)
  (ground-y 0 :type fixnum)
  (ceiling-y 0 :type fixnum)
  (ground-height 0 :type fixnum)
  (ceiling-height 0 :type fixnum))

(defun floor-y (env) (environment-ground-y env))
(defun ceiling-y (env) (environment-ceiling-y env))

;;; ---------------------------------------------------------------------------
;;; Loading

(defun %tokens (string)
  "Split on commas and trim, dropping empties -- which is what strtok does, since it
   treats a run of delimiters as one."
  (when string
    (remove ""
            (loop with start = 0
                  for pos = (position #\, string :start start)
                  collect (string-trim '(#\Space #\Tab) (subseq string start pos))
                  while pos
                  do (setf start (1+ pos)))
            :test #'string=)))

(defun %parse-field-spec (chars colors freqs)
  "One ambient field, from three parallel comma-separated lists: a character, a colour
   pair and a frequency per entry.

   The character list decides how many entries there are -- processCharList returns
   nAttr and the other two are read only that far -- so a colour or frequency without a
   character of its own is ignored, and a character without them gets zero.

   `env_ground_color = 004` is one entry of 4, not three of 0, 0 and 4: these are whole
   numbers per comma group, and a bare string of digits is a single number."
  (let ((chars (%tokens chars))
        (colors (%tokens colors))
        (freqs (%tokens freqs)))
    (flet ((number-at (list i)
             (let ((token (nth i list)))
               (or (and token (parse-integer token :junk-allowed t)) 0))))
      (loop for token in chars
            for i from 0
            collect (field:make-field-entry (char-code (char token 0))
                                            (number-at colors i)
                                            (number-at freqs i))))))

(defun %ambient-entries (config prefix)
  "Read one ambient field's chars/color/freq trio. Returns NIL when the field is unused
   (no characters configured), which is how crash_site declares 'no ceiling'."
  (flet ((text (suffix)
           (config:config-text config
                               (format nil "level_data.env_~a_~a" prefix suffix))))
    (%parse-field-spec (text "chars") (text "color") (text "freq"))))

(defun load-definitions (env config theme names)
  (dolist (name names env)
    (flet ((key (suffix) (format nil "~a.~a" name suffix)))
      (let* ((sprite-name (config:config-text config (key "sprite")))
             (sprite (and sprite-name (theme:find-sprite theme sprite-name))))
        (if sprite
            (setf (gethash name (environment-definitions env))
                  (%make-definition
                   :name name
                   :sprite sprite
                   :kind (bullets:object-type (config:config-int config (key "type") 0))
                   :layer (render-level (config:config-int config (key "rdr_level") 0))))
            (warn "Environment: no sprite ~s for ~s, skipping." sprite-name name))))))

(defun make-environment (config theme &key (random-state *random-state*))
  "Build the ambient fields and the scenery definitions.

   Field heights come from config and define the playable band: the ground occupies the
   bottom `env_ground_height` rows, the ceiling the top `env_cieling_height`, and the
   background fills what is left minus `env_bg_field_offset`."
  (let* ((env (%make-environment))
         (ground-height (config:config-int config "level_data.env_ground_height" 0))
         (ceiling-height (config:config-int config "level_data.env_cieling_height" 0))
         (bg-offset (config:config-int config "level_data.env_bg_field_offset" 0))
         (bg-height screen:+rows+))
    (dolist (layer *layers*)
      (setf (gethash layer (environment-layers env)) '()
            (gethash layer (environment-scroll env)) 0.0
            (gethash layer (environment-scrolled env)) 0))

    (setf (environment-ceiling-y env) screen:+rows+
          (environment-ground-y env) 0
          (environment-ground-height env) ground-height
          (environment-ceiling-height env) ceiling-height)

    (when (plusp ground-height)
      (let ((entries (%ambient-entries config "ground")))
        (when entries
          (setf (environment-ground env)
                (field:make-field screen:+cols+ ground-height entries
                                  :random-state random-state))))
      (decf bg-height ground-height)
      (setf (environment-ground-y env) ground-height))

    (when (plusp ceiling-height)
      (let ((entries (%ambient-entries config "cieling")))
        (when entries
          (setf (environment-ceiling env)
                (field:make-field screen:+cols+ ceiling-height entries
                                  :random-state random-state))))
      (decf bg-height ceiling-height)
      (decf (environment-ceiling-y env) ceiling-height))

    (let ((entries (%ambient-entries config "bg_field"))
          (height (- bg-height bg-offset)))
      (when (and entries (plusp height))
        (setf (environment-background env)
              (field:make-field screen:+cols+ height entries
                                :random-state random-state))))

    (load-definitions env config theme
                      (config:config-list config "level_data.environment_list"))
    env))

;;; ---------------------------------------------------------------------------

(defun create-object (env name x y)
  "The spawner's entry point for scenery."
  (let ((def (gethash name (environment-definitions env))))
    (cond
      ((null def) (warn "Environment: unknown object ~s" name) nil)
      (t
       (let ((s (make-scenery def x y)))
         (push s (gethash (definition-layer def) (environment-layers env)))
         s)))))

(defun scenery-count (env)
  (loop for layer in *layers* sum (length (gethash layer (environment-layers env)))))

(defun update (env velocity-x &key (player-status :play) (time-step 0.016))
  "Scroll each layer by the player's velocity, slowing by the parallax factor with
   depth, and drop anything that has passed far enough off the left edge.

   Freezes entirely while the player is dead or has just beaten a boss -- the original
   returns early from update in those states, so the world holds still."
  (when (member player-status '(:dead :boss-defeated))
    (return-from update env))
  (let ((velocity (* velocity-x time-step)))
    (dolist (layer *layers* env)
      (incf (gethash layer (environment-scroll env)) velocity)
      (let* ((world-x (truncate (gethash layer (environment-scroll env))))
             (delta (- world-x (gethash layer (environment-scrolled env)))))
        (unless (zerop delta)
          (setf (gethash layer (environment-layers env))
                (remove-if (lambda (s)
                             (decf (scenery-x s) delta)
                             (< (scenery-x s) +dead-delta+))
                           (gethash layer (environment-layers env)))))
        (setf (gethash layer (environment-scrolled env)) world-x))
      (setf velocity (* velocity +parallax-factor+)))))

(defun render (env screen)
  "Ambient fields first at the bottom layer, then the three scenery layers back to
   front by z-order."
  (when (environment-background env)
    (screen:enqueue screen (environment-background env) 0
                    (environment-ceiling-y env) +z-ambient+))
  (when (environment-ground env)
    (screen:enqueue screen (environment-ground env) 0
                    (environment-ground-height env) +z-ambient+))
  (when (environment-ceiling env)
    (screen:enqueue screen (environment-ceiling env) 0 screen:+rows+ +z-ambient+))
  (dolist (layer *layers* env)
    (let ((z (cdr (assoc layer *layer-z*))))
      (dolist (s (gethash layer (environment-layers env)))
        (screen:enqueue screen (definition-sprite (scenery-definition s))
                        (scenery-x s) (scenery-y s) z)))))

(defun clear (env)
  (dolist (layer *layers* env)
    (setf (gethash layer (environment-layers env)) '()
          (gethash layer (environment-scroll env)) 0.0
          (gethash layer (environment-scrolled env)) 0)))
