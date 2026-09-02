(in-package #:com.thejach.descendant.renderer.gl)

;;;; The FAST renderer, after the design in refterm.
;;;;
;;;; The slow one expands the cell buffer into pixels on the CPU: 28,800 cells times 24
;;;; pixels is 691,200 writes a frame, then 2.7 MB uploaded to a streaming texture. Every
;;;; one of those writes is a lookup into two tables and a bit test -- cheap individually,
;;;; and about ten milliseconds together, which is most of a 16 ms frame.
;;;;
;;;; None of that work is necessary. A cell is four bytes; the whole screen is 115 KB.
;;;; refterm's observation is that the expansion is a pure function of (cell, pixel within
;;;; cell), so it belongs in a fragment shader: upload the cells as they already are,
;;;; upload the font once, and let every pixel work out its own colour. The CPU's job
;;;; becomes a single memcpy.
;;;;
;;;; So the frame is:
;;;;
;;;;   cells   240x120 RGBA8UI, the screen's own u32 buffer uploaded unchanged --
;;;;           little-endian puts the character in R, the mod byte in B and the colour
;;;;           pair in A, which is exactly what the shader wants to read
;;;;   atlas   64x96 R8, the 4x6 font as a 16x16 grid of glyphs, uploaded once
;;;;   palette 16 colours and the two Win32 permutation tables, as uniforms
;;;;
;;;; and one draw of one triangle.
;;;;
;;;; The permutation tables go to the GPU rather than being applied on the way: resolving
;;;; them per cell would put the CPU back in the loop for no reason, and they are sixteen
;;;; integers.
;;;;
;;;; Correctness is not argued, it is diffed. RENDER-TO-ARRAY reads the framebuffer back
;;;; so a test can compare this against the slow renderer pixel for pixel; they must agree
;;;; exactly, because they are computing the same function by different means.

(defconstant +atlas-cols+ 16 "Glyphs across the font atlas; 256 of them in a 16x16 grid.")

(defparameter *vertex-shader* "#version 330 core
// No vertex buffer: one oversized triangle covering the viewport, from the vertex index.
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}")

(defparameter *fragment-shader* "#version 330 core
uniform usampler2D cells;   // R = character, B = mod, A = colour pair
uniform sampler2D atlas;    // R8, lit pixels of the 4x6 font
uniform vec3 palette[16];
uniform int fgSlots[16];    // low nibble of the pair -> palette slot
uniform int bgSlots[16];    // high nibble -> palette slot
uniform ivec2 cellSize;
uniform ivec2 gridSize;
uniform int atlasCols;
uniform vec2 outputSize;    // the drawable, which is not 960x720 in fullscreen

out vec4 color;

void main() {
  // Scale the 960x720 picture into the drawable, keeping its aspect and centring it.
  // The SDL path gets this from SDL_RenderSetLogicalSize; here it is arithmetic, and it
  // has to be, because F11 makes the window the size of the desktop.
  vec2 target = vec2(gridSize * cellSize);
  float scale = min(outputSize.x / target.x, outputSize.y / target.y);
  vec2 origin = (outputSize - target * scale) * 0.5;
  vec2 local = (gl_FragCoord.xy - origin) / scale;

  if (local.x < 0.0 || local.y < 0.0 || local.x >= target.x || local.y >= target.y) {
    color = vec4(0.0, 0.0, 0.0, 1.0);   // the letterbox
    return;
  }

  ivec2 px = ivec2(local);
  // GL counts rows up from the bottom; the cell buffer counts down from the top.
  px.y = int(target.y) - 1 - px.y;

  ivec2 cell = px / cellSize;
  ivec2 inCell = px % cellSize;

  uvec4 c = texelFetch(cells, cell, 0);
  int ch = int(c.r);
  int pair = int(c.a);

  int fg = fgSlots[pair & 15];
  int bg = bgSlots[(pair >> 4) & 15];

  ivec2 tile = ivec2(ch % atlasCols, ch / atlasCols);
  float lit = texelFetch(atlas, tile * cellSize + inCell, 0).r;

  color = vec4(lit > 0.5 ? palette[fg] : palette[bg], 1.0);
}")

(defclass gl-renderer ()
  ((font :initarg :font :reader gl-font)
   (program :accessor gl-program :initform nil)
   (vao :accessor gl-vao :initform nil)
   (atlas-texture :accessor gl-atlas-texture :initform nil)
   (cell-texture :accessor gl-cell-texture :initform nil)
   ;; The screen's cells, copied somewhere with a foreign address so GL can read them.
   (cell-buffer :accessor gl-cell-buffer :initform nil)
   (colormap :accessor gl-colormap :initform nil)
   (uniforms :accessor gl-uniforms :initform (make-hash-table :test #'equal))
   (context :accessor gl-context :initform nil)))

;;; ---------------------------------------------------------------------------
;;; Setup

(defun %compile-shader (kind source)
  (let ((shader (gl:create-shader kind)))
    (gl:shader-source shader source)
    (gl:compile-shader shader)
    (let ((log (gl:get-shader-info-log shader)))
      (unless (zerop (length log))
        (error "~a shader: ~a" kind log)))
    shader))

(defun %link-program ()
  (let ((vs (%compile-shader :vertex-shader *vertex-shader*))
        (fs (%compile-shader :fragment-shader *fragment-shader*))
        (program (gl:create-program)))
    (gl:attach-shader program vs)
    (gl:attach-shader program fs)
    (gl:link-program program)
    (let ((log (gl:get-program-info-log program)))
      (unless (zerop (length log))
        (error "linking the cell shader: ~a" log)))
    ;; Attached shaders are kept alive by the program; the handles are not needed again.
    (gl:delete-shader vs)
    (gl:delete-shader fs)
    program))

(defun check-gl (context)
  "Signal if GL is unhappy. Worth doing at every step that sets state: GL fails by
   quietly ignoring the call and leaving whatever was there, so a mistake shows up as a
   wrong picture rather than an error -- the palette going in with the wrong uniform
   call left every colour at zero and drew a black screen."
  (let ((err (gl:get-error)))
    (unless (eq err :zero)
      (error "GL error at ~a: ~a" context err))))

(defun %uniform (self name)
  (or (gethash name (gl-uniforms self))
      (setf (gethash name (gl-uniforms self))
            (let ((location (gl:get-uniform-location (gl-program self) name)))
              (when (minusp location)
                (error "the cell shader has no uniform ~s -- renamed, or optimised out ~
                        because nothing reads it" name))
              location))))

(defun %uniform-vec3-array (self name values)
  "Set a vec3[] uniform an element at a time.

   Not GL:UNIFORMFV, which emits glUniform1fv: for an array of vec3 that is the wrong
   call, GL rejects it, and the uniform keeps its previous value -- zero, which is black."
  (loop for i from 0
        for (r g b) in values
        do (gl:uniformf (%uniform self (format nil "~a[~d]" name i)) r g b)))

(defun %uniform-int-array (self name values)
  (loop for i from 0
        for v in values
        do (gl:uniformi (%uniform self (format nil "~a[~d]" name i)) v)))

(defun %build-atlas (self)
  "The whole font as one R8 texture: 256 glyphs in a 16x16 grid of 4x6 tiles.

   Uploaded once. The font never changes -- it is the Terminal cell font baked into the
   original's renderer, not something a theme can replace."
  (let* ((bits (font:font-bits (gl-font self)))
         (width (* +atlas-cols+ screen:+cell-width+))
         (height (* (/ 256 +atlas-cols+) screen:+cell-height+))
         (pixels (static-vectors:make-static-vector (* width height)
                                                    :element-type '(unsigned-byte 8)
                                                    :initial-element 0)))
    (declare (type (simple-array bit (* * *)) bits))
    (unwind-protect
         (progn
           (dotimes (ch 256)
             (let ((ox (* (mod ch +atlas-cols+) screen:+cell-width+))
                   (oy (* (floor ch +atlas-cols+) screen:+cell-height+)))
               (dotimes (y screen:+cell-height+)
                 (dotimes (x screen:+cell-width+)
                   (setf (aref pixels (+ (* (+ oy y) width) ox x))
                         (if (plusp (aref bits ch y x)) 255 0))))))
           (let ((texture (gl:gen-texture)))
             (gl:bind-texture :texture-2d texture)
             ;; Nearest everywhere and no mipmaps: every fetch is an exact texel, and a
             ;; filtered font would smear glyphs into their neighbours in the atlas.
             (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
             (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
             (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
             (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
             (gl:pixel-store :unpack-alignment 1)   ; rows are 64 bytes, not a multiple of 4
             (gl:tex-image-2d :texture-2d 0 :r8 width height 0 :red :unsigned-byte
                              (static-vectors:static-vector-pointer pixels))
             (setf (gl-atlas-texture self) texture)))
      (static-vectors:free-static-vector pixels))))

(defun %build-cell-texture (self)
  (let ((texture (gl:gen-texture)))
    (gl:bind-texture :texture-2d texture)
    (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
    (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
    (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
    (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
    (gl:tex-image-2d :texture-2d 0 :rgba8ui screen:+cols+ screen:+rows+ 0
                     :rgba-integer :unsigned-byte (cffi:null-pointer))
    (setf (gl-cell-texture self) texture)))

(defun make-gl-renderer (&key (font (font:read-cell-atlas)) colormap context)
  "Build the shader, the atlas and the cell texture. A current GL context is required --
   unlike the slow renderer, none of this can be done headless."
  (let ((self (make-instance 'gl-renderer :font font)))
    (setf (gl-context self) context
          (gl-program self) (%link-program)
          (gl-vao self) (gl:gen-vertex-array)
          (gl-cell-buffer self)
          (static-vectors:make-static-vector (* screen:+cols+ screen:+rows+)
                                             :element-type '(unsigned-byte 32)
                                             :initial-element 0))
    (%build-atlas self)
    (%build-cell-texture self)
    (gl:use-program (gl-program self))
    ;; The constants of the layout, set once.
    (gl:uniformi (%uniform self "cells") 0)
    (gl:uniformi (%uniform self "atlas") 1)
    (gl:uniformi (%uniform self "atlasCols") +atlas-cols+)
    (gl:uniformi (%uniform self "cellSize") screen:+cell-width+ screen:+cell-height+)
    (gl:uniformi (%uniform self "gridSize") screen:+cols+ screen:+rows+)
    (check-gl "setting up the cell shader")
    (%upload-slot-tables self)
    (when colormap (renderer:set-palette self colormap))
    self))

(defmethod renderer:destroy-renderer ((self gl-renderer))
  (when (gl-program self)
    (gl:delete-program (gl-program self))
    (setf (gl-program self) nil))
  (when (gl-vao self)
    (gl:delete-vertex-arrays (list (gl-vao self)))
    (setf (gl-vao self) nil))
  (let ((textures (remove nil (list (gl-atlas-texture self) (gl-cell-texture self)))))
    (when textures (gl:delete-textures textures)))
  (setf (gl-atlas-texture self) nil
        (gl-cell-texture self) nil)
  (when (gl-cell-buffer self)
    (static-vectors:free-static-vector (gl-cell-buffer self))
    (setf (gl-cell-buffer self) nil))
  self)

;;; ---------------------------------------------------------------------------
;;; Colour

(defun %upload-slot-tables (self)
  "The pair-to-palette-slot mapping, as two arrays of sixteen.

   A colour pair is two nibbles, each routed through one of the original's Win32
   permutation tables. That is a lookup the GPU can do as well as we can, and doing it
   here per cell would put the CPU back in the middle of the frame."
  (%uniform-int-array self "fgSlots"
                      (loop for n below 16
                            collect (glyph:glyph-fg-index (glyph:make-glyph 0 n))))
  (%uniform-int-array self "bgSlots"
                      (loop for n below 16
                            collect (glyph:glyph-bg-index
                                     (glyph:make-glyph 0 (ash n 4)))))
  (check-gl "uploading the slot tables"))

(defmethod renderer:set-palette ((self gl-renderer) colormap)
  (gl:use-program (gl-program self))
  ;; Through RENDERER::%ARGB so both renderers get the channel swap from one place; the
  ;; shader wants floats, so it is unpacked again on the way in.
  (%uniform-vec3-array
   self "palette"
   (loop for i below 16
         for argb = (renderer::%argb (theme:colormap-ref colormap i))
         collect (list (/ (ldb (byte 8 16) argb) 255.0)
                       (/ (ldb (byte 8 8) argb) 255.0)
                       (/ (ldb (byte 8 0) argb) 255.0))))
  (check-gl "uploading the palette")
  ;; The permutation depends on GLYPH:*COLOUR-MAPPING*, which a test may rebind between
  ;; frames, so it is refreshed with the palette rather than only at build time.
  (%upload-slot-tables self)
  (setf (gl-colormap self) colormap)
  self)

(defmethod renderer:ensure-palette ((self gl-renderer) colormap)
  (when (and colormap (not (eq colormap (gl-colormap self))))
    (renderer:set-palette self colormap))
  self)

;;; ---------------------------------------------------------------------------
;;; Drawing

(defmethod renderer:rasterize ((self gl-renderer) screen)
  "Copy the cells somewhere GL can reach and upload them. This is the whole of the
   per-frame CPU cost: 115 KB of memcpy, against the slow renderer's 691,200 pixels."
  (let ((buffer (gl-cell-buffer self)))
    (replace buffer (screen:screen-cells screen))
    (gl:active-texture :texture0)
    (gl:bind-texture :texture-2d (gl-cell-texture self))
    (gl:pixel-store :unpack-alignment 4)
    (gl:tex-sub-image-2d :texture-2d 0 0 0 screen:+cols+ screen:+rows+
                         :rgba-integer :unsigned-byte
                         (static-vectors:static-vector-pointer buffer))
    (check-gl "uploading the cells"))
  self)

(defun %drawable-size (self)
  "The framebuffer's size in pixels. Not the window's: on a scaled display they differ,
   and it is the framebuffer the viewport and the shader are talking about."
  (declare (ignorable self))
  (if lgame:*screen*
      (cffi:with-foreign-objects ((w :int) (h :int))
        (sdl2-ffi.functions:sdl-gl-get-drawable-size lgame:*screen* w h)
        (values (max 1 (cffi:mem-ref w :int))
                (max 1 (cffi:mem-ref h :int))))
      (values screen:+pixel-width+ screen:+pixel-height+)))

(defun %draw (self)
  (multiple-value-bind (width height) (%drawable-size self)
    (gl:viewport 0 0 width height)
    (gl:use-program (gl-program self))
    (gl:uniformf (%uniform self "outputSize") (float width) (float height)))
  (gl:use-program (gl-program self))
  (gl:bind-vertex-array (gl-vao self))
  (gl:active-texture :texture0)
  (gl:bind-texture :texture-2d (gl-cell-texture self))
  (gl:active-texture :texture1)
  (gl:bind-texture :texture-2d (gl-atlas-texture self))
  (gl:draw-arrays :triangles 0 3)
  (gl:bind-vertex-array 0))

(defmethod renderer:present ((self gl-renderer))
  (%draw self)
  (sdl2:gl-swap-window lgame:*screen*))

;;; ---------------------------------------------------------------------------
;;; Verification

(defun render-to-array (self)
  "Draw and read the framebuffer back as #x00RRGGBB, top row first -- the same shape the
   slow renderer's pixel buffer has, so the two can be compared directly.

   This is what makes the shader checkable. Reading pixels back is slow and has no place
   in a frame, which is why it is here and not in PRESENT."
  (%draw self)
  (gl:finish)
  (let* ((width screen:+pixel-width+)
         (height screen:+pixel-height+)
         (raw (gl:read-pixels 0 0 width height :rgba :unsigned-byte))
         (out (make-array (* width height) :element-type '(unsigned-byte 32))))
    (dotimes (y height out)
      ;; GL hands back the bottom row first.
      (let ((src (* (- height 1 y) width 4))
            (dst (* y width)))
        (dotimes (x width)
          (let ((o (+ src (* x 4))))
            (setf (aref out (+ dst x))
                  (logior (ash (aref raw (+ o 0)) 16)
                          (ash (aref raw (+ o 1)) 8)
                          (aref raw (+ o 2))))))))))

(defmethod renderer:save-ppm ((self gl-renderer) path)
  (let ((pixels (render-to-array self)))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede :if-does-not-exist :create)
      (let ((header (format nil "P6~%~d ~d~%255~%"
                            screen:+pixel-width+ screen:+pixel-height+)))
        (loop for ch across header do (write-byte (char-code ch) out)))
      (let ((row (make-array (* screen:+pixel-width+ 3)
                             :element-type '(unsigned-byte 8))))
        (dotimes (y screen:+pixel-height+ path)
          (dotimes (x screen:+pixel-width+)
            (let ((p (aref pixels (+ (* y screen:+pixel-width+) x)))
                  (o (* x 3)))
              (setf (aref row (+ o 0)) (ldb (byte 8 16) p)
                    (aref row (+ o 1)) (ldb (byte 8 8) p)
                    (aref row (+ o 2)) (ldb (byte 8 0) p))))
          (write-sequence row out))))))
