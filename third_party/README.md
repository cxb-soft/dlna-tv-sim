# third_party —— 自包含 LGPL FFmpeg

`-player native` 使用的 FFmpeg 是**从源码构建的 LGPL v2.1+ 动态库**，不依赖
Homebrew，也不随 App 分发任何 GPL 组件。二进制产物不放在仓库里，默认安装在：

```
$HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl
```

（路径不能含空格：pkg-config 会把带空格的 `prefix` 截断。可用
`DLNA_DEPS_ROOT` / `DLNA_FFMPEG_PREFIX` 覆盖，但同样不能有空格。）

## 构建

```bash
./scripts/build-native-deps.sh          # 默认 FFmpeg 9.0.2
FFMPEG_VERSION=9.0.2 ./scripts/build-native-deps.sh
```

脚本会下载官方 tarball、核对官方 `.sha256`（若可获取）、configure、编译、安装，
并生成 `ffmpeg-lgpl/BUILD-INFO.txt`（版本、构建时间、configure 参数、每个 dylib
的大小与 sha256）。构建日志在 `$HOME/Library/Caches/dlnatvsim-deps/src/`。

当前构建（2026-11-21，macOS arm64）：

| 项目 | 值 |
| --- | --- |
| 版本 | FFmpeg 9.0.2 |
| 许可 | LGPL version 2.1 or later（`CONFIG_GPL=0`、`CONFIG_NONFREE=0`、`CONFIG_VERSION3=0`） |
| 库 | libavformat / libavcodec / libavutil / libswresample / libswscale（动态库 + 头文件 + .pc） |
| 硬解 | h264_videotoolbox / hevc_videotoolbox（VideoToolbox） |
| 解码器 | h264、hevc、aac、aac_at、mp3、mp2、ac3、eac3、flac、opus、vorbis、subrip、ass、ssa、mov_text、webvtt、h264_videotoolbox、hevc_videotoolbox |
| 解封装 | mov（mp4/m4a/mov）、matroska（mkv/webm）、mp3、aac、mpegts、hls |
| 字幕 | SRT/ASS/SSA/mov_text/WebVTT（纯文本渲染，复杂 ASS 排版不还原） |
| 协议 | file、http、https、tcp、udp、crypto、tls（Secure Transport） |
| 外部依赖 | 只有系统框架（VideoToolbox/AudioToolbox/CoreMedia/CoreVideo/CoreServices/libSystem），无第三方库 |

关键 configure 项：

```
--enable-shared --disable-static --disable-programs --disable-doc
--disable-gpl --disable-nonfree --disable-version3 --disable-autodetect
--disable-everything
--enable-avformat --enable-avcodec --enable-avutil --enable-swresample --enable-swscale
--enable-videotoolbox --enable-audiotoolbox --enable-securetransport
--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox
--enable-decoder=h264,hevc,aac,aac_at,mp3,mp2,ac3,eac3,flac,opus,vorbis,subrip,ass,ssa,mov_text,webvtt,h264_videotoolbox,hevc_videotoolbox
--enable-demuxer=mov,matroska,mp3,aac,mpegts,hls
--enable-parser=h264,hevc,aac,mpegaudio
--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc
--enable-protocol=file,http,https,tcp,udp,crypto
--install-name-dir=@rpath --extra-ldflags=-Wl,-rpath,@loader_path
```

`--disable-autodetect` 是关键：否则 configure 会自动捡到 Homebrew 的 openssl、
libx264、libx265、lame 等，产物就不再自包含。

## 链接与 App 内布局

- 每个 dylib 的 install_name 是 `@rpath/libavXXX.<major>.dylib`，自身带
  `LC_RPATH=@loader_path`，互相依赖在 App 内即可解析。
- 引擎用 `CGO_LDFLAGS=-Wl,-rpath,@executable_path/lib` 链接，so `otool -L` 只剩
  `@rpath/...` 和系统框架。
- 打包脚本（`scripts/package-macos-app.sh`）把 dylib 复制到
  `DLNA 电视.app/Contents/Resources/engine/lib/`（保留版本号符号链接），并逐个签名。

开发机上想临时用这套库构建（而不是 Homebrew）：

```bash
PREFIX="$HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" CGO_ENABLED=1 \
  CGO_LDFLAGS="-Wl,-rpath,$PREFIX/lib" go build -o /tmp/dlna-native .
```

不设置这些环境变量时，`go build` 仍按默认 pkg-config 链接 Homebrew FFmpeg，
开发流程不变。

## LGPL 动态链接义务（发布清单）

FFmpeg 以 LGPL v2.1+ 发布。本项目的用法是**动态链接、不修改库源码**，分发时
需要做到：

1. **附许可文本**：随 App 分发 `LICENSE.md` 与 `COPYING.LGPLv2.1`。构建脚本会把
   它们装到 `ffmpeg-lgpl/share/licenses/ffmpeg/`，仓库内副本在
   `third_party/licenses/ffmpeg/`。
2. **允许替换库**：`Contents/Resources/engine/lib/` 里是未修改的独立 dylib，
   App 不内嵌、不混淆它们。用户可以用自己构建的兼容版本替换。
   - 注意：发布包若启用 Hardened Runtime，macOS 的 library validation 会要求
     被加载的库与主程序同一 Team ID 签名。若要让"替换后直接运行"成立，需在
     引擎（`Contents/Resources/engine/dlna-tv-sim`）签名时加
     `com.apple.security.cs.disable-library-validation` entitlement，或在文档中
     明确告知用户替换后需对整个 App 重新签名。两种做法都要在发布说明里写清。
3. **提供源码**：FFmpeg 9.0.2 官方源码
   `https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz`
   （sha256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`），
   以及本仓库的 `scripts/build-native-deps.sh`（含完整 configure 参数，可复现同版本
   构建）。承诺自分发日起至少三年内提供，或按 LGPL 要求随二进制提供。
4. **不额外限制**：不对库的使用、修改、反向工程加限制；App 的 EULA 需保留用户
   替换 LGPL 库的权利。
5. **无 GPL 组件**：configure 用 `--disable-gpl --disable-nonfree`，未链接
   libx264/libx265/libmp3lame 等 GPL 库；`otool -L` 只有 `@rpath` 与系统框架，
   `config.h` 中 `CONFIG_GPL=0` / `CONFIG_NONFREE=0`。

这不是法律意见；正式发版前请让负责许可的人复核一遍发布说明。

## 验证

```bash
PREFIX="$HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl"
# 只允许 @rpath 和系统框架
otool -L "$PREFIX/lib/libavcodec.dylib"
# GPL 关闭
grep CONFIG_GPL "$HOME/Library/Caches/dlnatvsim-deps/src/ffmpeg-9.0.2/config.h"
# 构建记录
cat "$PREFIX/BUILD-INFO.txt"
```

## 本轮实测（2026-11-21，macOS 27 arm64）

- App 复制到 `/tmp` 干净目录，用
  `env -i HOME=… PATH=/usr/bin:/bin:/usr/sbin:/sbin` 启动 App 内引擎
  （`-player native -http-port 8097 -no-ssdp`），投本地 Range 服务器上的
  `player_ts_45s.mp4`（1920×1080 H.264 + AAC，faststart）：
  `PLAYING` 0.3s、首帧 1.1s、`videotoolbox_vld` 硬解、seek 20s 首帧
  `pts=20.000`、暂停位置冻结、Stop → `STOPPED` 并关窗退出。
- `lsof` 显示运行时映射的 5 个 dylib 全部位于
  `DLNA 电视.app/Contents/Resources/engine/lib/`。签名后的 hardened runtime
  会清掉 `DYLD_PRINT_LIBRARIES`，所以改用 lsof 取证。
- `otool -L`：引擎与每个 dylib 只有 `@rpath/...` 和系统框架，无 `/opt/homebrew`。
- `nm -gU` 扫描 libav*/libsw*：x264/x265/lame/fdk/vpx/dav1d 符号均为 0。
- 体积：App 28M → 33M（+5M），其中 `engine/lib` 5.3M；引擎二进制 7.8M；
  发布 zip 11M → 13M。
- 同一套源码不设 `PKG_CONFIG_PATH` 构建的引擎仍链接 `/opt/homebrew`，
  开发机默认流程不受影响。

## libass 字幕渲染（2026-11-22）

- **libass 0.17.5**，ISC 许可，源码：https://github.com/libass/libass/releases/tag/0.17.5
- 源码 tarball sha256：`d0b416fa72d2b58e069469b28380cf9257903f062c7bedf9bca6dbd0ec92a75f`；freetype 2.15.0 `93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5`；harfbuzz 15.0.0 `968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df`；fribidi 1.0.16 `1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c`；libunibreak 7.0 `8c9a6e121736cd0d5c890ae3ae96f3f4010a19aa040f1dbded833a62a87717d3`。
- 直接/运行依赖（本轮本机）：freetype 2.15.0（FTL 或 GPLv2）、harfbuzz 15.0.0（MIT）、fribidi 1.0.16（LGPL-2.1+）、libunibreak 7.0（zlib）；fontconfig 2.18.3（MIT 类）用于字体查找/回退。均为 Homebrew 安装，未修改。
- 打包（2026-11-22）：`scripts/embed-libass.sh` 把 Homebrew libass 0.17.5 及 freetype/fribidi/harfbuzz/libunibreak 等 rpath 依赖复制到 deps 前缀，统一改 `@rpath`；`scripts/package-macos-app.sh` 再整目录嵌入 App 并逐个签名。另补入 FFmpeg 的传递依赖 `libbrotlicommon 1.2.1`（brotli，MIT），否则引擎启动会报 `Library not loaded`。
- 实测：App 引擎 `otool -L` 仅系统框架 + `@rpath/libass.9.dylib`/`@rpath/libav*`；干净目录 `/tmp/dlna-clean`、`env -i` + 独立 HOME + 8098 起引擎，`lsof` 加载 App 内 `libass.9.dylib`；播放 `/tmp/sub_ass_fixed.mkv` 到 10.226s 暂停，红字 `\an4\pos(200,500)` 位于左中（`/tmp/pe_shots/clean_102_libass.png`），日志 `/tmp/clean_libass_test2.log`；App 39MB，zip 16MB。
- **源码构建未接入**：当前 libass/依赖是 Homebrew 同版本二进制嵌入，不是从源码重编；发版前若要完全源码构建，需补 autoconf/automake/meson 工具链并复测。许可文本已放 `third_party/licenses/`（libass ISC、freetype FTL/GPLv2、harfbuzz MIT、fribidi LGPL-2.1+、libunibreak zlib、brotli MIT）；FFmpeg 许可在 `third_party/licenses/ffmpeg/`。
- FFmpeg 仍是 LGPL 2.1+ 动态库，未引入 GPL/nonfree 组件；libass 使用 ISC，不改变 FFmpeg 的 LGPL 构建。
