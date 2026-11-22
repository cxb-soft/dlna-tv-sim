# Windows 自研播放核心（player/win）

这是 `-player native` 在 Windows 上的实现，和 macOS 的 `player/engine_darwin.m`
互不复用：macOS 走 ObjC + VideoToolbox + AVSampleBufferDisplayLayer，Windows 走
C + SDL2 + FFmpeg 软解。

## 结构

| 文件 | 作用 |
| --- | --- |
| `player/engine_windows.c` | 引擎实现：FFmpeg 解封装/解码、SDL2 窗口与 D3D11 渲染、SDL2 audio（WASAPI）、音频主时钟、seek/暂停/倍速/音量/全屏、自绘控件、PNG 截图。整个文件包在 `#if defined(_WIN32) \|\| defined(PE_ENGINE_PORTABLE)` 里。 |
| `player/player_windows.go` | Go 封装，和 `player_darwin.go` 暴露同一套 API；build tag `windows && cgo`。 |
| `native_windows.go` | 进程主线程的 SDL 事件循环 host，和 `native.go` 同构；build tag `windows && cgo`。 |

Windows 上没有 cgo 时（`CGO_ENABLED=0`）`player_windows.go` 和 `native_windows.go`
不参与编译，`player_unsupported.go` / `native_stub.go` 仍按原样提供占位实现，
`-player native` 会自动回退 mpv。

## 依赖

- SDL2 2.32.0（官方 mingw 开发包，x86_64-w64-mingw32）
- FFmpeg 9.0 LGPL shared（BtbN 构建）
- 交叉编译器：`x86_64-w64-mingw32-gcc`（macOS: `brew install mingw-w64`）

```bash
./scripts/fetch-win-deps.sh          # 下载到 ~/Library/Caches/dlnatvsim-deps/win64
./scripts/build-windows-native.sh    # 产出 dist/dlna-tv-sim-windows-x64.exe
STAGE=dist/win64-runtime ./scripts/build-windows-native.sh  # 同时收集运行 DLL
```

运行时需要的 DLL：`SDL2.dll`、`avcodec-63.dll`、`avformat-63.dll`、
`avutil-61.dll`、`swresample-7.dll`、`swscale-10.dll`。

## 行为

- 默认引擎仍是 mpv；只有 `-player native` 或控制台切到 native 才会用这个引擎。
- 打开失败（缺 DLL、格式不支持、窗口/音频设备起不来）会记录日志并回退 mpv。
- 视频先做软解（`Status.Hardware == false`），D3D11VA 硬解留作后续。
- 音频输出 48kHz 立体声 S16；设备不支持时退回 44.1kHz。音频已播放采样数是主时钟，
  没有音轨时用墙钟。
- 倍速用 swresample 改变输入采样率实现（会有音调变化），不是变速不变调。
- 内置控件：播放/暂停、进度拖动、时间、音量/静音、全屏；键盘空格、左右、上下、
  M、F、Esc。鼠标移动 2.5 秒后自动隐藏，暂停时保留。
- 字幕轨只枚举、不渲染；字幕/音轨菜单入口按计划后置。

## 无 Windows 实机时的验证

`player/win/engine_selftest.c` 用同一份引擎代码在本机（macOS/Linux）编译运行，
验证打开、解码、音画时钟、seek、暂停/恢复、音量、倍速、截图和关窗。它只在
手动编译时使用，不参与 cgo 包构建：

```bash
PREFIX=$HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl
cc -g -O1 -fsanitize=address -DPE_ENGINE_PORTABLE \
  -Iplayer -I"$(brew --prefix sdl2)/include/SDL2" -I"$PREFIX/include" \
  player/engine_windows.c player/win/engine_selftest.c \
  $(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --libs sdl2 libavformat libavcodec libavutil libswscale libswresample) \
  -o /tmp/pe-selftest
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy /tmp/pe-selftest /tmp/pe-test.mp4
```

注意本机 Homebrew 的 `sdl2` 已经是 sdl2-compat；自测建议用官方 SDL2 2.32.0
（`/tmp/sdl2-install`）编译，和 Windows 包里的版本一致。
