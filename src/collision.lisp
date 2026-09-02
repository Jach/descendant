(in-package #:com.thejach.descendant.collision)

;;;; Port of origRef/Engine/gam_collision_manager.c.
;;;;
;;;; Sweep and prune along X. Colliders are kept sorted by their left edge, so the inner
;;;; scan can stop as soon as a candidate starts to the right of the current collider's
;;;; right edge -- everything further along is sorted beyond it too.
;;;;
;;;; The original threads this through a hand-rolled linked list with IDs, largely to
;;;; survive colliders being removed from inside a hit callback. We keep an ordered
;;;; vector and take a snapshot before dispatching, which gives the same guarantee
;;;; without the ID bookkeeping: removals during a sweep affect the next sweep, not the
;;;; one in flight.
;;;;
;;;; Both parties get a HIT call, and each is told the other. A collider whose rect has
;;;; entirely left the world gets an OFFSCREEN call instead and is skipped for the rest
;;;; of that sweep.

(defstruct (collider (:constructor make-collider (rect kind &key data on-hit on-offscreen)))
  (rect nil :type rect:rect)
  (kind :none :type keyword)
  (data nil)
  (on-hit nil :type (or null function))
  (on-offscreen nil :type (or null function))
  (alive? t :type boolean))

(defstruct (world (:constructor %make-world (width height)))
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (colliders (make-array 0 :adjustable t :fill-pointer 0) :type (vector t)))

(defun make-world (&optional (width screen:+cols+) (height screen:+rows+))
  (%make-world width height))

(defun add (world collider)
  "Insert keeping the vector ordered by left edge."
  (let* ((v (world-colliders world))
         (x (rect:rect-x (collider-rect collider)))
         (i (or (position-if (lambda (c) (> (rect:rect-x (collider-rect c)) x)) v)
                (fill-pointer v))))
    (vector-push-extend nil v)
    (replace v v :start1 (1+ i) :start2 i)
    (setf (aref v i) collider)
    collider))

(defun remove-collider (world collider)
  (setf (collider-alive? collider) nil)
  (let ((v (world-colliders world)))
    (let ((i (position collider v)))
      (when i
        (replace v v :start1 i :start2 (1+ i))
        (decf (fill-pointer v)))))
  collider)

(defun move (world collider dx dy)
  "Re-inserting is how the original keeps the list ordered; the comment there reads
   'Optimize later'. Kept as-is: correctness first, and the counts are small."
  (remove-collider world collider)
  (setf (collider-alive? collider) t)
  (rect:move-ip (collider-rect collider) dx dy)
  (add world collider))

(defun count-colliders (world)
  (fill-pointer (world-colliders world)))

(defun outside-world? (world collider)
  "check_world: entirely past an edge. Y counts up, and a rect spans (y-h, y]."
  (let ((r (collider-rect collider)))
    (or (<= (+ (rect:rect-x r) (rect:rect-w r)) 0)
        (> (- (rect:rect-y r) (rect:rect-h r)) (world-height world))
        (>= (rect:rect-x r) (world-width world))
        (< (rect:rect-y r) 0))))

(defun %dispatch-hit (a b)
  (when (and (collider-alive? a) (collider-on-hit a))
    (funcall (collider-on-hit a) a b)))

(defun check-collisions (world)
  "One sweep. Returns the number of colliding pairs found."
  (let ((snapshot (copy-seq (world-colliders world)))
        (pairs 0))
    (loop for i from 0 below (length snapshot)
          for a = (aref snapshot i)
          do (cond
               ((not (collider-alive? a)))
               ((outside-world? world a)
                (when (collider-on-offscreen a)
                  (funcall (collider-on-offscreen a) a)))
               (t
                (loop for j from (1+ i) below (length snapshot)
                      for b = (aref snapshot j)
                      ;; Sorted by left edge, so once a candidate starts beyond this
                      ;; collider's right edge nothing further along can overlap.
                      while (<= (rect:rect-x (collider-rect b))
                                (+ (rect:rect-x (collider-rect a))
                                   (rect:rect-w (collider-rect a))))
                      do (when (and (collider-alive? b)
                                    (rect:collide? (collider-rect a)
                                                   (collider-rect b)))
                           (incf pairs)
                           (%dispatch-hit a b)
                           (%dispatch-hit b a))))))
    pairs))

(defun clear (world)
  (setf (fill-pointer (world-colliders world)) 0)
  world)
