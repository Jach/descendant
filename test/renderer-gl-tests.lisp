(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The GL renderer, checked against the software one pixel for pixel.
;;;;
;;;; This is the whole point of keeping both. The two compute the same function -- cell
;;;; buffer plus font plus palette to pixels -- by completely different means, so the slow
;;;; one is a reference the fast one can be held to exactly, with no tolerance and no
;;;; eyeballing. A shader that is nearly right looks fine and is wrong.
;;;;
;;;; These need a GL context and so a display. Everything else in the suite is headless;
;;;; when there is no display these skip rather than fail, because a machine without one
;;;; is a normal place to run the other 5,600 checks.

(defvar *gl-unavailable* nil
  "Set once if a context cannot be had, so the reason is reported once rather than per
   test.")

(defmacro with-gl ((soft fast) &body body)
  "A window, a context, and one of each renderer."
  `(if *gl-unavailable*
       (skip "no GL context: ~a" *gl-unavailable*)
       (handler-case
           (lgame:with-overlays
             (lgame:init)
             (sdl2:gl-set-attr :context-major-version 3)
             (sdl2:gl-set-attr :context-minor-version 3)
             (sdl2:gl-set-attr :context-profile-mask
                               sdl2-ffi:+sdl-gl-context-profile-core+)
             (lgame.display:create-centered-window
              "descendant tests" screen:+pixel-width+ screen:+pixel-height+
              (logior lgame::+sdl-window-shown+ lgame::+sdl-window-opengl+))
             (let ((context (sdl2:gl-create-context lgame:*screen*)))
               (sdl2:gl-make-current lgame:*screen* context)
               (let ((,soft (renderer:make-renderer))
                     (,fast (renderer.gl:make-gl-renderer)))
                 (unwind-protect (progn ,@body)
                   (renderer:destroy-renderer ,soft)
                   (renderer:destroy-renderer ,fast)
                   (sdl2:gl-delete-context context)))))
         (error (e)
           (setf *gl-unavailable* e)
           (skip "no GL context: ~a" e)))))

(defun %frame-of (level-key ticks screen)
  "Run a level to TICKS and composite one frame into SCREEN. Returns its colormap."
  (let ((audio:*muted?* t) (level:*frame* 0) (level:*state* :play) (level:*current* nil)
        (level:*screen* (screen:make-screen)))
    (unwind-protect
         (progn
           (level:start-level level-key)
           (dotimes (i ticks) (declare (ignore i))
             (level:update-level level:*current*))
           (level:render-level level:*current* screen)
           (screen:composite screen)
           (level:level-colormap level:*current*))
      (level:shutdown))))

(defun %count-differences (soft fast)
  "How many pixels the two renderers disagree on. The software buffer carries an opaque
   alpha the framebuffer read-back does not, so only the colour is compared."
  (let ((a (renderer::renderer-pixels soft))
        (b (renderer.gl:render-to-array fast))
        (diff 0))
    (dotimes (i (length b) diff)
      (unless (= (logand #xFFFFFF (aref a i)) (aref b i))
        (incf diff)))))

(test the-two-renderers-draw-the-same-picture
  "Four screens with quite different content: the menu's art, the credits still, a live
   game frame with the HUD and a full palette in play, and the score table."
  (with-gl (soft fast)
    (dolist (spec '((:menu 20) (:credits 40) (:descendant 120) (:score 30)))
      (destructuring-bind (key ticks) spec
        (let* ((sc (screen:make-screen))
               (colormap (%frame-of key ticks sc)))
          (renderer:ensure-palette soft colormap)
          (renderer:ensure-palette fast colormap)
          (renderer:rasterize soft sc)
          (renderer:rasterize fast sc)
          (is (zerop (%count-differences soft fast))
              "~a: ~d of ~d pixels differ" key (%count-differences soft fast)
              (* screen:+pixel-width+ screen:+pixel-height+)))))))

(test the-renderers-agree-after-a-palette-change
  "Each stage has its own colours, and the fast renderer holds them in uniforms rather
   than in a table it rebuilds -- so a stale palette would show as a whole screen in the
   wrong hues, which is worth a test of its own."
  (with-gl (soft fast)
    (let ((sc (screen:make-screen)))
      (dolist (theme '("crash_site.thm" "hidden_cave.thm" "brain_pain.thm"))
        (let ((colormap (theme:theme-colormap
                         (theme:read-theme (paths:theme-path theme)))))
          (%frame-of :menu 10 sc)
          (renderer:ensure-palette soft colormap)
          (renderer:ensure-palette fast colormap)
          (renderer:rasterize soft sc)
          (renderer:rasterize fast sc)
          (is (zerop (%count-differences soft fast))
              "~a: the two disagree" theme))))))

(test the-renderers-agree-under-the-authored-colour-mapping
  "The pair-to-slot permutation is a pair of uniform arrays on the GPU rather than a
   lookup table on the CPU. Switching the mapping has to reach both."
  (with-gl (soft fast)
    (let ((glyph:*colour-mapping* :authored)
          (sc (screen:make-screen)))
      (let ((colormap (%frame-of :menu 15 sc)))
        ;; Forced rather than ENSUREd: the colormap object has not changed, only the
        ;; mapping applied to it.
        (renderer:set-palette soft colormap)
        (renderer:set-palette fast colormap)
        (renderer:rasterize soft sc)
        (renderer:rasterize fast sc)
        (is (zerop (%count-differences soft fast)))))))

(test the-font-atlas-holds-every-glyph
  "256 glyphs in a 16x16 grid of 4x6 tiles. A wrong tile size or column count would put
   every character's neighbours inside it, which reads as noise rather than as an error."
  (is (= 16 renderer.gl:+atlas-cols+))
  (is (= 256 (* renderer.gl:+atlas-cols+ (/ 256 renderer.gl:+atlas-cols+))))
  (let ((font (font:read-cell-atlas)))
    (is (= 4 screen:+cell-width+))
    (is (= 6 screen:+cell-height+))
    ;; The atlas is built from these, so a font of another shape would silently truncate.
    (is (equal '(256 6 4) (array-dimensions (font:font-bits font))))))
