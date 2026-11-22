# player —— 自研播放核心（macOS / Windows）

这是 DLNA 电视模拟器的**进程内播放核心**：不拉起 mpv/VLC，自己做解封装、
解码、出声和音画同步。macOS 用 VideoToolbox 硬解，Windows 用 FFmpeg 软解 +
SDL2（D3D11 渲染 / WASAPI 音频）；两边共用 `engine.h` 接口和 Go 侧 API。

```
FFmpeg 解封装 ──┬─ 视频包 → VideoToolbox 硬解 → CVPixelBuffer → AVSampleBufferDisplayLayer
                └─ 音频包 → FFmpeg 解码 → swresample 48k 立体声 → AVAudioEngine
                                    音频渲染时间 = 主时钟
```

## 目录

| 文件 | 作用 |
| --- | --- |
| `engine.h` | C 接口：`pe_open/play/pause/seek/...`、`PeStatus` |
| `engine_darwin.m` | 媒体引擎 + 窗口/显示层/音频输出（ObjC + FFmpeg） |
| `player_darwin.go` | Go 封装：参数、状态快照、`OnUpdate`/`OnClose` 回调 |
| `player_unsupported.go` | 非 darwin/cgo 的编译占位 |
| `engine_windows.c` | Windows 引擎：FFmpeg 软解 + SDL2 渲染/音频/控件（见 `win/README.md`） |
| `player_windows.go` | Windows 的 Go 封装（与 darwin 版同一套 API） |
| `win/engine_selftest.c` | 无 Windows 实机时，在本机用同一份引擎代码做运行时自测 |
| `cmd/play/main.go` | 验证命令行，支持脚本化播放/暂停/seek/截图 |

## 线程模型

- **demux 线程**：`av_read_frame` → 视频送 VT 解码、音频解码重采样；
  队列/环形缓冲达到上限时反压，避免整片解到内存里。
- **audio 线程**：环形缓冲 → `AVAudioPCMBuffer` → `AVAudioPlayerNode`，
  维持约 0.5s 已调度音频。
- **render 线程**：以音频渲染时间为时钟，按 PTS 取帧；迟到超过 80ms 的帧丢弃。
- **主线程**：`NSApplication` 事件循环。窗口/全屏/音量等 UI 命令放在一个
  50ms 的 `NSTimer` 队列里执行（见“坑”一节）。

暂停时冻结音频时钟与画面；seek 时清空队列、`avcodec_flush_buffers`，
丢弃旧位置解出的帧，再按目标位置重新灌音频、重新锚定时钟。

## 运行

```bash
# 本地文件
go run ./player/cmd/play -file /tmp/x.mp4

# 全屏 + HTTP
go run ./player/cmd/play -file http://127.0.0.1:18080/x.mp4 -fullscreen

# 强制软解（对比 CPU）
go run ./player/cmd/play -file /tmp/x.mp4 -soft

# 脚本化验证：播放 2s → 暂停截图 → seek 20s → 再暂停截图 → 关窗
go run ./player/cmd/play -file /tmp/x.mp4 -script \
  "wait 2; pause; pos; shot /tmp/a.png; play; seek 20; wait 1.2; pause; pos; shot /tmp/b.png; closewin"
```

常用参数：`-w/-h`、`-fullscreen`、`-vol 0-100`、`-mute`、`-start 秒`、
`-status-every 秒`（0 关闭）、`-max-run 秒`、`-exit-on-end`。

脚本命令：`wait/sleep 秒`、`play`、`pause`、`toggle`、`stop`、`seek 秒`、
`seekrel 秒`、`vol`、`mute on|off`、`fullscreen on|off|toggle`、`pos`、
`shot 路径`、`closewin`、`quit`。

macOS 上 `NSApplication` 事件循环必须在主线程：调用方要
`runtime.LockOSThread()`，先 `player.Open`，再 `player.Run`（会阻塞到窗口关闭）。

## 测试素材

```bash
# 45s 1080p H.264 + AAC，画面顶部两条时间条：第 1 条 = mod(t,10)/10，
# 第 2 条 = mod(floor(t/10),10)/10，截图可反读画面 PTS
ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=45" \
  -f lavfi -i "color=black:size=1920x40:rate=30:duration=45" \
  -f lavfi -i "color=black:size=1920x40:rate=30:duration=45" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=45" \
  -filter_complex "[1:v]geq=lum='if(lt(X,W*mod(T,10)/10),235,16)':cb=128:cr=128[b1];\
[2:v]geq=lum='if(lt(X,W*mod(floor(T/10),10)/10),235,16)':cb=128:cr=128[b2];\
[0:v][b1]overlay=0:0[v1];[v1][b2]overlay=0:40,format=yuv420p[v]" \
  -map "[v]" -map 3:a -c:v libx264 -preset veryfast -b:v 8M -g 60 \
  -c:a aac -b:a 192k -movflags +faststart /tmp/player_ts_45s.mp4
```

## 实测记录（本机 macOS 27 beta，2026-11-21）

素材：`/tmp/player_ts_45s.mp4`（1920×1080 H.264 + AAC，45s）、
`/tmp/player_ts_20s_hevc.mkv`（1920×1080 HEVC + AAC 44.1k，20s）。

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 硬解确证 | 首帧像素格式 `videotoolbox_vld`；`VTIsHardwareDecodeSupported(H.264)=1` | `final_smoke.log` |
| CPU（1080p30，10s） | 硬解稳态 4.3–7.0%；软解 20–36%（约 5–6 倍） | `cpu_hw.log` / `cpu_soft.log` |
| 首帧（本地） | 408–1530ms（含建窗/音频启动；HTTP 408ms，最终冒烟 534ms） | `run10.log`、`http.log` |
| seek 20s | 响应 15–24ms；1.14s 后位置 21.13s，画面时间条读数 21.13s | `run10.log`、截图 `run10/02_seek20.png` |
| seek 5s（关键帧回退） | 92–108ms，首帧 pts=5.000 | `run3.log` |
| 暂停 | 位置冻结，画面帧 1.933s / 时钟 1.963s（差 30ms，≤1 帧），截图时间条 1.94s | `run10.log`、`01_pause.png` |
| 音画对齐 | 已显示帧 pacing 误差 avg +0.6ms、p95 5.3ms、max 9.3ms（10s 硬解） | `cpu_hw.log` |
| 全屏 | 1800×1169 逻辑点（截图 3600×2338），还原 1600×932（3200×1864） | `run9.log`、`player_shots8` |
| 窗口关闭回调 | `closewin` → `windowWillClose` → `OnClose` → 事件循环退出、进程正常结束 | `run9.log`、`run6.log` |
| 播放结束/最长运行 | `-max-run 5` 到点关闭，汇总位置 4.74s，退出码 0 | `final_smoke.log` |
| HEVC mkv | `hw=true`，首帧 1.13s，CPU 6.2–6.9%，不丢帧 | `hevc2.log` |
| HTTP | 本地 Go 文件服务器（支持 Range）播放 + seek 20s 均正常，`hw=true` | `http.log` |
| 音画实际出声 | **未验证**：系统输出为静音（volume 0 / muted true）；音频节点渲染时钟在推进 | `osascript get volume settings` |

注：一次连续跑多个播放器实例时，HEVC 那次启动到首帧花了 23.5s
（`/tmp/player_logs/hevc.log`），单独重跑为 1.13s，未复现，怀疑是上一个实例
退出后音频设备/窗口服务释放慢；正式接入前需要压一压反复开关窗口的场景。

## 已知问题与限制

- macOS / Windows 有实现；Linux 只有编译占位。
- 只做播放核心：没有字幕、音轨切换、倍速、比例、截图、循环。
- HLS（m3u8）没有验证；FFmpeg 理论上能打开，但分片/网络中断路径没测。
- 播放结束只上报 `Ended` 并暂停，没有自动关窗；DLNA 侧需要自己决定收窗时机。
- 音频实际出声未验证（系统输出静音）；只确认了音频引擎在持续消费 PCM。
- 一个进程只跑一个播放器：`NSApplication` 在 `pe_run` 里独占主线程；
  同一个进程里关掉再开新片未验证。
- 启动时会一次性建窗 + 启音频引擎，约 0.2–1.0s；HEVC 冷启动偶发更慢。
- 窗口不会主动抢前台（移除了 `activateIgnoringOtherApps:`，它会阻塞主线程）。
- **许可证**：开发机默认仍链接 Homebrew FFmpeg（GPL 构建，仅本地验证）。
  发布用的自包含 LGPL 构建见 `third_party/README.md` 与文末「自包含 LGPL FFmpeg」。

## 踩过的坑（接入前值得知道）

1. **`dispatch_get_main_queue` 在这个启动上下文里不稳定**：窗口创建、全屏、
   关窗如果都靠 `dispatch_async(main_queue)`，会出现块收不到、主线程卡在
   AppKit 里的情况。现在统一改为「主 run loop 上的 50ms NSTimer +
   命令队列」，心跳日志可判断主循环是否还在转。
2. **属性名不能和自定义 setter 撞**：`@property BOOL fullscreen` 的 setter
   就是 `-setFullscreen:`，`self.fullscreen = on` 会递归调用自己，getter
   永远是 0，表现为“全屏能进不能退”。改名为 `fsActive` 解决。
3. **暂停恢复要重新锚定时钟**：`pause` 后 `playerTimeForNodeTime:` 可能返回
   nil；沿用旧锚点会把暂停时长算进音频时钟，恢复后瞬间丢几十帧。现在先
   `play` 再读节点时间做锚点。
4. **seek 必须丢弃旧位置解出的帧**：光清队列不够，解码线程手里还有旧包；
   用 `discarding` 标志从 seek 请求一直挡到解码器 flush 完成。
5. **`drawbox` 的 `w` 不按 `t` 变**：生成时间条要用 `geq`（`T` 变量可用），
   否则截图里的“进度条”是静态图案，不能当时间证据。

## 接入现有 `screen` 接口

建议新增 `playerScreen`（`engine_pick.go` 里加一个 `native` 选项，mpv 继续兜底）：

- `Show(uri,title,vol,mute)` → `player.Open{URL:uri, Fullscreen:true, ...}`；
  首次调用前需保证主线程已经进入 `player.Run()` 的事件循环。
- `Play/Pause/Stop/Seek/SetVolume/SetMute` 直接映射到 `Player` 同名方法；
  `Close` → `Player.Close()`。
- `OnUpdate` 里把 `Position/Duration/Paused` 回填给 `Device`
  （复用 `engine_state.go` 的 `syncPosition/setDuration`），`Ended` 时调
  `onPlaybackEnded`，`Closed` 时调 `onScreenExit`。
- 关键的工程改动是**主线程归属**：当前引擎进程 `main()` 是 Go 主 goroutine，
  `player.Run()` 会阻塞到窗口关闭。要么把播放事件循环放到进程主线程常驻
  （播放请求通过 channel 进来，Open/Close 在循环内执行），要么把播放器放到
  独立子进程（那就退回和 mpv 类似的进程模型，只是换成自己的二进制）。
  前者更接近“进程内播放”，也是这次 spike 想验证的方向。
- 需要新增 `screen` 之外的进度回调（现有 `screen` 接口没有 position/duration，
  mpv 是通过 JSON IPC 单独回填的）；`player` 已经用 `OnUpdate` 提供。

## 已接入主引擎（`-player native`，2026-11-21）

接入点在 `native.go`（darwin+cgo）/ `native_windows.go`（windows+cgo）/
`native_stub.go`（其余平台占位）：

- `nativeScreen` 实现 `screen`；`engine_pick.go` 在 `-player native` 时选它，
  自动模式仍是 mpv。`main()` 先 `runtime.LockOSThread()`，起完 HTTP/SSDP 后
  进入 `nativeHost.Run()`：投屏请求经 channel 投给主线程 `player.Open`；
  播放中的 Play/Pause/Seek/音量直接调引擎（C 侧有锁，可从任意 goroutine 调）；
  关窗在主线程事件循环里做，并且要让 run loop 再跑一拍才停 NSApp。
- 状态回填：`OnUpdate` → `Device.setDuration/syncPosition`；`Ended` →
  `onPlaybackEnded`（回 STOPPED 并收窗）；用户关窗 → `onScreenExit`。
- 失败回退：`native` 打开失败 → `fallbackFrom("native")` → mpv（再 VLC/网页），
  日志会写清原因。
- 引擎侧修补（接入时才暴露）：
  1. `player_darwin.go`：`Status/do` 持读锁读 C 结构，`Close` 等 `Run` 返回后再
     拿写锁销毁；`Run/Close` 加 closing/destroyed 栅栏，避免轮询打到已释放内存。
  2. `engine_darwin.m`：eof 时把环形缓冲里不足 20ms 的音频尾巴也排空（否则
     `alen` 永不为 0、上层收不到 Ended）；队列放完且时钟到片尾才算 Ended。
  3. `engine_darwin.m`：关窗必须在事件循环还转的时候 `orderOut/close`，并在
     下一拍定时器里停 NSApp；直接停循环再关窗会留一块黑屏盖住桌面。

实测（本机 macOS，45s 1080p H.264+AAC，本地 Go Range 服务器，
`-http-port 8096 -no-ssdp -no-open -player native`）：

| 项目 | 结果 |
| --- | --- |
| 投屏 | TRANSITIONING → PLAYING，位置按 1s/s 前进；首帧 75–930ms |
| 全屏 | 1800×1169（截图 3600×2338） |
| CPU | 1080p30 硬解 3.1–5.2% |
| 暂停 | PAUSED_PLAYBACK，位置冻结（21.269 保持不动） |
| seek 20s | 位置 20.001；1.2s 后暂停在 21.269；截图时间条 bar1=12.7%、bar2=20.0%（t≈21.3s） |
| Stop | STOPPED/0，窗口撤下、屏幕回桌面；连续 3 轮 cast/stop 后仍能重开 |
| 自然播完 | 45.247s 上报 Ended → 关窗、STOPPED |
| 用户关窗 | 点窗口关闭按钮 → onScreenExit、STOPPED |
| 坏地址 | native 打不开 → 回退 mpv，日志写明原因 |

已知现象/限制：

- 窗口关掉后 `CGWindowList` 可能还留一条 onscreen 记录（AppKit 里 visible=0），
  屏幕像素已经是桌面；下一次投屏或进程退出后消失，不影响使用。
- Linux 只有编译占位：`GOOS=linux CGO_ENABLED=0 go build ./...` 通过，
  `-player native` 会回退 mpv。Windows 用 `GOOS=windows CGO_ENABLED=1` + mingw
  构建（见 `win/README.md`）。
- 本机 Homebrew FFmpeg 是 GPL 构建，只用于开发/本地验证；发布包已改用
  自包含 LGPL 构建（见下节）。

## 自包含 LGPL FFmpeg（发布用，2026-11-21）

发布版 `-player native` 不再链接 `/opt/homebrew`，改用本地源码构建的
FFmpeg 9.0.2 LGPL 动态库，随 App 放进 `Contents/Resources/engine/lib/`：

```bash
./scripts/build-native-deps.sh     # 构建 LGPL FFmpeg 到 ~/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl
./scripts/package-macos-app.sh     # 引擎用 cgo 构建，嵌入 dylib 并签名
DLNA_NATIVE_ENGINE=0 ./scripts/package-macos-app.sh   # 旧行为：不含 native
```

- 引擎与 dylib 的 `otool -L` 只出现 `@rpath/...` 与系统框架；引擎带
  `LC_RPATH=@executable_path/lib`，dylib 带 `@loader_path`，互相依赖在 App 内解析。
- 开发机不设 `PKG_CONFIG_PATH` 时仍按原样链接 Homebrew，`go run ./player/cmd/play`
  等开发流程不变。
- 许可文本、替换库与源码获取方式见 `third_party/README.md`；仓库内副本在
  `third_party/licenses/ffmpeg/`。
- 实测（App 内引擎、`env -i` 干净环境）：H.264/HEVC 均 `videotoolbox_vld` 硬解，
  seek 20s 首帧 pts=20.000，Stop 后正常关窗退出；运行时加载的 libav* 全部来自
  App 内 `engine/lib`。

## 完整化（2026-11-22）

HLS（TS/AES）、音轨/字幕、倍速、比例、循环、截图与自绘控件已实现，详见
[`NATIVE-FULL.md`](NATIVE-FULL.md)。HLS fMP4 仍有已知限制，文中列明。
