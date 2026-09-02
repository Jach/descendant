(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; The main menu, and the CONTINUE row that comes and goes.

(defmacro with-menu ((var &key continue) &body body)
  `(let ((audio:*muted?* t)
         (level:*frame* 0) (level:*state* :play) (level:*current* nil)
         (state:*continue-theme* ,continue)
         (state:*theme* :crash-site)
         (state:*run-score* 0))
     (unwind-protect
          (progn
            (level:start-level :menu)
            (let ((,var level:*current*))
              ,@body))
       (level:shutdown))))

(test continue-is-hidden-until-there-is-something-to-resume
  "The menu is the original's exactly until a run has ended past stage one."
  (with-menu (m)
    (is (= 6 (length (menu::%options m))) "the shipped six")
    (is (null (find :continue (menu::%options m) :key #'first))))
  (with-menu (m :continue :hidden-cave)
    (is (= 7 (length (menu::%options m))))
    (is (eq :continue (first (second (menu::%options m))))
        "directly below START, as asked")))

(test the-panel-grows-with-the-rows
  "Reported bug: the rows shifted down correctly but the background box did not, so EXIT
   hung off the end on bare starfield."
  (let (plain grown)
    (with-menu (m) (setf plain (menu::%main-area-for m)))
    (with-menu (m :continue :hidden-cave) (setf grown (menu::%main-area-for m)))
    (is (> (theme:sprite-height grown) (theme:sprite-height plain))
        "taller with CONTINUE showing")
    (is (= (theme:sprite-width grown) (theme:sprite-width plain)) "same width")))

(test the-list-shifts-up-so-exit-clears-the-ticker
  "Growing the panel downward is not enough on its own: the shipped six already end just
   above the scrolling ticker, so a seventh would push EXIT onto it."
  (is (< (menu::%y-offset 7) (menu::%y-offset 6))
      "the list starts higher when there are more rows")
  ;; Every row, including the last, has to land above the ticker.
  (let* ((rows 7)
         (last-y (menu::%option-y (1- rows) rows)))
    (is (> last-y 0) "the last row is on screen")))

(test the-panel-is-cached-per-size
  "There are only two sizes; rebuilding five thousand cells a frame to discover that
   would be silly."
  (with-menu (m :continue :hidden-cave)
    (is (eq (menu::%main-area-for m) (menu::%main-area-for m)) "same object back")))

(test continuing-does-not-crash-on-the-vanishing-row
  "The reported crash. RESUME-RUN clears the flag that puts CONTINUE on screen, and the
   menu renders another frame before the switch happens -- with the selection naming a
   row that no longer exists, whose position is NIL."
  (with-menu (m :continue :hidden-cave)
    (setf (menu::menu-selection m) :continue)
    (menu::%activate m)
    (is (eq :start (menu::menu-selection m)) "the cursor moved somewhere real")
    (is-false (state:continue-available?) "and the continue was consumed")
    ;; The frame that follows must render.
    (let ((sc (screen:make-screen)))
      (finishes (level:render-level m sc)))))

(test rendering-survives-a-selection-with-no-row
  "Belt and braces for the same class of bug: drawing no cursor for a frame beats dying
   over one."
  (with-menu (m)
    (setf (menu::menu-selection m) :continue)   ; not in the visible list
    (is (null (menu::%option-row m :continue)))
    (let ((sc (screen:make-screen)))
      (finishes (level:render-level m sc)))))

(test start-and-continue-both-reach-the-game
  (with-menu (m :continue :brain-pain)
    (setf (menu::menu-selection m) :start)
    (menu::%activate m)
    (is (eq :descendant level:*requested*))
    (is (eq :crash-site state:*theme*) "START always begins at the first stage"))
  (with-menu (m :continue :brain-pain)
    (setf (menu::menu-selection m) :continue)
    (menu::%activate m)
    (is (eq :descendant level:*requested*))
    (is (eq :brain-pain state:*theme*) "CONTINUE resumes where the run ended")))

(test the-menu-renders-both-ways
  (dolist (continue (list nil :hidden-cave))
    (let ((sc (screen:make-screen)))
      (with-menu (m :continue continue)
        (finishes (level:render-level m sc))
        (screen:composite sc)
        (is (notevery #'zerop (screen:screen-cells sc)))))))

(test the-shipped-layout-is-untouched-without-continue
  "Only the list and its panel may move for an extra option: with the original's six rows
   this screen is checked pixel-for-pixel against a real capture."
  (with-menu (m)
    (is (= menu::+base-main-options+ (length (menu::%options m))))
    (is (= menu::+y-offset+ (menu::%y-offset menu::+base-main-options+))
        "the list starts exactly where it always did")
    (is (= menu::+base-main-area-height+
           (theme:sprite-height (menu::%main-area-for m)))
        "and the panel is the shipped size")))

(defun %banner-and-scroller-rows (m)
  "Where the two banners land, as (banner-top scroller-top), by rendering and reading
   back what was queued rather than by recomputing the arithmetic under test."
  (let ((sc (screen:make-screen)))
    (level:render-level m sc)
    (let ((queued (loop for z below screen:+z-layers+
                        append (coerce (aref (screen::screen-queues sc) z) 'list))))
      (flet ((top-of (sprite)
               (let ((entry (find sprite queued :key #'first)))
                 (and entry (- screen:+rows+ (third entry))))))
        (list (top-of (menu::menu-banner m))
              (top-of (menu::menu-line-break m)))))))

(test the-frame-does-not-move-when-continue-appears
  "Both banners are the frame the menu sits in. A frame that shifts as you step into the
   options and back is worse than a tight fit, so the list and its panel absorb the extra
   row instead."
  (let (plain crowded sub)
    (with-menu (m)
      (setf plain (%banner-and-scroller-rows m)))
    (with-menu (m :continue :hidden-cave)
      (setf crowded (%banner-and-scroller-rows m))
      ;; And on the options page, which is where the jump was visible. The selection has
      ;; to move with the page, as choosing OPTIONS does.
      (setf (menu::menu-page m) :sub
            (menu::menu-selection m) :difficulty)
      (setf sub (%banner-and-scroller-rows m)))
    (is (equal plain crowded)
        "six rows put them at ~a, seven at ~a" plain crowded)
    (is (equal plain sub)
        "the options page puts them at ~a" sub)))

(test the-scroller-is-the-shipped-one
  "It was briefly given an extra row of background on top, to close the gap under EXIT.
   The panel reaches the scroller on its own now, and the extra row was visible."
  (with-menu (m)
    (let ((plain (menu::menu-line-break m)))
      (is (= (theme:sprite-height plain)
             (theme:sprite-height
              (text:text-sprite
               (font:read-bft (paths:font-path "dsc_font_arial_05.bft"))
               menu::*format-break*)))
          "no rows added to the text's own height"))))

(test escape-backs-out-of-the-options-rather-than-quitting
  "Reported: it quit the game. Everywhere else escape means 'not this one', and the
   options screen is somewhere you go to change a setting and come back."
  (with-menu (m)
    (let ((level:*state* :play) (level:*requested* nil))
      (setf (menu::menu-page m) :sub
            (menu::menu-selection m) :difficulty)
      (menu::%activate-escape m)
      (is (eq :main (menu::menu-page m)) "back to the main page")
      (is-false (eq level:*state* :quit) "and the game is still running")
      ;; From the main page it still quits, as the original did.
      (menu::%activate-escape m)
      (is (eq :quit level:*state*)))))

(test nothing-is-left-black-under-the-last-option
  "The reported bug, checked where it happens rather than by eye: with CONTINUE showing,
   every cell from the top of the panel to the top of the scroller must be painted."
  (with-menu (m :continue :hidden-cave)
    (let ((sc (screen:make-screen)))
      (dotimes (i 20) (level:update-level m))
      (level:render-level m sc)
      (screen:composite sc)
      ;; A column running down the middle of the option panel.
      (let* ((x (+ menu::+option-x+ 10))
             (rows (length (menu::%options m)))
             (top (- screen:+rows+ (- (menu::%y-offset rows) 3)))
             (panel-top-row (- screen:+rows+ top))
             (empty (loop for py from panel-top-row below screen:+rows+
                          count (zerop (screen:cell-ref sc x py)))))
        (is (zerop empty)
            "~d empty cells below the panel top in column ~d" empty x)))))
