(in-package #:com.thejach.descendant.screen-effect)

;;;; The machinery shared by the warp hole and the static field.
;;;;
;;;; origRef/GamePlay/dsc_warp_hole.c and dsc_static_field.c are the same file twice --
;;;; the static field's header comment still reads "Purpose: Warp Hole effect for end of
;;;; level". Same five-state buffer machine, same double buffer, same seeding, same
;;;; random-fill kernel. Only what happens per frame differs: the warp boils for 45
;;;; frames and then swirls, the static field boils forever with a faster-growing radius.
;;;; So the duplicated 90% lives here.
;;;;
;;;; The idea behind all of it: never draw source art. Clear the renderer's back buffer,
;;;; let one frame compose into it, copy that into two screen-sized buffers, and from
;;;; then on read one and write the other, swapping each frame. Every frame's output is
;;;; the previous frame's output transformed again, so the picture that was on screen
;;;; when the boss died -- or when the ship did -- is what gets chewed up.
;;;;
;;;; The five states, and why there are five:
;;;;
;;;;   :inactive   nothing running
;;;;   :no-image   started, but there is nothing to transform yet. Render asks for the
;;;;               back buffer to be cleared and steps to :snapshot without drawing.
;;;;   :snapshot   set by render, consumed by the NEXT update, which copies the back
;;;;               buffer into both halves and goes :active. Never survives to a render
;;;;               in normal play.
;;;;   :active     the steady state: transform, swap, draw.
;;;;   :clear      a re-seed was asked for. Behaves like :no-image except that the
;;;;               current buffer is still drawn, so the frame being captured includes
;;;;               the effect itself.
;;;;
;;;; The round trip through render is not incidental: asking for a clear and reading the
;;;; result on the next update is the only way to capture a composed frame, because the
;;;; composite happens between the two.

(defconstant +cos-45+ 0.707106781 "DSC_COS_45")

(defstruct (effect (:constructor %make-effect))
  (sprites nil :type (or null simple-vector))
  (current 0 :type fixnum)
  (state :inactive :type keyword)
  (pos-x 0 :type fixnum)
  (pos-y 0 :type fixnum)
  (active-frame 0 :type fixnum)
  (z 3 :type fixnum))

(defun make-effect (&key (z 3)) (%make-effect :z z))

(defun active? (e) (not (eq (effect-state e) :inactive)))

(defun buffer (e index)
  (theme:sprite-glyphs (svref (effect-sprites e) index)))

(defun read-buffer (e) (buffer e (logxor (effect-current e) 1)))
(defun write-buffer (e) (buffer e (effect-current e)))

(defun swap (e)
  "Make the current write buffer the next read buffer."
  (setf (effect-current e) (logxor (effect-current e) 1))
  e)

(defun begin (e pos-x pos-y)
  "Allocate the buffers and arm the machine. POS-Y arrives in the game's Y-up convention
   and is flipped to a row, because the effects work in row-major screen space."
  (let ((size (* screen:+cols+ screen:+rows+)))
    (flet ((blank ()
             (theme:make-sprite "Effect" screen:+cols+ screen:+rows+
                                (make-array size :element-type '(unsigned-byte 32)
                                                 :initial-element glyph:+transparent+))))
      (setf (effect-sprites e) (vector (blank) (blank))))
    (setf (effect-pos-x e) pos-x
          (effect-pos-y e) (- screen:+rows+ pos-y)
          (effect-state e) :no-image
          (effect-current e) 0
          (effect-active-frame e) 1))
  e)

(defun snapshot (e)
  "Re-seed from whatever is on screen at the end of this frame."
  (setf (effect-state e) :clear)
  e)

(defun finish (e)
  (setf (effect-sprites e) nil
        (effect-state e) :inactive
        (effect-active-frame e) 0)
  e)

(defun seed-if-needed (e screen)
  "Consume a pending :SNAPSHOT. Both halves are filled, so the first swap has something
   to read either way round."
  (when (eq (effect-state e) :snapshot)
    (screen:copy-back-buffer screen (buffer e (effect-current e)))
    (screen:copy-back-buffer screen (buffer e (logxor (effect-current e) 1)))
    (setf (effect-state e) :active))
  e)

(defun boil (e radius-f)
  "Replace every cell of a disc of RADIUS-F with a glyph taken from a random position in
   the read buffer -- the picture dissolves into a churn of its own cells.

   The inner axis-aligned square skips the distance test, being wholly inside the circle
   anyway. That is the original's one concession to speed and it is worth keeping the
   shape of, because the same structure reappears in the warp's swirl.

   Buffers are swapped first, so this writes the buffer that will be drawn."
  (let* ((size (* screen:+cols+ screen:+rows+))
         (rad-sq (* radius-f radius-f))
         (in-rect-w (truncate (* radius-f +cos-45+)))
         (radius (truncate radius-f))
         (cx (effect-pos-x e)) (cy (effect-pos-y e))
         (min-x (max 0 (- cx radius))) (max-x (min (1- screen:+cols+) (+ cx radius)))
         (min-y (max 0 (- cy radius))) (max-y (min (1- screen:+rows+) (+ cy radius)))
         (in-min-x (- cx in-rect-w)) (in-max-x (+ cx in-rect-w))
         (in-min-y (- cy in-rect-w)) (in-max-y (+ cy in-rect-w)))
    (declare (type fixnum size radius cx cy min-x max-x min-y max-y))
    (swap e)
    (let ((read (read-buffer e))
          (write (write-buffer e)))
      (declare (type (simple-array (unsigned-byte 32) (*)) read write))
      (loop for row of-type fixnum from min-y to max-y
            for base of-type fixnum = (* row screen:+cols+)
            for dy of-type single-float = (float (- row cy) 1.0)
            do (loop for col of-type fixnum from min-x to max-x
                     for dx of-type single-float = (float (- col cx) 1.0)
                     when (or (and (<= in-min-y row) (<= row in-max-y)
                                   (<= in-min-x col) (<= col in-max-x))
                              (<= (+ (* dx dx) (* dy dy)) rad-sq))
                       do (setf (aref write (+ base col)) (aref read (random size)))))))
  e)

(defun render (e screen)
  "The render half of the state machine, and the half that drives the seeding.

   The original returns FALSE from the :SNAPSHOT case, which the engine treats as a fatal
   render error and quits. It is unreachable during normal play, because UPDATE always
   converts :SNAPSHOT to :ACTIVE first -- but the level's pause check returns before the
   scene is updated, so pausing during either effect killed the game. We draw nothing that
   frame; see PLAN.md section 7."
  (flet ((draw ()
           (screen:enqueue screen (svref (effect-sprites e) (effect-current e))
                           0 screen:+rows+ (effect-z e))))
    (ecase (effect-state e)
      (:inactive)
      (:no-image
       (screen:request-clear-back-buffer screen)
       (setf (effect-state e) :snapshot))
      (:clear
       (screen:request-clear-back-buffer screen)
       (setf (effect-state e) :snapshot)
       (draw))
      (:snapshot)
      (:active (draw))))
  e)
