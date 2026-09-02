(in-package #:cl-user)

(defpackage #:com.thejach.descendant.paths
  (:use #:cl)
  (:documentation "Locating the application root and asset files, in both a checked-out
                   source tree and a dumped binary.")
  (:local-nicknames (#:deploy #:org.shirakumo.deploy))
  (:export #:*deployed*
           #:local-dev?
           #:app-root
           #:user-data-path
           #:*assets-writable*
           #:asset-path
           #:theme-path
           #:font-path
           #:config-path
           #:sound-path))

(defpackage #:com.thejach.descendant.settings
  (:use #:cl)
  (:documentation "ADDED, not ported. Everything the options screen can change, and the
                   file beside the high scores that remembers it across restarts.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths))
  (:export #:*settings* #:*path* #:*file-name* #:settings-path
           #:setting #:make-setting #:setting-key #:setting-name #:setting-default
           #:setting-kind #:setting-range #:setting-deployed #:default
           #:value #:reset #:booleanp #:clamp-to-range
           #:+max-volume+ #:volume-fraction
           #:choice-values #:choice-label #:needs-restart? #:*renderer-labels*
           #:on-change #:apply-change #:apply-all
           #:load-settings #:save-settings))

(defpackage #:com.thejach.descendant.state
  (:use #:cl)
  (:documentation "The few values that outlive a level switch: the live parts of
                   struct DescendantState, plus the score a finished run hands on.")
  (:local-nicknames (#:settings #:com.thejach.descendant.settings))
  (:export #:+boot-difficulty+
           #:+max-difficulty+
           #:*difficulty*
           #:*difficulty-chosen?*
           #:*run-score*
           #:*continue-theme*
           #:record-death-at #:continue-available? #:begin-new-run #:resume-run
           #:*carried-score*
           #:*theme*
           #:*themes*
           #:advance-theme
           #:+tuned-hz+ #:*simulation-hz* #:*time-based-rates?*
           #:rate-scale #:scale-ticks
           #:*speed-presets* #:*speed-preset* #:set-speed-preset #:cycle-speed-preset
           #:*cycle*
           #:*cave-palettes*
           #:cave-palette
           #:difficulty-from-config
           #:set-difficulty
           #:reset))

(defpackage #:com.thejach.descendant.binary
  (:use #:cl)
  (:documentation "Reading the original little-endian binary assets.")
  (:export #:octets
           #:read-file-octets
           #:read-file-string
           #:u8-ref
           #:u16-ref
           #:u32-ref
           #:s32-ref
           #:asciiz))

(defpackage #:com.thejach.descendant.glyph
  (:use #:cl)
  (:documentation "The GLYPH: one 32-bit cell of the 240x120 screen.

                   byte 0  character code
                   byte 1  unused by the renderer (an editor artifact)
                   byte 2  mod; #xFF means 'transparent background'
                   byte 3  colour-pair index

                   #xFFFFFFFF is a fully transparent cell.")
  (:export #:glyph
           #:*colour-mapping*
           #:*win32-bg-slots*
           #:*win32-fg-slots*
           #:channel-swap?
           #:+transparent+
           #:+mod-transparent-bg+
           #:+default-fg-char+
           #:+default-bg-char+
           #:make-glyph
           #:glyph-char
           #:glyph-mod
           #:glyph-pair
           #:glyph-bg-index
           #:glyph-fg-index
           #:encode-pair
           #:transparent?
           #:transparent-bg?))

(defpackage #:com.thejach.descendant.font
  (:use #:cl)
  (:documentation "Bitmap fonts. Two on-disk formats normalise to one in-memory
                   structure: the 4x6 cell font (char -> pixels) and the shipped .bft
                   fonts (char -> cells). See PLAN.md D6.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:bin #:com.thejach.descendant.binary))
  (:export #:font
           #:font-name
           #:font-width
           #:font-height
           #:font-first-char
           #:font-count
           #:font-bits
           #:font-covers?
           #:font-pixel
           #:read-bft
           #:read-cell-atlas
           #:glyph-lines
           #:font-ink))

(defpackage #:com.thejach.descendant.theme
  (:use #:cl)
  (:documentation "Loading .thm files: a 16-entry palette plus a bank of named sprites.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:bin #:com.thejach.descendant.binary)
                    (#:glyph #:com.thejach.descendant.glyph))
  (:export #:*hidden-cave-palette*
           #:colormap
           #:colormap-name
           #:colormap-colors
           #:color-red
           #:color-green
           #:color-blue
           #:colormap-ref
           #:color-luminance
           #:luminance-map
           #:recolor-sprite
           #:recolor-theme

           #:sprite
           #:make-sprite
           #:sprite-name
           #:sprite-width
           #:sprite-height
           #:sprite-frames
           #:sprite-extra-bytes
           #:sprite-glyphs
           #:sprite-ref
           #:sprite-frame-offset

           #:theme
           #:theme-name
           #:theme-colormap
           #:theme-sprites
           #:read-theme
           #:find-sprite
           #:sprite-names))

(defpackage #:com.thejach.descendant.config
  (:use #:cl)
  (:documentation "Parsing the .cfg level files: [section] / key = value, # comments.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:bin #:com.thejach.descendant.binary))
  (:export #:config
           #:*overrides*
           #:read-config
           #:config-value
           #:config-text
           #:config-int
           #:config-float
           #:config-bool
           #:config-list
           #:config-keys))

(defpackage #:com.thejach.descendant.text
  (:use #:cl)
  (:documentation "Rendering strings with a .bft font, where each font pixel becomes a
                   whole cell. Port of GF_setData/GF_getSprite in gam_font.c.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:font #:com.thejach.descendant.font)
                    (#:theme #:com.thejach.descendant.theme))
  (:export #:+total-transparency+
           #:*transparent-bg-attr*
           #:font-attr
           #:text-width
           #:text-sprite
           #:render-text-into
           #:check-text-coverage
           #:missing-glyphs))

(defpackage #:com.thejach.descendant.field
  (:use #:cl)
  (:documentation "Randomised decoration fields (star field, ambient background).
                   Port of dsc_envCreateField.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme))
  (:export #:field-entry
           #:make-field-entry
           #:field-entry-char
           #:field-entry-pair
           #:field-entry-frequency
           #:entries-from-config
           #:make-field
           #:make-star-field))

(defpackage #:com.thejach.descendant.audio
  (:use #:cl)
  (:documentation "SDL_mixer wrapper standing in for FMOD. Missing files are tolerated.
                   A candidate for promotion into lgame -- see PLAN.md section 6.")
  (:export #:sound
           #:sound-name
           #:sound-kind
           #:*effects-volume*
           #:*music-volume*
           #:*muted?*
           #:*channels*
           #:*dropped-sounds*
           #:*stolen-sounds*
           #:*steal-channels?*
           #:*max-voices-per-sound*
           #:*halt-channel-fn*
           #:*play-chunk-fn*
           #:*channel-playing-fn*
           #:*retained-music*
           #:retain-music
           #:retained-music
           #:take-retained-music
           #:init-channels
           #:load-sound
           #:free-sound
           #:play
           #:play-music
           #:stop-music
           #:stop-all
           #:set-effects-volume
           #:set-music-volume))

(defpackage #:com.thejach.descendant.rect
  (:use #:cl)
  (:documentation "Axis-aligned rects in cell coordinates. Port of mat_rect.c.")
  (:export #:rect #:make-rect #:rect-x #:rect-y #:rect-w #:rect-h
           #:rect-left #:rect-right #:rect-top #:rect-bottom
           #:move-ip #:set-size #:collide? #:collide-point? #:contains?))

(defpackage #:com.thejach.descendant.movement
  (:use #:cl)
  (:documentation "The ship's two-register integrator. Port of dsc_movement.c.")
  (:export #:movement #:make-movement
           #:movement-accel-x #:movement-accel-y
           #:movement-vx #:movement-vy
           #:movement-prev-vx #:movement-prev-vy
           #:movement-env-vx #:movement-env-vy
           #:movement-world-x #:movement-world-y
           #:set-acceleration #:set-acceleration-components
           #:calc-world-velocity #:integrate #:reset))

(defpackage #:com.thejach.descendant.screen
  (:use #:cl)
  (:documentation "The 240x120 cell buffer and its 20 z-ordered sprite queues.
                   This is the port of GR_render's compositing half.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme))
  (:export #:*right-edge-off-by-one*
           #:+cols+
           #:+rows+
           #:+cell-width+
           #:+cell-height+
           #:+pixel-width+
           #:+pixel-height+
           #:+z-layers+
           #:screen
           #:make-screen
           #:screen-cells
           #:screen-back
           #:screen-clear-back?
           #:request-clear-back-buffer
           #:copy-back-buffer
           #:cell-ref
           #:clear-screen
           #:enqueue
           #:composite
           #:blit-sprite))

(defpackage #:com.thejach.descendant.collision
  (:use #:cl)
  (:documentation "Sweep-and-prune collision. Port of gam_collision_manager.c.")
  (:local-nicknames (#:rect #:com.thejach.descendant.rect)
                    (#:screen #:com.thejach.descendant.screen))
  (:export #:collider #:make-collider
           #:collider-rect #:collider-kind #:collider-data #:collider-alive?
           #:collider-on-hit #:collider-on-offscreen
           #:world #:make-world #:world-width #:world-height
           #:add #:remove-collider #:move #:count-colliders
           #:outside-world? #:check-collisions #:clear))

(defpackage #:com.thejach.descendant.renderer
  (:use #:cl)
  (:documentation "The SLO renderer: rasterise the cell buffer into an RGBA pixel buffer
                   with the 4x6 cell font and upload it to a streaming SDL texture.
                   Also the generic interface both renderers answer to.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:font #:com.thejach.descendant.font)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:paths #:com.thejach.descendant.paths))
  (:export #:renderer
           #:make-renderer
           #:destroy-renderer
           #:renderer-palette
           #:renderer-bg-lut
           #:renderer-fg-lut
           #:set-palette
           #:ensure-palette
           #:renderer-colormap
           #:rasterize
           #:present
           #:save-ppm))

(defpackage #:com.thejach.descendant.renderer.gl
  (:use #:cl)
  (:documentation "The FAST renderer: the cell buffer goes to the GPU as a texture and a
                   fragment shader does the glyph expansion, after refterm's design.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:font #:com.thejach.descendant.font)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:renderer #:com.thejach.descendant.renderer))
  (:export #:gl-renderer #:make-gl-renderer #:render-to-array
           #:+atlas-cols+ #:*vertex-shader* #:*fragment-shader*))

(defpackage #:com.thejach.descendant.level
  (:use #:cl)
  (:documentation "Level state machine and the fixed-timestep tick.
                   Port of gam_state_manager.c plus gam_main.c's update loop.")
  (:local-nicknames (#:screen #:com.thejach.descendant.screen)
                    (#:state #:com.thejach.descendant.state)
                    (#:renderer #:com.thejach.descendant.renderer))
  (:export #:+time-step+
           #:logic-hz
           #:*state*
           #:*current*
           #:*requested*
           #:*frame*
           #:*screen*
           #:*render-mode*
           #:measured-fps
           #:level
           #:level-name
           #:load-level
           #:init-level
           #:update-level
           #:render-level
           #:level-colormap
           #:handle-event
           #:deinit-level
           #:unload-level
           #:register-level
           #:make-level
           #:request-level
           #:*requested*
           #:request-quit
           #:present-this-frame?
           #:tick
           #:advance
           #:present
           #:shutdown
           #:start-level
           #:switch-if-requested))

(defpackage #:com.thejach.descendant.bullets
  (:use #:cl)
  (:documentation "Bullets and bombs: a shared pool of linear and spline-driven
                   projectiles. Port of dsc_bullets_bombs.c.")
  (:local-nicknames (#:rect #:com.thejach.descendant.rect)
                    (#:movement #:com.thejach.descendant.movement)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:collision #:com.thejach.descendant.collision)
                    (#:state #:com.thejach.descendant.state)
                    (#:level #:com.thejach.descendant.level)
                    (#:spline #:cl-catmull-rom-spline))
  (:export #:*slow-player-shots?* #:*player-kinds* #:player-projectile?
           #:definition #:make-definition
           #:definition-name #:definition-sprite #:definition-kind
           #:projectile #:projectile-rect #:projectile-definition
           #:projectile-spline #:projectile-dead? #:projectile-move
           #:projectile-collider
           #:pool #:make-pool #:pool-live #:pool-free #:pool-world
           #:object-type #:load-definitions #:definition #:live-count
           #:should-die? #:hit
           #:fire #:fire-spline #:update #:render #:clear
           #:+z-projectile+ #:*max-projectiles*))

(defpackage #:com.thejach.descendant.enemies
  (:use #:cl)
  (:documentation "Enemy definitions, instances, movement and firing.
                   Port of dsc_enemies.c; bosses are a later slice.")
  (:local-nicknames (#:rect #:com.thejach.descendant.rect)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:collision #:com.thejach.descendant.collision)
                    (#:spline #:cl-catmull-rom-spline)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:state #:com.thejach.descendant.state)
                    (#:bullets #:com.thejach.descendant.bullets))
  (:export #:definition #:definition-name #:definition-sprite #:definition-kind
           #:definition-acceleration #:definition-homing #:definition-health
           #:definition-movements #:definition-shots #:definition-guns
           #:definition-spawn-probability #:definition-spawn-orientation
           #:gun #:make-gun #:gun-x-fraction #:gun-y-fraction #:gun-shots
           #:enemy #:enemy-rect #:enemy-health #:enemy-movement
           #:enemy-movement-timer #:enemy-dead? #:enemy-definition #:enemy-collider
           #:enemy-spline #:enemy-frame #:advance-frame
           #:+animation-delta+ #:+turret-wake-x+
           #:path #:make-path #:path-dt #:path-knots #:*spline-paths* #:path-for
           #:build-spline #:advance-spline #:+spline-restart-limit+
           #:pool #:make-pool #:pool-live #:pool-free #:pool-world #:pool-world-x
           #:pool-on-death #:pool-player-status #:pool-difficulty #:pool-fire-bullet
           #:pool-scroll-delta
           #:pool-sound-death #:pool-sound-fire #:pool-sound-bomb
           #:pool-fire-spline #:pool-on-boss-defeated #:pool-emit
           #:pool-midboss-count #:pool-midboss-deaths
           #:spawn-allowed? #:+max-midboss-instances+
           #:*max-concurrent-midbosses* #:live-midbosses
           #:*max-concurrent-per-definition* #:live-of-definition
           #:*max-concurrent-overrides* #:max-concurrent-for
           #:init-theme #:*chaser-name* #:*chaser-spawn*
           #:offscreen #:offscreen-rule #:+offscreen-wrap-distance+
           #:bullet-flamer #:bullet-launcher #:bullet-upcurve #:bullet-circle
           #:bullet-homing #:bullet-cannon #:bullet-omega-blast
           #:ship-damage-enabled? #:*vulnerable-player-states*
           #:pattern #:make-pattern #:pattern-bullet #:pattern-speed
           #:pattern-spread #:pattern-delay #:pattern-spline
           #:shot-pattern #:gun-position #:fire-spread #:fire-everything
           #:+fire-x-limit+
           #:movement-type #:shot-type #:parse-guns #:parse-int-list
           #:load-definition #:load-definitions #:definition #:live-count
           #:scroll-step #:advance-movement #:movement-fn
           #:spawn #:turret? #:damage-for #:score-for #:hit
           #:update #:render #:clear
           #:+z-enemy+ #:+max-enemies+))

(defpackage #:com.thejach.descendant.hud
  (:use #:cl)
  (:documentation "Health and shield meters, score, FPS and pause banner.
                   Port of dsc_hud.c.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:text #:com.thejach.descendant.text)
                    (#:screen #:com.thejach.descendant.screen))
  (:export #:hud #:make-hud #:hud-score #:hud-health #:hud-shields #:hud-fps
           #:hud-show-fps? #:hud-paused?
           #:hud-health-bar #:hud-shield-bar #:hud-score-sprite #:hud-fps-sprite
           #:hud-gc #:hud-gc-sprite #:set-gc #:gc-milliseconds
           #:set-bar #:set-score #:set-fps #:update #:render #:toggle-fps #:toggle-pause
           #:set-banner #:flash-shields #:hud-banner-sprite #:hud-banner-visible?
           #:hud-banner-delta #:hud-banner-flash-delta
           #:+banner-delta+ #:+banner-flash-delta+
           #:set-status #:hud-status #:hud-stat-bg
           #:+glyph-bg+ #:+glyph-invuln-bg+ #:+glyph-on+ #:+glyph-off+
           #:+shield-bars+ #:+health-bars+ #:+glyph-on+ #:+glyph-off+ #:+glyph-bg+
           #:+z-hud+))

(defpackage #:com.thejach.descendant.emitter
  (:use #:cl)
  (:documentation "The particle fountain. Port of dsc_emitter.c.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen))
  (:export #:particle #:particle-x #:particle-y #:particle-lifetime #:particle-sprite
           #:particle-vx #:particle-vy
           #:emitter #:make-emitter #:emitter-live #:emitter-random-state
           #:live-count #:spew #:update #:render #:clear
           #:*colour-pairs* #:+z-particle+ #:+scroll-adjust+))

(defpackage #:com.thejach.descendant.screen-effect
  (:use #:cl)
  (:documentation "The buffer machine shared by the warp hole and the static field.
                   dsc_static_field.c is a copy of dsc_warp_hole.c -- its header comment
                   still says so -- and this is the 90% they have in common.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen))
  (:export #:effect #:make-effect #:effect-state #:effect-current #:effect-sprites
           #:effect-pos-x #:effect-pos-y #:effect-active-frame #:effect-z
           #:active? #:buffer #:read-buffer #:write-buffer #:swap
           #:begin #:snapshot #:finish #:seed-if-needed #:boil #:render
           #:+cos-45+))

(defpackage #:com.thejach.descendant.warp
  (:use #:cl)
  (:documentation "The end-of-level vortex. Port of dsc_warp_hole.c.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:fx #:com.thejach.descendant.screen-effect))
  (:export #:warp #:make-warp #:warp-state #:warp-active-frame #:warp-radius
           #:warp-init-radius #:warp-current #:warp-sprites #:warp-rotation
           #:warp-effect
           #:active? #:begin #:snapshot #:finish #:update #:render
           #:*centre-row-artifact* #:+boil-frames+ #:+z-warp+))

(defpackage #:com.thejach.descendant.static-field
  (:use #:cl)
  (:documentation "The player's death sequence. Port of dsc_static_field.c.")
  (:local-nicknames (#:screen #:com.thejach.descendant.screen)
                    (#:fx #:com.thejach.descendant.screen-effect))
  (:export #:static-field #:make-static-field #:static-field-radius
           #:static-field-effect
           #:state #:active-frame #:sprites #:current
           #:active? #:begin #:snapshot #:finish #:update #:render
           #:+radius-growth+ #:+z-static-field+))

(defpackage #:com.thejach.descendant.effects
  (:use #:cl)
  (:documentation "Frame-animated one-shot sprites. Port of dsc_effects.c.")
  (:local-nicknames (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:bullets #:com.thejach.descendant.bullets))
  (:export #:definition #:definition-name #:definition-sprite #:definition-loops
           #:definition-delta
           #:effect #:effect-x #:effect-y #:effect-frame #:effect-dead?
           #:effect-loops-left #:effect-definition
           #:pool #:make-pool #:pool-live
           #:load-definitions #:definition #:live-count
           #:create-object #:update #:render #:clear #:+z-effect+))

(defpackage #:com.thejach.descendant.collectables
  (:use #:cl)
  (:documentation "Power-up pickups. Port of dsc_collectables.c.")
  (:local-nicknames (#:rect #:com.thejach.descendant.rect)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:collision #:com.thejach.descendant.collision)
                    (#:bullets #:com.thejach.descendant.bullets))
  (:export #:definition #:definition-name #:definition-sprite #:definition-kind
           #:collectable #:collectable-rect #:collectable-dead? #:collectable-definition
           #:collectable-collider
           #:pool #:make-pool #:pool-live #:pool-world #:pool-world-x #:pool-sound
           #:pool-on-collect
           #:load-definitions #:definition #:live-count
           #:collect #:create-object #:update #:render #:clear
           #:+z-collectable+ #:+dead-delta+))

(defpackage #:com.thejach.descendant.environment
  (:use #:cl)
  (:documentation "Ambient fields (ground, ceiling, background) and parallax scenery.
                   Port of dsc_environment.c.")
  (:local-nicknames (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:bullets #:com.thejach.descendant.bullets))
  (:export #:definition #:definition-name #:definition-sprite #:definition-kind
           #:definition-layer
           #:scenery #:make-scenery #:scenery-x #:scenery-y #:scenery-definition
           #:environment #:make-environment
           #:environment-ground #:environment-ceiling #:environment-background
           #:environment-layers #:environment-definitions
           #:environment-ground-height #:environment-ceiling-height
           #:floor-y #:ceiling-y #:render-level
           #:load-definitions #:create-object #:scenery-count
           #:update #:render #:clear
           #:+parallax-factor+ #:+dead-delta+ #:*layers*))

(defpackage #:com.thejach.descendant.spawner
  (:use #:cl)
  (:documentation "Distance-driven spawning of enemies, scenery and collectables.
                   Port of dsc_spawner.c.")
  (:local-nicknames (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:state #:com.thejach.descendant.state)
                    (#:bullets #:com.thejach.descendant.bullets))
  (:export #:scaled-distance
           #:spawnable #:spawnable-name #:spawnable-sprite #:spawnable-kind
           #:spawnable-orientation #:spawnable-probability
           #:spawn-class #:spawn-class-name #:spawn-class-objects
           #:spawn-class-probability #:spawn-class-start #:spawn-class-delta
           #:spawn-class-last-spawn-x
           #:spawner #:make-spawner #:spawner-classes #:spawner-special
           #:spawner-ceiling-y #:spawner-ground-y #:spawner-create
           #:spawner-start-x #:spawner-max-world-x #:spawner-spawn-world-x
           #:spawner-ceiling-right #:spawner-center-right #:spawner-floor-right
           #:spawner-random-state
           #:orientation #:pick-weighted #:total-weight
           #:load-spawnable #:load-class #:reset #:place #:handler-kind
           #:spawn-ready? #:spawn #:spawn-special #:update
           #:+min-y+))

(defpackage #:com.thejach.descendant.player
  (:use #:cl)
  (:documentation "The player ship. Port of dsc_player.c.")
  (:local-nicknames (#:rect #:com.thejach.descendant.rect)
                    (#:movement #:com.thejach.descendant.movement)
                    (#:state #:com.thejach.descendant.state)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:level #:com.thejach.descendant.level))
  (:export #:player #:make-player
           #:player-rect #:player-move #:player-sprite #:player-collider
           #:player-status #:player-health #:player-max-health
           #:player-shields #:player-max-shields #:player-score
           #:player-laser-limit #:player-bomb-limit #:player-death-limit
           #:player-spread #:player-rapid #:player-invuln
           #:player-start-x #:player-max-x #:player-min-y #:player-max-y
           #:player-fire-bullet #:player-fire-bomb #:player-emit
           #:player-sound-fire #:player-sound-bomb
           #:*couple-vertical-to-thrust* #:*vertical-accel*
           #:steer-acceleration
           #:alive? #:invulnerable? #:effective-status
           #:fire-laser #:fire-bomb #:bomb-arc
           #:damage-for #:apply-collectable #:hit #:explode
           #:*invincible?* #:*points-shield-refund* #:points-shield-refund
           #:powerup-duration
           #:*contact-kinds* #:*contact-damage-scale*
           #:player-health-debt #:player-shield-debt
           #:player-scr-x #:player-scr-y #:player-trigger-frame
           #:defeat-boss #:+warp-delay+ #:+warp-arrival-sq+
           #:update #:render))

(defpackage #:com.thejach.descendant.cheats
  (:use #:cl)
  (:documentation "Typed cheat codes. ADDED, not ported -- the original has none.")
  (:local-nicknames (#:player #:com.thejach.descendant.player))
  (:export #:*buffer* #:*buffer-size* #:*codes*
           #:define-cheat #:feed #:reset #:toggle-invincible))

(defpackage #:com.thejach.descendant.level.intro
  (:use #:cl)
  (:documentation "The intro level: crash-landing movie then scrolling credits.
                   Port of dsc_level_intro.c.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:level #:com.thejach.descendant.level))
  (:export #:intro))

;;; Before the menu, which offers to erase the table and so names this package.
(defpackage #:com.thejach.descendant.level.score
  (:use #:cl)
  (:documentation "The high score table. Port of dsc_level_score.c.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:state #:com.thejach.descendant.state)
                    (#:level #:com.thejach.descendant.level))
  (:export #:score
           #:read-high-scores
           #:write-high-scores
           #:score-player-score
           #:score-input-mode? #:score-input-name #:score-scores #:*scores-path*
           #:scores-path #:erase-scores #:*default-scores*
           #:set-input-mode #:input-char #:input-backspace #:commit-name
           #:rebuild-entries #:+max-name-length+
           #:qualifies?
           #:insert-score
           #:format-row
           #:layout-y))

(defpackage #:com.thejach.descendant.level.menu
  (:use #:cl)
  (:documentation "Placeholder menu so the intro has somewhere to hand off to.
                   The real port of dsc_level_menu.c lands in milestone 5.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:state #:com.thejach.descendant.state)
                    (#:settings #:com.thejach.descendant.settings)
                    (#:score #:com.thejach.descendant.level.score)
                    (#:level #:com.thejach.descendant.level))
  (:export #:menu #:menu-difficulty #:menu-page #:menu-selection
           #:menu-erased? #:menu-restart-needed?
           #:*sub-columns* #:*erased-label* #:*restart-label* #:*value-strip*
           #:row-enabled? #:choices-for))

(defpackage #:com.thejach.descendant.level.controls
  (:use #:cl)
  (:documentation "The controls reference card. Port of dsc_level_controls.c.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:level #:com.thejach.descendant.level))
  (:export #:controls))

(defpackage #:com.thejach.descendant.wipe
  (:use #:cl)
  (:documentation "ADDED, not ported. A transition: filled rectangles growing from the
                   centre in concentric bands until the screen is covered.")
  (:local-nicknames (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:screen #:com.thejach.descendant.screen))
  (:export #:wipe #:make-wipe #:start #:stop #:update #:render #:recolor
           #:running? #:covered? #:progress #:wipe-ticks #:wipe-timer #:wipe-ramp
           #:wipe-direction #:+default-ticks+ #:+band-count+))

(defpackage #:com.thejach.descendant.showcase
  (:use #:cl)
  (:documentation "ADDED, not ported. The parade of enemies across the credit roll:
                   each flies in from the right, fires its signature pattern, and leaves.

                   The enemies are real ones -- the shipped definitions, guns and shot
                   patterns -- driven along a scripted path instead of by their movement
                   types, and toned into the credits palette on the way in.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:rect #:com.thejach.descendant.rect)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:bullets #:com.thejach.descendant.bullets)
                    (#:enemies #:com.thejach.descendant.enemies)
                    (#:level #:com.thejach.descendant.level))
  (:export #:showcase #:make-showcase #:update #:render #:free
           #:*roster* #:*lanes* #:showcase-slots #:showcase-bullets
           #:slot-entry #:slot-phase #:slot-x #:slot-timer #:slot-row #:slot-delay
           #:entry-label #:entry-enemy #:entry-height #:entry-flush-right?
           #:showcase-solo #:showcase-pending #:showcase-solo-height
           #:+band-top+ #:+band-bottom+
           #:+fly-in-ticks+ #:+hold-ticks+ #:+fly-out-ticks+ #:+cycle-ticks+))

(defpackage #:com.thejach.descendant.level.credits
  (:use #:cl)
  (:documentation "The scrolling credit roll. Port of dsc_level_credits.c.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:showcase #:com.thejach.descendant.showcase)
                    (#:wipe #:com.thejach.descendant.wipe)
                    (#:level #:com.thejach.descendant.level))
  (:export #:credits #:layout-y #:credits-showcase #:credits-wipe))

(defpackage #:com.thejach.descendant.level.bestiary
  (:use #:cl)
  (:documentation "ADDED, not ported. A hidden gallery of every enemy, stage by stage,
                   in each stage's own colours. Reached with B from the credits.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:glyph #:com.thejach.descendant.glyph)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:rect #:com.thejach.descendant.rect)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:bullets #:com.thejach.descendant.bullets)
                    (#:enemies #:com.thejach.descendant.enemies)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:wipe #:com.thejach.descendant.wipe)
                    (#:level #:com.thejach.descendant.level))
  (:export #:bestiary #:*stages* #:*flush-right* #:*layout* #:display-name
           #:bestiary-stages #:bestiary-index #:bestiary-phase #:bestiary-timer
           #:bestiary-wipe #:current-stage #:advance-stage
           #:stage #:stage-key #:stage-theme #:stage-exhibits #:stage-enemies
           #:stage-bullets
           #:exhibit #:exhibit-name #:exhibit-label #:exhibit-enemy
           #:exhibit-x #:exhibit-y #:exhibit-width
           #:+settle-ticks+ #:+linger-ticks+ #:+stage-ticks+))

(defpackage #:com.thejach.descendant.level.descendant
  (:use #:cl)
  (:documentation "The game level. Port of dsc_level_descendant.c: builds every
                   subsystem from the theme's config and wires their hooks together.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:config #:com.thejach.descendant.config)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:screen #:com.thejach.descendant.screen)
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
                    (#:effects #:com.thejach.descendant.effects)
                    (#:emitter #:com.thejach.descendant.emitter)
                    (#:warp #:com.thejach.descendant.warp)
                    (#:static-field #:com.thejach.descendant.static-field)
                    (#:hud #:com.thejach.descendant.hud)
                    (#:state #:com.thejach.descendant.state)
                    (#:settings #:com.thejach.descendant.settings)
                    (#:level #:com.thejach.descendant.level))
  (:export #:descendant #:*themes* #:theme-files
           #:descendant-player #:descendant-bullets #:descendant-enemies
           #:descendant-spawner #:descendant-environment #:descendant-collectables
           #:descendant-effects #:descendant-emitter #:descendant-hud
           #:descendant-world #:descendant-theme #:descendant-paused?
           #:descendant-difficulty #:descendant-held #:held? #:toggle-pause
           #:carry-score-on #:abandon-run
           #:descendant-theme-key #:descendant-warp #:descendant-trigger-frame
           #:descendant-swallowed? #:*warp-shape* #:+boss-death-delta+
           #:descendant-static-field #:descendant-enemies-retired?
           #:+warp-done-delta+ #:+warp-all-delta+))

(defpackage #:com.thejach.descendant.level.placeholder
  (:use #:cl)
  (:documentation "Stand-ins for levels not yet ported, so menu navigation works.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:font #:com.thejach.descendant.font)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:level #:com.thejach.descendant.level))
  (:export #:placeholder))

(defpackage #:com.thejach.descendant
  (:use #:cl)
  (:documentation "Entry point.")
  (:local-nicknames (#:paths #:com.thejach.descendant.paths)
                    (#:glyph #:com.thejach.descendant.glyph)
                    (#:font #:com.thejach.descendant.font)
                    (#:theme #:com.thejach.descendant.theme)
                    (#:config #:com.thejach.descendant.config)
                    (#:text #:com.thejach.descendant.text)
                    (#:field #:com.thejach.descendant.field)
                    (#:audio #:com.thejach.descendant.audio)
                    (#:screen #:com.thejach.descendant.screen)
                    (#:renderer #:com.thejach.descendant.renderer)
                    (#:renderer.gl #:com.thejach.descendant.renderer.gl)
                    (#:cheats #:com.thejach.descendant.cheats)
                    (#:settings #:com.thejach.descendant.settings)
                    (#:score #:com.thejach.descendant.level.score)
                    (#:deploy #:org.shirakumo.deploy)
                    (#:state #:com.thejach.descendant.state)
                    (#:level #:com.thejach.descendant.level))
  (:export #:main
           #:toplevel
           #:*fullscreen?*
           #:*start-level*
           #:*unlimited?*
           #:*gl-context*
           #:toggle-unlimited
           #:apply-settings
           #:apply-fullscreen
           #:toggle-fullscreen))
