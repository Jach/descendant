(in-package #:com.thejach.descendant.level.bestiary)

;;;; ADDED, not ported. A hidden gallery, reached by pressing B on the credits.
;;;;
;;;; One stage at a time, every enemy that stage has, laid out on a star field and
;;;; labelled. They sit still for a moment, fire their real shot patterns, and after a few
;;;; seconds the wipe closes over and the next stage takes their place. Three stages, then
;;;; round again. B or ESC returns to the credits.
;;;;
;;;; The point of it is the colour. The credits parade has to retone its enemies into that
;;;; screen's film palette, because only one colormap is uploaded per frame. Here the
;;;; stage's own palette is the level's palette, so everything appears exactly as it does
;;;; in the game -- which is the whole reason this exists as a separate screen instead of
;;;; more of the roll.
;;;;
;;;; Layout is a shelf packer: tallest first, left to right, wrap to a new shelf when the
;;;; row is full. Nothing here is authored, so a config change cannot push an enemy off
;;;; the screen without the packer noticing.

(defconstant +z-star-field+ 0)
(defconstant +z-enemy+ 3)
(defconstant +z-label+ 4)
(defconstant +z-wipe+ 12 "Above everything: the point is to hide what is underneath.")

(defconstant +settle-ticks+ 62 "About a second of stillness before anything fires.")
(defconstant +linger-ticks+ 375 "And about six more before the wipe closes over.")
(defconstant +stage-ticks+ (+ +settle-ticks+ +linger-ticks+))

(defconstant +fire-stagger+ 9
  "Ticks between one exhibit opening fire and the next. Firing them all on the same tick
   reads as a single event rather than as each enemy doing its own thing.")
(defconstant +refire-ticks+ 150
  "How long an exhibit waits before firing again, which is about as long as a pattern
   takes to cross the screen and be culled.")
(defconstant +frame-ticks+ 11
  "Ticks per animation frame. The faker turrets spend two of their three frames disguised
   as rock, so a still gallery shows a boulder and calls it a turret.")

(defconstant +h-gap+ 7
  "Preferred cells between neighbours on a shelf, when there is room to spare. Wide
   enough that two name plates never read as one run of words, which four was not.")
(defconstant +min-gap+ 2
  "The tightest spacing a row may be squeezed to. Stage two needs it: with the worm
   holding the right of the top row, the three tall pieces beside it fit only just.")
(defconstant +v-gap+ 3 "Rows between shelves.")
(defconstant +label-gap+ 2 "Rows between an enemy and its name.")
(defconstant +margin+ 3)

(defparameter *difficulty* 3
  "Shot patterns are difficulty-scaled; the gallery shows the busiest version.")

(defparameter *stages*
  '((:crash-site "level_crash_site.cfg" "crash_site.thm"
     ("enemy_ship_bullet" "enemy_ship_bomb"))
    (:hidden-cave "level_hidden_cave.cfg" "hidden_cave.thm"
     ("enemy_ship_bullet" "enemy_ship_bomb" "enemy_super_bomb"))
    (:brain-pain "level_brain_pain.cfg" "brain_pain.thm"
     ("enemy_ship_bullet" "enemy_ship_bomb" "enemy_flame_shot")))
  "(key config theme projectile-definitions), in the order the game plays them.")

(defparameter *layout*
  '((:crash-site
     ;; Named outright rather than searched for: the ships and the boss above, the two
     ;; turrets and the floogle along the bottom.
     :place (("boss_Omegablaster" "enemy_ship_bomber" "enemy_ship_tiefighter"
              "enemy_ship_kamikaze")
             ("turret_light" "turret_heavy" "enemy_ship_floogle"))
     :corners (("boss_Gear" . :top-right)))
    (:hidden-cave :rows 2
     ;; The packer has no eye. The spider is the one small thing on a shelf of tall ones,
     ;; so it reads as stranded until it rises into the gap under the wall; and the cannon
     ;; belongs under the worm rather than adrift between the two.
     :nudge (("enemy_ship_spider" -4 -22)
             ("enemy_ship_Cannon" 14 6)))
    (:brain-pain :rows 3
     ;; Stage three is all small ships, so a third shelf spreads them instead of crowding
     ;; two. Its two big ones go to opposite corners rather than side by side.
     :corners (("boss_Chaser" . :top-left)
               ("boss_Battleship" . :bottom-right))))
  "Per-stage layout, keyed as in *STAGES*. Everything here is presentation: the packer
   guarantees the arrangement fits and does not overlap, and these only say where the eye
   should land.

     :place    rows of names, left to right, instead of a searched arrangement
     :rows     how many rows to search for, when :PLACE is not given
     :corners  names pinned to :top-left, :top-right, :bottom-left or :bottom-right
     :nudge    (name dx dy), for the cases the packer has no eye for

   See %SHELVES-FROM-PLACE, %SHELVES and %JUSTIFY.")

(defparameter *shared-once*
  '("boss_Chaser")
  "The chaser is listed in all three level configs -- it is the enemy that trails the
   player everywhere -- so exhibiting each stage's roster faithfully shows it three times.
   It is placed once instead, on the emptiest stage. See %ASSIGN-SHARED.")

(defparameter *flush-right* '("boss_doomworm")
  "Enemies that are a slice of something longer and belong against the right edge, as
   they arrive in the level. Parking the worm clear of the edge shows a blunt end that
   never reads as the end of anything.")

(defparameter *name-prefixes*
  '("enemy_ship_" "enemy_turret_" "enemy_midboss_" "enemy_" "midboss_" "boss_" "turret_")
  "Stripped, longest-first, to turn a config key into something worth reading.")

;;; ---------------------------------------------------------------------------

;;; X and WIDTH describe the packed box, not the art. The sprite and the name plate are
;;; each centred inside it, which matters because a plate is often wider than the enemy it
;;; names -- FLOOGLE is seven characters over a four-cell ship. Centring the plate on the
;;; art instead lets it hang outside the box and collide with the next exhibit.
(defstruct (exhibit (:constructor make-exhibit (name label enemy x y width)))
  (name "" :type string)
  (label nil)
  (enemy nil)
  (x 0 :type fixnum)
  (y 0 :type fixnum)
  (width 0 :type fixnum)
  ;; The tick this one next opens fire, staggered from its neighbours.
  (next-fire 0 :type fixnum))

(defstruct (stage (:constructor %make-stage))
  (key nil)
  (theme nil)
  (star-field nil)
  (enemies nil)
  (bullets nil)
  (exhibits '() :type list))

(defclass bestiary (level:level)
  ((stages :accessor bestiary-stages :initform '())
   (index :accessor bestiary-index :initform 0)
   (phase :accessor bestiary-phase :initform :show)
   (timer :accessor bestiary-timer :initform 0)
   (fired :accessor bestiary-fired :initform nil)
   ;; Free-running, unlike TIMER, so animation does not restart with each stage.
   (frame :accessor bestiary-frame :initform 0)
   (wipe :accessor bestiary-wipe :initform nil)
   (font :accessor bestiary-font :initform nil))
  (:default-initargs :name "bestiary"))

(level:register-level :bestiary 'bestiary)

(defun display-name (key)
  "A config key as a name plate: prefix dropped, underscores opened out, upper case.
   Turrets keep the word, since LIGHT on its own says nothing."
  (let ((name key))
    (dolist (prefix *name-prefixes*)
      (when (and (>= (length name) (length prefix))
                 (string-equal prefix name :end2 (length prefix)))
        (setf name (subseq name (length prefix)))
        (return)))
    (setf name (substitute #\Space #\_ (string-upcase name)))
    (if (and (search "TURRET" key :test #'char-equal)
             (not (search "TURRET" name :test #'char-equal)))
        (concatenate 'string name " TURRET")
        name)))

(defun %stage-roster (cfg)
  "Every enemy the stage lists, in the order the config gives them."
  (remove-duplicates
   (append (config:config-list cfg "level_data.enemy_ships")
           (config:config-list cfg "level_data.turrets")
           (config:config-list cfg "level_data.bosses"))
   :test #'string= :from-end t))

(defun %box (sprite label)
  "The cell a sprite and its name plate together occupy."
  (values (max (theme:sprite-width sprite) (theme:sprite-width label))
          (+ (theme:sprite-height sprite) +label-gap+ (theme:sprite-height label))))

(defun %item-width (it) (nth-value 0 (%box (second it) (third it))))
(defun %item-height (it) (nth-value 1 (%box (second it) (third it))))

(defun %run-width (run)
  "The narrowest this row can be drawn: every box plus the tightest spacing that still
   reads as two separate things."
  (+ (reduce #'+ run :key #'%item-width :initial-value 0)
     (* +min-gap+ (max 0 (1- (length run))))))

(defun %run-height (run)
  (reduce #'max run :key #'%item-height :initial-value 0))

(defun %splits (n row-count)
  "Every way to cut N items into ROW-COUNT contiguous non-empty runs, as lists of lengths."
  (cond ((< n row-count) '())
        ((= row-count 1) (list (list n)))
        (t (loop for k from 1 to (1+ (- n row-count))
                 append (mapcar (lambda (rest) (cons k rest))
                                (%splits (- n k) (1- row-count)))))))

(defun %shelves-from-place (items place corners)
  "Rows named outright, left to right, instead of searched for. Anything the stage does
   not mention joins the row with the least in it, so a new enemy in a config cannot
   quietly vanish from the gallery."
  (let* ((by-name (lambda (name) (find name items :key #'first :test #'string=)))
         (pinned (remove-if-not (lambda (it) (assoc (first it) corners :test #'string=))
                                items))
         (rows (loop for row in place
                     collect (loop for name in row
                                   for it = (funcall by-name name)
                                   if it collect it
                                   else do (warn "Bestiary: ~s is placed but not on the ~
                                                  bill." name))))
         (named (append pinned (reduce #'append rows)))
         (leftover (remove-if (lambda (it) (member it named)) items)))
    (dolist (it leftover)
      (warn "Bestiary: ~s is not placed; adding it to the emptiest row."
            (first it))
      (let ((target (first (sort (copy-list rows) #'< :key #'%run-width))))
        (setf (nth (position target rows) rows) (append target (list it)))))
    (let ((row-count (length rows)))
      (loop for run in rows
            for row from 0
            collect (append (%pinned-for pinned corners row row-count :left)
                            run
                            (%pinned-for pinned corners row row-count :right))))))

(defun %pinned-for (pinned corners row row-count side)
  (remove-if-not
   (lambda (it)
     (let ((corner (cdr (assoc (first it) corners :test #'string=))))
       (and (if (member corner '(:top-left :top-right))
                (zerop row)
                (= row (1- row-count)))
            (eq side (if (member corner '(:top-left :bottom-left)) :left :right)))))
   pinned))

(defun %shelves (items row-count reserved-width corners)
  "Divide ITEMS into ROW-COUNT shelves, tallest first so each shelf is tidy.

   The cut is searched rather than guessed. Balancing the rows by WIDTH is the obvious
   approach and it is wrong: what has to fit is the total HEIGHT, and that is the sum of
   each row's tallest item, so an even split by width can strand one tall thing on a row
   of small ones and cost a whole extra row's worth of screen. Stage two fails outright
   that way. With a dozen items and three rows there are only a few dozen cuts, so every
   one is tried and the shortest that fits wins.

   RESERVED-WIDTH is space held back on the first shelf for a flush-right exhibit.
   CORNERS is an alist of name to :top-left, :top-right, :bottom-left or :bottom-right;
   those are pinned to the end of the row named and kept out of the search, so two of
   them can be placed opposite each other."
  (let* ((pinned (remove-if-not (lambda (it) (assoc (first it) corners :test #'string=))
                                items))
         (rest (sort (remove-if (lambda (it) (member it pinned)) (copy-list items))
                     #'> :key #'%item-height))
         (n (length rest)))
    (flet ((pinned-for (row side)
             (%pinned-for pinned corners row row-count side)))
      (let ((best nil) (best-score nil))
        (dolist (lengths (%splits n row-count))
          (let ((runs '()) (tail rest))
            (dolist (k lengths)
              (push (subseq tail 0 k) runs)
              (setf tail (nthcdr k tail)))
            (setf runs (nreverse runs))
            ;; Fold the pinned items in at the ends they were asked for, before judging.
            (setf runs (loop for run in runs
                             for row from 0
                             collect (append (pinned-for row :left)
                                             run
                                             (pinned-for row :right))))
            (let ((fits t) (height 0))
              (loop for run in runs
                    for row from 0
                    do (let ((available (- screen:+cols+ (if (zerop row) reserved-width 0))))
                         (when (> (%run-width run) available) (setf fits nil))
                         (incf height (%run-height run))))
              ;; Shortest wins; between equally short ones, the evenest, so a row is not
              ;; left holding a single item with the others crowded.
              (let ((score (list height
                                 (- (reduce #'max runs :key #'length)
                                    (reduce #'min runs :key #'length)))))
                (when (and fits (or (null best-score)
                                    (and (= (first score) (first best-score))
                                         (< (second score) (second best-score)))
                                    (< (first score) (first best-score))))
                  (setf best runs best-score score))))))
        (or best
            ;; Nothing fits at this row count; hand back everything on one shelf and let
            ;; %LAYOUT try again with fewer rows.
            (list (append (pinned-for 0 :left) rest (pinned-for 0 :right))))))))

(defun %justify (shelves reserved-width first-shelf-height)
  "Spread the shelves down the screen and their contents across it, sharing the space
   left over equally rather than packing everything against the top left. Returns a list
   of (key sprite label x top width).

   FIRST-SHELF-HEIGHT lets a flush-right exhibit taller than anything beside it claim the
   vertical room it needs."
  (let* ((live (remove-if #'null shelves))
         (heights (loop for s in live
                        for i from 0
                        collect (max (if (zerop i) first-shelf-height 0)
                                     (reduce #'max s :key #'%item-height :initial-value 0))))
         (used (reduce #'+ heights))
         (v-slack (max 0 (- screen:+rows+ used)))
         (v-gap (floor v-slack (1+ (length live))))
         (top v-gap)
         (placed '()))
    (loop for shelf in live
          for h in heights
          do (let* ((widths (mapcar #'%item-width shelf))
                    (available (- screen:+cols+ (if (eq shelf (first live)) reserved-width 0)))
                    (h-slack (max 0 (- available (reduce #'+ widths))))
                    ;; Share the leftover equally between the edges and the gaps, so a
                    ;; sparse row spreads across the screen instead of huddling. Never
                    ;; below the spacing the row was judged to fit at.
                    (h-gap (max +min-gap+ (floor h-slack (1+ (length shelf)))))
                    (x (max 0 (floor (- available (+ (reduce #'+ widths)
                                                     (* h-gap (1- (length shelf)))))
                                     2))))
               (loop for it in shelf
                     for w in widths
                     do (push (list (first it) (second it) (third it) x top w) placed)
                        (incf x (+ w h-gap)))
               (incf top (+ h v-gap))))
    (values (nreverse placed) (- top v-gap))))

(defun %layout (items row-count reserved-width first-shelf-height corners place)
  "Arrange ITEMS. With PLACE the rows are taken as given; otherwise they are searched
   for, shrinking the row count if the tallest shelves will not fit together."
  (if place
      (multiple-value-bind (placed used)
          (%justify (%shelves-from-place items place corners)
                    reserved-width first-shelf-height)
        (when (> used screen:+rows+)
          (warn "Bestiary: the placed layout needs ~d rows of ~d; something will be ~
                 clipped." used screen:+rows+))
        (values placed used))
      (loop for rows downfrom (max 1 row-count) to 1
            do (multiple-value-bind (placed used)
                   (%justify (%shelves items rows reserved-width corners)
                             reserved-width first-shelf-height)
                 (when (or (<= used screen:+rows+) (= rows 1))
                   (when (> used screen:+rows+)
                     (warn "Bestiary: layout needs ~d rows of ~d; something will be ~
                            clipped." used screen:+rows+))
                   (return (values placed used)))))))

(defstruct (pending (:constructor %make-pending))
  "A stage resolved to art but not yet placed, so that what goes on it can still change."
  key theme enemies bullets (items '() :type list) flush (shared '() :type list))

(defun %item-area (item)
  (multiple-value-bind (w h) (%box (second item) (third item))
    (* w h)))

(defun %resolve-stage (self spec)
  (destructuring-bind (key config-name theme-name projectiles) spec
    (let* ((cfg (config:read-config (paths:config-path config-name)))
           (th (theme:read-theme (paths:theme-path theme-name)))
           (enemy-pool (enemies:make-pool :world nil :difficulty *difficulty*))
           (bullet-pool (bullets:make-pool :world nil))
           (font (bestiary-font self))
           (attr (text:font-attr :pair (glyph:encode-pair 15 0)))
           (roster (%stage-roster cfg)))
      (setf (enemies:pool-fire-bullet enemy-pool)
            (lambda (name direction x y) (bullets:fire bullet-pool name direction x y))
            (enemies:pool-fire-spline enemy-pool)
            (lambda (name points speed) (bullets:fire-spline bullet-pool name points speed)))
      (bullets:load-definitions bullet-pool cfg th projectiles)
      (enemies:load-definitions enemy-pool cfg th roster :difficulty *difficulty*)

      ;; Resolve the roster to art plus a name plate, dropping anything the config names
      ;; but the theme does not draw.
      (let ((items '()) (flush nil) (shared '()))
        (dolist (name roster)
          (let* ((def (enemies:definition enemy-pool name))
                 (sprite (and def (enemies:definition-sprite def))))
            (when sprite
              (let ((label-text (display-name name)))
                (text:check-text-coverage font label-text :context "bestiary")
                (let ((entry (list name sprite (text:text-sprite font label-text attr))))
                  (cond
                    ((member name *shared-once* :test #'string=)
                     (push (cons name entry) shared))
                    ((member name *flush-right* :test #'string=) (setf flush entry))
                    (t (push entry items))))))))
        (%make-pending :key key :theme th :enemies enemy-pool :bullets bullet-pool
                       :items (nreverse items) :flush flush :shared shared)))))

(defun %assign-shared (pendings)
  "Enemies every stage's config lists -- the chaser is in all three -- are exhibited once,
   on whichever stage has the least art on it. Measured rather than chosen, so it follows
   the configs if they change."
  (let ((names (remove-duplicates
                (loop for p in pendings append (mapcar #'car (pending-shared p)))
                :test #'string=)))
    (dolist (name names pendings)
      (let ((host (first (sort (remove-if-not
                                (lambda (p) (assoc name (pending-shared p) :test #'string=))
                                (copy-list pendings))
                               #'<
                               :key (lambda (p)
                                      (reduce #'+ (pending-items p)
                                              :key #'%item-area :initial-value 0))))))
        (when host
          (let ((entry (cdr (assoc name (pending-shared host) :test #'string=))))
            (setf (pending-items host)
                  (append (pending-items host) (list entry)))))))))

(defun %place-stage (pending)
  (let* ((key (pending-key pending))
         (options (rest (assoc key *layout*)))
         (flush (pending-flush pending))
         (enemy-pool (pending-enemies pending))
         (reserved (if flush
                       (+ (nth-value 0 (%box (second flush) (third flush))) +min-gap+)
                       0))
         (flush-height (if flush
                           (nth-value 1 (%box (second flush) (third flush)))
                           0)))
    (multiple-value-bind (placed used)
        (%layout (pending-items pending)
                 (or (getf options :rows) 2)
                 reserved flush-height (getf options :corners) (getf options :place))
      (declare (ignore used))
      (let ((exhibits '())
            ;; The flush-right exhibit sits level with the first shelf.
            (first-top (if placed (fifth (first placed)) 1)))
        (when flush
          (destructuring-bind (key* sprite label) flush
            ;; Hard against the right edge, so the body reads as continuing past it.
            (let ((w (theme:sprite-width sprite)))
              (push (%exhibit enemy-pool key* sprite label
                              (- screen:+cols+ w) first-top w (getf options :nudge))
                    exhibits))))
        (dolist (p placed)
          (destructuring-bind (key* sprite label x top w) p
            (push (%exhibit enemy-pool key* sprite label x top w (getf options :nudge))
                  exhibits)))
        (setf exhibits (nreverse exhibits))
        ;; Stagger the opening volleys so the screen wakes up in sequence.
        (loop for x in exhibits
              for i from 0
              do (setf (exhibit-next-fire x) (+ +settle-ticks+ (* i +fire-stagger+))))
        (%make-stage :key key :theme (pending-theme pending)
                     :star-field (%star-field)
                     :enemies enemy-pool :bullets (pending-bullets pending)
                     :exhibits exhibits)))))

(defun %exhibit (pool name sprite label x top width &optional nudges)
  "Place one enemy, centred in its box. TOP counts down from the top of the screen; the
   pool's Y counts up from the bottom, which is what the renderer wants."
  (let* ((nudge (cdr (assoc name nudges :test #'string=)))
         (x (+ x (or (first nudge) 0)))
         (top (+ top (or (second nudge) 0)))
         ;; FORCE: a gallery has no midboss deaths behind it, and the boss gate would
         ;; otherwise refuse every boss on the bill.
         (art-x (+ x (ash (- width (theme:sprite-width sprite)) -1)))
         (e (enemies:spawn pool name art-x (- screen:+rows+ top) :force t)))
    (unless e (warn "Bestiary: could not place ~s" name))
    (make-exhibit name label e x top width)))

(defun %star-field ()
  (field:make-field screen:+cols+ screen:+rows+
                    (list (field:make-field-entry (char-code #\.) 1 2)
                          (field:make-field-entry (char-code #\Space) 1 96))))

(defmethod level:load-level ((self bestiary))
  (setf (bestiary-font self) (font:read-bft (paths:font-path "dsc_font_hud_04.bft")))
  ;; Resolve every stage before placing any of them: which stage hosts the shared enemies
  ;; depends on how full the others turn out to be.
  (setf (bestiary-stages self)
        (mapcar #'%place-stage
                (%assign-shared
                 (mapcar (lambda (spec) (%resolve-stage self spec)) *stages*))))
  (setf (bestiary-wipe self)
        (wipe:make-wipe (theme:theme-colormap (stage-theme (first (bestiary-stages self))))))
  t)

(defun current-stage (self)
  (nth (bestiary-index self) (bestiary-stages self)))

(defmethod level:init-level ((self bestiary))
  (setf (bestiary-index self) 0
        (bestiary-timer self) 0
        (bestiary-fired self) nil)
  (%reset-fire-schedule (current-stage self))
  ;; The credits covered the screen on their way out, so open from that same covered
  ;; state rather than cutting straight to a finished gallery.
  (wipe:recolor (bestiary-wipe self) (level:level-colormap self))
  (wipe:start (bestiary-wipe self) :reveal)
  (setf (bestiary-phase self) :reveal)
  t)

(defmethod level:level-colormap ((self bestiary))
  (theme:theme-colormap (stage-theme (current-stage self))))

(defun %fire-exhibit (pool x)
  "One exhibit fires everything it has."
  (let ((e (exhibit-enemy x))
        ;; Shots that aim, aim left, which is where the player would be.
        (player (rect:make-rect 12 (ash screen:+rows+ -1) 9 4)))
    (when e
      (loop for kind in (enemies:definition-shots (enemies:enemy-definition e))
            for i from 0
            for pattern = (enemies:shot-pattern kind *difficulty*)
            when pattern
              do (enemies:fire-spread pool e pattern i :player-rect player)))))

(defun %fire-due (self)
  "Fire whatever is due this tick, and book each one's next turn. Exhibits keep firing
   for as long as the stage is up, so a screen that has been watched for a while is not
   just a still life."
  (let* ((stage (current-stage self))
         (pool (stage-enemies stage))
         (now (bestiary-timer self)))
    (dolist (x (stage-exhibits stage))
      (when (and (exhibit-enemy x)
                 (>= now (exhibit-next-fire x))
                 ;; Nothing new once the wipe is about to close, so shots are not cut off
                 ;; mid-flight.
                 (< now (- +stage-ticks+ +refire-ticks+)))
        (%fire-exhibit pool x)
        (incf (exhibit-next-fire x) +refire-ticks+)))))

(defun %cull-strays (stage)
  "No collision world, so nothing else notices a projectile leaving the screen."
  (let ((margin 24))
    (dolist (p (bullets:pool-live (stage-bullets stage)))
      (let ((r (bullets:projectile-rect p)))
        (when (and r (or (< (rect:rect-x r) (- margin))
                         (> (rect:rect-x r) (+ screen:+cols+ margin))
                         (< (rect:rect-y r) (- margin))
                         (> (rect:rect-y r) (+ screen:+rows+ margin))))
          (setf (bullets:projectile-dead? p) t))))))

(defun %reset-fire-schedule (stage)
  (loop for x in (stage-exhibits stage)
        for i from 0
        do (setf (exhibit-next-fire x) (+ +settle-ticks+ (* i +fire-stagger+)))))

(defun advance-stage (self)
  (setf (bestiary-index self) (mod (1+ (bestiary-index self))
                                   (length (bestiary-stages self)))
        (bestiary-timer self) 0
        (bestiary-fired self) nil)
  ;; The gradient is drawn from the palette in use, which has just changed.
  (wipe:recolor (bestiary-wipe self) (level:level-colormap self))
  (bullets:clear (stage-bullets (current-stage self)))
  (%reset-fire-schedule (current-stage self))
  (bestiary-index self))

(defmethod level:update-level ((self bestiary))
  (let ((stage (current-stage self)))
    (bullets:update (stage-bullets stage))
    (%cull-strays stage))
  (incf (bestiary-frame self))
  (ecase (bestiary-phase self)
    ;; Opening out from the middle to show a stage that is already in place. Arriving on
    ;; a finished screen with no transition at all was the jarring part.
    (:reveal
     (unless (wipe:update (bestiary-wipe self))
       (setf (bestiary-phase self) :show
             (bestiary-timer self) 0)))
    (:show
     (incf (bestiary-timer self))
     (%fire-due self)
     (when (>= (bestiary-timer self) +stage-ticks+)
       (setf (bestiary-phase self) :cover)
       (wipe:start (bestiary-wipe self) :cover)))
    (:cover
     (let ((w (bestiary-wipe self)))
       ;; Swap stages the instant the screen is fully painted, so the change is never
       ;; seen, then run the same shape backwards to show the new one.
       (cond
         ((wipe:covered? w)
          (advance-stage self)
          (setf (bestiary-phase self) :reveal)
          (wipe:start w :reveal))
         ((not (wipe:update w))
          (setf (bestiary-phase self) :show))))))
  t)

(defmethod level:handle-event ((self bestiary) event)
  (when (= (lgame.event:event-type event) lgame::+sdl-keyup+)
    (let ((key (lgame.event:key-scancode event)))
      (when (or (= key lgame::+sdl-scancode-escape+)
                (= key lgame::+sdl-scancode-b+))
        (level:request-level :credits)
        t))))

(defmethod level:render-level ((self bestiary) screen)
  (let ((stage (current-stage self)))
    (screen:enqueue screen (stage-star-field stage) 0 screen:+rows+ +z-star-field+)
    (dolist (x (stage-exhibits stage))
      (let ((e (exhibit-enemy x)))
        (when e
          (let* ((r (enemies:enemy-rect e))
                 (sprite (enemies:definition-sprite (enemies:enemy-definition e)))
                 ;; Cycle the frames. The faker turrets are disguised as rock in two of
                 ;; their three, so a still gallery labels a boulder as a turret.
                 (frame (if (> (theme:sprite-frames sprite) 1)
                            (mod (floor (bestiary-frame self) +frame-ticks+)
                                 (theme:sprite-frames sprite))
                            0)))
            (screen:enqueue screen sprite
                            (rect:rect-x r) (rect:rect-y r) +z-enemy+ frame)
            (let ((label (exhibit-label x)))
              (when label
                ;; Centred in the packed box, not on the art -- see the EXHIBIT comment.
                (screen:enqueue screen label
                                (+ (exhibit-x x)
                                   (ash (- (exhibit-width x)
                                           (theme:sprite-width label))
                                        -1))
                                (- (rect:rect-y r) (rect:rect-h r) +label-gap+)
                                +z-label+)))))))
    (dolist (p (bullets:pool-live (stage-bullets stage)))
      (let ((r (bullets:projectile-rect p)))
        (when r
          (screen:enqueue screen
                          (bullets:definition-sprite (bullets:projectile-definition p))
                          (rect:rect-x r) (rect:rect-y r) +z-enemy+)))))
  (wipe:render (bestiary-wipe self) screen +z-wipe+)
  t)

(defmethod level:unload-level ((self bestiary))
  ;; The credits' track is playing on loan. Going back there hands it straight over;
  ;; leaving for anywhere else -- or quitting -- means nobody else will free it.
  (unless (eq level:*requested* :credits)
    (let ((held (audio:take-retained-music)))
      (when held
        (audio:stop-music)
        (audio:free-sound held))))
  (dolist (stage (bestiary-stages self))
    (bullets:clear (stage-bullets stage)))
  (setf (bestiary-stages self) '()
        (bestiary-wipe self) nil)
  t)
