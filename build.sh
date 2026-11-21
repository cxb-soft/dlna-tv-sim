#!/bin/bash
# 交叉编译各平台可执行文件。产物在 dist/。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
mkdir -p dist

build() {
  local goos="$1" goarch="$2" out="$3"
  echo "→ $goos/$goarch  $out"
  GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "dist/$out" .
}

build darwin arm64  dlna-tv-sim-macos-arm64
build darwin amd64  dlna-tv-sim-macos-amd64
build windows amd64 dlna-tv-sim-windows-x64.exe
build windows arm64 dlna-tv-sim-windows-arm64.exe
build linux amd64   dlna-tv-sim-linux-amd64
build linux arm64   dlna-tv-sim-linux-arm64

ls -lh dist/
