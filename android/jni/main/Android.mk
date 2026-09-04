LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

# The module MUST be called "main". SDLActivity.getLibraries() returns {"SDL2", "main"}
# by default and dlsyms SDL_main out of the second one. Naming it anything else means
# writing Java to say so; naming it this means writing none.
LOCAL_MODULE := main

LOCAL_C_INCLUDES := $(LOCAL_PATH)/../SDL2/include
LOCAL_SRC_FILES := main.c
LOCAL_SHARED_LIBRARIES := SDL2

# GLESv2, not GLESv3: the probe only calls glClearColor, glClear and glGetString, all of
# which are ES2 entry points, while the CONTEXT it asks SDL for is still ES 3.0. So the
# link stays on the library every NDK has, and GL_VERSION still tells us whether ES 3 was
# granted. The Lisp port reaches GL through cl-opengl's dlopen and links against neither.
LOCAL_LDLIBS := -llog -lGLESv2

# M2 compiles the initialize_lisp path instead of the probe, and links against the SBCL
# runtime declared as a prebuilt in ../sbcl/Android.mk.
ifeq ($(DESCENDANT_LISP),1)
  LOCAL_CFLAGS += -DDESCENDANT_LISP
  LOCAL_SHARED_LIBRARIES += sbcl
endif

include $(BUILD_SHARED_LIBRARY)
