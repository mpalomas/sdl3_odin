// Compares the generated bindings in sdl3/ with Odin's vendor:sdl3, declaration by declaration.
//
//	odin run tools/compare_vendor -- [--vendor <odin root>/vendor/sdl3] [--suggest]
//
// Reports what's only in one of them and where they differ: procedure signatures, struct fields, enum members, constants
// and type declarations. Each signature difference is classified:
//   idiom  the same ABI written another way (^T or [^]T, a #by_ptr struct, an enum or bit_set over the same integer...)
//   ABI    a different ABI: a mistake on one side (vendor:sdl3 has some, e.g. procedures returning int instead of c.int)
// --suggest prints, for the idiom differences, the tools/gen/overrides.txt lines that would make ours match vendor's.
package main

import "core:fmt"
import vmem "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

REPO_DIR :: #directory + "../../"

Param :: struct {
	name: string,
	type: string, // with "#by_ptr " in front for a #by_ptr parameter
}

Proc :: struct {
	params: [dynamic]Param,
	ret:    string, // "" for none
}

Field :: struct {
	name: string,
	type: string,
	tag:  string, // the raw_union_tag's value, or ""
}

Struct :: struct {
	is_union: bool,
	fields:   [dynamic]Field,
}

Enum :: struct {
	backing: string,
	members: [dynamic]string,
}

// Package is what a package declares, by name.
Package :: struct {
	procs:   map[string]Proc,
	structs: map[string]Struct,
	enums:   map[string]Enum,
	consts:  map[string]string,
	types:   map[string]string,
}

main :: proc() {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	vendor_dir := ""
	suggest := false
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--suggest":
			suggest = true
		case "--vendor":
			if i + 1 < len(os.args) {
				vendor_dir = os.args[i + 1]
				i += 1
			}
		case:
			fmt.eprintln("usage: odin run tools/compare_vendor -- [--vendor <dir>] [--suggest]")
			os.exit(2)
		}
	}
	if vendor_dir == "" {
		vendor_dir, _ = filepath.join({ODIN_ROOT, "vendor", "sdl3"})
	}
	ours_dir, _ := filepath.join({REPO_DIR, "sdl3"})
	ours := read_package(ours_dir)
	vendor := read_package(vendor_dir)
	compare(&ours, &vendor, suggest)
}

//---------//
// READING //
//---------//

read_package :: proc(dir: string) -> Package {
	pkg, ok := parser.parse_package_from_path(dir)
	if !ok {
		fmt.eprintfln("compare_vendor: cannot parse the package in %s", dir)
		os.exit(1)
	}
	out: Package
	names, _ := slice.map_keys(pkg.files)
	slice.sort(names)
	for name in names {
		file := pkg.files[name]
		for stmt in file.decls {
			visit(&out, file.src, stmt, false)
		}
	}
	return out
}

visit :: proc(out: ^Package, src: string, stmt: ^ast.Stmt, in_foreign: bool) {
	if stmt == nil {
		return
	}
	#partial switch s in stmt.derived {
	case ^ast.Foreign_Block_Decl:
		visit(out, src, s.body, true)
	case ^ast.When_Stmt:
		visit(out, src, s.body, in_foreign)
		visit(out, src, s.else_stmt, in_foreign)
	case ^ast.Block_Stmt:
		for inner in s.stmts {
			visit(out, src, inner, in_foreign)
		}
	case ^ast.Value_Decl:
		if s.is_mutable || is_private(src, s.attributes[:]) {
			return
		}
		for name_expr, i in s.names {
			if i >= len(s.values) {
				continue
			}
			name := text(src, name_expr)
			value := s.values[i]
			if in_foreign {
				if lit, is_lit := value.derived.(^ast.Proc_Lit); is_lit {
					out.procs[name] = read_proc(src, lit.type)
				}
				continue
			}
			read_decl(out, src, name, value)
		}
	}
}

is_private :: proc(src: string, attributes: []^ast.Attribute) -> bool {
	for attribute in attributes {
		if strings.contains(text(src, attribute), "private") {
			return true
		}
	}
	return false
}

read_decl :: proc(out: ^Package, src: string, name: string, value: ^ast.Expr) {
	expr := value
	if d, is_distinct := expr.derived.(^ast.Distinct_Type); is_distinct {
		if st, is_struct := d.type.derived.(^ast.Struct_Type); is_struct {
			expr = st
		}
	}
	#partial switch v in expr.derived {
	case ^ast.Struct_Type:
		out.structs[name] = Struct{is_union = v.is_raw_union, fields = read_fields(src, v.fields)}
		return
	case ^ast.Enum_Type:
		e := Enum{backing = text(src, v.base_type) if v.base_type != nil else "int"}
		for member in v.fields {
			if fv, is_value := member.derived.(^ast.Field_Value); is_value {
				append(&e.members, text(src, fv.field))
			} else {
				append(&e.members, text(src, member))
			}
		}
		out.enums[name] = e
		return
	case ^ast.Proc_Lit:
		return // a procedure written in Odin
	case ^ast.Helper_Type:
		out.types[name] = text(src, value)
		return
	}
	// Constants are named in capitals; anything else is a type.
	if is_constant_name(name) {
		out.consts[name] = text(src, value)
	} else {
		out.types[name] = text(src, value)
	}
}

is_constant_name :: proc(name: string) -> bool {
	for ch in name {
		if !(ch >= 'A' && ch <= 'Z') && !(ch >= '0' && ch <= '9') && ch != '_' {
			return false
		}
	}
	return true
}

read_proc :: proc(src: string, t: ^ast.Proc_Type) -> Proc {
	p: Proc
	if t.params != nil {
		for field in t.params.list {
			type := text(src, field.type)
			if .By_Ptr in field.flags {
				type = strings.concatenate({"#by_ptr ", type})
			}
			for name in field.names {
				append(&p.params, Param{text(src, name), type})
			}
		}
	}
	if t.results != nil && len(t.results.list) > 0 {
		p.ret = text(src, t.results.list[0].type)
	}
	return p
}

read_fields :: proc(src: string, list: ^ast.Field_List) -> [dynamic]Field {
	fields: [dynamic]Field
	if list == nil {
		return fields
	}
	for field in list.list {
		tag := ""
		if raw := field.tag.text; raw != "" {
			if at := strings.index(raw, `raw_union_tag:"`); at >= 0 {
				rest := raw[at + len(`raw_union_tag:"`):]
				if end := strings.index_byte(rest, '"'); end >= 0 {
					tag = rest[:end]
				}
			}
		}
		for name in field.names {
			append(&fields, Field{text(src, name), text(src, field.type), tag})
		}
	}
	return fields
}

// text is a node's source, with whitespace runs made one space.
text :: proc(src: string, node: ^ast.Node) -> string {
	if node == nil {
		return ""
	}
	raw := src[node.pos.offset:node.end.offset]
	b := strings.builder_make()
	space := false
	for ch in strings.trim_space(raw) {
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
			space = true
			continue
		}
		if space {
			strings.write_byte(&b, ' ')
			space = false
		}
		strings.write_rune(&b, ch)
	}
	out := strings.to_string(b)
	out, _ = strings.replace_all(out, "( ", "(")
	out, _ = strings.replace_all(out, " )", ")")
	return out
}

//-----------//
// COMPARING //
//-----------//

// The ABI class of a type: "ptr", or the integer or float it's made of.
resolve :: proc(pkg: ^Package, type: string) -> string {
	t := strings.trim_prefix(type, "#by_ptr ")
	for _ in 0 ..< 8 {
		if is_pointerish(t) {
			return "ptr"
		}
		if class, ok := int_alias(t); ok {
			return class
		}
		if strings.has_prefix(t, "distinct ") {
			t = t[len("distinct "):]
			continue
		}
		if strings.has_prefix(t, "bit_set[") {
			if semicolon := strings.index_byte(t, ';'); semicolon >= 0 {
				t = strings.trim_space(strings.trim_suffix(t[semicolon + 1:], "]"))
				continue
			}
		}
		if e, ok := pkg.enums[t]; ok {
			t = e.backing
			continue
		}
		if alias, ok := pkg.types[t]; ok {
			t = alias
			continue
		}
		return t
	}
	return t
}

is_pointerish :: proc(t: string) -> bool {
	return strings.has_prefix(t, "^") || strings.has_prefix(t, "[^]") || t == "rawptr" || t == "cstring" ||
	       strings.has_prefix(t, "Maybe(^") || strings.has_prefix(t, "proc") || strings.has_prefix(t, "#type proc")
}

int_alias :: proc(t: string) -> (class: string, ok: bool) {
	switch t {
	case "Uint8", "c.uchar", "u8", "bool", "b8":             return "u8", true
	case "Sint8", "c.char", "c.schar", "i8":                 return "i8", true
	case "Uint16", "c.ushort", "u16":                        return "u16", true
	case "Sint16", "c.short", "i16":                         return "i16", true
	case "Uint32", "c.uint", "u32":                          return "u32", true
	case "Sint32", "c.int", "i32", "b32", "rune", "c.wchar_t": return "i32", true
	case "Uint64", "c.ulonglong", "c.size_t", "uint", "uintptr", "c.ulong", "u64": return "u64", true
	case "Sint64", "c.longlong", "c.intptr_t", "c.long", "i64": return "i64", true
	case "int":                                               return "i64(int)", true
	case "f32":                                               return "f32", true
	case "f64":                                               return "f64", true
	}
	return "", false
}

// classify returns "" when two types are written the same, "idiom" when they have the same ABI, else "ABI".
classify :: proc(ours, vendor: ^Package, a, b: string) -> string {
	if a == b {
		return ""
	}
	a_ptr := strings.has_prefix(a, "#by_ptr ")
	b_ptr := strings.has_prefix(b, "#by_ptr ")
	if a_ptr != b_ptr {
		// #by_ptr T is passed as ^T.
		a2 := strings.concatenate({"^", a[len("#by_ptr "):]}) if a_ptr else a
		b2 := strings.concatenate({"^", b[len("#by_ptr "):]}) if b_ptr else b
		return "idiom" if resolve(ours, a2) == resolve(vendor, b2) else "ABI"
	}
	return "idiom" if resolve(ours, a) == resolve(vendor, b) else "ABI"
}

compare :: proc(ours, vendor: ^Package, suggest: bool) {
	report_only :: proc(kind: string, a, b: []string) {
		only_a, only_b: [dynamic]string
		for name in a {
			if !slice.contains(b, name) {
				append(&only_a, name)
			}
		}
		for name in b {
			if !slice.contains(a, name) {
				append(&only_b, name)
			}
		}
		if len(only_a) > 0 {
			fmt.printfln("%s only in ours (%d): %s", kind, len(only_a), strings.join(only_a[:], " "))
		}
		if len(only_b) > 0 {
			fmt.printfln("%s only in vendor (%d): %s", kind, len(only_b), strings.join(only_b[:], " "))
		}
	}
	report_only("proc", sorted_keys(ours.procs), sorted_keys(vendor.procs))
	report_only("struct", sorted_keys(ours.structs), sorted_keys(vendor.structs))
	report_only("enum", sorted_keys(ours.enums), sorted_keys(vendor.enums))
	report_only("const", sorted_keys(ours.consts), sorted_keys(vendor.consts))
	report_only("type", sorted_keys(ours.types), sorted_keys(vendor.types))

	idiom, abi, suggestions: [dynamic]string
	add :: proc(idiom, abi: ^[dynamic]string, kind, line: string) {
		append(idiom if kind == "idiom" else abi, line)
	}

	for name in sorted_keys(ours.procs) {
		b, in_vendor := vendor.procs[name]
		if !in_vendor {
			continue
		}
		a := ours.procs[name]
		if len(a.params) != len(b.params) {
			append(&abi, fmt.aprintf("proc %s: %d parameters, vendor %d", name, len(a.params), len(b.params)))
			continue
		}
		for pa, i in a.params {
			pb := b.params[i]
			if kind := classify(ours, vendor, pa.type, pb.type); kind != "" {
				add(&idiom, &abi, kind, fmt.aprintf("proc %s(%s): %s, vendor %s", name, pa.name, pa.type, pb.type))
				if kind == "idiom" {
					c_param := strings.trim_right(pa.name, "_")
					if strings.has_prefix(pb.type, "#by_ptr ") {
						append(&suggestions, fmt.aprintf("byptr SDL_%s.%s", name, c_param))
					} else {
						append(&suggestions, fmt.aprintf("param SDL_%s.%s %s", name, c_param, pb.type))
					}
				}
			}
		}
		ra := a.ret if a.ret != "" else "void"
		rb := b.ret if b.ret != "" else "void"
		if kind := classify(ours, vendor, ra, rb); kind != "" {
			add(&idiom, &abi, kind, fmt.aprintf("proc %s: returns %s, vendor %s", name, a.ret if a.ret != "" else "nothing",
				b.ret if b.ret != "" else "nothing"))
			if kind == "idiom" {
				append(&suggestions, fmt.aprintf("param SDL_%s.return %s", name, b.ret))
			}
		}
	}

	for name in sorted_keys(ours.structs) {
		b, in_vendor := vendor.structs[name]
		if !in_vendor {
			continue
		}
		a := ours.structs[name]
		names_a, names_b: [dynamic]string
		for f in a.fields {
			append(&names_a, f.name)
		}
		for f in b.fields {
			append(&names_b, f.name)
		}
		if !slice.equal(names_a[:], names_b[:]) {
			append(&abi, fmt.aprintf("struct %s: fields %v, vendor %v", name, names_a[:], names_b[:]))
			continue
		}
		for x, i in a.fields {
			y := b.fields[i]
			if y.tag != "" && x.tag != y.tag {
				append(&idiom, fmt.aprintf("struct %s.%s: tag %s, vendor %s", name, x.name, x.tag, y.tag))
				append(&suggestions, fmt.aprintf("tag SDL_%s.%s %s", name, x.name, y.tag))
			}
			if strings.has_prefix(x.type, "struct") || strings.has_prefix(y.type, "struct") {
				continue // records declared in place: compared by hand
			}
			if kind := classify(ours, vendor, x.type, y.type); kind != "" {
				add(&idiom, &abi, kind, fmt.aprintf("struct %s.%s: %s, vendor %s", name, x.name, x.type, y.type))
				if kind == "idiom" {
					append(&suggestions, fmt.aprintf("field SDL_%s.%s %s", name, x.name, y.type))
				}
			}
		}
	}

	for name in sorted_keys(ours.enums) {
		b, in_vendor := vendor.enums[name]
		if !in_vendor {
			continue
		}
		a := ours.enums[name]
		if a.backing != b.backing {
			kind := "idiom" if resolve(ours, a.backing) == resolve(vendor, b.backing) else "ABI"
			add(&idiom, &abi, kind, fmt.aprintf("enum %s: %s, vendor %s", name, a.backing, b.backing))
			append(&suggestions, fmt.aprintf("enum SDL_%s %s", name, b.backing))
		}
		only_a, only_b: [dynamic]string
		for m in a.members {
			if !slice.contains(b.members[:], m) {
				append(&only_a, m)
			}
		}
		for m in b.members {
			if !slice.contains(a.members[:], m) {
				append(&only_b, m)
			}
		}
		if len(only_a) > 0 || len(only_b) > 0 {
			fmt.printfln("enum %s members: only ours %v, only vendor %v", name, only_a[:], only_b[:])
		}
	}

	for name in sorted_keys(ours.consts) {
		b, in_vendor := vendor.consts[name]
		if !in_vendor {
			continue
		}
		if a := ours.consts[name]; a != b && !numbers_equal(a, b) {
			fmt.printfln("const %s: %s, vendor %s", name, a, b)
		}
	}
	for name in sorted_keys(ours.types) {
		b, in_vendor := vendor.types[name]
		if !in_vendor {
			continue
		}
		if a := ours.types[name]; a != b {
			fmt.printfln("type %s: %s, vendor %s", name, a, b)
		}
	}

	fmt.printfln("\n%d ABI differences:", len(abi))
	for line in abi {
		fmt.printfln("  %s", line)
	}
	fmt.printfln("\n%d idiom differences:", len(idiom))
	for line in idiom {
		fmt.printfln("  %s", line)
	}
	if suggest {
		fmt.println("\n# suggested overrides (idiom differences)")
		for line in suggestions {
			fmt.println(line)
		}
	}
}

sorted_keys :: proc(m: map[string]$T) -> []string {
	keys, _ := slice.map_keys(m)
	slice.sort(keys)
	return keys
}

numbers_equal :: proc(a, b: string) -> bool {
	if x, x_ok := strconv.parse_i128(a); x_ok {
		y, y_ok := strconv.parse_i128(b)
		return y_ok && x == y
	}
	x, x_ok := strconv.parse_f64(a)
	y, y_ok := strconv.parse_f64(b)
	return x_ok && y_ok && x == y
}
