# The size-minimized SDL3 of sdl3_odin, as a CMake initial cache: tools/build_sdl3.sh (and .ps1) pass it with -C.
# The linkage (SDL_SHARED, SDL_STATIC) comes from the build script. Releases ship this file, and tools/fetch_sdl3_libs.sh
# refuses libraries built from another one.
#
# Kept: video (Wayland + libdecor, X11, Cocoa, Win32, dummy), OpenGL, OpenGL ES, Vulkan, Metal, audio (PipeWire,
# PulseAudio, ALSA, WASAPI, DirectSound, CoreAudio, dummy), joysticks and gamepads with every driver (HIDAPI, udev, libusb on
# Linux, DirectInput, XInput, RawInput, WGI, IOKit, GameController), haptics, sensors, virtual joysticks, D-Bus and IBus.
# Dropped: the 2D renderer, the GPU API, camera, file dialogs, tray, power, KMSDRM, offscreen, rare audio backends,
# assertions and (on Linux) unwind tables. Every Linux library is dlopen'ed (SDL_DEPS_SHARED).

set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "") # -Os, /O1: the biggest size lever (-1.1 MB against -O3)
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF CACHE BOOL "") # LTO saves 2%, and a gcc LTO archive only links with gcc
set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "") # the static library goes into PIE programs
set(CMAKE_PLATFORM_NO_VERSIONED_SONAME ON CACHE BOOL "") # libSDL3.so, not .so.0: found next to the program, never the system's

if(CMAKE_HOST_WIN32)
	# Setting CMAKE_C_FLAGS replaces CMake's MSVC defaults, so they're repeated here.
	set(CMAKE_C_FLAGS "/DWIN32 /D_WINDOWS /DSDL_LEAN_AND_MEAN=1 /Gw" CACHE STRING "")
	set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded CACHE STRING "") # static CRT, as the official binaries
	set(CMAKE_SHARED_LINKER_FLAGS "/OPT:REF /OPT:ICF /INCREMENTAL:NO" CACHE STRING "")
elseif(CMAKE_HOST_APPLE)
	# Mach-O objects are already split per symbol, so no -ffunction-sections. Unwind tables stay: AppKit can throw
	# Objective-C exceptions through SDL's frames.
	set(CMAKE_C_FLAGS "-DSDL_LEAN_AND_MEAN=1" CACHE STRING "")
	set(CMAKE_SHARED_LINKER_FLAGS "-Wl,-dead_strip" CACHE STRING "")
	set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0 CACHE STRING "")
else()
	set(CMAKE_C_FLAGS "-ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables -fno-unwind-tables -DSDL_LEAN_AND_MEAN=1"
		CACHE STRING "")
	set(CMAKE_SHARED_LINKER_FLAGS "-Wl,--gc-sections -Wl,-O1" CACHE STRING "")
endif()

# BUILD
set(SDL_TESTS OFF CACHE BOOL "")
set(SDL_TEST_LIBRARY OFF CACHE BOOL "")
set(SDL_EXAMPLES OFF CACHE BOOL "")
set(SDL_INSTALL OFF CACHE BOOL "")
set(SDL_ASSERTIONS disabled CACHE STRING "")
set(SDL_DEPS_SHARED ON CACHE BOOL "")
set(SDL_VENDOR_INFO "sdl3_odin" CACHE STRING "")

# SUBSYSTEMS
set(SDL_RENDER OFF CACHE BOOL "") # xgpu renders; also drops every render backend and the software renderer
set(SDL_GPU OFF CACHE BOOL "")
set(SDL_CAMERA OFF CACHE BOOL "")
set(SDL_DIALOG OFF CACHE BOOL "")
set(SDL_TRAY OFF CACHE BOOL "")
set(SDL_POWER OFF CACHE BOOL "")
set(SDL_SENSOR ON CACHE BOOL "") # free on Linux and macOS; gamepad gyros don't need it, system IMUs do
set(SDL_HAPTIC ON CACHE BOOL "")
set(SDL_JOYSTICK ON CACHE BOOL "")
set(SDL_HIDAPI ON CACHE BOOL "")
set(SDL_HIDAPI_JOYSTICK ON CACHE BOOL "")
set(SDL_VIRTUAL_JOYSTICK ON CACHE BOOL "")

# VIDEO
set(SDL_DUMMYVIDEO ON CACHE BOOL "") # headless programs and tests, with SDL_VIDEO_DRIVER=dummy
set(SDL_OFFSCREEN OFF CACHE BOOL "")
set(SDL_KMSDRM OFF CACHE BOOL "")
set(SDL_OPENVR OFF CACHE BOOL "")
set(SDL_OPENGL ON CACHE BOOL "")
set(SDL_OPENGLES ON CACHE BOOL "")
set(SDL_VULKAN ON CACHE BOOL "")
set(SDL_FRIBIDI OFF CACHE BOOL "") # X11 message box text shaping
set(SDL_LIBTHAI OFF CACHE BOOL "")

# AUDIO
set(SDL_DUMMYAUDIO ON CACHE BOOL "") # machines without a sound card, with SDL_AUDIO_DRIVER=dummy
set(SDL_DISKAUDIO OFF CACHE BOOL "")
set(SDL_JACK OFF CACHE BOOL "")
set(SDL_SNDIO OFF CACHE BOOL "")
set(SDL_OSS OFF CACHE BOOL "")

# SYSTEM
set(SDL_LIBURING OFF CACHE BOOL "") # only SDL_AsyncIO uses io_uring
if(CMAKE_HOST_WIN32 OR CMAKE_HOST_APPLE)
	set(SDL_HIDAPI_LIBUSB OFF CACHE BOOL "") # we don't ship a libusb; Linux dlopens the system's
endif()
