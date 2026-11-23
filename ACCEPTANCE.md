# 验收清单

目标：别人拿到这台电脑，手机/平板能在投屏列表里看到它，点一下电脑全屏播放，遥控器（播放/暂停/停止/音量/进度）都有效。

## 场景

1. **首次启动（macOS）**
   - 双击/运行产物，控制台网页自动打开，能看到设备名、地址、引擎。
   - 系统询问「本地网络」权限时允许。
   - 页面右上角订阅数/调用数从 0 开始，事件流有 SSDP 通告记录。

2. **首次启动（Windows）**
   - 解压后双击 exe，控制台网页打开。
   - 防火墙弹窗允许（专用网络）。
   - 同目录放了 `mpv.exe` 时，页面「播放引擎」显示 mpv；否则显示 web 或 vlc。

3. **发现**
   - 手机/平板与电脑同一 Wi-Fi（同一网段）。
   - 视频 App 的「投屏」列表里出现配置的设备名。
   - 退出程序后，列表里的设备消失（bye-bye）。

4. **投屏播放**
   - 选中设备后，电脑全屏播放该视频，没有地址栏/播放器控件。
   - 网页控制台显示：状态 PLAYING、标题、进度在走、拉流成功（状态码/Content-Type/字节数）。
   - 视频播完自动回到 STOPPED。

5. **遥控**
   - 暂停：画面停住，状态 PAUSED_PLAYBACK，进度冻结。
   - 继续：从原位置继续。
   - 停止：回到 STOPPED，进度归零。
   - 音量/静音：声音变化，事件里有 Volume/Mute。
   - 进度拖动：跳到对应位置。

6. **错误路径**
   - 没有媒体时点播放 → 手机端提示失败（UPnP 701）。
   - 投一个坏地址（例如 `http://127.0.0.1:1/x.mp4`）→ 拉流失败，状态回到 STOPPED，日志有原因。

7. **多控制点**
   - 手机 App 与网页控制台同时连接，状态互相同步。
   - 控制点退订后不再收到事件。

8. **网页兜底**
   - 删掉/改名 mpv、VLC 后启动，引擎显示 web。
   - 从网页投一个 mp4，`/screen` 页面全屏播放（浏览器允许自动播放时）。

## 已验证（本机 macOS 26/27 beta，2026-11-21）

- **真实设备投屏跑通**：iPad 上的视频 App 发现设备后，依次调用 `SetAVTransportURI` → `Play` → `Seek` → 持续 `GetTransportInfo`/`GetPositionInfo`/`GetVolume`/`GetCurrentTransportActions`，mpv 全屏播放该集（mkv，47 分钟），进度同步。片子由 iPad 自己在链接本地网络上提供（`http://169.254.149.65:50431/...`）。
- **控制台高级控制（mpv）**：投带双音轨双字幕的 mkv 后，`/api/player` 返回 2 条音轨（English/Chinese，aac）与 2 条字幕（EnglishSub/ChineseSub，subrip）；切到中文音轨、中文字幕后 selected 正确翻转；画面比例 4:3、倍速 2× 均生效；截图返回 HTTP 200、40026 字节 PNG（640×360）。
- **控制台高级控制（网页引擎）**：能力表只报 `speed`/`loop`；倍速 1.5×、循环开关都写进设备状态；非法比例返回 409；网页引擎下截图返回 409（不支持）。
- **网页播放时长与结束**：网页播放器把 `duration` 上报给设备（`/api/report`），DLNA 侧不再永远是 0；播完上报 `ended`，设备回到 `STOPPED`、进度归零（日志「播放结束」）。
- **控制台 UI**：Chromium 1440×900 下实际打开，页面无 console 报错；倍速菜单、循环、进度、音量、日志、自检都能操作；待机时设备卡显示「mpv 全屏」而不是误报「网页播放」。
- **进度条**：seek 时屏幕底部出现进度条与时间（截图确认 `00:11:32 / 00:47:04 (25%)`）。
- **组播权限坑**：同样的发包代码，在 Friend 的 agent 进程里报 `no route to host`，用 Terminal 身份运行则正常。macOS 的本地网络权限按 App 身份隔离，所以推荐用 `启动电视.command` 双击启动。
- `go test ./...` 全绿（描述/SCPD 解析、订阅与事件 SEQ、状态机、Seek、音量、错误码、HLS 改写、SSDP 报文构造，以及新增的倍速/比例/轨道校验、`/api/player`、`/api/report`）。
- 环回单播 M-SEARCH → 正确 200 OK（LOCATION/ST/USN/EXT/CACHE-CONTROL）。
- 网页控制台可打开、可投屏、日志实时。

## 桌面应用（2026-11-21）

- **启动不带终端**：`DLNA 电视.app` 双击启动，Flutter 窗口正常显示，引擎作为子进程拉起（`Contents/Resources/engine/dlna-tv-sim -no-open -http-port 8090`），退出 App 后引擎被回收。
- **签名**：Developer ID 签名，`codesign --verify --deep --strict` 通过；引擎单独签名（`--deep` 不重签裸二进制）。
- **更新检查**：真实请求 GitHub Releases，当前 v0.3.0 时能显示「有新版本」横幅并带更新说明。
- **待确认**：首次启动的本地网络授权弹窗已出现（截图确认），需用户点 Allow 后才能验证组播与手机发现；未点之前 `/api/diag` 仍是 `multicast false`。

## 自研播放引擎（2026-11-22，macOS）

`-player native` 实测（测试实例 8096/8097，独立 HOME，未动 8090）：

- HLS：HTTP TS 首帧 1.2s、seek 43ms；HTTP fMP4 首帧 673ms、30fps、零丢帧；本地 AES-128 首帧 0.48s、seek 44ms；TS/fMP4 均能收到 ended。
- 音轨/字幕：双音轨 mkv 切 AAC→AC3 110ms；SRT/ASS 切换 42–93ms，cue 文本与时间对得上；字幕为自绘渲染。
- 倍速 1.5×（0.6s 墙钟推进 0.9s 媒体时间）、比例 16:9/4:3、循环回开头、PNG 截图均实测。
- 播放器 UI：自绘控件层（scrim、琥珀主题、SF Symbols、进度 hover 气泡、音轨/字幕菜单、自动隐藏、快捷键、缓冲 spinner、错误 toast）；1280×720 与 1800/1920 两组截图在 `/tmp/pe_shots/`；真实鼠标（cliclick）验证 hover/拖进度/菜单/双击全屏，点击热区统一 40pt。
- App 联调：`/api/cast` → `PLAYING`、engine native、硬解；`/api/player` 能力与真实能力一致；Stop 后回 `STOPPED` 并关窗。
- 打包：LGPL FFmpeg 9.0.2 动态库随 App（`Contents/Resources/engine/lib/`），`env -i` 干净环境启动、`lsof -p` 确认加载的是 App 内 dylib；App 28MB → 33MB。

未验证：ASS 高级排版（未引 libass）、HLS HEVC/加密 fMP4/master playlist、本地 fMP4 起播慢、Windows/Linux native。

## Windows mpv IPC 不再卡指令（2026-11-23，0.5.3）

现象：iPad 投到 Windows（mpv 引擎）时，暂停后按播放没反应、遥控按钮一直转；一集播完点下一集停在「电视正在缓冲」。日志里 SOAP Play 20 秒超时（设备其实已报 PLAYING）、Stop 12 秒超时、TRANSITIONING 持续 30 秒、下一集卡在旧画面。

原因：`ipc_windows.go` 用 `os.OpenFile` 打开 mpv 的命名管道，拿到的是同步句柄（FILE_SYNCHRONOUS_IO_NONALERT）。Windows 会把同一同步句柄上的 I/O 串行化，`readLoop` 一直挂着 ReadFile，于是每次写指令都要等 mpv 发出下一条事件。播放中 `time-pos` 不停地推，看不出来；mpv 暂停、空闲或卡在取流时什么都不发，Play/Stop/`loadfile` 就卡十几秒甚至更久。

改法：
- `dialIPC` 改用 `O_FILE_FLAG_OVERLAPPED` 打开管道（Go 1.26 的 `os.OpenFile` 支持），句柄进 Go 运行时的 IOCP，读写互不等待；`Close` 用 CancelIoEx 打断挂着的读。unix 套接字路径不变。
- 写 IPC 统一走 `writeIPC`：一次一整行（`writeMu` 串行化），普通指令 3 秒写超时，退出时的 `quit` 1 秒，mpv 整个卡死时不会把 SOAP 请求或退出流程挂住。

已验证（Wine 10 跑 windows/amd64 测试，模拟 mpv 的重叠 I/O 服务端管道）：
- `TestIPCHandleIsOverlapped`：旧代码得到 mode=0x20（同步句柄）判失败，新代码通过。Wine 不模拟同步句柄的串行化，所以这条直接检查句柄模式。
- 读挂着时写 `pause`/`stop`/`loadfile` 立即送达；挂着读时写 `quit` + `Close` 不卡、读返回；服务端不读时写入 300ms 超时返回（旧的同步句柄这里会一直卡住）。
- Windows 全量测试在 Wine 下通过；macOS `go test ./...`、`-race` 通过；windows/amd64、windows/arm64 交叉编译通过。

未验证：Windows 实机 + 真实 mpv.exe 上的暂停后播放、播完下一集（需在 Windows 机器上投屏确认）。

## 未验证

- Windows 实机运行（只做了交叉编译）。
- 厂商私有扩展（Samsung/LG 附加服务）未实现。
