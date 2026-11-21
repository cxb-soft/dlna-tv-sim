package main

import (
	"context"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	serviceAVTransport       = "AVTransport"
	serviceRenderingControl  = "RenderingControl"
	serviceConnectionManager = "ConnectionManager"

	stateNoMedia       = "NO_MEDIA_PRESENT"
	stateStopped       = "STOPPED"
	statePlaying       = "PLAYING"
	statePaused        = "PAUSED_PLAYBACK"
	stateTransitioning = "TRANSITIONING"

	serverString = "Linux/4.9.0 UPnP/1.0 DLNADOC/1.50 DLNA-TV-SIM/1.0"
)

// Probe 记录"电视"去拉取媒体地址的结果——真电视也会这么干。
type Probe struct {
	URI         string `json:"uri"`
	Status      string `json:"status"` // idle connecting streaming error skipped
	Detail      string `json:"detail"`
	ContentType string `json:"content_type"`
	Length      int64  `json:"length"`
	Bytes       int64  `json:"bytes"`
	At          string `json:"at"`
}

// Device 是一台 DLNA MediaRenderer（DMR）的完整状态。
type Device struct {
	mu      sync.RWMutex
	cfg     Config
	cfgPath string
	log     *EventLog
	verbose bool

	// AVTransport
	state     string
	status    string
	uri       string
	uriMeta   string
	nextURI   string
	nextMeta  string
	duration  time.Duration
	trackNo   int
	pos       time.Duration
	posAt     time.Time
	playSpeed string
	playMode  string

	// RenderingControl
	volume int
	mute   bool

	// 播放器高级选项（控制台可调，mpv 引擎会真正生效）
	speed      float64
	loop       bool
	aspect     string
	tracks     []TrackInfo
	bitrate    float64
	fps        float64
	lastShot   string
	lastShotAt time.Time

	probe Probe

	subs      *Subscriptions
	msCount   int64
	soapCount int64
	httpPort  int
	startedAt time.Time
	bootID    int
	client    *http.Client

	scr          screen
	srv          *http.Server
	sd           *SSDP
	streamClient *http.Client
	native       *nativeHost
}

func NewDevice(cfg Config, cfgPath string, verbose bool) *Device {
	d := &Device{
		cfg:       cfg,
		cfgPath:   cfgPath,
		verbose:   verbose,
		log:       NewEventLog(2000),
		state:     stateNoMedia,
		status:    "OK",
		playSpeed: "1",
		playMode:  "NORMAL",
		volume:    30,
		speed:     1,
		aspect:    "auto",
		startedAt: time.Now(),
		bootID:    int(time.Now().Unix() % 2147483647),
		client: &http.Client{
			Timeout: 20 * time.Second,
			// 允许没有 User-Agent 的老式源
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				DisableCompression:    true,
				ResponseHeaderTimeout: 12 * time.Second,
			},
		},
		streamClient: &http.Client{
			// 代理给浏览器拉流用：不能设总超时，否则长视频会被掐断
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				DisableCompression:    true,
				ResponseHeaderTimeout: 15 * time.Second,
				ForceAttemptHTTP2:     true,
			},
		},
	}
	d.subs = newSubscriptions(d)
	d.native = newNativeHost()
	return d
}

func (d *Device) logf(kind, format string, args ...any) {
	d.log.Add(kind, format, args...)
}

// ---------- 位置 / 时间 ----------

func (d *Device) positionLocked() time.Duration {
	if d.state == statePlaying {
		p := d.pos + time.Since(d.posAt)
		if d.duration > 0 && p > d.duration {
			p = d.duration
		}
		return p
	}
	return d.pos
}

func (d *Device) Position() time.Duration {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.positionLocked()
}

func formatTime(dur time.Duration) string {
	if dur < 0 {
		dur = 0
	}
	s := int64(dur / time.Second)
	return fmt.Sprintf("%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
}

func parseTimeTarget(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	parts := strings.Split(s, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, fmt.Errorf("无法解析时间: %q", s)
	}
	var h, m int
	var sec float64
	var err error
	if len(parts) == 3 {
		if h, err = strconv.Atoi(parts[0]); err != nil {
			return 0, fmt.Errorf("无法解析时间: %q", s)
		}
		if m, err = strconv.Atoi(parts[1]); err != nil {
			return 0, fmt.Errorf("无法解析时间: %q", s)
		}
		if sec, err = strconv.ParseFloat(parts[2], 64); err != nil {
			return 0, fmt.Errorf("无法解析时间: %q", s)
		}
	} else {
		if m, err = strconv.Atoi(parts[0]); err != nil {
			return 0, fmt.Errorf("无法解析时间: %q", s)
		}
		if sec, err = strconv.ParseFloat(parts[1], 64); err != nil {
			return 0, fmt.Errorf("无法解析时间: %q", s)
		}
	}
	if h < 0 || m < 0 || sec < 0 {
		return 0, fmt.Errorf("无法解析时间: %q", s)
	}
	return time.Duration(h)*time.Hour + time.Duration(m)*time.Minute +
		time.Duration(sec*float64(time.Second)), nil
}

var (
	reResDuration = regexp.MustCompile(`(?is)<res\b[^>]*\bduration\s*=\s*"([^"]*)"`)
	reTitle       = regexp.MustCompile(`(?is)<dc:title[^>]*>(.*?)</dc:title>`)
	reResFormat   = regexp.MustCompile(`(?is)<res\b[^>]*>\s*(.*?)\s*</res>`)
)

// mediaTitle 从 DIDL-Lite 元数据里捞标题，捞不到就用 URL。
func mediaTitle(meta, uri string) string {
	if m := reTitle.FindStringSubmatch(meta); len(m) == 2 {
		if t := strings.TrimSpace(html.UnescapeString(m[1])); t != "" {
			return t
		}
	}
	if m := reResFormat.FindStringSubmatch(meta); len(m) == 2 {
		if u := strings.TrimSpace(html.UnescapeString(m[1])); u != "" {
			return u
		}
	}
	if u, err := url.Parse(uri); err == nil && u.Path != "" {
		seg := u.Path[strings.LastIndex(u.Path, "/")+1:]
		if seg != "" {
			return seg
		}
	}
	return uri
}

func durationFromMeta(meta string) time.Duration {
	m := reResDuration.FindStringSubmatch(meta)
	if len(m) != 2 {
		return 0
	}
	v := strings.TrimSpace(strings.ReplaceAll(m[1], ",", "."))
	if v == "" || strings.EqualFold(v, "unknown") {
		return 0
	}
	d, err := parseTimeTarget(v)
	if err != nil {
		return 0
	}
	return d
}

// ---------- 状态变更广播 ----------

// eventedVars 返回某服务当前所有"可变事件"变量值（LastChange 的原始素材）。
func (d *Device) eventedVars(service string) map[string]string {
	d.mu.RLock()
	defer d.mu.RUnlock()
	switch service {
	case serviceAVTransport:
		vars := map[string]string{
			"TransportState":             d.state,
			"TransportStatus":            d.status,
			"TransportPlaySpeed":         d.playSpeed,
			"CurrentPlayMode":            d.playMode,
			"PlaybackStorageMedium":      "NETWORK",
			"NumberOfTracks":             strconv.Itoa(d.trackCountLocked()),
			"CurrentTrack":               strconv.Itoa(d.trackNo),
			"AVTransportURI":             d.uri,
			"AVTransportURIMetaData":     d.uriMeta,
			"CurrentTrackURI":            d.uri,
			"CurrentTrackMetaData":       d.uriMeta,
			"CurrentTrackDuration":       formatTime(d.duration),
			"CurrentMediaDuration":       formatTime(d.duration),
			"NextAVTransportURI":         d.nextURI,
			"NextAVTransportURIMetaData": d.nextMeta,
			"CurrentTransportActions":    d.transportActionsLocked(),
		}
		return vars
	case serviceRenderingControl:
		return map[string]string{
			"Volume":         strconv.Itoa(d.volume),
			"Mute":           boolStr(d.mute),
			"PresetNameList": "FactoryDefaults",
		}
	}
	return nil
}

func (d *Device) trackCountLocked() int {
	if d.uri == "" {
		return 0
	}
	n := 1
	if d.nextURI != "" {
		n = 2
	}
	return n
}

func (d *Device) transportActionsLocked() string {
	if d.uri == "" {
		return ""
	}
	switch d.state {
	case statePlaying:
		return "Play,Stop,Pause,Seek"
	case statePaused:
		return "Play,Stop,Seek"
	case stateStopped:
		return "Play,Seek,Stop"
	case stateTransitioning:
		return "Stop"
	}
	return "Play,Stop,Seek"
}

func boolStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// emit 在状态变化后推事件给所有订阅了该服务的控制点。
func (d *Device) emit(service string) {
	vars := d.eventedVars(service)
	if vars == nil {
		return
	}
	d.subs.notify(service, vars)
}

// ---------- 播放控制（供 SOAP 与网页共用） ----------

type upnpError struct {
	Code int
	Desc string
}

func (d *Device) SetURI(uri, meta string) {
	uri = strings.TrimSpace(uri)
	d.mu.Lock()
	if uri == "" {
		d.uri, d.uriMeta = "", ""
		d.nextURI, d.nextMeta = "", ""
		d.duration, d.pos, d.posAt = 0, 0, time.Now()
		d.state, d.trackNo = stateNoMedia, 0
		d.mu.Unlock()
		// 不少控制点结束投屏是「把 URI 置空」而不是发 Stop，这里也要把播放器收掉。
		d.closeScreen()
		d.emit(serviceAVTransport)
		d.logf("avt", "清空当前媒体")
		return
	}
	d.uri, d.uriMeta = uri, meta
	d.nextURI, d.nextMeta = "", ""
	d.duration = durationFromMeta(meta)
	d.pos, d.posAt = 0, time.Now()
	d.trackNo = 1
	if d.state != stateStopped {
		d.state = stateStopped
	}
	d.mu.Unlock()
	d.logf("avt", "SetAVTransportURI: %s", mediaTitle(meta, uri))
	d.emit(serviceAVTransport)
}

func (d *Device) Play() *upnpError {
	d.mu.Lock()
	if d.uri == "" {
		d.mu.Unlock()
		return &upnpError{701, "Transition not available"}
	}
	if d.state == statePlaying {
		d.mu.Unlock()
		return nil
	}
	d.state = stateTransitioning
	d.posAt = time.Now()
	uri, volume, mute := d.uri, d.volume, d.mute
	meta := d.uriMeta
	d.mu.Unlock()

	d.emit(serviceAVTransport)
	d.logf("avt", "Play")

	go func() {
		time.Sleep(120 * time.Millisecond)
		d.mu.Lock()
		if d.state != stateTransitioning {
			d.mu.Unlock()
			return
		}
		d.state = statePlaying
		d.posAt = time.Now()
		d.mu.Unlock()
		d.emit(serviceAVTransport)
		d.showOnScreen(uri, mediaTitle(meta, uri), volume, mute)
		go d.probeMedia(uri)
	}()
	return nil
}

func (d *Device) Pause() *upnpError {
	d.mu.Lock()
	switch d.state {
	case statePlaying:
		d.pos = d.positionLocked()
		d.posAt = time.Now()
		d.state = statePaused
	case statePaused:
		d.mu.Unlock()
		return nil
	default:
		d.mu.Unlock()
		return &upnpError{701, "Transition not available"}
	}
	d.mu.Unlock()
	if d.scr != nil {
		d.scr.Pause()
	}
	d.logf("avt", "Pause")
	d.emit(serviceAVTransport)
	return nil
}

func (d *Device) Stop() *upnpError {
	d.mu.Lock()
	if d.uri == "" {
		d.mu.Unlock()
		// 有些控制点先清 URI 再 Stop；这时即使没有媒体，也要收掉可能还开着的窗口。
		d.closeScreen()
		d.logf("avt", "Stop（当前无媒体）")
		return &upnpError{701, "Transition not available"}
	}
	d.pos, d.posAt = 0, time.Now()
	d.state = stateStopped
	d.mu.Unlock()
	if d.scr != nil {
		d.scr.Stop()
	}
	// 投屏结束就把播放器窗口收掉，不留一个空着的 mpv。
	d.closeScreen()
	d.logf("avt", "Stop")
	d.emit(serviceAVTransport)
	return nil
}

// closeScreen 关掉当前播放器并清空引用；下次 Play 会重新创建。
// Close 会发 quit 并等进程退出，所以不要在持锁时调。
func (d *Device) closeScreen() {
	d.mu.Lock()
	scr := d.scr
	d.scr = nil
	d.mu.Unlock()
	if scr != nil {
		scr.Close()
	}
}

func (d *Device) Seek(target time.Duration) *upnpError {
	d.mu.Lock()
	if d.uri == "" {
		d.mu.Unlock()
		return &upnpError{701, "Transition not available"}
	}
	if target < 0 {
		d.mu.Unlock()
		return &upnpError{711, "Illegal seek target"}
	}
	if d.duration > 0 && target > d.duration {
		d.mu.Unlock()
		return &upnpError{711, "Illegal seek target"}
	}
	d.pos = target
	d.posAt = time.Now()
	d.mu.Unlock()
	if d.scr != nil {
		d.scr.Seek(target)
	}
	d.logf("avt", "Seek → %s", formatTime(target))
	d.emit(serviceAVTransport)
	return nil
}

func (d *Device) SetVolume(v int) *upnpError {
	if v < 0 || v > 100 {
		return &upnpError{402, "Invalid Args"}
	}
	d.mu.Lock()
	d.volume = v
	d.mu.Unlock()
	if d.scr != nil {
		d.scr.SetVolume(v)
	}
	d.logf("rcs", "音量 → %d", v)
	d.emit(serviceRenderingControl)
	return nil
}

func (d *Device) SetMute(m bool) {
	d.mu.Lock()
	d.mute = m
	d.mu.Unlock()
	if d.scr != nil {
		d.scr.SetMute(m)
	}
	d.logf("rcs", "静音 → %v", m)
	d.emit(serviceRenderingControl)
}

// Cast 是网页遥控器用的"一键投屏"：设地址 + 播放。
func (d *Device) Cast(uri, meta string) *upnpError {
	d.SetURI(uri, meta)
	d.mu.RLock()
	state := d.state
	d.mu.RUnlock()
	if state == stateNoMedia {
		return &upnpError{402, "Invalid Args"}
	}
	return d.Play()
}

// ---------- 媒体探测：真电视会去连这个地址 ----------

func (d *Device) setProbe(p Probe) {
	p.At = time.Now().Format("15:04:05")
	d.mu.Lock()
	d.probe = p
	d.mu.Unlock()
}

func (d *Device) ProbeInfo() Probe {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.probe
}

func (d *Device) probeMedia(uri string) {
	u, err := url.Parse(uri)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		d.setProbe(Probe{URI: uri, Status: "skipped", Detail: "非 HTTP 地址，交给播放器直接解码"})
		return
	}
	d.setProbe(Probe{URI: uri, Status: "connecting"})
	d.logf("media", "拉流: %s", uri)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, uri, nil)
	if err != nil {
		d.setProbe(Probe{URI: uri, Status: "error", Detail: err.Error()})
		return
	}
	req.Header.Set("Range", "bytes=0-1048575")
	req.Header.Set("User-Agent", serverString)
	req.Header.Set("Accept", "*/*")
	resp, err := d.client.Do(req)
	if err != nil {
		d.setProbe(Probe{URI: uri, Status: "error", Detail: err.Error()})
		d.logf("media", "拉流失败: %v", err)
		return
	}
	defer resp.Body.Close()
	n, copyErr := io.CopyN(io.Discard, resp.Body, 256*1024)
	if copyErr != nil && copyErr != io.EOF {
		d.logf("media", "读取中断（%d 字节后）: %v", n, copyErr)
	}
	length := resp.ContentLength
	if cr := resp.Header.Get("Content-Range"); cr != "" {
		if i := strings.LastIndex(cr, "/"); i >= 0 {
			if total, e := strconv.ParseInt(strings.TrimSpace(cr[i+1:]), 10, 64); e == nil && total > 0 {
				length = total
			}
		}
	}
	d.setProbe(Probe{
		URI:         uri,
		Status:      "streaming",
		Detail:      resp.Status,
		ContentType: resp.Header.Get("Content-Type"),
		Length:      length,
		Bytes:       n,
	})
	d.logf("media", "拉流成功 %s %s 已取 %d 字节", resp.Status, resp.Header.Get("Content-Type"), n)
}

// ---------- 给网页用的快照 ----------

// TrackInfo 是一条音轨/字幕轨的摘要，目前由 mpv 提供。
type TrackInfo struct {
	ID       int    `json:"id"`
	Type     string `json:"type"` // audio / sub
	Title    string `json:"title"`
	Lang     string `json:"lang"`
	Codec    string `json:"codec"`
	Selected bool   `json:"selected"`
}

// PlayerStats 是播放引擎的实时指标，拿不到就是 0。
type PlayerStats struct {
	BitrateKbps float64 `json:"bitrate_kbps"`
	FPS         float64 `json:"fps"`
}

func capabilitiesFor(engine string) []string {
	switch engine {
	case "mpv":
		return []string{"speed", "loop", "aspect", "tracks", "screenshot", "stats"}
	case "native":
		return []string{"speed", "loop", "aspect", "tracks", "screenshot"}
	case "web":
		return []string{"speed", "loop"}
	}
	return []string{}
}

// engineNameLocked 算出当前（或第一次投屏时）会用的引擎。
// 还没有屏幕实例时按配置和本机可用性推算，避免控制台先显示成"网页播放"。
func (d *Device) engineNameLocked() string {
	if d.scr != nil {
		return d.scr.Kind()
	}
	switch strings.ToLower(strings.TrimSpace(d.cfg.Player)) {
	case "web":
		return "web"
	case "native":
		if nativeAvailable() {
			return "native"
		}
		return "web"
	case "vlc":
		if findVLC() != "" {
			return "vlc"
		}
		return "web"
	case "mpv":
		if findMPV() != "" {
			return "mpv"
		}
		return "web"
	}
	if findMPV() != "" {
		return "mpv"
	}
	if findVLC() != "" {
		return "vlc"
	}
	return "web"
}

// ReportDuration 让网页播放器把拿到的时长告诉设备，
// 这样 DLNA 侧 GetMediaDuration 和进度条才有值（mpv 自己会报）。
func (d *Device) ReportDuration(dur time.Duration) {
	if dur <= 0 {
		return
	}
	d.mu.Lock()
	changed := d.duration == 0 || d.duration > dur+500*time.Millisecond || d.duration < dur-500*time.Millisecond
	if changed {
		d.duration = dur
	}
	d.mu.Unlock()
	if changed {
		d.logf("player", "网页播放器上报时长 %s", dur.Truncate(time.Second))
		d.emit(serviceAVTransport)
	}
}

// SetSpeed 调整播放倍速（0.25x–4x）。mpv 立即生效，网页引擎由页面应用。
func (d *Device) SetSpeed(v float64) *upnpError {
	if v < 0.25 || v > 4 {
		return &upnpError{402, "Invalid Args"}
	}
	d.mu.Lock()
	d.speed = v
	d.mu.Unlock()
	if e, ok := d.scr.(playerEngine); ok {
		e.SetSpeed(v)
	}
	d.logf("player", "播放倍速 → %gx", v)
	return nil
}

func (d *Device) SetLoop(on bool) *upnpError {
	d.mu.Lock()
	d.loop = on
	d.mu.Unlock()
	if e, ok := d.scr.(playerEngine); ok {
		e.SetLoop(on)
	}
	d.logf("player", "循环播放 → %v", on)
	return nil
}

func (d *Device) SetAspect(a string) *upnpError {
	switch a {
	case "auto", "16:9", "4:3", "21:9":
	default:
		return &upnpError{402, "Invalid Args"}
	}
	d.mu.Lock()
	d.aspect = a
	d.mu.Unlock()
	if e, ok := d.scr.(playerEngine); ok {
		e.SetAspect(a)
	}
	d.logf("player", "画面比例 → %s", a)
	return nil
}

// SelectTrack 切音轨或字幕轨；kind=audio/sub，id=0 表示关掉字幕。
func (d *Device) SelectTrack(kind string, id int) *upnpError {
	if kind != "audio" && kind != "sub" {
		return &upnpError{402, "Invalid Args"}
	}
	if id < 0 {
		return &upnpError{402, "Invalid Args"}
	}
	d.mu.RLock()
	tracks := d.tracks
	d.mu.RUnlock()
	if id > 0 && len(tracks) > 0 {
		found := false
		for _, t := range tracks {
			if t.ID == id && t.Type == kind {
				found = true
				break
			}
		}
		if !found {
			return &upnpError{402, "Invalid Args"}
		}
	}
	if e, ok := d.scr.(playerEngine); ok {
		e.SelectTrack(kind, id)
	}
	d.logf("player", "切%s轨 → %d", kind, id)
	return nil
}

// Screenshot 让播放引擎截一张当前画面，返回文件路径。
func (d *Device) Screenshot() (string, *upnpError) {
	e, ok := d.scr.(playerEngine)
	if !ok {
		return "", &upnpError{501, "Action Failed"}
	}
	path := filepath.Join(os.TempDir(), fmt.Sprintf("dlna-tv-shot-%d.png", time.Now().UnixNano()))
	if err := e.ScreenshotTo(path); err != nil {
		d.logf("player", "截图失败: %v", err)
		return "", &upnpError{501, "Action Failed"}
	}
	d.mu.Lock()
	old := d.lastShot
	d.lastShot = path
	d.lastShotAt = time.Now()
	d.mu.Unlock()
	if old != "" && old != path {
		_ = os.Remove(old)
	}
	d.logf("player", "已截图")
	return path, nil
}

func (d *Device) lastScreenshot() string {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.lastShot
}

func (d *Device) noteSpeed(v float64) {
	d.mu.Lock()
	d.speed = v
	d.mu.Unlock()
}

func (d *Device) noteLoop(on bool) {
	d.mu.Lock()
	d.loop = on
	d.mu.Unlock()
}

func (d *Device) setTracks(list []TrackInfo) {
	d.mu.Lock()
	d.tracks = list
	d.mu.Unlock()
}

func (d *Device) setBitrate(bps float64) {
	d.mu.Lock()
	d.bitrate = bps / 1000
	d.mu.Unlock()
}

func (d *Device) setFPS(f float64) {
	d.mu.Lock()
	d.fps = f
	d.mu.Unlock()
}

// PlayerState 是 /api/player 的返回：控制台据此渲染高级控制。
func (d *Device) PlayerState() map[string]any {
	s := d.Snapshot()
	return map[string]any{
		"engine":       s.Player,
		"speed":        s.Speed,
		"loop":         s.Loop,
		"aspect":       s.Aspect,
		"tracks":       s.Tracks,
		"capabilities": s.Capabilities,
		"stats":        s.Stats,
	}
}

type StateJSON struct {
	FriendlyName  string   `json:"friendly_name"`
	UUID          string   `json:"uuid"`
	ModelName     string   `json:"model_name"`
	State         string   `json:"state"`
	Status        string   `json:"status"`
	URI           string   `json:"uri"`
	Title         string   `json:"title"`
	Meta          string   `json:"meta"`
	NextURI       string   `json:"next_uri"`
	Duration      float64  `json:"duration"`
	Position      float64  `json:"position"`
	Volume        int      `json:"volume"`
	Mute          bool     `json:"mute"`
	PlayMode      string   `json:"play_mode"`
	Subscribers   int      `json:"subscribers"`
	MSearch       int64    `json:"msearch"`
	SOAPCalls     int64    `json:"soap_calls"`
	Probe         Probe    `json:"probe"`
	Addresses     []string `json:"addresses"`
	Port          int      `json:"port"`
	UptimeSeconds int64    `json:"uptime"`
	Player        string   `json:"player"`
	Version       string   `json:"version"`

	// 高级播放状态
	Speed        float64     `json:"speed"`
	Loop         bool        `json:"loop"`
	Aspect       string      `json:"aspect"`
	Tracks       []TrackInfo `json:"tracks"`
	Capabilities []string    `json:"capabilities"`
	Stats        PlayerStats `json:"stats"`
}

func (d *Device) Snapshot() StateJSON {
	d.mu.RLock()
	player := d.engineNameLocked()
	s := StateJSON{
		FriendlyName:  d.cfg.FriendlyName,
		UUID:          d.cfg.UUID,
		ModelName:     d.cfg.ModelName,
		State:         d.state,
		Status:        d.status,
		URI:           d.uri,
		Title:         mediaTitle(d.uriMeta, d.uri),
		Meta:          d.uriMeta,
		NextURI:       d.nextURI,
		Duration:      d.duration.Seconds(),
		Position:      d.positionLocked().Seconds(),
		Volume:        d.volume,
		Mute:          d.mute,
		PlayMode:      d.playMode,
		Probe:         d.probe,
		Port:          d.httpPort,
		UptimeSeconds: int64(time.Since(d.startedAt).Seconds()),
		Version:       version,
		Speed:         d.speed,
		Loop:          d.loop,
		Aspect:        d.aspect,
		Tracks:        append([]TrackInfo(nil), d.tracks...),
		Capabilities:  capabilitiesFor(player),
		Stats:         PlayerStats{BitrateKbps: d.bitrate, FPS: d.fps},
	}
	s.Player = player
	d.mu.RUnlock()

	s.Subscribers = d.subs.count()
	s.MSearch = atomic.LoadInt64(&d.msCount)
	s.SOAPCalls = atomic.LoadInt64(&d.soapCount)
	s.Addresses = localIPv4s()
	return s
}

// localIPv4s 返回本机可用于访问的 IPv4 地址（给网页展示、构造 LOCATION）。
func localIPv4s() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []string
	for _, ifi := range ifaces {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipnet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}
			out = append(out, ip4.String())
		}
	}
	sort.Slice(out, func(i, j int) bool {
		// 让 192.168/10/172 私有网段排前面
		return rankIP(out[i]) < rankIP(out[j])
	})
	return out
}

func rankIP(ip string) int {
	switch {
	case strings.HasPrefix(ip, "192.168."):
		return 0
	case strings.HasPrefix(ip, "10."):
		return 1
	case strings.HasPrefix(ip, "172."):
		return 2
	case strings.HasPrefix(ip, "100."):
		return 4
	default:
		return 3
	}
}
