(in-package #:com.thejach.descendant.warp)

;;;; Port of origRef/GamePlay/dsc_warp_hole.c -- the end-of-level vortex.
;;;;
;;;; The buffer machine, the seeding and the boil kernel are shared with the static
;;;; field and live in screen-effect.lisp; what is here is the part that is actually a
;;;; vortex.
;;;;
;;;; Two phases:
;;;;
;;;;   Frames 1..44   boil. The picture dissolves into a churning soup of its own cells
;;;;                  inside a disc that widens asymptotically.
;;;;
;;;;   Frames 45+     swirl. A rotation about a point near the centre is applied
;;;;                  N-CIRCLES times over N-CIRCLES nested discs -- the outer disc is
;;;;                  rotated once, the next twice, the innermost three times. That
;;;;                  difference is the entire trick: the shear between the rings is
;;;;                  what reads as a vortex rather than a spinning plate. A 9x9 box at
;;;;                  the dead centre keeps boiling, giving it a hole.
;;;;
;;;; The rotation angle is a constant 0.1 rad; only the radius grows. The original has a
;;;; "// Make this configurable" note on the angle that never happened.

(defconstant +initial-rotation+ 0.1 "DSC_WARP_INITIAL_ROT")
(defconstant +boil-frames+ 45 "WARP_INITIAL_ANIM_FRAMES")
(defconstant +radius-growth+ 0.15 "### Magic!!!, in the original's own words.")
(defconstant +core-half-width+ 4
  "Half-width of the boiling square at the very centre. The original calls its bounds
   wtfMinX/wtfMaxX, which is as good a name as any.")
(defconstant +z-warp+ 3 "RDR_Z_FOUR")

(defparameter *centre-row-artifact* t
  "The original leaves a band of the nine centre rows unwritten, so those cells show
   whichever buffer they were in two frames ago and flicker.

   It is a stale-variable slip: on those rows the loops that fill from the inner-square
   edge to the core do not advance `point.d_x`, so each writes the same cell over and
   over instead of walking the span. `textureMap` takes the destination from the same
   point it takes the source from, so nothing downstream notices. The `// wtfMinX vs
   inMinX ...` comment left in the C suggests it was seen and not chased down.

   Defaults to T because it is part of how the shipped vortex looked. Bind to NIL to
   walk the span properly.")

(defstruct (warp (:constructor %make-warp))
  (effect (fx:make-effect :z +z-warp+) :type fx:effect)
  (rotation +initial-rotation+ :type single-float)
  ;; Three radii, all in cells and all divided by N-CIRCLES on the way in.
  (max-radius 0.0 :type single-float)
  (init-radius 0.0 :type single-float)   ; drives the boil, grows asymptotically
  (radius 0.0 :type single-float)        ; drives the swirl, grows linearly
  (n-circles 1 :type fixnum))

(defun make-warp () (%make-warp))

;;; Pass-throughs, so callers need not know about the shared layer.
(defun active? (w) (fx:active? (warp-effect w)))
(defun warp-state (w) (fx:effect-state (warp-effect w)))
(defun warp-active-frame (w) (fx:effect-active-frame (warp-effect w)))
(defun warp-sprites (w) (fx:effect-sprites (warp-effect w)))
(defun warp-current (w) (fx:effect-current (warp-effect w)))
(defun snapshot (w)
  "Re-seed from what is on screen right now. The level calls this the moment the ship
   reaches the middle, so the ship is swallowed by the vortex rather than vanishing."
  (fx:snapshot (warp-effect w)) w)
(defun finish (w) (fx:finish (warp-effect w)) w)

(defun begin (w pos-x pos-y n-circles min-radius max-radius)
  "beginWarp. Both radii are integer-divided by N-CIRCLES before becoming floats, exactly
   as the C does -- with the shipped 8 and 3 that is 2, not 2.67."
  (fx:begin (warp-effect w) pos-x pos-y)
  (setf (warp-rotation w) +initial-rotation+
        (warp-n-circles w) n-circles
        (warp-max-radius w) (float (floor max-radius n-circles) 1.0)
        (warp-radius w) (float (floor min-radius n-circles) 1.0)
        (warp-init-radius w) (warp-radius w))
  w)

;;; ---------------------------------------------------------------------------
;;; Phase two: swirl

(defstruct (affine (:constructor %make-affine))
  (a 1.0 :type single-float) (b 0.0 :type single-float) (dx 0.0 :type single-float)
  (c 0.0 :type single-float) (d 1.0 :type single-float) (dy 0.0 :type single-float))

(defun rotation-about (x y angle)
  "Mtx33::rotAffine -- rotate by ANGLE about (X, Y)."
  (let* ((s (sin angle)) (c (cos angle)))
    (%make-affine :a (float c 1.0) :b (float (- s) 1.0)
                  :dx (float (+ (- x (* c x)) (* s y)) 1.0)
                  :c (float s 1.0) :d (float c 1.0)
                  :dy (float (- y (* s x) (* c y)) 1.0))))

(declaim (inline %texture-map))
(defun %texture-map (write read mtx col row)
  "One sample: rotate (COL, ROW), wrap it onto the screen, copy that glyph here.

   The wrap is a single add-or-subtract rather than a modulus, so it only handles
   coordinates that fall within one screen of the edge -- which is all the rotation can
   produce. The clamp after it is the original's `//### Kludge-o-rama`."
  (declare (type (simple-array (unsigned-byte 32) (*)) write read)
           (type fixnum col row))
  (let* ((x (float col 1.0)) (y (float row 1.0))
         (sx (truncate (+ (* (affine-a mtx) x) (* (affine-b mtx) y) (affine-dx mtx))))
         (sy (truncate (+ (* (affine-c mtx) x) (* (affine-d mtx) y) (affine-dy mtx))))
         (size (* screen:+cols+ screen:+rows+)))
    (declare (type fixnum sx sy size))
    (setf sx (cond ((< sx 0) (+ sx screen:+cols+))
                   ((>= sx screen:+cols+) (- sx screen:+cols+))
                   (t sx))
          sy (cond ((< sy 0) (+ sy screen:+rows+))
                   ((>= sy screen:+rows+) (- sy screen:+rows+))
                   (t sy)))
    (let ((from (min (1- size) (max 0 (+ (* sy screen:+cols+) sx)))))
      (setf (aref write (+ (* row screen:+cols+) col)) (aref read from)))))

(defun %swirl (w)
  "N-CIRCLES nested discs, each rotated once more than the one outside it."
  (let* ((e (warp-effect w))
         (size (* screen:+cols+ screen:+rows+))
         (cx (fx:effect-pos-x e)) (cy (fx:effect-pos-y e))
         ;; The original cannot explain these two offsets either; the vortex eye sits
         ;; slightly up and to the right of the geometric centre because of them.
         (mtx (rotation-about (float (- cx 5) 1.0) (float (+ cy 5) 1.0) (warp-rotation w)))
         (inner (truncate (warp-radius w)))
         (radius (* inner (warp-n-circles w)))
         (core-min-x (- cx +core-half-width+)) (core-max-x (+ cx +core-half-width+))
         (core-min-y (- cy +core-half-width+)) (core-max-y (+ cy +core-half-width+)))
    (declare (type fixnum size cx cy inner radius))
    (dotimes (ring (warp-n-circles w))
      (declare (ignore ring))
      (let* ((rad-sq (float (* radius radius) 1.0))
             (in-rect-w (truncate (* radius fx:+cos-45+)))
             (min-x (max 0 (- cx radius))) (max-x (min (1- screen:+cols+) (+ cx radius)))
             (min-y (max 0 (- cy radius))) (max-y (min (1- screen:+rows+) (+ cy radius)))
             (in-min-x (- cx in-rect-w)) (in-max-x (+ cx in-rect-w))
             (in-min-y (- cy in-rect-w)) (in-max-y (+ cy in-rect-w)))
        (declare (type fixnum min-x max-x min-y max-y))
        (fx:swap e)
        (let ((read (fx:read-buffer e))
              (write (fx:write-buffer e)))
          (declare (type (simple-array (unsigned-byte 32) (*)) read write))
          (loop for row of-type fixnum from min-y to max-y
                for dy of-type single-float = (float (- row cy) 1.0)
                do (flet ((mapped (col)
                            (%texture-map write read mtx col row))
                          (inside? (col)
                            (let ((dx (float (- col cx) 1.0)))
                              (<= (+ (* dx dx) (* dy dy)) rad-sq))))
                     (cond
                       ;; Rows clear of the inner square: distance test all the way.
                       ((or (< row in-min-y) (> row in-max-y))
                        (loop for col of-type fixnum from min-x to max-x
                              when (inside? col) do (mapped col)))
                       ;; Rows crossing the inner square but clear of the core.
                       ((or (< row core-min-y) (> row core-max-y))
                        (loop for col of-type fixnum from min-x below in-min-x
                              when (inside? col) do (mapped col))
                        (loop for col of-type fixnum
                                from (max min-x in-min-x) to (min max-x in-max-x)
                              do (mapped col))
                        (loop for col of-type fixnum from (1+ in-max-x) to max-x
                              when (inside? col) do (mapped col)))
                       ;; The nine centre rows: the core boils instead of rotating.
                       (t
                        (loop for col of-type fixnum from min-x below in-min-x
                              when (inside? col) do (mapped col))
                        (unless *centre-row-artifact*
                          (loop for col of-type fixnum
                                  from (max min-x in-min-x) to (min max-x (1- core-min-x))
                                do (mapped col)))
                        (loop for col of-type fixnum
                                from (max min-x core-min-x) to (min max-x core-max-x)
                              do (setf (aref write (+ (* row screen:+cols+) col))
                                       (aref read (random size))))
                        (unless *centre-row-artifact*
                          (loop for col of-type fixnum
                                  from (max min-x (1+ core-max-x)) to (min max-x in-max-x)
                                do (mapped col)))
                        (loop for col of-type fixnum from (1+ in-max-x) to max-x
                              when (inside? col) do (mapped col)))))))
        (decf radius inner)))
    (when (< (warp-radius w) (warp-max-radius w))
      (incf (warp-radius w) +radius-growth+)))
  w)

;;; ---------------------------------------------------------------------------
;;; Entity

(defun update (w screen)
  (let ((e (warp-effect w)))
    (ecase (fx:effect-state e)
      (:inactive)
      (:no-image (incf (fx:effect-active-frame e)))
      ((:active :clear :snapshot)
       (fx:seed-if-needed e screen)
       (cond
         ((< (fx:effect-active-frame e) +boil-frames+)
          (fx:boil e (* (warp-init-radius w) (warp-n-circles w)))
          ;; Asymptotic approach, so the boil never quite reaches full size before the
          ;; swirl takes over and restarts from the much smaller RADIUS. That
          ;; discontinuity is in the original and is visible as a snap at frame 45.
          (incf (warp-init-radius w)
                (/ (- (warp-max-radius w) (warp-init-radius w))
                   (float +boil-frames+ 1.0))))
         (t (%swirl w)))
       (incf (fx:effect-active-frame e)))))
  w)

(defun render (w screen)
  (fx:render (warp-effect w) screen)
  w)
