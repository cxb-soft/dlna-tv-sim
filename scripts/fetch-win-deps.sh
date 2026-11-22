#!/bin/bash
# 下载 Windows x64 自研播放核心需要的开发库和运行库：
#   SDL2 2.32.0（官方 mingw 开发包，x86_64-w64-mingw32）
#   FFmpeg 9.0 LGPL shared（BtbN 构建，含 avcodec/avformat/avutil/swscale/swresample）
#
# 产物：
#   $DLNA_DEPS_ROOT/win64/sdl2/{include,lib,bin}
#   $DLNA_DEPS_ROOT/win64/ffmpeg/{include,lib,bin,LICENSE.txt}
#
# 用法：
#   ./scripts/fetch-win-deps.sh
#   FORCE=1 ./scripts/fetch-win-deps.sh          # 重新下载解压
#   DLNA_DEPS_ROOT=/path/to/cache ./scripts/fetch-win-deps.sh
#
# 注意：FFmpeg 必须是 LGPL shared 构建，才能随程序一起分发 DLL；
# 不要换成 GPL 构建（BtbN 的 *-gpl-shared 不能用于闭源/许可不兼容的发布）。
set -euo pipefail

cd "$(dirname "$0")/.."

DEPS_ROOT="${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}"
WIN_ROOT="$DEPS_ROOT/win64"
CACHE="$DEPS_ROOT/win64-downloads"
SDL2_VERSION="${SDL2_VERSION:-2.32.0}"
SDL2_URL="${SDL2_URL:-https://www.libsdl.org/release/SDL2-devel-$SDL2_VERSION-mingw.tar.gz}"
FFMPEG_ASSET="${FFMPEG_ASSET:-ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip}"
FFMPEG_URL="${FFMPEG_URL:-https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$FFMPEG_ASSET}"

mkdir -p "$CACHE" "$WIN_ROOT"

download() {
  local url="$1" out="$2"
  if [ -s "$out" ] && [ -z "${FORCE:-}" ]; then
    echo "  已有 $(basename "$out")"
    return
  fi
  echo "→ 下载 $url"
  rm -f "$out.part"
  curl -fL --retry 3 --retry-delay 2 -o "$out.part" "$url"
  mv "$out.part" "$out"
}

extract_zip() {
  local zip="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip" -d "$dest"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$zip" "$dest"
  else
    echo "错误：需要 unzip 或 python3 才能解压 $zip" >&2
    exit 1
  fi
}

have_deps() {
  [ -f "$WIN_ROOT/sdl2/lib/libSDL2.dll.a" ] &&
    [ -f "$WIN_ROOT/sdl2/include/SDL2/SDL.h" ] &&
    [ -f "$WIN_ROOT/ffmpeg/lib/libavcodec.dll.a" ] &&
    [ -f "$WIN_ROOT/ffmpeg/include/libavcodec/avcodec.h" ]
}

if have_deps && [ -z "${FORCE:-}" ]; then
  echo "Windows 依赖已经就绪：$WIN_ROOT"
else
  SDL_TGZ="$CACHE/SDL2-devel-$SDL2_VERSION-mingw.tar.gz"
  FF_ZIP="$CACHE/$FFMPEG_ASSET"

  download "$SDL2_URL" "$SDL_TGZ"
  download "$FFMPEG_URL" "$FF_ZIP"

  echo "→ 解压 SDL2"
  rm -rf "$CACHE/sdl2-src"
  mkdir -p "$CACHE/sdl2-src"
  tar xzf "$SDL_TGZ" -C "$CACHE/sdl2-src"
  SDL_DIR="$(find "$CACHE/sdl2-src" -maxdepth 2 -type d -name x86_64-w64-mingw32 | head -1)"
  if [ -z "$SDL_DIR" ]; then
    echo "错误：SDL2 包里没有 x86_64-w64-mingw32 目录" >&2
    exit 1
  fi
  rm -rf "$WIN_ROOT/sdl2"
  mkdir -p "$WIN_ROOT/sdl2"
  cp -R "$SDL_DIR/." "$WIN_ROOT/sdl2/"

  echo "→ 解压 FFmpeg"
  rm -rf "$CACHE/ffmpeg-src"
  extract_zip "$FF_ZIP" "$CACHE/ffmpeg-src"
  FF_DIR="$(find "$CACHE/ffmpeg-src" -maxdepth 1 -type d -name 'ffmpeg-*' | head -1)"
  if [ -z "$FF_DIR" ]; then
    echo "错误：FFmpeg 包里没有 ffmpeg-* 目录" >&2
    exit 1
  fi
  rm -rf "$WIN_ROOT/ffmpeg"
  mkdir -p "$WIN_ROOT/ffmpeg"
  cp -R "$FF_DIR/." "$WIN_ROOT/ffmpeg/"

  # BtbN 的 shared 包给的是 MSVC 的 .lib 和 .def；MinGW/cgo 要 .dll.a。
  # 这里从 .def 生成 import library，否则 CI 新解压后会缺 libavcodec.dll.a。
  if command -v x86_64-w64-mingw32-dlltool >/dev/null 2>&1; then
    for def in "$WIN_ROOT/ffmpeg/lib"/*.def; do
      [ -f "$def" ] || continue
      base="$(basename "$def" .def)"
      stem="${base%-*}"
      x86_64-w64-mingw32-dlltool -d "$def" -l "$WIN_ROOT/ffmpeg/lib/lib${stem}.dll.a" -D "${base}.dll"
    done
  fi

  if ! have_deps; then
    echo "错误：解压后仍然缺少开发库，检查下载包是否完整" >&2
    exit 1
  fi
fi

if ! grep -q "lgpl" <<<"$FFMPEG_ASSET"; then
  echo "警告：$FFMPEG_ASSET 看起来不是 LGPL 构建，发布前请核对许可证" >&2
fi

echo
echo "Windows 依赖已就绪：$WIN_ROOT"
echo "  SDL2   $SDL2_VERSION"
echo "  FFmpeg $FFMPEG_ASSET"
echo "  运行库："
ls "$WIN_ROOT"/ffmpeg/bin/avcodec-*.dll \
   "$WIN_ROOT"/ffmpeg/bin/avformat-*.dll \
   "$WIN_ROOT"/ffmpeg/bin/avutil-*.dll \
   "$WIN_ROOT"/ffmpeg/bin/swresample-*.dll \
   "$WIN_ROOT"/ffmpeg/bin/swscale-*.dll \
   "$WIN_ROOT/sdl2/bin/SDL2.dll" 2>/dev/null | sed 's/^/    /'
echo
echo "构建 Windows 原生版："
echo "  ./scripts/build-windows-native.sh"
