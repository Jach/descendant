(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-test-hud ()
  (hud:make-hud (font:read-bft (paths:font-path "dsc_font_hud_04.bft"))
                (font:read-bft (paths:font-path "dsc_font_hud_06.bft"))))

(defun count-lit-bars (sprite)
  (count hud:+glyph-on+ (theme:sprite-glyphs sprite)))

(defun count-spent-bars (sprite)
  (count hud:+glyph-off+ (theme:sprite-glyphs sprite)))

(test hud-meter-dimensions
  "Two cells per bar, four rows tall: 35 health bars and 20 shield bars."
  (let ((h (make-test-hud)))
    (is (= 70 (theme:sprite-width (hud:hud-health-bar h))) "35 bars x 2 cells")
    (is (= 4 (theme:sprite-height (hud:hud-health-bar h))))
    (is (= 40 (theme:sprite-width (hud:hud-shield-bar h))) "20 bars x 2 cells")))

(test hud-bar-fills-proportionally
  (let* ((h (make-test-hud))
         (bar (hud:hud-health-bar h)))
    (hud:set-bar bar 100 100)
    ;; Bars sit on every other column, inset one row top and bottom: 35 bars x 2 rows.
    (is (= 70 (count-lit-bars bar)) "full health lights every bar on both rows")
    (is (= 0 (count-spent-bars bar)))
    (hud:set-bar bar 100 50)
    (is (= 34 (count-lit-bars bar)) "half of 35 bars, truncated, over two rows")
    (is (plusp (count-spent-bars bar)))
    (hud:set-bar bar 100 0)
    (is (= 0 (count-lit-bars bar)) "empty lights nothing")))

(test hud-bar-handles-a-zero-maximum
  "Guard against a divide by zero before any player is attached."
  (let ((bar (hud:hud-health-bar (make-test-hud))))
    (finishes (hud:set-bar bar 0 0))
    (is (= 0 (count-lit-bars bar)))))

(test hud-score-is-zero-padded
  (let ((h (make-test-hud)))
    (hud:set-score h 1234)
    (is (= 1234 (hud:hud-score h)))
    ;; SCORE:00000000: is 15 characters in the 4-wide HUD font.
    (is (= 60 (theme:sprite-width (hud:hud-score-sprite h))) "15 chars x 4 cells")))

(test hud-updates-only-on-change
  "The original caches each value and skips rebuilding the sprite when it has not
   moved, which matters because a rebuild re-rasterises every cell."
  (let* ((h (make-test-hud)))
    (hud:update h :score 500 :health 100 :max-health 150)
    (let ((sprite (hud:hud-score-sprite h)))
      (hud:update h :score 500)
      (is (eq sprite (hud:hud-score-sprite h)) "same score, same sprite object")
      (hud:update h :score 600)
      (is (not (eq sprite (hud:hud-score-sprite h))) "a new score rebuilds it"))))

(test hud-tracks-player-values
  (let ((h (make-test-hud))
        (p (make-test-player)))
    (hud:update h :health (player:player-health p)
                  :max-health (player:player-max-health p)
                  :shields (player:player-shields p)
                  :max-shields (player:player-max-shields p)
                  :score (player:player-score p))
    (is (= 150 (hud:hud-health h)))
    (is (= 10 (hud:hud-shields h)))
    (is (= 70 (count-lit-bars (hud:hud-health-bar h))) "full health")
    ;; Take damage and watch the meter fall.
    (player:hit p :enemy-ship)
    (hud:update h :health (player:player-health p)
                  :max-health (player:player-max-health p))
    (is (< (count-lit-bars (hud:hud-health-bar h)) 70))))

(test hud-fps-readout-is-optional
  (let ((h (make-test-hud)))
    (is-false (hud:hud-show-fps? h) "off by default")
    (hud:toggle-fps h)
    (is-true (hud:hud-show-fps? h))
    (hud:update h :fps 62.5)
    (is (< (abs (- 62.5 (hud:hud-fps h))) 0.01))))

(test hud-renders
  (let ((h (make-test-hud))
        (s (screen:make-screen)))
    (hud:update h :score 1234 :health 100 :max-health 150 :shields 5 :max-shields 10)
    (hud:render h s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)))
    ;; Y counts up from the bottom, so the score's Y of rows-2 puts its top row at
    ;; screen row 2 -- the upper-left corner, not the lower.
    (is (notevery #'zerop (loop for x from 2 below 60
                                collect (screen:cell-ref s x 3)))
        "the score line drew near the top-left")))

(test hud-pause-banner
  (let ((h (make-test-hud))
        (plain (screen:make-screen))
        (paused (screen:make-screen)))
    (hud:render h plain)
    (screen:composite plain)
    (hud:toggle-pause h)
    (is-true (hud:hud-paused? h))
    (hud:render h paused)
    (screen:composite paused)
    (is (> (count-if-not #'zerop (screen:screen-cells paused))
           (count-if-not #'zerop (screen:screen-cells plain)))
        "the banner adds cells")
    ;; The reported bug: the banner stayed up after unpausing. It has to be a toggle,
    ;; because UPDATE does not run while paused and so can never clear a flag.
    (hud:toggle-pause h)
    (is-false (hud:hud-paused? h))
    (let ((again (screen:make-screen)))
      (hud:render h again)
      (screen:composite again)
      (is (equalp (screen:screen-cells plain) (screen:screen-cells again))
          "and unpausing puts the screen back exactly as it was"))))

(test hud-meters-turn-yellow-while-invulnerable
  "The meters ARE the power-up's readout -- there is no separate indicator anywhere on
   the HUD, which is why the background glyph changing is the whole effect."
  (let ((h (make-test-hud)))
    (is (= hud:+glyph-bg+ (hud:hud-stat-bg h)) "normal to start")
    (hud:update h :status :invulnerable)
    (is (= hud:+glyph-invuln-bg+ (hud:hud-stat-bg h)))
    (is (find hud:+glyph-invuln-bg+ (theme:sprite-glyphs (hud::hud-shield-bar h)))
        "and the shield meter was actually repainted")
    (is (find hud:+glyph-invuln-bg+ (theme:sprite-glyphs (hud::hud-health-bar h)))
        "as was the health meter")))

(test hud-meters-return-to-normal-when-the-powerup-lapses
  (let ((h (make-test-hud)))
    (hud:update h :status :invulnerable)
    (hud:update h :status :play)
    (is (= hud:+glyph-bg+ (hud:hud-stat-bg h)))
    (is (null (find hud:+glyph-invuln-bg+ (theme:sprite-glyphs (hud::hud-shield-bar h))))
        "no yellow left anywhere")))

(test invulnerability-blanks-the-meters-rather-than-tinting-them
  "The asymmetry between the two branches IS the effect. Both repaint, which wipes the
   lit bars -- but only the :PLAY branch clears the cached health and shields. So going
   invulnerable leaves the meters SOLID YELLOW with no bars at all until something
   actually changes, while coming back forces them to redraw immediately."
  (let ((h (make-test-hud)))
    (hud:update h :health 100 :max-health 150 :shields 5 :max-shields 10)
    (is (find hud:+glyph-on+ (theme:sprite-glyphs (hud::hud-health-bar h))) "bars lit")

    (hud:update h :status :invulnerable)
    (is (= 100 (hud::hud-health h)) "cache deliberately NOT cleared")
    (is (= 5 (hud::hud-shields h)))
    ;; Same values again: UPDATE sees no change, so the meters stay blank.
    (hud:update h :health 100 :max-health 150 :shields 5 :max-shields 10)
    (is (null (find hud:+glyph-on+ (theme:sprite-glyphs (hud::hud-health-bar h))))
        "no bars -- the meter is solid yellow")
    (is (every (lambda (g) (= g hud:+glyph-invuln-bg+))
               (theme:sprite-glyphs (hud::hud-health-bar h)))
        "every cell of it")

    ;; A real change during the power-up does paint bars back over the yellow.
    (hud:update h :health 90 :max-health 150)
    (is (find hud:+glyph-on+ (theme:sprite-glyphs (hud::hud-health-bar h))))
    (is (find hud:+glyph-invuln-bg+ (theme:sprite-glyphs (hud::hud-health-bar h)))
        "on a yellow background")))

(test returning-to-play-redraws-the-bars-immediately
  "`d_shields = 0; d_health = 0;` -- the original clears the cache here and only here."
  (let ((h (make-test-hud)))
    (hud:update h :health 100 :max-health 150 :shields 5 :max-shields 10)
    (hud:update h :status :invulnerable)
    (hud:update h :status :play)
    (is (= 0 (hud::hud-health h)) "cache cleared, with 0 as the original uses")
    (is (= 0 (hud::hud-shields h)))
    (hud:update h :health 100 :max-health 150 :shields 5 :max-shields 10)
    (is (find hud:+glyph-on+ (theme:sprite-glyphs (hud::hud-health-bar h)))
        "the bars came straight back")
    (is (null (find hud:+glyph-invuln-bg+
                    (theme:sprite-glyphs (hud::hud-health-bar h))))
        "and no yellow is left")))

(test hud-other-states-leave-the-meters-alone
  "Only :INVULNERABLE and :PLAY say anything; dying does not reset a running power-up."
  (let ((h (make-test-hud)))
    (hud:update h :status :invulnerable)
    (hud:update h :status :dead)
    (is (= hud:+glyph-invuln-bg+ (hud:hud-stat-bg h)))))

;;; ---------------------------------------------------------------------------
;;; The shield banner

(test shield-change-raises-the-banner
  "Losing a shield is the only irreversible thing that happens to you, so it is the one
   thing on the HUD that demands attention.

   The very first reading counts as a change, because the cached shield count starts at
   nothing -- so the banner flashes 100% as a level opens. That is the original too:
   HUD_initTheme leaves d_shields at 0 and the first update sees ten."
  (let ((h (make-test-hud)))
    (hud:update h :shields 10 :max-shields 10)
    (is-true (hud:hud-banner-visible? h) "flashes on the opening reading")
    ;; Let it lapse, then take a hit.
    (dotimes (i (1+ hud:+banner-delta+)) (hud:update h))
    (is-false (hud:hud-banner-visible? h))
    (hud:update h :shields 9 :max-shields 10)
    (is-true (hud:hud-banner-visible? h))
    (is (= hud:+banner-delta+ (hud:hud-banner-delta h)))))

(test banner-reports-the-percentage
  "Three digits wide whatever the value, matching the original's in-place write of a
   fixed-width field into `<< SHIELDS AT 100% >>`."
  (let ((h (make-test-hud)))
    (hud:update h :shields 9 :max-shields 10)
    (is (= (* 6 (length "<< SHIELDS AT 090% >>"))
           (theme:sprite-width (hud:hud-banner-sprite h)))
        "21 characters in the 6-wide HUD font")
    ;; And a 100% banner is exactly as wide, which is the point of the padding.
    (let ((wide (theme:sprite-width (hud:hud-banner-sprite h))))
      (hud:update h :shields 10 :max-shields 10)
      (is (= wide (theme:sprite-width (hud:hud-banner-sprite h)))))))

(test banner-flashes-then-goes-away
  (let ((h (make-test-hud)))
    (hud:update h :shields 10 :max-shields 10)
    (hud:update h :shields 9 :max-shields 10)
    (let ((flips 0)
          (last t))
      (dotimes (i hud:+banner-delta+)
        (hud:update h)
        (unless (eq last (hud:hud-banner-visible? h))
          (incf flips)
          (setf last (hud:hud-banner-visible? h))))
      (is (> flips 5) "it blinked several times, got ~d flips" flips)
      (is-false (hud:hud-banner-visible? h) "and is gone by the end"))))

(test banner-is-suppressed-while-invulnerable
  "The original tests the PREVIOUS tick's status, so the power-up has to already have
   been running -- and the tick it lapses on is still quiet."
  (let ((h (make-test-hud)))
    ;; Settle into the power-up and let any opening banner expire.
    (hud:update h :shields 10 :max-shields 10 :status :invulnerable)
    (dotimes (i (1+ hud:+banner-delta+)) (hud:update h :status :invulnerable))
    (is-false (hud:hud-banner-visible? h))
    ;; Now a hit lands while it is up: no banner.
    (hud:update h :shields 9 :max-shields 10 :status :invulnerable)
    (is-false (hud:hud-banner-visible? h) "silent while invulnerable")
    ;; And the tick it lapses on is judged by the PREVIOUS status, so also silent.
    (hud:update h :shields 8 :max-shields 10 :status :play)
    (is-false (hud:hud-banner-visible? h) "still silent on the lapsing tick")
    ;; The next one is not.
    (hud:update h :shields 7 :max-shields 10 :status :play)
    (is-true (hud:hud-banner-visible? h))))

(test banner-renders-centred
  (let ((h (make-test-hud))
        (plain (screen:make-screen))
        (flashing (screen:make-screen)))
    (hud:render h plain)
    (screen:composite plain)
    (hud:update h :shields 10 :max-shields 10)
    (hud:update h :shields 9 :max-shields 10)
    (hud:render h flashing)
    (screen:composite flashing)
    (is (> (count-if-not #'zerop (screen:screen-cells flashing))
           (count-if-not #'zerop (screen:screen-cells plain)))
        "the banner adds cells")))

(test cheat-shows-as-a-permanent-powerup
  "iddqd reads on the HUD as invulnerability that never lapses."
  (let ((h (make-test-hud))
        (p (make-test-player))
        (player:*invincible?* t))
    (hud:update h :status (player:effective-status p))
    (is (= hud:+glyph-invuln-bg+ (hud:hud-stat-bg h)))))

(test a-real-powerup-cannot-switch-the-cheat-off
  "The reported requirement: collecting an I power-up while the cheat is on, and letting
   it lapse, must not take the yellow away. That works because EFFECTIVE-STATUS derives
   the display rather than the power-up assigning it."
  (let ((h (make-test-hud))
        (p (make-test-player))
        (player:*invincible?* t))
    (player:hit p :collectable :collectable-name "collect_invuln")
    (is (eq :invulnerable (player:effective-status p)))
    ;; Run the power-up all the way out.
    (setf (player:player-invuln p) 1)
    (player:update p)
    (is (eq :play (player:player-status p)) "the power-up itself lapsed")
    (is (eq :invulnerable (player:effective-status p)) "but the cheat has not")
    (hud:update h :status (player:effective-status p))
    (is (= hud:+glyph-invuln-bg+ (hud:hud-stat-bg h)) "so the meters stay yellow")))

(test cheat-does-not-mask-the-states-the-level-needs
  "Dying, warping and the boss sequence all have to stay visible or the level's state
   machine stops working."
  (let ((p (make-test-player))
        (player:*invincible?* t))
    (dolist (status '(:dead :warp :boss-defeated))
      (setf (player:player-status p) status)
      (is (eq status (player:effective-status p)) "~a must pass through" status))))
