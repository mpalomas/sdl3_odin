package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

//---------//
// C TYPES //
//---------//

// parse_type parses a clang type string ("const char *const *", "void (*)(void *, int)", "Uint8[16]") into a type tree:
// {"t": "name", "name", "const"}, {"t": "ptr", "to", "const"}, {"t": "array", "of", "n"}, {"t": "func", "ret", "params",
// "variadic"}, {"t": "record", "tag": "struct"|"union"} (an anonymous record) or {"t": "enum", "name"}.
parse_type :: proc(text: string) -> Json_Object {
	p := Type_Parser{text = text, tokens = tokenize(text)}
	result := type_name(&p)
	if token, ok := peek(&p); ok {
		die("unexpected '%s' in type '%s'", token, text)
	}
	return result
}

@(private="file")
QUALIFIERS := []string{"const", "volatile", "restrict", "__restrict", "_Nonnull", "_Nullable", "_Null_unspecified"}
@(private="file")
BUILTIN_WORDS := []string{"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "bool"}

// tokenize splits a type string. Clang names anonymous records "union (unnamed at <path>:<line>:<col>)" (older ones
// "(unnamed union at ...)"); they become __anonymous__, resolved by the caller.
@(private="file")
tokenize :: proc(text: string) -> []string {
	cleaned := replace_anonymous(text)
	tokens: [dynamic]string
	pos := 0
	for pos < len(cleaned) {
		for pos < len(cleaned) && is_space(cleaned[pos]) {
			pos += 1
		}
		if pos >= len(cleaned) {
			break
		}
		rest := cleaned[pos:]
		n := 0
		switch {
		case strings.has_prefix(rest, "..."):
			n = 3
		case is_identifier_start(rest[0]):
			n = 1
			for n < len(rest) && is_identifier_byte(rest[n]) {
				n += 1
			}
		case rest[0] >= '0' && rest[0] <= '9':
			for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' {
				n += 1
			}
		case strings.index_byte("*()[],", rest[0]) >= 0:
			n = 1
		case:
			die("cannot tokenize type '%s' at '%s'", cleaned, rest)
		}
		append(&tokens, rest[:n])
		pos += n
	}
	return tokens[:]
}

@(private="file")
replace_anonymous :: proc(text: string) -> string {
	b := strings.builder_make()
	pos := 0
	for pos < len(text) {
		if text[pos] == '(' {
			rest := text[pos + 1:]
			word := "unnamed" if strings.has_prefix(rest, "unnamed") else "anonymous" if strings.has_prefix(rest, "anonymous") else ""
			if word != "" {
				after := rest[len(word):]
				for tag in ([]string{" struct", " union", " enum"}) {
					if strings.has_prefix(after, tag) {
						after = after[len(tag):]
						break
					}
				}
				if strings.has_prefix(after, " at ") {
					if close := strings.index_byte(after, ')'); close >= 0 {
						strings.write_string(&b, "__anonymous__")
						pos = len(text) - len(after) + close + 1
						continue
					}
				}
			}
		}
		strings.write_byte(&b, text[pos])
		pos += 1
	}
	return strings.to_string(b)
}

Type_Parser :: struct {
	text:   string,
	tokens: []string,
	pos:    int,
}

@(private="file")
peek :: proc(p: ^Type_Parser) -> (token: string, ok: bool) {
	if p.pos < len(p.tokens) {
		return p.tokens[p.pos], true
	}
	return "", false
}

@(private="file")
take :: proc(p: ^Type_Parser, expected := "") -> string {
	token, ok := peek(p)
	if !ok || (expected != "" && token != expected) {
		die("expected %s in type '%s', got %s", expected if expected != "" else "a token", p.text, token if ok else "None")
	}
	p.pos += 1
	return token
}

@(private="file")
type_name :: proc(p: ^Type_Parser) -> Json_Object {
	base := specifiers(p)
	declarator := abstract_declarator(p)
	return build(declarator, base)
}

@(private="file")
specifiers :: proc(p: ^Type_Parser) -> Json_Object {
	is_const := false
	words: [dynamic]string
	tag := ""
	for {
		token, ok := peek(p)
		if !ok {
			break
		}
		if slice.contains(QUALIFIERS, token) {
			take(p)
			is_const = is_const || token == "const"
		} else if token == "struct" || token == "union" || token == "enum" {
			take(p)
			tag = token
			append(&words, take(p))
		} else if slice.contains(BUILTIN_WORDS, token) {
			append(&words, take(p))
		} else if is_identifier_start(token[0]) && len(words) == 0 {
			append(&words, take(p)) // a typedef name
		} else {
			break
		}
	}
	if len(words) == 0 {
		die("no type in '%s'", p.text)
	}
	if words[0] == "__anonymous__" {
		if tag != "struct" && tag != "union" {
			die("anonymous %s in '%s'", tag, p.text)
		}
		return object("t", "record", "tag", tag, "const", is_const)
	}
	name := strings.join(words[:], " ")
	if tag == "enum" {
		return object("t", "enum", "name", name, "const", is_const)
	}
	if tag != "" {
		return object("t", "name", "name", name, "tag", tag, "const", is_const)
	}
	return object("t", "name", "name", name, "const", is_const)
}

// A declarator's pointers, arrays and functions, applied to a base type by build.
Declarator :: struct {
	pointers: [dynamic]bool, // const or not
	inner:    ^Declarator,
	suffixes: [dynamic]Suffix,
}

Suffix :: struct {
	is_func:  bool,
	count:    Json, // an array's: i64, or Json_Null when unbounded
	params:   Json_Array,
	variadic: bool,
}

@(private="file")
abstract_declarator :: proc(p: ^Type_Parser) -> ^Declarator {
	d := new(Declarator)
	for {
		token, _ := peek(p)
		if token != "*" {
			break
		}
		take(p)
		is_const := false
		for {
			qualifier, ok := peek(p)
			if !ok || !slice.contains(QUALIFIERS, qualifier) {
				break
			}
			is_const = is_const || take(p) == "const"
		}
		append(&d.pointers, is_const)
	}
	if token, _ := peek(p); token == "(" && is_grouping(p) {
		take(p, "(")
		d.inner = abstract_declarator(p)
		take(p, ")")
	}
	for {
		token, _ := peek(p)
		if token != "[" && token != "(" {
			break
		}
		if take(p) == "[" {
			count: Json = Json_Null{}
			if next, _ := peek(p); next != "]" {
				n, n_ok := strconv.parse_i64(take(p))
				if !n_ok {
					die("bad array size in '%s'", p.text)
				}
				count = n
			}
			take(p, "]")
			append(&d.suffixes, Suffix{count = count})
		} else {
			params, variadic := parameters(p)
			append(&d.suffixes, Suffix{is_func = true, params = params, variadic = variadic})
		}
	}
	return d
}

@(private="file")
build :: proc(d: ^Declarator, base: Json_Object) -> Json_Object {
	result := base
	for is_const in d.pointers {
		result = object("t", "ptr", "to", result, "const", is_const)
	}
	#reverse for suffix in d.suffixes {
		if suffix.is_func {
			result = object("t", "func", "ret", result, "params", suffix.params, "variadic", suffix.variadic)
		} else {
			result = object("t", "array", "of", result, "n", suffix.count)
		}
	}
	return build(d.inner, result) if d.inner != nil else result
}

// is_grouping tells whether "(" opens a grouping declarator like "(*)" (a pointer or another group follows) or a
// parameter list.
@(private="file")
is_grouping :: proc(p: ^Type_Parser) -> bool {
	if p.pos + 1 >= len(p.tokens) {
		return false
	}
	following := p.tokens[p.pos + 1]
	return following == "*" || following == "(" || following == "["
}

@(private="file")
parameters :: proc(p: ^Type_Parser) -> (params: Json_Array, variadic: bool) {
	if token, _ := peek(p); token == ")" {
		take(p)
		return
	}
	for {
		if token, _ := peek(p); token == "..." {
			take(p)
			variadic = true
		} else {
			param := type_name(p)
			next, _ := peek(p)
			is_void := get_string(param, "t") == "name" && get_string(param, "name") == "void" && next == ")" && len(params) == 0
			if !is_void {
				append(&params, param)
			}
		}
		if token, _ := peek(p); token == "," {
			take(p)
			continue
		}
		take(p, ")")
		return
	}
}

is_space :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\v' || ch == '\f'
}

is_identifier_start :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_identifier_byte :: proc(ch: u8) -> bool {
	return is_identifier_start(ch) || (ch >= '0' && ch <= '9')
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("dump: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
