(in-package #:com.thejach.descendant.test)
(in-suite descendant)

;;;; Collectables, the particle emitter, and effects.

(defun make-collectable-pool (&key world collected)
  (let ((pool (collectables:make-pool :world world :on-collect collected))
        (cfg (config:read-config (paths:config-path "level_crash_site.cfg")))
        (th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (collectables:load-definitions
     pool cfg th (config:config-list cfg "level_data.collectable_list"))
    pool))

(test collectables-load-from-config
  (let ((pool (make-collectable-pool)))
    (dolist (name '("collect_rapid" "collect_spread" "collect_invuln" "collect_points"))
      (is-true (collectables:definition pool name) "~a should load" name))))

(test collectables-scroll-with-player-progress
  "Pickups sit still in world space, so they track the player's world X rather than a
   velocity."
  (let* ((pool (make-collectable-pool))
         (c (collectables:create-object pool "collect_rapid" 200 40)))
    (collectables:update pool 0)
    (collectables:update pool 50)
    (is (= 150 (rect:rect-x (collectables:collectable-rect c)))
        "moved left by exactly the distance travelled")))

(test collectables-are-collected-by-the-player-only
  (let* ((collected '())
         (pool (make-collectable-pool
                :collected (lambda (name) (push name collected))))
         (c (collectables:create-object pool "collect_spread" 100 40)))
    (let ((audio:*muted?* t))
      ;; An enemy bullet passing through does nothing.
      (funcall (collision:collider-on-hit (collectables:collectable-collider c))
               nil (collision:make-collider (rect:make-rect 100 40 2 2) :enemy-bullet))
      (is-false (collectables:collectable-dead? c))
      ;; The player picks it up.
      (funcall (collision:collider-on-hit (collectables:collectable-collider c))
               nil (collision:make-collider (rect:make-rect 100 40 9 4) :player))
      (is-true (collectables:collectable-dead? c))
      (is (equal '("collect_spread") collected)))))

(test collectables-only-reaped-while-the-player-moves
  "Faithful quirk: the original wraps the whole reap loop in `if (delta != 0)`, so a
   pickup collected while standing still stays on screen, already marked dead, until
   the player moves again."
  (let* ((audio:*muted?* t)
         (pool (make-collectable-pool))
         (c (collectables:create-object pool "collect_rapid" 100 40)))
    (collectables:update pool 0)
    (collectables:collect pool c)
    (is-true (collectables:collectable-dead? c))
    (dotimes (i 10) (collectables:update pool 0))
    (is (= 1 (collectables:live-count pool)) "still listed while stationary")
    (collectables:update pool 1)
    (is (= 0 (collectables:live-count pool)) "reaped as soon as the player moves")))

(test collectables-feed-the-players-powerups
  "The names the pool reports are the ones player:apply-collectable recognises."
  (with-original-rates
    (let ((p (make-test-player)))
      (dolist (spec '(("collect_rapid" . 300) ("collect_spread" . 300)))
        (player:apply-collectable p (car spec)))
      (is (= 300 (player:player-rapid p)))
      (is (= 300 (player:player-spread p)))
      (player:apply-collectable p "collect_points")
      (is (= 9000 (player:player-score p))))))

;;; ---------------------------------------------------------------------------
;;; Emitter

(defun test-emitter ()
  (emitter:make-emitter :random-state (sb-ext:seed-random-state 5)))

(test emitter-burst-sizes
  "The three shapes differ in count and lifetime: a full circle is 100, a limited cone
   50, and a line burst 30."
  (let ((e (test-emitter)))
    (is (= 100 (emitter:spew e 50 50 :circle)))
    (emitter:clear e)
    (is (= 100 (emitter:spew e 50 50 :circle-small)))
    (emitter:clear e)
    (is (= 50 (emitter:spew e 50 50 :circle-limited)))
    (emitter:clear e)
    (is (= 30 (emitter:spew e 50 50 :enemy)))
    (emitter:clear e)
    (is (= 0 (emitter:spew e 50 50 :spline)) "spline is deliberately not ported")))

(test emitter-particles-expire
  (let ((e (test-emitter)))
    (emitter:spew e 50 50 :enemy)
    (is (= 30 (emitter:live-count e)))
    ;; A line burst lives 0.4s, so ~25 ticks at 0.016.
    (dotimes (i 30) (emitter:update e))
    (is (= 0 (emitter:live-count e)) "all expired")))

(test emitter-circle-lives-longer-than-lines
  (let ((circle (test-emitter))
        (lines (test-emitter)))
    (emitter:spew circle 50 50 :circle)
    (emitter:spew lines 50 50 :lines)
    (dotimes (i 30) (emitter:update circle) (emitter:update lines))
    (is (= 0 (emitter:live-count lines)) "0.4s bursts are gone")
    (is (plusp (emitter:live-count circle)) "1.0s bursts are still going")))

(test emitter-is-bounded
  (let ((e (emitter:make-emitter :max-particles 10
                                 :random-state (sb-ext:seed-random-state 5))))
    (emitter:spew e 50 50 :circle)
    (is (= 10 (emitter:live-count e)) "the cap holds")))

(test emitter-particles-drift-left-with-the-world
  "update_circle adds a constant leftward nudge so debris stays with the scrolling
   world rather than the camera."
  (let* ((e (test-emitter)))
    (emitter:spew e 100 50 :circle)
    (let ((xs-before (mapcar #'emitter:particle-x (emitter:emitter-live e))))
      (dotimes (i 10) (emitter:update e))
      (let ((xs-after (mapcar #'emitter:particle-x (emitter:emitter-live e))))
        (is (< (/ (reduce #'+ xs-after) (length xs-after))
               (/ (reduce #'+ xs-before) (length xs-before)))
            "the burst drifts left on average")))))

(test emitter-renders
  (let ((e (test-emitter))
        (s (screen:make-screen)))
    (emitter:spew e 100 50 :circle)
    (emitter:render e s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)))))

;;; ---------------------------------------------------------------------------
;;; Effects

(defun make-effect-pool ()
  (let ((pool (effects:make-pool))
        (cfg (config:read-config (paths:config-path "level_crash_site.cfg")))
        (th (theme:read-theme (paths:theme-path "crash_site.thm"))))
    (effects:load-definitions pool cfg th
                              (config:config-list cfg "level_data.effects_list"))
    pool))

(test effects-load-from-config
  (let* ((pool (make-effect-pool))
         (boom (effects:definition pool "explosion")))
    (is-true boom)
    (is (= 1 (effects:definition-loops boom)) "anim_loops = 1")
    (is (= 5 (effects:definition-delta boom)) "anim_delta = 5")))

(test effects-animate-and-retire
  "A frame advances every anim_delta ticks, and the effect dies when its loops run out."
  (let* ((pool (make-effect-pool))
         (e (effects:create-object pool "explosion" 50 50 0)))
    (is-true e)
    (is (= 1 (effects:live-count pool)))
    (is (= 0 (effects:effect-frame e)))
    ;; Nothing happens on the spawn tick itself.
    (effects:update pool 0)
    (is (= 0 (effects:effect-frame e)))
    ;; Then a frame every five ticks.
    (effects:update pool 5)
    (is (= 1 (effects:effect-frame e)))
    ;; Run it out.
    (loop for frame from 6 to 400
          until (zerop (effects:live-count pool))
          do (effects:update pool frame))
    (is (= 0 (effects:live-count pool)) "one loop and it is gone")))

(test effects-render-the-current-frame
  (let ((pool (make-effect-pool))
        (s (screen:make-screen)))
    (effects:create-object pool "explosion" 50 50 0)
    (effects:render pool s)
    (screen:composite s)
    (is (notevery #'zerop (screen:screen-cells s)))))

(test effects-unknown-name-warns
  (let ((pool (make-effect-pool)))
    (handler-bind ((warning #'muffle-warning))
      (is (null (effects:create-object pool "no_such_effect" 0 0))))))

;;; ---------------------------------------------------------------------------
;;; Audio robustness
;;;
;;; Regression: SDL_mixer defaults to 8 channels and lgame never allocates more, so a
;;; firefight exhausted them within seconds and cl-sdl2-mixer turned the resulting -1
;;; into an error that killed the game mid-frame.

(defmacro with-fake-mixer ((&key (channels 8)) &body body)
  "A mixer we can saturate on purpose. CHANNELS stay busy until something halts them,
   which is what makes the exhaustion and voice-cap paths reachable in a test."
  `(let* ((audio:*muted?* nil)
          (audio:*channels* ,channels)
          (audio:*max-voices-per-sound* audio:*max-voices-per-sound*)
          (audio:*steal-channels?* t)
          (audio:*dropped-sounds* 0)
          (audio:*stolen-sounds* 0)
          ;; Length mismatch forces the bookkeeping tables to be rebuilt at this size.
          (com.thejach.descendant.audio::*channel-owner* #())
          (com.thejach.descendant.audio::*channel-serial* #())
          (busy (make-array ,channels :initial-element nil))
          (halted '())
          (audio:*channel-playing-fn* (lambda (c) (aref busy c)))
          (audio:*halt-channel-fn*
            (lambda (c) (push c halted) (setf (aref busy c) nil)))
          (audio:*play-chunk-fn*
            (lambda (chunk loops channel)
              (declare (ignore chunk loops))
              (cond
                ((>= channel 0) (setf (aref busy channel) t) channel)
                (t (let ((free (position nil busy)))
                     (unless free
                       (error 'simple-error
                              :format-control "No free channels available"))
                     (setf (aref busy free) t)
                     free))))))
     (declare (ignorable busy halted))
     (flet ((sounding () (count t busy))
            (halt-log () (reverse halted)))
       (declare (ignorable #'sounding #'halt-log))
       ,@body)))

(defun fake-sound (&optional (name "test.wav"))
  (com.thejach.descendant.audio::%make-sound :name name :kind :chunk :handle :fake))

(test audio-channel-count-is-generous
  "Eight is the SDL default and far too few. Rapid fire bypasses the laser cooldown
   entirely, firing every tick -- 62.5 shots a second. The original ran FMOD with 32."
  (is (>= audio:*channels* 32)))

(test audio-caps-the-voices-of-one-sound
  "The reported bug: collecting rapid fire made the game get much louder.

   player_fire.wav is 1.1 seconds of audio and rapid fire plays it every tick, so
   seventy copies of an identical waveform end up overlapping. Identical waveforms sum
   nearly linearly, so that is not a denser texture, it is a volume ramp of some +17 dB.
   Capping the concurrent copies bounds the sum."
  (with-fake-mixer (:channels 64)
    (let ((laser (fake-sound "player_fire.wav")))
      (dotimes (i 40) (audio:play laser))
      (is (= audio:*max-voices-per-sound* (sounding))
          "never more copies of one sound than the cap allows")
      (is (= 0 audio:*dropped-sounds*) "and every shot was still heard"))))

(test audio-voice-cap-recycles-the-oldest-copy
  "Over the cap, a sound takes back its own oldest voice -- so the newest shot is the
   one you hear, and the older ones are the ones that go."
  (with-fake-mixer (:channels 64)
    (let ((audio:*max-voices-per-sound* 3)
          (laser (fake-sound "player_fire.wav")))
      (is (= 0 (audio:play laser)))
      (is (= 1 (audio:play laser)))
      (is (= 2 (audio:play laser)))
      (is (= 0 (audio:play laser)) "the fourth recycles the first")
      (is (= 1 (audio:play laser)) "then the second")
      (is (equal '(0 1) (halt-log)) "oldest first, and each was halted before reuse")
      (is (= 0 audio:*stolen-sounds*)
          "recycling your own voice is not the same as stealing someone else's"))))

(test audio-voice-cap-is-per-sound
  "Different effects must still overlap freely; the cap is about one sound piling onto
   itself, not about the mix as a whole."
  (with-fake-mixer (:channels 64)
    (let ((audio:*max-voices-per-sound* 2)
          (laser (fake-sound "player_fire.wav"))
          (bomb (fake-sound "player_bomb.wav"))
          (pickup (fake-sound "item_pickup.wav")))
      (dotimes (i 10)
        (audio:play laser)
        (audio:play bomb)
        (audio:play pickup))
      (is (= 6 (sounding)) "two voices each, three sounds")
      (is (= 0 audio:*dropped-sounds*)))))

(test audio-steals-the-oldest-channel-when-none-is-free
  "FMOD's FMOD_CHANNEL_FREE steals rather than failing, and pygame preempts the oldest
   channel. SDL_mixer does neither, so we steal -- and we take the oldest, because taking
   them in rotation would happily kill a sound that started this frame."
  (with-fake-mixer (:channels 3)
    (let ((audio:*max-voices-per-sound* 0)   ; cap off, so the device is what saturates
          (a (fake-sound "a.wav")) (b (fake-sound "b.wav"))
          (c (fake-sound "c.wav")) (d (fake-sound "d.wav")))
      (is (= 0 (audio:play a)))
      (is (= 1 (audio:play b)))
      (is (= 2 (audio:play c)))
      (is (= 0 (audio:play d)) "nothing free, so the oldest goes")
      (is (= 1 audio:*stolen-sounds*))
      (is (= 0 audio:*dropped-sounds*) "stealing means nothing is lost")
      (is (= 1 (audio:play d)) "and then the next-oldest"))))

(test audio-play-never-signals-when-everything-fails
  "Belt and braces: if even the steal fails, drop the sound rather than signalling."
  (let ((audio:*muted?* nil)
        (audio:*dropped-sounds* 0)
        (audio:*channel-playing-fn* (lambda (c) (declare (ignore c)) t))
        (audio:*halt-channel-fn* (lambda (ch) (declare (ignore ch)) nil))
        (audio:*play-chunk-fn*
          (lambda (chunk loops channel)
            (declare (ignore chunk loops channel))
            (error 'simple-error :format-control "No free channels available")))
        (sound (fake-sound)))
    (is (null (audio:play sound)) "returns nil rather than signalling")
    (is (= 1 audio:*dropped-sounds*))))

(test audio-play-tolerates-a-negative-channel
  "SDL_mixer can also just return -1 without signalling."
  (let ((audio:*muted?* nil)
        (audio:*dropped-sounds* 0)
        (audio:*steal-channels?* nil)
        (audio:*channel-playing-fn* (lambda (c) (declare (ignore c)) nil))
        (audio:*play-chunk-fn* (lambda (c l ch) (declare (ignore c l ch)) -1))
        (sound (fake-sound)))
    (is (null (audio:play sound)))
    (is (= 1 audio:*dropped-sounds*))))

(test audio-sustained-rapid-fire-keeps-playing
  "The reported crash, with rapid fire: an 8-channel mixer that never frees anything.
   Every shot must still be heard, and nothing may signal.

   With the voice cap in place the device is never even saturated -- the laser recycles
   its own voices long before it runs the mixer out. That is the fix for both symptoms:
   the crash and the loudness had the same cause."
  (with-fake-mixer (:channels 8)
    (let ((laser (fake-sound "player_fire.wav")))
      (finishes (dotimes (i 200) (audio:play laser)))
      (is (= 0 audio:*dropped-sounds*) "nothing was lost")
      (is (= 0 audio:*stolen-sounds*) "and no other sound had to be sacrificed")
      (is (<= (sounding) audio:*max-voices-per-sound*)))))

(test audio-holding-shot-and-bomb-together-is-survivable
  "A player can hold both fire and bomb. Four sounds a bomb, one a shot, every tick."
  (with-fake-mixer (:channels 8)
    (let ((laser (fake-sound "player_fire.wav"))
          (bomb (fake-sound "player_bomb.wav")))
      (finishes (dotimes (i 200)
                  (audio:play laser)
                  (dotimes (arc 4) (audio:play bomb))))
      (is (= 0 audio:*dropped-sounds*))
      (is (<= (sounding) 8)))))

(test collectables-persist-far-behind-the-player
  "Reported bug: pickups vanished as soon as they left the screen, so a missed one was
   gone for good.

   The original sets `collectDtP->d_coll.d_collide.offscreen = 0` where enemies and
   projectiles both install a handler, so a pickup is only reaped by the -800 check --
   it lingers well off the left edge and the player can turn back for it."
  (let* ((world (collision:make-world))
         (pool (make-collectable-pool :world world))
         (c (collectables:create-object pool "collect_rapid" 10 40)))
    (is (null (collision:collider-on-offscreen (collectables:collectable-collider c)))
        "no offscreen handler, matching the original")
    ;; Scroll it well off the left edge; the collision sweep must not reap it.
    ;; `update` takes an absolute world-x and moves by the delta, so each call needs a
    ;; new position -- repeating one is a no-op.
    (collectables:update pool 200)
    (collision:check-collisions world)
    (collectables:update pool 400)
    (is (= 1 (collectables:live-count pool)) "still alive 400 units off-screen")
    (is (minusp (rect:rect-x (collectables:collectable-rect c))))
    ;; And the player can come back for it.
    (collectables:update pool 0)
    (is (= 1 (collectables:live-count pool)))
    (is (= 10 (rect:rect-x (collectables:collectable-rect c)))
        "backing up brings it on screen again, right where it was left")))

(test collectables-do-eventually-expire
  "They persist, but not forever -- the -800 dead delta still applies."
  (let* ((pool (make-collectable-pool))
         (c (collectables:create-object pool "collect_rapid" 10 40)))
    (declare (ignore c))
    (collectables:update pool 0)
    (collectables:update pool 1000)
    (is (= 0 (collectables:live-count pool)) "past the dead zone, reclaimed")))

(test hit-particles-are-scattered-not-stacked
  "PARTICLE_LINES/ENEMY spawn at `x + -5 + rand(8)`, `y + -5 + rand(11)` -- scattered
   around the impact rather than on top of it. That scatter is what makes it read as a
   stream tearing off the enemy instead of one line, and it is why the spray is visible
   even when the thing it came off is standing still."
  (let ((e (test-emitter)))
    (emitter:spew e 100 50 :enemy)
    (let ((xs (mapcar #'emitter:particle-x (emitter:emitter-live e)))
          (ys (mapcar #'emitter:particle-y (emitter:emitter-live e))))
      (is (> (length (remove-duplicates xs)) 1) "spread across x")
      (is (> (length (remove-duplicates ys)) 1) "and across y")
      ;; Within the original's window, and no wider.
      (is (every (lambda (x) (<= 95 x 102)) xs))
      (is (every (lambda (y) (<= 45 y 55)) ys)))))

(test hit-particles-all-fly-left
  "Scattered origin, but a single direction -- that is what makes it a stream."
  (let ((e (test-emitter)))
    (emitter:spew e 100 50 :enemy)
    (is (every (lambda (p) (minusp (emitter:particle-vx p))) (emitter:emitter-live e)))
    (is (every (lambda (p) (< (abs (emitter:particle-vy p)) 1e-3))
               (emitter:emitter-live e))
        "dead level")))
