(in-package #:com.thejach.descendant.audio)

;;;; SDL_mixer standing in for FMOD Ex (aud_sound.c). The original's interface was
;;;; register_sound / register_stream / play / play_bgm / set_music_volume /
;;;; set_effects_volume, which maps cleanly onto mixer chunks and music.
;;;;
;;;; Missing files are tolerated rather than fatal. level_hidden_cave.cfg and
;;;; level_brain_pain.cfg used to reference jaguar.wav, an FMOD sample from the old sound
;;;; test driver that was never shipped in Resources/Sounds; the original would have got
;;;; SOUND_INVALID_ID back and skipped the play call, and so would we. Those sections have
;;;; since been removed from the configs -- nothing in the port ever read them -- but the
;;;; tolerance stays, because it is the right behaviour and not a workaround for that one
;;;; file. A level should not fail to load over a sound effect.
;;;;
;;;; NOTE: this is the piece most worth lifting into lgame. lgame already depends on
;;;; sdl2-mixer and opens the device in init.lisp, but exposes no audio package, so
;;;; every game re-writes this. Kept behind a small interface for that reason.

(defvar *effects-volume* 1.0)
(defvar *music-volume* 1.0)
(defvar *muted?* nil
  "When true, load calls still succeed but nothing is sent to the device. Useful for
   headless test runs where no audio device exists.")

(defparameter *channels* 64
  "How many chunks may play at once. SDL_mixer defaults to EIGHT, and lgame's init
   opens the device without ever calling allocate-channels, so without INIT-CHANNELS a
   game gets that default.

   Eight is far too few here. With the rapid-fire power-up the laser bypasses its
   cooldown entirely and fires EVERY tick -- 62.5 shots a second, each holding a channel
   until the sample finishes. The original ran FMOD with 32
   (`FMOD_System_Init(system, 32, ...)`), so 64 is already generous by comparison; what
   actually saved FMOD was not the count but its voice management, which STEAL-CHANNEL
   below reproduces.")

(defvar *dropped-sounds* 0
  "Count of sounds skipped because no channel was free. Diagnostic only: a steadily
   climbing number means *CHANNELS* is too low, but it is never worth a warning per
   drop, which would be far noisier than the missing sound.")

(defparameter *max-voices-per-sound* 4
  "How many copies of ONE sound may sound at once.

   This is a loudness control, not a resource one. player_fire.wav is 1.1 seconds of
   audio; the laser fires every 5 ticks normally and EVERY tick under rapid fire, so
   between fourteen and seventy copies of an identical waveform overlap. Identical
   waveforms sum almost linearly, so the effect is not a thicker texture but a straight
   volume ramp -- roughly +17 dB over a single shot -- and it climbs the moment the
   power-up is collected.

   Capping the voices per sound bounds that sum while leaving unrelated effects free to
   overlap normally. Four is +6 dB over a single shot: dense enough that rapid fire still
   reads as rapid, quiet enough that it does not take over the mix.

   Worth noting the original had a cruder version of the same limit by accident. FMOD was
   given 32 voices total, so the pile-up could never exceed 32 copies. Allocating 64
   channels made this WORSE than the original rather than better, which is what surfaced
   it.")

(defvar *channel-owner* #() "Per-channel: the sound currently playing there, or NIL.")
(defvar *channel-serial* #() "Per-channel: a play counter, so the oldest can be found.")
(defvar *play-serial* 0)

(defvar *channel-playing-fn*
  (lambda (channel) (plusp (sdl2-mixer:playing channel)))
  "Seam: is CHANNEL still sounding? Bookkeeping alone cannot tell, since a chunk may have
   simply finished.")

(defun %ensure-channel-tables ()
  (unless (= (length *channel-owner*) *channels*)
    (setf *channel-owner* (make-array *channels* :initial-element nil)
          *channel-serial* (make-array *channels* :initial-element 0)))
  *channel-owner*)

(defun %playing? (channel)
  (handler-case (funcall *channel-playing-fn* channel) (error () nil)))

(defun %claim (channel sound)
  (when (< -1 channel (length *channel-owner*))
    (setf (svref *channel-owner* channel) sound
          (svref *channel-serial* channel) (incf *play-serial*)))
  channel)

(defun %voices (sound)
  "Channels currently sounding SOUND, oldest first."
  (sort (loop for c from 0 below (length *channel-owner*)
              when (and (eq (svref *channel-owner* c) sound) (%playing? c))
                collect c)
        #'< :key (lambda (c) (svref *channel-serial* c))))

(defun init-channels (&optional (channels *channels*))
  "Allocate the mixing channels. Must run after the audio device is open, i.e. after
   lgame:init."
  (setf *channels* channels)
  (%ensure-channel-tables)
  (unless *muted?*
    (handler-case (sdl2-mixer:allocate-channels channels)
      (error (e) (warn "Audio: could not allocate ~d channels: ~a" channels e))))
  channels)

(defstruct (sound (:constructor %make-sound))
  (name "" :type string)
  (kind :chunk :type (member :chunk :music))
  (handle nil)
  (channel nil))

(defun %volume-to-mix (volume)
  "SDL_mixer volumes are 0..128; the configs express them as 0.0..1.0 floats."
  (max 0 (min 128 (round (* 128 volume)))))

(defun load-sound (path &key (kind (if (string-equal "mp3" (pathname-type path))
                                       :music :chunk)))
  "Load PATH as a one-shot chunk or a streaming music track. Returns NIL and warns if
   the file is absent, mirroring the original's SOUND_INVALID_ID."
  (cond
    ((not (probe-file path))
     (warn "Audio: missing sound file ~a, skipping." path)
     nil)
    (*muted?* (%make-sound :name (namestring path) :kind kind :handle nil))
    (t
     (handler-case
         (%make-sound :name (namestring path)
                      :kind kind
                      :handle (ecase kind
                                (:chunk (sdl2-mixer:load-wav (namestring path)))
                                (:music (sdl2-mixer:load-music (namestring path)))))
       (error (e)
         (warn "Audio: could not load ~a: ~a" path e)
         nil)))))

(defun free-sound (sound)
  (when (and sound (sound-handle sound))
    (ecase (sound-kind sound)
      (:chunk (sdl2-mixer:free-chunk (sound-handle sound)))
      (:music (sdl2-mixer:free-music (sound-handle sound))))
    (setf (sound-handle sound) nil))
  nil)

(defvar *play-chunk-fn* (lambda (chunk loops channel)
                          (sdl2-mixer:play-channel channel chunk loops))
  "The raw mixer call, behind a seam so the failure paths can be tested without
   exhausting a real device. CHANNEL of -1 means 'any free one'.")

(defvar *halt-channel-fn* (lambda (channel) (sdl2-mixer:halt-channel channel))
  "Companion seam for stealing.")

(defparameter *steal-channels?* t
  "Whether to reuse a busy channel when none is free.

   The original ran FMOD, which does this for you: `FMOD_System_PlaySound` with
   `FMOD_CHANNEL_FREE` never fails when the 32 voices are busy -- FMOD virtualises or
   steals the least important one, so the newest sound is always heard. pygame's mixer
   behaves the same way, preempting the oldest channel rather than refusing.

   SDL_mixer alone does neither: `Mix_PlayChannel(-1, ...)` simply returns -1. Without
   stealing, sustained fire goes silent for as long as the channels stay saturated,
   which is precisely backwards -- you lose the sound of what you are doing NOW and
   keep whatever happened to start first.

   So we steal the OLDEST busy channel: newest wins, matching both FMOD and pygame.")

(defvar *stolen-sounds* 0 "Diagnostic: how many plays reused a busy channel.")

(defun %oldest-channel ()
  "The channel whose sound started longest ago -- a silent one if there is one, since it
   costs nothing to take. Preferring the oldest rather than taking channels in rotation
   matters: round-robin will happily kill a sound that started this frame."
  (let ((best nil) (best-serial nil))
    (loop for c from 0 below (length *channel-owner*)
          do (cond
               ((not (%playing? c)) (return-from %oldest-channel c))
               ((or (null best-serial) (< (svref *channel-serial* c) best-serial))
                (setf best c best-serial (svref *channel-serial* c)))))
    (or best 0)))

(defun %steal-channel (&optional (channel (%oldest-channel)))
  "Halt CHANNEL and return it, ready to be reused."
  (ignore-errors (funcall *halt-channel-fn* channel))
  (when (< -1 channel (length *channel-owner*))
    (setf (svref *channel-owner* channel) nil))
  channel)

(defun play (sound &key (loops 0))
  "Play a chunk, stealing a busy channel if none is free. LOOPS is the number of
   *repeats*, as in SDL_mixer, so 0 plays once and -1 loops forever.

   Returns the channel, or NIL if the sound could not be played at all.

   Two limits apply. A sound may not exceed *MAX-VOICES-PER-SOUND* simultaneous copies of
   itself, which keeps rapid fire from summing into a wall of noise; past that it recycles
   its own oldest voice, so the rate stays audible but the level does not climb. And when
   every channel in the device is busy, the globally oldest is stolen.

   **Never signals.** When every channel is busy SDL_mixer returns -1 and cl-sdl2-mixer
   turns that into an SDL-MIXER-ERROR; letting that propagate kills the game mid-frame
   over a sound effect, which is the wrong trade every time. Any mixer failure is
   absorbed -- audio is never worth a crash."
  (when (and sound (sound-handle sound) (eq (sound-kind sound) :chunk))
    (%ensure-channel-tables)
    (flet ((try (channel)
             (handler-case
                 (let ((got (funcall *play-chunk-fn* (sound-handle sound) loops channel)))
                   (and got (>= got 0) got))
               (error () nil))))
      (let* ((voices (%voices sound))
             (over-limit (and (plusp *max-voices-per-sound*)
                              (>= (length voices) *max-voices-per-sound*)))
             ;; Recycling this sound's own oldest voice, rather than asking for a free
             ;; channel, is what caps the pile-up.
             (channel (if over-limit
                          (try (%steal-channel (first voices)))
                          (try -1))))
        (when (and (null channel) *steal-channels?*)
          (setf channel (try (%steal-channel)))
          (when channel (incf *stolen-sounds*)))
        (cond
          (channel
           (ignore-errors
            (sdl2-mixer:volume channel (%volume-to-mix *effects-volume*)))
           (%claim channel sound)
           (setf (sound-channel sound) channel)
           channel)
          (t (incf *dropped-sounds*) nil))))))

(defun play-music (sound &key (loops -1))
  "Start a music track. Tolerant for the same reason PLAY is."
  (when (and sound (sound-handle sound) (eq (sound-kind sound) :music))
    (handler-case
        (progn (sdl2-mixer:volume-music (%volume-to-mix *music-volume*))
               (sdl2-mixer:play-music (sound-handle sound) loops))
      (error (e)
        (warn "Audio: could not start music ~a: ~a" (sound-name sound) e)
        nil))))

(defun stop-music ()
  (unless *muted?* (sdl2-mixer:halt-music)))

;;; ---------------------------------------------------------------------------
;;; Music that outlives a level
;;;
;;; A level normally owns its track and halts it on the way out, which is right when the
;;; next screen has music of its own. It is wrong when one screen is a detour from
;;; another -- the credits and the gallery behind them are one continuous place, and
;;; cutting the music at the door and restarting it on the way back announces a level
;;; change the player is not supposed to notice.

(defvar *retained-music* nil
  "A track handed on across a level change instead of being halted and freed. The level
   that takes it becomes its owner and is responsible for freeing it.")

(defun retain-music (sound)
  "Keep SOUND playing past the end of this level."
  (setf *retained-music* sound))

(defun retained-music () *retained-music*)

(defun take-retained-music ()
  "Claim the retained track, if any, and with it the duty to free it."
  (prog1 *retained-music* (setf *retained-music* nil)))

(defun stop-all ()
  (unless *muted?*
    (sdl2-mixer:halt-channel -1)
    (sdl2-mixer:halt-music)))

(defun set-effects-volume (volume)
  (setf *effects-volume* volume)
  (unless *muted?* (sdl2-mixer:volume -1 (%volume-to-mix volume)))
  volume)

(defun set-music-volume (volume)
  (setf *music-volume* volume)
  (unless *muted?* (sdl2-mixer:volume-music (%volume-to-mix volume)))
  volume)
