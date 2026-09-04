LOCAL_PATH := $(call my-dir)

# The SBCL runtime, as a prebuilt. build.sh copies it here from the cross-build tree when
# DESCENDANT_LISP=1, and ndk-build both links libmain.so against it and installs it into
# libs/arm64-v8a/ alongside everything else.
#
# Guarded so the M0 build -- which has no Lisp in it at all -- does not need the file to
# exist. all-subdir-makefiles picks this up either way.

ifeq ($(DESCENDANT_LISP),1)

include $(CLEAR_VARS)
LOCAL_MODULE := sbcl
LOCAL_SRC_FILES := libsbcl.so
include $(PREBUILT_SHARED_LIBRARY)

endif
