(in-package #:com.thejach.descendant.level.descendant)

;;;; Port of origRef/GameLevels/dsc_level_descendant.c -- the game itself.
;;;;
;;;; This level owns nothing of its own. It builds each subsystem from the theme's
;;;; config, wires their hooks together, and then drives them in the order the original
;;;; registers its entities: player, spawner, enemies, projectiles, collectables,
;;;; environment, effects, particles, HUD.
;;;;
;;;; The wiring is where the subsystems actually meet:
;;;;   player  -> bullets   firing hooks
;;;;   player  -> emitter   damage and death bursts
;;;;   enemies -> bullets   enemy fire
;;;;   enemies -> emitter   hit and death bursts, plus score on death
;;;;   spawner -> enemies / environment / collectables, by object type
;;;;
;;;; DSC_LEVEL_DESCENDANT_01 and _02 in the original are two aliases of this same code,
;;;; ping-ponged so the outgoing theme can unload while the next loads. We keep one
;;;; level and swap the theme in place, since nothing here needs the double buffering.

(defconstant +music-track-delta+ 10800 "DSC_MUSIC_TRACK_DELTA, roughly 3 minutes.")
(defconstant +boss-death-delta+ 450
  "DSC_BOSS_DEATH_DELTA: frames from the boss dying to the next theme loading.")
(defconstant +warp-all-delta+ 180
  "DSC_WARP_ALL_DELTA: frames into the death sequence at which the enemies are retired.")
(defconstant +warp-done-delta+ 340
  "DSC_WARP_DONE_DELTA: frames from the ship dying to the score table.")
(defconstant +static-field-radius+ 5 "beginStaticField's minRadius.")
(defparameter *warp-shape* '(3 8 54)
  "beginWarp's n-circles, min-radius and max-radius, flagged `//### Magic!` in the
   original. Three nested rings is what makes it read as a vortex; see src/warp.lisp.")

(defparameter *themes*
  '((:crash-site "crash_site.thm" "level_crash_site.cfg")
    (:hidden-cave "hidden_cave.thm" "level_hidden_cave.cfg")
    (:brain-pain "brain_pain.thm" "level_brain_pain.cfg"))
  "Which files each theme loads. The ORDER the warp hole walks lives in state:*themes*,
   since it has to outlive any one level instance; this table only maps a key to its
   assets. Keep the two in step.")

(defclass descendant (level:level)
  ;; Defaults to whatever the last run left in STATE, so a fresh instance built by a
  ;; level switch picks up where the previous one left off.
  ((theme-key :accessor descendant-theme-key :initarg :theme-key
              :initform state:*theme*)
   (theme :accessor descendant-theme :initform nil)
   (config :accessor descendant-config :initform nil)
   ;; subsystems
   (world :accessor descendant-world :initform nil)
   (player :accessor descendant-player :initform nil)
   (bullets :accessor descendant-bullets :initform nil)
   (enemies :accessor descendant-enemies :initform nil)
   (spawner :accessor descendant-spawner :initform nil)
   (environment :accessor descendant-environment :initform nil)
   (collectables :accessor descendant-collectables :initform nil)
   (effects :accessor descendant-effects :initform nil)
   (emitter :accessor descendant-emitter :initform nil)
   (hud :accessor descendant-hud :initform nil)
   ;; input, held between events
   (held :accessor descendant-held :initform (make-hash-table :test #'eq))
   ;; audio
   (tracks :accessor descendant-tracks :initform '())
   (track-index :accessor descendant-track-index :initform 0)
   (difficulty :accessor descendant-difficulty :initform state:+boot-difficulty+
    :documentation "Snapshotted from state:*difficulty* at load, since that is when the
                    original reads the global -- enemy health and every bullet pattern
                    are baked in by addEnemy. Changing the setting mid-level does
                    nothing, in the port as in the original.")
   (paused? :accessor descendant-paused? :initform nil)
   ;; End-of-level sequence
   (warp :accessor descendant-warp :initform (warp:make-warp))
   (trigger-frame :accessor descendant-trigger-frame :initform 0)
   (swallowed? :accessor descendant-swallowed? :initform nil
    :documentation "Set once the ship has reached the vortex. The original expresses this
                    by unregistering the player entity for good.")
   (static-field :accessor descendant-static-field
                 :initform (static-field:make-static-field))
   (enemies-retired? :accessor descendant-enemies-retired? :initform nil
    :documentation "Set partway through the death sequence, when the original
                    unregisters the enemy entity."))
  (:default-initargs :name "descendant"))

(level:register-level :descendant 'descendant)

(defun theme-files (key)
  (let ((row (assoc key *themes*)))
    (values (second row) (third row))))

;;; ---------------------------------------------------------------------------
;;; Wiring

(defun %wire (self)
  "Connect the subsystems' hooks. Everything below is a one-way call from one pool into
   another, which is what keeps them independently testable."
  (let ((player (descendant-player self))
        (bullets (descendant-bullets self))
        (enemies (descendant-enemies self))
        (emitter (descendant-emitter self))
        (effects (descendant-effects self)))
    (setf (player:player-fire-bullet player)
          (lambda (name angle x y) (bullets:fire bullets name angle x y))

          (player:player-fire-bomb player)
          (lambda (name points speed) (bullets:fire-spline bullets name points speed))

          (player:player-emit player)
          (lambda (x y type) (emitter:spew emitter x y type))

          (enemies:pool-fire-bullet enemies)
          (lambda (name angle x y) (bullets:fire bullets name angle x y))

          (enemies:pool-fire-spline enemies)
          (lambda (name points speed) (bullets:fire-spline bullets name points speed))

          ;; Spew on every hit that lands, not just the fatal one.
          (enemies:pool-emit enemies)
          (lambda (x y type) (emitter:spew emitter x y type))

          (enemies:pool-on-death enemies)
          (lambda (enemy score)
            (incf (player:player-score player) score)
            (let ((r (enemies:enemy-rect enemy)))
              (when r
                (let ((cx (+ (rect:rect-x r) (truncate (rect:rect-w r) 2)))
                      (cy (- (rect:rect-y r) (truncate (rect:rect-h r) 2))))
                  ;; Particles and nothing else. There WAS an explosion sprite here; it
                  ;; was mine, not the original's, and it read as a square blob over the
                  ;; wreck. Worth being explicit about why it is gone: the only
                  ;; createObject("explosion", ...) anywhere in the C is COMMENTED OUT,
                  ;; at dsc_player.c:78. The whole effects subsystem is built, loaded
                  ;; from config, updated and rendered every frame -- and never handed a
                  ;; single object. It is dead code in the shipped game.
                  (emitter:spew emitter cx cy :circle))))))

    ;; Killing the boss ends the level. This hangs off the pool's destroy path rather
    ;; than its damage path, because Destroy_Enemy runs however the boss died -- so a
    ;; boss that drifts off the left edge also ends the level, as in the original.
    (setf (enemies:pool-on-boss-defeated enemies)
          (lambda (enemy) (declare (ignore enemy)) (player:defeat-boss player)))

    ;; The spawner hands new objects to whichever pool owns that type.
    (setf (spawner:spawner-create (descendant-spawner self))
          (lambda (handler name x y)
            (ecase handler
              (:enemies (enemies:spawn (descendant-enemies self) name x y))
              (:environment (environment:create-object (descendant-environment self)
                                                       name x y))
              (:collectables (collectables:create-object
                              (descendant-collectables self) name x y)))))
    self))

(defmethod level:load-level ((self descendant))
  (multiple-value-bind (theme-file config-file) (theme-files (descendant-theme-key self))
    (let* ((cfg (config:read-config (paths:config-path config-file)))
           ;; Bound around the read, since the palette fixup happens as the theme loads.
           (th (let ((theme:*hidden-cave-palette* (state:cave-palette)))
                 (theme:read-theme (paths:theme-path theme-file))))
           (hud4 (font:read-bft (paths:font-path "dsc_font_hud_04.bft")))
           (hud6 (font:read-bft (paths:font-path "dsc_font_hud_06.bft")))
           (world (collision:make-world))
           (difficulty (setf (descendant-difficulty self) state:*difficulty*)))
      (setf (descendant-config self) cfg
            (descendant-theme self) th
            (descendant-world self) world)

      ;; Player. The score comes from STATE rather than starting at zero, because a warp
      ;; to the next theme rebuilds this object and the original's g_player is a global
      ;; that simply keeps counting.
      (let ((sprite (theme:find-sprite th "player")))
        (unless sprite (error "descendant: theme ~a has no player sprite" theme-file))
        (setf (descendant-player self) (player:make-player sprite)
              (player:player-score (descendant-player self)) state:*run-score*))

      ;; Projectiles
      (let ((pool (bullets:make-pool
                   :world world
                   :max (config:config-int cfg "level_data.bombs_bullets_max" 512))))
        (bullets:load-definitions pool cfg th
                                  (config:config-list cfg "level_data.bombs_bullets"))
        (setf (descendant-bullets self) pool))

      ;; Enemies: ships, bosses and turrets all share one pool.
      (let ((pool (enemies:make-pool :world world :difficulty difficulty)))
        (enemies:load-definitions
         pool cfg th
         (append (config:config-list cfg "level_data.enemy_ships")
                 (config:config-list cfg "level_data.bosses")
                 (config:config-list cfg "level_data.turrets"))
         :difficulty difficulty)
        (setf (descendant-enemies self) pool))

      ;; Environment first, since it defines the band the spawner places into.
      (setf (descendant-environment self) (environment:make-environment cfg th))

      (let ((pool (collectables:make-pool
                   :world world
                   :sound (audio:load-sound (paths:sound-path "item_pickup.wav")
                                            :kind :chunk))))
        (collectables:load-definitions
         pool cfg th (config:config-list cfg "level_data.collectable_list"))
        (setf (descendant-collectables self) pool))

      (let ((pool (effects:make-pool)))
        (effects:load-definitions pool cfg th
                                  (config:config-list cfg "level_data.effects_list"))
        (setf (descendant-effects self) pool))

      (setf (descendant-emitter self) (emitter:make-emitter)
            (descendant-hud self) (hud:make-hud hud4 hud6)
            (descendant-spawner self)
            (spawner:make-spawner cfg th
                                  :ceiling-y (environment:ceiling-y
                                              (descendant-environment self))
                                  :ground-y (environment:floor-y
                                             (descendant-environment self))))

      ;; The player's Y band is the environment's, not the whole screen.
      (setf (player:player-min-y (descendant-player self))
            (max (player:player-min-y (descendant-player self))
                 (environment:floor-y (descendant-environment self)))
            (player:player-max-y (descendant-player self))
            (min (player:player-max-y (descendant-player self))
                 (1- (environment:ceiling-y (descendant-environment self)))))

      (setf (player:player-sound-fire (descendant-player self))
            (audio:load-sound (paths:sound-path "player_fire.wav") :kind :chunk)
            (player:player-sound-bomb (descendant-player self))
            (audio:load-sound (paths:sound-path "player_bomb.wav") :kind :chunk)
            ;; The three DSCEnemies registers for itself.
            (enemies:pool-sound-death (descendant-enemies self))
            (audio:load-sound (paths:sound-path "enemy_death.wav") :kind :chunk)
            (enemies:pool-sound-fire (descendant-enemies self))
            (audio:load-sound (paths:sound-path "enemy_fire.wav") :kind :chunk)
            (enemies:pool-sound-bomb (descendant-enemies self))
            (audio:load-sound (paths:sound-path "enemy_bomb.wav") :kind :chunk)
            (descendant-tracks self)
            (remove nil (mapcar (lambda (n)
                                  (audio:load-sound (paths:sound-path n) :kind :music))
                                (config:config-list cfg "level_data.music_tracks"))))

      ;; The player is a collider too, so enemies and pickups can find it.
      (let* ((p (descendant-player self))
             (collider (collision:make-collider
                        (player:player-rect p) :player
                        :data p
                        :on-hit (lambda (self-collider other)
                                  (declare (ignore self-collider))
                                  (%player-hit self p other)))))
        (setf (player:player-collider p) collider)
        (collision:add world collider))

      (%wire self)
      ;; After wiring, so the chaser's hooks are live the moment it exists.
      (enemies:init-theme (descendant-enemies self))
      t)))

(defun %player-hit (level p other)
  "Route a collision into the player, looking up a collectable's name only when the
   other object actually is one."
  (declare (ignore level))
  (let ((kind (collision:collider-kind other)))
    (if (eq kind :collectable)
        (let ((c (collision:collider-data other)))
          (player:hit p :collectable
                      :collectable-name
                      (and c (collectables:definition-name
                              (collectables:collectable-definition c)))))
        (player:hit p kind))))

(defmethod level:init-level ((self descendant))
  (clrhash (descendant-held self))
  (setf (descendant-paused? self) nil
        (descendant-trigger-frame self) 0
        (descendant-swallowed? self) nil
        (descendant-enemies-retired? self) nil)
  (warp:finish (descendant-warp self))
  (static-field:finish (descendant-static-field self))
  (when (descendant-tracks self)
    (setf (descendant-track-index self) (random (length (descendant-tracks self))))
    (audio:play-music (nth (descendant-track-index self) (descendant-tracks self))))
  t)

(defmethod level:level-colormap ((self descendant))
  (theme:theme-colormap (descendant-theme self)))

;;; ---------------------------------------------------------------------------
;;; Input
;;;
;;; The level tracks held keys itself rather than polling, since lgame delivers
;;; discrete events. The original's g_input.keyPressed is the same idea.

(defparameter *key-bindings*
  (list :up 'lgame::+sdl-scancode-up+
        :down 'lgame::+sdl-scancode-down+
        :left 'lgame::+sdl-scancode-left+
        :right 'lgame::+sdl-scancode-right+
        :fire 'lgame::+sdl-scancode-x+
        :bomb 'lgame::+sdl-scancode-z+))

(defun %action-for (scancode)
  (cond
    ((= scancode lgame::+sdl-scancode-up+) :up)
    ((= scancode lgame::+sdl-scancode-down+) :down)
    ((= scancode lgame::+sdl-scancode-left+) :left)
    ((= scancode lgame::+sdl-scancode-right+) :right)
    ((= scancode lgame::+sdl-scancode-x+) :fire)
    ((= scancode lgame::+sdl-scancode-z+) :bomb)
    (t nil)))

(defun held? (self action)
  "Whether an action's key is down. AUTO FIRE answers yes for both weapons regardless.

   Noted rather than hidden: with auto-fire on there is no reason ever to let go, which
   is the same objection as holding both keys down by hand -- the setting does not create
   that problem, it just spares the fingers. If firing is ever made a choice worth making,
   this is one of the two places that has to change."
  (or (and (settings:value :auto-fire)
           (member action '(:fire :bomb))
           t)
      (gethash action (descendant-held self))))

(defun carry-score-on (self)
  "Keep the running total for the level that follows this one.

   Called at every transition that continues the same run -- beating a theme, or the
   debug skip. The score is not reset anywhere except abandoning to the menu and finishing
   a run, matching the single `g_player.d_score = 0` in the original."
  (setf state:*run-score* (player:player-score (descendant-player self))))

(defun abandon-run (self)
  "Give up and go back to the menu, forfeiting the score.

   `g_player.d_score = 0` appears exactly once in the whole game and this is it: the score
   survives beating a level, dying, and warping, but not walking away."
  (declare (ignore self))
  (setf state:*run-score* 0)
  (level:request-level :menu))

(defun toggle-pause (self)
  "Pausing is two things at once -- the level stops ticking and the HUD raises its
   banner -- and they must stay in step. Keeping them in one function is what stops the
   banner outliving the pause, which is exactly what happened when the HUD learned about
   it from an UPDATE argument instead: UPDATE does not run while paused, so the flag
   could be set but never cleared."
  (setf (descendant-paused? self) (not (descendant-paused? self)))
  (hud:toggle-pause (descendant-hud self))
  self)

(defmethod level:handle-event ((self descendant) event)
  (let ((type (lgame.event:event-type event)))
    (cond
      ((= type lgame::+sdl-keydown+)
       (let* ((key (lgame.event:key-scancode event))
              (action (%action-for key)))
         (cond
           (action (setf (gethash action (descendant-held self)) t) t)
           ((= key lgame::+sdl-scancode-escape+) (abandon-run self) t)
           ((= key lgame::+sdl-scancode-p+) (toggle-pause self) t)
           ;; ADDED, not ported: skip to the next theme. The original has the same idea
           ;; under #if defined(_DEBUG) -- A, S and D jump straight to a chosen theme.
           ((= key lgame::+sdl-scancode-n+)
            (carry-score-on self)
            (%advance-theme self)
            (level:request-level :descendant)
            t)
           ((= key lgame::+sdl-scancode-f+)
            (hud:toggle-fps (descendant-hud self)) t)
           (t nil))))
      ((= type lgame::+sdl-keyup+)
       (let ((action (%action-for (lgame.event:key-scancode event))))
         (when action (remhash action (descendant-held self)) t)))
      (t nil))))

;;; ---------------------------------------------------------------------------
;;; Update

;;; ---------------------------------------------------------------------------
;;; End of level
;;;
;;; Killing the boss puts the player into :BOSS-DEFEATED and starts a 450-frame
;;; countdown. During it the ship is reeled into the middle of the screen and swallowed
;;; by the warp hole, then the next theme loads.
;;;
;;; The original expresses this by unregistering scene entities and re-registering a
;;; subset a frame later. The subset is the point: the spawner, enemies and collectables
;;; stop for good, while bullets, particles and the player come back so the ship still
;;; trails debris on its way in. Scenery and the HUD are never unregistered and keep
;;; going throughout. We just gate the same calls on the level state.

(defun %advance-theme (self)
  "Hand the next theme to whatever level instance comes after this one.

   It has to go through STATE, not through this object: requesting a level switch tears
   this instance down and builds a fresh one, so anything stored here is discarded. That
   was the bug that made the game replay crash_site forever."
  (setf (descendant-theme-key self) (state:advance-theme)))

(defun %update-warp (self)
  "One frame of the end-of-level sequence. Returns NIL once the level is over."
  (let ((p (descendant-player self))
        (w (descendant-warp self))
        (frame (descendant-trigger-frame self)))
    (cond
      ((zerop frame)
       (destructuring-bind (n-circles min-radius max-radius) *warp-shape*
         (warp:begin w (ash screen:+cols+ -1) (ash screen:+rows+ -1)
                     n-circles min-radius max-radius)))
      ;; Frame 1 is where the original brings the player, bullets and particles back;
      ;; nothing to do here, since we gate on the state rather than a registration list.
      ((eq (player:player-status p) :warp)
       ;; The ship has reached the middle: fold the screen, ship and all, back into the
       ;; vortex buffers, then stop updating and drawing it. The original flips the
       ;; status back to :BOSS-DEFEATED here purely so this branch does not fire again;
       ;; SWALLOWED? is what actually retires the ship.
       (warp:snapshot w)
       (setf (descendant-swallowed? self) t
             (player:player-status p) :boss-defeated))
      ((>= frame +boss-death-delta+)
       (warp:finish w)
       (carry-score-on self)
       (%advance-theme self)
       (level:request-level :descendant)
       (return-from %update-warp nil)))
    (incf (descendant-trigger-frame self))

    (unless (descendant-swallowed? self)
      (player:update p))
    (bullets:update (descendant-bullets self))
    (environment:update (descendant-environment self)
                        (movement:movement-vx (player:player-move p))
                        :player-status (player:player-status p))
    (effects:update (descendant-effects self) level:*frame*)
    (emitter:update (descendant-emitter self))
    (warp:update w level:*screen*)
    (hud:update (descendant-hud self)
                :score (player:player-score p)
                :health (player:player-health p)
                :max-health (player:player-max-health p)
                :shields (player:player-shields p)
                :max-shields (player:player-max-shields p)
                :fps (level:measured-fps))
    t))

;;; ---------------------------------------------------------------------------
;;; Losing
;;;
;;; Spending the last shield puts the player into :DEAD and starts a second, shorter
;;; countdown. A field of static blooms out of the wreck and eats the screen, and at
;;; DSC_WARP_DONE_DELTA the score table takes over.
;;;
;;; The registration dance here is more aggressive than the warp's: at frame 2 the
;;; original calls unregisterAll() and puts back only the static field, enemies, bullets,
;;; particles and the HUD. The player, spawner, collectables and scenery are gone for
;;; good -- so enemies keep flying over the static while it grows, which is the look. The
;;; scenery vanishing is invisible either way, since the static field's sprite is
;;; full-screen and sits above it.

(defun %update-death (self)
  "One frame of the death sequence. Returns NIL once the level is over."
  (let ((p (descendant-player self))
        (sf (descendant-static-field self))
        (frame (descendant-trigger-frame self)))
    (cond
      ((zerop frame)
       (let ((r (player:player-rect p)))
         (static-field:begin sf
                             (+ (rect:rect-x r) (ash (rect:rect-w r) -1))
                             (- (rect:rect-y r) (ash (rect:rect-h r) -1))
                             +static-field-radius+)))
      ((= frame +warp-all-delta+)
       ;; The original also calls warpHole.snapshot() here, which does nothing: the warp
       ;; was never begun on this path and its entity is not registered, so the state it
       ;; sets is overwritten unread by the next beginWarp. A leftover from the static
       ;; field having been split out of the warp hole. Not ported; see PLAN.md section 7.
       (setf (descendant-enemies-retired? self) t))
      ((>= frame +warp-done-delta+)
       (static-field:finish sf)
       ;; The run is over: hand the total to the score table and start the next one fresh.
       ;; Remember where it ended so the menu can offer a continue.
       (setf state:*carried-score* (player:player-score p)
             state:*run-score* 0)
       (state:record-death-at (descendant-theme-key self))
       (level:request-level :score)
       (return-from %update-death nil)))
    (incf (descendant-trigger-frame self))

    (unless (descendant-enemies-retired? self)
      (enemies:update (descendant-enemies self)
                      :player-rect (player:player-rect p)
                      :player-accel-x (movement:movement-accel-x (player:player-move p))))
    (bullets:update (descendant-bullets self))
    (effects:update (descendant-effects self) level:*frame*)
    (emitter:update (descendant-emitter self))
    (static-field:update sf level:*screen*)
    (hud:update (descendant-hud self)
                :score (player:player-score p)
                :health (player:player-health p)
                :max-health (player:player-max-health p)
                :shields (player:player-shields p)
                :max-shields (player:player-max-shields p)
                :fps (level:measured-fps))
    t))

(defmethod level:update-level ((self descendant))
  ;; The original returns from updateFrame before the scene is ticked, so nothing updates
  ;; while paused -- the HUD included. Rendering is unaffected, which is what keeps the
  ;; banner and the rest of the display on screen.
  (when (descendant-paused? self)
    (return-from level:update-level t))

  (case (player:player-status (descendant-player self))
    ((:boss-defeated :warp)
     (return-from level:update-level (%update-warp self)))
    (:dead
     (return-from level:update-level (%update-death self))))

  ;; Touch places the ship vertically outright rather than asking it to accelerate --
  ;; see the header of src/touch.lisp for why steering an accelerating ship with a finger
  ;; does not work. Horizontal is untouched and still arrives as held arrow keys.
  #+android
  (let ((row (com.thejach.descendant.touch:vertical-row)))
    (when row
      (player:set-vertical-center-row (descendant-player self) row)))

  (let* ((p (descendant-player self))
         (world (descendant-world self))
         (enemies (descendant-enemies self))
         (move (player:player-move p))
         (world-x (truncate (movement:movement-world-x move))))

    ;; Music rotation, as the menu does.
    (when (and (descendant-tracks self)
               (plusp level:*frame*)
               (zerop (mod level:*frame* +music-track-delta+)))
      (setf (descendant-track-index self)
            (mod (1+ (descendant-track-index self)) (length (descendant-tracks self))))
      (audio:play-music (nth (descendant-track-index self) (descendant-tracks self))))

    (player:update p :up? (held? self :up) :down? (held? self :down)
                     :left? (held? self :left) :right? (held? self :right)
                     :fire? (held? self :fire) :bomb? (held? self :bomb))

    ;; Keep the player's collider in step with its rect. The player owns its position
    ;; directly, so the world only needs re-sorting.
    (when (player:player-collider p)
      (collision:move world (player:player-collider p) 0 0))

    (setf (enemies:pool-player-status enemies) (player:player-status p))

    (spawner:update (descendant-spawner self) world-x level:*frame*)
    (enemies:update enemies :player-rect (player:player-rect p)
                            :player-accel-x (movement:movement-accel-x move)
                            :world-x world-x)
    (bullets:update (descendant-bullets self))
    (collectables:update (descendant-collectables self) world-x)
    (environment:update (descendant-environment self) (movement:movement-vx move)
                        :player-status (player:player-status p))
    (effects:update (descendant-effects self) level:*frame*)
    (emitter:update (descendant-emitter self))

    (collision:check-collisions world)

    (hud:update (descendant-hud self)
                :score (player:player-score p)
                :health (player:player-health p)
                :max-health (player:player-max-health p)
                :shields (player:player-shields p)
                :max-shields (player:player-max-shields p)
                :fps (level:measured-fps)
                ;; EFFECTIVE, not raw: the cheat shows as invulnerable on the HUD without
                ;; touching the player's own state machine.
                :status (player:effective-status p)))
  t)

(defmethod level:render-level ((self descendant) screen)
  (let* ((warping? (warp:active? (descendant-warp self)))
         (dying? (static-field:active? (descendant-static-field self)))
         (ending? (or warping? dying?)))
    (environment:render (descendant-environment self) screen)
    (unless ending?
      (collectables:render (descendant-collectables self) screen))
    ;; Enemies keep flying over the static as it grows -- the original puts the enemy
    ;; entity back at frame 2 of the death sequence -- but stop dead at the vortex.
    (unless (or warping? (descendant-enemies-retired? self))
      (enemies:render (descendant-enemies self) screen))
    ;; Both effects are full-screen sprites on RDR_Z_FOUR, so they cover the scenery but
    ;; still have the ship, bullets and particles drawn over them -- which is exactly
    ;; what feeds those back in on the next snapshot.
    (when warping? (warp:render (descendant-warp self) screen))
    (when dying? (static-field:render (descendant-static-field self) screen))
    (bullets:render (descendant-bullets self) screen)
    ;; The ship stops being drawn once it has been swallowed, or once it is wreckage.
    (unless (or (descendant-swallowed? self) dying?)
      (player:render (descendant-player self) screen))
    (emitter:render (descendant-emitter self) screen)
    (effects:render (descendant-effects self) screen)
    ;; Hidden, not switched off: the HUD keeps being updated so the meters and the score
    ;; are right the moment it comes back, and so the pause banner still counts down.
    (when (settings:value :show-hud)
      (hud:render (descendant-hud self) screen)))
  t)

(defmethod level:unload-level ((self descendant))
  ;; Deliberately does NOT touch state:*run-score*. Unload runs after whatever decided to
  ;; leave, so setting it here would undo the reset the death path just made.
  ;; CARRY-SCORE-ON is called at each transition instead, where the intent is known.
  (audio:stop-all)
  (mapc #'audio:free-sound (descendant-tracks self))
  (audio:free-sound (player:player-sound-fire (descendant-player self)))
  (audio:free-sound (player:player-sound-bomb (descendant-player self)))
  (audio:free-sound (collectables:pool-sound (descendant-collectables self)))
  (audio:free-sound (enemies:pool-sound-death (descendant-enemies self)))
  (audio:free-sound (enemies:pool-sound-fire (descendant-enemies self)))
  (audio:free-sound (enemies:pool-sound-bomb (descendant-enemies self)))
  (setf (descendant-tracks self) '()
        (descendant-theme self) nil
        (descendant-world self) nil)
  t)
