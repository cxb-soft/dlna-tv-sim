#!/bin/bash
# 构建 LGPL 版 FFmpeg 动态库（macOS），供 -player native 自包含链接。
#
# 产物默认安装到 $HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl。
# 注意：安装路径不能包含空格 —— pkg-config 不支持空格路径（会把 prefix 截断）。
#
# 用法：
#   ./scripts/build-native-deps.sh
#   FFMPEG_VERSION=9.0.2 ./scripts/build-native-deps.sh
#   DLNA_DEPS_ROOT=/path/to/deps ./scripts/build-native-deps.sh
#   DLNA_FFMPEG_PREFIX=/path/to/prefix ./scripts/build-native-deps.sh
#
# 构建自包含引擎（开发机临时验证）：
#   PREFIX=$HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl
#   PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig CGO_ENABLED=1 \
#     CGO_LDFLAGS="-Wl,-rpath,$PREFIX/lib" go build -o /tmp/dlna-native .
# 打包 App 用 scripts/package-macos-app.sh（会自动嵌入 dylib 并设 @rpath）。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
DEPS_ROOT="${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}"
PREFIX="${DLNA_FFMPEG_PREFIX:-$DEPS_ROOT/ffmpeg-lgpl}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
ARCH="${ARCH:-arm64}"

case "$PREFIX" in
  *[[:space:]]*)
    echo "错误：安装前缀不能包含空格（pkg-config 不支持）：$PREFIX" >&2
    exit 1
    ;;
esac
case "$DEPS_ROOT" in
  *[[:space:]]*)
    echo "错误：DLNA_DEPS_ROOT 不能包含空格（pkg-config 不支持）：$DEPS_ROOT" >&2
    exit 1
    ;;
esac

SRC_PARENT="$DEPS_ROOT/src"
SRC="$SRC_PARENT/ffmpeg-$FFMPEG_VERSION"
TARBALL="$SRC_PARENT/ffmpeg-$FFMPEG_VERSION.tar.xz"
URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

mkdir -p "$SRC_PARENT"

echo "→ 源码：$URL"
if [ ! -f "$TARBALL" ]; then
  curl -fL --retry 3 -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
PUB_SHA="$(curl -fsSL "$URL.sha256" 2>/dev/null | awk '{print $1}' || true)"
if [ -n "$PUB_SHA" ] && [ "$PUB_SHA" != "$SHA256" ]; then
  echo "错误：tarball sha256 与官方发布不一致：$SHA256 != $PUB_SHA" >&2
  exit 1
fi
echo "  sha256=$SHA256${PUB_SHA:+ (已与官方 .sha256 核对)}"

if [ ! -x "$SRC/configure" ]; then
  rm -rf "$SRC"
  tar -C "$SRC_PARENT" -xf "$TARBALL"
fi

CONFIGURE_ARGS=(
  --prefix="$PREFIX"
  --arch="$ARCH" --cc=clang
  --enable-shared --disable-static
  --disable-programs --disable-doc --disable-debug
  --disable-gpl --disable-nonfree
  --disable-autodetect
  --disable-avdevice --disable-avfilter
  --disable-everything
  --enable-avformat --enable-avcodec --enable-avutil
  --enable-swresample --enable-swscale
  --enable-videotoolbox --enable-audiotoolbox --enable-securetransport
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox
  --enable-decoder=h264,hevc,aac,aac_at,mp3,mp2,ac3,eac3,flac,opus,vorbis,subrip,ass,ssa,mov_text,webvtt,h264_videotoolbox,hevc_videotoolbox
  --enable-demuxer=mov,matroska,mp3,aac,mpegts,hls
  --enable-parser=h264,hevc,aac,mpegaudio
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc
  --enable-protocol=file,http,https,tcp,udp,crypto
  --enable-network
  # dylib 的 install_name 用 @rpath，App 内由 executable 的 rpath 指向 lib/
  --install-name-dir=@rpath
  # 每个 dylib 自己带 @loader_path，互相依赖也能在 App 内解析
  --extra-ldflags="-Wl,-rpath,@loader_path"
)

echo "→ 配置（LGPL，最小组件集）"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
./configure "${CONFIGURE_ARGS[@]}" > "$SRC_PARENT/configure-$FFMPEG_VERSION.log" 2>&1
if ! grep -q '^License: LGPL version 2.1 or later' "$SRC_PARENT/configure-$FFMPEG_VERSION.log"; then
  echo "错误：configure 结果不是 LGPL 2.1，见 $SRC_PARENT/configure-$FFMPEG_VERSION.log" >&2
  exit 1
fi

echo "→ 编译（-j${JOBS}）"
make -j"$JOBS" > "$SRC_PARENT/make-$FFMPEG_VERSION.log" 2>&1
echo "→ 安装到 $PREFIX"
make install > "$SRC_PARENT/install-$FFMPEG_VERSION.log" 2>&1

# 许可文件：make install 不会带 COPYING；LGPL 动态链接分发必须随附
install -d "$PREFIX/share/licenses/ffmpeg"
for f in LICENSE.md COPYING.LGPLv2.1 COPYING.LGPLv3; do
  cp "$SRC/$f" "$PREFIX/share/licenses/ffmpeg/$f"
done

# 自包含检查：不允许出现 Homebrew / 本地库路径
echo "→ 检查 dylib 依赖"
bad=0
for lib in "$PREFIX"/lib/*.dylib; do
  [ -L "$lib" ] && continue
  if otool -L "$lib" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|'"$(printf '%s' "$PREFIX" | sed 's/[.[\*^$()+?{|]/\\&/g')"; then
    echo "  错误：$lib 仍依赖非系统库：" >&2
    otool -L "$lib" | tail -n +2 >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1

if ! grep -q '#define CONFIG_GPL 0' "$SRC/config.h" || ! grep -q '#define CONFIG_NONFREE 0' "$SRC/config.h"; then
  echo "错误：config.h 显示 GPL/nonfree 未关闭" >&2
  exit 1
fi

# 构建信息（供发布/审计）
{
  echo "FFmpeg $FFMPEG_VERSION — LGPL 动态库构建（macOS ${ARCH}）"
  echo "built_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "build_host: $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"
  echo "compiler: $(clang --version | head -1)"
  echo "source_url: $URL"
  echo "source_sha256: $SHA256"
  echo "prefix: $PREFIX"
  echo "license: LGPL version 2.1 or later (CONFIG_GPL=0 CONFIG_NONFREE=0 CONFIG_VERSION3=0)"
  printf 'configure:'
  printf ' %q' "${CONFIGURE_ARGS[@]}"
  echo
  echo
  echo "dylibs:"
  for lib in "$PREFIX"/lib/*.dylib; do
    [ -L "$lib" ] && continue
    printf '  %-28s %10s bytes  sha256=%s\n' "$(basename "$lib")" \
      "$(stat -f%z "$lib")" "$(shasum -a 256 "$lib" | awk '{print $1}')"
  done
  echo
  echo "otool -L (libavcodec):"
  otool -L "$PREFIX/lib/libavcodec.dylib" | sed 's/^/  /'
} > "$PREFIX/BUILD-INFO.txt"

echo
echo "✓ 完成：$PREFIX"
du -sh "$PREFIX"
ls -lh "$PREFIX/lib/"*.dylib | sed -n '1,12p'
echo
echo "构建自包含引擎："
echo "  PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig CGO_ENABLED=1 \\"
echo "    CGO_LDFLAGS=\"-Wl,-rpath,$PREFIX/lib\" go build -o /tmp/dlna-native ."
