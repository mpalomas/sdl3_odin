package main

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

//---------//
// EMITTER //
//---------//

Emitter :: struct {
	api:          ^Api,
	overrides:    ^Overrides,
	typedefs:     map[string]^Decl, // by C name
	records:      map[string]^Decl, // structs, unions and opaque types, by C name
	enums:        map[string]^Decl,
	flags_macros: map[string]bool,  // macros that became bit_set members or constants
	odin_names:   map[string]string, // Odin name -> C name, to catch two declarations with the same name
	errors:       [dynamic]string,
}

error :: proc(e: ^Emitter, format: string, args: ..any) {
	append(&e.errors, fmt.aprintf(format, ..args))
}

// builtin_type is a builtin or standard C type, or an SDL integer type (written by hand in sdl3/sdl3.odin), in Odin.
@(private="file")
builtin_type :: proc(name: string) -> (odin: string, ok: bool) {
	switch name {
	case "char":                   return "c.char", true
	case "signed char":            return "c.schar", true
	case "unsigned char":          return "c.uchar", true
	case "short":                  return "c.short", true
	case "unsigned short":         return "c.ushort", true
	case "int":                    return "c.int", true
	case "unsigned int":           return "c.uint", true
	case "long":                   return "c.long", true
	case "unsigned long":          return "c.ulong", true
	case "long long":              return "c.longlong", true
	case "unsigned long long":     return "c.ulonglong", true
	case "float":                  return "f32", true
	case "double":                 return "f64", true
	case "bool":                   return "bool", true
	case "_Bool":                  return "bool", true
	case "size_t":                 return "uint", true
	case "wchar_t":                return "c.wchar_t", true
	case "va_list":                return "c.va_list", true
	case "__builtin_va_list":      return "c.va_list", true
	case "uintptr_t":              return "uintptr", true
	case "intptr_t":               return "c.intptr_t", true
	case "int8_t":                 return "i8", true
	case "uint8_t":                return "u8", true
	case "int16_t":                return "i16", true
	case "uint16_t":               return "u16", true
	case "int32_t":                return "i32", true
	case "uint32_t":               return "u32", true
	case "int64_t":                return "i64", true
	case "uint64_t":               return "u64", true
	case "Sint8":                  return "Sint8", true
	case "Uint8":                  return "Uint8", true
	case "Sint16":                 return "Sint16", true
	case "Uint16":                 return "Uint16", true
	case "Sint32":                 return "Sint32", true
	case "Uint32":                 return "Uint32", true
	case "Sint64":                 return "Sint64", true
	case "Uint64":                 return "Uint64", true
	case "VkInstance":             return "vk.Instance", true
	case "VkPhysicalDevice":       return "vk.PhysicalDevice", true
	case "VkSurfaceKHR":           return "vk.SurfaceKHR", true
	case "VkAllocationCallbacks":  return "vk.AllocationCallbacks", true
	}
	return "", false
}

// System types SDL only passes pointers to; they're rawptr in Odin.
@(private="file")
FOREIGN_OPAQUE_TYPES := []string{"XEvent", "MSG"}

@(private="file")
ODIN_KEYWORDS := []string{
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer", "distinct", "do",
	"dynamic", "else", "enum", "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix", "not_in", "or_break",
	"or_continue", "or_else", "or_return", "package", "proc", "return", "struct", "switch", "transmute", "typeid", "union",
	"using", "when", "where",
}

// odin_name is a C declaration's name in Odin: SDL_ dropped (SDLK_ becomes K_), unless an override names it.
odin_name :: proc(e: ^Emitter, c_name: string) -> string {
	if name, ok := lookup(e.overrides, &e.overrides.names, "name", c_name); ok {
		return name
	}
	name := c_name
	if strings.has_prefix(name, "SDLK_") {
		name = strings.concatenate({"K_", name[len("SDLK_"):]})
	} else if strings.has_prefix(name, "SDL_") {
		name = name[len("SDL_"):]
	}
	return identifier(name)
}

// identifier makes a name usable in Odin: keywords get an underscore after, names starting with a digit one before.
identifier :: proc(name: string) -> string {
	if slice.contains(ODIN_KEYWORDS, name) || name == "c" || name == "vk" { // packages the generated files import
		return strings.concatenate({name, "_"})
	}
	if len(name) > 0 && name[0] >= '0' && name[0] <= '9' {
		return strings.concatenate({"_", name})
	}
	return name
}

//-------//
// TYPES //
//-------//

Type_Context :: enum {
	Param,
	Return,
	Field,
	Typedef,
}

// type_text writes a C type in Odin. indent is the indentation of the line it's on, for records declared in place.
type_text :: proc(e: ^Emitter, t: Type, ctx: Type_Context, indent := 0, path := "") -> string {
	switch t.kind {
	case .Name:
		if t.name == "void" {
			return ""
		}
		if odin, ok := builtin_type(t.name); ok {
			return odin
		}
		if strings.has_prefix(t.name, "SDL_") {
			return odin_name(e, t.name)
		}
		if slice.contains(FOREIGN_OPAQUE_TYPES, t.name) {
			return "rawptr"
		}
		error(e, "%s: unknown C type %q", path, t.name)
		return t.name
	case .Enum:
		return odin_name(e, t.name)
	case .Pointer:
		inner := t.inner^
		#partial switch inner.kind {
		case .Name:
			if inner.name == "void" || slice.contains(FOREIGN_OPAQUE_TYPES, inner.name) {
				return "rawptr"
			}
			if inner.name == "char" {
				return "cstring"
			}
			if inner.name == "__va_list_tag" {
				return "c.va_list" // a va_list parameter, decayed to a pointer on x86-64
			}
		case .Func:
			return func_text(e, inner, indent, path)
		case .Pointer:
			if inner.inner.kind == .Name && inner.inner.name == "char" {
				// `const char * const *` is an array of strings; `char **` usually where a string is returned.
				return "[^]cstring" if inner.is_const else "^cstring"
			}
		}
		return strings.concatenate({"^", type_text(e, inner, ctx, indent, path)})
	case .Array:
		element := type_text(e, t.inner^, ctx, indent, path)
		if ctx == .Param || t.count == 0 {
			return strings.concatenate({"[^]", element})
		}
		return fmt.aprintf("[%d]%s", t.count, element)
	case .Func:
		return func_text(e, t, indent, path)
	case .Record:
		return record_text(e, t.tag == "union", t.fields, indent, path)
	}
	return ""
}

func_text :: proc(e: ^Emitter, t: Type, indent: int, path: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `proc "c" (`)
	for param, i in t.params {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		name := t.param_names[i] if i < len(t.param_names) && t.param_names[i] != "" else fmt.aprintf("arg%d", i)
		fmt.sbprintf(&b, "%s: %s", identifier(name), type_text(e, param, .Param, indent, path))
	}
	if t.variadic {
		strings.write_string(&b, ", #c_vararg args: ..any" if len(t.params) > 0 else "#c_vararg args: ..any")
	}
	strings.write_string(&b, ")")
	if ret := type_text(e, t.ret^, .Return, indent, path); ret != "" {
		fmt.sbprintf(&b, " -> %s", ret)
	}
	return strings.to_string(b)
}

// record_text writes a struct or a raw union's body. path is the record's C name, then its fields: SDL_X.input.axis.
record_text :: proc(e: ^Emitter, is_union: bool, fields: []Field, indent: int, path: string) -> string {
	fields := fields
	b := strings.builder_make()
	// Every event starts as SDL_CommonEvent does; like vendor:sdl3, they take it in with `using`, so its fields (and
	// their Odin types: type is an EventType) are the same in all of them.
	common := strings.has_suffix(path, "Event") && path != "SDL_CommonEvent" && starts_like_common_event(fields)
	if common {
		fields = fields[3:]
	}
	strings.write_string(&b, "struct #raw_union {" if is_union else "struct {")
	if len(fields) == 0 && !common {
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	strings.write_string(&b, "\n")
	if common {
		write_indent(&b, indent + 1)
		strings.write_string(&b, "using commonEvent: CommonEvent,\n")
	}
	for field in fields {
		field_path := fmt.aprintf("%s.%s", path, field.name)
		text: string
		if override, ok := lookup(e.overrides, &e.overrides.fields, "field", field_path); ok {
			text = override
		} else {
			text = type_text(e, field.type, .Field, indent + 1, field_path)
		}
		write_indent(&b, indent + 1)
		if field.name == "" {
			fmt.sbprintf(&b, "using _: %s", text)
		} else if is_padding(path, field.name) {
			fmt.sbprintf(&b, "_: %s", text) // as vendor:sdl3 has them
		} else {
			fmt.sbprintf(&b, "%s: %s", identifier(field.name), text)
		}
		if tag, ok := lookup(e.overrides, &e.overrides.tags, "tag", field_path); ok {
			fmt.sbprintf(&b, " `raw_union_tag:\"%s\"`", tag)
		}
		strings.write_string(&b, ",\n")
	}
	write_indent(&b, indent)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// is_padding tells a field that's only there for the layout, which vendor:sdl3 names _: padding1, padding2... anywhere,
// padding in the events (but SDL_Event's), reserved in SDL_CommonEvent.
is_padding :: proc(record, name: string) -> bool {
	if name == "reserved" {
		return record == "SDL_CommonEvent"
	}
	digits := strings.trim_prefix(name, "padding")
	if digits == name {
		return false
	}
	if digits == "" {
		return strings.has_suffix(record, "Event") && record != "SDL_Event" // SDL_Event's padding is its size
	}
	for ch in digits {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

starts_like_common_event :: proc(fields: []Field) -> bool {
	is :: proc(field: Field, name, type: string) -> bool {
		return field.name == name && field.type.kind == .Name && field.type.name == type
	}
	// The events have an SDL_EventType where SDL_CommonEvent has the Uint32 it's stored in.
	return len(fields) >= 3 && (is(fields[0], "type", "SDL_EventType") || is(fields[0], "type", "Uint32")) &&
	       is(fields[1], "reserved", "Uint32") && is(fields[2], "timestamp", "Uint64")
}

write_indent :: proc(b: ^strings.Builder, indent: int) {
	for _ in 0 ..< indent {
		strings.write_byte(b, '\t')
	}
}

//--------------//
// DECLARATIONS //
//--------------//

// emit_header returns the generated Odin of one header, or "" when it has nothing to bind.
emit_header :: proc(e: ^Emitter, header: ^Header) -> string {
	body := strings.builder_make()
	functions: [dynamic]^Decl
	for &decl in header.decls {
		if skipped(e, decl.name) {
			continue
		}
		// A run of constants ends with a blank line, like the other declarations.
		if decl.kind != .Macro && decl.kind != .Function && strings.has_suffix(strings.to_string(body), "\n") &&
		   !strings.has_suffix(strings.to_string(body), "\n\n") && strings.builder_len(body) > 0 {
			strings.write_string(&body, "\n")
		}
		switch decl.kind {
		case .Function:
			if !decl.inline && decl.exported {
				append(&functions, &decl)
			}
		case .Typedef:
			emit_typedef(e, &body, &decl)
		case .Struct, .Union:
			emit_record(e, &body, &decl)
		case .Opaque:
			if _, ok := e.records[decl.name]; ok && e.records[decl.name] != &decl {
				continue // a complete definition is emitted instead
			}
			declare(e, &decl, odin_name(e, decl.name))
			fmt.sbprintf(&body, "%s :: struct {{}}\n\n", odin_name(e, decl.name))
		case .Enum:
			emit_enum(e, &body, &decl)
		case .Macro:
			emit_macro(e, &body, &decl)
		}
	}
	emit_functions(e, &body, functions[:])
	text := strings.trim_space(strings.to_string(body))
	if text == "" {
		return ""
	}
	b := strings.builder_make()
	fmt.sbprintf(&b, "// Generated by tools/gen from SDL %s's %s. DO NOT EDIT: change tools/gen/overrides.txt or the generator.\n",
		e.api.sdl_version, header.name)
	strings.write_string(&b, "package sdl3\n\n")
	if uses_package(text, "c") {
		strings.write_string(&b, "import \"core:c\"\n")
	}
	if uses_package(text, "vk") {
		strings.write_string(&b, "import vk \"vendor:vulkan\"\n")
	}
	strings.write_string(&b, "\n")
	strings.write_string(&b, text)
	strings.write_string(&b, "\n")
	return strings.to_string(b)
}

// uses_package tells whether Odin text refers to a package: "c.int", but not "proc.x" or a string's "abc.d".
uses_package :: proc(text, package_name: string) -> bool {
	in_string := false
	for i in 0 ..< len(text) {
		ch := text[i]
		if ch == '"' && (i == 0 || text[i - 1] != '\\') {
			in_string = !in_string
		}
		if in_string || !strings.has_prefix(text[i:], package_name) || i + len(package_name) >= len(text) ||
		   text[i + len(package_name)] != '.' {
			continue
		}
		if i == 0 || !is_identifier_byte(text[i - 1]) {
			return true
		}
	}
	return false
}

is_identifier_byte :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
}

header_of :: proc(e: ^Emitter, decl: ^Decl) -> ^Header {
	for &header in e.api.headers {
		if header.name == decl.header {
			return &header
		}
	}
	return nil
}

skipped :: proc(e: ^Emitter, c_name: string) -> bool {
	_, ok := lookup(e.overrides, &e.overrides.skips, "skip", c_name)
	return ok
}

// declare records an Odin name, and reports it when another declaration already has it.
declare :: proc(e: ^Emitter, decl: ^Decl, name: string) {
	if previous, ok := e.odin_names[name]; ok && previous != decl.name {
		error(e, "%s:%d: %s and %s are both %s in Odin", decl.header, decl.line, previous, decl.name, name)
		return
	}
	e.odin_names[name] = decl.name
}

emit_typedef :: proc(e: ^Emitter, b: ^strings.Builder, decl: ^Decl) {
	t := decl.type
	// typedef struct SDL_X SDL_X: the record is emitted under its own name.
	if t.kind == .Name && t.tag != "" && t.name == decl.name {
		return
	}
	if t.kind == .Enum && t.name == decl.name {
		return
	}
	name := odin_name(e, decl.name)
	if flags, ok := lookup(e.overrides, &e.overrides.flags, "flags", decl.name); ok {
		emit_flags(e, b, decl, name, flags)
		return
	}
	declare(e, decl, name)
	if override, ok := lookup(e.overrides, &e.overrides.types, "type", decl.name); ok {
		fmt.sbprintf(b, "%s :: %s\n\n", name, override)
		return
	}
	#partial switch t.kind {
	case .Pointer:
		if t.inner.kind == .Func {
			fmt.sbprintf(b, "%s :: #type %s\n\n", name, func_text(e, t.inner^, 0, decl.name))
			return
		}
		if t.inner.kind == .Name && t.inner.name == "void" {
			fmt.sbprintf(b, "%s :: distinct rawptr\n\n", name)
			return
		}
	case .Name:
		if t.tag == "" {
			fmt.sbprintf(b, "%s :: distinct %s\n\n", name, type_text(e, t, .Typedef, 0, decl.name))
			return
		}
	}
	fmt.sbprintf(b, "%s :: %s\n\n", name, type_text(e, t, .Typedef, 0, decl.name))
}

emit_record :: proc(e: ^Emitter, b: ^strings.Builder, decl: ^Decl) {
	name := odin_name(e, decl.name)
	declare(e, decl, name)
	if override, ok := lookup(e.overrides, &e.overrides.types, "type", decl.name); ok {
		fmt.sbprintf(b, "%s :: %s\n\n", name, override)
		return
	}
	fmt.sbprintf(b, "%s :: %s\n\n", name, record_text(e, decl.kind == .Union, decl.fields, 0, decl.name))
}

// enum_prefix is the prefix of an enum's constants that its Odin members drop: SDL_GAMEPAD_BUTTON_ for
// SDL_GamepadButton, else the longest one they share up to an underscore.
enum_prefix :: proc(c_name: string, names: []string) -> string {
	expected := strings.concatenate({"SDL_", upper_snake(c_name[len("SDL_"):] if strings.has_prefix(c_name, "SDL_") else c_name), "_"})
	all_expected := len(names) > 0
	for name in names {
		if !strings.has_prefix(name, expected) || len(name) == len(expected) {
			all_expected = false
		}
	}
	if all_expected {
		return expected
	}
	if len(names) < 2 {
		return "SDL_"
	}
	prefix := names[0]
	for name in names[1:] {
		n := 0
		for n < len(prefix) && n < len(name) && prefix[n] == name[n] {
			n += 1
		}
		prefix = prefix[:n]
	}
	if cut := strings.last_index_byte(prefix, '_'); cut >= 0 {
		return prefix[:cut + 1]
	}
	return ""
}

// upper_snake turns CamelCase into CAMEL_CASE: GamepadButton becomes GAMEPAD_BUTTON, GPUTextureType GPU_TEXTURE_TYPE.
upper_snake :: proc(name: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(name) {
		ch := name[i]
		is_upper := ch >= 'A' && ch <= 'Z'
		if i > 0 && is_upper {
			previous := name[i - 1]
			next_lower := i + 1 < len(name) && name[i + 1] >= 'a' && name[i + 1] <= 'z'
			if (previous >= 'a' && previous <= 'z') || (previous >= '0' && previous <= '9') ||
			   (previous >= 'A' && previous <= 'Z' && next_lower) {
				strings.write_byte(&b, '_')
			}
		}
		strings.write_byte(&b, ch - 32 if ch >= 'a' && ch <= 'z' else ch)
	}
	return strings.to_string(b)
}

emit_enum :: proc(e: ^Emitter, b: ^strings.Builder, decl: ^Decl) {
	name := odin_name(e, decl.name)
	declare(e, decl, name)
	backing := "c.int"
	if override, ok := lookup(e.overrides, &e.overrides.enums, "enum", decl.name); ok {
		backing = override
	}
	names := make([]string, len(decl.constants))
	for constant, i in decl.constants {
		names[i] = constant.name
	}
	prefix := enum_prefix(decl.name, names)
	fmt.sbprintf(b, "%s :: enum %s {{\n", name, backing)
	next: i64 = 0
	for constant in decl.constants {
		if skipped(e, constant.name) {
			next = constant.value + 1
			continue
		}
		member: string
		if override, ok := lookup(e.overrides, &e.overrides.members, "member", constant.name); ok {
			member = override
		} else {
			member = identifier(constant.name[len(prefix):])
		}
		if constant.value == next {
			fmt.sbprintf(b, "\t%s,\n", member)
		} else {
			fmt.sbprintf(b, "\t%s = %s,\n", member, integer_text(constant.value))
		}
		next = constant.value + 1
	}
	strings.write_string(b, "}\n\n")
	if _, ok := lookup(e.overrides, &e.overrides.aliases, "aliases", decl.name); ok {
		for constant in decl.constants {
			if skipped(e, constant.name) {
				continue
			}
			member, member_ok := lookup(e.overrides, &e.overrides.members, "member", constant.name)
			if !member_ok {
				member = identifier(constant.name[len(prefix):])
			}
			fmt.sbprintf(b, "%s :: %s.%s\n", odin_name(e, constant.name), name, member)
		}
		strings.write_string(b, "\n")
	}
}

integer_text :: proc(value: i64) -> string {
	if value >= 0x10000 {
		return fmt.aprintf("0x%x", value)
	}
	return fmt.aprintf("%d", value)
}

// emit_flags writes a bit_set over the bits of the macros named <prefix>*, and a constant for each macro: the bit's set,
// or a combination of bits.
emit_flags :: proc(e: ^Emitter, b: ^strings.Builder, decl: ^Decl, name: string, flags: Flags_Override) {
	backing := type_text(e, decl.type, .Typedef, 0, decl.name)
	enum_name := flags.enum_name
	if enum_name == "" {
		enum_name = strings.trim_suffix(name, "s")
		if enum_name == name {
			enum_name = strings.concatenate({name, "_Flag"})
		}
	}
	declare(e, decl, name)
	Bit :: struct {
		macro:  ^Decl,
		member: string,
		value:  u64,
	}
	bits: [dynamic]Bit
	// The flags are the run of <prefix>* macros right after the typedef, as SDL's headers write them. A prefix with a star
	// in it (SDL_BUTTON_*MASK) only takes the macros that also end as it does; the others in the run stay constants.
	prefix, _, suffix := strings.partition(flags.prefix, "*")
	header := header_of(e, decl)
	after := false
	for &macro in header.decls {
		if &macro == decl {
			after = true
			continue
		}
		if !after {
			continue
		}
		if macro.kind != .Macro || !strings.has_prefix(macro.name, prefix) {
			break
		}
		if skipped(e, macro.name) || !strings.has_suffix(macro.name, suffix) {
			continue
		}
		value, value_ok := strconv.parse_u64(macro.value)
		if !value_ok {
			if signed, signed_ok := strconv.parse_i64(macro.value); signed_ok {
				value, value_ok = u64(signed), true
			}
		}
		if !value_ok {
			continue
		}
		member, member_ok := lookup(e.overrides, &e.overrides.members, "member", macro.name)
		if !member_ok {
			member = identifier(strings.trim_suffix(macro.name[len(prefix):], suffix))
		}
		append(&bits, Bit{&macro, member, value})
		e.flags_macros[macro.name] = true
	}
	if len(bits) == 0 {
		error(e, "%s:%d: no %s macros follow %s", decl.header, decl.line, flags.prefix, decl.name)
	}
	fmt.sbprintf(b, "%s :: distinct bit_set[%s; %s]\n", name, enum_name, backing)
	fmt.sbprintf(b, "%s :: enum %s {{\n", enum_name, backing)
	for bit in bits {
		if bit.value != 0 && bit.value & (bit.value - 1) == 0 {
			index := 0
			for bit.value >> u64(index) != 1 {
				index += 1
			}
			fmt.sbprintf(b, "\t%s = %d,\n", bit.member, index)
		}
	}
	strings.write_string(b, "}\n\n")
	for bit in bits {
		constant := odin_name(e, bit.macro.name)
		declare(e, bit.macro, constant)
		covered: u64 = 0
		for single in bits {
			if single.value != 0 && single.value & (single.value - 1) == 0 && bit.value & single.value == single.value {
				covered |= single.value
			}
		}
		if covered != bit.value {
			// Bits no member names, like SDL_BLENDMODE_INVALID's 0x7FFFFFFF: the value itself.
			fmt.sbprintf(b, "%s :: transmute(%s)%s(0x%X)\n", constant, name, backing, bit.value)
			continue
		}
		fmt.sbprintf(b, "%s :: %s{{", constant, name)
		first := true
		for single in bits {
			if single.value != 0 && single.value & (single.value - 1) == 0 && bit.value & single.value == single.value {
				fmt.sbprintf(b, "%s.%s", "" if first else ", ", single.member)
				first = false
			}
		}
		strings.write_string(b, "}\n")
	}
	strings.write_string(b, "\n")
}

emit_macro :: proc(e: ^Emitter, b: ^strings.Builder, decl: ^Decl) {
	if e.flags_macros[decl.name] {
		return
	}
	name := odin_name(e, decl.name)
	declare(e, decl, name)
	fmt.sbprintf(b, "%s :: %s\n", name, macro_value(decl))
}

// macro_value writes a macro's value as a literal: the header's own text when it's a plain number, else the value clang
// computed.
macro_value :: proc(decl: ^Decl) -> string {
	switch decl.ctype {
	case "s":
		return quote(decl.value)
	case "f32", "f64":
		literal := strings.trim_right(decl.body, "fF")
		if _, ok := strconv.parse_f64(literal); ok && !strings.contains_any(literal, "()") {
			return literal
		}
		return decl.value
	}
	literal := decl.body
	if strings.has_prefix(literal, "SDL_UINT64_C(") || strings.has_prefix(literal, "SDL_SINT64_C(") {
		literal = strings.trim_suffix(literal[len("SDL_UINT64_C("):], ")")
	}
	literal = strings.trim_right(literal, "uUlL")
	if strings.has_prefix(literal, "0x") || strings.has_prefix(literal, "0X") {
		if _, ok := strconv.parse_u64(literal); ok {
			return literal
		}
	}
	return decl.value
}

quote :: proc(s: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '"')
	for ch in s {
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\t': strings.write_string(&b, `\t`)
		case:      strings.write_rune(&b, ch)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

//-----------//
// FUNCTIONS //
//-----------//

// platform_condition is the `when` condition of a declaration that only exists on some platforms, or "".
platform_condition :: proc(decl: ^Decl) -> string {
	switch {
	case strings.contains(decl.guard, "SDL_PLATFORM_WIN"):
		return "ODIN_OS == .Windows"
	case strings.contains(decl.guard, "SDL_PLATFORM_LINUX"):
		return "ODIN_OS == .Linux"
	case strings.contains(decl.guard, "SDL_PLATFORM_APPLE"), strings.contains(decl.guard, "SDL_PLATFORM_MACOS"):
		return "ODIN_OS == .Darwin"
	}
	return ""
}

emit_functions :: proc(e: ^Emitter, b: ^strings.Builder, functions: []^Decl) {
	if len(functions) == 0 {
		return
	}
	// One foreign block for the functions every platform has, then one per platform condition, in order of appearance.
	conditions: [dynamic]string
	append(&conditions, "")
	for f in functions {
		if condition := platform_condition(f); !slice.contains(conditions[:], condition) {
			append(&conditions, condition)
		}
	}
	for condition in conditions {
		block := strings.builder_make()
		indent := 0 if condition == "" else 1
		for f in functions {
			if platform_condition(f) != condition {
				continue
			}
			write_indent(&block, indent + 1)
			strings.write_string(&block, function_text(e, f, indent + 1))
			strings.write_string(&block, "\n")
		}
		if strings.builder_len(block) == 0 {
			continue
		}
		strings.write_string(b, "\n")
		if condition != "" {
			fmt.sbprintf(b, "when %s {{\n", condition)
		}
		write_indent(b, indent)
		strings.write_string(b, "@(default_calling_convention=\"c\", link_prefix=\"SDL_\")\n")
		write_indent(b, indent)
		strings.write_string(b, "foreign lib {\n")
		strings.write_string(b, strings.to_string(block))
		write_indent(b, indent)
		strings.write_string(b, "}\n")
		if condition != "" {
			strings.write_string(b, "}\n")
		}
	}
}

function_text :: proc(e: ^Emitter, f: ^Decl, indent: int) -> string {
	if !strings.has_prefix(f.name, "SDL_") {
		error(e, "%s: function %s has no SDL_ prefix, link_prefix can't bind it", f.header, f.name)
	}
	name := odin_name(e, f.name)
	declare(e, f, name)
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s :: proc(", name)
	for param, i in f.params {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		key := fmt.aprintf("%s.%s", f.name, param.name)
		param_name := identifier(param.name if param.name != "" else fmt.aprintf("arg%d", i))
		if _, byptr := lookup(e.overrides, &e.overrides.byptr, "byptr", key); byptr {
			if param.type.kind != .Pointer {
				error(e, "%s: byptr needs a pointer parameter", key)
			}
			fmt.sbprintf(&b, "#by_ptr %s: %s", param_name, type_text(e, param.type.inner^, .Param, indent, key))
		} else if override, ok := lookup(e.overrides, &e.overrides.params, "param", key); ok {
			fmt.sbprintf(&b, "%s: %s", param_name, override)
		} else {
			fmt.sbprintf(&b, "%s: %s", param_name, type_text(e, param.type, .Param, indent, key))
		}
	}
	if f.variadic {
		strings.write_string(&b, ", #c_vararg args: ..any" if len(f.params) > 0 else "#c_vararg args: ..any")
	}
	strings.write_string(&b, ")")
	ret_key := fmt.aprintf("%s.return", f.name)
	ret, ret_ok := lookup(e.overrides, &e.overrides.params, "param", ret_key)
	if !ret_ok {
		ret = type_text(e, f.ret, .Return, indent, ret_key)
	}
	if ret != "" {
		fmt.sbprintf(&b, " -> %s", ret)
	}
	strings.write_string(&b, " ---")
	return strings.to_string(b)
}
