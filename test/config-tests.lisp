(in-package #:com.thejach.descendant.test)
(in-suite descendant)

(defun crash-cfg () (config:read-config (paths:config-path "level_crash_site.cfg")))

(test config-all-levels-parse
  (dolist (file '("level_intro.cfg" "level_menu.cfg" "level_credits.cfg"
                  "level_score.cfg" "level_crash_site.cfg" "level_hidden_cave.cfg"
                  "level_brain_pain.cfg"))
    (finishes (config:read-config (paths:config-path file)))))

(test config-section-and-key-trimming
  "Sections are written '[ level_data ]' with padding, and keys are padded out to align
   the '='. Both get trimmed before being joined into 'section.key'."
  (let ((c (crash-cfg)))
    (is (= 4 (config:config-int c "level_data.enemy_ships_count")))
    (is (= 512 (config:config-int c "level_data.bombs_bullets_max")))
    (is (= 5 (config:config-int c "level_data.env_ground_height")))))

(test config-comments-are-stripped
  "'probability  = 3 # should be based on difficulty' must read as 3, and the comment
   must not leak into the text value."
  (let ((c (crash-cfg)))
    (is (= 3 (config:config-int c "spawn_enemy_ship.probability")))
    (is (string= "3" (config:config-text c "spawn_enemy_ship.probability")))
    (is (= 60 (config:config-int c "spawn_enemy_ship.spawn_delta")))
    (is (= 10 (config:config-int c "spawn_nothing.probability")))))

(test config-lists
  (let ((c (crash-cfg)))
    (let ((ships (config:config-list c "level_data.enemy_ships")))
      (is (= 4 (length ships)))
      (is (string= "enemy_ship_floogle" (first ships)))
      (is (string= "enemy_ship_kamikaze" (fourth ships))))
    ;; Spaces after the commas must be trimmed away.
    (let ((tracks (config:config-list c "level_data.music_tracks")))
      (is (equal '("Play_01.mp3" "Play_02.mp3" "Play_03.mp3" "Play_04.mp3") tracks)))
    (is (= 10 (length (config:config-list c "level_data.environment_list"))))))

(test config-text-values
  (let ((c (crash-cfg)))
    (is (string= "^" (config:config-text c "level_data.env_ground_chars")))
    ;; Kept as written; leading zeroes are the author's, not a number format.
    (is (string= "004" (config:config-text c "level_data.env_ground_color")))
    (is (string= "." (config:config-text c "level_data.env_bg_field_chars")))))

(test config-missing-keys-use-defaults
  (let ((c (crash-cfg)))
    (is (null (config:config-value c "no_such.key")))
    (is (= 42 (config:config-int c "no_such.key" 42)))
    (is (string= "fallback" (config:config-text c "no_such.key" "fallback")))
    (is (null (config:config-list c "no_such.key")))))

(test config-empty-values
  "Several keys are deliberately blank, e.g. crash_site has no ceiling."
  (let ((c (crash-cfg)))
    (is (string= "" (config:config-text c "level_data.env_cieling_chars")))
    (is (= 0 (config:config-int c "level_data.env_cieling_height")))))

(test config-jaguar-is-gone
  "jaguar.wav was an FMOD sample from the old sound test driver, never shipped in
   Resources/Sounds and never read by the port -- nothing consumes the `sounds' list at
   all. Its sections have been pruned from the two configs that named it.

   The whole three-line section had to go, not just the file= line: deleting the header
   alone would leave sound_id=555 orphaned, and the parser keys on `section.key', so it
   would silently reattach to whatever section came before."
  (dolist (level '("level_hidden_cave.cfg" "level_brain_pain.cfg"))
    (let ((c (config:read-config (paths:config-path level))))
      (is (null (config:config-text c "sound_jaguar.file")) "~a: section gone" level)
      (is (null (config:config-text c "sound_jaguar.sound_id")) "~a: no orphan" level)
      (is (null (config:config-text c "spawn_collectable.sound_id"))
          "~a: sound_id did not reattach to the preceding section" level)
      ;; Still parses, and the keys around the hole are intact.
      (is (= 0 (config:config-int c "level_data.sounds_count")) "~a: count zeroed" level)
      (is (string= "" (config:config-text c "level_data.sounds")) "~a: list emptied" level)
      (is (= 4 (config:config-int c "level_data.music_tracks_count"))
          "~a: the key after the hole still reads" level)))
  (is (not (probe-file (paths:sound-path "jaguar.wav")))))
