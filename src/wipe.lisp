(in-package #:com.thejach.descendant.wipe)

;;;; ADDED, not ported. A screen transition: filled rectangles growing out from the
;;;; centre in concentric bands until nothing of the old screen is left.
;;;;
;;;; The bands are drawn every frame rather than accumulated, because the screen is
;;;; composited fresh each time -- there is no persistent canvas to add a ring to. That
;;;; turns out to be the simpler model anyway: a cell's band is a function of where it
;;;; sits, so the whole effect is one comparison per cell against a precomputed distance.
;;;;
;;;; Distance is measured as a square ring, max(|dx|/halfWidth, |dy|/halfHeight), not a
;;;; circle. Cells are 4x6 pixels, so a circle in cell space arrives on screen as an
;;;; ellipse; a rectangle is both what was asked for and the honest shape here.
;;;;
;;;; Colour comes from the palette in use, sorted by brightness, so the bands read as a
;;;; gradient rather than as arbitrary hues. Any palette gives a usable ramp -- that is
;;;; the one property all sixteen-colour maps in this game share.

(defconstant +default-ticks+ 44
  "About 0.7 seconds at 62.5 Hz.")

(defconstant +band-count+ 16
  "Rings of colour between the centre and the corner. One per palette slot.")

(defclass wipe ()
  ((sprite :reader wipe-sprite :initform nil)
   (distance :accessor wipe-distance :initform nil
             :documentation "Per cell, 0.0 at the centre to 1.0 at the furthest corner.")
   (band :accessor wipe-band :initform nil)
   (ramp :accessor wipe-ramp :initform nil
         :documentation "Palette slots, darkest first.")
   (ticks :accessor wipe-ticks :initform +default-ticks+)
   (timer :accessor wipe-timer :initform 0)
   (running :accessor wipe-running :initform nil)
   ;; :COVER grows from the centre until the screen is hidden; :REVEAL runs the same
   ;; shape backwards, shrinking back to the centre to show what is now underneath.
   (direction :accessor wipe-direction :initform :cover)))

(defun %ramp-for (colormap)
  "The palette's slots ordered by brightness."
  (sort (loop for i below 16 collect i) #'<
        :key (lambda (i) (theme:color-luminance (theme:colormap-ref colormap i)))))

(defun make-wipe (colormap &key (ticks +default-ticks+))
  (let* ((self (make-instance 'wipe))
         (cols screen:+cols+)
         (rows screen:+rows+)
         (n (* cols rows))
         (distance (make-array n :element-type 'single-float))
         (band (make-array n :element-type '(unsigned-byte 8)))
         (cx (/ (1- cols) 2.0))
         (cy (/ (1- rows) 2.0)))
    (dotimes (y rows)
      (dotimes (x cols)
        (let* ((d (max (/ (abs (- x cx)) cx) (/ (abs (- y cy)) cy)))
               (i (+ (* y cols) x)))
          (setf (aref distance i) (float d 1.0)
                (aref band i) (min (1- +band-count+)
                                   (floor (* d +band-count+)))))))
    (setf (wipe-distance self) distance
          (wipe-band self) band
          (wipe-ticks self) ticks
          (wipe-ramp self) (coerce (%ramp-for colormap) 'vector)
          (slot-value self 'sprite)
          (theme:make-sprite "wipe" cols rows
                             (make-array n :element-type '(unsigned-byte 32)
                                           :initial-element glyph:+transparent+)))
    self))

(defun recolor (self colormap)
  "Re-derive the gradient after the palette changes."
  (setf (wipe-ramp self) (coerce (%ramp-for colormap) 'vector))
  self)

(defun start (self &optional (direction :cover))
  (check-type direction (member :cover :reveal))
  (setf (wipe-timer self) 0
        (wipe-direction self) direction
        (wipe-running self) t)
  self)

(defun running? (self) (wipe-running self))

(defun covered? (self)
  "True once the screen is entirely painted -- the moment it is safe to swap what is
   underneath without the change being seen. Only a cover reaches this; a reveal starts
   there and works the other way."
  (and (eq (wipe-direction self) :cover)
       (>= (wipe-timer self) (wipe-ticks self))))

(defun update (self)
  "Advance one tick. Returns true while the wipe is still running."
  (when (wipe-running self)
    (incf (wipe-timer self))
    (when (> (wipe-timer self) (wipe-ticks self))
      (setf (wipe-running self) nil)))
  (wipe-running self))

(defun stop (self)
  (setf (wipe-running self) nil
        (wipe-timer self) 0)
  self)

(defun progress (self)
  "How much of the screen is painted, 0 to 1, whichever way the wipe is going."
  (let ((fraction (if (plusp (wipe-ticks self))
                      (min 1.0 (/ (float (wipe-timer self) 1.0) (wipe-ticks self)))
                      1.0)))
    (if (eq (wipe-direction self) :reveal)
        (- 1.0 fraction)
        fraction)))

(defun render (self screen z)
  (when (wipe-running self)
    (let* ((sprite (wipe-sprite self))
           (glyphs (theme:sprite-glyphs sprite))
           (distance (wipe-distance self))
           (band (wipe-band self))
           (ramp (wipe-ramp self))
           (n (length ramp))
           (reach (progress self)))
      (dotimes (i (length glyphs))
        (setf (aref glyphs i)
              (if (<= (aref distance i) reach)
                  (let ((slot (aref ramp (min (1- n) (aref band i)))))
                    ;; Both nibbles the same colour, so the cell is solid whatever
                    ;; character happens to be drawn in it.
                    (glyph:make-glyph glyph:+default-fg-char+
                                      (glyph:encode-pair slot slot)))
                  glyph:+transparent+)))
      (screen:enqueue screen sprite 0 screen:+rows+ z)))
  t)
