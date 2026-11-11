// Dumps SDL3's C API into upstream/sdl3_api.json, the input of tools/gen.
//
//	odin run tools/dump -- [--sdl-source build/SDL3-<version>] [--out upstream/sdl3_api.json]
//
// Needs clang, and SDL's source tree for its list of exports (src/dynapi/SDL_dynapi_procs.h); tools/build_sdl3.sh extracts
// it into build/. Run it after updating upstream/include; tools/gen doesn't need clang.
//
// What it does:
//   - parses upstream/include/SDL3 with clang's JSON AST dump, three times: as on Linux, and with the defines of Windows and
//     macOS, since some declarations only exist there (clang can't use Windows' system headers here, so a stub stands in
//     for them). Functions, records (with their anonymous members), enums (with every value computed) and typedefs, each
//     with its header and line, and C type strings parsed into a type tree.
//   - scans the headers for #define lines and evaluates the object-like macros that are constants by compiling and running
//     a small C program, with each platform's defines. Function-like macros are listed, for tools/gen to check that each
//     one is written by hand or ignored.
//   - records the SDL_PLATFORM_* conditions around each declaration.
//   - checks that every exported function (SDL_dynapi_procs.h) is there.
package main

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

REPO_DIR :: #directory + "../../"

// The headers the AST is read from. SDL.h includes all the others but these.
TRANSLATION_UNIT :: "#define SDL_MAIN_HANDLED 1\n#include <SDL3/SDL.h>\n#include <SDL3/SDL_main.h>\n#include <SDL3/SDL_vulkan.h>\n"

// Clang runs on this machine, as Linux; the other platforms are SDL's platform defines on top.
Variant :: struct {
	name:    string,
	defines: []string,
}

VARIANTS := []Variant{
	{"linux", {}},
	{"windows", {"-DSDL_PLATFORM_WINDOWS", "-DSDL_PLATFORM_WIN32"}},
	{"macos", {"-DSDL_PLATFORM_APPLE", "-DSDL_PLATFORM_MACOS"}},
}

repo_dir, include_dir, work_dir: string

main :: proc() {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	repo_dir, _ = filepath.clean(REPO_DIR)
	include_dir, _ = filepath.join({repo_dir, "upstream", "include"})
	include_sdl3_dir, _ = filepath.join({include_dir, "SDL3"})
	work_dir, _ = filepath.join({repo_dir, "build", "dump"})

	out_path, _ := filepath.join({repo_dir, "upstream", "sdl3_api.json"})
	out_name := "upstream/sdl3_api.json"
	sdl_source := ""
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--sdl-source", "--out":
			if i + 1 >= len(os.args) {
				die("%s needs a path", os.args[i])
			}
			if os.args[i] == "--out" {
				out_path, out_name = os.args[i + 1], os.args[i + 1]
			} else {
				sdl_source = os.args[i + 1]
			}
			i += 1
		case:
			fmt.eprintln("usage: odin run tools/dump -- [--sdl-source <SDL source tree>] [--out <json>]")
			os.exit(2)
		}
	}

	version := release_env("SDL_VERSION")
	if sdl_source == "" {
		sdl_source, _ = filepath.join({repo_dir, "build", strings.concatenate({"SDL3-", version})})
	}
	dynapi, _ := filepath.join({sdl_source, "src", "dynapi", "SDL_dynapi_procs.h"})
	if !os.exists(dynapi) {
		die("%s is missing: run tools/build_sdl3.sh first, or pass --sdl-source", dynapi)
	}

	stub, _ := filepath.join({work_dir, "stub"})
	if err := os.make_directory_all(stub); err != nil && err != .Exist {
		die("cannot create %s: %v", stub, err)
	}
	process_h, _ := filepath.join({stub, "process.h"})
	write_text(process_h, "/* stands in for the Windows header SDL_thread.h includes */\n")
	unit, _ := filepath.join({work_dir, "api.c"})
	write_text(unit, TRANSLATION_UNIT)

	// DECLARATIONS
	per_variant := make([]Decls, len(VARIANTS))
	for variant, v in VARIANTS {
		per_variant[v] = dump_variant(variant, stub, unit)
	}
	merged: Decls
	for variant, v in VARIANTS {
		for key, i in per_variant[v].keys {
			decl := per_variant[v].values[i]
			index, known := merged.index[key]
			if !known {
				copied := copy_object(decl)
				set(&copied, "platforms", Json_Array{})
				index = decls_put(&merged, key, copied)
			}
			target := &merged.values[index]
			if decl_body(decl) != decl_body(target^) {
				variants_value, has_variants := get(target^, "variants")
				variants := variants_value.(Json_Object) if has_variants else Json_Object{}
				set(&variants, variant.name, decl)
				set(target, "variants", variants)
			}
			platforms, _ := get(target^, "platforms")
			list := platforms.(Json_Array)
			append(&list, variant.name)
			set(target, "platforms", list)
		}
	}

	// HEADERS
	entries, list_err := os.read_all_directory_by_path(include_sdl3_dir, context.allocator)
	if list_err != nil {
		die("cannot list %s: %v", include_sdl3_dir, list_err)
	}
	headers: [dynamic]string
	for entry in entries {
		if strings.has_suffix(entry.name, ".h") && !is_skipped_header(entry.name) {
			append(&headers, strings.clone(entry.name))
		}
	}
	slice.sort(headers[:])
	scans: map[string]Header_Scan
	for h in headers {
		path, _ := filepath.join({include_sdl3_dir, h})
		scans[h] = scan_header(path)
	}
	for &decl in merged.values {
		scan := scans[get_string(decl, "header")]
		set(&decl, "guard", scan.conditions[get_int(decl, "line")] or_else "")
	}

	// MACROS
	Candidate :: struct {
		macro:  Macro,
		header: string,
	}
	candidates: [dynamic]Candidate
	seen: map[string]bool
	for h in headers {
		for macro in macro_candidates(scans[h].macros[:]) {
			if !seen[macro.name] {
				seen[macro.name] = true
				append(&candidates, Candidate{macro, h})
			}
		}
	}
	names := make([]string, len(candidates))
	for candidate, i in candidates {
		names[i] = candidate.macro.name
	}
	slice.sort(names)
	values := make([]map[string]Macro_Value, len(VARIANTS))
	for variant, v in VARIANTS {
		values[v] = evaluate_macros(names, variant.defines)
	}
	macros: [dynamic]Json_Object
	for candidate in candidates {
		name := candidate.macro.name
		present: [dynamic]int // indexes into VARIANTS
		for _, v in VARIANTS {
			if name in values[v] {
				append(&present, v)
			}
		}
		if len(present) == 0 {
			continue
		}
		first := values[present[0]][name]
		platforms: [dynamic]string
		for v in present {
			append(&platforms, VARIANTS[v].name)
		}
		slice.sort(platforms[:])
		platform_list: Json_Array
		for p in platforms {
			append(&platform_list, p)
		}
		entry := object("name", name, "header", candidate.header, "line", candidate.macro.line, "kind", "macro", "body",
			candidate.macro.body, "guard", candidate.macro.guard, "ctype", first.kind, "value", first.value, "platforms",
			platform_list)
		differs := false
		for v in present {
			differs = differs || values[v][name] != first
		}
		if differs {
			variants: Json_Object
			for v in present {
				value := values[v][name]
				set(&variants, VARIANTS[v].name, object("kind", value.kind, "value", value.value))
			}
			set(&entry, "variants", variants)
		}
		append(&macros, entry)
	}
	function_macros: Json_Array
	for h in headers {
		for macro in scans[h].macros {
			if macro.has_params && is_sdl_name(macro.name) {
				append(&function_macros, object("name", macro.name, "header", h, "line", macro.line, "params", macro.params,
					"body", macro.body))
			}
		}
	}

	// CHECK
	exports := dynapi_exports(read_text(dynapi))
	missing: [dynamic]string
	for name in exports {
		if (Decl_Key{"function", name}) not_in merged.index && !is_mobile_entry_point(name) {
			append(&missing, name)
		}
	}
	if len(missing) > 0 {
		slice.sort(missing[:])
		die("exported functions missing from the dump: %s", strings.join(missing[:], ", "))
	}
	for &decl in merged.values {
		if get_string(decl, "kind") == "function" && !get_bool(decl, "inline") {
			set(&decl, "exported", get_string(decl, "name") in exports)
		}
	}

	// OUTPUT
	ordered: [dynamic]Json_Object
	append(&ordered, ..merged.values[:])
	append(&ordered, ..macros[:])
	slice.stable_sort_by(ordered[:], proc(a, b: Json_Object) -> bool {
		ha, hb := get_string(a, "header"), get_string(b, "header")
		if ha != hb {
			return ha < hb
		}
		la, lb := get_int(a, "line"), get_int(b, "line")
		if la != lb {
			return la < lb
		}
		return get_string(a, "kind") == "macro" && get_string(b, "kind") != "macro"
	})
	header_list: Json_Array
	for h in headers {
		decls: Json_Array
		for decl in ordered {
			if get_string(decl, "header") == h {
				append(&decls, decl)
			}
		}
		append(&header_list, object("name", h, "decls", decls))
	}
	output := object("sdl_version", version, "headers", header_list, "function_macros", function_macros)
	b := strings.builder_make()
	write_json(&b, output)
	strings.write_byte(&b, '\n')
	write_text(out_path, strings.to_string(b))

	counts: map[string]int
	for decl in ordered {
		counts[get_string(decl, "kind")] += 1
	}
	kinds, _ := slice.map_keys(counts)
	slice.sort(kinds)
	parts: [dynamic]string
	for kind in kinds {
		append(&parts, fmt.aprintf("%d %s", counts[kind], kind))
	}
	fmt.printfln("dump: %s: %s, %d function-like macros", out_name, strings.join(parts[:], ", "), len(function_macros))
}

//--------------//
// DECLARATIONS //
//--------------//

Decl_Key :: struct {
	kind: string, // "struct" for opaque records too
	name: string,
}

// Decls keeps declarations by key in the order they first came, like a Python dict.
Decls :: struct {
	keys:   [dynamic]Decl_Key,
	values: [dynamic]Json_Object,
	index:  map[Decl_Key]int,
}

decls_put :: proc(d: ^Decls, key: Decl_Key, value: Json_Object) -> int {
	if index, ok := d.index[key]; ok {
		d.values[index] = value
		return index
	}
	append(&d.keys, key)
	append(&d.values, value)
	d.index[key] = len(d.keys) - 1
	return len(d.keys) - 1
}

// dump_variant runs clang's AST dump with a platform's defines and converts its declarations.
@(private="file")
dump_variant :: proc(variant: Variant, stub, unit: string) -> Decls {
	command: [dynamic]string
	append(&command, "clang", "-fsyntax-only", "-fparse-all-comments", "-I", include_dir, "-I", stub)
	append(&command, ..variant.defines)
	append(&command, "-Xclang", "-ast-dump=json", "-Xclang", "-ast-dump-filter=SDL_", unit)
	state, stdout, stderr := run(command[:])
	if state.exit_code != 0 {
		die("clang failed for %s:\n%s", variant.name, string(stderr[:min(len(stderr), 3000)]))
	}
	ast_path, _ := filepath.join({work_dir, fmt.tprintf("ast_%s.json", variant.name)})
	write_text(ast_path, string(stdout))

	locations: Locations
	converter := Converter{locations = &locations, include_sdl3 = include_sdl3_dir}
	decls: Decls
	parse_arena: vmem.Arena
	defer vmem.arena_destroy(&parse_arena)
	pos := 0
	for {
		data, next, ok := next_object(stdout, pos)
		if !ok {
			break
		}
		pos = next
		value, parse_err := json.parse(data, parse_integers = true, allocator = vmem.arena_allocator(&parse_arena))
		if parse_err != nil {
			die("cannot parse clang's AST for %s: %v", variant.name, parse_err)
		}
		node := value.(json.Object)
		track_locations(&locations, node)
		if decl, decl_ok := convert(&converter, node); decl_ok {
			kind := get_string(decl, "kind")
			key := Decl_Key{"struct" if kind == "opaque" else kind, get_string(decl, "name")}
			// A complete record wins over its forward declaration, and the first of the same kind otherwise.
			if index, known := decls.index[key]; known && get_string(decls.values[index], "kind") != "opaque" {
				vmem.arena_free_all(&parse_arena)
				continue
			}
			decls_put(&decls, key, decl)
		}
		vmem.arena_free_all(&parse_arena)
	}
	return decls
}

// decl_body is a declaration without what may differ between platforms' dumps of the same one, as text to compare.
@(private="file")
decl_body :: proc(decl: Json_Object) -> string {
	body: Json_Object
	for pair in decl {
		switch pair.key {
		case "line", "platforms", "variants", "guard":
		case:
			append(&body, pair)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	write_json(&b, body)
	return strings.to_string(b)
}

// dynapi_exports reads the function names of SDL_DYNAPI_PROC(<return type>,<name>,...) lines.
@(private="file")
dynapi_exports :: proc(text: string) -> map[string]bool {
	exports: map[string]bool
	for line in strings.split_lines(text) {
		if !strings.has_prefix(line, "SDL_DYNAPI_PROC(") {
			continue
		}
		rest := line[len("SDL_DYNAPI_PROC("):]
		comma := strings.index_byte(rest, ',')
		if comma < 0 {
			continue
		}
		rest = rest[comma + 1:]
		end := 0
		for end < len(rest) && is_identifier_byte(rest[end]) {
			end += 1
		}
		if strings.has_prefix(rest, "SDL_") && end > len("SDL_") && end < len(rest) && rest[end] == ',' {
			exports[strings.clone(rest[:end])] = true
		}
	}
	return exports
}

// is_mobile_entry_point: mobile, console and app-callback entry points aren't in desktop headers' active branches.
@(private="file")
is_mobile_entry_point :: proc(name: string) -> bool {
	rest := strings.trim_prefix(name, "SDL_")
	return strings.contains(rest, "Android") || strings.contains(rest, "iOS") || strings.has_prefix(rest, "GDK") ||
	       strings.has_prefix(rest, "GetGDK") || rest == "IsChromebook" || rest == "IsDeXMode" ||
	       strings.has_prefix(rest, "OnApplication")
}

//-------//
// FILES //
//-------//

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		die("cannot read %s: %v", path, err)
	}
	return string(data)
}

write_text :: proc(path, text: string) {
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
		die("cannot write %s: %v", path, err)
	}
}

// release_env reads a key of upstream/release.env.
@(private="file")
release_env :: proc(key: string) -> string {
	path, _ := filepath.join({repo_dir, "upstream", "release.env"})
	for line in strings.split_lines(read_text(path)) {
		if strings.has_prefix(line, "#") {
			continue
		}
		k, _, v := strings.partition(strings.trim_space(line), "=")
		if k == key {
			return v
		}
	}
	die("upstream/release.env has no %s", key)
}
