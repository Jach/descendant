(in-package #:com.thejach.descendant.static-field)

;;;; Port of origRef/GamePlay/dsc_static_field.c -- the player's death sequence.
;;;;
;;;; This is the warp hole's boil phase and nothing else: a disc of the screen dissolving
;;;; into a churn of its own cells, centred on wherever the ship was, growing from five
;;;; cells at a steady 0.65 a frame until it has eaten the display. No swirl, no second
;;;; phase, no cap on the radius -- the level tears it down on a timer instead.
;;;;
;;;; That the C is a copy of dsc_warp_hole.c is not a guess: its file header still says
;;;; "Purpose: Warp Hole effect for end of level". Everything the two share is in
;;;; screen-effect.lisp, which leaves this file as the radius schedule.

(defconstant +radius-growth+ 0.65
  "### Magic!!!, with a `//0.45f` left beside it -- it was tuned by eye.")
(defconstant +z-static-field+ 3 "RDR_Z_FOUR")

(defstruct (static-field (:constructor %make-static-field))
  (effect (fx:make-effect :z +z-static-field+) :type fx:effect)
  (radius 0.0 :type single-float))

(defun make-static-field () (%make-static-field))

(defun active? (sf) (fx:active? (static-field-effect sf)))
(defun state (sf) (fx:effect-state (static-field-effect sf)))
(defun active-frame (sf) (fx:effect-active-frame (static-field-effect sf)))
(defun sprites (sf) (fx:effect-sprites (static-field-effect sf)))
(defun current (sf) (fx:effect-current (static-field-effect sf)))
(defun snapshot (sf) (fx:snapshot (static-field-effect sf)) sf)
(defun finish (sf) (fx:finish (static-field-effect sf)) sf)

(defun begin (sf pos-x pos-y min-radius)
  "beginStaticField. POS is the centre of the ship, so the static blooms out of the wreck
   rather than from the middle of the screen as the warp does."
  (fx:begin (static-field-effect sf) pos-x pos-y)
  (setf (static-field-radius sf) (float min-radius 1.0))
  sf)

(defun update (sf screen)
  (let ((e (static-field-effect sf)))
    (ecase (fx:effect-state e)
      (:inactive)
      (:no-image (incf (fx:effect-active-frame e)))
      ((:active :clear :snapshot)
       (fx:seed-if-needed e screen)
       (fx:boil e (static-field-radius sf))
       ;; Linear and unbounded. At 0.65 a frame from 5 it covers the whole screen in
       ;; about 380 frames, and the level ends the sequence at 340 -- so it is still
       ;; growing when it is torn down, which is why the edges never settle.
       (incf (static-field-radius sf) +radius-growth+)
       (incf (fx:effect-active-frame e)))))
  sf)

(defun render (sf screen)
  (fx:render (static-field-effect sf) screen)
  sf)
