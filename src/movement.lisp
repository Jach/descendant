(in-package #:com.thejach.descendant.movement)

;;;; Port of origRef/GamePlay/dsc_movement.c.
;;;;
;;;; Acceleration is set from a direction and speed; velocity is then advanced by an
;;;; unusual two-register scheme that is worth spelling out, because it is not the
;;;; Euler step it looks like:
;;;;
;;;;     save     = velocity
;;;;     prev     = (prev + acceleration) * drag
;;;;     velocity = prev
;;;;     prev     = save
;;;;
;;;; So the two registers swap roles each call and the integrator alternates between
;;;; them, giving the ship its characteristic lag and float. Reproduced exactly; a
;;;; "tidied" Euler version does not feel the same.

(defstruct (movement (:constructor make-movement ()))
  (accel-x 0.0 :type single-float)
  (accel-y 0.0 :type single-float)
  (prev-vx 0.0 :type single-float)
  (prev-vy 0.0 :type single-float)
  (vx 0.0 :type single-float)
  (vy 0.0 :type single-float)
  (env-vx 0.0 :type single-float)
  (env-vy 0.0 :type single-float)
  (world-x 0.0 :type single-float)
  (world-y 0.0 :type single-float))

(defun set-acceleration (m direction speed time-delta)
  "accel = (cos d, sin d) * speed * dt

   Coerces to single-float because CL's PI is a double, so any angle derived from it
   would otherwise contaminate the whole integrator with double arithmetic. The
   original is float throughout."
  (let ((scale (* speed time-delta)))
    (setf (movement-accel-x m) (float (* (cos direction) scale) 1.0)
          (movement-accel-y m) (float (* (sin direction) scale) 1.0)))
  m)

(defun set-acceleration-components (m ax ay)
  "Set the acceleration axes directly, rather than deriving both from one direction and
   one magnitude. Lets a caller drive the two axes independently."
  (setf (movement-accel-x m) (float ax 1.0)
        (movement-accel-y m) (float ay 1.0))
  m)

(defun calc-world-velocity (m drag)
  "The two-register swap described above."
  (let ((save-vx (movement-vx m))
        (save-vy (movement-vy m)))
    (setf (movement-prev-vx m) (* (+ (movement-prev-vx m) (movement-accel-x m)) drag)
          (movement-prev-vy m) (* (+ (movement-prev-vy m) (movement-accel-y m)) drag)
          (movement-vx m) (movement-prev-vx m)
          (movement-vy m) (movement-prev-vy m)
          (movement-prev-vx m) save-vx
          (movement-prev-vy m) save-vy))
  m)

(defun integrate (m time-delta)
  "Advance the world position by the current velocity."
  (incf (movement-world-x m) (* (movement-vx m) time-delta))
  (incf (movement-world-y m) (* (movement-vy m) time-delta))
  m)

(defun reset (m)
  (setf (movement-accel-x m) 0.0 (movement-accel-y m) 0.0
        (movement-prev-vx m) 0.0 (movement-prev-vy m) 0.0
        (movement-vx m) 0.0 (movement-vy m) 0.0
        (movement-env-vx m) 0.0 (movement-env-vy m) 0.0)
  m)
