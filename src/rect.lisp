(in-package #:com.thejach.descendant.rect)

;;;; Axis-aligned rectangles in cell coordinates. Port of origRef/Math/mat_rect.c.
;;;;
;;;; Coordinates match the renderer: X grows right from column 0, Y counts UP from the
;;;; bottom of the screen. A rect spans [x, x+w) horizontally and (y-h, y] vertically --
;;;; that is, Y is the rect's TOP edge and it extends downward by its height.
;;;;
;;;; The overlap test is transcribed rather than rewritten, because it is not the
;;;; textbook one. See COLLIDE? for the quirk it carries.

(defstruct (rect (:constructor make-rect (x y w h)))
  (x 0 :type fixnum)
  (y 0 :type fixnum)
  (w 0 :type fixnum)
  (h 0 :type fixnum))

(declaim (inline rect-left rect-right rect-top rect-bottom move-ip))

(defun rect-left (r) (rect-x r))
(defun rect-right (r) (+ (rect-x r) (rect-w r)))
(defun rect-top (r) (rect-y r))
(defun rect-bottom (r) (- (rect-y r) (rect-h r)))

(defun move-ip (r dx dy)
  (incf (rect-x r) dx)
  (incf (rect-y r) dy)
  r)

(defun set-size (r w h)
  (setf (rect-w r) w (rect-h r) h)
  r)

(defun collide-point? (r x y)
  (and (<= (rect-x r) x) (< x (rect-right r))
       (<= (rect-bottom r) y) (<= y (rect-y r))))

(defun collide? (a b)
  "Rect_collide_rect, transcribed from mat_rect.c.

   Faithful quirk: the vertical half requires one rect's top to be strictly above the
   other's, so **two rects with exactly equal Y never collide**, whichever way round
   they are tested. The horizontal half has no such gap because it uses <=. Reproduced
   deliberately -- gameplay was tuned against it, and a bullet that passes cleanly
   through a target sharing its exact row is original behaviour."
  (let ((ax (rect-x a)) (aw (rect-w a)) (ay (rect-y a)) (ah (rect-h a))
        (bx (rect-x b)) (bw (rect-w b)) (by (rect-y b)) (bh (rect-h b)))
    (and (or (and (< ax (+ bx bw)) (<= bx ax))
             (and (< bx (+ ax aw)) (<= ax bx)))
         (or (and (>= ay (- by bh)) (> by ay))
             (and (>= by (- ay ah)) (> ay by))))))

(defun contains? (outer inner)
  (and (<= (rect-x outer) (rect-x inner))
       (<= (rect-right inner) (rect-right outer))
       (<= (rect-bottom outer) (rect-bottom inner))
       (<= (rect-y inner) (rect-y outer))))
