(defsystem "descendant"
  :description "Port of The Descendant (DigiPen GAM150, 2010) to Common Lisp"
  :author "Kevin Secretan <jach@thejach.com>"
  :defsystem-depends-on ("deploy")
  :depends-on ("lgame" "alexandria" "static-vectors" "cl-catmull-rom-spline" "cl-opengl"
               "deploy")
  ;; ASDF:MAKE produces bin/ -- the executable, the foreign libraries it needs, and the
  ;; assets -- which is the thing to hand to somebody, not the executable alone.
  :build-operation "deploy-op"
  :build-pathname "descendant"
  :entry-point "com.thejach.descendant:toplevel"
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "paths")
                             (:file "settings")
                             (:file "state")
                             (:file "binary")

                             ;; asset decoding
                             (:file "glyph")
                             (:file "font")
                             (:file "theme")
                             (:file "config")

                             ;; sprite generation from assets
                             (:file "text")
                             (:file "field")

                             ;; geometry and physics
                             (:file "rect")
                             (:file "movement")

                             ;; presentation
                             (:file "screen")
                             (:file "renderer")

                             ;; Same two variables, one dialect each: GLSL 3.30 for
                             ;; desktop GL, GLSL ES 3.00 for Android. Whole copies rather
                             ;; than one string with conditionals in it, so that diffing
                             ;; the pair is the account of what changed. RENDERER-GL
                             ;; below does not know which it got.
                             (:file "renderer-gl-shaders"    :if-feature (:not :android))
                             (:file "renderer-gl-shaders-es" :if-feature :android)
                             (:file "renderer-gl")
                             (:file "audio")
                             (:file "collision")

                             ;; levels
                             (:file "level")

                             ;; Before the levels, not beside MAIN: level-score and
                             ;; level-descendant name this package in #+android forms,
                             ;; and a package has to exist when a form mentioning it is
                             ;; READ, not merely when it runs.
                             (:file "touch" :if-feature :android)

                             ;; gameplay
                             (:file "bullets")
                             (:file "enemies")
                             (:file "environment")
                             (:file "collectables")
                             (:file "emitter")
                             (:file "effects")
                             (:file "screen-effect")
                             (:file "warp")
                             (:file "static-field")
                             (:file "hud")
                             (:file "spawner")
                             (:file "player")
                             (:file "cheats")

                             ;; First: every real level below overrides the placeholder
                             ;; registered for its keyword, so the fallbacks have to go
                             ;; down before the things that replace them.
                             (:file "level-placeholder")
                             (:file "level-intro")
                             ;; Before the menu, which offers to erase the table.
                             (:file "level-score")
                             (:file "level-menu")
                             (:file "level-descendant")
                             (:file "level-controls")
                             (:file "showcase")
                             (:file "wipe")
                             (:file "level-bestiary")
                             (:file "level-credits")

                             ;; Before MAIN, which calls it: inside an APK the assets are
                             ;; a region of a zip until this has run.
                             (:file "android-assets" :if-feature :android)

                             (:file "main")

                             ;; Deploy's business is finding the foreign libraries a
                             ;; bundle needs and copying them next to the executable.
                             ;; An APK has neither an executable nor libraries to hunt:
                             ;; the packaging step already puts them where the linker
                             ;; looks. So none of this belongs in the Android build --
                             ;; and it would not compile there anyway, since it reads
                             ;; ELF headers through SB-POSIX.
                             (:file "deployment" :if-feature (:not :android)))))
  :in-order-to ((asdf:test-op (asdf:test-op "descendant/test"))))

(defsystem "descendant/test"
  :depends-on ("descendant" "fiveam")
  :serial t
  :pathname "test"
  :components ((:file "packages")
               (:file "font-tests")
               (:file "theme-tests")
               (:file "config-tests")
               (:file "screen-tests")
               (:file "text-tests")
               (:file "field-tests")
               (:file "level-tests")
               (:file "fidelity-tests")
               (:file "collision-tests")
               (:file "player-tests")
               (:file "bullets-tests")
               (:file "enemies-tests")
               (:file "spawner-tests")
               (:file "environment-tests")
               (:file "pickups-tests")
               (:file "hud-tests")
               (:file "descendant-tests")
               (:file "warp-tests")
               (:file "state-tests")
               (:file "settings-tests")
               (:file "renderer-gl-tests")
               (:file "cheats-tests")
               (:file "speed-tests")
               (:file "score-tests")
               (:file "menu-tests")
               (:file "showcase-tests")
               (:file "bestiary-tests"))
  :perform (asdf:test-op (o c) (uiop:symbol-call '#:5am '#:run-all-tests)))
