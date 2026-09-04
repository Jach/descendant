#!/usr/bin/env bash
#
# Build descendant.apk. Desktop side.
#
#   android/setup.sh          # once, to fetch SDL
#   android/build.sh          # every time
#   android/build.sh install  # ... and push it to the phone
#
# No Gradle and no Android Studio. The pipeline is aapt2 -> javac -> d8 -> zip ->
# zipalign -> apksigner, which is few enough moving parts to see all at once, and is the
# same bargain win32/build.sh makes.
#
# ENV KNOBS
#   WITH_ASSETS=1   include the game's 18 MB of assets. Off by default: M0 does not need
#                   them and leaving them out makes the edit-build-install loop quick.
#   DESCENDANT_LISP=1
#                   build the M2 shape -- main.c hands over to Lisp instead of running its
#                   own probe. Needs libmain's Lisp half to exist first.
#
# Everything this writes goes under android/out/ and android/ndk/, both gitignored.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd .. && pwd)"

# ---------------------------------------------------------------------------
# Where things are on this machine. All absolute, because /usr/bin/java on Gentoo is a
# java-config wrapper script and going through it buys nothing but another way to fail.

NDK="${NDK:-/opt/android-ndk}"
BUILD_TOOLS="${BUILD_TOOLS:-/opt/android-sdk-update-manager/build-tools/36}"
JAVA_HOME="${JAVA_HOME:-/opt/openjdk-bin-21}"
ANDROID_JAR="${ANDROID_JAR:-$PWD/android-35/android.jar}"
SBCL_TREE="${SBCL_TREE:-$PWD/sbcl-2.6.8}"
# Deliberately NOT under out/, which this script wipes on every run. The core takes
# minutes on a device to produce and belongs to build-core.sh; putting it in a directory
# whose first act is "rm -rf" meant build.sh destroyed it and then quietly fell back to
# the stock SBCL core, so the APK ran M2's probe while looking like it had the game in it.
CORE="${CORE:-$PWD/core/descendant.core}"

OUT="out"
NDK_PROJECT="ndk"
APK_NAME="descendant"

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

# ---------------------------------------------------------------------------

say() { echo; echo "== $* =="; }

require() {
  [[ -e "$1" ]] || { echo "Missing: $1${2:+  ($2)}" >&2; exit 1; }
}

say "checking prerequisites"
require "$NDK/ndk-build"                "install the NDK, or set NDK="
require "$BUILD_TOOLS/d8"               "android-sdk-build-tools"
require "$BUILD_TOOLS/apksigner"        "android-sdk-build-tools"
require "$ANDROID_JAR"                  "unpack the API 35 platform into android/android-35/"
require "$JAVA_HOME/bin/javac"          "set JAVA_HOME to a JDK 21"
require "src/SDL2"                      "run android/setup.sh first"
for tool in aapt2 zipalign zip; do
  command -v "$tool" >/dev/null || { echo "Missing '$tool' on PATH." >&2; exit 1; }
done
echo "   ndk         $(cat "$NDK/source.properties" | sed -n 's/^Pkg.ReleaseName = //p')"
echo "   jdk         $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

rm -rf "$OUT"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# 1. Native libraries
#
# ndk-build wants a project laid out its way, so build one rather than contorting the
# tracked sources to match. The jni/ files are copied in fresh every run, so editing
# android/jni/main/main.c and re-running this is all there is to it.

say "ndk-build"

mkdir -p "$NDK_PROJECT/jni"
cp -r jni/. "$NDK_PROJECT/jni/"

# Each library builds from its own Android.mk, picked up by all-subdir-makefiles.
#
# All four, not the two this game uses: lgame's init calls sdl2-image and SDL2_ttf
# unconditionally, and building them here means lgame needs no change and a future port
# that does render fonts gets the packaging for free. See PLAN.md 5.4.
for lib in SDL2 SDL2_image SDL2_mixer SDL2_ttf; do
  ln -sfn "../../src/$lib" "$NDK_PROJECT/jni/$lib"
done

# The SBCL runtime, as a prebuilt for jni/sbcl/Android.mk. Copied rather than symlinked:
# ndk-build's prebuilt rules want a real file, and the M0 build must work with this
# absent.
if [[ "${DESCENDANT_LISP:-0}" == "1" ]]; then
  require "$SBCL_TREE/src/runtime/libsbcl.so" "run android/build-sbcl.sh first"
  require "$SBCL_TREE/output/sbcl.core"       "run android/build-sbcl.sh first"
  cp "$SBCL_TREE/src/runtime/libsbcl.so" "$NDK_PROJECT/jni/sbcl/libsbcl.so"
  echo "   linking against libsbcl.so"
fi

# Every codec is named explicitly rather than left to its default.
#
# The defaults cannot be trusted here because they assume a git checkout: SDL2_mixer's
# external/ in the release tarball holds a download.sh and nothing else, yet
# SUPPORT_WAVPACK defaults to true and wants a wavpack module that was never fetched.
# ndk-build then stops with "depends on undefined modules". The same trap is waiting
# behind FLAC and OGG, which are on by default for the same reason.
#
# So: on for the two formats the game actually ships -- assets/Sounds is .wav and .mp3 --
# and off for everything else. Smaller, and it cannot break when a default changes.
#
# SDL2_ttf is the exception that proves it: its tarball DOES bundle freetype, with an
# Android.mk, so that one builds. Only harfbuzz is missing, and it buys complex-script
# shaping that nothing here will ask for.
"$NDK/ndk-build" \
  NDK_PROJECT_PATH="$NDK_PROJECT" \
  APP_BUILD_SCRIPT="$NDK_PROJECT/jni/Android.mk" \
  NDK_APPLICATION_MK="$NDK_PROJECT/jni/Application.mk" \
  DESCENDANT_LISP="${DESCENDANT_LISP:-0}" \
  SUPPORT_WAV=true \
  SUPPORT_MP3_MINIMP3=true \
  SUPPORT_WAVPACK=false \
  SUPPORT_FLAC_DRFLAC=false \
  SUPPORT_FLAC_LIBFLAC=false \
  SUPPORT_OGG_STB=false \
  SUPPORT_OGG=false \
  SUPPORT_MP3_MPG123=false \
  SUPPORT_GME=false \
  SUPPORT_MOD_XMP=false \
  SUPPORT_MID_TIMIDITY=false \
  SUPPORT_HARFBUZZ=false \
  -j"$(nproc)"

LIBS="$NDK_PROJECT/libs/arm64-v8a"
require "$LIBS/libmain.so" "ndk-build produced no libmain.so"
require "$LIBS/libSDL2.so" "ndk-build produced no libSDL2.so"

echo
for so in "$LIBS"/*.so; do
  printf '   %-20s %8d bytes\n' "$(basename "$so")" "$(stat -c %s "$so")"
done

# What the library actually depends on. This is the check PLAN.md 7.2 asks for at M2:
# anything beyond libc/libm/libdl/liblog/libGLESv2/libSDL2 has to be shipped too, and
# Android will only install files named lib*.so out of lib/arm64-v8a/.
echo
echo "   libmain.so needs:"
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -d "$LIBS/libmain.so" \
  | sed -n 's/.*NEEDED.*\[\(.*\)\]/     \1/p'

# ---------------------------------------------------------------------------
# 2. Java -> classes.dex
#
# SDL's own classes, compiled unmodified. We contribute none: the manifest names
# org.libsdl.app.SDLActivity directly, which works because our native module is called
# "main" -- the name SDLActivity already looks for.

say "javac + d8"

SDL_JAVA="src/SDL2/android-project/app/src/main/java"
mkdir -p "$OUT/classes" "$OUT/dex"

# --release 17 rather than -bootclasspath: since JDK 9 the two are mutually exclusive,
# and d8 --lib does the platform desugaring properly anyway.
"$JAVA_HOME/bin/javac" \
  --release 17 -nowarn \
  -classpath "$ANDROID_JAR" \
  -d "$OUT/classes" \
  $(find "$SDL_JAVA" -name '*.java')

echo "   $(find "$OUT/classes" -name '*.class' | wc -l) class files"

"$BUILD_TOOLS/d8" \
  --release --min-api 21 \
  --lib "$ANDROID_JAR" \
  --output "$OUT/dex" \
  $(find "$OUT/classes" -name '*.class')

require "$OUT/dex/classes.dex" "d8 produced no dex"

# ---------------------------------------------------------------------------
# 3. Manifest (and assets) -> the base APK
#
# aapt2 is the only thing that can compile a manifest, and it handles assets too. It does
# not handle native libraries or dex, which is what step 4 is for.

say "aapt2 link"

AAPT_ASSETS=()
if [[ "${WITH_ASSETS:-0}" == "1" ]]; then
  # A staged copy, so the two files the game writes at runtime never end up shipped
  # inside the APK. They are gitignored for the same reason.
  # The extra level is deliberate: aapt2 -A takes the directory whose CONTENTS become the
  # APK's assets/, so staging the game's assets/ inside it makes the in-APK path
  # "assets/Themes/..." -- which is also where they land under the app's private
  # directory, so one manifest string serves as both the name to read and the name to
  # write.
  rm -rf "$OUT/assets"
  mkdir -p "$OUT/assets"
  cp -r "$PROJECT_ROOT/assets" "$OUT/assets/assets"
  rm -f "$OUT/assets/assets/options.ini" "$OUT/assets/assets/highscores.txt"

  # A manifest of everything shipped, because the game has to copy these out of the APK
  # on first run and cannot ask what is in there: enumerating an asset directory is a JNI
  # call, and SDL exposes no wrapper for it. The list is known here, so it is written
  # here. src/android-assets.lisp reads it back.
  #
  # Paths are relative to the APK's assets/ root and therefore begin "assets/", which is
  # also where they land under the app's private directory -- so the same string serves
  # as both the name to read and the name to write.
  # ! -name MANIFEST because the shell creates the redirect target before find runs, so
  # without it the manifest lists itself and the game copies it back out for no reason.
  ( cd "$OUT/assets" && find . -type f ! -name MANIFEST | sed 's|^\./||' | sort ) \
    > "$OUT/assets/MANIFEST"

  AAPT_ASSETS=(-A "$OUT/assets")
  echo "   including assets ($(wc -l < "$OUT/assets/MANIFEST") files + manifest)"
else
  echo "   no assets (WITH_ASSETS=1 to include them)"
fi

# The launcher icon is the only resource we have. android/make-icon.sh regenerates it
# from the game's own player sprite; the PNGs are tracked, so this build needs neither
# SBCL nor ImageMagick.
aapt2 compile --dir res -o "$OUT/res.zip"

aapt2 link \
  -o "$OUT/base.apk" \
  --manifest AndroidManifest.xml \
  -I "$ANDROID_JAR" \
  --min-sdk-version 21 \
  --target-sdk-version 35 \
  "${AAPT_ASSETS[@]}" \
  "$OUT/res.zip"

# ---------------------------------------------------------------------------
# 4. Add dex and native libraries
#
# An APK is a zip, and aapt2 has already written the entries that have to be laid out its
# way. Appending the rest with zip leaves those untouched.

say "packaging"

mkdir -p "$OUT/pkg/lib/arm64-v8a"
cp "$LIBS"/*.so "$OUT/pkg/lib/arm64-v8a/"
cp "$OUT/dex/classes.dex" "$OUT/pkg/"

# The core goes in beside the libraries, named lib*.so so that Android installs it at all
# -- the packager only extracts files matching that pattern out of lib/<abi>/. It is not
# an ELF file and nothing will try to load it as one; main.c finds it by asking the linker
# where libmain.so came from and looking next door.
#
# This placement is the whole of the uncompressed-core bet in PLAN.md 7.2: that directory
# is the one place an app controls where a file may be mapped executable. If the installer
# rejects a non-ELF lib*.so, or the mapping is refused, this is where we find out.
if [[ "${DESCENDANT_LISP:-0}" == "1" ]]; then
  # The game's core if it has been built, the stock one otherwise. The stock core still
  # runs main.c's probe, which is the M2 shape and worth keeping reachable: if the game
  # core misbehaves, swapping back says whether the problem is the game or the plumbing.
  if [[ -f "$CORE" ]]; then
    cp "$CORE" "$OUT/pkg/lib/arm64-v8a/libsbclcore.so"
    CORE_KIND="the game"
  else
    cp "$SBCL_TREE/output/sbcl.core" "$OUT/pkg/lib/arm64-v8a/libsbclcore.so"
    CORE_KIND="stock SBCL"
    # Loud, because the APK still installs and runs and looks fine -- it just runs
    # main.c's probe instead of the game, which reads as "the game did nothing".
    echo
    echo "   !! No game core at $CORE"
    echo "   !! Falling back to the stock SBCL core, so this APK will run the M2 probe"
    echo "   !! and not the game. Run android/build-core.sh to build one."
    echo
  fi
  echo "   core: $CORE_KIND"
  printf '         %s bytes as libsbclcore.so\n' \
    "$(stat -c %s "$OUT/pkg/lib/arm64-v8a/libsbclcore.so")"
fi

cp "$OUT/base.apk" "$OUT/unaligned.apk"
( cd "$OUT/pkg" && zip -q -r -X "../unaligned.apk" lib classes.dex )

# -p page-aligns the .so entries, which costs nothing and is what the platform wants.
zipalign -p -f 4 "$OUT/unaligned.apk" "$OUT/$APK_NAME-unsigned.apk"

# ---------------------------------------------------------------------------
# 5. Sign
#
# A debug key, generated once and kept. Android refuses to install an unsigned APK, and
# it refuses to install an update signed by a different key -- so regenerating this
# casually would mean uninstalling the game off every phone it is on.

say "signing"

KEYSTORE="debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
  echo "   generating $KEYSTORE (debug key, kept -- see the note in this script)"
  "$JAVA_HOME/bin/keytool" -genkeypair \
    -keystore "$KEYSTORE" -alias androiddebugkey \
    -storepass android -keypass android \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Descendant Debug, O=thejach, C=US"
fi

"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias androiddebugkey \
  --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/$APK_NAME.apk" \
  "$OUT/$APK_NAME-unsigned.apk"

"$BUILD_TOOLS/apksigner" verify --print-certs "$OUT/$APK_NAME.apk" | head -2

# ---------------------------------------------------------------------------

say "built $OUT/$APK_NAME.apk ($(stat -c %s "$OUT/$APK_NAME.apk") bytes)${CORE_KIND:+, core: $CORE_KIND}"

if [[ "${1:-}" == "install" ]]; then
  say "installing"
  adb install -r "$OUT/$APK_NAME.apk"
  cat <<EOF

Launch it, then watch what it says:

    adb shell setprop log.tag V     # see below -- needed after every reboot
    adb logcat -c && adb logcat -s descendant:V SDL:V AndroidRuntime:E

At M0 the interesting lines are GL_VERSION (needs to say OpenGL ES 3.x), the internal
storage path, and the finger events when you touch the screen.

If logcat shows NOTHING -- not even SDL's own chatter -- the phone is not logging rather
than the app not talking. This ROM ships with the global log level set to silent, which
looks identical to a broken app: 'logcat -g' reports healthy buffers and logd is running.
Check with 'adb shell getprop log.tag'; an 'S' means silent. The setprop above fixes it
without root and lasts until the next reboot.
EOF
else
  echo
  echo "   android/build.sh install   to push it to the phone"
fi
