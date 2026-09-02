(in-package #:cl-user)

(defpackage #:com.thejach.descendant.test
  (:use #:cl #:fiveam)
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:state #:com.thejach.descendant.state)
                    (#:settings #:com.thejach.descendant.settings)
                    (#:descendant #:com.thejach.descendant)
                    (#:bin #:com.thejach.descendant.binary)
                    (#:glyph #:com.thejach.descendant.glyph)
                    (#:font #:com.thejach.descendant.font)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:rect #:com.thejach.descendant.rect)
                    (#:movement #:com.thejach.descendant.movement)
                    (#:collision #:com.thejach.descendant.collision)
                    (#:player #:com.thejach.descendant.player)
                    (#:bullets #:com.thejach.descendant.bullets)
                    (#:enemies #:com.thejach.descendant.enemies)
                    (#:spawner #:com.thejach.descendant.spawner)
                    (#:environment #:com.thejach.descendant.environment)
                    (#:collectables #:com.thejach.descendant.collectables)
                    (#:emitter #:com.thejach.descendant.emitter)
                    (#:effects #:com.thejach.descendant.effects)
                    (#:warp #:com.thejach.descendant.warp)
                    (#:cheats #:com.thejach.descendant.cheats)
                    (#:static-field #:com.thejach.descendant.static-field)
                    (#:fx #:com.thejach.descendant.screen-effect)
                    (#:hud #:com.thejach.descendant.hud)
                    (#:dsc #:com.thejach.descendant.level.descendant)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:renderer #:com.thejach.descendant.renderer)
                    (#:renderer.gl #:com.thejach.descendant.renderer.gl)
                    (#:level #:com.thejach.descendant.level)
                    (#:intro #:com.thejach.descendant.level.intro)
                    (#:menu #:com.thejach.descendant.level.menu)
                    (#:score #:com.thejach.descendant.level.score)
                    (#:showcase #:com.thejach.descendant.showcase)
                    (#:credits #:com.thejach.descendant.level.credits)
                    (#:wipe #:com.thejach.descendant.wipe)
                    (#:bestiary #:com.thejach.descendant.level.bestiary))
  (:export #:run-all))

(in-package #:com.thejach.descendant.test)

(def-suite descendant)
(in-suite descendant)

(defmacro with-original-rates (&body body)
  "Run BODY with the original's numbers: tick counts unconverted and contact damage
   unscaled.

   Tests that pin a specific tick count or damage figure are asserting fidelity to the C,
   so they have to opt out of our balance adjustments -- otherwise they would be
   asserting our scaling factors instead, and would silently change meaning if those were
   ever retuned."
  `(let ((state:*time-based-rates?* nil)
         (player:*contact-damage-scale* 1.0))
     ,@body))

(defmacro with-game ((var) &body body)
  "Start the real game level, bind it to VAR, and tear it down afterwards.

   Lives here rather than beside the level tests because several earlier test files use
   it, and a macro used before its defining file is compiled is silently treated as a
   function call."
  `(let ((audio:*muted?* t)
         (level:*frame* 0)
         (level:*state* :play)
         (level:*current* nil)
         ;; LEVEL:TICK binds this; these tests drive UPDATE-LEVEL directly, and the warp
         ;; hole reads the back buffer during update.
         (level:*screen* (screen:make-screen))
         ;; Cross-level state is global by design, so isolate it per test.
         (state:*theme* :crash-site)
         (state:*carried-score* 0))
     (unwind-protect
          (progn
            (level:start-level :descendant)
            (let ((,var level:*current*))
              ,@body))
       (level:shutdown))))

(defun run-all ()
  (run! 'descendant))
