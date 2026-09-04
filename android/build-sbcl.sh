#!/usr/bin/env bash
#
# Cross-build SBCL for Android. Runs on the DESKTOP, with the phone plugged in.
#
#   android/build-sbcl.sh
#
# This is milestone M1 of android/PLAN.md.
#
# WHY THIS IS NOT A TERMUX BUILD
#
# It was, briefly, and that was a mistake born of not reading far enough. SBCL 2.6.8
# supports Android as a first-class cross-compilation target: --with-android, Config
# files per architecture, android-os.c, and make-android.sh to drive the whole thing.
# doc/internals-notes/Android-build.txt in the source tree is the account of how it was
# done, and it is worth reading.
#
# So the build happens here, with the NDK's clang, and the phone is used only to RUN the
# stages that need target code -- header groveling, cold init, contribs -- which
# make-android.sh does over adb, pushing to /data/local/tmp where the shell user may
# execute. That is better than building in Termux on every axis: desktop compile speed,
# the real NDK sysroot instead of Termux's prefix, and no third-party patch set to track.
#
# Two flags in make-android.sh are worth knowing about, because between them they explain
# both failures the Termux attempt hit:
#
#   --with-android      run-program.c has a #if defined guard for the missing
#                       getdtablesize(). Building as plain linux misses it.
#   --without-gcc-tls   bionic's thread-local storage does not suit the initial-exec
#                       model arm64-assem.S would otherwise use, so the assembly takes
#                       its pthread_getspecific path instead. Without this you get
#                       "undefined symbol: current_thread" at link time.
#
# REQUIREMENTS
#   - the NDK
#   - a phone in developer mode, USB debugging on, attached for the WHOLE build
#   - a host SBCL (2.6.7 building 2.6.8 is fine -- N-1 is supported)
#
# ENV KNOBS
#   CLEAN=1       throw away the source tree and start over
#   LINKABLE=1    add --with-sb-linkable-runtime. Off by default: upstream's documented
#                 invocation does not use it, make-shared-library.sh produces libsbcl.so
#                 without it, and a first build should have as few variables as possible.
#                 See PLAN.md 7.2 for when we might want it.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SBCL_VERSION="2.6.8"
NDK="${NDK:-/opt/android-ndk}"
ANDROID_API="${ANDROID_API:-21}"
SRC_DIR="$PWD/sbcl-$SBCL_VERSION"

say() { echo; echo "== $* =="; }

# ---------------------------------------------------------------------------

say "checking prerequisites"

[[ -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || {
  echo "No NDK toolchain at $NDK. Set NDK=." >&2; exit 1; }

command -v sbcl >/dev/null || { echo "Need a host SBCL." >&2; exit 1; }
command -v adb  >/dev/null || { echo "Need adb." >&2; exit 1; }

# The device is not optional and not only needed at the end: make-config.sh asks it what
# architecture it is before anything is compiled. Better to say so now than forty minutes
# in.
# Skip the "List of devices attached" header, and count only lines whose state is exactly
# "device" -- an unauthorized or offline entry is a phone that is plugged in and still
# cannot run anything, which is the case worth catching separately from no phone at all.
DEVICES="$(adb devices | awk 'NR>1 && $2=="device" {n++} END {print n+0}')"
if [[ "$DEVICES" -eq 0 ]]; then
  cat >&2 <<'EOF'
No usable device. This build needs the phone attached for its whole duration -- it runs
the target-code stages over adb, and asks the device its architecture before it starts.

  - USB debugging on, cable in, and accept the RSA prompt on the phone
  - check with: adb devices -- the state must read "device", not "unauthorized"
EOF
  adb devices >&2
  exit 1
fi
echo "   device:    $(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r') ($(adb shell uname -m | tr -d '\r'))"
echo "   host sbcl: $(sbcl --version)"
echo "   ndk:       $(sed -n 's/^Pkg.ReleaseName = //p' "$NDK/source.properties")"
echo "   api level: $ANDROID_API"

# ---------------------------------------------------------------------------

say "source"

[[ "${CLEAN:-0}" == "1" ]] && rm -rf "$SRC_DIR"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "   cloning SBCL $SBCL_VERSION"
  # The annotated-tag warning git prints here is normal: the tag is a tag object, and git
  # is telling you it resolved it to the commit it points at.
  git clone --depth 1 --branch "sbcl-$SBCL_VERSION" \
    https://github.com/sbcl/sbcl.git "$SRC_DIR"
else
  echo "   reusing $SRC_DIR"
fi

cd "$SRC_DIR"

# ---------------------------------------------------------------------------
# Symlinks
#
# make-android.sh pushes the whole tree to the device, and `adb push` cannot recreate a
# symlink on an unrooted phone -- it fails with "remote symlink failed: Permission denied"
# and takes the build down with it.
#
# SBCL already knows this: make-config.sh copies its Config files rather than linking them
# when building for Android, with the comment "adb push doesn't like symlinks on unrooted
# devices". What it does not cover is the symlinks checked into the source tree itself.
# There are twelve, all in contrib/sb-manual/doc/, each pointing at a sibling contrib's
# manual.lisp. They exist to build the manual, which we are not building.
#
# Replace them with copies rather than deleting them: the cost is a few kilobytes, and a
# tree that still has every file it is supposed to have cannot surprise a later stage.

say "flattening symlinks for adb push"

SYMLINKS="$(find . -type l | wc -l)"
if [[ "$SYMLINKS" -gt 0 ]]; then
  find . -type l -print0 | while IFS= read -r -d '' link; do
    target="$(readlink -f -- "$link" || true)"
    if [[ -n "$target" && -e "$target" ]]; then
      rm -f -- "$link"
      cp -a -- "$target" "$link"
    else
      # Dangling. adb push would fail on it just the same, and nothing can want it.
      echo "   dropping broken symlink $link"
      rm -f -- "$link"
    fi
  done
  echo "   flattened $SYMLINKS"
else
  echo "   none left"
fi

# ---------------------------------------------------------------------------

say "building"

# No --with-sb-core-compression yet. Config.arm64-android links -lzstd against whatever
# is in android-libs/, which means building zstd for Android first -- a step worth taking
# only once there is something to compress. PLAN.md 7.2 covers when that becomes
# interesting; for now the uncompressed core is the shorter path to an answer.
EXTRA_FLAGS=()
[[ "${LINKABLE:-0}" == "1" ]] && EXTRA_FLAGS+=(--with-sb-linkable-runtime)

echo "   make-android.sh adds --with-android --without-gcc-tls --check-host-lisp itself"
echo "   stages needing the device run over adb into /data/local/tmp/sbcl"
echo

NDK="$NDK" ANDROID_API="$ANDROID_API" \
  sh make-android.sh \
    --ndk="$NDK" \
    --android-api="$ANDROID_API" \
    --xc-host='sbcl --no-userinit --no-sysinit --disable-debugger' \
    "${EXTRA_FLAGS[@]}"

# ---------------------------------------------------------------------------

say "shared library"

# make-android.sh runs this itself, but it is the artifact the whole port depends on, so
# check rather than assume. libsbcl.so is the runtime as something an APK may contain --
# lib/arm64-v8a/ is the only place in an APK where code may execute.
if [[ ! -f src/runtime/libsbcl.so ]]; then
  echo "   libsbcl.so missing; running make-shared-library.sh directly"
  sh make-shared-library.sh
fi

for artifact in output/sbcl.core src/runtime/sbcl src/runtime/libsbcl.so; do
  [[ -f "$artifact" ]] || { echo "MISSING: $artifact" >&2; exit 1; }
  printf '   %-28s %10d bytes\n' "$artifact" "$(stat -c %s "$artifact")"
done

echo
echo "   libsbcl.so needs:"
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -d src/runtime/libsbcl.so \
  | sed -n 's/.*NEEDED.*\[\(.*\)\]/     \1/p'
echo "   soname: $("$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -d src/runtime/libsbcl.so | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')"

# ---------------------------------------------------------------------------

say "verifying on the device"

# The built SBCL is an arm64 Android binary, so it cannot be run here. make-android.sh
# left the whole tree at /data/local/tmp/sbcl, which is where it can run.
#
# SOFT-CARD-MARKS is the interesting line, for PLAN.md 7.1: when it is on, the GC write
# barrier is software card marking rather than mprotect plus a SIGSEGV handler, and ART's
# signal chaining has that much less to interfere with.
#
# It has to be looked for in SB-IMPL:+INTERNAL-FEATURES+ and not in CL:*FEATURES*. SBCL
# keeps its build-time internals out of the user-visible list to stop it becoming a wall
# of noise; the #+ reader consults both (src/code/sharpm.lisp). Asking only *FEATURES*
# reports "no" for a feature that is switched on, which is worse than not asking.

adb shell "cd /data/local/tmp/sbcl && \
  LD_LIBRARY_PATH=/data/local/tmp/sbcl/android-libs \
  ./src/runtime/sbcl --core output/sbcl.core --no-userinit --no-sysinit --non-interactive --eval '
    (progn
      (format t \"~&   version: ~a on ~a~%\" (lisp-implementation-version) (machine-type))
      (dolist (f (list :android :sb-thread :sb-linkable-runtime :sb-core-compression
                       :gencgc :soft-card-marks :use-cons-region :gcc-tls))
        (format t \"~&   ~(~a~)~28t~a~%\" f
                (cond ((member f *features*) \"yes\")
                      ((member f sb-impl:+internal-features+) \"yes (internal)\")
                      (t \"no\"))))
      (terpri))'" || {
  echo "The core did not run on the device. That is M1 failing, not a formality." >&2
  exit 1
}

cat <<EOF

== M1 done ==

  core:      $SRC_DIR/output/sbcl.core
  runtime:   $SRC_DIR/src/runtime/sbcl
  library:   $SRC_DIR/src/runtime/libsbcl.so
  on device: /data/local/tmp/sbcl

An SBCL that runs on the phone, and a runtime in the one shape an APK can contain.

Next, for M2, the two things this leaves open:

  1. Whether ":android yes" above came with ":soft-card-marks yes". If so, PLAN.md 7.1
     is much less of a worry.

  2. How the game's core gets loaded. With libsbcl.so as a shared runtime, the simplest
     shape is a plain core file plus initialize_lisp(argc, argv, envp) passing
     "--core <path>", with SAVE-LISP-AND-DIE :TOPLEVEL doing the rest -- no
     callable-exports and no linkable runtime needed. If that works, LINKABLE=1 never
     becomes necessary.
EOF
