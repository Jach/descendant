(in-package #:com.thejach.descendant.font)

;;;; Two on-disk bitmap font formats normalise to one in-memory structure.
;;;;
;;;;   terminal_4x6.bin  char -> PIXELS. Extracted from the Windows console 'Terminal'
;;;;                     face in dosapp.fon by tools/extract_cellfont.py. Every one of
;;;;                     the 28,800 screen cells is drawn with this.
;;;;
;;;;   *.bft             char -> CELLS. The game's own fonts, used to draw large blocky
;;;;                     text: a lit pixel emits a #xDB cell, an unlit one a space.
;;;;                     Produced in 2010 by cropping a window out of hand-drawn
;;;;                     Windows FNT glyphs (Tools/FontEditor/font_main.cpp).
;;;;
;;;; The two are NOT interchangeable -- they compose, since the .bft path emits cells
;;;; that the cell font then renders. Only the storage is shared. Note the opposite bit
;;;; orders below; normalising here keeps that confusion out of every call site.

(defstruct (font (:constructor %make-font))
  (name "" :type string)
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (first-char 0 :type fixnum)
  (count 0 :type fixnum)
  ;; [glyph-index, y, x] -> 1 if lit. Indexed by (- char first-char).
  (bits (make-array '(0 0 0) :element-type 'bit) :type (simple-array bit (* * *))))

(declaim (inline font-covers? font-pixel))

(defun font-covers? (font char)
  (let ((i (- char (font-first-char font))))
    (and (>= i 0) (< i (font-count font)))))

(defun font-pixel (font char y x)
  "1 if the pixel at (X, Y) of CHAR is lit, else 0. Characters the font does not cover
   read as 0 rather than erroring, matching how the original silently rendered
   undrawn glyphs as blanks."
  (if (font-covers? font char)
      (aref (font-bits font) (- char (font-first-char font)) y x)
      0))

(defun font-ink (font char)
  "Number of lit pixels in CHAR. The art shades by glyph density, so this is the
   quantity that actually matters when judging a substitute face."
  (let ((n 0))
    (dotimes (y (font-height font) n)
      (dotimes (x (font-width font))
        (incf n (font-pixel font char y x))))))

(defun glyph-lines (font char)
  "CHAR as a list of strings, '#' lit and '.' unlit. For debugging and tests."
  (loop for y below (font-height font)
        collect (with-output-to-string (s)
                  (dotimes (x (font-width font))
                    (write-char (if (plusp (font-pixel font char y x)) #\# #\.) s)))))

;;; ---------------------------------------------------------------------------
;;; .bft  --  name[24], i32 width, i32 height, then u16 rows[height][95].
;;; Chars #x20..#x7E. Bit x of a row is column x, i.e. LSB is leftmost.
;;; Files are zero-padded to 4096 bytes; the trailing padding is ignored.

(defconstant +bft-first-char+ #x20)
(defconstant +bft-count+ 95 "' ' through '~', per GAM_BEGIN_CHAR/GAM_END_CHAR.")
(defconstant +bft-data-offset+ 32)

(defun read-bft (path)
  (let* ((d (bin:read-file-octets path))
         (name (bin:asciiz d 0 24))
         (width (bin:s32-ref d 24))
         (height (bin:s32-ref d 28))
         (bits (make-array (list +bft-count+ height width) :element-type 'bit
                                                           :initial-element 0)))
    (assert (and (plusp width) (<= width 16)) (width)
            "~a: implausible .bft width ~d (rows are u16)" path width)
    (assert (plusp height) (height) "~a: implausible .bft height ~d" path height)
    (dotimes (i +bft-count+)
      (dotimes (y height)
        (let ((row (bin:u16-ref d (+ +bft-data-offset+ (* 2 (+ (* i height) y))))))
          (dotimes (x width)
            (setf (aref bits i y x) (if (logbitp x row) 1 0))))))   ; LSB = leftmost
    (%make-font :name name :width width :height height
                :first-char +bft-first-char+ :count +bft-count+ :bits bits)))

;;; ---------------------------------------------------------------------------
;;; terminal_4x6.bin  --  no header. 256 glyphs x 6 rows, one byte per row,
;;; bit 7 is the leftmost pixel (the low nibble is unused at 4 wide).

(defconstant +cell-font-width+ 4)
(defconstant +cell-font-height+ 6)
(defconstant +cell-font-count+ 256)

(defun read-cell-atlas (&optional (path (paths:font-path "terminal_4x6.bin")))
  (let ((d (bin:read-file-octets path))
        (bits (make-array (list +cell-font-count+ +cell-font-height+ +cell-font-width+)
                          :element-type 'bit :initial-element 0)))
    (assert (= (length d) (* +cell-font-count+ +cell-font-height+)) ()
            "~a: expected ~d bytes, got ~d"
            path (* +cell-font-count+ +cell-font-height+) (length d))
    (dotimes (i +cell-font-count+)
      (dotimes (y +cell-font-height+)
        (let ((row (aref d (+ (* i +cell-font-height+) y))))
          (dotimes (x +cell-font-width+)
            (setf (aref bits i y x) (if (logbitp (- 7 x) row) 1 0))))))  ; MSB = leftmost
    (%make-font :name "Terminal" :width +cell-font-width+ :height +cell-font-height+
                :first-char 0 :count +cell-font-count+ :bits bits)))
