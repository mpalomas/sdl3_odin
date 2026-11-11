package sdl3

// SDL's function-like macros and the inline functions of its headers, which tools/gen can't bind: written by hand, with
// vendor:sdl3's names and signatures.

import "core:c"

//---------//
// VERSION //
//---------//

@(require_results)
VERSIONNUM :: #force_inline proc "contextless" (major, minor, patch: c.int) -> c.int {
	return major * 1000000 + minor * 1000 + patch
}

@(require_results)
VERSIONNUM_MAJOR :: #force_inline proc "contextless" (version: c.int) -> c.int { return version / 1000000 }
@(require_results)
VERSIONNUM_MINOR :: #force_inline proc "contextless" (version: c.int) -> c.int { return (version / 1000) % 1000 }
@(require_results)
VERSIONNUM_MICRO :: #force_inline proc "contextless" (version: c.int) -> c.int { return version % 1000 }

@(require_results)
VERSION_ATLEAST :: #force_inline proc "contextless" (major, minor, patch: c.int) -> bool {
	return VERSION >= VERSIONNUM(major, minor, patch)
}

//--------//
// STDINC //
//--------//

@(require_results)
FOURCC :: #force_inline proc "contextless" (#any_int A, B, C, D: u8) -> u32 {
	return u32(A) << 0 | u32(B) << 8 | u32(C) << 16 | u32(D) << 24
}

// INIT_INTERFACE zeroes an interface struct (SDL_IOStreamInterface, SDL_VirtualJoystickDesc...) and sets its version
// to its size, as SDL_INIT_INTERFACE does.
INIT_INTERFACE :: proc "contextless" (iface: ^$T) {
	iface^ = {}
	iface.version = size_of(T)
}

//-------//
// ERROR //
//-------//

Unsupported :: proc "c" () -> bool { return SetError("That operation is not supported") }
InvalidParamError :: proc "c" (param: cstring) -> bool { return SetError("Parameter '%s' is invalid", param) }

//--------//
// THREAD //
//--------//

// SDL_CreateThread is a macro that passes the C runtime's thread functions on Windows. Passing none is fine: SDL then uses
// CreateThread, which is what a static C runtime (as in sdl3_odin's libraries) wants anyway.
@(require_results)
CreateThread :: proc "c" (fn: ThreadFunction, name: cstring, data: rawptr) -> ^Thread {
	return CreateThreadRuntime(fn, name, data, nil, nil)
}

@(require_results)
CreateThreadWithProperties :: proc "c" (props: PropertiesID) -> ^Thread {
	return CreateThreadWithPropertiesRuntime(props, nil, nil)
}

//----------//
// KEYBOARD //
//----------//

@(require_results)
SCANCODE_TO_KEYCODE :: #force_inline proc "contextless" (X: Scancode) -> Keycode {
	return Keycode(X) | K_SCANCODE_MASK
}

//-------//
// MOUSE //
//-------//

@(require_results)
BUTTON_MASK :: #force_inline proc "contextless" (#any_int button: c.int) -> MouseButtonFlags {
	return transmute(MouseButtonFlags)(Uint32(1) << Uint32(button - 1))
}

//-------//
// AUDIO //
//-------//

@(require_results)
DEFINE_AUDIO_FORMAT :: #force_inline proc "contextless" (signed, bigendian, flt, size: Uint16) -> Uint16 {
	return (signed << 15) | (bigendian << 12) | (flt << 8) | (size & AUDIO_MASK_BITSIZE)
}

@(require_results)
AUDIO_BITSIZE :: #force_inline proc "contextless" (x: AudioFormat) -> Uint16 { return Uint16(x) & AUDIO_MASK_BITSIZE }
@(require_results)
AUDIO_BYTESIZE :: #force_inline proc "contextless" (x: AudioFormat) -> Uint16 { return AUDIO_BITSIZE(x) / 8 }
@(require_results)
AUDIO_ISFLOAT :: #force_inline proc "contextless" (x: AudioFormat) -> bool { return Uint16(x) & AUDIO_MASK_FLOAT != 0 }
@(require_results)
AUDIO_ISBIGENDIAN :: #force_inline proc "contextless" (x: AudioFormat) -> bool { return Uint16(x) & AUDIO_MASK_BIG_ENDIAN != 0 }
@(require_results)
AUDIO_ISLITTLEENDIAN :: #force_inline proc "contextless" (x: AudioFormat) -> bool { return !AUDIO_ISBIGENDIAN(x) }
@(require_results)
AUDIO_ISSIGNED :: #force_inline proc "contextless" (x: AudioFormat) -> bool { return Uint16(x) & AUDIO_MASK_SIGNED != 0 }
@(require_results)
AUDIO_ISINT :: #force_inline proc "contextless" (x: AudioFormat) -> bool { return !AUDIO_ISFLOAT(x) }
@(require_results)
AUDIO_ISUNSIGNED :: #force_inline proc "contextless" (x: AudioFormat) -> bool { return !AUDIO_ISSIGNED(x) }

@(require_results)
AUDIO_FRAMESIZE :: #force_inline proc "contextless" (x: AudioSpec) -> c.int {
	return c.int(AUDIO_BYTESIZE(x.format)) * x.channels
}

//--------//
// PIXELS //
//--------//

@(require_results)
DEFINE_PIXELFOURCC :: #force_inline proc "contextless" (#any_int A, B, C, D: u8) -> Uint32 {
	return FOURCC(A, B, C, D)
}

@(require_results)
DEFINE_PIXELFORMAT :: #force_inline proc "contextless" (type: PixelType, order: PackedOrder, layout: PackedLayout,
	bits, bytes: Uint32) -> PixelFormat {
	return PixelFormat((1 << 28) | (Uint32(type) << 24) | (Uint32(order) << 20) | (Uint32(layout) << 16) | (bits << 8) |
		(bytes << 0))
}

@(require_results)
PIXELFLAG :: #force_inline proc "contextless" (format: PixelFormat) -> Uint32 { return (Uint32(format) >> 28) & 0x0F }
@(require_results)
PIXELTYPE :: #force_inline proc "contextless" (format: PixelFormat) -> PixelType {
	return PixelType((Uint32(format) >> 24) & 0x0F)
}
@(require_results)
PIXELORDER :: #force_inline proc "contextless" (format: PixelFormat) -> PackedOrder {
	return PackedOrder((Uint32(format) >> 20) & 0x0F)
}
@(require_results)
PIXELARRAYORDER :: #force_inline proc "contextless" (format: PixelFormat) -> ArrayOrder {
	return ArrayOrder((Uint32(format) >> 20) & 0x0F)
}
@(require_results)
PIXELLAYOUT :: #force_inline proc "contextless" (format: PixelFormat) -> PackedLayout {
	return PackedLayout((Uint32(format) >> 16) & 0x0F)
}

@(require_results)
ISPIXELFORMAT_FOURCC :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	return format != .UNKNOWN && PIXELFLAG(format) != 1
}

@(require_results)
BITSPERPIXEL :: #force_inline proc "contextless" (format: PixelFormat) -> Uint32 {
	return 0 if ISPIXELFORMAT_FOURCC(format) else (Uint32(format) >> 8) & 0xFF
}

@(require_results)
BYTESPERPIXEL :: #force_inline proc "contextless" (format: PixelFormat) -> Uint32 {
	if ISPIXELFORMAT_FOURCC(format) {
		#partial switch format {
		case .YUY2, .UYVY, .YVYU, .P010:
			return 2
		}
		return 1
	}
	return Uint32(format) & 0xFF
}

@(require_results)
ISPIXELFORMAT_INDEXED :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	#partial switch PIXELTYPE(format) {
	case .INDEX1, .INDEX2, .INDEX4, .INDEX8:
		return !ISPIXELFORMAT_FOURCC(format)
	}
	return false
}

@(require_results)
ISPIXELFORMAT_PACKED :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	#partial switch PIXELTYPE(format) {
	case .PACKED8, .PACKED16, .PACKED32:
		return !ISPIXELFORMAT_FOURCC(format)
	}
	return false
}

@(require_results)
ISPIXELFORMAT_ARRAY :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	#partial switch PIXELTYPE(format) {
	case .ARRAYU8, .ARRAYU16, .ARRAYU32, .ARRAYF16, .ARRAYF32:
		return !ISPIXELFORMAT_FOURCC(format)
	}
	return false
}

@(require_results)
ISPIXELFORMAT_10BIT :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	return !ISPIXELFORMAT_FOURCC(format) && PIXELTYPE(format) == .PACKED32 && PIXELLAYOUT(format) == .LAYOUT_2101010
}

@(require_results)
ISPIXELFORMAT_FLOAT :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	#partial switch PIXELTYPE(format) {
	case .ARRAYF16, .ARRAYF32:
		return !ISPIXELFORMAT_FOURCC(format)
	}
	return false
}

@(require_results)
ISPIXELFORMAT_ALPHA :: #force_inline proc "contextless" (format: PixelFormat) -> bool {
	if ISPIXELFORMAT_PACKED(format) {
		#partial switch PIXELORDER(format) {
		case .ARGB, .RGBA, .ABGR, .BGRA:
			return true
		}
	}
	if ISPIXELFORMAT_ARRAY(format) {
		#partial switch PIXELARRAYORDER(format) {
		case .ARGB, .RGBA, .ABGR, .BGRA:
			return true
		}
	}
	return false
}

@(require_results)
DEFINE_COLORSPACE :: #force_inline proc "contextless" (type: ColorType, range: ColorRange, primaries: ColorPrimaries,
	transfer: TransferCharacteristics, matrix_: MatrixCoefficients, chroma: ChromaLocation) -> Colorspace {
	return Colorspace((Uint32(type) << 28) | (Uint32(range) << 24) | (Uint32(chroma) << 20) | (Uint32(primaries) << 10) |
		(Uint32(transfer) << 5) | (Uint32(matrix_) << 0))
}

@(require_results)
COLORSPACETYPE :: #force_inline proc "contextless" (cspace: Colorspace) -> ColorType {
	return ColorType((Uint32(cspace) >> 28) & 0x0F)
}
@(require_results)
COLORSPACERANGE :: #force_inline proc "contextless" (cspace: Colorspace) -> ColorRange {
	return ColorRange((Uint32(cspace) >> 24) & 0x0F)
}
@(require_results)
COLORSPACECHROMA :: #force_inline proc "contextless" (cspace: Colorspace) -> ChromaLocation {
	return ChromaLocation((Uint32(cspace) >> 20) & 0x0F)
}
@(require_results)
COLORSPACEPRIMARIES :: #force_inline proc "contextless" (cspace: Colorspace) -> ColorPrimaries {
	return ColorPrimaries((Uint32(cspace) >> 10) & 0x1F)
}
@(require_results)
COLORSPACETRANSFER :: #force_inline proc "contextless" (cspace: Colorspace) -> TransferCharacteristics {
	return TransferCharacteristics((Uint32(cspace) >> 5) & 0x1F)
}
@(require_results)
COLORSPACEMATRIX :: #force_inline proc "contextless" (cspace: Colorspace) -> MatrixCoefficients {
	return MatrixCoefficients(Uint32(cspace) & 0x1F)
}
@(require_results)
ISCOLORSPACE_MATRIX_BT601 :: #force_inline proc "contextless" (cspace: Colorspace) -> bool {
	return COLORSPACEMATRIX(cspace) == .BT601 || COLORSPACEMATRIX(cspace) == .BT470BG
}
@(require_results)
ISCOLORSPACE_MATRIX_BT709 :: #force_inline proc "contextless" (cspace: Colorspace) -> bool {
	return COLORSPACEMATRIX(cspace) == .BT709
}
@(require_results)
ISCOLORSPACE_MATRIX_BT2020_NCL :: #force_inline proc "contextless" (cspace: Colorspace) -> bool {
	return COLORSPACEMATRIX(cspace) == .BT2020_NCL
}
@(require_results)
ISCOLORSPACE_LIMITED_RANGE :: #force_inline proc "contextless" (cspace: Colorspace) -> bool {
	return COLORSPACERANGE(cspace) != .FULL
}
@(require_results)
ISCOLORSPACE_FULL_RANGE :: #force_inline proc "contextless" (cspace: Colorspace) -> bool {
	return COLORSPACERANGE(cspace) == .FULL
}

//------//
// RECT //
//------//

RectToFRect :: #force_inline proc "contextless" (rect: Rect, frect: ^FRect) {
	frect^ = {f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
}

@(require_results)
PointInRect :: #force_inline proc "contextless" (p: Point, r: Rect) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

@(require_results)
PointInRectFloat :: #force_inline proc "contextless" (p: FPoint, r: FRect) -> bool {
	return p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
}

@(require_results)
RectEmpty :: #force_inline proc "contextless" (r: Rect) -> bool { return r.w <= 0 || r.h <= 0 }

@(require_results)
RectEmptyFloat :: #force_inline proc "contextless" (r: FRect) -> bool { return r.w < 0 || r.h < 0 }

@(require_results)
RectsEqual :: #force_inline proc "contextless" (a, b: Rect) -> bool { return a == b }

@(require_results)
RectsEqualEpsilon :: #force_inline proc "contextless" (a, b: FRect, epsilon: f32) -> bool {
	return a == b || (abs(a.x - b.x) <= epsilon && abs(a.y - b.y) <= epsilon && abs(a.w - b.w) <= epsilon &&
		abs(a.h - b.h) <= epsilon)
}

@(require_results)
RectsEqualFloat :: #force_inline proc "contextless" (a, b: FRect) -> bool { return RectsEqualEpsilon(a, b, FLT_EPSILON) }

//---------//
// SURFACE //
//---------//

@(require_results)
MUSTLOCK :: #force_inline proc "contextless" (S: ^Surface) -> bool { return .LOCK_NEEDED in S.flags }

//-------//
// VIDEO //
//-------//

@(require_results)
WINDOWPOS_UNDEFINED_DISPLAY :: #force_inline proc "contextless" (X: c.int) -> c.int { return WINDOWPOS_UNDEFINED_MASK | X }
@(require_results)
WINDOWPOS_ISUNDEFINED :: #force_inline proc "contextless" (X: c.int) -> bool {
	return Uint32(X) & 0xFFFF0000 == WINDOWPOS_UNDEFINED_MASK
}
@(require_results)
WINDOWPOS_CENTERED_DISPLAY :: #force_inline proc "contextless" (X: c.int) -> c.int { return WINDOWPOS_CENTERED_MASK | X }
@(require_results)
WINDOWPOS_ISCENTERED :: #force_inline proc "contextless" (X: c.int) -> bool {
	return Uint32(X) & 0xFFFF0000 == WINDOWPOS_CENTERED_MASK
}

// gl_set_proc_address loads OpenGL procedures for vendor:OpenGL: gl.load_up_to(4, 5, sdl.gl_set_proc_address).
gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(^FunctionPointer)(p)^ = GL_GetProcAddress(name)
}
