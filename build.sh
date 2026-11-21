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
build windows amd64 dlna-tv-sim-windows-x64.exe
build windows arm64 dlna-tv-sim-windows-arm64.exe
build linux amd64   dlna-tv-sim-linux-amd64
build linux arm64   dlna-tv-sim-linux-arm64

ls -lh dist/
