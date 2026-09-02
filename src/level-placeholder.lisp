(in-package #:com.thejach.descendant.level.placeholder)

;;;; Stand-ins for the levels not yet ported, so the menu's destinations all work and
;;;; the navigation can be exercised end to end. Each shows its title over the menu
;;;; backdrop and returns on any key.
;;;;
;;;; These are scaffolding, not ports. As each real level lands it simply re-registers
;;;; its keyword and the placeholder stops being reachable.

(defconstant +z-star-field+ 0)
(defconstant +z-background+ 1)
(defconstant +z-text+ 9)

(defclass placeholder (level:level)
  ((title :initarg :title :accessor placeholder-title :initform "NOT IMPLEMENTED")
   (return-to :initarg :return-to :accessor placeholder-return-to :initform :menu)
   (theme :accessor placeholder-theme :initform nil)
   (background :accessor placeholder-background :initform nil)
   (star-field :accessor placeholder-star-field :initform nil)
   (title-sprite :accessor placeholder-title-sprite :initform nil)
   (hint-sprite :accessor placeholder-hint-sprite :initform nil)))

(defmacro define-placeholder (keyword class-name title)
  `(progn
     (defclass ,class-name (placeholder) ()
       (:default-initargs :name ,title :title ,title))
     (level:register-level ,keyword ',class-name)))

(define-placeholder :descendant descendant-placeholder "THE DESCENDANT")
(define-placeholder :controls controls-placeholder "CONTROLS")
(define-placeholder :score score-placeholder "HIGH SCORES")
(define-placeholder :credits credits-placeholder "CREDITS")

(defmethod level:load-level ((self placeholder))
  (let ((th (theme:read-theme (paths:theme-path "menu.thm")))
        (hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft"))))
    (setf (placeholder-theme self) th
          (placeholder-background self) (theme:find-sprite th "menu_bg")
          (placeholder-star-field self) (field:make-star-field screen:+cols+
                                                               screen:+rows+)
          (placeholder-title-sprite self)
          (text:text-sprite hud6 (placeholder-title self))
          (placeholder-hint-sprite self)
          (text:text-sprite hud6 "NOT YET PORTED  PRESS ANY KEY"))
    t))

(defmethod level:level-colormap ((self placeholder))
  (theme:theme-colormap (placeholder-theme self)))

(defmethod level:handle-event ((self placeholder) event)
  (when (= (lgame.event:event-type event) lgame::+sdl-keydown+)
    (level:request-level (placeholder-return-to self))
    t))

(defmethod level:render-level ((self placeholder) screen)
  (flet ((centre (sprite y z)
           (screen:enqueue screen sprite
                           (ash (- screen:+cols+ (theme:sprite-width sprite)) -1)
                           y z)))
    (screen:enqueue screen (placeholder-star-field self) 0 screen:+rows+ +z-star-field+)
    (screen:enqueue screen (placeholder-background self) 0 screen:+rows+ +z-background+)
    (centre (placeholder-title-sprite self) (- screen:+rows+ 50) +z-text+)
    (centre (placeholder-hint-sprite self) (- screen:+rows+ 62) +z-text+))
  t)
