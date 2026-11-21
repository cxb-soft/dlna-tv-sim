package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
)

var version = "0.4.1"

func main() {
	cfgPath, err := configPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "拿不到配置目录: %v\n", err)
		os.Exit(1)
	}
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取配置失败: %v\n", err)
		os.Exit(1)
	}

	port := flag.Int("http-port", 0, "HTTP 端口（默认 8090，0 表示用配置里的）")
	name := flag.String("name", "", "电视名称，写进配置")
	uuidArg := flag.String("uuid", "", "固定设备 UUID，写进配置")
	player := flag.String("player", "", "播放引擎：auto（默认）/ mpv / vlc / web")
	noSSDP := flag.Bool("no-ssdp", false, "不启动 SSDP 发现（只跑 HTTP，排查用）")
	noOpen := flag.Bool("no-open", false, "启动后不自动打开控制台网页")
	verbose := flag.Bool("v", false, "详细日志（含每个 SSDP / SOAP / VLC 细节）")
	showVer := flag.Bool("version", false, "打印版本后退出")
	flag.Parse()

	if *showVer {
		fmt.Printf("dlna-tv-sim %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
		return
	}

	changed := false
	if *port != 0 {
		cfg.HTTPPort = *port
		changed = true
	}
	if *name != "" {
		cfg.FriendlyName = *name
		changed = true
	}
	if *uuidArg != "" {
		cfg.UUID = *uuidArg
		changed = true
	}
	if *player != "" {
		cfg.Player = *player
		changed = true
	}
	if cfg.SerialNumber == "" {
		cfg.SerialNumber = serialFor(cfg.UUID)
		changed = true
	}
	if changed {
		if err := cfg.save(cfgPath); err != nil {
			fmt.Fprintf(os.Stderr, "保存配置失败: %v\n", err)
		}
	}

	dev := NewDevice(cfg, cfgPath, *verbose)
	if err := dev.Listen(); err != nil {
		fmt.Fprintf(os.Stderr, "启动失败: %v\n", err)
		fmt.Fprintf(os.Stderr, "提示：用 -http-port 8091 换一个端口再试。\n")
		os.Exit(1)
	}

	var sd *SSDP
	if !*noSSDP {
		sd = NewSSDP(dev)
		dev.sd = sd
		if err := sd.Start(); err != nil {
			dev.logf("ssdp", "SSDP 启动失败: %v", err)
			dev.logf("ssdp", "控制点不会自动发现这台电视，但用地址 %s 仍可投屏", dev.baseURL(fallbackIP()))
		}
	}

	printBanner(dev)

	if !*noOpen {
		openBrowser(fmt.Sprintf("http://127.0.0.1:%d/", dev.httpPort))
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	fmt.Println("\n收到退出信号，正在关闭…")
	if sd != nil {
		sd.Close()
	}
	dev.Close()
	fmt.Println("已退出。")
}

func printBanner(d *Device) {
	cfg := d.cfg
	fmt.Println()
	fmt.Println("  DLNA 电视模拟器 · " + version)
	fmt.Println("  ────────────────────────────────────────────")
	fmt.Println("  设备名 : " + cfg.FriendlyName)
	fmt.Println("  UUID   : uuid:" + cfg.UUID)
	fmt.Println("  型号   : " + cfg.ModelName + " " + cfg.ModelNumber)
	for _, ip := range append([]string{"127.0.0.1"}, localIPv4s()...) {
		fmt.Printf("  地址   : http://%s:%d/dmr.xml\n", ip, d.httpPort)
	}
	fmt.Println("  播放器 : " + engineLabel(cfg.Player))
	fmt.Println("  控制台 : http://127.0.0.1:" + fmt.Sprint(d.httpPort) + "/")
	fmt.Println()
	if runtime.GOOS == "windows" {
		fmt.Println("  Windows 首次运行：若弹出防火墙提示，请勾选“专用网络”并允许，")
		fmt.Println("  否则手机搜不到这台电视（UDP 1900 组播 + HTTP 端口）。")
		fmt.Println()
	}
	fmt.Println("  现在可以在手机视频 App 里点“投屏”，选中这台电视。Ctrl+C 退出。")
	fmt.Println()
}

// openBrowser 用系统方式打开控制台网页。
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	if err := cmd.Start(); err != nil {
		return
	}
	go func() { _ = cmd.Wait() }()
}

func init() {
	// 让终端里中文不花屏（Windows 老控制台默认不是 UTF-8）
	if runtime.GOOS == "windows" {
		enableUTF8Console()
	}
}

// engineLabel 说明最终会用到哪个播放引擎，横幅要和实际选择一致。
func engineLabel(player string) string {
	switch strings.ToLower(strings.TrimSpace(player)) {
	case "web":
		return "网页播放器（-player web）"
	case "vlc":
		if p := findVLC(); p != "" {
			return "VLC 全屏引擎（" + p + "）"
		}
		return "网页播放器（没找到 VLC，-player vlc 失效）"
	case "mpv":
		if p := findMPV(); p != "" {
			return "mpv 全屏引擎（" + p + "）"
		}
		return "网页播放器（没找到 mpv，-player mpv 失效）"
	}
	if p := findMPV(); p != "" {
		return "mpv 全屏引擎（" + p + "，自动选择）"
	}
	if p := findVLC(); p != "" {
		return "VLC 全屏引擎（" + p + "，自动选择）"
	}
	return "网页播放器（没找到 mpv/VLC，可用 -player 指定）"
}
