// Smoke tests of the libraries in lib/<platform> through the bindings, on SDL's dummy video and audio drivers, so they
// run without a display or a sound card:
//
//	odin test tests                                      # the static library
//	odin test tests -define:SDL3_SHARED=true -out:lib/<platform>/smoke_tests_shared    # the shared one, found next to it
package tests

import "core:strings"
import "core:sync"
import "core:testing"
import sdl "../sdl3"

// SDL's state is global, and the test runner runs tests on several threads.
@(private="file")
sdl_lock: sync.Mutex

@(private="file")
init_dummy :: proc(t: ^testing.T, flags: sdl.InitFlags) -> bool {
	_ = sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "dummy")
	_ = sdl.SetHint(sdl.HINT_AUDIO_DRIVER, "dummy")
	ok := sdl.Init(flags)
	testing.expectf(t, ok, "Failed initializing SDL. Error: %v", sdl.GetError())
	return ok
}

@(test)
version_matches_headers :: proc(t: ^testing.T) {
	sync.guard(&sdl_lock)
	// The library is the release the headers (and so the bindings) come from.
	testing.expect_value(t, sdl.GetVersion(), sdl.VERSION)
	testing.expect_value(t, sdl.VERSIONNUM_MAJOR(sdl.VERSION), 3)
	testing.expect(t, strings.contains(string(sdl.GetRevision()), "release-"), "a release build")
}

@(test)
drivers_are_compiled_in :: proc(t: ^testing.T) {
	sync.guard(&sdl_lock)
	video, audio: [dynamic]string
	defer delete(video)
	defer delete(audio)
	for i in 0 ..< sdl.GetNumVideoDrivers() {
		append(&video, string(sdl.GetVideoDriver(i)))
	}
	for i in 0 ..< sdl.GetNumAudioDrivers() {
		append(&audio, string(sdl.GetAudioDriver(i)))
	}
	expected_video := []string{"dummy"}
	expected_audio := []string{"dummy"}
	when ODIN_OS == .Linux {
		expected_video = {"wayland", "x11", "dummy"}
		expected_audio = {"pipewire", "pulseaudio", "alsa", "dummy"}
	} else when ODIN_OS == .Windows {
		expected_video = {"windows", "dummy"}
		expected_audio = {"wasapi", "dummy"}
	} else when ODIN_OS == .Darwin {
		expected_video = {"cocoa", "dummy"}
		expected_audio = {"coreaudio", "dummy"}
	}
	for name in expected_video {
		testing.expectf(t, contains(video[:], name), "video driver %s is missing from %v", name, video[:])
	}
	for name in expected_audio {
		testing.expectf(t, contains(audio[:], name), "audio driver %s is missing from %v", name, audio[:])
	}
	// The minimized build has neither of these.
	testing.expect(t, !contains(video[:], "offscreen") && !contains(video[:], "kmsdrm"), "offscreen and kmsdrm are off")
	testing.expect(t, !contains(audio[:], "disk"), "disk audio is off")
}

@(private="file")
contains :: proc(names: []string, name: string) -> bool {
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}

@(test)
window_on_dummy_driver :: proc(t: ^testing.T) {
	sync.guard(&sdl_lock)
	if !init_dummy(t, {.VIDEO, .EVENTS}) {
		return
	}
	defer sdl.Quit()
	testing.expect_value(t, string(sdl.GetCurrentVideoDriver()), "dummy")

	window := sdl.CreateWindow("smoke", 320, 200, {.HIDDEN, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	if !testing.expectf(t, window != nil, "Failed creating a window. Error: %v", sdl.GetError()) {
		return
	}
	defer sdl.DestroyWindow(window)

	testing.expect(t, sdl.GetWindowProperties(window) != 0, "the window has properties")
	testing.expect(t, .RESIZABLE in sdl.GetWindowFlags(window), "the flags round trip")
	w, h: i32
	testing.expect(t, sdl.GetWindowSize(window, &w, &h), "window size")
	testing.expect_value(t, w, 320)
	testing.expect_value(t, h, 200)
	testing.expect(t, sdl.SetWindowTitle(window, "renamed"), "set title")
	testing.expect_value(t, string(sdl.GetWindowTitle(window)), "renamed")

	// A user event goes through the queue and comes back whole.
	user_type := sdl.RegisterEvents(1)
	pushed := sdl.Event{user = {type = sdl.EventType(user_type), code = 42}}
	testing.expect(t, sdl.PushEvent(&pushed), "push an event")
	found := false
	event: sdl.Event
	for sdl.PollEvent(&event) {
		if u32(event.type) == user_type {
			found = event.user.code == 42
		}
	}
	testing.expect(t, found, "the user event comes back")
}

@(test)
virtual_gamepad :: proc(t: ^testing.T) {
	sync.guard(&sdl_lock)
	if !init_dummy(t, {.GAMEPAD}) {
		return
	}
	defer sdl.Quit()

	desc: sdl.VirtualJoystickDesc
	sdl.INIT_INTERFACE(&desc)
	desc.type = Uint16(sdl.JoystickType.GAMEPAD)
	desc.naxes = u16(len(sdl.GamepadAxis)) - 1 // without INVALID
	desc.nbuttons = u16(len(sdl.GamepadButton)) - 1 // without INVALID
	desc.name = "sdl3_odin virtual pad"
	id := sdl.AttachVirtualJoystick(desc)
	if !testing.expectf(t, id != 0, "Failed attaching a virtual joystick. Error: %v", sdl.GetError()) {
		return
	}
	defer _ = sdl.DetachVirtualJoystick(id)
	testing.expect(t, sdl.IsGamepad(id), "a virtual gamepad is a gamepad")

	gamepad := sdl.OpenGamepad(id)
	if !testing.expectf(t, gamepad != nil, "Failed opening the gamepad. Error: %v", sdl.GetError()) {
		return
	}
	defer sdl.CloseGamepad(gamepad)
	testing.expect_value(t, string(sdl.GetGamepadName(gamepad)), "sdl3_odin virtual pad")

	joystick := sdl.GetGamepadJoystick(gamepad)
	testing.expect(t, sdl.SetJoystickVirtualButton(joystick, c_int(sdl.GamepadButton.SOUTH), true), "press south")
	testing.expect(t, sdl.SetJoystickVirtualAxis(joystick, c_int(sdl.GamepadAxis.LEFTX), 12345), "move the left stick")
	sdl.UpdateGamepads()
	testing.expect(t, sdl.GetGamepadButton(gamepad, .SOUTH), "south is down")
	testing.expect(t, !sdl.GetGamepadButton(gamepad, .EAST), "east is up")
	testing.expect_value(t, sdl.GetGamepadAxis(gamepad, .LEFTX), 12345)
}

Uint16 :: sdl.Uint16
c_int :: i32

@(test)
audio_stream_on_dummy_driver :: proc(t: ^testing.T) {
	sync.guard(&sdl_lock)
	if !init_dummy(t, {.AUDIO}) {
		return
	}
	defer sdl.Quit()
	testing.expect_value(t, string(sdl.GetCurrentAudioDriver()), "dummy")

	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = 48000}
	stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if !testing.expectf(t, stream != nil, "Failed opening an audio stream. Error: %v", sdl.GetError()) {
		return
	}
	defer sdl.DestroyAudioStream(stream)
	samples: [256]f32
	testing.expect(t, sdl.PutAudioStreamData(stream, raw_data(samples[:]), size_of(samples)), "queue audio")
	testing.expect(t, sdl.GetAudioStreamQueued(stream) > 0, "the audio is queued")
}

@(test)
event_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(sdl.Event), 128)
	testing.expect_value(t, offset_of(sdl.KeyboardEvent, scancode), 24)
}
