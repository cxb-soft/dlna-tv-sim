package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// screen 是"电视面板"的抽象：DLNA 侧只关心播放/暂停/停止/音量，
// 具体是交给 VLC 还是浏览器，由实现决定。
type screen interface {
	Kind() string
	Show(uri, title string, volume int, mute bool)
	Play()
	Pause()
	Stop()
	Seek(d time.Duration)
	SetVolume(v int)
	SetMute(m bool)
	Close()
}

// playerEngine 是可选的"高级播放控制"能力，目前只有 mpv 完整实现。
// 网页引擎靠页面自己读 /api/state 应用倍速和循环，VLC 不提供这些。
type playerEngine interface {
	SetSpeed(v float64)
	SetLoop(on bool)
	SetAspect(a string)
	SelectTrack(kind string, id int)
	ScreenshotTo(path string) error
}

// ---------- 网页播放器（兜底） ----------

type webScreen struct{ dev *Device }

func (w *webScreen) Kind() string { return "web" }

func (w *webScreen) Show(uri, title string, volume int, mute bool) {
	w.dev.logf("screen", "网页播放器接手（浏览器格式有限）: %s", title)
}

func (w *webScreen) Play()              {}
func (w *webScreen) Pause()             {}
func (w *webScreen) Stop()              {}
func (w *webScreen) Seek(time.Duration) {}
func (w *webScreen) SetVolume(int)      {}
func (w *webScreen) SetMute(bool)       {}
func (w *webScreen) Close()             {}

// ---------- VLC 全屏引擎 ----------

type vlcScreen struct {
	dev  *Device
	path string

	mu         sync.Mutex
	cmd        *exec.Cmd
	conn       net.Conn
	started    bool
	volume     int
	mute       bool
	exiting    bool
	fullscreen bool
	playState  string
}

func (v *vlcScreen) Kind() string { return "vlc" }

func (v *vlcScreen) Show(uri, title string, volume int, mute bool) {
	v.mu.Lock()
	v.volume, v.mute = volume, mute
	v.playState = ""
	v.mu.Unlock()

	if err := v.start(); err != nil {
		v.dev.logf("screen", "VLC 没起来（%v），改用网页播放器", err)
		v.dev.useWebScreen()
		return
	}
	v.command("stop")
	time.Sleep(150 * time.Millisecond)
	v.command("add " + vlcQuote(uri))
	v.applyVolume(volume, mute)
	// 等 VLC 真的开始播，再切全屏；视频输出还没建出来时，
	// fullscreen 指令会被直接丢掉。
	v.waitPlaying(6 * time.Second)
	time.Sleep(800 * time.Millisecond)
	v.mu.Lock()
	needFullscreen := !v.fullscreen
	v.mu.Unlock()
	if needFullscreen {
		v.enterFullscreen()
		v.mu.Lock()
		v.fullscreen = true
		v.mu.Unlock()
		v.dev.logf("screen", "已切全屏")
	}
	v.dev.logf("screen", "VLC 全屏播放: %s", title)
}

func (v *vlcScreen) Play() {
	v.command("play")
}

func (v *vlcScreen) Pause() {
	v.command("pause")
}

func (v *vlcScreen) Stop() {
	v.command("stop")
}

func (v *vlcScreen) Seek(d time.Duration) {
	sec := int(d.Seconds())
	if sec < 0 {
		sec = 0
	}
	v.command("seek " + strconv.Itoa(sec))
}

func (v *vlcScreen) SetVolume(vol int) {
	v.mu.Lock()
	v.volume = vol
	mute := v.mute
	v.mu.Unlock()
	v.applyVolume(vol, mute)
}

func (v *vlcScreen) SetMute(m bool) {
	v.mu.Lock()
	v.mute = m
	vol := v.volume
	v.mu.Unlock()
	v.applyVolume(vol, m)
}

func (v *vlcScreen) applyVolume(vol int, mute bool) {
	vlcVol := vol * 512 / 100
	if mute {
		vlcVol = 0
	}
	if vlcVol < 0 {
		vlcVol = 0
	}
	v.command("volume " + strconv.Itoa(vlcVol))
}

func (v *vlcScreen) command(cmd string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.conn == nil {
		return
	}
	v.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	if _, err := io.WriteString(v.conn, cmd+"\n"); err != nil {
		v.dev.logf("screen", "VLC 指令失败（%s）: %v", cmd, err)
	}
}

func (v *vlcScreen) start() error {
	v.mu.Lock()
	if v.started && v.conn != nil {
		v.mu.Unlock()
		return nil
	}
	v.mu.Unlock()

	port, err := freePort()
	if err != nil {
		return err
	}
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	args := []string{
		"--extraintf=rc",
		"--rc-host=" + addr,
		"--rc-fake-tty",
		"--no-video-title-show",
		"--no-osd",
		"--quiet",
		"--no-media-library",
		"--no-snapshot-preview",
		"--no-stats",
	}
	cmd := exec.Command(v.path, args...)
	cmd.Stdout = io.Discard
	stderr := &limitedBuffer{limit: 4096}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return err
	}

	deadline := time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		conn, derr := net.DialTimeout("tcp", addr, 300*time.Millisecond)
		if derr == nil {
			v.mu.Lock()
			v.cmd = cmd
			v.conn = conn
			v.started = true
			v.mu.Unlock()
			go v.readLoop(conn)
			go v.waitExit(cmd)
			v.dev.logf("screen", "VLC 已启动（%s）", v.path)
			if runtime.GOOS == "darwin" {
				// 从后台进程拉起时窗口可能不会自动到前台
				go exec.Command("osascript", "-e", `tell application "VLC" to activate`).Run()
			}
			return nil
		}
		// 进程已经退了就不用再等
		if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
			return fmt.Errorf("VLC 进程提前退出")
		}
		time.Sleep(150 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	if msg := strings.TrimSpace(stderr.String()); msg != "" {
		return fmt.Errorf("VLC RC 端口 %d 未就绪：%s", port, firstLine(msg))
	}
	return fmt.Errorf("VLC RC 端口 %d 未就绪", port)
}

func (v *vlcScreen) readLoop(conn net.Conn) {
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 64*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if i := strings.Index(line, "state "); i >= 0 {
			st := strings.TrimSpace(strings.TrimSuffix(line[i+len("state "):], ")"))
			v.mu.Lock()
			v.playState = st
			v.mu.Unlock()
		}
		if v.dev.verbose {
			v.dev.logf("vlc", "%s", line)
		}
	}
}

// waitPlaying 等 VLC 真正开始解码。视频输出没建好就切全屏，VLC 会直接忽略。
// enterFullscreen 在 macOS 上走系统快捷键：VLC 3.0.20 的 RC fullscreen
// 指令本身是坏的（会报 lua error），但 Cmd+F 是可靠的。
func (v *vlcScreen) enterFullscreen() {
	if runtime.GOOS != "darwin" {
		v.command("fullscreen")
		return
	}
	script := `tell application "VLC" to activate
delay 0.4
tell application "System Events" to keystroke "f" using command down`
	if out, err := exec.Command("osascript", "-e", script).CombinedOutput(); err != nil {
		v.dev.logf("screen", "全屏快捷键失败: %v %s", err, strings.TrimSpace(string(out)))
		return
	}
}

func (v *vlcScreen) waitPlaying(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		v.mu.Lock()
		st := v.playState
		v.mu.Unlock()
		if st == "playing" {
			return true
		}
		time.Sleep(150 * time.Millisecond)
	}
	return false
}

func (v *vlcScreen) waitExit(cmd *exec.Cmd) {
	err := cmd.Wait()
	v.mu.Lock()
	wasExiting := v.exiting
	v.started = false
	v.fullscreen = false
	v.cmd = nil
	if v.conn != nil {
		v.conn.Close()
		v.conn = nil
	}
	v.mu.Unlock()
	if wasExiting {
		return
	}
	v.dev.logf("screen", "VLC 窗口已关闭（%v）", err)
	v.dev.onScreenExit()
}

func (v *vlcScreen) Close() {
	v.mu.Lock()
	if v.exiting {
		v.mu.Unlock()
		return
	}
	v.exiting = true
	conn := v.conn
	cmd := v.cmd
	v.mu.Unlock()

	if conn != nil {
		io.WriteString(conn, "quit\n")
		conn.Close()
	}
	if cmd != nil && cmd.Process != nil {
		done := make(chan struct{})
		go func() {
			cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = cmd.Process.Kill()
		}
	}
}

func vlcQuote(s string) string {
	if strings.ContainsAny(s, " \t") {
		return `"` + s + `"`
	}
	return s
}

// useWebScreen 在 VLC 启动失败时降级，避免投屏直接卡住。
func (d *Device) useWebScreen() {
	d.mu.Lock()
	d.scr = &webScreen{dev: d}
	uri := d.uri
	title := mediaTitle(d.uriMeta, d.uri)
	d.mu.Unlock()
	d.logf("screen", "已切到网页播放器")
	if uri != "" {
		d.scr.Show(uri, title, d.volumeOf(), d.muteOf())
	}
}

func (d *Device) volumeOf() int {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.volume
}

func (d *Device) muteOf() bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.mute
}

func (d *Device) showOnScreen(uri, title string, volume int, mute bool) {
	d.mu.Lock()
	scr := d.scr
	d.mu.Unlock()
	if scr == nil {
		scr = d.newScreen()
		d.mu.Lock()
		if d.scr == nil {
			d.scr = scr
		} else {
			scr = d.scr
		}
		d.mu.Unlock()
	}
	scr.Show(uri, title, volume, mute)
}

// onScreenExit 处理"用户把播放器窗口关了"：就当成电视被关掉，回到 STOPPED。
func (d *Device) onScreenExit() {
	d.mu.Lock()
	playing := d.state == statePlaying || d.state == statePaused || d.state == stateTransitioning
	if playing {
		d.state = stateStopped
		d.pos = 0
		d.posAt = time.Now()
	}
	d.mu.Unlock()
	if playing {
		d.emit(serviceAVTransport)
	}
}

// findVLC 依次找：程序旁边的绿色版 → 系统安装位置 → PATH。
func findVLC() string {
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		switch runtime.GOOS {
		case "windows":
			candidates = append(candidates, filepath.Join(dir, "vlc", "vlc.exe"))
		case "darwin":
			candidates = append(candidates, filepath.Join(dir, "vlc", "VLC.app", "Contents", "MacOS", "VLC"))
		default:
			candidates = append(candidates, filepath.Join(dir, "vlc", "vlc"))
		}
	}
	switch runtime.GOOS {
	case "darwin":
		candidates = append(candidates,
			"/Applications/VLC.app/Contents/MacOS/VLC",
			filepath.Join(os.Getenv("HOME"), "Applications/VLC.app/Contents/MacOS/VLC"),
		)
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramW6432")} {
			if base == "" {
				continue
			}
			candidates = append(candidates, filepath.Join(base, "VideoLAN", "VLC", "vlc.exe"))
		}
	}
	if p, err := exec.LookPath("vlc"); err == nil {
		candidates = append(candidates, p)
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	return ""
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}
