#!/bin/bash
# 把 Flutter 界面和 Go 引擎合成一个 macOS .app，产出 dist/dlna-tv-sim-macos-app.zip
# 用法：./scripts/package-macos-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -E '^var version = ' main.go | sed -E 's/.*"(.*)".*/\1/' | head -1)"
APP="ui/build/macos/Build/Products/Release/DLNA 电视.app"
DEFAULT_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
SIGN_ID="${SIGN_ID:-${DEFAULT_ID:--}}"

# 自包含原生引擎：默认链接 scripts/build-native-deps.sh 产出的 LGPL FFmpeg，
# 把 dylib 放进 Contents/Resources/engine/lib（@rpath/@executable_path/lib）。
# DLNA_NATIVE_ENGINE=0 可退回不含 native 的 CGO_ENABLED=0 构建。
DEPS_ROOT="${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}"
FFMPEG_PREFIX="${DLNA_FFMPEG_PREFIX:-$DEPS_ROOT/ffmpeg-lgpl}"
NATIVE_ENGINE="${DLNA_NATIVE_ENGINE:-1}"

echo "→ 构建 Go 引擎（arm64），版本 $VERSION"
  echo "→ 嵌入 libass 字幕库（0.17.5）"
  DLNA_FFMPEG_PREFIX="$FFMPEG_PREFIX" ./scripts/embed-libass.sh

mkdir -p dist
if [ "$NATIVE_ENGINE" = "1" ]; then
  if [ ! -f "$FFMPEG_PREFIX/lib/libavcodec.dylib" ]; then
    echo "错误：找不到 LGPL FFmpeg（${FFMPEG_PREFIX}）" >&2
    echo "      先运行 scripts/build-native-deps.sh，或用 DLNA_NATIVE_ENGINE=0 构建不含 native 的引擎。" >&2
    exit 1
  fi
  case "$FFMPEG_PREFIX" in
    *[[:space:]]*)
      echo "错误：FFMPEG_PREFIX 不能包含空格（pkg-config 不支持）：$FFMPEG_PREFIX" >&2
      exit 1
      ;;
  esac
  echo "  链接自包含 LGPL FFmpeg：$FFMPEG_PREFIX"
  PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
  CGO_LDFLAGS="-Wl,-rpath,@executable_path/lib ${CGO_LDFLAGS:-}" \
    go build -trimpath \
    -ldflags "-s -w -X main.version=$VERSION" -o /tmp/dlna-tv-sim-engine .
else
  echo "  警告：DLNA_NATIVE_ENGINE=0，引擎不含自研播放核心（-player native 不可用）" >&2
  GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X main.version=$VERSION" -o /tmp/dlna-tv-sim-engine .
fi
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

if [ "$NATIVE_ENGINE" = "1" ]; then
  echo "→ 嵌入 FFmpeg 动态库（@rpath）"
  ENGINE_DIR="$APP/Contents/Resources/engine"
  rm -rf "$ENGINE_DIR/lib"
  mkdir -p "$ENGINE_DIR/lib"
  # 保留符号链接：install_name 是 @rpath/libavcodec.63.dylib，实体是 libavcodec.63.1.102.dylib
  for f in "$FFMPEG_PREFIX"/lib/*.dylib; do cp -a "$f" "$ENGINE_DIR/lib/"; done
  # 依赖闭包：所有 dylib 的 @rpath 引用必须能在 engine/lib 里找到。
  missing=""
  for f in "$ENGINE_DIR/lib"/*.dylib; do
    while read -r dep; do
      [ -z "$dep" ] && continue
      [ -e "$ENGINE_DIR/lib/$dep" ] || missing="$missing $dep"
    done < <(otool -L "$f" | awk '/@rpath/ {print $1}' | sed 's#@rpath/##')
  done
  if [ -n "$missing" ]; then
    echo "错误：缺少 @rpath 依赖:$missing" >&2
    exit 1
  fi
  # 引擎只能依赖 @rpath 与系统框架，不能残留 Homebrew/绝对前缀
  # libass 可能因 pkg-config/链接缓存记录 Homebrew 绝对路径，打包前改回 @rpath。
  if otool -L "$ENGINE_DIR/dlna-tv-sim" | grep -q '/opt/homebrew/opt/libass/lib/libass.9.dylib'; then
    install_name_tool -change /opt/homebrew/opt/libass/lib/libass.9.dylib @rpath/libass.9.dylib "$ENGINE_DIR/dlna-tv-sim"
  fi
  ABS_RE="$(printf '%s' "$FFMPEG_PREFIX" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  if otool -L "$ENGINE_DIR/dlna-tv-sim" | tail -n +2 | grep -Eq "/opt/homebrew|/usr/local|$ABS_RE"; then
    echo "错误：引擎仍链接外部 FFmpeg：" >&2
    otool -L "$ENGINE_DIR/dlna-tv-sim" | tail -n +2 >&2
    exit 1
  fi
  if ! otool -l "$ENGINE_DIR/dlna-tv-sim" | grep -A2 LC_RPATH | grep -q '@executable_path/lib'; then
    echo "错误：引擎缺少 @executable_path/lib 的 rpath" >&2
    exit 1
  fi
  otool -L "$ENGINE_DIR/dlna-tv-sim" | sed -n '1,12p'
fi

echo "→ 签名（${SIGN_ID}）"
# --deep 不会重签 Resources 里的裸二进制，引擎和 dylib 要单独签，否则 TCC 认不出它属于这个 App
if [ "$NATIVE_ENGINE" = "1" ]; then
  for lib in "$APP/Contents/Resources/engine/lib/"*.dylib; do
    [ -L "$lib" ] && continue
    codesign --force --options runtime --sign "$SIGN_ID" "$lib"
  done
fi
codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Resources/engine/dlna-tv-sim"
# 框架必须和主程序同 Team ID，否则 hardened runtime 下 dyld 拒绝加载
codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"

# 公证：没有凭据时跳过（NOTARIZE=0 可强制跳过）
NOTARY_KEY="${NOTARY_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_MG4AM2TW96.p8}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-MG4AM2TW96}"
NOTARY_ISSUER="${NOTARY_ISSUER:-e2b55696-56a1-4da2-9cf8-1d0ef3b98edd}"
if [ "${NOTARIZE:-1}" = "1" ] && [ -f "$NOTARY_KEY" ]; then
  echo "→ 公证（notarytool）"
  rm -f /tmp/dlna-notarize.zip
  ditto -c -k --keepParent "$APP" /tmp/dlna-notarize.zip
  xcrun notarytool submit /tmp/dlna-notarize.zip \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait \
    | tail -4
  xcrun stapler staple "$APP" | tail -2
  spctl -a -vv "$APP" 2>&1 | head -2
fi

echo "→ 打包 zip"
rm -f dist/dlna-tv-sim-macos-app.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/dlna-tv-sim-macos-app.zip
ls -lh dist/dlna-tv-sim-macos-app.zip
shasum -a 256 dist/dlna-tv-sim-macos-app.zip
