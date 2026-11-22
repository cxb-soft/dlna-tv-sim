#!/bin/bash
# 交叉编译各平台可执行文件。产物在 dist/。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-}"
mkdir -p dist

# 只有显式给了 VERSION 才用 ldflags 覆盖，否则用 main.go 里的版本号
build() {
  local goos="$1" goarch="$2" out="$3"
  echo "→ $goos/$goarch  $out"
  local ldflags="-s -w"
  if [ -n "$VERSION" ]; then
    ldflags="$ldflags -X main.version=$VERSION"
  fi
  GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
    go build -trimpath -ldflags "$ldflags" -o "dist/$out" .
}

build darwin arm64  dlna-tv-sim-macos-arm64
build darwin amd64  dlna-tv-sim-macos-amd64
# Windows x64：准备好 SDL2/FFmpeg 开发库时带自研播放核心（-player native），
# 没准备好就退回纯 Go 版本，native 会自动回退 mpv。
WIN_DEPS="${DLNA_WIN_DEPS:-${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}/win64}"
if [ -f "$WIN_DEPS/ffmpeg/lib/libavcodec.dll.a" ] && \
   [ -f "$WIN_DEPS/sdl2/lib/libSDL2.dll.a" ] && \
   command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "→ windows/amd64  dlna-tv-sim-windows-x64.exe（含自研播放核心）"
  OUT="dist/dlna-tv-sim-windows-x64.exe" VERSION="$VERSION" ./scripts/build-windows-native.sh
else
  echo "→ windows/amd64  （没找到 Windows SDL2/FFmpeg，退回纯 Go 版本）"
  build windows amd64 dlna-tv-sim-windows-x64.exe
fi
build windows arm64 dlna-tv-sim-windows-arm64.exe
build linux amd64   dlna-tv-sim-linux-amd64
build linux arm64   dlna-tv-sim-linux-arm64

ls -lh dist/
