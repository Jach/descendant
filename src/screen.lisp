(in-package #:com.thejach.descendant.screen)

;;;; The cell buffer and its z-ordered queues: the compositing half of GR_render
;;;; (origRef/Renderer/gam_render.c). Sprites are enqueued during a frame, then
;;;; composited bottom layer first, painter's algorithm.

(defconstant +cols+ 240 "DSC_SCREEN_COLS")
(defconstant +rows+ 120 "DSC_SCREEN_ROWS")
(defconstant +cell-width+ 4 "Console font width; GR_initFont searched for 4x6.")
(defconstant +cell-height+ 6 "Console font height.")
(defconstant +pixel-width+ (* +cols+ +cell-width+))    ; 960
(defconstant +pixel-height+ (* +rows+ +cell-height+))  ; 720
(defconstant +z-layers+ 20 "RDR_Z_ONE .. RDR_Z_TWENTY")

(defparameter *right-edge-off-by-one* nil
  "The original's right-hand clip is off by one: it tests `p_x + width >= maxx` and then
   sets x_off to 1 + overflow, dropping a column that is actually on screen. Every
   full-screen 240-wide sprite trips it, so the shipped game had a permanent 1-cell
   (4-pixel) dead stripe down the right edge of the display -- unnoticed at the time.

   We clip correctly and reclaim the column, so this defaults to NIL. Bind it to T to
   reproduce the original artifact (the test suite does, to keep the behaviour pinned).")

(defstruct (screen (:constructor %make-screen))
  (cells (make-array (* +cols+ +rows+) :element-type '(unsigned-byte 32))
   :type (simple-array (unsigned-byte 32) (*)))
  ;; The original's second buffer; see the commentary on BACK below.
  (back (make-array (* +cols+ +rows+) :element-type '(unsigned-byte 32)
                                      :initial-element glyph:+transparent+)
   :type (simple-array (unsigned-byte 32) (*)))
  (clear-back? nil :type boolean)
  (queues (make-array +z-layers+ :initial-element nil) :type simple-vector))

(defun make-screen ()
  (%make-screen))

;;; The back buffer (GR_render's d_bbDtP) is not a copy of the composite, and the
;;; difference is load-bearing for the warp hole, which snapshots it.
;;;
;;; Two things make it diverge. It is written UNCONDITIONALLY -- a transparent glyph
;;; overwrites it even though it leaves the visible cell alone -- so the last (highest-z)
;;; sprite covering a cell wins outright, punching transparent holes wherever an upper
;;; sprite's bounding box overhangs whatever is beneath it. And it is only cleared on
;;; request, never per frame, so cells no sprite touched keep the previous frame's value.
;;;
;;; The result is "what the topmost sprite drew here, including its transparency", which
;;; is what gives the warp its characteristic holey swirl. Compositing the visible buffer
;;; instead would look cleaner and wrong.

(defun request-clear-back-buffer (screen)
  "GR_clear_back_buf: arm the clear, which happens at the start of the next COMPOSITE."
  (setf (screen-clear-back? screen) t)
  screen)

(defun copy-back-buffer (screen destination)
  "GR_copy_back_buf, whole-screen only -- the original asserts on any sub-rectangle."
  (replace destination (screen-back screen))
  destination)

(declaim (inline cell-ref (setf cell-ref)))

(defun cell-ref (screen x y)
  (aref (screen-cells screen) (+ (* y +cols+) x)))

(defun (setf cell-ref) (value screen x y)
  (setf (aref (screen-cells screen) (+ (* y +cols+) x)) value))

(defun clear-screen (screen)
  "The original memsets the screen buffer to zero every frame, which is char 0 with
   colour pair 0 -- i.e. palette slot 0 as background, black in every shipped theme."
  (fill (screen-cells screen) 0))

(defun enqueue (screen sprite x y z &optional (frame 0))
  "Queue SPRITE for drawing at cell (X, Y) on layer Z.

   Y is measured from the BOTTOM of the screen: the original computes the top row as
   (rows - Y), so Y = +rows+ puts the sprite's top edge at row 0."
  (check-type z (integer 0 #.(1- +z-layers+)))
  (push (list sprite x y frame) (aref (screen-queues screen) z)))

(defun composite (screen)
  "Draw every queued sprite into the cell buffer and empty the queues.

   Within a layer the original prepends to a linked list and then walks it head-first,
   so the most recently enqueued sprite is drawn FIRST and the earliest ends up on top.
   Pushing onto a list and iterating it reproduces that order exactly."
  (clear-screen screen)
  (when (screen-clear-back? screen)
    (fill (screen-back screen) glyph:+transparent+)
    (setf (screen-clear-back? screen) nil))
  (dotimes (z +z-layers+)
    (dolist (entry (aref (screen-queues screen) z))
      (destructuring-bind (sprite x y frame) entry
        (blit-sprite screen sprite x y frame)))
    (setf (aref (screen-queues screen) z) nil))
  screen)

(defun blit-sprite (screen sprite x y &optional (frame 0))
  "Blit one frame of SPRITE with the original's clipping and transparency rules.

   Transparent cells (#xFFFFFFFF) leave the destination untouched. A mod byte of #xFF
   means 'keep the background underneath and apply only the foreground', which the
   original implements by OR-ing just the foreground nibble of the colour pair."
  (let* ((cells (screen-cells screen))
         (back (screen-back screen))
         (glyphs (theme:sprite-glyphs sprite))
         (width (theme:sprite-width sprite))
         (height (theme:sprite-height sprite))
         (px x)
         (py (- +rows+ y))
         (x-off 0)
         (y-off 0)
         (base (theme:sprite-frame-offset sprite frame)))
    (declare (type (simple-array (unsigned-byte 32) (*)) cells back glyphs)
             (type fixnum width height px py x-off y-off base))
    ;; Wholly outside the screen?
    (when (or (< (+ px width) 0) (>= px +cols+)
              (< (+ py height) 0) (>= py +rows+))
      (return-from blit-sprite screen))
    (when (< py 0)
      (setf y-off (- py)
            py 0)
      (incf base (* width y-off)))
    (when (< px 0)
      (setf x-off (- px)
            px 0)
      (incf base x-off))
    ;; Faithful quirk, see *right-edge-off-by-one*: the original reuses x_off for the
    ;; right-hand clip, tests `>=` rather than `>`, and adds one, so a sprite whose
    ;; right edge lands exactly on the last column loses that column. A 240-wide
    ;; background therefore never paints column 239 at all.
    (if *right-edge-off-by-one*
        (when (>= (+ px width) +cols+)
          (setf x-off (1+ (- (+ px width) +cols+))))
        (when (> (+ px width) +cols+)
          (setf x-off (- (+ px width) +cols+))))
    (let ((cols-to-draw (- width x-off)))
      (declare (type fixnum cols-to-draw))
      (loop for row of-type fixnum from 0 below (- height y-off)
            while (< py +rows+)
            do (let ((dst (+ (* py +cols+) px))
                     (src base))
                 (declare (type fixnum dst src))
                 (loop for col of-type fixnum from 0 below cols-to-draw
                       do (let ((g (aref glyphs src)))
                            (unless (= g glyph:+transparent+)
                              (setf (aref cells dst)
                                    (if (= (glyph:glyph-mod g) glyph:+mod-transparent-bg+)
                                        ;; Keep the existing background, take the new
                                        ;; foreground nibble and character.
                                        (let ((under (aref cells dst)))
                                          (glyph:make-glyph
                                           (glyph:glyph-char g)
                                           (logior (logand (glyph:glyph-pair under) #xF0)
                                                   (logand (glyph:glyph-pair g) #x0F))))
                                        g)))
                            ;; Unconditional, transparency and all -- see BACK above.
                            (setf (aref back dst) g)
                            (incf dst)
                            (incf src)))
                 (incf base width)
                 (incf py))))
    screen))
