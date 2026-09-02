(in-package #:com.thejach.descendant.theme)

;;;; .thm layout (verified byte-exact against every shipped theme):
;;;;
;;;;   [0]   char name[16]
;;;;   [16]  {u8 r, g, b, pad}[16]     the palette
;;;;   [80]  u32 id
;;;;   [84]  i32 nSprites
;;;;   then nSprites x {
;;;;       char name[32]; u32 objID; i32 width, height, nFrames, extraBytes, offset;
;;;;       u32 glyphs[nFrames * width * height];
;;;;   }
;;;;
;;;; The 56-byte sprite header is sizeof(GameSpriteData) minus the 8-byte data
;;;; placeholder, which is what dsc_object_manager.c:69 computes.
;;;;
;;;; intro.thm, menu.thm and credits.thm carry junk after the last sprite. The original
;;;; ignores it because it only ever reads nSprites, so we do too.

(defconstant +palette-size+ 16)
(defconstant +colormap-name-length+ 16)
(defconstant +sprite-name-length+ 32)
(defconstant +sprite-header-size+ 56)
(defconstant +sprite-table-offset+ 84)

(defstruct (colormap (:constructor %make-colormap))
  (name "" :type string)
  (id 0 :type (unsigned-byte 32))
  ;; 16 entries of packed #x00RRGGBB.
  (colors (make-array +palette-size+ :element-type '(unsigned-byte 32))
   :type (simple-array (unsigned-byte 32) (*))))

(declaim (inline color-red color-green color-blue colormap-ref))

(defun color-red   (c) (ldb (byte 8 16) c))
(defun color-green (c) (ldb (byte 8 8) c))
(defun color-blue  (c) (ldb (byte 8 0) c))

(defun colormap-ref (colormap index)
  "Packed #x00RRGGBB for palette slot INDEX."
  (aref (colormap-colors colormap) index))

(defstruct (sprite (:constructor %make-sprite))
  (name "" :type string)
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (frames 1 :type fixnum)
  (extra-bytes 0 :type fixnum)
  (glyphs (make-array 0 :element-type '(unsigned-byte 32))
   :type (simple-array (unsigned-byte 32) (*))))

(defun make-sprite (name width height glyphs &optional (frames 1))
  "Build a sprite that did not come from a .thm -- text rendered from a .bft font, a
   generated star field, and so on. GLYPHS is row-major within each frame."
  (assert (= (length glyphs) (* frames width height)) ()
          "make-sprite ~s: expected ~d glyphs, got ~d"
          name (* frames width height) (length glyphs))
  (%make-sprite :name name :width width :height height :frames frames
                :glyphs (if (typep glyphs '(simple-array (unsigned-byte 32) (*)))
                            glyphs
                            (make-array (length glyphs)
                                        :element-type '(unsigned-byte 32)
                                        :initial-contents (coerce glyphs 'list)))))

(declaim (inline sprite-frame-offset sprite-ref))

(defun sprite-frame-offset (sprite frame)
  (* frame (sprite-width sprite) (sprite-height sprite)))

(defun sprite-ref (sprite frame y x)
  "The glyph at cell (X, Y) of FRAME. Row-major within a frame."
  (aref (sprite-glyphs sprite)
        (+ (sprite-frame-offset sprite frame) (* y (sprite-width sprite)) x)))

;;; ---------------------------------------------------------------------------
;;; Recolouring a sprite into a foreign palette.
;;;
;;; Only one colormap is uploaded per frame (RENDERER:ENSURE-PALETTE), so a sprite shown
;;; on a screen that belongs to another theme is painted with that theme's colours. The
;;; slot indices survive; their meanings do not. Slot 11 is bright green in crash_site
;;; and dark blue in credits, so a floogle dropped onto the credit roll arrives blue.
;;;
;;; Matching by nearest RGB goes badly, because the credits palette is a near-monochrome
;;; film ramp with no green in it at all -- every green in the source collapses onto the
;;; one or two least-wrong slots and the sprite loses its internal shading. Matching by
;;; LUMINANCE instead keeps that shading, which is what actually reads as shape: dark
;;; outlines stay dark, highlights stay bright, and the sprite comes out toned to the
;;; destination the way a duotone print would be.

(defun color-luminance (packed-rgb)
  "Rec. 709 luma of a packed #x00RRGGBB, as the renderer would show it. Red and blue may
   be exchanged on the way to the screen; their weights exchange with them."
  (let ((r (color-red packed-rgb))
        (g (color-green packed-rgb))
        (b (color-blue packed-rgb)))
    (when (glyph:channel-swap?) (rotatef r b))
    (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b))))

(defun luminance-map (from to)
  "A 16-entry vector mapping each slot of colormap FROM to the slot of TO closest to it
   in brightness."
  (let ((table (make-array +palette-size+ :element-type '(unsigned-byte 8))))
    (dotimes (i +palette-size+ table)
      (let ((target (color-luminance (colormap-ref from i)))
            (best 0)
            (best-distance nil))
        (dotimes (j +palette-size+)
          (let ((d (abs (- target (color-luminance (colormap-ref to j))))))
            (when (or (null best-distance) (< d best-distance))
              (setf best-distance d best j))))
        (setf (aref table i) best)))))

(defun recolor-sprite (sprite table &optional name)
  "A copy of SPRITE with every cell's colours sent through TABLE, a slot-to-slot map from
   LUMINANCE-MAP. Transparent cells and the character codes are untouched, so the shape
   and any animation frames come through unchanged."
  (let* ((source (sprite-glyphs sprite))
         (glyphs (make-array (length source) :element-type '(unsigned-byte 32))))
    (dotimes (i (length source))
      (let ((g (aref source i)))
        (setf (aref glyphs i)
              (if (glyph:transparent? g)
                  g
                  (glyph:make-glyph (glyph:glyph-char g)
                                    (glyph:encode-pair
                                     (aref table (glyph:glyph-fg-index g))
                                     (aref table (glyph:glyph-bg-index g)))
                                    (glyph:glyph-mod g))))))
    (%make-sprite :name (or name (sprite-name sprite))
                  :width (sprite-width sprite)
                  :height (sprite-height sprite)
                  :frames (sprite-frames sprite)
                  :extra-bytes (sprite-extra-bytes sprite)
                  :glyphs glyphs)))

(defstruct (theme (:constructor %make-theme))
  (name "" :type string)
  (colormap (%make-colormap) :type colormap)
  (sprites (make-hash-table :test #'equal) :type hash-table))

(defun find-sprite (theme name)
  (gethash name (theme-sprites theme)))

(defun sprite-names (theme)
  (loop for k being the hash-keys of (theme-sprites theme) collect k))

(defun recolor-theme (theme colormap &optional names)
  "A copy of THEME toned into COLORMAP, so its sprites can be shown on a screen that
   belongs to another theme. NAMES limits the work to the sprites actually wanted.

   The result carries COLORMAP as its own, which is the honest thing to report: these
   sprites are now expressed in that palette and would be wrong under any other."
  (let* ((table (luminance-map (theme-colormap theme) colormap))
         (sprites (make-hash-table :test #'equal)))
    (dolist (name (or names (sprite-names theme)))
      (let ((s (find-sprite theme name)))
        (when s (setf (gethash name sprites) (recolor-sprite s table)))))
    (%make-theme :name (theme-name theme) :colormap colormap :sprites sprites)))

(defun %read-colormap (d)
  (let ((colors (make-array +palette-size+ :element-type '(unsigned-byte 32))))
    (dotimes (i +palette-size+)
      (let ((o (+ +colormap-name-length+ (* i 4))))
        (setf (aref colors i)
              (logior (ash (bin:u8-ref d o) 16)          ; r
                      (ash (bin:u8-ref d (+ o 1)) 8)     ; g
                      (bin:u8-ref d (+ o 2))))))         ; b   (4th byte is padding)
    (%make-colormap :name (bin:asciiz d 0 +colormap-name-length+)
                    :id (bin:u32-ref d 80)
                    :colors colors)))

;;; ---------------------------------------------------------------------------
;;; The hidden cave's palette.
;;;
;;; hidden_cave overrides palette slots 8 and 13 with browns, intending a brown cave.
;;; The renderer's COLORREF swap turns them blue, which is how level 2 shipped as the
;;; accidental "ice cave" (PLAN.md D1). Both looks are worth having, so pre-swapping
;;; those two slots at load time cancels the render-time swap and restores the brown.

(defparameter *hidden-cave-palette* :brown
  ":brown  slots 8 and 13 pre-swapped so the cave renders as the brown it was drawn
            as. The default -- it is what the level was meant to look like.
   :ice    left alone, so the render-time R/B swap turns them blue and the cave
            appears exactly as it shipped.

   Only affects hidden_cave; every other theme is untouched either way.")

(defparameter *cave-fixup-slots* '(8 13))

(defun %swap-rb (packed)
  (logior (ash (ldb (byte 8 0) packed) 16)
          (ash (ldb (byte 8 8) packed) 8)
          (ldb (byte 8 16) packed)))

(defun %apply-cave-palette (colormap)
  "Pre-swap the cave's two brown slots when :brown is selected, so the renderer's swap
   cancels out and they reach the screen as the authored browns."
  (when (and (eq *hidden-cave-palette* :brown)
             (string-equal "hidden_cave" (colormap-name colormap)))
    (dolist (slot *cave-fixup-slots*)
      (setf (aref (colormap-colors colormap) slot)
            (%swap-rb (aref (colormap-colors colormap) slot)))))
  colormap)

(defun read-theme (path)
  (let* ((d (bin:read-file-octets path))
         (colormap (%apply-cave-palette (%read-colormap d)))
         (n (bin:s32-ref d +sprite-table-offset+))
         (sprites (make-hash-table :test #'equal :size (max 1 n)))
         (offset (+ +sprite-table-offset+ 4)))
    (assert (<= 0 n 4096) (n) "~a: implausible sprite count ~d" path n)
    (dotimes (i n)
      (let* ((name (bin:asciiz d offset +sprite-name-length+))
             (width (bin:s32-ref d (+ offset 36)))
             (height (bin:s32-ref d (+ offset 40)))
             (frames (bin:s32-ref d (+ offset 44)))
             (extra (bin:s32-ref d (+ offset 48)))
             (cells (* frames width height))
             (glyphs (make-array cells :element-type '(unsigned-byte 32))))
        (incf offset +sprite-header-size+)
        (assert (<= (+ offset (* 4 cells)) (length d)) ()
                "~a: sprite ~s (~dx~d x~d) runs past end of file"
                path name width height frames)
        (dotimes (j cells)
          (setf (aref glyphs j) (bin:u32-ref d (+ offset (* 4 j)))))
        (incf offset (* 4 cells))
        (setf (gethash name sprites)
              (%make-sprite :name name :width width :height height
                            :frames frames :extra-bytes extra :glyphs glyphs))))
    (%make-theme :name (colormap-name colormap) :colormap colormap :sprites sprites)))
