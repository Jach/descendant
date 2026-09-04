#!/usr/bin/env bash
#
# Build the game's core ON THE DEVICE and bring it back. Desktop side, phone attached.
#
#   android/build-core.sh
#
# Milestone M3. This is the step that cannot happen on the desktop: fasls are
# target-specific, so the game and its whole dependency tree have to be compiled by the
# SBCL that will run them. Everything else is just moving files around.
#
# The first run compiles about thirty systems from scratch and is slow. Later runs reuse
# the device's fasl cache and only recompile what changed.
#
# ENV KNOBS
#   CLEAN=1   wipe the device's staging directory and fasl cache first

set -euo pipefail

here="${BASH_SOURCE[0]%/*}"
[[ "$here" == "${BASH_SOURCE[0]}" ]] && here="."
cd "$here"

SBCL_TREE="${SBCL_TREE:-$PWD/sbcl-2.6.8}"
REMOTE="/data/local/tmp/descendant"
REMOTE_SBCL="/data/local/tmp/sbcl"
STAGE="out/stage"

# Heap for the COMPILE, which is nothing to do with the heap the game runs in -- that one
# is set by the argv main.c passes to initialize_lisp, and SAVE-LISP-AND-DIE does not bake
# this in.
#
# SBCL's default gigabyte is not enough to compile cl-opengl. Its funcs-gl.lisp is one
# vast file of defcfun forms, and SBCL's constraint propagation over it exhausts the heap
# mid-collection at about 99% of a gigabyte.
#
# Four is a round number well clear of that, and costs nothing on a device that cannot use
# it: dynamic space is reserved address space, not committed memory, so a 64-bit phone
# with far less RAM than this still starts fine.
BUILD_HEAP_MB="${BUILD_HEAP_MB:-4096}"

say() { echo; echo "== $* =="; }

# ---------------------------------------------------------------------------

say "checking prerequisites"

[[ -f "$SBCL_TREE/src/runtime/sbcl" ]] || {
  echo "No cross-built SBCL. Run android/build-sbcl.sh first." >&2; exit 1; }
[[ -d "$SBCL_TREE/obj/sbcl-home/contrib" ]] || {
  echo "No contribs at $SBCL_TREE/obj/sbcl-home -- ASDF lives there." >&2; exit 1; }
[[ -d "ndk/libs/arm64-v8a" ]] || {
  echo "No native libraries. Run android/build.sh first." >&2; exit 1; }

DEVICES="$(adb devices | awk 'NR>1 && $2=="device" {n++} END {print n+0}')"
[[ "$DEVICES" -gt 0 ]] || { echo "No usable device." >&2; adb devices >&2; exit 1; }

if [[ "${CLEAN:-0}" == "1" ]]; then
  echo "   wiping $REMOTE and the device fasl cache"
  adb shell "rm -rf $REMOTE" || true
fi

# ---------------------------------------------------------------------------
# 1. Work out what to send
#
# Asked of ASDF rather than listed here: load the game on the desktop and see what that
# took. A hand-written list would drift from descendant.asd the first time a dependency
# changed, and silently -- the build would just fail on the device, an hour of pushing
# later.

say "collecting the dependency closure"

SYSTEMS="$(sbcl --script collect-systems.lisp)"
COUNT="$(echo "$SYSTEMS" | grep -c .)"
echo "   $COUNT system directories"

# ---------------------------------------------------------------------------
# 2. Stage
#
# Copied into one flat tree rather than pushed from their scattered homes, so the device
# sees a single directory and the registry setup in build-android.lisp is one line.
#
# Symlinks are flattened for the same reason as in build-sbcl.sh: adb push cannot create
# one on an unrooted device, and several Quicklisp checkouts contain them.

say "staging"

rm -rf "$STAGE"
mkdir -p "$STAGE/systems"

PROJECT="$(cd .. && pwd)"

# A checkout is not the same thing as a system.
#
# ASDF hands back the directory a system was defined in, and for the two we own that
# directory holds far more than the system: this project's is 27 GB once android/ has an
# SBCL build tree, the API-35 platform stubs and bin/ in it -- and it contains out/stage,
# so copying it wholesale means copying the staging directory into itself. Which is what
# the first version of this did.
#
# So the two local checkouts are staged by naming what ASDF actually reads. Everything
# from Quicklisp is a real system directory and can be copied whole.
# -p on every copy, and it is not cosmetic.
#
# Staging is rebuilt from scratch each run, so without preserved timestamps every file
# arrives with a new mtime, `adb push --sync` concludes the whole tree has changed and
# sends it, and ASDF then finds every fasl older than its source and recompiles the lot.
# That is thirty systems of pointless work on a phone, every run. With -p, unchanged
# sources keep their mtimes, the push skips them, and the device's fasl cache stands.
stage_lean() {                       # src dst item...
  local src="$1" dst="$2"; shift 2
  mkdir -p "$dst"
  local item
  for item in "$@"; do
    [[ -e "$src/$item" ]] && cp -rLp "$src/$item" "$dst/"
  done
}

stage_whole() {                      # src dst
  local src="$1" dst="$2"
  mkdir -p "$dst"
  # Skipping .git on the way in rather than deleting it afterwards: several of these are
  # git checkouts whose history dwarfs their source.
  find "$src" -mindepth 1 -maxdepth 1 ! -name '.git' \
    -exec cp -rLp {} "$dst/" \; 2>/dev/null || true
}

while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  name="$(basename "${dir%/}")"
  dst="$STAGE/systems/$name"
  case "$(cd "$dir" && pwd)" in
    "$PROJECT")
      # assets/ is not needed to compile, but having it on the device is what allows a
      # headless frame to be rendered there and diffed against the desktop.
      stage_lean "$dir" "$dst" descendant.asd src assets ;;
    */lgame)
      stage_lean "$dir" "$dst" lgame.asd src ;;
    *)
      stage_whole "$dir" "$dst" ;;
  esac
done <<< "$SYSTEMS"

# Specs for architectures that are not this one: cl-sdl2 ships nineteen at ~3.5 MB each,
# and exactly two matter -- the Android one it will use, and the x86-64 Linux one that
# build-android.lisp copies for the two bindings that lack an Android spec.
find "$STAGE" -name '*.spec' \
     ! -name '*.aarch64-unknown-linux-android.spec' \
     ! -name '*.x86_64-pc-linux-gnu.spec' -delete 2>/dev/null || true

# adb push cannot recreate a symlink on an unrooted device.
find "$STAGE" -type l -delete 2>/dev/null || true

cp build-android.lisp "$STAGE/"

STAGED_MB="$(find "$STAGE" -type f -printf '%s\n' | awk '{s+=$1} END {printf "%.0f", s/1048576}')"
echo "   $(find "$STAGE" -type f | wc -l) files, ${STAGED_MB} MB"

# A tripwire, because the failure it catches does not look like a failure.
#
# ASDF reports the directory a system was DEFINED in, and for this project that is a
# checkout holding an SBCL build tree, the platform stubs, bin/ and out/stage itself --
# 27 GB, and self-referential, so a naive copy never finishes rather than erroring. The
# lean staging above is the fix; this is here so that if the rules and the tree ever drift
# apart again, the build says so in a second instead of filling the disk.
if [[ "$STAGED_MB" -gt 500 ]]; then
  echo >&2
  echo "Staged ${STAGED_MB} MB, which is far more than the ~45 MB this should be." >&2
  echo "Something is being copied whole that ought to be copied leanly; check the" >&2
  echo "case statement above against what collect-systems.lisp returned." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Push

say "pushing to $REMOTE"

adb shell "mkdir -p $REMOTE"
adb push --sync "$STAGE/systems"     "$REMOTE/" > /dev/null
adb push "$STAGE/build-android.lisp" "$REMOTE/" > /dev/null

# The native libraries, so CFFI has something to dlopen.
#
# And the versioned names cl-sdl2 asks for, as symlinks. Android has no versioned
# sonames, so the files are libSDL2.so and friends; the bindings want
# libSDL2-2.0.so.0. Here that is a symlink, which the device can make even though adb
# push cannot. The APK cannot have one at all, which is why build-android.lisp rewrites
# the library specs before dumping -- this only gets the BUILD to load.
adb push --sync ndk/libs/arm64-v8a "$REMOTE/" > /dev/null
adb shell "cd $REMOTE/arm64-v8a && \
  ln -sf libSDL2.so libSDL2-2.0.so.0 && \
  ln -sf libSDL2_mixer.so libSDL2_mixer-2.0.so.0 && \
  ln -sf libSDL2_image.so libSDL2_image-2.0.so.0 && \
  ln -sf libSDL2_ttf.so libSDL2_ttf-2.0.so.0"

# ---------------------------------------------------------------------------
# 4. Build
#
# SBCL_HOME points at the cross-build's contribs, which is where ASDF is -- the runtime
# was never installed anywhere, it just sits in the build tree.

say "compiling on the device (slow the first time)"

# HOME is not set in an adb shell, and without it ASDF resolves its output cache to
# /.cache -- the filesystem root, which no app or shell user may write. The failure looks
# alarming (a backtrace out of trivial-features' first compile) and has nothing to do with
# any of this; it is just ASDF asking where home is and being told nowhere.
#
# Pointing HOME at the staging directory also puts the fasl cache inside it, so CLEAN=1
# genuinely clears it and adb push --sync leaves it alone between runs.
adb shell "cd $REMOTE && \
  HOME=$REMOTE \
  XDG_CACHE_HOME=$REMOTE/.cache \
  SBCL_HOME=$REMOTE_SBCL/obj/sbcl-home \
  LD_LIBRARY_PATH=$REMOTE/arm64-v8a \
  $REMOTE_SBCL/src/runtime/sbcl \
    --core $REMOTE_SBCL/output/sbcl.core \
    --dynamic-space-size $BUILD_HEAP_MB \
    --no-sysinit --no-userinit --disable-debugger \
    --load build-android.lisp" 2>&1 | tee out/build-core.log

# ---------------------------------------------------------------------------

say "retrieving the core"

# core/ and not out/: build.sh wipes out/ at the start of every run, and this file cost
# minutes of on-device compilation to make.
mkdir -p core
adb pull "$REMOTE/descendant.core" "core/descendant.core" > /dev/null 2>&1 || {
  echo "No core came back. The tail of out/build-core.log says why." >&2
  exit 1; }

printf '   core/descendant.core  %s bytes\n' "$(stat -c %s core/descendant.core)"

cat <<EOF

== M3 core built ==

Next: put it in the APK in place of the stock one, which is a one-line change to
build.sh once this has been seen to work.
EOF
