#!/usr/bin/env bash
# Builds the size-minimized SDL3 into lib/<os>-<arch>/: libSDL3.a (static) and libSDL3.so or libSDL3.dylib (shared). Linux and
# macOS; tools/build_sdl3.ps1 builds the Windows libraries.
#
#   tools/build_sdl3.sh [static|shared|all]      (all by default)
#
# The sources are SDL's release tarball, pinned in upstream/release.env: downloaded into build/ and checked against its SHA256,
# then patched with upstream/patches/*.patch if there are any. The options are upstream/sdl3_options.cmake. After configuring,
# the build's SDL_build_config.h is checked against upstream/sdl3_expected_<os>.txt, since CMake turns a feature off without
# failing when its dev package is missing.
#
# Environment:
#   JOBS                 parallel jobs (default: number of CPUs)
#   SDL3_ALLOW_MISSING   features of the expected list that may be missing, space separated, for a machine without some dev
#                        package (e.g. "HAVE_IBUS_IBUS_H"). Releases are built without it.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

die() {
	echo "build_sdl3: $*" >&2
	exit 1
}

case "$(uname -s)" in
Linux) OS=linux SHARED_FILE=libSDL3.so ;;
Darwin) OS=macos SHARED_FILE=libSDL3.dylib ;;
*) die "unsupported OS $(uname -s); on Windows use tools/build_sdl3.ps1" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) ARCH=x86_64 ;;
arm64 | aarch64) ARCH=arm64 ;;
*) die "unsupported architecture $(uname -m)" ;;
esac
PLATFORM="$OS-$ARCH"
LIB_DIR="lib/$PLATFORM"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

case "${1:-all}" in
static) LINKAGES="static" ;;
shared) LINKAGES="shared" ;;
all) LINKAGES="static shared" ;;
*) die "usage: tools/build_sdl3.sh [static|shared|all]" ;;
esac

SDL_VERSION="$(sed -n 's/^SDL_VERSION=//p' upstream/release.env)"
SDL_SHA256="$(sed -n 's/^SDL_SHA256=//p' upstream/release.env)"
[ -n "$SDL_VERSION" ] && [ -n "$SDL_SHA256" ] || die "upstream/release.env needs SDL_VERSION and SDL_SHA256"

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# SOURCES

TARBALL="build/SDL3-$SDL_VERSION.tar.gz"
SRC="build/SDL3-$SDL_VERSION"
mkdir -p build
if [ ! -f "$TARBALL" ]; then
	echo "==> downloading SDL $SDL_VERSION"
	curl -fsSL --retry 3 -o "$TARBALL.part" \
		"https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL3-$SDL_VERSION.tar.gz"
	mv "$TARBALL.part" "$TARBALL"
fi
[ "$(sha256 "$TARBALL")" = "$SDL_SHA256" ] || die "$TARBALL doesn't match SDL_SHA256 in upstream/release.env; delete it to download again"

# The patches are part of what the extracted tree is made from, so a change to them extracts it again.
PATCHES=()
if [ -d upstream/patches ]; then
	while IFS= read -r patch; do PATCHES+=("$patch"); done < <(find upstream/patches -name '*.patch' | sort)
fi
STAMP="$SDL_SHA256"
for patch in ${PATCHES[@]+"${PATCHES[@]}"}; do STAMP="$STAMP $(sha256 "$patch")"; done
if [ ! -f "$SRC/.sdl3_odin_stamp" ] || [ "$(cat "$SRC/.sdl3_odin_stamp")" != "$STAMP" ]; then
	echo "==> extracting $TARBALL"
	rm -rf "$SRC"
	tar -xzf "$TARBALL" -C build
	for patch in ${PATCHES[@]+"${PATCHES[@]}"}; do
		echo "==> applying $patch"
		patch -d "$SRC" -p1 --forward --silent <"$patch"
	done
	echo "$STAMP" >"$SRC/.sdl3_odin_stamp"
fi

# The bindings are generated from upstream/include, so it must be what we build.
diff -r -q "$SRC/include/SDL3" upstream/include/SDL3 >/dev/null ||
	die "upstream/include/SDL3 differs from SDL $SDL_VERSION's headers (diff -r $SRC/include/SDL3 upstream/include/SDL3)"

# CHECK

# check_features compares a build's SDL_build_config.h with upstream/sdl3_expected_<os>.txt.
check_features() {
	local config="$1" failed=0 line name want
	while IFS= read -r line; do
		case "$line" in "" | "#"*) continue ;; esac
		want="${line:0:1}" name="${line:1}"
		if grep -qE "^#define $name( |$)" "$config"; then
			[ "$want" = "-" ] && { echo "build_sdl3: $name is on, upstream/sdl3_expected_$OS.txt says off" >&2; failed=1; }
		elif [ "$want" = "+" ]; then
			if [[ " ${SDL3_ALLOW_MISSING:-} " == *" $name "* ]]; then
				echo "build_sdl3: warning: $name is missing (allowed by SDL3_ALLOW_MISSING)" >&2
			else
				echo "build_sdl3: $name is missing: is its dev package installed? (see $config)" >&2
				failed=1
			fi
		fi
	done <"upstream/sdl3_expected_$OS.txt"
	return "$failed"
}

# check_shared checks the shared library's name and that it only needs the C library.
check_shared() {
	local lib="$1"
	if [ "$OS" = linux ]; then
		local soname needed
		soname="$(readelf -d "$lib" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
		[ "$soname" = libSDL3.so ] || die "$lib has the SONAME '$soname', expected libSDL3.so"
		needed="$(readelf -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | grep -v -E '^(libc|libm)\.so\.6$' || true)"
		[ -z "$needed" ] || die "$lib needs more than libc and libm: $needed (SDL_DEPS_SHARED should dlopen them)"
	else
		local id
		id="$(otool -D "$lib" | tail -n 1)"
		[ "$id" = "@rpath/libSDL3.dylib" ] || die "$lib has the install name '$id', expected @rpath/libSDL3.dylib"
	fi
}

# BUILD

mkdir -p "$LIB_DIR"
for linkage in $LINKAGES; do
	dir="build/$PLATFORM-$linkage"
	echo "==> configuring $linkage in $dir"
	if [ "$linkage" = static ]; then shared=OFF static=ON; else shared=ON static=OFF; fi
	cmake -S "$SRC" -B "$dir" --fresh -G Ninja -C upstream/sdl3_options.cmake \
		-DSDL_SHARED="$shared" -DSDL_STATIC="$static" >"$dir.configure.log" 2>&1 ||
		{ tail -n 30 "$dir.configure.log" >&2; die "configure failed, see $dir.configure.log"; }
	config="$dir/include-config-minsizerel/build_config/SDL_build_config.h"
	# What the build has, for the log.
	grep -E '^#define SDL_(VIDEO_DRIVER|AUDIO_DRIVER|JOYSTICK|HAPTIC|SENSOR|VIDEO_OPENGL|VIDEO_VULKAN|VIDEO_METAL)[A-Z0-9_]* 1' "$config" |
		sed 's/^#define \([A-Z0-9_]*\).*/\1/' | tr '\n' ' ' || true
	echo
	check_features "$config" || die "the $linkage build lacks expected features (configure log: $dir.configure.log)"

	echo "==> building $linkage"
	cmake --build "$dir" -j "$JOBS" >"$dir.build.log" 2>&1 ||
		{ tail -n 30 "$dir.build.log" >&2; die "build failed, see $dir.build.log"; }

	if [ "$linkage" = static ]; then
		cp "$dir/libSDL3.a" "$LIB_DIR/libSDL3.a"
	else
		cp -L "$dir/$SHARED_FILE" "$LIB_DIR/$SHARED_FILE"
		if [ "$OS" = linux ]; then
			strip --strip-all "$LIB_DIR/$SHARED_FILE"
		else
			# Found through the program's rpath, under the name it's shipped with.
			install_name_tool -id @rpath/libSDL3.dylib "$LIB_DIR/$SHARED_FILE"
			strip -x "$LIB_DIR/$SHARED_FILE"
			codesign --force --sign - "$LIB_DIR/$SHARED_FILE"
		fi
		check_shared "$LIB_DIR/$SHARED_FILE"
	fi
done
cp upstream/LICENSE.txt "$LIB_DIR/SDL3_LICENSE.txt"
ls -l "$LIB_DIR"
