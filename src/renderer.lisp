(in-package #:com.thejach.descendant.renderer)

;;;; The SLO renderer: expand the 240x120 cell buffer into a 960x720 ARGB pixel buffer
;;;; using the 4x6 cell font, then hand it to SDL as a streaming texture.
;;;;
;;;; Deliberately simple and easy to verify -- SAVE-PPM works with no display at all, so
;;;; output can be diffed in tests. It is also the reference the GL renderer is checked
;;;; against, pixel for pixel, which is the only way to be sure a shader is drawing the
;;;; same picture as the loop it replaces.
;;;;
;;;; The five operations below are generic so the two renderers can share callers. Only
;;;; those five differ; everything about what a frame CONTAINS is settled before either
;;;; is asked to draw it.

(defconstant +pixel-count+ (* screen:+pixel-width+ screen:+pixel-height+))
(defconstant +pitch+ (* screen:+pixel-width+ 4) "Bytes per output row.")

(defgeneric rasterize (renderer screen)
  (:documentation "Take the frame's cells. What that costs is the whole difference
                   between the two renderers."))
(defgeneric present (renderer)
  (:documentation "Put the last rasterised frame on the display."))
(defgeneric destroy-renderer (renderer))
(defgeneric set-palette (renderer colormap))
(defgeneric ensure-palette (renderer colormap)
  (:documentation "Upload COLORMAP if it is not already active. Safe to call every
                   frame."))
(defgeneric save-ppm (renderer path)
  (:documentation "Write the current frame as a binary PPM, for headless comparison."))

(defstruct (renderer (:constructor %make-renderer))
  (font nil :type (or null font:font))
  ;; 16 entries of #xAARRGGBB, alpha forced opaque.
  (palette (make-array 16 :element-type '(unsigned-byte 32) :initial-element #xFF000000)
   :type (simple-array (unsigned-byte 32) (*)))
  (pixels nil)
  (texture nil)
  ;; The colormap currently uploaded, so a per-frame ENSURE-PALETTE is nearly free.
  (colormap nil)
  ;; colour-pair byte -> resolved ARGB, rebuilt whenever the palette changes.
  (bg-lut (make-array 256 :element-type '(unsigned-byte 32) :initial-element #xFF000000)
   :type (simple-array (unsigned-byte 32) (*)))
  (fg-lut (make-array 256 :element-type '(unsigned-byte 32) :initial-element #xFF000000)
   :type (simple-array (unsigned-byte 32) (*))))

(defun make-renderer (&key (font (font:read-cell-atlas)) colormap)
  "Create a renderer and its pixel buffer. Touches no SDL state; a texture is created
   lazily on the first PRESENT, so tests can rasterise headlessly."
  (let ((r (%make-renderer
            :font font
            :pixels (static-vectors:make-static-vector
                     +pixel-count+ :element-type '(unsigned-byte 32)
                                   :initial-element #xFF000000))))
    (when colormap (set-palette r colormap))
    r))

(defmethod destroy-renderer ((renderer renderer))
  (when (renderer-texture renderer)
    (sdl2:destroy-texture (renderer-texture renderer))
    (setf (renderer-texture renderer) nil))
  (when (renderer-pixels renderer)
    (static-vectors:free-static-vector (renderer-pixels renderer))
    (setf (renderer-pixels renderer) nil))
  renderer)

(defun %argb (packed-rgb)
  "#x00RRGGBB -> opaque ARGB, exchanging red and blue when the active colour mapping
   reproduces the original's COLORREF bug."
  (let ((r (ldb (byte 8 16) packed-rgb))
        (g (ldb (byte 8 8) packed-rgb))
        (b (ldb (byte 8 0) packed-rgb)))
    (if (glyph:channel-swap?)
        (logior #xFF000000 (ash b 16) (ash g 8) r)
        (logior #xFF000000 (ash r 16) (ash g 8) b))))

(defmethod set-palette ((renderer renderer) colormap)
  "Load a theme's 16 colours and rebuild the pair lookup tables.

   Without this every colour resolves to the all-black default and the screen stays
   blank -- the original calls g_rdr.set_color_map from OM_load_theme for exactly this
   reason, so the palette must follow the theme.

   Resolving each of the 256 possible colour-pair bytes up front turns the inner
   rasterising loop into two array reads and keeps the mapping policy in one place."
  (let ((p (renderer-palette renderer))
        (bg-lut (renderer-bg-lut renderer))
        (fg-lut (renderer-fg-lut renderer)))
    (dotimes (i 16)
      (setf (aref p i) (%argb (theme:colormap-ref colormap i))))
    (dotimes (pair 256)
      (let ((g (glyph:make-glyph 0 pair)))
        (setf (aref bg-lut pair) (aref p (glyph:glyph-bg-index g))
              (aref fg-lut pair) (aref p (glyph:glyph-fg-index g)))))
    (setf (renderer-colormap renderer) colormap)
    renderer))

(defmethod ensure-palette ((renderer renderer) colormap)
  (when (and colormap (not (eq colormap (renderer-colormap renderer))))
    (set-palette renderer colormap))
  renderer)

(defmethod rasterize ((renderer renderer) screen)
  "Expand the cell buffer into the ARGB pixel buffer: 691,200 pixel writes a frame, which
   is the number the GL path exists to avoid."
  (let ((pixels (renderer-pixels renderer))
        (bg-lut (renderer-bg-lut renderer))
        (fg-lut (renderer-fg-lut renderer))
        (bits (font:font-bits (renderer-font renderer)))
        (cells (screen:screen-cells screen)))
    (declare (type (simple-array (unsigned-byte 32) (*)) bg-lut fg-lut cells)
             (type (simple-array bit (* * *)) bits)
             (optimize (speed 3) (safety 1)))
    (dotimes (cy screen:+rows+ renderer)
      (declare (type fixnum cy))
      (dotimes (cx screen:+cols+)
        (declare (type fixnum cx))
        (let* ((g (aref cells (+ (* cy screen:+cols+) cx)))
               (char (glyph:glyph-char g))
               (pair (glyph:glyph-pair g))
               (bg (aref bg-lut pair))
               (fg (aref fg-lut pair))
               (x0 (* cx screen:+cell-width+))
               (y0 (* cy screen:+cell-height+)))
          (declare (type fixnum char pair x0 y0))
          (dotimes (y screen:+cell-height+)
            (declare (type fixnum y))
            (let ((row (+ (* (+ y0 y) screen:+pixel-width+) x0)))
              (declare (type fixnum row))
              (dotimes (x screen:+cell-width+)
                (declare (type fixnum x))
                (setf (aref pixels (+ row x))
                      (if (plusp (aref bits char y x)) fg bg))))))))))

(defun %ensure-texture (renderer)
  (or (renderer-texture renderer)
      (setf (renderer-texture renderer)
            (sdl2:create-texture lgame:*renderer* :argb8888 :streaming
                                 screen:+pixel-width+ screen:+pixel-height+))))

(defmethod present ((renderer renderer))
  "Upload the pixel buffer and draw it. Assumes lgame has a window and renderer."
  (let ((texture (%ensure-texture renderer)))
    (sdl2:update-texture texture nil
                         (static-vectors:static-vector-pointer (renderer-pixels renderer))
                         +pitch+)
    (lgame.render:clear)
    (sdl2:render-copy lgame:*renderer* texture)
    (lgame.render:present)))

(defmethod save-ppm ((renderer renderer) path)
  "Write the current pixel buffer as a binary PPM. No display required, which makes
   this the workhorse for headless verification."
  (let ((pixels (renderer-pixels renderer)))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede :if-does-not-exist :create)
      (let ((header (format nil "P6~%~d ~d~%255~%"
                            screen:+pixel-width+ screen:+pixel-height+)))
        (loop for ch across header do (write-byte (char-code ch) out)))
      (let ((row (make-array (* screen:+pixel-width+ 3) :element-type '(unsigned-byte 8))))
        (dotimes (y screen:+pixel-height+ path)
          (dotimes (x screen:+pixel-width+)
            (let ((p (aref pixels (+ (* y screen:+pixel-width+) x)))
                  (o (* x 3)))
              (setf (aref row (+ o 0)) (ldb (byte 8 16) p)
                    (aref row (+ o 1)) (ldb (byte 8 8) p)
                    (aref row (+ o 2)) (ldb (byte 8 0) p))))
          (write-sequence row out))))))
