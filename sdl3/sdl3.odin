// Bindings for SDL 3, generated from its headers by tools/gen (the *_generated.odin files) plus the parts written by hand
// here and in sdl3_macros.odin. Names follow vendor:sdl3: SDL_ dropped (SDL_CreateWindow is CreateWindow, SDLK_A is K_A),
// enum members without their prefix (SDL_EVENT_QUIT is EventType.QUIT), flags as bit_sets (WindowFlags{.RESIZABLE}).
package sdl3

@(private)
OS :: "macos" when ODIN_OS == .Darwin else "linux" when ODIN_OS == .Linux else "windows" when ODIN_OS == .Windows else
	#panic("sdl3: unsupported OS")
@(private) ARCH :: "x86_64" when ODIN_ARCH == .amd64 else "arm64" when ODIN_ARCH == .arm64 else #panic("sdl3: unsupported architecture")

// Link the shared library (libSDL3.so, libSDL3.dylib, or SDL3.dll through SDL3.dll.lib) instead of the static one. Enable
// with -define:SDL3_SHARED=true, and ship the library next to the program.
SDL3_SHARED :: #config(SDL3_SHARED, false)

when SDL3_SHARED {
	@(private) FILE :: "SDL3.dll.lib" when ODIN_OS == .Windows else "libSDL3.dylib" when ODIN_OS == .Darwin else "libSDL3.so"
} else {
	@(private) FILE :: "SDL3.lib" when ODIN_OS == .Windows else "libSDL3.a"
}

// Path of the library, relative to this directory. Override with -define:SDL3_LIB=<path>.
SDL3_LIB :: #config(SDL3_LIB, "../lib/" + OS + "-" + ARCH + "/" + FILE)

when !#exists(SDL3_LIB) {
	#panic("Could not find the SDL3 library at '" + SDL3_LIB + "'. Run tools/fetch_sdl3_libs.sh or tools/build_sdl3.sh " +
		"(.ps1 on Windows), or pass -define:SDL3_LIB=<path>.")
}

// @(export) makes the import visible to the whole package, not just this file. A static SDL also needs the system
// libraries it calls directly; everything else (Wayland, X11, PipeWire...) it loads at run time.
when SDL3_SHARED {
	@(export) foreign import lib {SDL3_LIB}
} else when ODIN_OS == .Windows {
	@(export) foreign import lib {
		SDL3_LIB,
		"system:user32.lib", "system:gdi32.lib", "system:winmm.lib", "system:imm32.lib", "system:ole32.lib",
		"system:oleaut32.lib", "system:version.lib", "system:uuid.lib", "system:advapi32.lib", "system:setupapi.lib",
		"system:shell32.lib", "system:cfgmgr32.lib", "system:kernel32.lib",
	}
} else when ODIN_OS == .Darwin {
	@(export) foreign import lib {
		SDL3_LIB,
		"system:Cocoa.framework", "system:IOKit.framework", "system:ForceFeedback.framework", "system:Carbon.framework",
		"system:CoreAudio.framework", "system:AudioToolbox.framework", "system:CoreHaptics.framework",
		"system:GameController.framework", "system:Metal.framework", "system:QuartzCore.framework",
		"system:CoreVideo.framework", "system:CoreFoundation.framework", "system:UniformTypeIdentifiers.framework",
		"system:AVFoundation.framework", "system:CoreMedia.framework",
	}
} else {
	@(export) foreign import lib {SDL3_LIB, "system:m", "system:dl", "system:pthread"}
}

//-------------------//
// INTEGERS (stdinc) //
//-------------------//

Sint8  :: i8
Uint8  :: u8
Sint16 :: i16
Uint16 :: u16
Sint32 :: i32
Uint32 :: u32
Sint64 :: i64
Uint64 :: u64
