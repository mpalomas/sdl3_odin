// Generates the Odin bindings of SDL3 from upstream/sdl3_api.json (written by tools/dump_api.py) and tools/gen/overrides.txt:
// one sdl3/<header>_generated.odin per SDL header. The rest of package sdl3 is written by hand.
//
// Usage: odin run tools/gen -- <sdl3_api.json> <overrides.txt> <output dir> [<abi dir>]
//   With an abi dir, also writes <abi dir>/abi_check.c and <abi dir>/odin/main.odin, run by tools/abi/check.sh.
package main

import vmem "core:mem/virtual"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

main :: proc() {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	if len(os.args) != 4 && len(os.args) != 5 {
		fmt.eprintln("usage: gen <sdl3_api.json> <overrides.txt> <output dir> [<abi dir>]")
		os.exit(2)
	}
	api_path, overrides_path, out_dir := os.args[1], os.args[2], os.args[3]

	files, abi_c, abi_odin, err := generate(read(api_path), read(overrides_path))
	if err != "" {
		fmt.eprintfln("gen: %s", err)
		os.exit(1)
	}

	// Write the files, and delete generated files of headers that no longer have anything to bind.
	keep: [dynamic]string
	for file in files {
		path, _ := filepath.join({out_dir, file.name})
		write(path, file.text)
		append(&keep, file.name)
	}
	entries, list_err := os.read_all_directory_by_path(out_dir, context.allocator)
	if list_err != nil {
		fmt.eprintfln("gen: cannot list %s: %v", out_dir, list_err)
		os.exit(1)
	}
	for entry in entries {
		if strings.has_suffix(entry.name, "_generated.odin") && !slice.contains(keep[:], entry.name) {
			_ = os.remove(entry.fullpath)
		}
	}
	if len(os.args) == 5 {
		abi_dir := os.args[4]
		c_path, _ := filepath.join({abi_dir, "abi_check.c"})
		odin_path, _ := filepath.join({abi_dir, "odin", "main.odin"})
		write(c_path, abi_c)
		write(odin_path, abi_odin)
	}
	fmt.printfln("gen: %d files in %s", len(files), out_dir)
}

Generated_File :: struct {
	name: string,
	text: string,
}

// generate returns the generated files, or a description of what went wrong.
generate :: proc(api_json, overrides_text: string) -> (files: []Generated_File, abi_c, abi_odin: string, err: string) {
	api, api_err := load_api(transmute([]u8)api_json)
	if api_err != "" {
		return nil, "", "", api_err
	}
	overrides, overrides_err := parse_overrides(overrides_text)
	if overrides_err != "" {
		return nil, "", "", overrides_err
	}

	e := Emitter{api = &api, overrides = &overrides}
	for &header in api.headers {
		for &decl in header.decls {
			#partial switch decl.kind {
			case .Typedef:
				e.typedefs[decl.name] = &decl
			case .Struct, .Union:
				e.records[decl.name] = &decl
			case .Opaque:
				if decl.name not_in e.records {
					e.records[decl.name] = &decl
				}
			case .Enum:
				e.enums[decl.name] = &decl
			}
		}
	}

	out: [dynamic]Generated_File
	for &header in api.headers {
		text := emit_header(&e, &header)
		if text == "" {
			continue
		}
		base := strings.trim_suffix(strings.trim_prefix(header.name, "SDL_"), ".h")
		append(&out, Generated_File{fmt.aprintf("%s_generated.odin", base), text})
	}

	abi_c, abi_odin = emit_abi_check(&e)

	// Overrides that matched nothing are mistakes, or leftovers of an older SDL.
	unused := overrides_unused(&overrides)
	for line in unused {
		append(&e.errors, fmt.aprintf("override %q matches nothing", line))
	}
	if len(e.errors) > 0 {
		return nil, "", "", strings.join(e.errors[:], "\n")
	}
	return out[:], abi_c, abi_odin, ""
}

overrides_unused :: proc(overrides: ^Overrides) -> []string {
	unused: [dynamic]string
	check :: proc(unused: ^[dynamic]string, used: map[string]bool, directive: string, keys: []string) {
		for key in keys {
			line := fmt.aprintf("%s %s", directive, key)
			if line not_in used {
				append(unused, line)
			}
		}
	}
	keys :: proc(m: map[string]$T) -> []string {
		out, _ := slice.map_keys(m)
		slice.sort(out)
		return out
	}
	check(&unused, overrides.used, "type", keys(overrides.types))
	check(&unused, overrides.used, "param", keys(overrides.params))
	check(&unused, overrides.used, "byptr", keys(overrides.byptr))
	check(&unused, overrides.used, "field", keys(overrides.fields))
	check(&unused, overrides.used, "tag", keys(overrides.tags))
	check(&unused, overrides.used, "enum", keys(overrides.enums))
	check(&unused, overrides.used, "flags", keys(overrides.flags))
	check(&unused, overrides.used, "name", keys(overrides.names))
	check(&unused, overrides.used, "member", keys(overrides.members))
	check(&unused, overrides.used, "aliases", keys(overrides.aliases))
	check(&unused, overrides.used, "skip", keys(overrides.skips))
	return unused[:]
}

read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("gen: cannot read %s: %v", path, err)
		os.exit(1)
	}
	return string(data)
}

write :: proc(path, data: string) {
	if err := os.write_entire_file(path, transmute([]u8)data); err != nil {
		fmt.eprintfln("gen: cannot write %s: %v", path, err)
		os.exit(1)
	}
}
