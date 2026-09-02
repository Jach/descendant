(in-package #:com.thejach.descendant.bullets)

;;;; Port of origRef/GamePlay/dsc_bullets_bombs.c.
;;;;
;;;; Two kinds of projectile share one pool:
;;;;
;;;;   *linear*  a bullet fired at an angle. Velocity is set once and never changes;
;;;;             the original does this by setting acceleration from the angle at a
;;;;             magic speed of 10000 with dt 0.016, then calling calcWorldVelocity
;;;;             with a drag of 1.0 -- which, given the two-register integrator, just
;;;;             copies acceleration into velocity. So the bullet travels 2.56 cells
;;;;             per tick along its angle, forever.
;;;;
;;;;   *spline*  a bomb following a Catmull-Rom path through 13 knots. Each tick asks
;;;;             the spline for its next point and moves there.
;;;;
;;;; Both die on leaving the world, and on hitting anything that is not on their own
;;;; side. Projectiles pass through each other and through collectables.

(defconstant +bullet-speed+ 10000.0 "The original's '### Magic!!!!!' acceleration.")
(defconstant +bullet-dt+ 0.016 "Used when setting that acceleration, not the frame dt.")
(defconstant +z-projectile+ 3 "RDR_Z_FOUR")

;;; Deliberate deviation: no spline pool.
;;;
;;; The original keeps 1000 pre-allocated splines and marks a bomb dead on the spot if
;;; none is free -- a way of avoiding malloc mid-frame in C. We allocate a spline per
;;; bomb and let the GC have it. Two reasons: reproducing an allocation-failure path is
;;; meaningless under a GC, and cl-catmull-rom-spline exports no way to clear a spline's
;;; knots for reuse anyway (RESET only rewinds traversal), so pooling would mean
;;; reaching into its internals. The projectile pool itself is kept, since that one
;;; bounds live objects rather than working around allocation.

(defparameter *max-projectiles* 512
  "level_data.bombs_bullets_max in the shipped configs. The original allocates 1<<18
   slots regardless and caps the live count by the free list.")

(defstruct (definition (:constructor make-definition (name sprite kind)))
  (name "" :type string)
  (sprite nil)
  (kind :none :type keyword))

(defstruct (projectile (:constructor %make-projectile))
  (definition nil)
  (rect nil :type (or null rect:rect))
  (collider nil)
  (move (movement:make-movement) :type movement:movement)
  (spline nil)
  (dead? nil :type boolean))

(defstruct (pool (:constructor %make-pool))
  (definitions (make-hash-table :test #'equal) :type hash-table)
  (live '() :type list)
  (free '() :type list)
  (world nil))

;;; The .cfg `type` numbers, from DSCObjectType in dsc_defines.h.
(defparameter *object-types*
  '((0 . :no-collision) (1 . :player) (2 . :player-bullet) (3 . :player-bomb)
    (4 . :enemy-ship) (5 . :enemy-turret) (6 . :enemy-bullet) (7 . :enemy-bomb)
    (8 . :building) (9 . :collectable) (10 . :tree) (11 . :water)
    (12 . :mountain) (13 . :god) (14 . :enemy-boss) (15 . :enemy-midboss)))

(defun object-type (n)
  (or (cdr (assoc n *object-types*)) :no-collision))

(defun make-pool (&key world (max *max-projectiles*))
  "Pre-allocate the projectile slots, as the original does at load time, so that firing
   never has to grow anything."
  (let ((p (%make-pool :world world)))
    (setf (pool-free p) (loop repeat max collect (%make-projectile)))
    p))

(defun load-definitions (pool config theme names)
  "Read each `[name] sprite= type=` section, as loadTheme does."
  (dolist (name names pool)
    (let* ((sprite-name (config:config-text config (format nil "~a.sprite" name)))
           (sprite (and sprite-name (theme:find-sprite theme sprite-name)))
           (kind (object-type (config:config-int config (format nil "~a.type" name) 0))))
      (if sprite
          (setf (gethash name (pool-definitions pool))
                (make-definition name sprite kind))
          (warn "Bullets: no sprite ~s for ~s, skipping." sprite-name name)))))

(defun definition (pool name)
  (gethash name (pool-definitions pool)))

(defun live-count (pool) (length (pool-live pool)))

;;; ---------------------------------------------------------------------------
;;; Collision

(defparameter *pass-through*
  '(:no-collision :player-bullet :player-bomb :enemy-bullet :enemy-bomb :collectable)
  "COLLIDE_hit ignores these outright, so projectiles never stop each other and never
   stop on a collectable.")

(defparameter *enemy-kinds*
  '(:enemy-ship :enemy-turret :enemy-midboss :enemy-boss))

(defun should-die? (own-kind other-kind)
  "A projectile dies on anything but its own side. Player shots survive touching the
   player; enemy shots survive touching enemies."
  (cond
    ((member other-kind *pass-through*) nil)
    ((member own-kind '(:player-bullet :player-bomb)) (not (eq other-kind :player)))
    ((member own-kind '(:enemy-bullet :enemy-bomb)) (not (member other-kind *enemy-kinds*)))
    (t nil)))

(defun hit (projectile other-kind)
  (when (should-die? (definition-kind (projectile-definition projectile)) other-kind)
    (setf (projectile-dead? projectile) t))
  projectile)

;;; ---------------------------------------------------------------------------
;;; Spawning

(defun %acquire (pool)
  (pop (pool-free pool)))

(defun %attach (pool p x y)
  (let* ((sprite (definition-sprite (projectile-definition p)))
         (rect (rect:make-rect x y (theme:sprite-width sprite)
                               (theme:sprite-height sprite))))
    (setf (projectile-rect p) rect
          (projectile-dead? p) nil
          (projectile-collider p)
          (collision:make-collider rect (definition-kind (projectile-definition p))
                                   :data p
                                   :on-hit (lambda (self other)
                                             (declare (ignore self))
                                             (hit p (collision:collider-kind other)))
                                   :on-offscreen (lambda (self)
                                                   (declare (ignore self))
                                                   (setf (projectile-dead? p) t))))
    (when (pool-world pool)
      (collision:add (pool-world pool) (projectile-collider p)))
    (push p (pool-live pool))
    p))

(defun fire (pool name direction x y)
  "createObject: a bullet travelling forever along DIRECTION."
  (let ((def (definition pool name)))
    (cond
      ((null def) (warn "Bullets: unknown projectile ~s" name) nil)
      ((null (pool-free pool)) nil)             ; pool exhausted: silently drop
      (t
       (let ((p (%acquire pool)))
         (setf (projectile-definition p) def
               (projectile-spline p) nil)
         (movement:reset (projectile-move p))
         (let ((m (projectile-move p)))
           (setf (movement:movement-world-x m) (float x)
                 (movement:movement-world-y m) (float y))
           ;; Drag of 1.0 through the two-register integrator copies acceleration
           ;; straight into velocity, giving a constant-speed bullet.
           (movement:set-acceleration m direction +bullet-speed+ +bullet-dt+)
           (movement:calc-world-velocity m 1.0))
         (%attach pool p x y))))))

(defun fire-spline (pool name points speed)
  "createSplineObject: a bomb following POINTS, a list of (x . y) knots.

   SPEED is the spline's per-step delta-t (0.135 for player bombs), so a larger value
   traverses the arc faster and in coarser jumps."
  (let ((def (definition pool name)))
    (cond
      ((null def) (warn "Bullets: unknown projectile ~s" name) nil)
      ((null (pool-free pool)) nil)
      (t
       (let* ((p (%acquire pool))
              (first-point (first points))
              (x (truncate (car first-point)))
              (y (truncate (cdr first-point)))
              ;; A spline advances by DT per tick rather than by a velocity, so it is
              ;; slowed by dividing the parameter -- and comes out smoother for it, since
              ;; the arc is simply sampled more finely. The player's bombs are exempt for
              ;; the same reason their bullets are.
              (player? (and (not *slow-player-shots?*)
                            (member (definition-kind def) *player-kinds*)))
              (spline (make-instance 'spline:spline
                                     :dt (if player?
                                             speed
                                             (/ speed (float (state:rate-scale) 1.0))))))
         (setf (projectile-definition p) def)
         (movement:reset (projectile-move p))
         (dolist (pt points)
           (spline:add-knot spline (vector (car pt) (cdr pt))))
         (setf (projectile-spline p) spline)
         (%attach pool p x y))))))

;;; ---------------------------------------------------------------------------
;;; Update

(defun %reap (pool p)
  (setf (projectile-spline p) nil)          ; the GC takes it from here
  (when (and (pool-world pool) (projectile-collider p))
    (collision:remove-collider (pool-world pool) (projectile-collider p)))
  (setf (projectile-collider p) nil
        (projectile-rect p) nil)
  (push p (pool-free pool)))

(defun %move-to (pool p nx ny)
  "Move a projectile's rect to (NX, NY), keeping the collision world's ordering in step.

   The rect must move whether or not a world is attached -- position is the
   projectile's own state, and the world is only an index over it."
  (let* ((r (projectile-rect p))
         (dx (- nx (rect:rect-x r)))
         (dy (- ny (rect:rect-y r))))
    (if (and (pool-world pool) (projectile-collider p))
        (collision:move (pool-world pool) (projectile-collider p) dx dy)
        (rect:move-ip r dx dy))))

(defun %advance-spline (pool p)
  "Ask the spline for its next point. The original treats a non-positive X as the end
   of the path -- next_point returns a zero vector once the spline is exhausted, so
   x <= 0 doubles as the done? signal."
  (declare (ignore pool))
  (let* ((point (spline:next-point (projectile-spline p)))
         (nx (aref point 0))
         (ny (aref point 1)))
    (if (> nx 0.0)
        (values (truncate nx) (truncate ny) t)
        (progn (setf (projectile-dead? p) t) (values 0 0 nil)))))

(defparameter *player-kinds* '(:player-bullet :player-bomb)
  "Projectiles the player fired. Held separately because they are exempt from the
   frame-rate correction; see *SLOW-PLAYER-SHOTS?*.")

(defparameter *slow-player-shots?* nil
  "Whether the player's own projectiles are slowed to the original's wall-clock speed
   along with everything else.

   Enemy fire genuinely needed it -- at 62.5 Hz a stage-two cannon volley crossed the
   screen in half the time and was simply unreadable. But applying the same correction to
   the player's shots reads as a nerf rather than a fix: the shot leaves the nose at half
   the speed it did, so it takes longer to reach anything, and the game feels less
   responsive even though the fire RATE is unchanged.

   The asymmetry is deliberate and is not the original's -- there, everything moved at
   whatever the frame rate gave. Set this to T for uniform treatment.")

(defun player-projectile? (p)
  (member (definition-kind (projectile-definition p)) *player-kinds*))

(defun %step-for (p time-step)
  (if (and (not *slow-player-shots?*) (player-projectile? p))
      time-step
      (/ time-step (float (state:rate-scale) 1.0))))

(defun update (pool &optional (time-step level:+time-step+))
  "Advance every live projectile and reap the dead. Returns the live count.

   Enemy projectiles have their step divided by RATE-SCALE for the same reason everything
   else does: a projectile advances by velocity * timestep per TICK, so at 62.5 Hz it
   covers twice the ground per second it did at the ~30 the original managed. The
   player's own shots are left at full speed -- see *SLOW-PLAYER-SHOTS?*."
  (let ((survivors '()))
    (dolist (p (pool-live pool))
      (cond
        ((projectile-dead? p) (%reap pool p))
        ((projectile-spline p)
         (multiple-value-bind (nx ny moved?) (%advance-spline pool p)
           (if moved?
               (progn (%move-to pool p nx ny)
                      (push p survivors))
               (%reap pool p))))
        (t
         (let ((m (projectile-move p)))
           (movement:integrate m (%step-for p time-step))
           (%move-to pool p
                     (truncate (movement:movement-world-x m))
                     (truncate (movement:movement-world-y m)))
           (push p survivors)))))
    (setf (pool-live pool) (nreverse survivors))
    (length (pool-live pool))))

(defun render (pool screen)
  (dolist (p (pool-live pool) pool)
    (let ((r (projectile-rect p)))
      (when r
        (screen:enqueue screen (definition-sprite (projectile-definition p))
                        (rect:rect-x r) (rect:rect-y r) +z-projectile+)))))

(defun clear (pool)
  (dolist (p (copy-list (pool-live pool)))
    (%reap pool p))
  (setf (pool-live pool) '())
  pool)
