# arm64 only. The phone is arm64-v8a and nothing else is a goal; building the other three
# ABIs would quadruple the APK to serve devices that will never see it.
APP_ABI := arm64-v8a

# android-21 is SDL's floor and matches the NDK's aarch64-linux-android21-clang.
APP_PLATFORM := android-21

# APP_STL is deliberately not set, which gets the NDK default of "system".
#
# It was "none", on the mistaken belief that SDL2 is all C. It is not:
# src/hidapi/android/hid.cpp is C++, SDL's Android.mk globs it in unconditionally, and it
# needs operator new and delete. With "none" those are unresolved and libSDL2.so does not
# link.
#
# "system" is bionic's minimal C++ support -- new, delete, type_info, and no STL
# containers -- which is all hid.cpp wants and costs nothing extra in the APK. It is also
# what SDL's own android-project expects: its Application.mk leaves APP_STL commented out
# and only suggests c++_shared for projects that use the STL themselves. We do not.

APP_OPTIM := release
APP_CFLAGS += -O2
