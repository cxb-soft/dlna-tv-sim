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
- 有视频时音频设备保持暂停，首帧显示后才开声；纯音频文件立即开声。首帧解码后不受
  时钟门限，直接显示；起播/seek 缓冲期窗口显示“准备中…”/“跳转中…”。
- seek 立即把进度/时钟置到目标并清空视频队列/音频环，同时中断阻塞中的 `av_read_frame`；
  媒体线程完成 seek 后首帧直接显示。拖动过程只更新预览，释放时只发一次 seek。
- 倍速用 swresample 改变输入采样率实现（会有音调变化），不是变速不变调。
- 自绘控制层（对齐 macOS）：顶部标题/设备名和右上编码信息胶囊；底部影院 scrim、
  琥珀进度条、当前/总时长；播放/暂停、±10 秒、音量/静音、倍速菜单、音轨菜单、
  画面比例、截图、全屏、关闭。悬停高亮；播放 2.5 秒后自动隐藏，暂停/拖动/菜单常显。
  快捷键：空格暂停、左右 ±10 秒、上下音量、M 静音、F 全屏、S 截图、Esc 退出。
- 截图保存到桌面（失败退回 `%TEMP%`），用 toast 提示结果；字幕轨只枚举，菜单可选但
  暂不渲染（选择时 toast 说明），音轨菜单可以切换。
- 文本在 Windows 上用 GDI（Microsoft YaHei UI）渲染，不引入 SDL2_ttf 或额外字体 DLL；
  本机 portable 自测没有 GDI，退回 5x7 点阵，只用于检查布局/图标，中文以 Windows 为准。

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

控制层自测：加 `PE_SELFTEST_UI=1` 会在 `/tmp` 生成 `winui_01_controls.bmp` 到
`winui_05_toast.bmp`（通过 `SDL_RenderReadPixels` 抓渲染帧），用来检查控制条、
倍速/音轨菜单、暂停态和 toast 的位置。本机没有 GDI，文字退回 5x7 点阵，只能验证
布局和图标；中文文本、悬停和真实鼠标/键盘交互仍需 Windows 实机确认。

seek/起播自测：用 40s 素材加 `PE_SELFTEST_SEEK=1`，会打印 `DRAG_BEFORE`、
`SEEK50`（50% = 20s）和 `SEEK30`（30s）的位置、`buffering`、已显示帧数和 seek 耗时；
`首视频/首音频` 日志用来核对起播顺序。
