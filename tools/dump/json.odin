package main

import "core:fmt"
import "core:strings"

//------------------//
// ORDERED JSON OUT //
//------------------//

// The JSON sdl3_api.json is written from: objects keep their keys in the order they're set.
Json :: union {
	Json_Null,
	bool,
	i64,
	string,
	Json_Array,
	Json_Object,
}

Json_Null :: struct {}
Json_Array :: distinct [dynamic]Json
Json_Object :: distinct [dynamic]Json_Pair

Json_Pair :: struct {
	key:   string,
	value: Json,
}

// set sets a key, in place if the object has it, else at the end.
set :: proc(object: ^Json_Object, key: string, value: Json) {
	for &pair in object {
		if pair.key == key {
			pair.value = value
			return
		}
	}
	append(object, Json_Pair{key, value})
}

get :: proc(object: Json_Object, key: string) -> (value: Json, ok: bool) {
	for pair in object {
		if pair.key == key {
			return pair.value, true
		}
	}
	return nil, false
}

get_string :: proc(object: Json_Object, key: string) -> string {
	value, _ := get(object, key)
	s, _ := value.(string)
	return s
}

get_int :: proc(object: Json_Object, key: string) -> i64 {
	value, _ := get(object, key)
	n, _ := value.(i64)
	return n
}

get_bool :: proc(object: Json_Object, key: string) -> bool {
	value, _ := get(object, key)
	b, _ := value.(bool)
	return b
}

// object builds an object from key/value pairs: object("t", "ptr", "to", to, "const", true).
object :: proc(pairs: ..Json) -> Json_Object {
	o: Json_Object
	for i := 0; i + 1 < len(pairs); i += 2 {
		append(&o, Json_Pair{pairs[i].(string), pairs[i + 1]})
	}
	return o
}

// copy_object is a shallow copy, like Python's dict(d).
copy_object :: proc(o: Json_Object) -> Json_Object {
	out := make(Json_Object, len(o))
	copy(out[:], o[:])
	return out
}

// write_json writes a value the way Python's json.dump(value, indent=1) does, with ASCII escapes.
write_json :: proc(b: ^strings.Builder, value: Json, level := 0) {
	switch v in value {
	case Json_Null:
		strings.write_string(b, "null")
	case bool:
		strings.write_string(b, "true" if v else "false")
	case i64:
		fmt.sbprintf(b, "%d", v)
	case string:
		write_json_string(b, v)
	case Json_Array:
		if len(v) == 0 {
			strings.write_string(b, "[]")
			return
		}
		strings.write_string(b, "[")
		for item, i in v {
			strings.write_string(b, "," if i > 0 else "")
			write_newline(b, level + 1)
			write_json(b, item, level + 1)
		}
		write_newline(b, level)
		strings.write_string(b, "]")
	case Json_Object:
		if len(v) == 0 {
			strings.write_string(b, "{}")
			return
		}
		strings.write_string(b, "{")
		for pair, i in v {
			strings.write_string(b, "," if i > 0 else "")
			write_newline(b, level + 1)
			write_json_string(b, pair.key)
			strings.write_string(b, ": ")
			write_json(b, pair.value, level + 1)
		}
		write_newline(b, level)
		strings.write_string(b, "}")
	}
}

@(private="file")
write_newline :: proc(b: ^strings.Builder, level: int) {
	strings.write_byte(b, '\n')
	for _ in 0 ..< level {
		strings.write_byte(b, ' ')
	}
}

@(private="file")
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case '\b': strings.write_string(b, `\b`)
		case '\f': strings.write_string(b, `\f`)
		case:
			if r < 0x20 || r > 0x7f { // Python leaves DEL (0x7f) as it is
				if r > 0xffff {
					// A surrogate pair, as Python writes characters outside the BMP.
					c := r - 0x10000
					fmt.sbprintf(b, "\\u%04x\\u%04x", 0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff))
				} else {
					fmt.sbprintf(b, "\\u%04x", r)
				}
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}
