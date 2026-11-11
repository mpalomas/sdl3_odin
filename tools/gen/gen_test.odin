package main

import "core:os"
import "core:strings"
import "core:testing"

REPO :: #directory + "../../"

// The committed bindings and ABI programs are what tools/gen makes of the committed API dump and overrides.
@(test)
generated_files_are_current :: proc(t: ^testing.T) {
	api, api_err := os.read_entire_file(REPO + "upstream/sdl3_api.json", context.allocator)
	overrides, overrides_err := os.read_entire_file(REPO + "tools/gen/overrides.txt", context.allocator)
	if !testing.expect(t, api_err == nil && overrides_err == nil, "read the API dump and the overrides") {
		return
	}
	files, abi_c, abi_odin, err := generate(string(api), string(overrides))
	if !testing.expectf(t, err == "", "generate: %s", err) {
		return
	}
	expect_file :: proc(t: ^testing.T, path, want: string) {
		have, have_err := os.read_entire_file(path, context.allocator)
		testing.expectf(t, have_err == nil && string(have) == want, "%s is stale: run tools/gen (see the README)", path)
	}
	for file in files {
		expect_file(t, strings.concatenate({REPO + "sdl3/", file.name}), file.text)
	}
	expect_file(t, REPO + "tools/abi/abi_check.c", abi_c)
	expect_file(t, REPO + "tools/abi/odin/main.odin", abi_odin)
}

@(test)
upper_snake_splits_words :: proc(t: ^testing.T) {
	testing.expect_value(t, upper_snake("GamepadButton"), "GAMEPAD_BUTTON")
	testing.expect_value(t, upper_snake("GPUTextureType"), "GPU_TEXTURE_TYPE")
	testing.expect_value(t, upper_snake("HIDBusType"), "HID_BUS_TYPE")
}

@(test)
enum_prefix_strips_the_shared_part :: proc(t: ^testing.T) {
	testing.expect_value(t, enum_prefix("SDL_GamepadButton", {"SDL_GAMEPAD_BUTTON_SOUTH", "SDL_GAMEPAD_BUTTON_EAST"}), "SDL_GAMEPAD_BUTTON_")
	testing.expect_value(t, enum_prefix("SDL_EventType", {"SDL_EVENT_QUIT", "SDL_EVENT_KEY_DOWN"}), "SDL_EVENT_")
}
