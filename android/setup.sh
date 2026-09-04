#!/usr/bin/env bash
#
# Fetch the SDL sources the Android build needs. Desktop side, run once.
#
#   android/setup.sh
#
# Same arrangement as win32/setup.sh: everything this downloads is gitignored, and this
# script is the tracked record of what was downloaded and from where. Re-running is close
# to a no-op once the archives are in place.
#
# Versions are pinned to match win32/downloads/ exactly. There is no technical need for
# the two platforms to agree, but when a bug shows up on one and not the other, "they are
# different SDL versions" is a hypothesis worth having ruled out in advance.
#
# Only SDL2 itself is BUILT at this stage -- milestone M0 needs nothing else. The other
# three are fetched now anyway so that all four URLs are validated in one trip, and so
# that M5 is an edit to android/jni/Android.mk rather than another download.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOWNLOADS="downloads"
SRC="src"

SDL_VERSION="2.32.8"
SDL_IMAGE_VERSION="2.8.12"
SDL_MIXER_VERSION="2.8.2"
SDL_TTF_VERSION="2.24.0"

mkdir -p "$DOWNLOADS" "$SRC"

fetch() {
  local url="$1" file="$2"
  if [[ -f "$DOWNLOADS/$file" ]]; then
    echo "   have $file"
  else
    echo "   fetching $file"
    wget -q --show-progress -O "$DOWNLOADS/$file.part" "$url"
    mv "$DOWNLOADS/$file.part" "$DOWNLOADS/$file"
  fi
}

unpack() {
  local file="$1" dir="$2"
  if [[ -d "$SRC/$dir" ]]; then
    echo "   have $dir/"
  else
    echo "   unpacking $dir"
    tar -xzf "$DOWNLOADS/$file" -C "$SRC"
  fi
}

echo "== fetching =="
# The release tarballs, not the git checkouts: SDL_image, SDL_mixer and SDL_ttf carry
# their dependencies in external/ only in the release archives. That is the difference
# between "build it" and "go find freetype for arm64".
fetch "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL2-$SDL_VERSION.tar.gz" \
      "SDL2-$SDL_VERSION.tar.gz"
fetch "https://github.com/libsdl-org/SDL_image/releases/download/release-$SDL_IMAGE_VERSION/SDL2_image-$SDL_IMAGE_VERSION.tar.gz" \
      "SDL2_image-$SDL_IMAGE_VERSION.tar.gz"
fetch "https://github.com/libsdl-org/SDL_mixer/releases/download/release-$SDL_MIXER_VERSION/SDL2_mixer-$SDL_MIXER_VERSION.tar.gz" \
      "SDL2_mixer-$SDL_MIXER_VERSION.tar.gz"
fetch "https://github.com/libsdl-org/SDL_ttf/releases/download/release-$SDL_TTF_VERSION/SDL2_ttf-$SDL_TTF_VERSION.tar.gz" \
      "SDL2_ttf-$SDL_TTF_VERSION.tar.gz"

echo "== unpacking =="
unpack "SDL2-$SDL_VERSION.tar.gz"             "SDL2-$SDL_VERSION"
unpack "SDL2_image-$SDL_IMAGE_VERSION.tar.gz" "SDL2_image-$SDL_IMAGE_VERSION"
unpack "SDL2_mixer-$SDL_MIXER_VERSION.tar.gz" "SDL2_mixer-$SDL_MIXER_VERSION"
unpack "SDL2_ttf-$SDL_TTF_VERSION.tar.gz"     "SDL2_ttf-$SDL_TTF_VERSION"

# Stable names, so nothing downstream has to know the version numbers. build.sh symlinks
# these into the ndk-build work tree.
ln -sfn "SDL2-$SDL_VERSION"             "$SRC/SDL2"
ln -sfn "SDL2_image-$SDL_IMAGE_VERSION" "$SRC/SDL2_image"
ln -sfn "SDL2_mixer-$SDL_MIXER_VERSION" "$SRC/SDL2_mixer"
ln -sfn "SDL2_ttf-$SDL_TTF_VERSION"     "$SRC/SDL2_ttf"

JAVA_SRC="$SRC/SDL2/android-project/app/src/main/java/org/libsdl/app"
[[ -d "$JAVA_SRC" ]] || { echo "SDL's Java sources are not where expected: $JAVA_SRC" >&2; exit 1; }

cat <<EOF

== setup done ==

  SDL2 source:  android/$SRC/SDL2
  SDL2 Java:    android/$JAVA_SRC  ($(ls "$JAVA_SRC"/*.java | wc -l) files)

Next: android/build.sh
EOF
