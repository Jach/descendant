(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; Rect, movement and the collision sweep.

(test rect-spans
  "Y is the top edge and the rect extends downward; X spans [x, x+w)."
  (let ((r (rect:make-rect 10 50 4 6)))
    (is (= 10 (rect:rect-left r)))
    (is (= 14 (rect:rect-right r)))
    (is (= 50 (rect:rect-top r)))
    (is (= 44 (rect:rect-bottom r)))))

(test rect-equal-y-never-collides
  "Faithful quirk from mat_rect.c: the vertical half needs one top strictly above the
   other, so rects sharing a Y never collide however they are ordered. Gameplay was
   tuned against this."
  (let ((a (rect:make-rect 10 50 4 4))
        (b (rect:make-rect 12 50 4 4)))
    (is-false (rect:collide? a b))
    (is-false (rect:collide? b a)))
  ;; Identical rects likewise do not collide with themselves.
  (let ((a (rect:make-rect 10 50 4 4)))
    (is-false (rect:collide? a (rect:make-rect 10 50 4 4)))))

(test rect-collides-when-offset-vertically
  (let ((a (rect:make-rect 10 50 4 4))
        (b (rect:make-rect 12 49 4 4)))
    (is-true (rect:collide? a b))
    (is-true (rect:collide? b a))))

(test rect-x-is-half-open
  "A rect starting exactly on another's right edge does not overlap."
  (let ((a (rect:make-rect 10 50 4 4))
        (b (rect:make-rect 14 49 4 4)))
    (is-false (rect:collide? a b))
    (is-false (rect:collide? b a))))

(test rect-separated-rects-miss
  (is-false (rect:collide? (rect:make-rect 10 50 4 4) (rect:make-rect 40 20 4 4))))

(test rect-move-and-contains
  (let ((r (rect:make-rect 10 50 4 4)))
    (rect:move-ip r 5 -5)
    (is (= 15 (rect:rect-x r)))
    (is (= 45 (rect:rect-y r))))
  (is-true (rect:contains? (rect:make-rect 0 100 50 50) (rect:make-rect 10 90 5 5)))
  (is-false (rect:contains? (rect:make-rect 0 100 50 50) (rect:make-rect 10 90 100 5))))

(test movement-two-register-integrator
  "dsc_movement.c swaps two velocity registers each call, which is what gives the ship
   its lag. Reproduced literally: after one step velocity is (prev + accel) * drag and
   prev holds the OLD velocity."
  (let ((m (movement:make-movement)))
    (setf (movement:movement-vx m) 3.0
          (movement:movement-prev-vx m) 1.0
          (movement:movement-accel-x m) 1.0)
    (movement:calc-world-velocity m 0.5)
    ;; prev' = (1 + 1) * 0.5 = 1.0 -> velocity; prev then takes the old velocity, 3.0
    (is (< (abs (- 1.0 (movement:movement-vx m))) 1e-6))
    (is (< (abs (- 3.0 (movement:movement-prev-vx m))) 1e-6))))

(test movement-acceleration-from-direction
  (let ((m (movement:make-movement)))
    (movement:set-acceleration m 0.0 100.0 0.016)
    (is (< (abs (- 1.6 (movement:movement-accel-x m))) 1e-5))
    (is (< (abs (movement:movement-accel-y m)) 1e-5))))

(test movement-integrates-position
  (let ((m (movement:make-movement)))
    (setf (movement:movement-vx m) 10.0 (movement:movement-vy m) -5.0)
    (movement:integrate m 0.5)
    (is (< (abs (- 5.0 (movement:movement-world-x m))) 1e-6))
    (is (< (abs (- -2.5 (movement:movement-world-y m))) 1e-6))))

;;; ---------------------------------------------------------------------------

(defun test-collider (x y &optional (w 4) (h 4) (kind :test))
  (collision:make-collider (rect:make-rect x y w h) kind))

(test collision-keeps-colliders-sorted-by-x
  (let ((w (collision:make-world)))
    (dolist (x '(50 10 30 20))
      (collision:add w (test-collider x 60)))
    (is (= 4 (collision:count-colliders w)))
    (is (equal '(10 20 30 50)
               (map 'list (lambda (c) (rect:rect-x (collision:collider-rect c)))
                    (collision::world-colliders w))))))

(test collision-detects-overlapping-pairs
  (let* ((w (collision:make-world))
         (hits '())
         (a (collision:make-collider (rect:make-rect 10 50 6 6) :a
                                     :on-hit (lambda (self other)
                                               (declare (ignore self))
                                               (push (collision:collider-kind other)
                                                     hits))))
         (b (collision:make-collider (rect:make-rect 12 48 6 6) :b
                                     :on-hit (lambda (self other)
                                               (declare (ignore self))
                                               (push (collision:collider-kind other)
                                                     hits)))))
    (collision:add w a)
    (collision:add w b)
    (is (= 1 (collision:check-collisions w)))
    (is (equal '(:a :b) (sort hits #'string< :key #'symbol-name))
        "both parties are notified, each told the other")))

(test collision-ignores-distant-pairs
  (let ((w (collision:make-world)))
    (collision:add w (test-collider 10 50))
    (collision:add w (test-collider 200 50))
    (is (= 0 (collision:check-collisions w)))))

(test collision-reports-offscreen
  (let* ((w (collision:make-world))
         (gone nil)
         (c (collision:make-collider (rect:make-rect -10 50 4 4) :stray
                                     :on-offscreen (lambda (self)
                                                     (declare (ignore self))
                                                     (setf gone t)))))
    (collision:add w c)
    (is-true (collision:outside-world? w c))
    (collision:check-collisions w)
    (is-true gone)))

(test collision-survives-removal-during-a-hit
  "A hit callback that removes its collider must not corrupt the sweep in flight --
   the reason the original threaded IDs through its list."
  (let* ((w (collision:make-world))
         (a (collision:make-collider (rect:make-rect 10 50 6 6) :a))
         (b (collision:make-collider (rect:make-rect 12 48 6 6) :b)))
    (setf (collision:collider-on-hit a)
          (lambda (self other) (declare (ignore other)) (collision:remove-collider w self)))
    (collision:add w a)
    (collision:add w b)
    (finishes (collision:check-collisions w))
    (is (= 1 (collision:count-colliders w)))
    (is-false (collision:collider-alive? a))))

(test collision-move-keeps-order
  (let ((w (collision:make-world))
        (c (test-collider 10 60)))
    (collision:add w c)
    (collision:add w (test-collider 30 60))
    (collision:move w c 40 0)
    (is (= 50 (rect:rect-x (collision:collider-rect c))))
    (is (equal '(30 50)
               (map 'list (lambda (x) (rect:rect-x (collision:collider-rect x)))
                    (collision::world-colliders w))))))
