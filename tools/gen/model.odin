package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

//-------//
// MODEL //
//-------//

// A C type from sdl3_api.json, as tools/dump_api.py parsed it.
Type_Kind :: enum {
	Name,   // `name`: a builtin ("unsigned int") or a typedef ("Uint32", "SDL_Window")
	Enum,   // `name`, written "enum SDL_X" in C
	Pointer, // to `inner`
	Array,  // of `inner`, `count` elements (0 when unbounded)
	Func,   // returning `ret`, taking `params` (named by `param_names` when known)
	Record, // an anonymous struct or union declared in place: `tag`, `fields`
}

Type :: struct {
	kind:        Type_Kind,
	name:        string,
	tag:         string, // "struct" or "union" for records and tagged names
	is_const:    bool,
	inner:       ^Type,
	count:       int,
	ret:         ^Type,
	params:      []Type,
	param_names: []string,
	variadic:    bool,
	fields:      []Field,
}

Field :: struct {
	name: string, // "" for an anonymous member
	type: Type,
}

Param :: struct {
	name: string,
	type: Type,
}

Constant :: struct {
	name:  string,
	value: i64,
}

Decl_Kind :: enum {
	Function,
	Struct,
	Union,
	Opaque,
	Enum,
	Typedef,
	Macro,
}

Decl :: struct {
	kind:      Decl_Kind,
	name:      string,
	header:    string,
	line:      int,
	guard:     string,   // the SDL_PLATFORM_* conditions around it, "" for none
	platforms: []string, // where clang saw it: "linux", "windows", "macos"
	// Function
	ret:       Type,
	params:    []Param,
	variadic:  bool,
	inline:    bool,
	exported:  bool,
	// Struct, Union
	fields:    []Field,
	// Enum
	constants: []Constant,
	// Typedef
	type:      Type,
	// Macro
	ctype:     string, // "s", "i32", "u32", "i64", "u64", "f32", "f64"
	value:     string,
	body:      string, // as written in the header
}

Header :: struct {
	name:  string, // "SDL_video.h"
	decls: []Decl,
}

Function_Macro :: struct {
	name:   string,
	header: string,
}

Api :: struct {
	sdl_version:     string,
	headers:         []Header,
	function_macros: []Function_Macro,
}

//---------//
// LOADING //
//---------//

load_api :: proc(data: []u8) -> (api: Api, err: string) {
	root, parse_err := json.parse(data, parse_integers = true)
	if parse_err != nil {
		return {}, fmt.tprintf("cannot parse the API JSON: %v", parse_err)
	}
	object := root.(json.Object)
	api.sdl_version = get_string(object, "sdl_version")
	headers := get_array(object, "headers")
	api.headers = make([]Header, len(headers))
	for header_value, i in headers {
		header_object := header_value.(json.Object)
		header := &api.headers[i]
		header.name = get_string(header_object, "name")
		decls := get_array(header_object, "decls")
		header.decls = make([]Decl, len(decls))
		for decl_value, j in decls {
			decl_err: string
			header.decls[j], decl_err = load_decl(decl_value.(json.Object))
			if decl_err != "" {
				return {}, decl_err
			}
		}
	}
	macros := get_array(object, "function_macros")
	api.function_macros = make([]Function_Macro, len(macros))
	for macro_value, i in macros {
		macro := macro_value.(json.Object)
		api.function_macros[i] = {name = get_string(macro, "name"), header = get_string(macro, "header")}
	}
	return api, ""
}

@(private="file")
decl_kind :: proc(name: string) -> (kind: Decl_Kind, ok: bool) {
	switch name {
	case "function": return .Function, true
	case "struct":   return .Struct, true
	case "union":    return .Union, true
	case "opaque":   return .Opaque, true
	case "enum":     return .Enum, true
	case "typedef":  return .Typedef, true
	case "macro":    return .Macro, true
	}
	return {}, false
}

@(private="file")
load_decl :: proc(object: json.Object) -> (decl: Decl, err: string) {
	kind_name := get_string(object, "kind")
	kind, kind_ok := decl_kind(kind_name)
	if !kind_ok {
		return {}, fmt.tprintf("unknown declaration kind %q", kind_name)
	}
	decl = Decl{
		kind = kind, name = get_string(object, "name"), header = get_string(object, "header"), line = get_int(object, "line"),
		guard = get_string(object, "guard"),
	}
	platforms := get_array(object, "platforms")
	decl.platforms = make([]string, len(platforms))
	for p, i in platforms {
		decl.platforms[i] = p.(json.String)
	}
	switch kind {
	case .Function:
		decl.ret = load_type(object["ret"])
		decl.variadic = get_bool(object, "variadic")
		decl.inline = get_bool(object, "inline")
		decl.exported = get_bool(object, "exported")
		params := get_array(object, "params")
		decl.params = make([]Param, len(params))
		for p, i in params {
			param := p.(json.Object)
			decl.params[i] = {name = get_string(param, "name"), type = load_type(param["type"])}
		}
	case .Struct, .Union:
		decl.fields = load_fields(get_array(object, "fields"))
	case .Opaque:
	case .Enum:
		constants := get_array(object, "constants")
		decl.constants = make([]Constant, len(constants))
		for c, i in constants {
			constant := c.(json.Object)
			decl.constants[i] = {name = get_string(constant, "name"), value = i64(get_int(constant, "value"))}
		}
	case .Typedef:
		decl.type = load_type(object["type"])
	case .Macro:
		decl.ctype = get_string(object, "ctype")
		decl.value = get_string(object, "value")
		decl.body = get_string(object, "body")
	}
	return decl, ""
}

@(private="file")
load_fields :: proc(values: json.Array) -> []Field {
	fields := make([]Field, len(values))
	for f, i in values {
		field := f.(json.Object)
		fields[i] = {name = get_string(field, "name"), type = load_type(field["type"])}
	}
	return fields
}

@(private="file")
load_type :: proc(value: json.Value) -> Type {
	object := value.(json.Object)
	t := Type{is_const = get_bool(object, "const")}
	switch get_string(object, "t") {
	case "name":
		t.kind = .Name
		t.name = get_string(object, "name")
		t.tag = get_string(object, "tag")
	case "enum":
		t.kind = .Enum
		t.name = get_string(object, "name")
	case "ptr":
		t.kind = .Pointer
		t.inner = new_clone(load_type(object["to"]))
	case "array":
		t.kind = .Array
		t.inner = new_clone(load_type(object["of"]))
		t.count = get_int(object, "n")
	case "func":
		t.kind = .Func
		t.ret = new_clone(load_type(object["ret"]))
		t.variadic = get_bool(object, "variadic")
		params := get_array(object, "params")
		t.params = make([]Type, len(params))
		for p, i in params {
			t.params[i] = load_type(p)
		}
		names := get_array(object, "param_names")
		t.param_names = make([]string, len(names))
		for n, i in names {
			t.param_names[i] = n.(json.String)
		}
	case "record":
		t.kind = .Record
		t.tag = get_string(object, "tag")
		t.fields = load_fields(get_array(object, "fields"))
	case:
		fmt.panicf("unknown type kind %q", get_string(object, "t"))
	}
	return t
}

@(private="file")
get_string :: proc(object: json.Object, key: string) -> string {
	value, ok := object[key].(json.String)
	return value if ok else ""
}

@(private="file")
get_int :: proc(object: json.Object, key: string) -> int {
	#partial switch value in object[key] {
	case json.Integer:
		return int(value)
	case json.Float:
		return int(value)
	}
	return 0
}

@(private="file")
get_bool :: proc(object: json.Object, key: string) -> bool {
	value, ok := object[key].(json.Boolean)
	return bool(value) if ok else false
}

@(private="file")
get_array :: proc(object: json.Object, key: string) -> json.Array {
	value, ok := object[key].(json.Array)
	return value if ok else nil
}

//-----------//
// OVERRIDES //
//-----------//

// The Odin idioms the C headers can't tell, from tools/gen/overrides.txt. One per line:
//
//	type   <C typedef>         <Odin type>   the right-hand side of a typedef ("distinct [2]c.int")
//	param  <function>.<param>  <Odin type>   a parameter's type; "<function>.return" is the result
//	byptr  <function>.<param>                take a `const T *` parameter as `#by_ptr p: T`
//	field  <record>.<field>    <Odin type>   a struct or union field's type
//	tag    <record>.<field>    <tag text>    a raw_union_tag:"..." on a field of an anonymous union
//	enum   <C enum>            <Odin type>   an enum's backing type (c.int by default)
//	flags  <C typedef>         <prefix> [<enum name>]   a bit_set of the macros named <prefix>*
//	name   <C name>            <Odin name>   a declaration or macro's Odin name
//	member <C constant>        <Odin name>   an enum or bit_set member's name (the flag macro's constant keeps its own)
//	aliases <C enum>                         also a constant for each member: GL_RED_SIZE :: GLAttr.RED_SIZE
//	skip   <C name>                          not emitted (written by hand in sdl3/, or not wanted); also enum constants
Overrides :: struct {
	types:  map[string]string,
	params: map[string]string,
	byptr:  map[string]bool,
	fields: map[string]string,
	tags:   map[string]string,
	enums:  map[string]string,
	flags:  map[string]Flags_Override,
	names:  map[string]string,
	members: map[string]string,
	aliases: map[string]bool,
	skips:  map[string]bool,
	used:   map[string]bool, // the "<directive> <key>" of every override applied, to report the stale ones
}

Flags_Override :: struct {
	prefix:    string,
	enum_name: string, // "" for <bit_set name without "s">: WindowFlags has WindowFlag
}

parse_overrides :: proc(text: string) -> (overrides: Overrides, err: string) {
	for line, number in strings.split_lines(text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		fields := strings.fields(trimmed)
		rest := ""
		if len(fields) > 2 {
			rest = strings.trim_space(trimmed[strings.index(trimmed, fields[1]) + len(fields[1]):])
		}
		arguments_ok := true
		switch fields[0] {
		case "type":   arguments_ok = len(fields) >= 3; overrides.types[fields[1]] = rest
		case "param":  arguments_ok = len(fields) >= 3; overrides.params[fields[1]] = rest
		case "byptr":  arguments_ok = len(fields) == 2; overrides.byptr[fields[1]] = true
		case "field":  arguments_ok = len(fields) >= 3; overrides.fields[fields[1]] = rest
		case "tag":    arguments_ok = len(fields) >= 3; overrides.tags[fields[1]] = rest
		case "enum":   arguments_ok = len(fields) == 3; overrides.enums[fields[1]] = rest
		case "name":   arguments_ok = len(fields) == 3; overrides.names[fields[1]] = rest
		case "member": arguments_ok = len(fields) == 3; overrides.members[fields[1]] = rest
		case "aliases": arguments_ok = len(fields) == 2; overrides.aliases[fields[1]] = true
		case "skip":   arguments_ok = len(fields) == 2; overrides.skips[fields[1]] = true
		case "flags":
			arguments_ok = len(fields) == 3 || len(fields) == 4
			if arguments_ok {
				overrides.flags[fields[1]] = {prefix = fields[2], enum_name = fields[3] if len(fields) == 4 else ""}
			}
		case:
			return {}, fmt.tprintf("overrides line %d: unknown directive %q", number + 1, fields[0])
		}
		if !arguments_ok {
			return {}, fmt.tprintf("overrides line %d: wrong number of arguments for %q", number + 1, fields[0])
		}
	}
	return overrides, ""
}

// lookup returns an override and marks it used.
lookup :: proc(overrides: ^Overrides, table: ^map[string]$T, directive, key: string) -> (value: T, ok: bool) {
	value, ok = table[key]
	if ok {
		overrides.used[fmt.aprintf("%s %s", directive, key)] = true
	}
	return
}
