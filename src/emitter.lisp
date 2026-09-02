(in-package #:com.thejach.descendant.emitter)

;;;; Port of origRef/GamePlay/dsc_emitter.c.
;;;;
;;;; A particle fountain. Each particle is a single '*' cell in one of five warm colour
;;;; pairs, given a velocity and a lifetime, and left to drift. The player and enemies
;;;; already call into this through their `emit` hooks.
;;;;
;;;; Three shapes are in use:
;;;;
;;;;   :circle          100 particles fanned evenly around a full turn, 1.0s
;;;;   :circle-small    the same fan but faster, used when the player explodes
;;;;   :circle-limited  50 particles in a leftward cone, 0.7s -- a glancing hit
;;;;   :lines / :enemy  30 particles straight left at high speed, 0.4s
;;;;
;;;; :spline is not ported. The original's own comment calls it "not really functional
;;;; at the moment", it is never invoked by any caller, and it relies on copying a
;;;; Spline struct by value into a union -- which does not have a sensible Lisp
;;;; equivalent. SPEW ignores it rather than pretending.

(defconstant +z-particle+ 6 "RDR_Z_SEVEN")
(defconstant +scroll-adjust+ -50.0
  "update_circle nudges every particle left each tick to compensate for the level
   scrolling underneath it, so debris appears to stay with the world rather than the
   camera.")

(defparameter *colour-pairs* '(75 90 150 165 195)
  "valid_pairs: red, yellow, darkish red, dark red, orange.")

(defstruct (particle (:constructor %make-particle))
  (x 0.0 :type single-float)
  (y 0.0 :type single-float)
  (vx 0.0 :type single-float)
  (vy 0.0 :type single-float)
  (lifetime 0.0 :type single-float)
  (sprite nil))

(defstruct (emitter (:constructor %make-emitter))
  (sprites (make-hash-table) :type hash-table)
  (live '() :type list)
  (max-particles 4096 :type fixnum)
  (random-state *random-state*))

(defun make-emitter (&key (max-particles 4096) (random-state *random-state*))
  "One 1x1 '*' sprite per colour pair, as new_GameSpriteFromString builds them."
  (let ((e (%make-emitter :max-particles max-particles :random-state random-state)))
    (dolist (pair *colour-pairs* e)
      (setf (gethash pair (emitter-sprites e))
            (theme:make-sprite (format nil "particle~d" pair) 1 1
                               (make-array 1 :element-type '(unsigned-byte 32)
                                             :initial-element
                                             (glyph:make-glyph (char-code #\*) pair)))))))

(defun live-count (e) (length (emitter-live e)))

(defun %random-sprite (e)
  (let ((pair (nth (random (length *colour-pairs*) (emitter-random-state e))
                   *colour-pairs*)))
    (gethash pair (emitter-sprites e))))

(defun %emit (e x y direction speed lifetime)
  (when (< (length (emitter-live e)) (emitter-max-particles e))
    (push (%make-particle :x (float x) :y (float y)
                          :vx (float (* (cos direction) speed) 1.0)
                          :vy (float (* (sin direction) speed) 1.0)
                          :lifetime lifetime
                          :sprite (%random-sprite e))
          (emitter-live e))
    t))

(defun spew (e x y type)
  "The three burst shapes. Returns how many particles were created."
  (let ((state (emitter-random-state e))
        (made 0))
    (flet ((emit (direction speed lifetime)
             (when (%emit e x y direction speed lifetime) (incf made))))
      (case type
        ((:circle :circle-small :circle-limited)
         (let* ((limited? (eq type :circle-limited))
                (total (if limited? 50 100))
                (lifetime (if limited? 0.7 1.0))
                (speed-mult (cond (limited? 15.0) ((eq type :circle-small) 20.0)
                                  (t 10.0))))
           (dotimes (i total)
             (let ((speed (if (member type '(:circle-small :circle-limited))
                              ;; A coin flip between full and half speed, which is what
                              ;; gives these bursts their ragged edge.
                              (let ((s (+ speed-mult 30.0)))
                                (if (= 1 (random 2 state)) (/ s 2.0) s))
                              (* speed-mult (/ (float (random 6 state))
                                               (+ 1.0 (random 5 state))))))
                   (direction (if limited?
                                  ;; A cone pointing left, spanning +/- 5/12 of a turn.
                                  (+ (float pi 1.0)
                                     (/ (* (- (random 11 state) 5) (float pi 1.0)) 12.0))
                                  (/ (* 2.0 (float pi 1.0) i) (float total)))))
               (emit direction speed lifetime)))))
        ((:lines :enemy)
         ;; All thirty fly dead left at high speed, but they START scattered around the
         ;; impact rather than on top of it -- `x + -5 + rand(8)`, `y + -5 + rand(11)`.
         ;; That scatter is what makes it read as a stream tearing off the enemy instead
         ;; of a single line, and it is why the spray is visible even when the thing it
         ;; came off is standing still.
         (dotimes (i 30)
           (let ((jx (+ x -5 (random 8 state)))
                 (jy (+ y -5 (random 11 state))))
             (when (%emit e jx jy (float pi 1.0)
                          (float (+ 100 (random 50 state))) 0.4)
               (incf made)))))
        (:spline nil)))                    ; see the header note
    made))

(defun update (e &optional (time-step 0.016))
  "Drift, age, and drop anything whose lifetime has run out."
  (setf (emitter-live e)
        (remove-if (lambda (p)
                     (decf (particle-lifetime p) time-step)
                     (incf (particle-x p) (* (particle-vx p) time-step))
                     (incf (particle-x p) (* +scroll-adjust+ time-step))
                     (incf (particle-y p) (* (particle-vy p) time-step))
                     (<= (particle-lifetime p) 0.0))
                   (emitter-live e)))
  (length (emitter-live e)))

(defun render (e screen)
  (dolist (p (emitter-live e) e)
    (screen:enqueue screen (particle-sprite p)
                    (truncate (particle-x p)) (truncate (particle-y p))
                    +z-particle+)))

(defun clear (e)
  (setf (emitter-live e) '())
  e)
