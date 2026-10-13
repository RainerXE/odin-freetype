#!/usr/bin/env bash
# Build FreeType for Odin's own WASM target (js_wasm32) -- NO Emscripten.
# Output: freetype_wasm.o next to freetype.odin (git-ignored; the binding's JS branch imports it).
#
# Recipe: FreeType source (pinned tarball, SHA-256 checked) compiled with
#   clang --target=wasm32 --sysroot=$(odin root)vendor/libc-shim
# using a trimmed module list (ruishin-ftmodule.h) and a generated ftoption.h (no zlib/LZW/getenv),
# plus the setjmp/longjmp runtime from ../wasm-support (FreeType's cmap validator needs
# setjmp), merged into ONE object with `wasm-ld -r`. libc functions libc-shim lacks
# (strcat, ...) are NOT embedded: they come from wasm-support/libc_extras.o, linked once by
# src/web/webc.
#
#   CLANG=...  override compiler        WASM_LD=...  override wasm-ld
#   FT_SRC_CACHE=dir  where the tarball is kept (default: <repo>/artifacts/wasm-src)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE="$PWD"
SUPPORT="$HERE/../wasm-support"

FT_VERSION="2.14.3"
FT_SHA256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"
FT_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FT_VERSION}.tar.xz"
CACHE="${FT_SRC_CACHE:-$HERE/../../artifacts/wasm-src}"

find_clang() {
    if [ -n "${CLANG:-}" ]; then echo "$CLANG"; return; fi
    for c in /opt/homebrew/opt/llvm/bin/clang /usr/local/opt/llvm/bin/clang \
             "$(command -v clang-22 clang-21 clang-20 clang 2>/dev/null | head -1)"; do
        if [ -n "$c" ] && [ -x "$c" ] && "$c" --print-targets 2>/dev/null | grep -qi wasm32; then echo "$c"; return; fi
    done
    echo "ERROR: no clang with the wasm32 backend (Apple's has none; 'brew install llvm')" >&2; exit 1
}
find_wasm_ld() {
    if [ -n "${WASM_LD:-}" ]; then echo "$WASM_LD"; return; fi
    command -v wasm-ld || ls /opt/homebrew/bin/wasm-ld /usr/local/bin/wasm-ld 2>/dev/null | head -1 \
        || { echo "ERROR: wasm-ld not found ('brew install lld')" >&2; exit 1; }
}
CLANG="$(find_clang)"; WASM_LD="$(find_wasm_ld)"
SYSROOT="$(odin root)vendor/libc-shim"
[ -d "$SYSROOT" ] || { echo "ERROR: $SYSROOT missing (needs an Odin with vendor:libc-shim)"; exit 1; }

# --- source (downloaded into its own directory, verified before use) ---
mkdir -p "$CACHE"
TARBALL="$CACHE/freetype-${FT_VERSION}.tar.xz"
if [ ! -f "$TARBALL" ]; then
    echo "downloading FreeType ${FT_VERSION}"
    curl -sfL "$FT_URL" -o "$TARBALL"
fi
GOT="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
[ "$GOT" = "$FT_SHA256" ] || { echo "ERROR: FreeType tarball SHA-256 mismatch ($GOT)"; rm -f "$TARBALL"; exit 1; }
SRC="$CACHE/freetype-${FT_VERSION}"
[ -d "$SRC" ] || tar -xf "$TARBALL" -C "$CACHE"

# --- build in a temp dir ---
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT
# ftoption.h with the things we do not ship switched off
sed -e 's#^\#define FT_CONFIG_OPTION_ENVIRONMENT_PROPERTIES#/* & (RuiShin: off, no getenv) */#' \
    -e 's#^\#define FT_CONFIG_OPTION_USE_LZW#/* & (RuiShin: off) */#' \
    -e 's#^\#define FT_CONFIG_OPTION_USE_ZLIB#/* & (RuiShin: off) */#' \
    "$SRC/include/freetype/config/ftoption.h" > "$OBJ/ruishin-ftoption.h"
cp "$HERE/ruishin-ftmodule.h" "$OBJ/"

SJLJ=(-mexception-handling -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh)
CFLAGS=(-c -O2 --target=wasm32 --sysroot="$SYSROOT" -I"$SUPPORT/include" -I"$SRC/include" -I"$OBJ"
        "${SJLJ[@]}" -DFT2_BUILD_LIBRARY -DNDEBUG -Wno-everything
        '-DFT_CONFIG_MODULES_H=<ruishin-ftmodule.h>' '-DFT_CONFIG_OPTIONS_H=<ruishin-ftoption.h>')

# ftbase.c already includes ftlcdfil.c and most of base/
UNITS="base/ftbase base/ftinit base/ftsystem base/ftdebug base/ftbbox base/ftbitmap base/ftglyph
       base/ftmm base/ftsynth base/ftstroke base/ftfstype base/ftgasp base/fttype1
       truetype/truetype type1/type1 cff/cff sfnt/sfnt psaux/psaux pshinter/pshinter
       psnames/psmodule smooth/smooth raster/raster autofit/autofit sdf/sdf"
for u in $UNITS; do
    "$CLANG" "${CFLAGS[@]}" "$SRC/src/$u.c" -o "$OBJ/ft_$(echo "$u" | tr / _).o"
done
# runtime pieces: no libc-shim sysroot needed for these two, the third uses it
"$CLANG" -c -O1 --target=wasm32 -mexception-handling "$SUPPORT/sjlj_rt.c" -o "$OBJ/sjlj_rt.o"
"$CLANG" -c --target=wasm32 -mexception-handling "$SUPPORT/sjlj_tags.s" -o "$OBJ/sjlj_tags.o"

"$WASM_LD" -r "$OBJ"/*.o -o "$HERE/freetype_wasm.o"
echo "built $HERE/freetype_wasm.o ($(wc -c < "$HERE/freetype_wasm.o") bytes)"
