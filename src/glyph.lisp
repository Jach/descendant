(in-package #:com.thejach.descendant.glyph)

(deftype glyph () '(unsigned-byte 32))

(defconstant +transparent+ #xFFFFFFFF
  "A cell that is skipped entirely, leaving whatever was underneath. RDR_ALPHA.")

(defconstant +mod-transparent-bg+ #xFF
  "A mod byte of #xFF means only the foreground is applied; the background underneath
   shows through. GAM_FONT_ATTR_TRANSPARENCY.")

(defconstant +default-fg-char+ #xDB "Solid block, the lit pixel of .bft text.")
(defconstant +default-bg-char+ #x20 "Space, the unlit pixel of .bft text.")

(declaim (inline make-glyph glyph-char glyph-mod glyph-pair
                 glyph-bg-index glyph-fg-index transparent? transparent-bg?))

(defun make-glyph (char pair &optional (mod 0))
  (declare (type (unsigned-byte 8) char pair mod))
  (logior char (ash mod 16) (ash pair 24)))

(defun glyph-char (g)
  (declare (type glyph g))
  (ldb (byte 8 0) g))

(defun glyph-mod (g)
  (declare (type glyph g))
  (ldb (byte 8 16) g))

(defun glyph-pair (g)
  (declare (type glyph g))
  (ldb (byte 8 24) g))

;;; ---------------------------------------------------------------------------
;;; Colour-pair decomposition.
;;;
;;; PySpriteEdit encoded pair = 16*bg + (15 - fg) (sprite_edit_app.py:1096), and the
;;; unfinished curses path assumed the same. It is tempting to treat that as "the
;;; authored intent" and the Win32 path as buggy -- but the Win32 path is what players
;;; actually saw, and it is not a simple inverse: it routes both nibbles through the
;;; permutation tables below and then swaps red and blue via the COLORREF bug.
;;;
;;; This is settled empirically, not by argument. Decoding menu.thm's menu_bg through
;;; the tables below and comparing against a screenshot of the original game gives
;;; 99.76% exact pixel agreement (the remainder is the star field, a separate sprite).
;;; The two tables independently reproduce 23 of 24 observed slot mappings, the lone
;;; outlier being a cell the menu box overlays in the screenshot.
;;;
;;; So :original is the default. See PLAN.md D1.

(defparameter *colour-mapping* :original
  ":original  what the shipped game displayed -- permutation tables plus the R/B swap.
              Verified to 99.76% against a screenshot of the real thing.
   :authored  PySpriteEdit's own convention, bg = pair>>4 and fg = 15-(pair&15), with
              no channel swap. This is what the artists previewed in the editor, but
              it is NOT what the game rendered.")

;;; From g_bgColors / g_fgColors in origRef/Renderer/gam_render.c:584-622, reduced to
;;; palette indices (BACKGROUND_/FOREGROUND_ BLUE=1 GREEN=2 RED=4 INTENSITY=8).
(defparameter *win32-bg-slots*
  #(0 4 5 3 1 2 10 11 12 8 6 7 9 13 14 15))

(defparameter *win32-fg-slots*
  #(15 14 13 9 7 6 8 12 11 10 2 1 3 5 4 0))

(defun channel-swap? ()
  "The original wrote the registry palette as (r<<16)|(g<<8)|b while Win32 COLORREF is
   0x00BBGGRR, so every colour reached the screen with red and blue exchanged."
  (eq *colour-mapping* :original))

(defun glyph-bg-index (g)
  (declare (type glyph g))
  (let ((hi (ash (glyph-pair g) -4)))
    (if (eq *colour-mapping* :original)
        (aref *win32-bg-slots* hi)
        hi)))

(defun glyph-fg-index (g)
  (declare (type glyph g))
  (let ((lo (logand (glyph-pair g) #x0F)))
    (if (eq *colour-mapping* :original)
        (aref *win32-fg-slots* lo)
        (- 15 lo))))

;;; The inverse direction. GLYPH-FG-INDEX and GLYPH-BG-INDEX answer "what palette slot
;;; does this cell paint with"; ENCODE-PAIR answers "what pair paints with this slot",
;;; which is what recolouring a sprite needs. Both tables are permutations of 0-15, so
;;; the inverses are total.

(defun %invert (table)
  (let ((inv (make-array 16)))
    (dotimes (i 16 inv)
      (setf (aref inv (aref table i)) i))))

(defparameter *win32-bg-nibbles* (%invert *win32-bg-slots*))
(defparameter *win32-fg-nibbles* (%invert *win32-fg-slots*))

(defun encode-pair (fg-slot bg-slot)
  "The attribute byte that paints foreground FG-SLOT on background BG-SLOT, under the
   active colour mapping. Inverse of GLYPH-FG-INDEX / GLYPH-BG-INDEX."
  (declare (type (integer 0 15) fg-slot bg-slot))
  (if (eq *colour-mapping* :original)
      (logior (aref *win32-fg-nibbles* fg-slot)
              (ash (aref *win32-bg-nibbles* bg-slot) 4))
      (logior (- 15 fg-slot) (ash bg-slot 4))))

(defun transparent? (g)
  (declare (type glyph g))
  (= g +transparent+))

(defun transparent-bg? (g)
  (declare (type glyph g))
  (= (glyph-mod g) +mod-transparent-bg+))
