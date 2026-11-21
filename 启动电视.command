#!/bin/bash
# 双击这个文件即可启动电视模拟器。
#
# 为什么要用 Terminal 启动：macOS 的「本地网络」权限是跟 App 身份走的。
# 直接双击可执行文件、或由别的 App 拉起时，系统可能不给这个进程本地网络权限，
# 表现就是 SSDP 组播发不出去（no route to host），手机永远搜不到这台电视。
# 从 Terminal 启动则沿用 Terminal 已经获得的本地网络权限，组播正常。
cd "$(dirname "$0")" || exit 1

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  BIN="./dlna-tv-sim-macos-arm64"
else
  BIN="./dlna-tv-sim-macos-amd64"
fi

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件：$BIN"
  echo "请确认它和这个脚本在同一个目录里。"
  read -r -p "按回车关闭…" _
  exit 1
fi

echo "启动 DLNA 电视模拟器（$ARCH）…"
echo "控制台会自动在浏览器打开；关闭这个窗口或按 Ctrl+C 即停止。"
echo
exec "$BIN"
