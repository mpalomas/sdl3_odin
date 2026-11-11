package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

//--------//
// MACROS //
//--------//

// Object-like macros that are compiler or build plumbing, not API. A star matches anything, as .* does.
@(private="file")
PLUMBING := []string{
	"SDL_*_h_", "SDL_DECLSPEC", "SDLCALL", "SDL_FORCE_INLINE", "SDL_INLINE", "SDL_NODISCARD", "SDL_MALLOC",
	"SDL_DEPRECATED", "SDL_UNUSED", "SDL_FALLTHROUGH", "SDL_NORETURN", "SDL_ANALYZER_NORETURN", "SDL_HAS_BUILTIN",
	"SDL_MAIN_*", "SDL_PRINTF_FORMAT_STRING", "SDL_SCANF_FORMAT_STRING", "SDL_WPRINTF_VARARG_FUNC",
	"SDL_DISABLE_*", "SDL_ASSERT_LEVEL", "SDL_TriggerBreakpoint", "SDL_FUNCTION", "SDL_FILE", "SDL_LINE",
	"SDL_NULL_WHILE_LOOP_CONDITION", "SDL_BeginThreadFunction", "SDL_EndThreadFunction",
	"SDL_THREAD_ANNOTATION_ATTRIBUTE__", "SDL_CAPABILITY*", "SDL_*_CAPABILITY", "SDL_ACQUIRE*", "SDL_RELEASE*",
	"SDL_TRY_ACQUIRE*", "SDL_EXCLUDES", "SDL_ASSERT_CAPABILITY", "SDL_RETURN_CAPABILITY", "SDL_NO_THREAD_SAFETY_ANALYSIS",
	"SDL_SCOPED_CAPABILITY", "SDL_GUARDED_BY", "SDL_PT_GUARDED_BY", "SDL_ACQUIRED_BEFORE", "SDL_ACQUIRED_AFTER",
	"SDL_REQUIRES*", "SDL_WIKI_DOCUMENTATION_SECTION", "SDL_ALIGNED", "SDL_PLATFORM_*", "SDL_BYTEORDER",
	"SDL_FLOATWORDORDER", "SDL_LIL_ENDIAN", "SDL_BIG_ENDIAN", "SDL_HAS_FALLTHROUGH", "SDL_SIZE_MAX", "SDL_OUT_*",
	"SDL_IN_*", "SDL_INOUT_*", "SDL_ALLOC_SIZE*", "SDL_PRINTF_VARARG_FUNC*", "SDL_SCANF_VARARG_FUNC*",
	"SDL_WSCANF_VARARG_FUNC", "SDL_ENABLE_OLD_NAMES", "SDL_COMPILE_TIME_ASSERT", "SDL_INIT_INTERFACE", "SDL_PRI*",
	"SDL_SCN*", "SDL_ASSERT_FILE", "SDL_assert*",
	"SDL_ELF_NOTE_*", // dlopen annotations, only on ELF platforms
}

@(private="file")
is_plumbing :: proc(name: string) -> bool {
	// SDL_[a-z].*: lowercase names are functions in disguise (SDL_abs, SDL_zero...).
	if len(name) > 4 && strings.has_prefix(name, "SDL_") && name[4] >= 'a' && name[4] <= 'z' {
		return true
	}
	for pattern in PLUMBING {
		before, _, after := strings.partition(pattern, "*")
		if before == pattern {
			if name == pattern {
				return true
			}
		} else if len(name) >= len(before) + len(after) && strings.has_prefix(name, before) && strings.has_suffix(name, after) {
			return true
		}
	}
	return false
}

is_sdl_name :: proc(name: string) -> bool {
	return strings.has_prefix(name, "SDL_") || strings.has_prefix(name, "SDLK_")
}

// macro_candidates returns the object-like SDL macros of a header that could be constants: the first definition of
// each (others are in other platforms' branches), in order.
macro_candidates :: proc(macros: []Macro) -> []Macro {
	out: [dynamic]Macro
	seen: map[string]bool
	for macro in macros {
		if macro.has_params || !is_sdl_name(macro.name) || is_plumbing(macro.name) || macro.body == "" || seen[macro.name] {
			continue
		}
		seen[macro.name] = true
		append(&out, macro)
	}
	return out[:]
}

@(private="file")
PRINTER :: `
#include <stdio.h>
#include <string.h>
static void print_string(const char *name, const char *value) {
	printf("%s\ts\t", name);
	for (const char *c = value; *c; c++) {
		if (*c == '\\' || *c == '\t' || *c == '\n') printf("\\%c", *c == '\t' ? 't' : *c == '\n' ? 'n' : '\\');
		else putchar(*c);
	}
	putchar('\n');
}
static void print_i32(const char *name, long long value) { printf("%s\ti32\t%lld\n", name, value); }
static void print_u32(const char *name, unsigned long long value) { printf("%s\tu32\t%llu\n", name, value); }
static void print_i64(const char *name, long long value) { printf("%s\ti64\t%lld\n", name, value); }
static void print_u64(const char *name, unsigned long long value) { printf("%s\tu64\t%llu\n", name, value); }
static void print_f32(const char *name, double value) { printf("%s\tf32\t%.9g\n", name, value); }
static void print_f64(const char *name, double value) { printf("%s\tf64\t%.17g\n", name, value); }
#define PRINT(name) _Generic((name), \
	char *: print_string, const char *: print_string, \
	char: print_i32, signed char: print_i32, unsigned char: print_u32, short: print_i32, unsigned short: print_u32, \
	int: print_i32, unsigned int: print_u32, long: print_i64, unsigned long: print_u64, \
	long long: print_i64, unsigned long long: print_u64, float: print_f32, double: print_f64)(#name, name)
`

// macro_program writes a C program that prints each macro's name, type and value, and the line its first PRINT is on.
@(private="file")
macro_program :: proc(names: []string) -> (program: string, first_line: int) {
	head := strings.join({TRANSLATION_UNIT, PRINTER, "int main(void) {"}, "\n")
	first_line = strings.count(head, "\n") + 2
	b := strings.builder_make()
	strings.write_string(&b, head)
	for name in names {
		fmt.sbprintf(&b, "\n\tPRINT(%s);", name)
	}
	strings.write_string(&b, "\n\treturn 0;\n}\n")
	return strings.to_string(b), first_line
}

Macro_Value :: struct {
	kind:  string, // "s", "i32", "u32", "i64", "u64", "f32", "f64"
	value: string, // numbers as printed: decimal, or %.9g/%.17g for floats
}

// evaluate_macros compiles and runs the macro printer with a platform's defines, dropping the macros that don't compile
// as constants.
evaluate_macros :: proc(names: []string, defines: []string) -> map[string]Macro_Value {
	names := slice.clone_to_dynamic(names)
	source, _ := filepath.join({work_dir, "macros.c"})
	binary, _ := filepath.join({work_dir, "macros"})
	stub, _ := filepath.join({work_dir, "stub"})
	compiled := false
	for _ in 0 ..< 10 {
		program, first_line := macro_program(names[:])
		write_text(source, program)
		command: [dynamic]string
		append(&command, "clang", "-w", "-ferror-limit=0", "-I", include_dir, "-I", stub)
		append(&command, ..defines)
		append(&command, "-o", binary, source)
		state, _, stderr := run(command[:])
		if state.exit_code == 0 {
			compiled = true
			break
		}
		bad: map[string]bool
		for line in strings.split_lines(string(stderr)) {
			// <path>/macros.c:<line>:<col>: error
			at := strings.index(line, "macros.c:")
			if at < 0 {
				continue
			}
			rest := line[at + len("macros.c:"):]
			number_end := 0
			for number_end < len(rest) && rest[number_end] >= '0' && rest[number_end] <= '9' {
				number_end += 1
			}
			after := rest[number_end:]
			col_end := 1
			for col_end < len(after) && after[col_end] >= '0' && after[col_end] <= '9' {
				col_end += 1
			}
			if number_end == 0 || col_end == 1 || !strings.has_prefix(after, ":") || !strings.has_prefix(after[col_end:], ": error") {
				continue
			}
			number, _ := strconv.parse_int(rest[:number_end])
			if index := number - first_line; index >= 0 && index < len(names) {
				bad[names[index]] = true
			}
		}
		if len(bad) == 0 {
			die("the macro printer doesn't compile:\n%s", string(stderr[:min(len(stderr), 3000)]))
		}
		kept: [dynamic]string
		for name in names {
			if !bad[name] {
				append(&kept, name)
			}
		}
		names = kept
	}
	if !compiled {
		die("the macro printer still doesn't compile after 10 rounds")
	}
	state, stdout, _ := run({binary})
	if state.exit_code != 0 {
		die("the macro printer failed")
	}
	values: map[string]Macro_Value
	for line in strings.split(string(stdout), "\n") {
		if line == "" {
			continue
		}
		parts := strings.split_n(line, "\t", 3)
		value := parts[2]
		if parts[1] == "s" {
			value = unescape(value)
		}
		values[strings.clone(parts[0])] = Macro_Value{strings.clone(parts[1]), strings.clone(value)}
	}
	return values
}

// unescape undoes the printer's escapes: \t, \n, and a backslash before anything else.
@(private="file")
unescape :: proc(s: string) -> string {
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 't': strings.write_byte(&b, '\t')
			case 'n': strings.write_byte(&b, '\n')
			case:     strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// run runs a command and returns its exit state and output.
run :: proc(command: []string) -> (state: os.Process_State, stdout, stderr: []u8) {
	err: os.Error
	state, stdout, stderr, err = os.process_exec({command = command}, context.allocator)
	if err != nil {
		die("cannot run %s: %v", command[0], err)
	}
	return
}
