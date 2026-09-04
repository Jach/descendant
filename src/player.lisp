(in-package #:com.thejach.descendant.player)

;;;; Port of origRef/GamePlay/dsc_player.c.
;;;;
;;;; The ship accelerates along one of two fixed diagonals rather than steering freely:
;;;; up is +0.2pi and down is -0.2pi (1.8pi), so holding up-and-right drives the ship
;;;; forward and upward at a constant angle. A permanent forward DRIFT is added to
;;;; whatever the player asks for, which is why the ship always creeps right.
;;;;
;;;; Horizontal position is a *world* coordinate, not a screen one: the ship advances
;;;; through the level and the camera follows, with the ship held inside a dead zone.
;;;; Vertical position is clamped directly to the play area.

(defconstant +drag+ 0.95)
(defconstant +forward-accel+ 700.0)
(defconstant +backward-accel+ -500.0)
(defconstant +drift+ 700.0 "Added to the requested speed every tick, in its direction.")
;; Single-float, since CL's PI is a double and the original is float throughout.
(defconstant +up+ (float (* pi 0.2) 1.0) "PLAYER_UP")
(defconstant +down+ (float (* pi 1.8) 1.0) "PLAYER_DOWN")
(defconstant +max-dead-zone+ 800 "DSC_MAX_DEAD_ZONE")

(defconstant +max-health+ 150)
(defconstant +max-shields+ 10)
(defconstant +z-player+ 7 "RDR_Z_EIGHT")

(defconstant +laser-cooldown+ 5)
(defconstant +bomb-cooldown+ 30)
(defconstant +bomb-cooldown-rapid+ 5)
(defconstant +death-limit+ 2 "The original's value, with a '### put this in config'.")
(defconstant +powerup-duration+ 300)

;;; Contact damage.
;;;
;;; The collision manager calls `hit` on EVERY frame two rects overlap -- there is no
;;; debounce and no notion of a collision "starting". A projectile only lands once
;;; because it marks itself dead on impact, but a body does not: ramming an enemy ship
;;; costs 100 health per frame of overlap, and a boss 200 plus a shield.
;;;
;;; That makes contact damage scale directly with the frame rate. The same tenth of a
;;; second of overlap costs three frames of damage at the ~30 Hz the original managed and
;;; six at our 62.5 -- so contact hits exactly twice as hard here, and it is the one place
;;; where the port is harsher than the original by construction rather than by balance.
;;;
;;; Dividing by RATE-SCALE puts damage-per-second back where it was. It produces
;;; fractions, so the remainder is carried rather than rounded -- rounding down would
;;; make light contact free, and rounding up would undo the whole correction.

(defparameter *contact-kinds* '(:enemy-ship :enemy-boss :enemy-midboss :enemy-turret)
  "Kinds whose damage recurs while touching. Bullets and bombs are absent because they
   die on impact and so land exactly once.")

(defparameter *contact-damage-scale* 0.5
  "An additional multiplier on contact damage, on top of the frame-rate correction.
   CHANGED FROM THE ORIGINAL, where it is effectively 1.0.

   Ramming costs 100 of 150 health per frame, which at any frame rate means brushing an
   enemy is close to fatal. Halving it makes a graze survivable and a sustained ram still
   lethal. Set to 1.0 for the original's numbers.")

(defparameter *points-shield-refund* 3
  "Shield pips the points pickup restores at the default difficulty. ADDED, not ported --
   see APPLY-COLLECTABLE. Set to 0 for the original's score-only behaviour.")

(defun points-shield-refund (&optional (difficulty state:*difficulty*))
  "The refund, scaled by difficulty: a pip more at 1, a pip less for every step above 2.

   This is the one number that decides how long a run can last, because shields are
   otherwise unrecoverable. Scaling it makes difficulty mean something other than tougher
   enemies -- it sets how much of a mistake the run can absorb -- and it is what the loop's
   rising difficulty tightens once stage three has been beaten.

   Never scaled below one: a pickup worth crossing the screen for has to be worth
   something. But zero stays zero -- that is the switch for the original's score-only
   pickup, not a value to be floored back up."
  (if (plusp *points-shield-refund*)
      (max 1 (- *points-shield-refund* (- difficulty state:+boot-difficulty+)))
      0))

(defparameter *invincible?* nil
  "Cheat: never take damage, and never spend a shield. ADDED, not ported -- the original
   has no cheat code; nothing in the C matches iddqd or anything like it.

   It reads on the HUD as a permanent invulnerability power-up -- yellow meters that stay
   yellow -- but it is a stronger thing underneath. The power-up lets the hit land and
   rolls the health back afterwards, which still fires damage particles; this suppresses
   the damage outright.

   The two are kept independent on purpose: collecting a real power-up while the cheat is
   on must not be able to switch the cheat off when it lapses, so PLAYER-STATUS is
   derived rather than assigned. See EFFECTIVE-STATUS.")

(defstruct (player (:constructor %make-player))
  (sprite nil)
  (rect (rect:make-rect 0 0 0 0) :type rect:rect)
  (collider nil)
  (move (movement:make-movement) :type movement:movement)
  (status :play :type keyword)
  (health +max-health+ :type fixnum)
  (max-health +max-health+ :type fixnum)
  (shields +max-shields+ :type fixnum)
  (max-shields +max-shields+ :type fixnum)
  (score 0 :type fixnum)
  ;; cooldowns, all counted down once per tick
  (laser-limit 0 :type fixnum)
  (bomb-limit 0 :type fixnum)
  (death-limit 0 :type fixnum)
  ;; power-ups: each a remaining-tick count, 0 when inactive
  (spread 0 :type fixnum)
  (rapid 0 :type fixnum)
  (invuln 0 :type fixnum)
  ;; horizontal world scrolling
  (start-x 0 :type fixnum)
  (max-x 0 :type fixnum)
  ;; Fractional screen position, used only while being drawn into the warp hole. In
  ;; normal play the original refreshes these from the rect every tick and ignores them.
  (scr-x 0.0 :type single-float)
  (scr-y 0.0 :type single-float)
  (trigger-frame 0 :type fixnum)
  ;; Carried fractions of contact damage; see the commentary above *CONTACT-KINDS*.
  (health-debt 0.0 :type single-float)
  (shield-debt 0.0 :type single-float)
  (min-y 0 :type fixnum)
  (max-y 0 :type fixnum)
  ;; Touch only: whether the ship is currently travelling to meet a finger that was put
  ;; down some way off. See SET-VERTICAL-CENTER-ROW.
  (catching-up? nil :type boolean)
  ;; hooks the gameplay layer fills in; nil until bullets/emitter are ported
  (fire-bullet nil :type (or null function))
  (fire-bomb nil :type (or null function))
  (emit nil :type (or null function))
  (sound-fire nil)
  (sound-bomb nil))

(defun make-player (sprite)
  "Build a player from the theme's `player` sprite, positioned as player_init_theme does."
  (let* ((w (theme:sprite-width sprite))
         (h (theme:sprite-height sprite))
         (x (ash screen:+cols+ -3))                 ; cols >> 3
         (y (+ (ash screen:+rows+ -1) 10))          ; (rows >> 1) + 10
         (p (%make-player :sprite sprite
                          :rect (rect:make-rect x y w h)
                          :min-y (+ h 10)
                          :max-y (- screen:+rows+ 4))))
    (setf (movement:movement-world-y (player-move p)) (float y)
          (movement:movement-world-x (player-move p)) 0.0
          (player-start-x p) 0
          (player-max-x p) 0
          (player-scr-x p) (float x 1.0)
          (player-scr-y p) (float y 1.0))
    p))

(defun alive? (p) (plusp (player-health p)))
(defun invulnerable? (p) (or *invincible?* (plusp (player-invuln p))))

(defun effective-status (p)
  "The status the rest of the game should see.

   The cheat shows as :INVULNERABLE without touching PLAYER-STATUS, which is what keeps
   the two independent: a real power-up collected while the cheat is on still runs its
   own timer, and when that timer lapses it sets PLAYER-STATUS back to :PLAY -- but the
   cheat is still on, so this still reports :INVULNERABLE and the meters stay yellow.

   Only overrides the states where it makes sense. Dying, warping and the boss-defeated
   sequence all have to be visible or the level's state machine stops working."
  (let ((status (player-status p)))
    (if (and *invincible?* (member status '(:play :invulnerable)))
        :invulnerable
        status)))

;;; ---------------------------------------------------------------------------
;;; Firing

(defun %muzzle (p)
  "Nose of the ship: right edge, half height down."
  (values (+ (rect:rect-x (player-rect p)) (rect:rect-w (player-rect p)))
          (- (rect:rect-y (player-rect p)) (floor (rect:rect-h (player-rect p)) 2))))

(defparameter *spread-angles*
  (mapcar (lambda (a) (float a 1.0))
          (list 0.0 (/ pi 4.0) (- (/ pi 4.0)) (/ pi 8.0) (- (/ pi 8.0))
                (/ pi 12.0) (- (/ pi 12.0))))
  "fire_laser fires straight ahead, plus six more at these angles when spread is up.")

(defun fire-laser (p)
  (multiple-value-bind (cx cy) (%muzzle p)
    (when (player-fire-bullet p)
      (if (plusp (player-spread p))
          (dolist (angle *spread-angles*)
            (funcall (player-fire-bullet p) "player_ship_bullet" angle cx cy))
          (funcall (player-fire-bullet p) "player_ship_bullet" 0.0 cx cy))))
  (audio:play (player-sound-fire p))
  t)

(defun bomb-arc (p up? down? &optional (x-speed 7))
  "The 13 spline knots fire_bomb builds. Each step advances X by X-SPEED and Y by a
   downspeed that decreases by 4 each knot, so the bomb arcs over and falls away.
   Holding up or down changes both the launch point and the initial downspeed."
  (let* ((r (player-rect p))
         (start-x (cond (up? (+ (rect:rect-x r) (/ (rect:rect-w r) 2.0)))
                        (down? (+ (rect:rect-x r) (/ (rect:rect-w r) 2.0)))
                        (t (+ (rect:rect-x r) (rect:rect-w r)))))
         (start-y (cond (up? (float (rect:rect-y r)))
                        (down? (float (- (rect:rect-y r) (rect:rect-h r))))
                        (t (- (rect:rect-y r) (/ (rect:rect-h r) 2.0)))))
         (downspeed (cond (up? 10.0) (down? -10.0) (t 0.0)))
         (x start-x)
         (y start-y)
         (points (list (cons start-x start-y))))
    (dotimes (i 12)
      (incf x x-speed)
      (incf y downspeed)
      (decf downspeed 4.0)
      (push (cons x y) points))
    (nreverse points)))

(defun fire-bomb (p up? down?)
  "One bomb normally. With spread up the original loops x-speed 7, 9, 11, 13 -- it
   breaks out at 15 -- laying down four arcs of increasing range."
  (when (player-fire-bomb p)
    (loop for x-speed from 7 by 2
          while (/= x-speed 15)
          do (funcall (player-fire-bomb p) "player_ship_bomb"
                      (bomb-arc p up? down? x-speed) 0.135)
             (audio:play (player-sound-bomb p))
             (when (zerop (player-spread p)) (return))))
  t)

;;; ---------------------------------------------------------------------------
;;; Damage

(defparameter *damage-table*
  ;; Transcribed including the original's fallthrough: MIDBOSS falls into TURRET falls
  ;; into BOMB falls into BULLET, so the costs accumulate. Almost certainly missing
  ;; `break`s rather than intent, but it is what shipped and what the game was balanced
  ;; against, so it is reproduced. Health cost, then shield cost.
  '((:enemy-ship    100 0)
    (:enemy-boss    200 1)
    (:enemy-midboss 215 1)                    ; 200 + 7 + 5 + 3
    (:enemy-turret   15 0)                    ; 7 + 5 + 3
    (:enemy-bomb      8 0)                    ; 5 + 3
    (:enemy-bullet    3 0)))

(defun damage-for (kind)
  (let ((row (assoc kind *damage-table*)))
    (if row (values (second row) (third row)) (values 0 0))))

(defun powerup-duration ()
  "Power-up lifetimes are counted in ticks, so they are converted along with the
   cooldowns -- otherwise a power-up lasts half as long in wall time as it used to."
  (state:scale-ticks +powerup-duration+))

(defun apply-collectable (p name)
  (let ((duration (powerup-duration)))
   (cond
    ((string= name "collect_spread") (setf (player-spread p) duration))
    ((string= name "collect_rapid") (setf (player-rapid p) duration))
    ((string= name "collect_invuln")
     (setf (player-invuln p) duration
           (player-status p) :invulnerable))
    ((string= name "collect_points")
     (incf (player-score p) 9000)
     ;; ADDED, not ported: the original's points pickup is worth score and nothing else.
     ;; Shields are otherwise unrecoverable -- you start with ten and only ever lose them
     ;; -- so a long run ends on attrition however well it is played. Giving the pickup
     ;; some shields back makes it worth crossing the screen for.
     (setf (player-shields p)
           (min (player-max-shields p)
                (+ (player-shields p) (points-shield-refund)))))))
  p)

(defun hit (p kind &key collectable-name)
  "Apply a collision. KIND is the other object's type; COLLECTABLE-NAME is only read
   when KIND is :collectable.

   The original reads the collectable name unconditionally, casting the other object's
   data pointer before it knows what it is -- harmless there only because nothing
   dereferences the result unless the switch reaches the collectable branch. We read it
   only when it applies."
  (when (plusp (player-death-limit p))
    (return-from hit p))
  (let ((old-health (player-health p))
        (old-shields (player-shields p)))
    (cond
      ((eq kind :collectable)
       (when collectable-name (apply-collectable p collectable-name)))
      ;; The cheat drops the damage on the floor rather than rolling it back, so nothing
      ;; downstream ever sees a health change.
      (*invincible?*)
      (t
       (multiple-value-bind (health-cost shield-cost) (damage-for kind)
         (if (member kind *contact-kinds*)
             (multiple-value-bind (health shields) (%contact-cost p health-cost shield-cost)
               (decf (player-health p) health)
               (decf (player-shields p) shields))
             (progn (decf (player-health p) health-cost)
                    (decf (player-shields p) shield-cost))))))
    ;; Invulnerability rolls the DAMAGE back rather than preventing it -- but only
    ;; damage. The original can roll back unconditionally because its collectable branch
    ;; never touches health or shields; ours does, since the points pickup now heals, and
    ;; rolling that back would silently eat the pickup whenever it was collected during an
    ;; invulnerability. Which is exactly when you are most likely to be flying through
    ;; things to grab it.
    (when (and (invulnerable? p) (not (eq kind :collectable)))
      (setf (player-health p) old-health
            (player-shields p) old-shields))
    (when (and (/= (player-health p) old-health) (player-emit p))
      (multiple-value-bind (cx cy) (%centre p)
        (funcall (player-emit p) cx cy :circle-limited)))
    (when (minusp (player-health p))
      (setf (player-health p) 0)))
  p)

(defun %contact-cost (p health-cost shield-cost)
  "Whole points of contact damage to apply this tick, carrying the remainder.

   Returns (values health shields). Both are divided by RATE-SCALE so a given duration of
   contact costs what it did at the original's frame rate, and multiplied by
   *CONTACT-DAMAGE-SCALE* on top of that."
  (let ((factor (/ (float *contact-damage-scale* 1.0) (float (state:rate-scale) 1.0))))
    (incf (player-health-debt p) (* health-cost factor))
    (incf (player-shield-debt p) (* shield-cost factor))
    (multiple-value-bind (health health-rest) (floor (player-health-debt p))
      (multiple-value-bind (shields shield-rest) (floor (player-shield-debt p))
        (setf (player-health-debt p) (float health-rest 1.0)
              (player-shield-debt p) (float shield-rest 1.0))
        (values health shields)))))

(defun %centre (p)
  (let ((r (player-rect p)))
    (values (+ (rect:rect-x r) (floor (rect:rect-w r) 2))
            (- (rect:rect-y r) (floor (rect:rect-h r) 2)))))

(defun explode (p)
  (when (player-emit p)
    (multiple-value-bind (cx cy) (%centre p)
      (funcall (player-emit p) cx cy :circle-small)))
  (setf (player-death-limit p) +death-limit+)
  (decf (player-shields p))
  p)

;;; ---------------------------------------------------------------------------
;;; The warp hole
;;;
;;; When the boss dies the player stops steering and is reeled in to the middle of the
;;; screen, where the vortex swallows it. The pull is proportional to the remaining
;;; distance, so it eases in, with floors underneath it so it cannot stall.

(defconstant +warp-delay+ 80
  "Frames of no movement after the boss dies, before the pull starts.")
(defconstant +warp-arrival-sq+ 82.0
  "Squared distance in cells at which the ship counts as arrived -- just over 9 cells.")
(defconstant +warp-pull+ 0.6 "Fraction of the remaining distance covered per second.")
(defconstant +warp-min-step-x+ 0.12
  "Horizontal floor. Note it is a one-sided clamp in the original: a delta smaller than
   this becomes +0.12 even when it is NEGATIVE, so a ship right of centre would be pushed
   further right forever. It cannot happen, because the ship's screen column is pinned at
   cols>>3 = 30 and the target is cols>>1 = 120.")
(defconstant +warp-min-step-y+ 0.015
  "Vertical dead zone, and unlike the horizontal one it is symmetric, so the vertical
   converges properly.")

(defun defeat-boss (p)
  "Called when the boss dies. The level takes it from here."
  (setf (player-status p) :boss-defeated
        (player-trigger-frame p) 0)
  p)

(defun %warp-target ()
  (values (float (ash screen:+cols+ -1) 1.0) (float (ash screen:+rows+ -1) 1.0)))

(defun %pull-to-warp (p time-step)
  "One frame of the reel-in. Returns T once the ship has arrived."
  (multiple-value-bind (tx ty) (%warp-target)
    (let* ((r (player-rect p))
           (dx (- tx (float (rect:rect-x r) 1.0)))
           (dy (- ty (float (rect:rect-y r) 1.0))))
      (cond
        ((< (+ (* dx dx) (* dy dy)) +warp-arrival-sq+) t)
        (t
         (let ((step-x (* dx time-step +warp-pull+))
               (step-y (* dy time-step +warp-pull+)))
           (setf step-x (max step-x +warp-min-step-x+)
                 step-y (if (<= (abs step-y) +warp-min-step-y+) 0.0 step-y))
           (incf (player-scr-x p) step-x)
           (incf (player-scr-y p) step-y)
           (setf (rect:rect-x r) (truncate (player-scr-x p))
                 (rect:rect-y r) (truncate (player-scr-y p))))
         nil)))))

;;; ---------------------------------------------------------------------------
;;; Update

(defun %tick-powerups (p)
  (macrolet ((expire (slot &body on-zero)
               `(when (plusp (,slot p))
                  (when (zerop (decf (,slot p))) ,@on-zero))))
    (expire player-spread)
    (expire player-rapid)
    (expire player-invuln (setf (player-status p) :play))))

(defparameter *couple-vertical-to-thrust* nil
  "Whether horizontal thrust also scales the vertical climb rate.

   The original computes ONE direction vector and ONE scalar speed, then takes
   (cos d, sin d) * speed. Because `speed` grows when left or right is held, the
   vertical component grows with it: holding up alone gives a climb of 6.58 cells/tick^2
   while up+right gives 13.17, exactly double. The ship cannot climb quickly without
   also flying forward, which is not what the controls suggest.

   That coupling is also the only reason the original needs its 'cheap fix for
   backwards upward movement' -- flipping up/down when reversing, to undo the sign
   inversion that a negative `speed` causes on the vertical axis.

   T reproduces the original. NIL (the default) drives the axes independently: vertical
   depends only on up/down, horizontal only on left/right, and the flip is unnecessary
   because nothing couples them.")

(defparameter *vertical-accel* (* (sin +up+) +drift+)
  "The decoupled climb rate, set to match the original's up-alone value exactly, so
   flying straight up feels identical -- only the diagonal changes.")

(defun %steer (up? down? left? right?)
  "Direction and speed from the held keys, as the original computes them.

   Pressing left while steering flips the vertical angle: with a negative speed,
   sin(direction) * speed would otherwise send an 'up' press downward."
  (let ((direction 0.0)
        (speed 0.0))
    (cond (up? (setf direction +up+))
          (down? (setf direction +down+)))
    (cond (right? (setf speed +forward-accel+))
          (left? (setf speed +backward-accel+)
                 (unless (zerop direction)
                   (setf direction (if (= direction +up+) +down+ +up+)))))
    (values direction speed)))

(defun steer-acceleration (up? down? left? right? time-step)
  "The two acceleration components for this frame's input.

   Horizontal is unchanged from the original either way -- cos is the same for both
   steering angles, so the up/down flip never affected it. Only the vertical differs:
   coupled, it scales with thrust; decoupled, it depends solely on up/down."
  (multiple-value-bind (direction speed) (%steer up? down? left? right?)
    (let ((thrust (+ speed (if (minusp speed) (- +drift+) +drift+))))
      (if *couple-vertical-to-thrust*
          (values (* (cos direction) thrust time-step)
                  (* (sin direction) thrust time-step))
          (values (* (cos direction) thrust time-step)
                  (* (cond (up? *vertical-accel*)
                           (down? (- *vertical-accel*))
                           (t 0.0))
                     time-step))))))

(defun %scroll-x (p)
  "Horizontal world position with the dead zone. The camera never goes backwards: MAX-X
   only ever grows, and if the ship falls more than +max-dead-zone+ behind it is pushed
   forward to keep up."
  (let ((m (player-move p))
        (world-x (truncate (movement:movement-world-x (player-move p)))))
    (cond
      ((>= world-x (player-max-x p)) (setf (player-max-x p) world-x))
      ((< world-x (player-start-x p))
       (setf (movement:movement-world-x m) (float (player-start-x p))
             (movement:movement-vx m) 0.0))
      (t
       (let ((delta (- (player-max-x p) world-x)))
         (when (> delta +max-dead-zone+)
           (let ((push (float (- delta +max-dead-zone+))))
             (incf (movement:movement-world-x m) push)
             (setf (movement:movement-vx m) push))))))))

(defparameter *vertical-follow-step* 2.0
  "Rows the ship may cross in one tick while catching up to a finger placed far away.

   Two rows a tick is about 125 a second, so the whole play area takes eight tenths of a
   second to cross -- brisk, clearly movement rather than a jump, and still far quicker
   than the keyboard manages.

   NIL restores placing the ship outright, for comparing the two.")

(defparameter *vertical-snap-heights* 6.0
  "How far the ship will simply BE placed, in multiples of its own height, before it
   starts covering the distance instead.

   Separate from the step above, and larger than it: within this the finger and the ship
   are the same object and any lag is felt immediately, so it follows exactly. Beyond it
   the player has lifted a thumb and put it down somewhere else, and appearing there
   reads as a glitch rather than as flying.

   In ship heights rather than rows because that is the unit the decision is really in --
   a gap you could hide the ship in is small; one several ships across is a journey.")

(defparameter *vertical-arrive-heights* 2.0
  "How close the ship must get before a catch-up counts as finished.

   Deliberately smaller than the threshold that starts one, which makes this a latch
   rather than a line. With a single threshold the ship crosses back into snapping range
   while still travelling at full speed and jumps the last six ship-heights -- the very
   thing the catch-up exists to avoid, delivered right at the end where it is most
   visible. Arriving properly means closing to two.

   Note the landing is still a jump, just a smaller one: releasing the latch places the
   ship exactly, so the last two ship-heights -- eight rows, measured -- go by in a
   single tick. That is the cost of having a mode at all, and it cannot be tuned away
   without also capping ordinary following, which would put lag on every fast swipe.
   Lower this if eight rows reads as a hop; the limit is *VERTICAL-FOLLOW-STEP*, below
   which the two are indistinguishable.")

(defun set-vertical-center-row (p row)
  "Put the MIDDLE of the ship on ROW, counting down from the top of the picture.

   For touch, where the finger's position IS the input rather than a request to
   accelerate. Vertical velocity is zeroed as well as the position set, or the momentum
   from a previous key press would keep dragging the ship past the finger.

   The middle and not the top edge. RECT-Y is the top -- a rect spans (y-h, y] and y
   counts up -- so placing the ship by its rect put the sprite hanging a couple of rows
   below the thumb, which is small, constant, and exactly the sort of thing that makes a
   control feel untrustworthy without being obviously wrong.

   The horizontal axis is left completely alone: forward drift, thrust and the one-sided
   clamp all still apply. Only the vertical becomes a direct placement.

   This is knowingly more control than a keyboard gives -- the ship can cross the play
   area as fast as a thumb moves. On a touchscreen the alternative is worse: a finger
   asking for 'slightly up' through an accelerating control is what made the first
   attempt unflyable."
  (let* ((m (player-move p))
         (height (rect:rect-h (player-rect p)))
         ;; ROW counts down from the top; the game's y counts up. And the caller means
         ;; the ship's middle, so the top edge sits half a ship above it.
         (wanted (+ (- screen:+rows+ (float row 1.0)) (/ height 2.0)))
         (target (max (float (player-min-y p) 1.0)
                      (min (float (player-max-y p) 1.0) wanted)))
         (current (movement:movement-world-y m))
         (gap (- target current))
         (distance (abs gap))
         (start (* *vertical-snap-heights* height))
         (arrive (* *vertical-arrive-heights* height))
         ;; A latch, not a line: once travelling, keep travelling until close. See
         ;; *VERTICAL-ARRIVE-HEIGHTS*.
         (travelling? (cond
                        ((null *vertical-follow-step*) nil)
                        ((player-catching-up? p) (> distance arrive))
                        (t (> distance start))))
         (y (if travelling?
                (+ current (* (float (signum gap) 1.0) *vertical-follow-step*))
                target)))
    (setf (player-catching-up? p) travelling?)
    (setf (movement:movement-world-y m) y
          (movement:movement-vy m) 0.0
          (player-scr-y p) y))
  p)

(defun %clamp-y (p)
  (let* ((m (player-move p))
         (pos-y (truncate (movement:movement-world-y m)))
         (clamped (max (player-min-y p) (min (player-max-y p) pos-y))))
    (setf (rect:rect-y (player-rect p)) clamped)
    (when (/= pos-y clamped)
      (setf (movement:movement-world-y m) (float clamped)))))

(defun update (p &key up? down? left? right? fire? bomb? (time-step level:+time-step+))
  "One fixed tick. Returns the player.

   Cooldowns tick down only on the frames the corresponding key is not firing, matching
   the original's if/else-if structure -- holding fire does not decrement the laser
   cooldown, it is reset on each shot instead."
  ;; The warp states take over the whole tick: no steering, no firing, no cooldowns.
  (case (player-status p)
    (:boss-defeated
     (when (> (player-trigger-frame p) +warp-delay+)
       (when (%pull-to-warp p time-step)
         (setf (player-status p) :warp)))
     (incf (player-trigger-frame p))
     (return-from update p))
    (:warp
     (incf (player-trigger-frame p))
     (return-from update p))
    (:dead
     (incf (player-trigger-frame p))
     (return-from update p)))

  (cond
    ;; Out of shields: this is the run ending. Checked before the respawn countdown, so
    ;; the last EXPLODE spends the last shield and the very next tick is game over.
    ((not (plusp (player-shields p)))
     (setf (player-status p) :dead
           (player-shields p) 0
           (player-health p) 0
           (player-trigger-frame p) 0)
     (return-from update p))
    ((plusp (player-death-limit p))
     (when (zerop (decf (player-death-limit p)))
       (setf (player-laser-limit p) 0
             (player-bomb-limit p) 0
             (player-health p) (player-max-health p)))
     (return-from update p))
    ((not (alive? p))
     ;; Deliberately no early return: the original calls explode() and falls straight
     ;; through into steering and firing, so the ship still answers the controls on the
     ;; frame it blows up.
     (explode p)))

  ;; Bombs: fire on press when off cooldown, otherwise cool down. The cooldowns are
  ;; converted along with the enemies' -- scaling only theirs would quietly hand the
  ;; player twice the firepower relative to the original.
  (if (and bomb? (<= (player-bomb-limit p) 0))
      (progn (fire-bomb p up? down?)
             (setf (player-bomb-limit p)
                   (state:scale-ticks
                    (if (plusp (player-rapid p))
                        +bomb-cooldown-rapid+
                        +bomb-cooldown+))))
      (when (plusp (player-bomb-limit p)) (decf (player-bomb-limit p))))

  ;; Lasers: rapid fire bypasses the cooldown entirely.
  (if (and fire? (or (<= (player-laser-limit p) 0) (plusp (player-rapid p))))
      (progn (fire-laser p)
             (setf (player-laser-limit p) (state:scale-ticks +laser-cooldown+)))
      (when (plusp (player-laser-limit p)) (decf (player-laser-limit p))))

  (%tick-powerups p)

  (multiple-value-bind (ax ay) (steer-acceleration up? down? left? right? time-step)
    (let ((m (player-move p)))
      (movement:set-acceleration-components m ax ay)
      (movement:calc-world-velocity m +drag+)
      (movement:integrate m time-step)))

  (%scroll-x p)
  (%clamp-y p)
  ;; Refresh the fractional mirror, so the warp pull starts from wherever the ship was.
  (setf (player-scr-x p) (float (rect:rect-x (player-rect p)) 1.0)
        (player-scr-y p) (float (rect:rect-y (player-rect p)) 1.0))
  p)

(defun render (p screen)
  (screen:enqueue screen (player-sprite p)
                  (rect:rect-x (player-rect p))
                  (rect:rect-y (player-rect p))
                  +z-player+)
  p)
