#!/usr/bin/env bash
# Downloads the prebuilt SDL3 libraries that match the committed bindings into lib/<os>-<arch>/, from the GitHub release named
# in upstream/release.env (written by .github/workflows/build-sdl3.yml).
#
# Usage: tools/fetch_sdl3_libs.sh [PLATFORM...]
#   PLATFORM  linux-x86_64, macos-arm64 or windows-x86_64 (default: this machine's)
#
# Checks that the release was built from the committed SDL version and build options, and the downloads against the release's
# SHA256SUMS. Uses gh when it is installed and logged in, else curl.
# Environment:
#   SDL3_RELEASE_REPO  (default: mpalomas/sdl3_odin)
#   SDL3_RELEASE_URL   Base URL of the release downloads, for curl (default: the repository's releases)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLUG="${SDL3_RELEASE_REPO:-mpalomas/sdl3_odin}"
BASE_URL="${SDL3_RELEASE_URL:-https://github.com/$SLUG/releases/download}"
PIN="$REPO/upstream/release.env"

die() {
	echo "error: $*" >&2
	exit 1
}

TAG="$(sed -n 's/^RELEASE_TAG=//p' "$PIN")"
[[ -n "$TAG" ]] || die "no RELEASE_TAG in $PIN: no release has these sources yet. Build the libraries with tools/build_sdl3.sh"

if [[ $# -gt 0 ]]; then
	PLATFORMS=("$@")
else
	case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=macos ;;
	MINGW* | MSYS* | CYGWIN*) os=windows ;;
	*) die "unsupported OS $(uname -s)" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=x86_64 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) die "unsupported architecture $(uname -m)" ;;
	esac
	PLATFORMS=("$os-$arch")
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILES=(sources.env sdl3_options.cmake SHA256SUMS)
for platform in "${PLATFORMS[@]}"; do
	FILES+=("sdl3-$platform.tar.gz")
done

echo "Downloading ${FILES[*]} from release $TAG of $SLUG"
if [[ -z "${SDL3_RELEASE_URL:-}" ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
	patterns=()
	for f in "${FILES[@]}"; do
		patterns+=(--pattern "$f")
	done
	gh release download "$TAG" --repo "$SLUG" --dir "$TMP" "${patterns[@]}"
else
	for f in "${FILES[@]}"; do
		curl -fsSL --retry 3 -o "$TMP/$f" "$BASE_URL/$TAG/$f" || die "cannot download $f"
	done
fi
for f in "${FILES[@]}"; do
	[[ -f "$TMP/$f" ]] || die "release $TAG has no $f"
done

sha256() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d ' ' -f 1
	else
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}
for f in "${FILES[@]}"; do
	[[ "$f" != SHA256SUMS ]] || continue
	want="$(awk -v f="$f" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")"
	[[ -n "$want" ]] || die "$f is not in the release's SHA256SUMS"
	[[ "$(sha256 "$TMP/$f")" == "$want" ]] || die "checksum mismatch for $f"
done

# The libraries must be the SDL version and options the bindings were made for.
grep -E '^SDL_(VERSION|SHA256)=' "$PIN" | cmp -s - "$TMP/sources.env" ||
	die "upstream/release.env's SDL differs from release $TAG's: SDL was updated since. Build the libraries with tools/build_sdl3.sh"
cmp -s <(tr -d '\r' <"$REPO/upstream/sdl3_options.cmake") "$TMP/sdl3_options.cmake" ||
	die "upstream/sdl3_options.cmake differs from release $TAG's: the options changed since. Build the libraries with tools/build_sdl3.sh"

for platform in "${PLATFORMS[@]}"; do
	# The archives hold lib/<platform>/<libraries>.
	tar -xzf "$TMP/sdl3-$platform.tar.gz" -C "$REPO"
	echo "Extracted to lib/$platform/:"
	ls -lh "$REPO/lib/$platform/"
done
