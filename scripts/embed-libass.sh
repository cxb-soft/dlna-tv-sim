#!/bin/bash
# 把 libass 0.17.5 及其运行依赖复制到 deps 前缀，并统一改成 @rpath。
# 版本/许可/源码记录见 third_party/README.md；源码构建待补，当前用同版本 Homebrew 库。
set -euo pipefail
PREFIX="${DLNA_FFMPEG_PREFIX:-${DLNA_DEPS_ROOT:-$HOME/Library/Caches/dlnatvsim-deps}/ffmpeg-lgpl}"
LIBASS_LIB="${LIBASS_LIB:-/opt/homebrew/opt/libass/lib/libass.9.dylib}"
LIBASS_INC="${LIBASS_INC:-/opt/homebrew/include/ass}"
mkdir -p "$PREFIX/lib" "$PREFIX/include/ass" "$PREFIX/lib/pkgconfig"
cp -fL "$LIBASS_LIB" "$PREFIX/lib/"
ln -sf "$(basename "$LIBASS_LIB")" "$PREFIX/lib/libass.dylib"
cp -Rf "$LIBASS_INC/." "$PREFIX/include/ass/"

QUEUE=/tmp/libass_dylib_queue.txt
: > "$QUEUE"
echo "$LIBASS_LIB" >> "$QUEUE"
i=0
while [ "$i" -lt "$(wc -l < "$QUEUE")" ]; do
  i=$((i+1))
  lib=$(sed -n "${i}p" "$QUEUE")
  [ -f "$lib" ] || continue
  otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        if [ -f "$dep" ]; then
          base=$(basename "$dep")
          case " $(tr '\n' ' ' < "$QUEUE") " in
            *" $dep "*) ;;
            *) cp -fL "$dep" "$PREFIX/lib/$base"; echo "$dep" >> "$QUEUE" ;;
          esac
        fi
        ;;
    esac
  done
done

for lib in "$PREFIX"/lib/*.dylib; do
  [ -L "$lib" ] && continue
  chmod u+w "$lib"
  base=$(basename "$lib")
  install_name_tool -id "@rpath/$base" "$lib" 2>/dev/null || true
  otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*|"$PREFIX"/*)
        db=$(basename "$dep")
        [ -f "$PREFIX/lib/$db" ] && install_name_tool -change "$dep" "@rpath/$db" "$lib" 2>/dev/null || true
        ;;
    esac
  done
done

cat > "$PREFIX/lib/pkgconfig/libass.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libass
Description: LibASS ASSubtitle renderer
Version: 0.17.5
Libs: -L\${libdir} -lass
Cflags: -I\${includedir}
EOF

echo "libass embedded: $(otool -L "$PREFIX/lib/libass.9.dylib" | grep -c '@rpath') rpath deps"
