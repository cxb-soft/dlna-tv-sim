DLNA 电视模拟器 · Windows 版
============================

用法
----
1. 把整个文件夹解压出来（不要只把 exe 拖走，mpv\ 目录要一起）。
2. 双击 dlna-tv-sim-windows-x64.exe（ARM 机器用 arm64 版）。
3. 第一次运行如果弹出防火墙提示，勾选「专用网络」并允许。
   不放行的话手机搜不到这台电视（需要 UDP 1900 和 TCP 8090）。
4. 浏览器会自动打开控制台：http://127.0.0.1:8090/
   手机/平板和电脑连同一个 Wi-Fi，然后在视频 App 里点「投屏」，选中这台电视。

播放引擎
--------
已经内置 mpv（mpv\mpv.exe），解压即用，不需要另外安装任何播放器。

程序按这个顺序找播放器：
1. 本目录下的 mpv\mpv.exe（内置）或 mpv.exe
2. 系统安装的 VLC
3. 都没有时退回浏览器播放页 http://127.0.0.1:8090/screen
   （只支持浏览器能解的格式，mkv/ts 之类放不了）

内置的 mpv 能播 m3u8、ts、mkv、HEVC、AV1，基本和电视一致。

内置 mpv 的版本与许可证
----------------------
mpv 20261111-git-bcde6b93cc（shinchiro 构建，未修改）
源码：https://github.com/mpv-player/mpv
构建：https://github.com/shinchiro/mpv-winbuild-cmake
许可证：GNU GPL v2，全文见 LICENSE-mpv.txt

常用参数
--------
dlna-tv-sim-windows-x64.exe -name "客厅电视"   改设备名
dlna-tv-sim-windows-x64.exe -http-port 8091    换端口
dlna-tv-sim-windows-x64.exe -player vlc        指定引擎：auto/mpv/vlc/web
dlna-tv-sim-windows-x64.exe -no-open           启动后不开浏览器
dlna-tv-sim-windows-x64.exe -v                 详细日志

配置文件：%AppData%\dlna-tv-sim\config.json

如果手机搜不到
--------------
- 确认电脑和手机在同一个网段（同一 Wi-Fi，不是访客网络）。
- 如果开了带 TUN 的代理（Clash 等），组播可能被拦；临时关掉 TUN 或放行局域网。
- 把 Windows 网络从「公用」改成「专用」。
- 控制台网页里的「事件流」能看到是否收到 M-SEARCH，方便判断。
