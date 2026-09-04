# Top-level ndk-build makefile.
#
# build.sh assembles a work tree at android/ndk/jni/ containing this file, Application.mk,
# main/, and symlinks to the unpacked SDL sources. all-subdir-makefiles then picks up both
# SDL's own Android.mk and ours, which is how SDL expects to be built and means we carry
# no copy of its build rules.
#
# At M0 only SDL2 is symlinked in. M5 adds SDL2_mixer, SDL2_image and SDL2_ttf, and this
# file needs no change when it does -- the subdirectory appearing is the whole edit.

include $(call all-subdir-makefiles)
