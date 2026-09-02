(in-package #:com.thejach.descendant.collectables)

;;;; Port of origRef/GamePlay/dsc_collectables.c.
;;;;
;;;; Pickups sit still in world space and scroll left with the player's progress. The
;;;; player's collision handler is what applies their effect -- all this module does is
;;;; mark one collected and play the sound. Which power-up a pickup grants comes from
;;;; its NAME, matched in player:apply-collectable.

(defconstant +dead-delta+ -800
  "COLLECTABLE_DEAD_DELTA = -DSC_MAX_DEAD_ZONE.")
(defconstant +z-collectable+ 3 "RDR_Z_FOUR")

(defstruct (definition (:constructor %make-definition))
  (name "" :type string)
  (sprite nil)
  (kind :collectable :type keyword))

(defstruct (collectable (:constructor %make-collectable))
  (definition nil)
  (rect nil :type (or null rect:rect))
  (collider nil)
  (dead? nil :type boolean))

(defstruct (pool (:constructor %make-pool))
  (definitions (make-hash-table :test #'equal) :type hash-table)
  (live '() :type list)
  (world nil)
  (world-x 0 :type fixnum)
  (sound nil)
  (on-collect nil :type (or null function)))

(defun make-pool (&key world sound on-collect)
  (%make-pool :world world :sound sound :on-collect on-collect))

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
                   :kind (bullets:object-type
                          (config:config-int config (key "type") 9))))
            (warn "Collectables: no sprite ~s for ~s, skipping." sprite-name name))))))

(defun definition (pool name) (gethash name (pool-definitions pool)))
(defun live-count (pool) (length (pool-live pool)))

(defun collect (pool c)
  "COLLIDE_hit: only the player can pick something up. The effect itself is the
   player's business; this just retires the pickup."
  (unless (collectable-dead? c)
    (setf (collectable-dead? c) t)
    (audio:play (pool-sound pool))
    (when (pool-on-collect pool)
      (funcall (pool-on-collect pool) (definition-name (collectable-definition c)))))
  c)

(defun create-object (pool name x y)
  "The spawner's entry point."
  (let ((def (definition pool name)))
    (cond
      ((null def) (warn "Collectables: unknown pickup ~s" name) nil)
      (t
       (let* ((sprite (definition-sprite def))
              (rect (rect:make-rect x y (theme:sprite-width sprite)
                                    (theme:sprite-height sprite)))
              (c (%make-collectable :definition def :rect rect)))
         ;; No offscreen handler, deliberately: the original sets
         ;; `collectDtP->d_coll.d_collide.offscreen = 0` where enemies and projectiles
         ;; both install one. A pickup is therefore only reaped by the -800 check in
         ;; UPDATE, so it lingers far behind the left edge and the player can turn back
         ;; for one they missed. Installing a handler here kills it the moment it
         ;; leaves the screen, which quietly removes that whole bit of play.
         (setf (collectable-collider c)
               (collision:make-collider rect :collectable
                                        :data c
                                        :on-hit (lambda (self other)
                                                  (declare (ignore self))
                                                  (when (eq (collision:collider-kind other)
                                                            :player)
                                                    (collect pool c)))))
         (when (pool-world pool)
           (collision:add (pool-world pool) (collectable-collider c)))
         (push c (pool-live pool))
         c)))))

(defun %reap (pool c)
  (when (and (pool-world pool) (collectable-collider c))
    (collision:remove-collider (pool-world pool) (collectable-collider c)))
  (setf (collectable-collider c) nil))

(defun update (pool world-x)
  "Scroll with the player's progress and reap the collected and the departed.

   Faithful quirk: the original wraps this entire loop in `if (delta != 0)`, so nothing
   is reaped while the player is standing still -- a pickup collected on the spot stays
   on screen, already marked dead, until the player moves again. Reproduced; see
   PLAN.md section 7."
  (let ((delta (- world-x (pool-world-x pool))))
    (unless (zerop delta)
      (setf (pool-live pool)
            (remove-if (lambda (c)
                         (cond
                           ((collectable-dead? c) (%reap pool c) t)
                           (t
                            (let ((r (collectable-rect c)))
                              (if (pool-world pool)
                                  (collision:move (pool-world pool)
                                                  (collectable-collider c) (- delta) 0)
                                  (rect:move-ip r (- delta) 0))
                              (when (< (rect:rect-x r) +dead-delta+)
                                (%reap pool c)
                                t)))))
                       (pool-live pool))))
    (setf (pool-world-x pool) world-x))
  (length (pool-live pool)))

(defun render (pool screen)
  "Everything in the list is drawn, including anything already collected but not yet
   reaped -- which is what makes the standing-still quirk visible."
  (dolist (c (pool-live pool) pool)
    (let ((r (collectable-rect c)))
      (when r
        (screen:enqueue screen (definition-sprite (collectable-definition c))
                        (rect:rect-x r) (rect:rect-y r) +z-collectable+)))))

(defun clear (pool)
  (dolist (c (pool-live pool)) (%reap pool c))
  (setf (pool-live pool) '())
  pool)
