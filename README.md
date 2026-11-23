# DLNA 电视模拟器（dlna-tv-sim）

[![build](https://github.com/cxb-soft/dlna-tv-sim/actions/workflows/build.yml/badge.svg)](https://github.com/cxb-soft/dlna-tv-sim/actions/workflows/build.yml)

把电脑当成一台 DLNA 电视：手机、平板、播放器在「投屏」列表里能看到它，点一下就把视频推到电脑上全屏播放。

对外表现是一台标准的 UPnP/DLNA **MediaRenderer（DMR）**，不是只做界面模仿：
发现、设备描述、三套标准服务、事件订阅、状态机、错误码都按规范实现，VLC、nPlayer、绝大多数视频 App 的投屏都能直接对接。

> 网页兜底播放器内嵌了 hls.js（Apache-2.0），源码在 `web/hls.min.js`。

## 桌面应用（macOS，推荐）

双击 `DLNA 电视.app` 就能用：Flutter 原生窗口 + 内置 Go 引擎，不依赖浏览器，也不会弹终端。

- 首次启动 macOS 会问一次「允许 DLNA 电视查找本地网络设备」，必须允许，否则手机搜不到这台电视；之后不再询问。
- 播放仍由 mpv 全屏完成；没装 mpv 时回退网页播放器。
- 有新版本时窗口顶部会出现更新横幅，点「立即更新」会自动下载、校验 SHA256、替换旧包并重启。
- 打包：`./scripts/package-macos-app.sh`，产物 `dist/dlna-tv-sim-macos-app.zip`（含引擎、Developer ID 签名）。

## 快速开始

### macOS

双击 `dist/启动电视.command`（**推荐**），它会在 Terminal 里启动程序。

为什么强调用这个脚本：macOS 的「本地网络」权限是跟 App 身份走的，直接双击可执行文件、或由别的 App 拉起时，系统可能不给这个进程本地网络权限，表现就是 SSDP 组播发不出去（`no route to host`），手机永远搜不到。从 Terminal 启动则沿用 Terminal 的权限，组播正常。

也可以在终端里手动跑：

```bash
./dist/dlna-tv-sim-macos-arm64          # Apple 芯片
./dist/dlna-tv-sim-macos-amd64          # Intel
```

启动后会自动打开控制台网页（`http://127.0.0.1:8090/`）。第一次运行时，系统会问「本地网络」权限，务必允许——不允许的话局域网里根本发不出组播，手机也就搜不到这台电视。

### Windows

解压 `dlna-tv-sim-windows-x64.zip`，双击 `dlna-tv-sim-windows-x64.exe`。首次运行如果弹出防火墙提示，勾选「专用网络」并允许（需要 UDP 1900 和 TCP 8090）。

**mpv 已经内置在包里**（`mpv\mpv.exe`），解压即用，不需要另外安装播放器；m3u8/ts/mkv/HEVC/AV1 都能播。

如果不想用内置的，也可以自己装 VLC，程序会依次找 `mpv\mpv.exe` → 同目录 `mpv.exe` → 系统 VLC；都没有时退回浏览器播放（`/screen`，只支持浏览器能解的格式）。

内置 mpv 是 shinchiro 的官方构建，GPLv2，许可证全文在包里的 `LICENSE-mpv.txt`。

## 它模拟了什么

- **SSDP 发现**：响应 M-SEARCH（`ssdp:all`、`upnp:rootdevice`、设备类型、三个服务类型），启动时发 `ssdp:alive`，退出时发 `ssdp:byebye`；组播发不出去时自动补一条子网广播通告。
- **设备描述**：`/dmr.xml`，含 `DMR-1.50` 声明、图标、presentationURL、三个服务的控制/事件地址。
- **AVTransport**：`SetAVTransportURI`、`SetNextAVTransportURI`、`Play`、`Pause`、`Stop`、`Seek`、`Next`、`Previous`、`SetPlayMode`、`GetMediaInfo`、`GetTransportInfo`、`GetPositionInfo`、`GetDeviceCapabilities`、`GetTransportSettings`、`GetCurrentTransportActions`。
- **RenderingControl**：`GetVolume`/`SetVolume`、`GetMute`/`SetMute`、`GetVolumeDB`/`SetVolumeDB`/`GetVolumeDBRange`、`ListPresets`/`SelectPreset`。
- **ConnectionManager**：`GetProtocolInfo`（一大串 Sink 协议表）、`GetCurrentConnectionIDs`、`GetCurrentConnectionInfo`。
- **GENA 事件**：`SUBSCRIBE`/续订/`UNSUBSCRIBE`，订阅成功立刻推一次全量 `LastChange`，之后按变化推，带递增 `SEQ`。
- **播放**：真的去拉媒体地址（记录状态码、Content-Type、大小），真的调用播放器全屏播放，进度/时长/播完回待机都同步回设备状态。
- **错误码**：401 未知动作、402 参数非法、701 状态不允许、706 连接引用非法、710 Seek 模式不支持、711 非法 Seek 目标、712 播放速度不支持、718 InstanceID 非法。

## 网页控制台

`http://<本机IP>:8090/`

**播放**：播放/暂停/停止、后退/前进 10 秒、进度拖动、音量/静音。

**高级控制**（能力随引擎变化）：

| 功能 | mpv | 网页 | VLC |
| --- | --- | --- | --- |
| 倍速 0.5–2× | ✅ | ✅ | — |
| 循环播放 | ✅ | ✅ | — |
| 画面比例（自动/16:9/4:3/21:9） | ✅ | — | — |
| 音轨 / 字幕轨切换 | ✅ | — | — |
| 截图 | ✅ | — | — |
| 码率 / 帧率 | ✅ | — | — |

音轨和字幕是从播放引擎读的真实轨道列表（标题、语言、编码），切换直接作用于 mpv；不是页面上的假按钮。

**其他**：手动投一个地址（模拟手机投屏）、最近投过的地址、改设备名、网络自检、事件流（M-SEARCH、SOAP、事件推送、拉流、代理都实时打出来）。

快捷键：空格播放/暂停、← → 跳 10 秒、↑ ↓ 音量、M 静音、F 全屏、S 截图。

`/screen` 是无边框全屏播放页，给浏览器兜底播放用：有缓冲转圈、解码失败提示和进度条。

## 常用参数

```
-http-port 8090    HTTP 端口（默认 8090）
-name "客厅电视"    设备名，会写进配置
-uuid <uuid>       固定设备 UUID
-player auto       auto | mpv | vlc | web | native（macOS/Windows 自研核心）
-no-ssdp           只跑 HTTP，不参与发现（排查用）
-no-open           启动后不自动开浏览器
-v                 详细日志
```

配置文件在 `~/Library/Application Support/dlna-tv-sim/config.json`（Windows 是 `%AppData%\dlna-tv-sim\config.json`），UUID 会持久化，控制点不会把设备当成新的。

## 自研播放引擎（macOS / Windows，可选）

`-player native` 会启用进程内的自研播放核心，不依赖外部 mpv/VLC：FFmpeg(LGPL) 解封装、VideoToolbox 硬解、AVSampleBufferDisplayLayer 显示、AVAudioEngine 出声，音频时钟对时；播放器控件也是自绘的（进度、音量、倍速、音轨、字幕、比例、全屏、自动隐藏、快捷键）。

- macOS：mp4/mkv/HLS（TS、fMP4、AES-128）、H.264/HEVC 硬解、AAC/AC3/MP3、SRT/ASS 文本字幕、多音轨、倍速 0.5–2×、画面比例、循环、截图。
- Windows：FFmpeg 软解 + SDL2（D3D11 渲染）+ WASAPI 音频，音频时钟对时，起播首帧后再开声、seek 立即定位，自绘控制条（标题/设备、进度/时间、播放/±10s、音量、倍速/音轨/字幕/比例菜单、截图、全屏）；支持 mp4/mkv/HLS、H.264/HEVC/AV1 软解、AAC/AC3/MP3、SRT/ASS 字幕（libass 渲染，字体与排版按脚本还原）、多音轨、seek/暂停/倍速/音量/全屏/截图。需要包里自带的 `SDL2.dll`、`avcodec-63.dll`、`avformat-63.dll`、`avutil-61.dll`、`swresample-7.dll`、`swscale-10.dll`，以及字幕用的 `libass-9.dll`、`libfreetype-6.dll`、`libfribidi-0.dll`、`libharfbuzz-0.dll`、`libunibreak-7.dll`。
- 默认仍是 mpv；native 是可选引擎，遇到打不开的源会自动回退 mpv。
- 限制：macOS 的 ASS 只渲染文本（字体/定位/特效不还原），本地 HLS fMP4 起播约 5 秒（HTTP 正常）；Windows 目前是软解，倍速用重采样实现会有音调变化；Linux 暂无 native，会回退 mpv。
- 打包：`scripts/build-native-deps.sh` 构建 LGPL FFmpeg，`scripts/package-macos-app.sh` 会把 dylib 嵌进 App（体积约 +5MB）。Windows 用 `scripts/fetch-win-deps.sh` 下载 SDL2/FFmpeg 并交叉编译 libass 及依赖，`scripts/build-windows-native.sh` 交叉编译并把 DLL 摊进包。许可义务见 `third_party/README.md`。

## 已知限制

- **组播被拦截时发现会失效**。本机如果装了带 TUN 的代理（如 Clash Verge），它可能给 `224.0.0.0/4` 装上 reject 路由，程序发 SSDP 会直接 `no route to host`。程序会自动尝试子网广播兜底，但最可靠的办法是在代理里放行局域网和组播，或临时关掉 TUN。
- 只实现 DLNA/UPnP 的 DMR。AirPlay、Google Cast、Miracast 是另外的协议，不在范围内。
- 手机 App 的「屏幕镜像」多数走 AirPlay/Cast，不会出现在 DLNA 列表里；要用 App 内的「投屏」按钮。
- 网页兜底播放受浏览器解码能力限制，只适合 mp4/HLS 这类；ts、mkv 要靠 mpv/VLC。
- 网页兜底播放要能拖进度，媒体服务器必须支持 HTTP Range；不支持 Range 的源（如 `python -m http.server`）在浏览器里会被判成不可跳转。mpv/VLC 引擎不受影响。
- 未做厂商私有扩展（Samsung/LG 的附加服务），标准 DMR 行为完整。

## 开发

```bash
go test ./...        # 单元 + 端到端（订阅、投屏、播放、错误码）
./build.sh           # 产出 dist/ 下 mac/Windows/Linux 各平台可执行文件
```
