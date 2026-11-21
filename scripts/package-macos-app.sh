#!/bin/bash
# 把 Flutter 界面和 Go 引擎合成一个 macOS .app，产出 dist/dlna-tv-sim-macos-app.zip
# 用法：./scripts/package-macos-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -E '^var version = ' main.go | sed -E 's/.*"(.*)".*/\1/' | head -1)"
APP="ui/build/macos/Build/Products/Release/dlna_tv_sim.app"
DEFAULT_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
SIGN_ID="${SIGN_ID:-${DEFAULT_ID:--}}"

echo "→ 构建 Go 引擎（arm64），版本 $VERSION"
mkdir -p dist
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
  -ldflags "-s -w -X main.version=$VERSION" -o /tmp/dlna-tv-sim-engine .
file /tmp/dlna-tv-sim-engine

echo "→ 构建 Flutter 界面（release，arm64）"
(cd ui && flutter build macos --release --config-only \
  && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
       -derivedDataPath build/macos ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build \
     | tail -4)
APP="ui/build/macos/Build/Products/Release/DLNA 电视.app"

echo "→ 把引擎和 uosc 放进 .app"
mkdir -p "$APP/Contents/Resources/engine"
cp /tmp/dlna-tv-sim-engine "$APP/Contents/Resources/engine/dlna-tv-sim"
if [ -d uosc ]; then
  rm -rf "$APP/Contents/Resources/engine/uosc"
  cp -R uosc "$APP/Contents/Resources/engine/uosc"
fi

echo "→ 签名（$SIGN_ID）"
# --deep 不会重签 Resources 里的裸二进制，引擎要单独签，否则 TCC 认不出它属于这个 App
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Resources/engine/dlna-tv-sim"
# 框架必须和主程序同 Team ID，否则 hardened runtime 下 dyld 拒绝加载
codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"

echo "→ 打包 zip"
rm -f dist/dlna-tv-sim-macos-app.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/dlna-tv-sim-macos-app.zip
ls -lh dist/dlna-tv-sim-macos-app.zip
shasum -a 256 dist/dlna-tv-sim-macos-app.zip
