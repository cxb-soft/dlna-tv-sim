#!/bin/bash
# 交叉编译 Windows x64 版 libass 及其依赖（freetype / fribidi / libunibreak / harfbuzz），
# 供自研播放核心在 Windows 上渲染 ASS/SRT 字幕。
#
# 产物：
#   $DLNA_DEPS_ROOT/win64/subs/{include,lib,bin,share/licenses}
#     include/ass/ass.h            libass 头文件
#     lib/libass.dll.a             导入库
#     bin/libass-9.dll             运行库（及其依赖 DLL）
#
# 为什么自己编而不是直接用 msys2 的预编译包：
#   msys2 的 mingw-w64-x86_64-libass 链接的是 fontconfig；libass 在 Windows 上
#   更好的字体来源是 DirectWrite（系统字体表，无需配置文件），编译期检测到
#   <windows.h> 就会启用。自己编还能只留需要的组件，并静态链接 libgcc，
#   避免额外分发 libgcc_s_seh-1.dll。
#
# 用法：
#   ./scripts/build-win-subs-deps.sh
#   FORCE=1 ./scripts/build-win-subs-deps.sh          # 重新编译
#   DLNA_DEPS_ROOT=/path/to/cache ./scripts/build-win-subs-deps.sh
#
# 依赖：x86_64-w64-mingw32-gcc、meson、ninja、pkg-config、curl、tar
set -euo pipefail

cd "$(dirname "$0")/.."

DEPS_ROOT="${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}"
SRC="$DEPS_ROOT/src"
BUILD="$DEPS_ROOT/build/win-subs"
PREFIX="${DLNA_WIN_SUBS_PREFIX:-$DEPS_ROOT/win64/subs}"

FREETYPE_VERSION="${FREETYPE_VERSION:-2.15.0}"
FRIBIDI_VERSION="${FRIBIDI_VERSION:-1.0.16}"
LIBUNIBREAK_VERSION="${LIBUNIBREAK_VERSION:-7.0}"
HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-15.0.0}"
LIBASS_VERSION="${LIBASS_VERSION:-0.17.5}"

FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz"
FREETYPE_URL_ALT="https://downloads.sourceforge.net/freetype/freetype-$FREETYPE_VERSION.tar.xz"
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz"
LIBUNIBREAK_URL="https://github.com/adah1972/libunibreak/releases/download/libunibreak_${LIBUNIBREAK_VERSION//./_}/libunibreak-$LIBUNIBREAK_VERSION.tar.gz"
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
LIBASS_URL="https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.gz"

CC_BIN="${CC:-x86_64-w64-mingw32-gcc}"
CXX_BIN="${CXX:-x86_64-w64-mingw32-g++}"

for t in "$CC_BIN" "$CXX_BIN" x86_64-w64-mingw32-ar meson ninja pkg-config curl tar; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "错误：找不到 $t" >&2
    case "$t" in
      meson|ninja) echo "  安装：pip3 install meson ninja  或  apt-get install -y meson ninja-build" >&2 ;;
      x86_64-w64-mingw32-gcc|x86_64-w64-mingw32-g++) echo "  macOS: brew install mingw-w64；Debian/Ubuntu: apt-get install g++-mingw-w64-x86-64" >&2 ;;
    esac
    exit 1
  fi
done

mkdir -p "$SRC" "$BUILD" "$PREFIX"

fetch() {
  local url="$1" out="$2" url_alt="${3:-}"
  if [ -s "$out" ] && [ -z "${FORCE:-}" ]; then
    echo "  已有 $(basename "$out")"
    return
  fi
  rm -f "$out.part"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url"; then
    if [ -z "$url_alt" ]; then
      echo "错误：下载失败 $url" >&2
      return 1
    fi
    echo "  换镜像重试：$url_alt"
    curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url_alt"
  fi
  mv "$out.part" "$out"
}

unpack() {
  # unpack <tarball> <target-dir>：解到 $BUILD/<target-dir>，已经解过就复用
  local tarball="$1" dir="$2"
  if [ -d "$BUILD/$dir" ] && [ -n "$(ls -A "$BUILD/$dir" 2>/dev/null)" ]; then
    echo "  已解包 $dir"
    return
  fi
  rm -rf "$BUILD/$dir"
  mkdir -p "$BUILD/$dir"
  tar -xf "$tarball" -C "$BUILD/$dir"
}

CROSS_FILE="$BUILD/cross-mingw64.txt"
cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$CC_BIN'
cpp = '$CXX_BIN'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'
pkgconfig = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""

meson_build() {
  # meson_build <name> <srcdir> [额外参数...]
  # 已经配置过的目录走增量构建，重跑脚本不会从头重编。
  local name="$1" srcdir="$2"
  shift 2
  rm -rf "$BUILD/$name/build"
  meson setup "$BUILD/$name/build" "$srcdir" \
    --cross-file "$CROSS_FILE" --prefix="$PREFIX" \
    --buildtype=release --default-library=shared "$@" > "$BUILD/$name-setup.log" 2>&1 || {
    tail -30 "$BUILD/$name-setup.log" >&2
    echo "错误：$name 配置失败" >&2
    exit 1
  }
  ninja -C "$BUILD/$name/build" > "$BUILD/$name-build.log" 2>&1 || {
    tail -40 "$BUILD/$name-build.log" >&2
    echo "错误：$name 编译失败" >&2
    exit 1
  }
  ninja -C "$BUILD/$name/build" install > "$BUILD/$name-install.log" 2>&1 || {
    tail -20 "$BUILD/$name-install.log" >&2
    echo "错误：$name 安装失败" >&2
    exit 1
  }
}

echo "→ 下载源码"
fetch "$FREETYPE_URL" "$SRC/freetype-$FREETYPE_VERSION.tar.xz" "$FREETYPE_URL_ALT"
fetch "$FRIBIDI_URL" "$SRC/fribidi-$FRIBIDI_VERSION.tar.xz"
fetch "$LIBUNIBREAK_URL" "$SRC/libunibreak-$LIBUNIBREAK_VERSION.tar.gz"
fetch "$HARFBUZZ_URL" "$SRC/harfbuzz-$HARFBUZZ_VERSION.tar.xz"
fetch "$LIBASS_URL" "$SRC/libass-$LIBASS_VERSION.tar.gz"

echo "→ 解包"
unpack "$SRC/freetype-$FREETYPE_VERSION.tar.xz" "src-freetype"
unpack "$SRC/fribidi-$FRIBIDI_VERSION.tar.xz" "src-fribidi"
unpack "$SRC/libunibreak-$LIBUNIBREAK_VERSION.tar.gz" "src-libunibreak"
unpack "$SRC/harfbuzz-$HARFBUZZ_VERSION.tar.xz" "src-harfbuzz"
unpack "$SRC/libass-$LIBASS_VERSION.tar.gz" "src-libass"

# ---- freetype：关掉 zlib/brotli/png/bzip2/harfbuzz，避免多带 DLL ----
echo "→ freetype $FREETYPE_VERSION"
meson_build freetype "$BUILD/src-freetype/freetype-$FREETYPE_VERSION" \
  -Dzlib=disabled -Dbrotli=disabled -Dpng=disabled -Dbzip2=disabled -Dharfbuzz=disabled

# ---- fribidi：只要库，不要二进制和测试 ----
echo "→ fribidi $FRIBIDI_VERSION"
meson_build fribidi "$BUILD/src-fribidi/fribidi-$FRIBIDI_VERSION" \
  -Ddocs=false -Dbin=false -Dtests=false

# ---- libunibreak：autotools，tarball 自带 configure ----
echo "→ libunibreak $LIBUNIBREAK_VERSION"
ULB_SRC="$BUILD/src-libunibreak/libunibreak-$LIBUNIBREAK_VERSION"
if [ ! -x "$ULB_SRC/configure" ]; then
  echo "错误：libunibreak 源码里没有 configure" >&2
  exit 1
fi
rm -rf "$BUILD/unibreak-out"
mkdir -p "$BUILD/unibreak-out"
(
  cd "$BUILD/unibreak-out"
  "$ULB_SRC/configure" --host=x86_64-w64-mingw32 --prefix="$PREFIX" \
    --disable-static --enable-shared CFLAGS="-O2" > cfg.log 2>&1 || { tail -25 cfg.log >&2; exit 1; }
  make -j"${JOBS:-4}" > mk.log 2>&1 || { tail -30 mk.log >&2; exit 1; }
  make install > ins.log 2>&1 || { tail -20 ins.log >&2; exit 1; }
) || { echo "错误：libunibreak 构建失败" >&2; exit 1; }

# ---- harfbuzz：只需核心 shaping 库；静态链接 libgcc，减少要分发的 DLL ----
echo "→ harfbuzz $HARFBUZZ_VERSION"
meson_build harfbuzz "$BUILD/src-harfbuzz/harfbuzz-$HARFBUZZ_VERSION" \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
  -Dicu=disabled -Dgraphite=disabled -Dgraphite2=disabled -Dfreetype=enabled \
  -Dgdi=disabled -Ddirectwrite=disabled -Dcoretext=disabled -Dtests=disabled \
  -Ddocs=disabled -Dintrospection=disabled -Dutilities=disabled -Dbenchmark=disabled \
  -Dsubset=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled \
  -Dwith_libstdcxx=false \
  -Dc_link_args=-static-libgcc -Dcpp_link_args=-static-libgcc

# ---- libass：DirectWrite 取系统字体，不要 fontconfig ----
echo "→ libass $LIBASS_VERSION"
meson_build libass "$BUILD/src-libass/libass-$LIBASS_VERSION" \
  -Dfontconfig=disabled -Ddirectwrite=enabled -Dcoretext=disabled \
  -Dasm=disabled -Dlibunibreak=enabled -Dtest=disabled -Dcompare=disabled \
  -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

# ---- 许可证 ----
LIC="$PREFIX/share/licenses"
mkdir -p "$LIC/libass" "$LIC/freetype" "$LIC/fribidi" "$LIC/libunibreak" "$LIC/harfbuzz"
cp -f "$BUILD/src-libass/libass-$LIBASS_VERSION/COPYING" "$LIC/libass/COPYING" 2>/dev/null || true
cp -f "$BUILD/src-freetype/freetype-$FREETYPE_VERSION/docs/FTL.TXT" "$LIC/freetype/FTL.TXT" 2>/dev/null || true
cp -f "$BUILD/src-freetype/freetype-$FREETYPE_VERSION/docs/GPLv2.TXT" "$LIC/freetype/GPLv2.TXT" 2>/dev/null || true
cp -f "$BUILD/src-fribidi/fribidi-$FRIBIDI_VERSION/COPYING" "$LIC/fribidi/COPYING" 2>/dev/null || true
cp -f "$BUILD/src-libunibreak/libunibreak-$LIBUNIBREAK_VERSION/LICENCE" "$LIC/libunibreak/LICENCE" 2>/dev/null || true
cp -f "$BUILD/src-harfbuzz/harfbuzz-$HARFBUZZ_VERSION/COPYING" "$LIC/harfbuzz/COPYING" 2>/dev/null || true

# ---- 自检：头文件、导入库、DLL、依赖闭包 ----
echo "→ 自检"
fail=0
for f in include/ass/ass.h include/freetype2/freetype/freetype.h \
         include/fribidi/fribidi.h include/harfbuzz/hb.h \
         include/linebreak.h \
         lib/libass.dll.a lib/libfreetype.dll.a \
         lib/libfribidi.dll.a lib/libharfbuzz.dll.a lib/libunibreak.dll.a; do
  [ -f "$PREFIX/$f" ] || { echo "  缺少 $PREFIX/$f" >&2; fail=1; }
done
LIBASS_DLL="$(ls "$PREFIX"/bin/libass-*.dll 2>/dev/null | head -1)"
[ -n "$LIBASS_DLL" ] || { echo "  缺少 libass DLL" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1

# libass 的 DLL 只能依赖系统库和本前缀里的 DLL；指到别处说明有东西没打进来。
bad=0
for dll in "$PREFIX"/bin/*.dll; do
  while read -r dep; do
    case "$dep" in
      KERNEL32.dll|USER32.dll|GDI32.dll|ADVAPI32.dll|SHELL32.dll|OLE32.dll|COMDLG32.dll|\
      msvcrt.dll|dwrite.dll|d2d1.dll|DWrite.dll|IMM32.dll|SETUPAPI.dll|WINMM.dll|WS2_32.dll|\
      api-ms-win-*.dll|ext-ms-*.dll) continue ;;
    esac
    if [ ! -f "$PREFIX/bin/$dep" ]; then
      echo "  未解析依赖：$(basename "$dll") -> $dep" >&2
      bad=1
    fi
  done < <(x86_64-w64-mingw32-objdump -p "$dll" | awk '/DLL Name:/{print $3}')
done
[ "$bad" -eq 0 ] || { echo "错误：运行库依赖不完整" >&2; exit 1; }

cat > "$PREFIX/BUILD-INFO.txt" <<EOF
Windows x64 字幕渲染依赖（libass 及依赖库），由 scripts/build-win-subs-deps.sh 交叉编译
built_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
build_host: $(uname -s) $(uname -m)
compiler: $("$CC_BIN" --version | head -1)
prefix: $PREFIX
libass: $LIBASS_VERSION (ISC)  font provider: DirectWrite (Win32)  fontconfig: off
freetype: $FREETYPE_VERSION (FTL/GPLv2)
fribidi: $FRIBIDI_VERSION (LGPL-2.1)
libunibreak: $LIBUNIBREAK_VERSION (Zlib)
harfbuzz: $HARFBUZZ_VERSION (MIT)
sources:
  $FREETYPE_URL
  $FRIBIDI_URL
  $LIBUNIBREAK_URL
  $HARFBUZZ_URL
  $LIBASS_URL
dlls:
$(cd "$PREFIX/bin" && for f in *.dll; do printf '  %-28s %10s bytes\n' "$f" "$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")"; done)
EOF

echo
echo "✓ 字幕渲染依赖就绪：$PREFIX"
ls -1 "$PREFIX/bin" | sed 's/^/  bin\//'
echo "  头文件：$PREFIX/include/ass"
du -sh "$PREFIX" 2>/dev/null | sed 's/^/  占用 /'
