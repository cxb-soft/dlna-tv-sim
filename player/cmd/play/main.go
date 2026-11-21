// Command play 是自研播放核心的验证用命令行：本地文件/HTTP 都能播，
// 也可以用 -script 自动跑一段播放、暂停、seek、截图，便于复现实验。
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"dlnatvsim/player"
)

var started = time.Now()

func logf(format string, args ...any) {
	el := time.Since(started).Seconds()
	fmt.Printf("[cli %7.3fs] %s\n", el, fmt.Sprintf(format, args...))
}

func hhmmss(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	m := int(sec) / 60
	s := sec - float64(m*60)
	return fmt.Sprintf("%02d:%05.2f", m, s)
}

func summarize(st player.Status) string {
	return fmt.Sprintf("pos=%s/%s paused=%v ended=%v hw=%v drift=%+.1fms avg=%+.1f p95=%.1f max=%.1f shown=%d dropped=%d cpu=%.1f%% buf=%.0fms",
		hhmmss(st.Position), hhmmss(st.Duration), st.Paused, st.Ended, st.Hardware,
		st.DriftMS, st.DriftAvgMS, st.DriftP95MS, st.DriftMaxMS,
		st.FramesShown, st.FramesDroped, st.CPUPercent, st.BufferedMS)
}

func screenshot(win int, path string) error {
	if win == 0 {
		return fmt.Errorf("窗口号无效")
	}
	cmd := exec.Command("screencapture", "-x", "-o", fmt.Sprintf("-l%d", win), path)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func runScript(p *player.Player, script string) {
	cmds := strings.FieldsFunc(script, func(r rune) bool { return r == ';' || r == '\n' })
	for _, raw := range cmds {
		cmd := strings.TrimSpace(raw)
		if cmd == "" {
			continue
		}
		fields := strings.Fields(cmd)
		name := strings.ToLower(fields[0])
		arg := ""
		if len(fields) > 1 {
			arg = fields[1]
		}
		logf("脚本: %s", cmd)
		switch name {
		case "wait", "sleep":
			sec, _ := strconv.ParseFloat(arg, 64)
			time.Sleep(time.Duration(sec * float64(time.Second)))
		case "play":
			p.Play()
		case "pause":
			p.Pause()
		case "toggle":
			p.Toggle()
		case "stop":
			p.Stop()
		case "seek":
			sec, err := strconv.ParseFloat(arg, 64)
			if err != nil {
				logf("seek 参数无效: %q", arg)
				continue
			}
			p.Seek(sec)
		case "seekrel":
			d, _ := strconv.ParseFloat(arg, 64)
			p.SeekRelative(d)
		case "vol":
			v, _ := strconv.Atoi(arg)
			p.SetVolume(v)
			logf("音量 → %d", p.Volume())
		case "mute":
			p.SetMute(arg == "on" || arg == "true" || arg == "1")
			logf("静音 → %v", p.Muted())
		case "fullscreen":
			switch arg {
			case "on", "true", "1":
				p.SetFullscreen(true)
			case "off", "false", "0":
				p.SetFullscreen(false)
			default:
				p.ToggleFullscreen()
			}
			logf("全屏 → %v", p.Status().Fullscreen)
		case "closewin":
			p.CloseWindow()
		case "pos", "status":
			st := p.Status()
			logf("状态 %s | clock=%.3f video_pts=%.3f first=%.0fms seek=%.0fms win=%d",
				summarize(st), st.Clock, st.VideoPTS, st.FirstFrameMS, st.LastSeekMS, st.WindowNumber)
		case "shot":
			path := arg
			if path == "" {
				path = fmt.Sprintf("/tmp/player-shot-%d.png", time.Now().Unix())
			}
			st := p.Status()
			if err := screenshot(st.WindowNumber, path); err != nil {
				logf("截图失败: %v", err)
			} else {
				logf("截图已保存 %s（截图时 %s）", path, summarize(p.Status()))
			}
		case "quit", "exit":
			p.Close()
			return
		default:
			logf("未知脚本命令: %s", cmd)
		}
	}
}

func main() {
	runtime.LockOSThread()

	var (
		file       = flag.String("file", "", "本地文件路径或 http(s) 地址")
		title      = flag.String("title", "", "窗口标题")
		width      = flag.Int("w", 0, "窗口宽，0 表示按视频宽（上限 1600）")
		height     = flag.Int("h", 0, "窗口高，0 表示按视频高")
		fullscreen = flag.Bool("fullscreen", false, "无边框全屏启动")
		vol        = flag.Int("vol", 80, "音量 0-100")
		mute       = flag.Bool("mute", false, "静音")
		soft       = flag.Bool("soft", false, "强制软件解码（用于对比硬解 CPU）")
		startPos   = flag.Float64("start", 0, "起播位置（秒）")
		script     = flag.String("script", "", "自动脚本，如 \"wait 2; pos; pause; wait 2; pos; play; seek 10; wait 2; pos; shot /tmp/a.png\"")
		verbose    = flag.Bool("verbose", false, "每次状态回调都打印")
		every      = flag.Float64("status-every", 1.0, "状态打印间隔（秒），0 表示不自动打印")
		exitOnEnd  = flag.Bool("exit-on-end", false, "播放结束自动退出")
		maxRun     = flag.Float64("max-run", 0, "最长运行秒数，0 表示不限制")
	)
	flag.Parse()
	if *file == "" && flag.NArg() > 0 {
		*file = flag.Arg(0)
	}
	if *file == "" {
		fmt.Fprintln(os.Stderr, "用法: play -file /path/to/video.mp4 [-script \"wait 2; shot /tmp/a.png\"]")
		flag.PrintDefaults()
		os.Exit(2)
	}

	logf("FFmpeg %s，硬解设备 %s", player.Version(), player.HardwareDevice())

	p, err := player.Open(player.Options{
		URL:            *file,
		Title:          *title,
		Width:          *width,
		Height:         *height,
		Fullscreen:     *fullscreen,
		Volume:         *vol,
		Mute:           *mute,
		SoftwareDecode: *soft,
		StartPosition:  *startPos,
	})
	if err != nil {
		logf("打开失败: %v", err)
		os.Exit(1)
	}

	var stMu sync.Mutex
	lastPrint := time.Time{}
	var lastStatus player.Status
	p.OnUpdate(func(st player.Status) {
		stMu.Lock()
		if st.Duration > 0 || st.FramesShown > 0 {
			lastStatus = st
		}
		printIt := *every > 0 && time.Since(lastPrint).Seconds() >= *every
		if printIt {
			lastPrint = time.Now()
		}
		stMu.Unlock()
		if printIt || (*verbose && st.FramesShown%10 == 0) {
			logf("运行 %s", summarize(st))
		}
	})
	p.OnClose(func() {
		logf("窗口被关闭")
	})

	first := p.Status()
	logf("开始播放 %s | 视频 %s %dx%d@%dfps hw=%v | 音频 %s %v | 时长 %s",
		*file, p.VideoCodec(), first.Width, first.Height, first.FPS,
		first.Hardware, p.AudioCodec(), first.HasAudio, hhmmss(first.Duration))

	// Ctrl+C 时也走正常关闭路径，避免留下线程/窗口。
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		logf("收到中断，关闭播放器")
		p.Close()
	}()

	if *script != "" {
		go func() {
			time.Sleep(150 * time.Millisecond)
			runScript(p, *script)
		}()
	}
	if *maxRun > 0 {
		go func() {
			time.Sleep(time.Duration(*maxRun * float64(time.Second)))
			logf("达到最长运行时间，关闭")
			p.Close()
		}()
	}
	if *exitOnEnd {
		go func() {
			t := time.NewTicker(200 * time.Millisecond)
			defer t.Stop()
			for range t.C {
				st := p.Status()
				if st.Ended {
					logf("播放结束")
					time.Sleep(300 * time.Millisecond)
					p.Close()
					return
				}
			}
		}()
	}

	p.Run()

	final := p.Status()
	stMu.Lock()
	if lastStatus.FramesShown > 0 {
		final = lastStatus
	}
	stMu.Unlock()
	logf("==== 汇总 ====")
	logf("时长 %s，首帧 %.0fms，seek 响应 %.0fms", hhmmss(final.Duration), final.FirstFrameMS, final.LastSeekMS)
	logf("显示 %d 帧，丢帧 %d；pacing 误差 avg=%+.1fms p95=%.1fms max=%.1fms",
		final.FramesShown, final.FramesDroped, final.DriftAvgMS, final.DriftP95MS, final.DriftMaxMS)
	logf("硬解=%v，CPU=%.1f%%，缓冲=%.0fms，最终位置 %s",
		final.Hardware, final.CPUPercent, final.BufferedMS, hhmmss(final.Position))
	p.Close()
}
