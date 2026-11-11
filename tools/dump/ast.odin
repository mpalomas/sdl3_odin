package main

import "core:encoding/json"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

//-------------//
// CLANG'S AST //
//-------------//

Location :: struct {
	file: string,
	line: i64,
	ok:   bool, // false when the node has no location
}

// Clang's JSON leaves out a location's file and line when they're the same as the last location it printed, across the
// whole output. Locations follows them in print order: loc, then range begin and end, each as spelling then expansion,
// then the children. It keeps the location of every node by its id.
Locations :: struct {
	file:  string,
	line:  i64,
	by_id: map[string]Location,
}

@(private="file")
bare :: proc(l: ^Locations, loc: json.Object) -> Location {
	if file, ok := loc["file"].(json.String); ok {
		l.file = strings.clone(file)
	}
	if line, ok := loc["line"].(json.Integer); ok {
		l.line = line
	}
	return {l.file, l.line, true}
}

@(private="file")
location :: proc(l: ^Locations, value: json.Value) -> Location {
	loc, ok := value.(json.Object)
	if !ok || len(loc) == 0 {
		return {}
	}
	spelling, has_spelling := loc["spellingLoc"]
	expansion, has_expansion := loc["expansionLoc"]
	if has_spelling || has_expansion {
		bare(l, spelling.(json.Object) or_else nil)
		return bare(l, expansion.(json.Object) or_else nil)
	}
	return bare(l, loc)
}

track_locations :: proc(l: ^Locations, node: json.Object) {
	own := location(l, node["loc"])
	if r, ok := node["range"].(json.Object); ok {
		location(l, r["begin"])
		location(l, r["end"])
	}
	if id, ok := node["id"].(json.String); ok {
		l.by_id[strings.clone(id)] = own
	}
	for child in node["inner"].(json.Array) or_else nil {
		if child_object, ok := child.(json.Object); ok {
			track_locations(l, child_object)
		}
	}
}

node_location :: proc(l: ^Locations, node: json.Object) -> Location {
	id, _ := node["id"].(json.String)
	return l.by_id[id]
}

// next_object returns the extent of the next JSON object in a stream of them, and where the stream continues.
next_object :: proc(data: []u8, start: int) -> (object: []u8, next: int, ok: bool) {
	pos := start
	for pos < len(data) && is_space(data[pos]) {
		pos += 1
	}
	if pos >= len(data) {
		return nil, pos, false
	}
	begin, depth, in_string := pos, 0, false
	for ; pos < len(data); pos += 1 {
		ch := data[pos]
		if in_string {
			if ch == '\\' {
				pos += 1
			} else if ch == '"' {
				in_string = false
			}
			continue
		}
		switch ch {
		case '"':
			in_string = true
		case '{', '[':
			depth += 1
		case '}', ']':
			depth -= 1
			if depth == 0 {
				return data[begin:pos + 1], pos + 1, true
			}
		}
	}
	die("the AST dump ends inside an object")
}

//------------//
// CONVERSION //
//------------//

Converter :: struct {
	locations:    ^Locations,
	include_sdl3: string, // the cleaned path of upstream/include/SDL3
}

@(private="file")
str :: proc(object: json.Object, key: string) -> string {
	s, _ := object[key].(json.String)
	return strings.clone(s)
}

@(private="file")
qual_type :: proc(node: json.Object) -> string {
	t, _ := node["type"].(json.Object)
	s, _ := t["qualType"].(json.String)
	return strings.clone(s)
}

@(private="file")
children :: proc(node: json.Object) -> json.Array {
	return node["inner"].(json.Array) or_else nil
}

@(private="file")
header_of :: proc(c: ^Converter, loc: Location) -> (header: string, ok: bool) {
	if !loc.ok || loc.file == "" {
		return "", false
	}
	path, _ := filepath.clean(loc.file)
	directory := filepath.dir(path)
	if directory != c.include_sdl3 {
		return "", false
	}
	return filepath.base(path), true
}

// is_skipped_header: headers that are only part of SDL's own build or tests, or that are other APIs (OpenGL, EGL,
// intrinsics).
is_skipped_header :: proc(name: string) -> bool {
	if !strings.has_prefix(name, "SDL_") || !strings.has_suffix(name, ".h") {
		return false
	}
	middle := name[len("SDL_"):len(name) - len(".h")]
	switch middle {
	case "egl", "intrin", "begin_code", "close_code", "oldnames", "platform_defines", "copying", "revision":
		return true
	}
	return strings.has_prefix(middle, "test") || strings.has_prefix(middle, "opengl")
}

// convert turns a top-level clang node into a declaration of sdl3_api.json.
convert :: proc(c: ^Converter, node: json.Object) -> (decl: Json_Object, ok: bool) {
	loc := node_location(c.locations, node)
	header, header_ok := header_of(c, loc)
	if !header_ok || is_skipped_header(header) {
		return nil, false
	}
	kind := str(node, "kind")
	name := str(node, "name")
	decl = object("name", name, "header", header, "line", loc.line)
	switch kind {
	case "FunctionDecl":
		func := parse_type(qual_type(node))
		inline := (node["inline"].(json.Boolean) or_else false) || str(node, "storageClass") == "static"
		params: Json_Array
		for child in children(node) {
			param := child.(json.Object) or_else nil
			if str(param, "kind") == "ParmVarDecl" {
				append(&params, object("name", str(param, "name"), "type", parse_type(qual_type(param))))
			}
		}
		ret, _ := get(func, "ret")
		set(&decl, "kind", "function")
		set(&decl, "ret", ret)
		set(&decl, "variadic", get_bool(func, "variadic"))
		set(&decl, "inline", inline)
		set(&decl, "params", params)
	case "RecordDecl":
		if !(node["completeDefinition"].(json.Boolean) or_else false) {
			set(&decl, "kind", "opaque")
			set(&decl, "tag", str(node, "tagUsed"))
		} else {
			set(&decl, "kind", str(node, "tagUsed"))
			set(&decl, "fields", record_fields(c, node, header))
		}
	case "EnumDecl":
		set(&decl, "kind", "enum")
		set(&decl, "constants", enum_constants(c, node))
	case "TypedefDecl":
		typedef_type := parse_type(qual_type(node))
		add_param_names(&typedef_type, header, loc.line, name)
		set(&decl, "kind", "typedef")
		set(&decl, "type", typedef_type)
	case:
		return nil, false
	}
	return decl, true
}

@(private="file")
record_fields :: proc(c: ^Converter, node: json.Object, header: string) -> Json_Array {
	fields: Json_Array
	pending: [dynamic]json.Object // anonymous records waiting for the field that uses them
	for child in children(node) {
		child_node := child.(json.Object) or_else nil
		switch str(child_node, "kind") {
		case "RecordDecl":
			append(&pending, child_node)
		case "FieldDecl":
			field_name := str(child_node, "name")
			field_type := parse_type(qual_type(child_node))
			if record := find_record(&field_type); record != nil {
				if len(pending) == 0 {
					die("%s: field %s uses an anonymous record that isn't there", header, field_name)
				}
				set(record, "fields", record_fields(c, pending[0], header))
				ordered_remove(&pending, 0)
			}
			add_param_names(&field_type, header, node_location(c.locations, child_node).line, field_name)
			if child_node["isBitfield"].(json.Boolean) or_else false {
				die("%s: bit field %s isn't supported", header, field_name)
			}
			append(&fields, object("name", field_name, "type", field_type))
		}
	}
	return fields
}

// find_record finds the anonymous record a field's type is made of, through its arrays and pointers.
@(private="file")
find_record :: proc(t: ^Json_Object) -> ^Json_Object {
	current := t
	for {
		switch get_string(current^, "t") {
		case "array", "ptr":
			key := "of" if get_string(current^, "t") == "array" else "to"
			for &pair in current {
				if pair.key == key {
					current = &pair.value.(Json_Object)
				}
			}
		case "record":
			return current
		case:
			return nil
		}
	}
}

@(private="file")
enum_constants :: proc(c: ^Converter, node: json.Object) -> Json_Array {
	constants: Json_Array
	value: i64 = -1
	for child in children(node) {
		constant := child.(json.Object) or_else nil
		if str(constant, "kind") != "EnumConstantDecl" {
			continue
		}
		if explicit, ok := find_value(constant); ok {
			value = explicit
		} else {
			value += 1
		}
		append(&constants, object("name", str(constant, "name"), "value", value, "line",
			node_location(c.locations, constant).line))
	}
	return constants
}

@(private="file")
find_value :: proc(node: json.Object) -> (value: i64, ok: bool) {
	for child in children(node) {
		child_node := child.(json.Object) or_else nil
		if str(child_node, "kind") == "ConstantExpr" {
			if text, has := child_node["value"].(json.String); has {
				return strconv.parse_i64(text)
			}
		}
		if value, ok = find_value(child_node); ok {
			return
		}
	}
	return 0, false
}

//------------------------------//
// FUNCTION POINTER PARAMETERS //
//------------------------------//

@(private="file")
header_lines: map[string][]string

// The header lines of upstream/include/SDL3, set by main.
include_sdl3_dir: string

// fnptr_param_names returns the parameter names of a function pointer declared at a header's line ("(SDLCALL *name)(void
// *userdata, int x)"), which clang's type strings leave out, or nothing when the text doesn't have them.
@(private="file")
fnptr_param_names :: proc(header: string, line: i64, name: string) -> (names: [dynamic]string, ok: bool) {
	if header not_in header_lines {
		path, _ := filepath.join({include_sdl3_dir, header})
		header_lines[header] = strings.split(read_text(path), "\n")
	}
	lines := header_lines[header]
	first := max(int(line) - 3, 0)
	last := min(int(line) + 12, len(lines))
	text := strip_block_comments(strings.join(lines[first:last] if first < last else nil, " "))
	open, open_ok := find_fnptr_open(text, name)
	if !open_ok {
		return nil, false
	}
	params: [dynamic]string
	depth, pos, start := 1, open, open
	for pos < len(text) && depth > 0 {
		switch text[pos] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		}
		if (text[pos] == ',' && depth == 1) || depth == 0 {
			append(&params, strings.trim_space(text[start:pos]))
			start = pos + 1
		}
		pos += 1
	}
	for param in params {
		trimmed := strings.trim_space(strip_brackets(param))
		if trimmed == "void" || trimmed == "..." || trimmed == "" {
			continue
		}
		end := len(trimmed)
		for end > 0 && is_space(trimmed[end - 1]) {
			end -= 1
		}
		begin := end
		for begin > 0 && is_identifier_byte(trimmed[begin - 1]) {
			begin -= 1
		}
		word := trimmed[begin:end]
		if word == "" || !is_identifier_start(word[0]) {
			// Python's \b-less search takes the longest identifier ending there; digits alone aren't one.
			for len(word) > 0 && !is_identifier_start(word[0]) {
				word = word[1:]
			}
		}
		append(&names, word)
	}
	return names, true
}

// find_fnptr_open finds `(\s*(SDLCALL\s*)?\*\s*<name>\s*)\s*(` and returns the index after its last "(".
@(private="file")
find_fnptr_open :: proc(text, name: string) -> (index: int, ok: bool) {
	skip :: proc(text: string, pos: int) -> int {
		p := pos
		for p < len(text) && is_space(text[p]) {
			p += 1
		}
		return p
	}
	for start in 0 ..< len(text) {
		if text[start] != '(' {
			continue
		}
		p := skip(text, start + 1)
		if strings.has_prefix(text[p:], "SDLCALL") {
			after := skip(text, p + len("SDLCALL"))
			if after < len(text) && text[after] == '*' {
				p = after
			}
		}
		if p >= len(text) || text[p] != '*' {
			continue
		}
		p = skip(text, p + 1)
		if !strings.has_prefix(text[p:], name) {
			continue
		}
		p = skip(text, p + len(name))
		if p >= len(text) || text[p] != ')' {
			continue
		}
		p = skip(text, p + 1)
		if p >= len(text) || text[p] != '(' {
			continue
		}
		return p + 1, true
	}
	return 0, false
}

// strip_block_comments replaces each /* ... */ with a space, as re.sub(r"/\*.*?\*/", " ", text) does.
strip_block_comments :: proc(text: string) -> string {
	b := strings.builder_make()
	pos := 0
	for pos < len(text) {
		if strings.has_prefix(text[pos:], "/*") {
			if end := strings.index(text[pos + 2:], "*/"); end >= 0 {
				strings.write_byte(&b, ' ')
				pos += 2 + end + 2
				continue
			}
		}
		strings.write_byte(&b, text[pos])
		pos += 1
	}
	return strings.to_string(b)
}

// strip_brackets removes every [...], as re.sub(r"\[[^\]]*\]", "", text) does.
@(private="file")
strip_brackets :: proc(text: string) -> string {
	b := strings.builder_make()
	pos := 0
	for pos < len(text) {
		if text[pos] == '[' {
			if end := strings.index_byte(text[pos:], ']'); end >= 0 {
				pos += end + 1
				continue
			}
		}
		strings.write_byte(&b, text[pos])
		pos += 1
	}
	return strings.to_string(b)
}

add_param_names :: proc(t: ^Json_Object, header: string, line: i64, name: string) {
	if get_string(t^, "t") != "ptr" {
		return
	}
	for &pair in t {
		if pair.key != "to" {
			continue
		}
		to := &pair.value.(Json_Object)
		if get_string(to^, "t") != "func" {
			return
		}
		names, ok := fnptr_param_names(header, line, name)
		params, _ := get(to^, "params")
		if ok && len(names) == len(params.(Json_Array)) {
			list: Json_Array
			for n in names {
				append(&list, n)
			}
			set(to, "param_names", list)
		}
	}
}
