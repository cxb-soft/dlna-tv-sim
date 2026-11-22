# 第三方许可文本清单（libass 自包含打包）

本目录保存随 `DLNA 电视` App 分发的第三方库许可文本。当前 macOS native 引擎的
libass/字体相关依赖以 Homebrew 同版本动态库形式嵌入 `Contents/Resources/engine/lib`；
FFmpeg 仍是 `scripts/build-native-deps.sh` 产出的 LGPL 2.1+ 动态库，许可文本在
`third_party/licenses/ffmpeg/`。

| 组件 | 版本 | 许可 | 源码 | 本目录文件 |
|---|---|---|---|---|
| libass | 0.17.5 | ISC | https://github.com/libass/libass/releases/tag/0.17.5 | `libass-COPYING` |
| FreeType | 2.15.0 | FTL 或 GPLv2 | https://download.savannah.gnu.org/releases/freetype/ | `freetype-LICENSE.TXT` |
| HarfBuzz | 15.0.0 | MIT | https://github.com/harfbuzz/harfbuzz/releases/tag/15.0.0 | `harfbuzz-COPYING` |
| FriBidi | 1.0.16 | LGPL-2.1+ | https://github.com/fribidi/fribidi/releases/tag/v1.0.16 | `fribidi-COPYING` |
| libunibreak | 7.0 | zlib | https://github.com/adah1972/libunibreak/releases/tag/libunibreak_7_0 | `libunibreak-LICENCE` |
| Brotli | 1.2.1 | MIT | https://github.com/google/brotli | `brotli-LICENSE` |

说明：

- `libass 0.17.5` 源码 tarball sha256：`d0b416fa72d2b58e069469b28380cf9257903f062c7bedf9bca6dbd0ec92a75f`
- `freetype 2.15.0`：`93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5`
- `harfbuzz 15.0.0`：`968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df`
- `fribidi 1.0.16`：`1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c`
- `libunibreak 7.0`：`8c9a6e121736cd0d5c890ae3ae96f3f4010a19aa040f1dbded833a62a87717d3`
- 当前 `scripts/embed-libass.sh` 复制 Homebrew 0.17.5/2.15.0/15.0.0/1.0.16/7.0/1.2.1
  二进制并统一改为 `@rpath`；**尚未接入从源码编译的构建流程**。若发版要求完全源码构建，
  需补齐 autoconf/automake/meson 工具链后重新打包，并复测 `otool`/`lsof`。
- 以上版本均未修改源码；字体实际使用 macOS CoreText/PingFang 回退，未单独分发 fontconfig。
