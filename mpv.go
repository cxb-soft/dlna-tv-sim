package main

import (
	"bufio"
	"encoding/json"
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

// mpv 是首选的播放引擎：全屏可靠，格式覆盖广（m3u8/ts/mkv/HEVC），
// 而且有 JSON IPC 可以做播放/暂停/进度/音量，比 VLC 的 RC 稳。
type mpvScreen struct {
	dev  *Device
	path string
	sock string

	mu      sync.Mutex
	cmd     *exec.Cmd
	conn    io.ReadWriteCloser
	started bool
	exiting bool
	volume  int
	mute    bool
}

func (m *mpvScreen) Kind() string { return "mpv" }

func (m *mpvScreen) Show(uri, title string, volume int, mute bool) {
	m.mu.Lock()
	m.volume, m.mute = volume, mute
	m.mu.Unlock()

	if err := m.start(uri); err != nil {
		m.dev.logf("screen", "mpv 没起来（%v），换下一个引擎", err)
		m.dev.fallbackFrom("mpv")
		return
	}
	m.send(map[string]any{"command": []any{"loadfile", uri}})
	m.applyVolume(volume, mute)
	m.send(map[string]any{"command": []any{"set_property", "pause", false}})
	m.dev.logf("screen", "mpv 全屏播放: %s", title)
}

func (m *mpvScreen) Play() {
	m.send(map[string]any{"command": []any{"set_property", "pause", false}})
	m.showProgress()
}

func (m *mpvScreen) Pause() {
	m.send(map[string]any{"command": []any{"set_property", "pause", true}})
	m.showProgress()
}

// showProgress 让屏幕弹一下进度条，像电视按遥控那样。
func (m *mpvScreen) showProgress() {
	m.send(map[string]any{"command": []any{"show-progress"}})
}

func (m *mpvScreen) Stop() {
	m.send(map[string]any{"command": []any{"stop"}})
}

func (m *mpvScreen) Seek(d time.Duration) {
	m.send(map[string]any{"command": []any{"seek", int(d.Seconds()), "absolute"}})
	m.showProgress()
}

func (m *mpvScreen) SetVolume(vol int) {
	m.mu.Lock()
	m.volume = vol
	mute := m.mute
	m.mu.Unlock()
	m.applyVolume(vol, mute)
}

func (m *mpvScreen) SetMute(b bool) {
	m.mu.Lock()
	m.mute = b
	m.mu.Unlock()
	m.send(map[string]any{"command": []any{"set_property", "mute", b}})
}

func (m *mpvScreen) applyVolume(vol int, mute bool) {
	if vol < 0 {
		vol = 0
	}
	if vol > 100 {
		vol = 100
	}
	m.send(map[string]any{"command": []any{"set_property", "volume", vol}})
	m.send(map[string]any{"command": []any{"set_property", "mute", mute}})
}

func (m *mpvScreen) send(payload map[string]any) {
	m.mu.Lock()
	conn := m.conn
	m.mu.Unlock()
	if conn == nil {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	data = append(data, '\n')
	if _, err := conn.Write(data); err != nil {
		m.dev.logf("screen", "mpv 指令失败: %v", err)
	}
}

func (m *mpvScreen) start(uri string) error {
	m.mu.Lock()
	if m.started && m.conn != nil {
		m.mu.Unlock()
		return nil
	}
	m.mu.Unlock()

	sock := ipcPath()
	_ = os.Remove(sock)

	args := []string{
		"--fullscreen",
		// 平时像电视一样干净，鼠标一动才出进度条；手机上拖进度会显示进度条提示。
		"--osc=yes",
		"--osd-level=1",
		"--osd-on-seek=bar",
		"--osd-bar-align-y=0.95",
		"--osd-duration=2500",
		"--cursor-autohide=1200",
		"--no-terminal",
		"--really-quiet",
		"--idle=yes",
		"--force-window=yes",
		"--keep-open=no",
		"--input-ipc-server=" + sock,
		uri,
	}
	cmd := exec.Command(m.path, args...)
	cmd.Stdout = io.Discard
	stderr := &limitedBuffer{limit: 4096}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return err
	}

	var conn io.ReadWriteCloser
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		c, err := dialIPC(sock, 200*time.Millisecond)
		if err == nil {
			conn = c
			break
		}
		time.Sleep(150 * time.Millisecond)
	}
	if conn == nil {
		_ = cmd.Process.Kill()
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return fmt.Errorf("mpv IPC 未就绪：%s", firstLine(msg))
		}
		return fmt.Errorf("mpv IPC 未就绪")
	}

	m.mu.Lock()
	m.cmd = cmd
	m.conn = conn
	m.started = true
	m.mu.Unlock()

	go m.readLoop(conn)
	go func() {
		err := cmd.Wait()
		m.mu.Lock()
		wasExiting := m.exiting
		m.started = false
		m.cmd = nil
		m.conn = nil
		m.mu.Unlock()
		if !wasExiting {
			m.dev.logf("screen", "mpv 已退出（%v）", err)
			m.dev.onScreenExit()
		}
	}()

	// 让 mpv 把播放进度、时长、暂停状态推回来
	m.send(map[string]any{"command": []any{"observe_property", 1, "time-pos"}})
	m.send(map[string]any{"command": []any{"observe_property", 2, "duration"}})
	m.send(map[string]any{"command": []any{"observe_property", 3, "pause"}})
	m.dev.logf("screen", "mpv 已启动（%s）", m.path)
	return nil
}

type mpvEvent struct {
	Event  string          `json:"event"`
	Name   string          `json:"name"`
	Data   json.RawMessage `json:"data"`
	Reason string          `json:"reason"`
	ID     int             `json:"id"`
}

func (m *mpvScreen) readLoop(conn io.ReadWriteCloser) {
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), 256*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var ev mpvEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		switch ev.Event {
		case "property-change":
			switch ev.Name {
			case "duration":
				var sec float64
				if json.Unmarshal(ev.Data, &sec) == nil && sec > 0 {
					m.dev.setDuration(time.Duration(sec * float64(time.Second)))
				}
			case "time-pos":
				var sec float64
				if json.Unmarshal(ev.Data, &sec) == nil && sec >= 0 {
					m.dev.syncPosition(time.Duration(sec * float64(time.Second)))
				}
			}
		case "end-file":
			if ev.Reason == "eof" || ev.Reason == "error" {
				m.dev.logf("screen", "播放结束（%s）", ev.Reason)
				m.dev.onPlaybackEnded()
			}
		case "shutdown":
			m.dev.onScreenExit()
		}
		if m.dev.verbose {
			m.dev.logf("mpv", "%s", line)
		}
	}
	// 连接断了但进程还在（极少见）：当成窗口被关
	m.mu.Lock()
	wasExiting := m.exiting
	m.mu.Unlock()
	if !wasExiting {
		m.dev.onScreenExit()
	}
}

func (m *mpvScreen) Close() {
	m.mu.Lock()
	if m.exiting {
		m.mu.Unlock()
		return
	}
	m.exiting = true
	conn := m.conn
	cmd := m.cmd
	m.mu.Unlock()

	if conn != nil {
		payload, _ := json.Marshal(map[string]any{"command": []any{"quit"}})
		_, _ = conn.Write(append(payload, '\n'))
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

func ipcPath() string {
	if runtime.GOOS == "windows" {
		return `\\.\pipe\dlna-tv-sim-mpv-` + strconv.Itoa(os.Getpid())
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("dlna-tv-sim-mpv-%d.sock", os.Getpid()))
}

// findMPV 找 mpv：程序旁边的绿色版 → PATH → 常见安装位置。
func findMPV() string {
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		if runtime.GOOS == "windows" {
			candidates = append(candidates,
				filepath.Join(dir, "mpv", "mpv.exe"),
				filepath.Join(dir, "mpv.exe"),
			)
		} else {
			candidates = append(candidates,
				filepath.Join(dir, "mpv", "mpv"),
				filepath.Join(dir, "mpv"),
			)
		}
	}
	if p, err := exec.LookPath("mpv"); err == nil {
		candidates = append(candidates, p)
	}
	candidates = append(candidates,
		"/opt/homebrew/bin/mpv",
		"/usr/local/bin/mpv",
		"/usr/bin/mpv",
	)
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	return ""
}

// mpvConn 在 unix 上就是 unix socket。
func mpvDialError(err error) bool {
	var ne net.Error
	return err != nil && (os.IsNotExist(err) || (asNetError(err, &ne) && ne.Timeout()))
}

func asNetError(err error, target *net.Error) bool {
	if ne, ok := err.(net.Error); ok {
		*target = ne
		return true
	}
	return false
}
