# DLNA 电视 · Flutter 桌面端

macOS / Windows / Linux 的桌面窗口，负责界面与控制；播放仍然交给 Go 引擎（mpv 全屏），
引擎作为后台子进程启动，不经过 shell、不会弹终端。

## 代码结构

- `lib/main.dart`：入口，先渲染界面再连接引擎（避免白屏）
- `lib/src/app.dart`：应用外壳与退出处理
- `lib/src/theme.dart`：配色、字号层级、控件主题
- `lib/src/controller/app_controller.dart`：唯一状态源——引擎生命周期、轮询、指令、投屏、自检、更新
- `lib/src/services/engine_client.dart`：本机引擎 HTTP 客户端
- `lib/src/services/engine_manager.dart`：找引擎、起引擎、收引擎
- `lib/src/services/update_service.dart`：GitHub Release 检查（只提示，安装接口预留）
- `lib/src/models/`：状态、日志、自检、更新模型
- `lib/src/ui/`：顶栏、播放卡片、投屏/设备/自检面板、事件流
- `test/`：单元测试与 UI 接线测试（用假的控制器，不联网）

## 引擎查找顺序

1. 环境变量 `DLNA_TV_SIM_ENGINE`
2. 打包后的位置：
   - macOS：`DLNA 电视.app/Contents/Resources/engine/dlna-tv-sim`
   - Windows：`engine\dlna-tv-sim.exe`
   - Linux：`engine/dlna-tv-sim`
3. 开发期：从可执行文件和当前目录往上 14 层找 `dist/dlna-tv-sim-<平台>-<架构>`

`GET /api/state` 已经有响应的引擎会被直接复用，不会重复启动；退出 App 时只结束自己拉起的那个。

## 开发与调试

```bash
cd ui
flutter run -d macos --debug     # 热重载调界面
flutter analyze && flutter test
flutter build macos --debug
open "build/macos/Build/Products/Debug/DLNA 电视.app"
```

调试用环境变量：

| 变量 | 作用 |
| --- | --- |
| `DLNA_TV_SIM_PORT` | 引擎端口，默认 8090；测试请用 8091/8092 |
| `DLNA_TV_SIM_APP_VERSION` | 覆盖 App 版本，用来演练「有新版本」横幅 |
| `DLNA_TV_SIM_ENGINE` | 直接指定引擎可执行文件 |

## 已知限制

- 自动安装没有实现：`UpdateService.install()` 返回提示文案，替换安装由打包流程接入。
- Windows 退出时回收引擎：macOS 用 AppKit 的 `applicationWillTerminate` 兜底，
  Windows 目前依赖 Dart 的退出回调，后续应在 runner 里用 Job Object（KILL_ON_JOB_CLOSE）。
- `NSLocalNetworkUsageDescription` 已写进 Info.plist，但只有以 `.app` 身份运行时才会真正弹权限框。
