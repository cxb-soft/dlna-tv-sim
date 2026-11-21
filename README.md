# DLNA 电视模拟器（dlna-tv-sim）

[![build](https://github.com/cxb-soft/dlna-tv-sim/actions/workflows/build.yml/badge.svg)](https://github.com/cxb-soft/dlna-tv-sim/actions/workflows/build.yml)

把电脑当成一台 DLNA 电视：手机、平板、播放器在「投屏」列表里能看到它，点一下就把视频推到电脑上全屏播放。

对外表现是一台标准的 UPnP/DLNA **MediaRenderer（DMR）**，不是只做界面模仿：
发现、设备描述、三套标准服务、事件订阅、状态机、错误码都按规范实现，VLC、nPlayer、绝大多数视频 App 的投屏都能直接对接。

> 网页兜底播放器内嵌了 hls.js（Apache-2.0），源码在 `web/hls.min.js`。

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

解压 `dlna-tv-sim-windows-x64.zip`，双击 `dlna-tv-sim.exe`。首次运行如果弹出防火墙提示，勾选「专用网络」并允许（需要 UDP 1900 和 TCP 8090）。

播放引擎：

- **推荐**：把 `mpv.exe`（免安装版）放到 exe 同一个目录下，程序会自动用它，格式支持最全（m3u8/ts/mkv/HEVC 都行）；
- 或者装一个 VLC，程序也会自动找到；
- 两个都没有时，会退回浏览器播放（`/screen` 页面），只支持 Chrome/Edge 能解的格式。

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

- 看当前状态、播放内容、拉流结果；
- 遥控器：播放/暂停/停止/音量/静音/进度；
- 手动投一个地址（模拟手机投屏），方便测试；
- 改设备名（会写进配置，重启后仍生效）；
- 事件流：M-SEARCH、SOAP 动作、事件推送、拉流、代理都实时打出来。

`/screen` 是无边框全屏播放页，给浏览器兜底播放用。

## 常用参数

```
-http-port 8090    HTTP 端口（默认 8090）
-name "客厅电视"    设备名，会写进配置
-uuid <uuid>       固定设备 UUID
-player auto       auto | mpv | vlc | web
-no-ssdp           只跑 HTTP，不参与发现（排查用）
-no-open           启动后不自动开浏览器
-v                 详细日志
```

配置文件在 `~/Library/Application Support/dlna-tv-sim/config.json`（Windows 是 `%AppData%\dlna-tv-sim\config.json`），UUID 会持久化，控制点不会把设备当成新的。

## 已知限制

- **组播被拦截时发现会失效**。本机如果装了带 TUN 的代理（如 Clash Verge），它可能给 `224.0.0.0/4` 装上 reject 路由，程序发 SSDP 会直接 `no route to host`。程序会自动尝试子网广播兜底，但最可靠的办法是在代理里放行局域网和组播，或临时关掉 TUN。
- 只实现 DLNA/UPnP 的 DMR。AirPlay、Google Cast、Miracast 是另外的协议，不在范围内。
- 手机 App 的「屏幕镜像」多数走 AirPlay/Cast，不会出现在 DLNA 列表里；要用 App 内的「投屏」按钮。
- 网页兜底播放受浏览器解码能力限制，只适合 mp4/HLS 这类；ts、mkv 要靠 mpv/VLC。
- 未做厂商私有扩展（Samsung/LG 的附加服务），标准 DMR 行为完整。

## 开发

```bash
go test ./...        # 单元 + 端到端（订阅、投屏、播放、错误码）
./build.sh           # 产出 dist/ 下 mac/Windows/Linux 各平台可执行文件
```
