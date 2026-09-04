#|
Render the player ship to a PPM, for the Android launcher icon.

    sbcl --script android/make-icon.lisp

Writes android/out/icon.ppm plus the sprite's dimensions on stdout; android/make-icon.sh
turns that into the PNGs aapt2 wants.

The ship is drawn by the game's own renderer rather than by anything new: the theme is
read from assets/, the sprite is enqueued onto a real screen, composited and rasterised
exactly as a frame of play would be. So the icon cannot drift from what the game draws --
if the palette or the sprite changes, re-running this follows it.
|#

#-quicklisp
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))

(push (merge-pathnames "../" (uiop:pathname-directory-pathname *load-truename*))
      asdf:*central-registry*)

(handler-bind ((warning #'muffle-warning))
  (ql:quickload :descendant :silent t))

(in-package #:com.thejach.descendant)

(defun render-icon (&key (theme-name "crash_site.thm") (sprite-name "player")
                         (output "out/icon.ppm"))
  (let* ((theme (theme:read-theme (paths:theme-path theme-name)))
         (sprite (or (theme:find-sprite theme sprite-name)
                     (error "no sprite ~s in ~a; have: ~s"
                            sprite-name theme-name (theme:sprite-names theme))))
         (w (theme:sprite-width sprite))
         (h (theme:sprite-height sprite))
         (screen (screen:make-screen))
         (renderer (renderer:make-renderer)))
    (renderer:set-palette renderer (theme:theme-colormap theme))
    (screen:clear-screen screen)
    ;; Y counts from the BOTTOM -- ENQUEUE puts the sprite's top edge at (rows - y) --
    ;; so +ROWS+ is the top of the screen and the crop below is a fixed +0+0. Passing 0
    ;; here instead places the ship a full screen below the visible area, where it is
    ;; clipped away and the PPM comes out uniformly black.
    (screen:enqueue screen sprite 0 screen:+rows+ 0)
    (screen:composite screen)
    (renderer:rasterize renderer screen)
    (let ((path (merge-pathnames output
                                 (uiop:pathname-directory-pathname *load-truename*))))
      (ensure-directories-exist path)
      (renderer:save-ppm renderer path)
      ;; Consumed by make-icon.sh: cells are 4x6 px, so this is the crop rectangle.
      (format t "~&sprite ~a ~dx~d cells, ~dx~d px~%"
              sprite-name w h (* w screen:+cell-width+) (* h screen:+cell-height+))
      (format t "crop ~dx~d~%" (* w screen:+cell-width+) (* h screen:+cell-height+))
      (format t "ppm ~a~%" (namestring path)))))

(render-icon)
