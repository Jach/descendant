#!/usr/bin/env bash
#
# Fetch everything a Windows build needs into win32/, which is gitignored.
#
# Deliberately not in source control. SBCL is forty megabytes and Quicklisp is a moving
# target; a script that fetches them is reproducible, reviewable in a diff, and does not
# make every clone of this repository carry a binary toolchain forever. Run it once, and
# again when you want newer versions.
#
# Nothing here needs Wine. The MSI is unpacked with msitools, which is a Linux program --
# no prefix, no installer, no clicking.
#
#   apt-get install msitools wine64 curl unzip
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The versions are the only thing here likely to need touching. Each can be overridden
# from the environment, and a wrong one fails loudly on the download rather than quietly
# fetching something else:
#
#   SBCL_VERSION=2.6.9 ./win32/setup.sh
#
# The SDL numbers were not verified against the current releases; check them against
# github.com/libsdl-org if a fetch 404s.
SBCL_VERSION="${SBCL_VERSION:-2.6.8}"
SDL2_VERSION="${SDL2_VERSION:-2.32.8}"
SDL2_MIXER_VERSION="${SDL2_MIXER_VERSION:-2.8.2}"
SDL2_IMAGE_VERSION="${SDL2_IMAGE_VERSION:-2.8.12}"
SDL2_TTF_VERSION="${SDL2_TTF_VERSION:-2.24.0}"

DOWNLOADS="$HERE/downloads"
SBCL_DIR="$HERE/sbcl"
DLL_DIR="$HERE/dll"

mkdir -p "$DOWNLOADS" "$SBCL_DIR" "$DLL_DIR"

fetch() {  # fetch URL FILENAME
  if [[ -f "$DOWNLOADS/$2" ]]; then
    echo "have    $2"
  else
    echo "fetch   $2"
    curl -fsSL -o "$DOWNLOADS/$2" "$1"
  fi
}

echo "== SBCL for Windows =="
SBCL_MSI="sbcl-${SBCL_VERSION}-x86-64-windows-binary.msi"
fetch "https://downloads.sourceforge.net/project/sbcl/sbcl/${SBCL_VERSION}/${SBCL_MSI}" \
      "$SBCL_MSI"

STAMP="$SBCL_DIR/.unpacked-$SBCL_VERSION"
if [[ ! -f "$STAMP" ]]; then
  # Take the WHOLE SBCL directory, not just sbcl.exe and sbcl.core. The contribs --
  # sb-bsd-sockets, sb-posix and the rest -- are separate fasls under SBCL_HOME, and
  # REQUIRE has no way to find them if they are left behind. Quicklisp needs
  # sb-bsd-sockets before it can fetch anything, so this fails at the first download
  # with "Don't know how to REQUIRE SB-BSD-SOCKETS", which does not sound like a
  # missing-files problem at all.
  echo "unpack  $SBCL_MSI"
  rm -rf "$SBCL_DIR/raw" "$SBCL_DIR"/.unpacked-*
  mkdir -p "$SBCL_DIR/raw"
  ( cd "$SBCL_DIR/raw" && msiextract "$DOWNLOADS/$SBCL_MSI" >/dev/null )

  # msiextract mirrors the installer's layout, and the directory names have changed
  # between SBCL releases -- so locate the core and take the directory holding it, which
  # is what SBCL_HOME has to point at.
  core="$(find "$SBCL_DIR/raw" -name sbcl.core -print -quit)"
  [[ -n "$core" ]] || { echo "no sbcl.core in the MSI" >&2; exit 1; }
  cp -a "$(dirname "$core")/." "$SBCL_DIR/"

  # sbcl.exe usually sits beside the core, but not in every release.
  if [[ ! -f "$SBCL_DIR/sbcl.exe" ]]; then
    exe="$(find "$SBCL_DIR/raw" -name sbcl.exe -print -quit)"
    [[ -n "$exe" ]] || { echo "no sbcl.exe in the MSI" >&2; exit 1; }
    cp -a "$exe" "$SBCL_DIR/"
  fi

  rm -rf "$SBCL_DIR/raw"
  touch "$STAMP"
fi

echo "        $(find "$SBCL_DIR" -name '*.fasl' | wc -l) contrib fasls"

echo "== SDL runtime DLLs =="
# The runtime archives, not the -devel ones: we want the DLLs a player needs, and the
# codec DLLs SDL2_mixer depends on ship alongside it in the same archive.
# The repository name and the archive name differ by exactly the "2": the archives are
# SDL2_mixer-x.y.z-win32-x64.zip and the repository is libsdl-org/SDL_mixer. Both are
# spelled out rather than derived, because deriving one from the other is the sort of
# cleverness that produces four 404s and no clue which part was wrong.
sdl_zip() {  # sdl_zip REPO ARCHIVE VERSION
  local repo="$1" archive="$2" ver="$3"
  local zip="${archive}-${ver}-win32-x64.zip"
  fetch "https://github.com/libsdl-org/${repo}/releases/download/release-${ver}/${zip}" "$zip"
  unzip -o -j -q "$DOWNLOADS/$zip" '*.dll' -d "$DLL_DIR"
}
sdl_zip SDL        SDL2        "$SDL2_VERSION"
sdl_zip SDL_mixer  SDL2_mixer  "$SDL2_MIXER_VERSION"
sdl_zip SDL_image  SDL2_image  "$SDL2_IMAGE_VERSION"
sdl_zip SDL_ttf    SDL2_ttf    "$SDL2_TTF_VERSION"

# opengl32.dll belongs to Windows and to Wine. Bundling it would replace the user's
# graphics driver with ours, which is the same mistake as shipping libGL on Linux.
#
# The "32" in the name is not a word size -- it is left over from the Win16-to-Win32
# transition, as in kernel32 and user32, and the 64-bit DLL has the same name. Bitness
# comes from which directory it is loaded out of, and Windows picks that per process.
rm -f "$DLL_DIR/opengl32.dll"

echo
echo "SBCL : $SBCL_DIR"
echo "DLLs : $DLL_DIR  ($(ls -1 "$DLL_DIR" | wc -l) files)"
echo
echo "Next: win32/build.sh"
