# native 播放核心完整化（2026-11-22）

这一轮把 `-player native` 从 spike 补到可日常使用：HLS、音轨/字幕、倍速、画面比例、循环、截图，以及一套自绘播放器控件。默认引擎仍是 mpv；`-player native` 才走这里。

## 能力

| 能力 | 实现 | 状态 |
| --- | --- | --- |
| HLS | LGPL FFmpeg 增加 hls/mpegts demuxer、aac_adtstoasc、crypto 协议；本地/HTTP 的 TS 分片、AES-128 均可播、可 seek | HTTP TS 1.2s/seek 43ms；HTTP fMP4 673ms、30fps；本地 fMP4 约 5s（音频先读） |
| 音轨 | 枚举语言/标题/编码/声道；切轨重建解码器 + seek 到当前位置 + 重锚音频时钟 | AAC/AC3 双音轨实测 |
| 字幕 | SRT/ASS/SSA/mov_text/WebVTT 解码 + 自绘；Matroska ASS 包（8 逗号）与 Dialogue 行（9 逗号）都能解析，剥 `{\...}` 标签 | SRT/ASS 实测 |
| 倍速 | `AVAudioUnitTimePitch.rate`，0.25–4×，变速不变调；UI 提供 0.5–2.0× | 1.5× 实测 0.6s 墙钟走 0.9s 媒体 |
| 比例 | auto / 16:9 / 4:3 / fill；16:9、4:3 用独立视频层矩形做黑边，fill 用 `ResizeAspectFill` | 截图确认 |
| 循环 | 结尾自动 seek 0 并重锚时钟 | 18.5s→0.13s |
| 截图 | 保留最近一帧 CVPixelBuffer，CIContext→CGImage→PNG（不含控件） | 实测 PNG |
| 缓冲/错误 | 状态 `buffering`/`io_error`；UI 居中 loading、顶部 toast | 已实现 |
| 控件 | AppKit/CoreAnimation 全自绘，深色影院风，与应用主题同色 | 10+ 张截图 |

## UI

- 顶部：媒体标题 + 设备名/投屏中 + `H.264 · 1280×720 · 30fps · 硬解`。
- 底部：48pt 琥珀播放/暂停、±10s、音量滑块/静音、倍速/音轨/字幕/比例胶囊、全屏、关闭；进度条含已播/缓冲/悬停预览气泡和时间；热区 ≥ 40pt。
- 鼠标移动淡入、静止 2.5s 淡出（暂停/菜单/拖动不淡出）；悬停高亮；拖进度/音量；单击画面播放暂停（0.22s 延迟规避双击）、双击全屏；空格、←→、↑↓、M、F、S、Esc。
- 菜单：倍速（含循环开关）、音轨、字幕（关闭+各轨）、比例，自绘面板/勾选/悬停。
- 打开黑场 0.55s 淡入；关闭按钮 0.22s 淡出后收窗；DLNA Stop 0.18s 窗口淡出。
- 截图在 `/tmp/pe_shots/`：`10_controls.png`（控件+进度悬停）、`11_audio_menu.png`、`12_paused.png`、`13_sub_srt.png`、`14_sub_ass.png`、`15_aspect43.png`、`16_aspect169.png`、`17_loop.png`、`18_hls_ts.png`、`20_hidden.png`（控件淡出）、`21_buffering.png`（fMP4 起播缓冲）。均为 `screencapture -l<window>` 窗口原图，不是合成图。

## 验证结果（macOS 27 arm64）

- 1080p H.264+AAC mp4：硬解，首帧 0.4–1.5s，pacing p95 5–7ms，CPU 3–9%。
- 1080p HEVC mkv：硬解，首帧约 1.1s，CPU 6–7%。
- 双音轨/双字幕 mkv：2/2 枚举；AAC→AC3 切轨 110ms；SRT→ASS 42–93ms，cue 文本/时间正确。
- HLS TS（本地/HTTP）：HTTP 首帧 1.2s、seek 10s 43ms；本地首帧 0.5–2.3s、seek 37–259ms；播完 `ended=true`（TS demuxer 不报 EOF 时按 duration 兜底）。
- HLS fMP4：HTTP 首帧 673ms、30fps、零丢帧（7.5s/93 帧）；本地文件约 5s 起播后 30fps（长跑 10.8s/178 帧）；seek 15–162ms，播完 `ended=true`。
- 片尾兜底：duration 到片尾后连续 1.2s 无进展就上报 Ended；TS/fMP4 都验证，loop 同样回开头。
- 纯视频 mp4 / 纯视频 fMP4 HLS：30fps，位置正常推进（无音轨时引擎用墙钟起步）。
- HLS AES-128：放行密钥扩展名后首帧 0.48s，seek 44ms。
- LGPL 依赖重编后（`PKG_CONFIG_PATH=…/ffmpeg-lgpl/lib/pkgconfig`）：HLS TS + ASS 字幕通过；`otool -L` 只有 `@rpath/libav*`。

## 已知限制

- **本地文件 fMP4**：FFmpeg 9.0.1 的 hls+fMP4 对本地文件会先灌入约 5 秒音频再出视频，起播慢；HTTP 同一份 fMP4 首帧 673ms、30fps 正常。TS/AES 本地/HTTP 都正常。
- ASS 只渲染纯文本，定位/字体/颜色/特效不还原。
- AES 本地密钥常是 `.bin`，FFmpeg 默认按扩展名拦截；引擎设 `allowed_extensions=ALL`（仅本地文件）放行。
- HLS HEVC、加密 fMP4、master playlist 未实测。
- Linux 仍是编译占位，`-player native` 回退 mpv；Windows 已有独立实现（见 `player/win/README.md`）。一个进程仍只跑一个窗口。

## 视觉重做（2026-11-22，父链评审后）

按父链 9 条清单完成一轮视觉重做，实现在 `player/player_ui_darwin.m`：

- 底部 180pt `0 → 0.82` 黑 scrim，顶部 120pt `0.45 → 0`；控件不再直接压在亮画面上。
- 唯一强调色改为 `#F2C27C → #D99447` 琥珀渐变；其余全部中性白 0.92/0.55/0.28、黑 0.5；去掉了米色块和粉色胶囊。
- 全部图标换成 SF Symbols（18pt medium、白 0.92）：`play.fill`/`pause.fill`、`gobackward.10`/`goforward.10`、`speaker.wave.2.fill`/`speaker.slash.fill`、全屏双向箭头、`xmark`、菜单 `checkmark`、toast 图标。
- 顶部：15pt semibold 媒体名 + 11pt 白 0.55「DLNA 电视 · 投屏中」+ 6pt 琥珀点；右上格式信息收进 11pt 深色半透明胶囊。
- 底部：24pt 边距、4pt 进度条（轨道 0.18/缓冲 0.28/已播琥珀渐变/12pt 白色 hover 点）、11pt tabular 时间、40pt 圆形播放键（白 0.10 → 0.18、按下 0.96）、36pt ±10s/音量、右侧 12pt 圆角胶囊组、全屏/关闭圆形按钮。
- 菜单：280pt 宽、12pt 圆角、11pt 分组标题、36pt 行高、13pt/11pt 两级文字、hover 白 0.06、选中琥珀对勾；打开 120ms 上移 4pt + 淡入。
- 动效：控件淡入 180ms ease-out、淡出 220ms，出现整体上移 6pt；hover 120ms；缓冲 2pt 琥珀圆环；toast 深色胶囊 3s。
- 缓冲判定改为看 `frames_shown` 是否停滞（有视频时），避免 fMP4 音频时钟继续走、视频已停却显示“播放中”。

### 验收截图（真实鼠标，`cliclick`）

- 1280×720：`70_1280_controls.png`、`71_1280_hover.png`、`72_1280_menu.png`、`73_1280_menu_selected.png`、`74_1280_paused.png`、`75_1280_seek.png`、`76_1280_fullscreen_1920.png`、`78_1280_buffering.png`。
- 1920×1080：`80_1920_controls.png`、`81_1920_hover.png`、`82_1920_menu.png`、`83_1920_menu_selected.png`、`84_1920_paused.png`、`85_1920_seek.png`、`86_1920_fullscreen.png`、`88_1920_buffering.png`。
- 真实鼠标覆盖：hover 进度、点击音轨胶囊、选中文轨、点击播放/暂停、拖进度、双击全屏；日志出现 `paused=true`、`seek 28ms`、`全屏切换 on=1 窗口 1800x1169`，3 音轨/2 字幕均识别。

### 限制说明

- 本机屏幕逻辑宽 1800（全屏 1800×1169）。1920 大屏组是把 1800×1080 窗口内容放大到 1920×1080（横向 6.7%），全屏组是 1800×1169 等比缩放进 1920×1080（左右留黑）。若必须严格 1920×1080 布局，需要改显示模式后再截。
- 错误 toast 已实现（深色胶囊 + 图标 + 3s），本轮截图集中验证了缓冲态，没有单独截错误态。
- 本地 fMP4 起播约 5s 的引擎限制不变；HTTP fMP4 正常。ASS 高级样式、HLS HEVC/加密 fMP4 仍未覆盖。

## 字幕：libass 与默认轨（2026-11-22）

- 默认字幕轨：`pe_open` 在 `subtitle_track == 0` 时设 `sub_auto=1`，`open_media` 自动选第一条字幕流；UI「字幕」胶囊显示当前轨，用户点「关闭字幕」走 `pe_set_subtitle_track(0)` 显式关闭。CLI 新增 `-sub N`（0=自动）。
- 渲染：引入 libass 0.17.5（ISC），保留 Matroska/ASS 的 CodecPrivate 样式头与事件 Style 名（`Top`/`Red`/`Default`），把 FFmpeg 的 ASS/SRT 事件文本构造成 `Dialogue` 行交给 libass，解析 `\pos`/`\an`/`\fs`/颜色/描边；引擎合成整帧 RGBA，UI 按视频 content rect 缩放叠加。缺字体时 libass 回退系统 PingFang/Helvetica。
- 验证截图（1280×720，真实窗口，控件已隐藏）：
  - 4s：`/tmp/pe_shots/ass_final_4.png`，Top 样式黄色，`\pos(640,80)` 顶部居中。
  - 10s（原素材）：`/tmp/pe_shots/ass_final_10.png`，Red 样式红色，落在底部居中——**原素材这条事件是字面量 `红色字幕 RED POS(200\,500)`，没有 `{\pos...}` 标签**，libass 按 Red 的 Alignment 2 渲染，不是引擎丢标签。
  - 18s：`/tmp/pe_shots/ass_final_18.png`，Top 样式黄色，`\an8` 顶部居中。
  - seek 到 10s：`/tmp/pe_shots/ass_seek_10_fix.png`，预取后仍显示 9–13s 红色字幕。
  - SRT：`/tmp/pe_shots/ass_srt_2.png`；日志 `/tmp/sub_srt_full.log` 记录 2.000..6.000、8.000..12.000、16.000..20.000 三条 cue。
- 时间日志：
  - ASS `/tmp/sub_final_4.log` 3.000..7.000，`/tmp/sub_final_10.log` 9.000..13.000，`/tmp/sub_final_18.log` 17.000..21.000；暂停位置 3.989/10.197/18.197。
  - seek：`/tmp/seek_fix.log` 出现 `seek 字幕预取：0.000..10.000`，cue 3–7、9–13，暂停后当前字幕非空。
- seek 预取：`perform_seek` 先 seek 到 target-10，只解字幕包，再 seek 回 target；解决跨目标事件（9–13s，target 10s）被跳过的问题。
- Emby：`https://goemby.entertang.work/Videos/...` 当前对 native、curl 默认 UA、VLC UA、mpv UA 都是 401；`/tmp/native-sub.log` 里 mpv 同一条流也 401。已加 `-ua`/`-referer` 与 HTTP 401「认证失败」日志；这不是 UA 能单独解决的，需要有效 token/API key 或带认证的 URL。
- 构建/打包（2026-11-22）：`scripts/embed-libass.sh` 把 Homebrew libass 0.17.5 及 freetype/fribidi/harfbuzz/libunibreak 等 rpath 依赖复制到 deps 前缀；`scripts/package-macos-app.sh` 整目录嵌入 App 并逐个签名。补入 FFmpeg 传递依赖 `libbrotlicommon 1.2.1` 后，`otool -L` 引擎只链 `@rpath/libass.9.dylib`/`@rpath/libav*` 和系统框架。App 39MB、zip 16MB。
- clean 验证：`/tmp/dlna-clean` 复制 App 后 `env -i` + 独立 HOME + 8098 起引擎；`lsof -p` 显示进程加载 `.../DLNA 电视.app/Contents/Resources/engine/lib/libass.9.dylib`；依赖闭包无缺失；播放 `/tmp/sub_ass_fixed.mkv` 到 10.226s 暂停，红字 `\an4\pos(200,500)` 位于左中（`/tmp/pe_shots/clean_102_libass.png`，日志 `/tmp/clean_libass_test2.log`）。
- **限制**：libass/依赖当前是同版本 Homebrew 二进制嵌入，不是源码重编；源码 URL/sha256 与许可文本见 `third_party/README.md` 和 `third_party/licenses/`。发版前若要完全源码构建，需补 autoconf/automake/meson 工具链并复测。
- 当前目录未提交。
