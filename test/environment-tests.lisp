(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun make-test-environment (&optional (level "level_crash_site.cfg")
                                        (theme-file "crash_site.thm"))
  (environment:make-environment
   (config:read-config (paths:config-path level))
   (theme:read-theme (paths:theme-path theme-file))
   :random-state (sb-ext:seed-random-state 42)))

;;; ---------------------------------------------------------------------------
;;; Ambient field specs
;;;
;;; Three parallel comma-separated lists, the character list deciding how many entries
;;; there are. Reading only the first of each was the bug behind stage three's patchy
;;; ground: the two other characters vanished and the frequency fell to 70, so three
;;; cells in ten rolled past every entry and stayed transparent.

(test ambient-fields-read-every-entry
  (let ((entries (environment::%parse-field-spec "~,9,r" "180,164,119" "70,15,15")))
    (is (= 3 (length entries)))
    (is (equal '(#\~ #\9 #\r)
               (mapcar (lambda (e) (code-char (field:field-entry-char e))) entries)))
    (is (equal '(180 164 119) (mapcar #'field:field-entry-pair entries)))
    (is (equal '(70 15 15) (mapcar #'field:field-entry-frequency entries)))))

(test a-bare-run-of-digits-is-one-number
  "`env_ground_color = 004` is a single entry of 4, not three of 0, 0 and 4."
  (let ((entries (environment::%parse-field-spec "^" "004" "100")))
    (is (= 1 (length entries)))
    (is (= 4 (field:field-entry-pair (first entries))))
    (is (= 100 (field:field-entry-frequency (first entries))))))

(test an-unconfigured-field-has-no-entries
  "How crash_site declares 'no ceiling'."
  (is (null (environment::%parse-field-spec "" "" "")))
  (is (null (environment::%parse-field-spec nil nil nil))))

(test the-character-list-decides-how-many-entries-there-are
  "processCharList returns nAttr and the other two lists are read only that far."
  (let ((entries (environment::%parse-field-spec "a,b" "1,2,3" "4,5,6")))
    (is (= 2 (length entries)) "the third colour and frequency are ignored"))
  (let ((entries (environment::%parse-field-spec "a,b" "1" "4")))
    (is (= 2 (length entries)))
    (is (= 0 (field:field-entry-pair (second entries)))
        "a character with no colour of its own gets zero")))

(test trailing-comments-do-not-derail-a-value
  "brain_pain writes `env_bg_field_color = 7,2 # 7 is blue`."
  (let ((entries (environment::%parse-field-spec "+,." "7,2 # 7 is blue" "6,6")))
    (is (equal '(7 2) (mapcar #'field:field-entry-pair entries)))))

(test stage-threes-ground-covers-itself
  "The reported glitch, checked where it happens: mostly lime with splotches of green and
   red, and no bare screen showing through."
  (let* ((env (make-test-environment "level_brain_pain.cfg" "brain_pain.thm"))
         (ground (environment:environment-ground env)))
    (is-true ground)
    (is (notany #'glyph:transparent? (theme:sprite-glyphs ground))
        "the three frequencies sum to 100, so every cell is painted")
    ;; All three characters really appear, rather than one filling everything.
    (let ((seen (remove-duplicates
                 (map 'list #'glyph:glyph-char (theme:sprite-glyphs ground)))))
      (dolist (ch '(#\~ #\9 #\r))
        (is-true (member (char-code ch) seen)
                 "no ~a in the ground" ch)))))

(test the-caves-background-keeps-all-three-characters
  "Same bug, same fix: `.,^,+` was being truncated to `.`."
  (let* ((env (make-test-environment "level_hidden_cave.cfg" "hidden_cave.thm"))
         (bg (environment:environment-background env))
         (seen (remove-duplicates
                (map 'list #'glyph:glyph-char
                     (remove-if #'glyph:transparent? (theme:sprite-glyphs bg))))))
    (dolist (ch '(#\. #\^ #\+))
      (is-true (member (char-code ch) seen) "no ~a in the cave background" ch))))

(test environment-defines-the-playable-band
  "crash_site has a 5-row ground and no ceiling, so the floor sits at 5 and the ceiling
   stays at the top of the screen. This is what the spawner places against."
  (let ((env (make-test-environment)))
    (is (= 5 (environment:floor-y env)) "env_ground_height = 5")
    (is (= screen:+rows+ (environment:ceiling-y env)) "env_cieling_height = 0")
    (is-true (environment:environment-ground env) "a ground field was built")
    (is (null (environment:environment-ceiling env))
        "no ceiling field when the height is zero")))

(test environment-ground-field-dimensions
  (let* ((env (make-test-environment))
         (ground (environment:environment-ground env)))
    (is (= screen:+cols+ (theme:sprite-width ground)))
    (is (= 5 (theme:sprite-height ground)))
    ;; env_ground_freq is 100, so the ground is solid rather than scattered.
    (is (notany #'glyph:transparent? (theme:sprite-glyphs ground))
        "a 100% frequency fills every cell")))

(test environment-background-field-is-sparse
  "env_bg_field_freq = 8, so the background is a scattering of '.' like the star fields."
  (let* ((env (make-test-environment))
         (bg (environment:environment-background env)))
    (is-true bg)
    (let* ((glyphs (theme:sprite-glyphs bg))
           (opaque (count-if-not #'glyph:transparent? glyphs)))
      (is (< 0 opaque (length glyphs)) "some cells set, most transparent")
      (is (< (/ opaque (length glyphs)) 0.2) "roughly 8%"))))

(test environment-loads-scenery-definitions
  (let ((env (make-test-environment)))
    (let ((pyramid (gethash "env_pyramid_01" (environment:environment-definitions env))))
      (is-true pyramid)
      (is (eq :building (environment:definition-kind pyramid)) "type = 8"))
    (is (<= 10 (hash-table-count (environment:environment-definitions env)))
        "environment_list has ten entries")))

(test environment-render-levels
  (is (eq :fg-01 (environment:render-level 0)))
  (is (eq :bg-01 (environment:render-level 1)))
  (is (eq :bg-02 (environment:render-level 2)))
  (is (eq :fg-01 (environment:render-level 99)) "unknown levels fall to the front"))

(test environment-creates-and-tracks-scenery
  (let ((env (make-test-environment)))
    (is (= 0 (environment:scenery-count env)))
    (is-true (environment:create-object env "env_pyramid_01" 200 10))
    (is (= 1 (environment:scenery-count env)))
    (handler-bind ((warning #'muffle-warning))
      (is (null (environment:create-object env "no_such_thing" 0 0))))))

(test environment-scrolls-with-player-velocity
  (let ((env (make-test-environment)))
    (environment:create-object env "env_pyramid_01" 200 10)
    (let ((s (first (gethash :fg-01 (environment:environment-layers env)))))
      ;; A positive player velocity scrolls scenery left.
      (dotimes (i 100) (environment:update env 100.0))
      (is (< (environment:scenery-x s) 200) "scenery moved left"))))

(test environment-parallax-slows-with-depth
  "Each layer moves at 0.85x the one in front, which is what gives the horizon depth."
  (let ((env (make-test-environment)))
    ;; Place one object per layer at the same spot by overriding the definition layer.
    (let ((defs (environment:environment-definitions env)))
      (setf (environment::definition-layer (gethash "env_pyramid_01" defs)) :fg-01
            (environment::definition-layer (gethash "env_tree_01" defs)) :bg-01
            (environment::definition-layer (gethash "env_mountain_01" defs)) :bg-02))
    (environment:create-object env "env_pyramid_01" 200 10)
    (environment:create-object env "env_tree_01" 200 10)
    (environment:create-object env "env_mountain_01" 200 10)
    (dotimes (i 200) (environment:update env 100.0))
    (let ((front (scenery-x-on env :fg-01))
          (mid (scenery-x-on env :bg-01))
          (back (scenery-x-on env :bg-02)))
      (is (< front mid) "the front layer has travelled furthest left")
      (is (< mid back) "and the back layer least"))))

(defun scenery-x-on (env layer)
  (environment:scenery-x (first (gethash layer (environment:environment-layers env)))))

(test environment-drops-scenery-that-scrolls-far-enough-left
  "ENVIRONMENT_DEAD_DELTA is -800, well past the left edge, so objects linger a while
   before being reclaimed."
  (let ((env (make-test-environment)))
    (environment:create-object env "env_pyramid_01" 0 10)
    (is (= 1 (environment:scenery-count env)))
    (dotimes (i 100) (environment:update env 1000.0))
    (is (= 0 (environment:scenery-count env)) "eventually reclaimed")))

(test environment-freezes-when-the-player-is-dead
  "The original returns early from update while the player is dead or has beaten a
   boss, so the world holds still."
  (let ((env (make-test-environment)))
    (environment:create-object env "env_pyramid_01" 200 10)
    (let ((s (first (gethash :fg-01 (environment:environment-layers env)))))
      (dotimes (i 100) (environment:update env 100.0 :player-status :dead))
      (is (= 200 (environment:scenery-x s)) "nothing moved while dead")
      (dotimes (i 100) (environment:update env 100.0 :player-status :boss-defeated))
      (is (= 200 (environment:scenery-x s)) "nor after a boss")
      (dotimes (i 100) (environment:update env 100.0 :player-status :play))
      (is (< (environment:scenery-x s) 200) "and moves again once playing"))))

(test environment-renders-fields-and-scenery
  (let ((env (make-test-environment))
        (s (screen:make-screen)))
    (environment:create-object env "env_pyramid_01" 50 20)
    (environment:render env s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)))
    ;; The ground occupies the bottom rows of the screen.
    (is (notevery #'zerop
                  (loop for x below screen:+cols+
                        collect (screen:cell-ref s x (1- screen:+rows+))))
        "the ground strip drew along the bottom")))

(test environment-hidden-cave-has-a-ceiling
  "Unlike crash_site, the cave is enclosed -- which is what makes it a cave."
  (let ((env (make-test-environment "level_hidden_cave.cfg" "hidden_cave.thm")))
    (is (plusp (environment:environment-ceiling-height env)))
    (is-true (environment:environment-ceiling env))
    (is (< (environment:ceiling-y env) screen:+rows+)
        "the ceiling lowers the playable band")))
