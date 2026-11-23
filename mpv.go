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

	mu           sync.Mutex
	writeMu      sync.Mutex // 串行化 IPC 写：一次一整行，写超时只管当前这条
	cmd          *exec.Cmd
	conn         io.ReadWriteCloser
	started      bool
	exiting      bool
	volume       int
	mute         bool
	stderr       *limitedBuffer
	uri          string
	retries      int
	lastPos      time.Duration
	lastTick     time.Time
	paused       bool
	reloading    bool
	stallReloads int
}

func (m *mpvScreen) Kind() string { return "mpv" }

func (m *mpvScreen) Show(uri, title string, volume int, mute bool) {
	m.mu.Lock()
	m.volume, m.mute = volume, mute
	m.uri = uri
	m.retries = 0
	m.mu.Unlock()

	if err := m.start(); err != nil {
		m.dev.logf("screen", "mpv 没起来（%v），换下一个引擎", err)
		m.dev.fallbackFrom("mpv")
		return
	}
	m.send(map[string]any{"command": []any{"loadfile", uri}})
	m.applyVolume(volume, mute)
	m.applySettings()
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

// ---------- 高级播放控制 ----------

func (m *mpvScreen) SetSpeed(v float64) {
	m.send(map[string]any{"command": []any{"set_property", "speed", v}})
}

func (m *mpvScreen) SetLoop(on bool) {
	val := "no"
	if on {
		val = "inf"
	}
	m.send(map[string]any{"command": []any{"set_property", "loop-file", val}})
}

func (m *mpvScreen) SetAspect(a string) {
	val := "no"
	if a != "" && a != "auto" {
		val = a
	}
	m.send(map[string]any{"command": []any{"set_property", "video-aspect-override", val}})
}

// SelectTrack 切音轨/字幕轨；id=0 表示关掉字幕（关闭音轨没有意义，允许但很少用）。
func (m *mpvScreen) SelectTrack(kind string, id int) {
	prop := "aid"
	if kind == "sub" {
		prop = "sid"
	}
	var val any = id
	if id <= 0 {
		val = "no"
	}
	m.send(map[string]any{"command": []any{"set_property", prop, val}})
}

func (m *mpvScreen) ScreenshotTo(path string) error {
	m.send(map[string]any{"command": []any{"screenshot-to-file", path, "video"}})
	return nil
}

// parseMPVTracks 把 mpv 的 track-list 压成控制台需要的音轨/字幕轨。
type mpvTrackJSON struct {
	ID       int    `json:"id"`
	Type     string `json:"type"`
	Title    string `json:"title"`
	Lang     string `json:"lang"`
	Codec    string `json:"codec"`
	Selected bool   `json:"selected"`
}

func parseMPVTracks(data json.RawMessage) []TrackInfo {
	var raw []mpvTrackJSON
	if json.Unmarshal(data, &raw) != nil {
		return nil
	}
	list := make([]TrackInfo, 0, len(raw))
	for _, t := range raw {
		if t.Type != "audio" && t.Type != "sub" {
			continue
		}
		list = append(list, TrackInfo{
			ID: t.ID, Type: t.Type, Title: t.Title,
			Lang: t.Lang, Codec: t.Codec, Selected: t.Selected,
		})
	}
	return list
}

// applySettings 在每次投流时把控制台调好的参数带给新的 mpv 实例。
func (m *mpvScreen) applySettings() {
	d := m.dev
	d.mu.RLock()
	speed, loop, aspect := d.speed, d.loop, d.aspect
	d.mu.RUnlock()
	m.SetSpeed(speed)
	m.SetLoop(loop)
	m.SetAspect(aspect)
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
	m.writeMu.Lock()
	err = writeIPC(conn, data, mpvWriteTimeout)
	m.writeMu.Unlock()
	if err != nil {
		m.dev.logf("screen", "mpv 指令失败: %v", err)
	}
}

// mpvWriteTimeout 是一条 IPC 指令最多等多久。正常情况下写入立刻完成；
// 只有 mpv 整个卡死、不再读管道（缓冲写满）时才会超时，免得把 SOAP 请求一起挂住。
const mpvWriteTimeout = 3 * time.Second

type writeDeadliner interface {
	SetWriteDeadline(time.Time) error
}

// writeIPC 带写超时写一条 IPC 指令；连接不支持写超时时直接写。
func writeIPC(conn io.Writer, data []byte, timeout time.Duration) error {
	if d, ok := conn.(writeDeadliner); ok && d.SetWriteDeadline(time.Now().Add(timeout)) == nil {
		defer d.SetWriteDeadline(time.Time{})
	}
	_, err := conn.Write(data)
	return err
}

func (m *mpvScreen) start() error {
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
		"--osd-level=1",
		"--osd-on-seek=bar",
		"--osd-bar-align-y=0.95",
		"--osd-duration=2500",
		"--cursor-autohide=1200",
		"--no-terminal",
		// 不用 --really-quiet：它连错误也不输出，mpv 秒退时无法定位。
		"--msg-level=all=error",
		"--idle=yes",
		"--force-window=yes",
		"--keep-open=no",
		// 网络源断一下不要直接结束：给 FFmpeg 重连机会，并限制单次等待。
		"--network-timeout=15",
		"--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5",
		"--input-ipc-server=" + sock,
	}
	if dir := findUoscDir(); dir != "" {
		// uosc 是随包带的现代播放控件，替代 mpv 默认 OSC。
		args = append(args, "--config-dir="+dir)
		m.dev.logf("screen", "mpv 界面：uosc")
	} else {
		args = append(args, "--osc=yes")
	}
	cmd := exec.Command(m.path, args...)
	cmd.Stdout = io.Discard
	stderr := &limitedBuffer{limit: 4096}
	cmd.Stderr = io.MultiWriter(stderr, &lineLogWriter{
		log: func(line string) { m.dev.logf("mpv", "%s", line) },
	})
	m.mu.Lock()
	m.stderr = stderr
	m.mu.Unlock()
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
	m.mu.Lock()
	m.lastTick = time.Now()
	m.mu.Unlock()
	go m.watchStall()
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
	// 高级播放：轨道、码率、帧率、倍速、循环
	m.send(map[string]any{"command": []any{"observe_property", 4, "track-list"}})
	m.send(map[string]any{"command": []any{"observe_property", 5, "video-bitrate"}})
	m.send(map[string]any{"command": []any{"observe_property", 6, "container-fps"}})
	m.send(map[string]any{"command": []any{"observe_property", 7, "speed"}})
	m.send(map[string]any{"command": []any{"observe_property", 8, "loop-file"}})
	m.dev.logf("screen", "mpv 已启动（%s）", m.path)
	return nil
}

// retryAfterError 在网络中途断开时，从当前进度重新加载同一个地址。
// mpv 把断流报成 end-file(error)，不当成正常播完。
func (m *mpvScreen) retryAfterError() bool {
	m.mu.Lock()
	uri, exiting, pos := m.uri, m.exiting, m.lastPos
	if exiting || uri == "" || m.retries >= 3 {
		m.mu.Unlock()
		return false
	}
	m.retries++
	retries := m.retries
	m.mu.Unlock()

	m.dev.logf("screen", "取流中断，2 秒后重试（第 %d/3 次），从 %s 继续", retries, formatTime(pos))
	m.send(map[string]any{"command": []any{"show-text", "网络中断，正在重试…", 3000}})
	go func(uri string, pos time.Duration) {
		time.Sleep(2 * time.Second)
		m.mu.Lock()
		exiting := m.exiting
		m.mu.Unlock()
		if exiting {
			return
		}
		m.send(map[string]any{"command": []any{"set_property", "start", pos.Seconds()}})
		m.send(map[string]any{"command": []any{"loadfile", uri, "replace"}})
		m.send(map[string]any{"command": []any{"set_property", "pause", false}})
	}(uri, pos)
	return true
}

// watchStall 盯住“有窗口、没进度”的卡死：mpv 有时卡在读数据上，
// 既不发 end-file 也不前进，点播放也无效。25 秒没有 time-pos 就重新加载。
func (m *mpvScreen) watchStall() {
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for range t.C {
		m.mu.Lock()
		started, exiting, paused, reloading := m.started, m.exiting, m.paused, m.reloading
		last := m.lastTick
		m.mu.Unlock()
		if !started || exiting || paused || reloading || last.IsZero() {
			continue
		}
		if time.Since(last) < 25*time.Second {
			continue
		}

		m.mu.Lock()
		if m.reloading || m.paused || !m.started || m.exiting || time.Since(m.lastTick) < 25*time.Second {
			m.mu.Unlock()
			continue
		}
		m.reloading = true
		m.stallReloads++
		n := m.stallReloads
		pos := m.lastPos
		m.lastTick = time.Now()
		m.mu.Unlock()

		m.dev.logf("screen", "播放停滞：25 秒没有进度更新，重新加载（第 %d 次），从 %s 继续", n, formatTime(pos))
		m.send(map[string]any{"command": []any{"show-text", "播放停滞，正在重新加载…", 3000}})
		go m.reloadAt(pos)
	}
}

func (m *mpvScreen) reloadAt(pos time.Duration) {
	m.mu.Lock()
	uri := m.uri
	m.mu.Unlock()
	if uri == "" {
		return
	}
	m.send(map[string]any{"command": []any{"set_property", "start", pos.Seconds()}})
	m.send(map[string]any{"command": []any{"loadfile", uri, "replace"}})
	m.send(map[string]any{"command": []any{"set_property", "pause", false}})
	time.AfterFunc(8*time.Second, func() {
		m.mu.Lock()
		m.reloading = false
		m.mu.Unlock()
	})
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
					d := time.Duration(sec * float64(time.Second))
					m.mu.Lock()
					m.lastPos = d
					m.lastTick = time.Now()
					m.stallReloads = 0
					m.mu.Unlock()
					m.dev.syncPosition(d)
				}
			case "pause":
				var b bool
				if json.Unmarshal(ev.Data, &b) == nil {
					m.mu.Lock()
					m.paused = b
					m.lastTick = time.Now()
					m.mu.Unlock()
				}
			case "track-list":
				m.dev.setTracks(parseMPVTracks(ev.Data))
			case "video-bitrate":
				var bps float64
				if json.Unmarshal(ev.Data, &bps) == nil && bps > 0 {
					m.dev.setBitrate(bps)
				}
			case "container-fps":
				var fps float64
				if json.Unmarshal(ev.Data, &fps) == nil && fps > 0 {
					m.dev.setFPS(fps)
				}
			case "speed":
				var v float64
				if json.Unmarshal(ev.Data, &v) == nil && v > 0 {
					m.dev.noteSpeed(v)
				}
			case "loop-file":
				var v string
				if json.Unmarshal(ev.Data, &v) == nil {
					m.dev.noteLoop(v != "no")
				}
			}
		case "file-loaded":
			m.dev.logf("screen", "mpv file-loaded")
			m.dev.startPlayback()
			m.dev.applyPendingSeek()
			m.mu.Lock()
			m.retries = 0
			m.reloading = false
			m.stallReloads = 0
			m.lastTick = time.Now()
			m.mu.Unlock()
		case "end-file":
			switch ev.Reason {
			case "eof":
				m.dev.logf("screen", "播放结束（eof）")
				m.dev.onPlaybackEnded()
			case "error":
				if msg := m.stderrText(); msg != "" {
					m.dev.logf("mpv", "取流报错: %s", firstLine(msg))
				}
				if m.retryAfterError() {
					break
				}
				m.dev.logf("screen", "重试 3 次仍失败，结束播放")
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
		// quit 最多等 1 秒；随后的 Close 会打断 readLoop 挂着的读。
		payload, _ := json.Marshal(map[string]any{"command": []any{"quit"}})
		m.writeMu.Lock()
		_ = writeIPC(conn, append(payload, '\n'), time.Second)
		m.writeMu.Unlock()
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

// stderrText 返回 mpv 最后的错误输出，用来解释「为什么秒退」。
func (m *mpvScreen) stderrText() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stderr == nil {
		return ""
	}
	return strings.TrimSpace(m.stderr.String())
}

// findUoscDir 找随包的 uosc 资源目录（引擎同目录的 uosc/）。
func findUoscDir() string {
	var cands []string
	if exe, err := os.Executable(); err == nil {
		cands = append(cands, filepath.Join(filepath.Dir(exe), "uosc"))
	}
	if wd, err := os.Getwd(); err == nil {
		cands = append(cands, filepath.Join(wd, "uosc"))
	}
	for _, c := range cands {
		if st, err := os.Stat(filepath.Join(c, "scripts", "uosc", "main.lua")); err == nil && !st.IsDir() {
			return c
		}
	}
	return ""
}
