#!/usr/bin/env bash
#
# Build the Windows distributable by running a Windows SBCL under Wine.
#
# Not a cross-compile. SBCL cannot target another platform, so the way to get a Windows
# executable is to run a Windows SBCL, and Wine is how that happens on Linux. Everything
# it touches lives under win32/ -- its own prefix, its own Quicklisp -- so this cannot
# disturb whatever Wine setup you already have, and deleting win32/ undoes all of it.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

export WINEPREFIX="$HERE/prefix"
export WINEDEBUG="${WINEDEBUG:--all}"      # Wine is extremely chatty otherwise
# Keep wineboot from reaching for Mono and Gecko while building a fresh prefix. Neither is
# wanted here, and where there is no network the attempt waits on a dialog nobody sees.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"

SBCL_EXE="$HERE/sbcl/sbcl.exe"
QL_DIR="$HERE/quicklisp"

[[ -f "$SBCL_EXE" ]] || { echo "Run win32/setup.sh first." >&2; exit 1; }
[[ -d "$HERE/dll" ]] || { echo "No win32/dll -- run win32/setup.sh first." >&2; exit 1; }

# The prefix has to exist before winepath can translate anything, so this comes first.
if [[ ! -d "$WINEPREFIX" ]]; then
  echo "== creating a Wine prefix in win32/prefix =="
  # 64-bit: SBCL's Windows build is x86-64 and will not load in a 32-bit prefix.
  #
  # Stderr is deliberately kept. It used to go to /dev/null because wineboot is noisy on
  # a prefix that already exists -- but that also swallowed the reason it failed, and
  # under `set -e` the script then died here having printed only the line above. On a
  # machine where the prefix already existed this branch never ran, so the first time it
  # mattered was the first build in a fresh chroot.
  #
  # `|| true` because wineboot's exit status is not a reliable success signal; whether
  # the prefix exists afterwards is.
  WINEARCH=win64 wineboot --init || true

  # wineboot returns as soon as it has forked, so the prefix is still being populated
  # when it does. Everything below wants a finished prefix, and winepath against a
  # half-built one fails in confusing ways.
  wineserver -w || true

  [[ -d "$WINEPREFIX/drive_c" ]] || {
    echo "wineboot did not produce a prefix at $WINEPREFIX" >&2
    exit 1
  }
fi

# A Windows path with forward slashes. SBCL accepts those everywhere and they survive
# being put in a Lisp string, where backslashes would have to be doubled -- and doubling
# them through two layers of shell quoting is how this line goes wrong.
winpath() { winepath -w "$1" | tr '\\' '/'; }

export SBCL_HOME="$(winpath "$HERE/sbcl")"

if [[ ! -f "$QL_DIR/setup.lisp" ]]; then
  echo "== installing Quicklisp for the Windows SBCL =="
  mkdir -p "$QL_DIR"
  curl -fsSL -o "$QL_DIR/quicklisp.lisp" https://beta.quicklisp.org/quicklisp.lisp
  wine "$SBCL_EXE" --non-interactive \
    --load "$(winpath "$QL_DIR/quicklisp.lisp")" \
    --eval "(quicklisp-quickstart:install :path \"$(winpath "$QL_DIR")/\")"
fi

# lgame is not in Quicklisp, so the Windows SBCL has no way to find it. $HOME rather than
# a fixed path so this keeps working in the Debian chroot, where the checkout lives in the
# same place relative to the build user.
LGAME_SRC="${LGAME_SRC:-$HOME/quicklisp/local-projects/lgame}"
LGAME_DST="$QL_DIR/local-projects/lgame"

[[ -d "$LGAME_SRC" ]] || { echo "No lgame checkout at $LGAME_SRC" >&2; exit 1; }

echo "== copying lgame =="
mkdir -p "$QL_DIR/local-projects"
# Every build, not just the first. It is a working checkout, and a stale copy is the kind
# of thing that wastes an afternoon before anyone thinks to suspect it. Linux fasls are
# excluded because they are meaningless to a Windows SBCL.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude='*.fasl' --exclude='.git' "$LGAME_SRC/" "$LGAME_DST/"
else
  rm -rf "$LGAME_DST"
  cp -a "$LGAME_SRC" "$LGAME_DST"
  find "$LGAME_DST" -name '*.fasl' -delete
fi

# The SDL DLLs have to be loadable during the build, not just at runtime: CFFI calls
# LoadLibrary at load time, so compiling lgame opens SDL2.dll then and there.
#
# Windows searches the directory of the running .exe first -- here that is win32/sbcl,
# where sbcl.exe lives -- then system32, then PATH. win32/dll is none of those, so the
# DLLs go beside sbcl.exe. That relies only on the documented loader rule rather than on
# WINEPATH or any other Wine-specific knob, and it mirrors how the shipped game finds
# them: beside its own executable.
echo "== staging DLLs for the build =="
cp -f "$HERE"/dll/*.dll "$HERE/sbcl/"

echo "== building =="
cd "$ROOT"
# --load rather than --script: the build needs Quicklisp loaded first, and --script takes
# exactly one file. --no-sysinit/--no-userinit keep any local init out of a release build.
wine "$SBCL_EXE" \
  --dynamic-space-size 2048 \
  --no-sysinit --no-userinit \
  --load "$(winpath "$QL_DIR/setup.lisp")" \
  --load "$(winpath "$ROOT/build.lisp")" \
  --quit

echo
echo "Built: $ROOT/bin/windows/descendant.exe"
echo "Try it:  WINEPREFIX=$WINEPREFIX wine $ROOT/bin/windows/descendant.exe"
