(in-package #:com.thejach.descendant.effects)

;;;; Port of origRef/GamePlay/dsc_effects.c.
;;;;
;;;; Frame-animated one-shot sprites -- explosions, in practice. Each definition names a
;;;; sprite, how many times to loop it, and how many ticks each frame holds for. When
;;;; the last loop finishes the effect retires itself.
;;;;
;;;; From level_crash_site.cfg:
;;;;   [explosion] sprite = player_explode, anim_loops = 1, anim_delta = 5

(defconstant +z-effect+ 8 "RDR_Z_NINE, above the action.")

(defstruct (definition (:constructor %make-definition))
  (name "" :type string)
  (sprite nil)
  (kind :no-collision :type keyword)
  (loops 1 :type fixnum)
  (delta 1 :type fixnum))

(defstruct (effect (:constructor %make-effect))
  (definition nil)
  (x 0 :type fixnum)
  (y 0 :type fixnum)
  (frame 0 :type fixnum)
  (loops-left 1 :type fixnum)
  (spawn-frame 0 :type fixnum)
  (dead? nil :type boolean))

(defstruct (pool (:constructor %make-pool))
  (definitions (make-hash-table :test #'equal) :type hash-table)
  (live '() :type list))

(defun make-pool () (%make-pool))

(defun load-definitions (pool config theme names)
  (dolist (name names pool)
    (flet ((key (suffix) (format nil "~a.~a" name suffix)))
      (let* ((sprite-name (config:config-text config (key "sprite")))
             (sprite (and sprite-name (theme:find-sprite theme sprite-name))))
        (if sprite
            (setf (gethash name (pool-definitions pool))
                  (%make-definition
                   :name name
                   :sprite sprite
                   :kind (bullets:object-type (config:config-int config (key "type") 0))
                   :loops (max 1 (config:config-int config (key "anim_loops") 1))
                   :delta (max 1 (config:config-int config (key "anim_delta") 1))))
            (warn "Effects: no sprite ~s for ~s, skipping." sprite-name name))))))

(defun definition (pool name) (gethash name (pool-definitions pool)))
(defun live-count (pool) (length (pool-live pool)))

(defun create-object (pool name x y &optional (frame 0) centred?)
  "Spawn an effect with its sprite's top-left corner at (X, Y), as the original does --
   `d_rdr.d_X = posX; d_rdr.d_Y = posY`, no adjustment for the sprite's size.

   CENTRED? puts the sprite's middle there instead. Callers that have a thing's centre --
   an enemy that just died, say -- want that, and passing a centre to the corner-anchored
   version lands the explosion down and to the right of the wreck by half a sprite. The
   bigger the sprite the more obvious it is, which is why ground turrets showed it worst."
  (let ((def (definition pool name)))
    (cond
      ((null def) (warn "Effects: unknown effect ~s" name) nil)
      (t
       (let* ((sprite (definition-sprite def))
              ;; Y counts up and the sprite hangs DOWN from its Y, so centring adds half
              ;; the height rather than subtracting it.
              (x (if centred? (- x (floor (theme:sprite-width sprite) 2)) x))
              (y (if centred? (+ y (floor (theme:sprite-height sprite) 2)) y))
              (e (%make-effect :definition def :x x :y y
                               :loops-left (definition-loops def)
                               :spawn-frame frame)))
         (push e (pool-live pool))
         e)))))

(defun update (pool frame)
  "Advance animations. A frame only steps every `anim_delta` ticks, and the effect is
   skipped entirely on the tick it spawned -- the original compares against the spawn
   frame first, so a new effect always shows frame 0 for at least one tick."
  (setf (pool-live pool)
        (remove-if
         (lambda (e)
           (cond
             ((effect-dead? e) t)
             ((= (effect-spawn-frame e) frame) nil)
             (t
              (let ((def (effect-definition e)))
                (when (zerop (mod (- frame (effect-spawn-frame e))
                                  (definition-delta def)))
                  (incf (effect-frame e))
                  (when (>= (effect-frame e) (theme:sprite-frames (definition-sprite def)))
                    (decf (effect-loops-left e))
                    (if (zerop (effect-loops-left e))
                        (setf (effect-dead? e) t)
                        (setf (effect-frame e) 0))))
                (effect-dead? e)))))
         (pool-live pool)))
  (length (pool-live pool)))

(defun render (pool screen)
  (dolist (e (pool-live pool) pool)
    (let ((def (effect-definition e)))
      (screen:enqueue screen (definition-sprite def)
                      (effect-x e) (effect-y e) +z-effect+
                      (min (effect-frame e)
                           (1- (theme:sprite-frames (definition-sprite def))))))))

(defun clear (pool)
  (setf (pool-live pool) '())
  pool)
