DLNA 电视模拟器 · Windows 版
============================

用法
----
1. 双击 dlna-tv-sim.exe。
2. 第一次运行如果弹出防火墙提示，勾选「专用网络」并允许。
   不放行的话，手机搜不到这台电视（需要 UDP 1900 和 TCP 8090）。
3. 浏览器会自动打开控制台：http://127.0.0.1:8090/
   手机/平板和电脑连同一个 Wi-Fi，然后在视频 App 里点「投屏」，选中这台电视。

播放引擎（重要）
----------------
程序会按这个顺序找播放器：

1. 本目录下的 mpv\mpv.exe 或 mpv.exe（推荐）
   把 mpv 免安装版解压出来，mpv.exe 放进这个文件夹即可。
   下载：https://mpv.io/installation/ 或 https://sourceforge.net/projects/mpv-player-windows/files/
2. 系统安装的 VLC（C:\Program Files\VideoLAN\VLC\vlc.exe）
3. 都没有时，退回浏览器播放页 http://127.0.0.1:8090/screen
   （只支持浏览器能解的格式，mkv/ts 之类放不了）

mpv 能播 m3u8、ts、mkv、HEVC，基本和电视一致，建议带上。

常用参数
--------
dlna-tv-sim.exe -name "客厅电视"     改设备名
dlna-tv-sim.exe -http-port 8091      换端口
dlna-tv-sim.exe -player vlc          指定引擎：auto/mpv/vlc/web
dlna-tv-sim.exe -no-open             启动后不开浏览器
dlna-tv-sim.exe -v                   详细日志

配置文件：%AppData%\dlna-tv-sim\config.json

如果手机搜不到
--------------
- 确认电脑和手机在同一个网段（同一 Wi-Fi，不是访客网络）。
- 如果开了带 TUN 的代理（Clash 等），组播可能被拦；临时关掉 TUN 或放行局域网。
- 关掉 Windows 的「公用网络」模式，改成「专用网络」。
- 控制台网页里的「事件流」能看到是否收到 M-SEARCH，方便判断。
