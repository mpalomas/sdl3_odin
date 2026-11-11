# sdl3_odin

[SDL 3](https://libsdl.org) for Odin: bindings generated from SDL's headers, and SDL built for size, as static and shared libraries for Linux (x86-64), macOS (arm64) and Windows (x86-64).

Current version: SDL 3.4.20.

## What is built

Everything a game needs from SDL, and nothing it renders with, since rendering is someone else's job here (WebGPU, Vulkan, OpenGL):

- **Kept:** video (Wayland with libdecor, X11, Cocoa, Win32, and the dummy driver for headless programs and tests), OpenGL, OpenGL ES, Vulkan and Metal surfaces, audio (PipeWire, PulseAudio, ALSA, WASAPI, DirectSound, CoreAudio, dummy), joysticks and gamepads with every driver SDL has (HIDAPI's PlayStation, Switch, Xbox, Steam, 8BitDo... drivers, udev and libusb on Linux, DirectInput, XInput, RawInput and Windows.Gaming.Input, IOKit and GameController), haptics, sensors, virtual joysticks, IME through D-Bus (IBus, Fcitx).
- **Dropped:** the 2D renderer (and the software renderer), the GPU API, camera, file dialogs, tray, power, KMSDRM, offscreen video, JACK, sndio, OSS and disk audio, assertions, and on Linux unwind tables. `SDL_LEAN_AND_MEAN` drops the optimized surface blitters, RLE and YUV.
- On Linux every system library (Wayland, X11, PipeWire, PulseAudio, ALSA, udev, D-Bus, libusb, libdecor) is loaded at run time: the library needs only libc and libm, and a program starts on a machine without them.

The options are in [upstream/sdl3_options.cmake](upstream/sdl3_options.cmake). Measured on Linux x86-64, stripped: SDL's default build is 4.3 MB, this one 1.4 MB.

| Variant (Linux x86-64) | `libSDL3.so` |
|---|---|
| SDL's defaults, Release | 4,297,240 |
| These options | 1,395,704 |

A static SDL adds about as much to a program as the shared library weighs: SDL's dynamic API table refers to every function, so the linker can't drop unused ones. It's also what lets `SDL3_DYNAMIC_API=/path/libSDL3.so` swap in another SDL at run time, static or not.

## Layout

| Where | What |
|---|---|
| `sdl3/` | package `sdl3`: the bindings (`*_generated.odin`), and by hand the library selection (`sdl3.odin`) and SDL's function-like macros and inline functions (`sdl3_macros.odin`) |
| `lib/<os>-<arch>/` | the libraries, built or downloaded (git ignores them) |
| `upstream/` | the pinned release (`release.env`), its headers (`include/SDL3`), the API dumped from them (`sdl3_api.json`), the build options and what each OS's build must have (`sdl3_expected_<os>.txt`), SDL's license |
| `tools/` | `build_sdl3.sh`, `dump/` (the API dump from clang), `gen/` (the binding generator and its `overrides.txt`), `abi/` (the ABI check), `compare_vendor/` (the comparison with vendor:sdl3) |
| `tests/` | smoke tests on the dummy drivers |

## Using the bindings

Point a collection at this repository:

```sh
odin run my_game -collection:sdl3=path/to/sdl3_odin
```

```odin
import sdl "sdl3:sdl3"

sdl.Init({.VIDEO, .GAMEPAD})
window := sdl.CreateWindow("Hello", 1280, 720, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
```

Build options:

- `-define:SDL3_SHARED=true` links `libSDL3.so`, `libSDL3.dylib` or `SDL3.dll` instead of the static library. Ship it next to the program (Odin sets the rpath to the program's directory).
- `-define:SDL3_LIB=<path>` links another library, relative to `sdl3/`.

## Conventions

The names are [vendor:sdl3](https://github.com/odin-lang/Odin/tree/master/vendor/sdl3)'s, so code written for it builds against these bindings with a different import: `SDL_` dropped (`SDL_CreateWindow` is `CreateWindow`, `SDLK_A` is `K_A`), enum members without their prefix (`EventType.QUIT`), flags as bit_sets (`WindowFlags{.RESIZABLE}`), arrays as `[^]T`, nullable pointers as `Maybe(^T)`, events taking in `CommonEvent` with `using`. Where vendor:sdl3 is wrong, these aren't: it has 13 signatures that don't match the C functions (`PeepEvents` and the atomics returning a 64-bit `int`, `GetJoystickPowerInfo` taking `percent` by value, `GetTrayMenu` returning a struct...) and a `MessageBoxColorScheme` one color too long. Android, iOS and GDK functions aren't bound.

## Prebuilt libraries

```sh
tools/fetch_sdl3_libs.sh            # this machine's platform; or name them: linux-x86_64 macos-arm64 windows-x86_64
tools/fetch_sdl3_libs.ps1           # the same in PowerShell
```

They download the release pinned in `upstream/release.env` (`RELEASE_TAG`), check it against its `SHA256SUMS`, and refuse it if it was built from another SDL or other options than the committed ones. `.github/workflows/build-sdl3.yml` builds the releases: Linux on Ubuntu 22.04 (glibc 2.35), macOS 13+, Windows with Visual Studio 2026 and the static C runtime.

## Building

On Linux and macOS, with CMake, Ninja and a C compiler, plus on Linux the dev packages of the libraries SDL loads (`tools/install_build_deps.sh` installs them on Debian and Ubuntu; on Arch: `wayland wayland-protocols libdecor libx11 libxext libxcursor libxi libxfixes libxrandr libxss libxtst pipewire libpulse alsa-lib systemd-libs dbus ibus libusb libxkbcommon mesa`):

```sh
tools/build_sdl3.sh            # static and shared, into lib/<os>-<arch>
```

On Windows, with CMake and Visual Studio (2026, or any recent one):

```powershell
tools/build_sdl3.ps1
```

They download SDL's release tarball into `build/`, check it against `upstream/release.env`, apply `upstream/patches/*.patch` if there are any, and check that the configured build has everything `upstream/sdl3_expected_<os>.txt` lists: CMake turns a feature off when its dev package is missing, without failing.

## Updating SDL

1. Put the new version and its tarball's SHA256 in `upstream/release.env`, and its `include/SDL3` in `upstream/include`.
2. `tools/build_sdl3.sh`
3. `odin run tools/dump` (needs clang) rewrites `upstream/sdl3_api.json`.
4. `odin run tools/gen -- upstream/sdl3_api.json tools/gen/overrides.txt sdl3 tools/abi` regenerates the bindings and the ABI check. It fails on overrides that match nothing and on names that collide.
5. `tools/abi/check.sh`, `odin test tests`, `odin test tools/gen`, and `odin run tools/compare_vendor` to see what changed against vendor:sdl3.

## Tests

- `odin test tests` (and with `-define:SDL3_SHARED=true -out:lib/<platform>/smoke_tests_shared`): the library is the release the headers come from, the drivers that must be compiled in are, and a window, a virtual gamepad and an audio stream work on the dummy drivers.
- `tools/abi/check.sh`: every record's size, alignment and field offsets, every enum constant and every macro's value, from C and from the bindings (3,248 values).
- `odin test tools/gen`: the committed bindings are what the generator makes of the committed dump and overrides.

## License

MIT, see [LICENSE](LICENSE). SDL is under the zlib license, in [upstream/LICENSE.txt](upstream/LICENSE.txt) and next to the libraries.
