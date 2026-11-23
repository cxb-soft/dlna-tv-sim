#!/bin/bash
# 交叉编译 Windows x64 自研播放核心版本，并可选地把运行库一起摊到输出目录。
#
# 前置：
#   ./scripts/fetch-win-deps.sh
#
# 用法：
#   ./scripts/build-windows-native.sh
#   OUT=dist/dlna-tv-sim-windows-x64.exe ./scripts/build-windows-native.sh
#   STAGE=dist/win64-runtime ./scripts/build-windows-native.sh
#
# 说明：默认引擎仍是 mpv，自研核心要加 -player native 才会用；起不来会自动
# 回退 mpv（见 engine_pick.go / native_windows.go）。
set -euo pipefail

cd "$(dirname "$0")/.."

DEPS_ROOT="${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}"
WIN_ROOT="${DLNA_WIN_DEPS:-$DEPS_ROOT/win64}"
OUT="${OUT:-dist/dlna-tv-sim-windows-x64.exe}"
STAGE="${STAGE:-}"

if [ ! -f "$WIN_ROOT/ffmpeg/lib/libavcodec.dll.a" ] || [ ! -f "$WIN_ROOT/sdl2/lib/libSDL2.dll.a" ] \
   || [ ! -f "$WIN_ROOT/subs/lib/libass.dll.a" ]; then
  echo "缺少 Windows 开发库：$WIN_ROOT" >&2
  echo "先运行：./scripts/fetch-win-deps.sh" >&2
  exit 1
fi

CC="${CC:-x86_64-w64-mingw32-gcc}"
if ! command -v "$CC" >/dev/null 2>&1; then
  echo "找不到交叉编译器 $CC（macOS: brew install mingw-w64）" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

export GOOS=windows
export GOARCH=amd64
export CGO_ENABLED=1
export CC
export CXX="${CXX:-x86_64-w64-mingw32-g++}"
export CGO_CFLAGS="-I$WIN_ROOT/sdl2/include/SDL2 -I$WIN_ROOT/ffmpeg/include -I$WIN_ROOT/subs/include ${CGO_CFLAGS:-}"
export CGO_LDFLAGS="-L$WIN_ROOT/ffmpeg/lib -L$WIN_ROOT/sdl2/lib -L$WIN_ROOT/subs/lib ${CGO_LDFLAGS:-}"

LDFLAGS="-s -w"
if [ -n "${VERSION:-}" ]; then
  LDFLAGS="$LDFLAGS -X main.version=$VERSION"
fi
if [ "${GUI:-}" = "1" ]; then
  # Flutter 桌面壳里启动的引擎不要弹控制台窗口。
  LDFLAGS="$LDFLAGS -H windowsgui"
fi

echo "→ 交叉编译 $OUT"
go build -trimpath -ldflags "$LDFLAGS" -o "$OUT" .

echo "→ 检查动态库依赖"
x86_64-w64-mingw32-objdump -p "$OUT" | awk '/DLL Name:/{print "    " $3}' | sort -u

if [ -n "$STAGE" ]; then
  mkdir -p "$STAGE"
  echo "→ 收集运行库到 $STAGE"
  cp "$WIN_ROOT/sdl2/bin/SDL2.dll" "$STAGE/"
  cp "$WIN_ROOT"/ffmpeg/bin/avcodec-*.dll "$STAGE/"
  cp "$WIN_ROOT"/ffmpeg/bin/avformat-*.dll "$STAGE/"
  cp "$WIN_ROOT"/ffmpeg/bin/avutil-*.dll "$STAGE/"
  cp "$WIN_ROOT"/ffmpeg/bin/swresample-*.dll "$STAGE/"
  cp "$WIN_ROOT"/ffmpeg/bin/swscale-*.dll "$STAGE/"
  # 字幕渲染：libass + freetype/fribidi/harfbuzz/unibreak
  if compgen -G "$WIN_ROOT/subs/bin/*.dll" >/dev/null; then
    cp "$WIN_ROOT"/subs/bin/*.dll "$STAGE/"
  else
    echo "缺字幕渲染 DLL：$WIN_ROOT/subs/bin" >&2
    exit 1
  fi
  cp "$WIN_ROOT/ffmpeg/LICENSE.txt" "$STAGE/LICENSE-FFmpeg.txt"
  if [ -f "$WIN_ROOT/sdl2/share/licenses/SDL2/LICENSE.txt" ]; then
    cp "$WIN_ROOT/sdl2/share/licenses/SDL2/LICENSE.txt" "$STAGE/LICENSE-SDL2.txt"
  elif [ -f "$WIN_ROOT/sdl2/LICENSE.txt" ]; then
    cp "$WIN_ROOT/sdl2/LICENSE.txt" "$STAGE/LICENSE-SDL2.txt"
  elif [ -f third_party/licenses/SDL2-LICENSE.txt ]; then
    cp third_party/licenses/SDL2-LICENSE.txt "$STAGE/LICENSE-SDL2.txt"
  fi
  if [ -f third_party/licenses/ffmpeg/COPYING.LGPLv2.1 ]; then
    cp third_party/licenses/ffmpeg/COPYING.LGPLv2.1 "$STAGE/COPYING.LGPLv2.1"
  fi
  # libass 与依赖库的许可证（ISC / FTL+GPLv2 / LGPL-2.1 / Zlib / MIT）
  SUBS_LIC="$WIN_ROOT/subs/share/licenses"
  if [ -d "$SUBS_LIC" ]; then
    cp "$SUBS_LIC/libass/COPYING" "$STAGE/LICENSE-libass.txt" 2>/dev/null || true
    cp "$SUBS_LIC/freetype/FTL.TXT" "$STAGE/LICENSE-freetype-FTL.txt" 2>/dev/null || true
    cp "$SUBS_LIC/freetype/GPLv2.TXT" "$STAGE/LICENSE-freetype-GPLv2.txt" 2>/dev/null || true
    cp "$SUBS_LIC/fribidi/COPYING" "$STAGE/LICENSE-fribidi.txt" 2>/dev/null || true
    cp "$SUBS_LIC/libunibreak/LICENCE" "$STAGE/LICENSE-libunibreak.txt" 2>/dev/null || true
    cp "$SUBS_LIC/harfbuzz/COPYING" "$STAGE/LICENSE-harfbuzz.txt" 2>/dev/null || true
  else
    echo "缺字幕依赖许可证：$SUBS_LIC" >&2
    exit 1
  fi
  echo "  运行库："
  ls -lh "$STAGE"/*.dll | awk '{print "    " $9, $5}'
  echo "  许可证："
  ls -1 "$STAGE"/LICENSE-* "$STAGE"/COPYING.* 2>/dev/null | sed 's|^.*/|    |'
fi

ls -lh "$OUT"
