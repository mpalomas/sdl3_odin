package main

import "core:strings"

//---------//
// HEADERS //
//---------//

Macro :: struct {
	name:       string,
	line:       i64,
	params:     string, // "(a, b)" with the parentheses; "" for an object-like macro
	has_params: bool,
	body:       string,
	guard:      string,
}

Header_Scan :: struct {
	macros:     [dynamic]Macro,
	conditions: map[i64]string, // the platform conditions in effect at each logical line
}

Logical_Line :: struct {
	number: i64,
	text:   string,
}

// logical_lines splits a header into lines with backslash continuations joined and comments removed. A block comment
// becomes spaces as long as its first line, and its newlines, so line numbers stay; strings aren't looked at.
logical_lines :: proc(text: string) -> []Logical_Line {
	b := strings.builder_make()
	pos := 0
	for pos < len(text) {
		if strings.has_prefix(text[pos:], "/*") {
			if end := strings.index(text[pos + 2:], "*/"); end >= 0 {
				comment := text[pos:pos + 2 + end + 2]
				first_line := comment
				if newline := strings.index_byte(comment, '\n'); newline >= 0 {
					first_line = comment[:newline]
				}
				for _ in 0 ..< len(first_line) {
					strings.write_byte(&b, ' ')
				}
				for _ in 0 ..< strings.count(comment, "\n") {
					strings.write_byte(&b, '\n')
				}
				pos += len(comment)
				continue
			}
		}
		strings.write_byte(&b, text[pos])
		pos += 1
	}
	lines := strings.split(strings.to_string(b), "\n")
	out: [dynamic]Logical_Line
	number := 0
	for number < len(lines) {
		start := number + 1
		line := lines[number]
		for strings.has_suffix(line, "\\") && number + 1 < len(lines) {
			number += 1
			line = strings.concatenate({line[:len(line) - 1], " ", lines[number]})
		}
		number += 1
		if cut := strings.index(line, "//"); cut >= 0 {
			line = line[:cut]
		}
		append(&out, Logical_Line{i64(start), line})
	}
	return out[:]
}

// scan_header returns a header's #define lines and the SDL_PLATFORM_* conditions in effect on each line.
scan_header :: proc(path: string) -> Header_Scan {
	scan: Header_Scan
	stack: [dynamic][dynamic]string // the branches of each open #if chain
	for line in logical_lines(read_text(path)) {
		if directive, after, ok := match_conditional(line.text); ok {
			rest := strings.trim_space(after)
			switch directive {
			case "if", "ifdef", "ifndef":
				text := rest
				if directive == "ifdef" {
					text = strings.concatenate({"defined(", rest, ")"})
				} else if directive == "ifndef" {
					text = strings.concatenate({"!defined(", rest, ")"})
				}
				branches: [dynamic]string
				append(&branches, text)
				append(&stack, branches)
			case "elif":
				if len(stack) > 0 {
					append(&stack[len(stack) - 1], rest)
				}
			case "else":
				if len(stack) > 0 {
					append(&stack[len(stack) - 1], "else")
				}
			case "endif":
				if len(stack) > 0 {
					pop(&stack)
				}
			}
		}
		platform: [dynamic]string
		for branches in stack {
			if strings.contains(strings.join(branches[:], " "), "SDL_PLATFORM_") {
				append(&platform, branch_condition(branches[:]))
			}
		}
		scan.conditions[line.number] = strings.join(platform[:], " && ")
		if macro, ok := match_define(line.text); ok {
			macro.line = line.number
			macro.guard = scan.conditions[line.number]
			append(&scan.macros, macro)
		}
	}
	return scan
}

// branch_condition is the condition of the current branch of an #if chain: its own, with the earlier ones false.
@(private="file")
branch_condition :: proc(branches: []string) -> string {
	parts: [dynamic]string
	for b in branches[:len(branches) - 1] {
		append(&parts, strings.concatenate({"!(", b, ")"}))
	}
	if current := branches[len(branches) - 1]; current != "else" {
		append(&parts, strings.concatenate({"(", current, ")"}))
	}
	return strings.join(parts[:], " && ")
}

// match_conditional matches `^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)$`.
@(private="file")
match_conditional :: proc(line: string) -> (directive, rest: string, ok: bool) {
	pos := skip_spaces(line, 0)
	if pos >= len(line) || line[pos] != '#' {
		return
	}
	pos = skip_spaces(line, pos + 1)
	end := pos
	for end < len(line) && is_identifier_byte(line[end]) {
		end += 1
	}
	switch line[pos:end] {
	case "if", "ifdef", "ifndef", "elif", "else", "endif":
		return line[pos:end], line[end:], true
	}
	return
}

// match_define matches `^\s*#\s*define\s+([A-Za-z_][A-Za-z_0-9]*)(\([^)]*\))?(.*)$`.
@(private="file")
match_define :: proc(line: string) -> (macro: Macro, ok: bool) {
	pos := skip_spaces(line, 0)
	if pos >= len(line) || line[pos] != '#' {
		return
	}
	pos = skip_spaces(line, pos + 1)
	if !strings.has_prefix(line[pos:], "define") {
		return
	}
	pos += len("define")
	after := skip_spaces(line, pos)
	if after == pos || after >= len(line) || !is_identifier_start(line[after]) {
		return
	}
	end := after
	for end < len(line) && is_identifier_byte(line[end]) {
		end += 1
	}
	macro.name = line[after:end]
	if end < len(line) && line[end] == '(' {
		if close := strings.index_byte(line[end:], ')'); close >= 0 {
			macro.params = line[end:end + close + 1]
			macro.has_params = true
			end += close + 1
		}
	}
	macro.body = strings.trim_space(line[end:])
	return macro, true
}

@(private="file")
skip_spaces :: proc(text: string, pos: int) -> int {
	p := pos
	for p < len(text) && is_space(text[p]) {
		p += 1
	}
	return p
}
