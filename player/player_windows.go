//go:build windows && cgo

// Package player 是 DLNA 电视模拟器的自研播放核心（Windows 版）。
//
// 媒体管线在 C/SDL2 层：FFmpeg 软解 → SDL2 纹理（D3D11 渲染后端）出画；
// 音频 FFmpeg 解码 → swresample 转 48k 立体声 → SDL2 audio（WASAPI）播放，
// 并以音频已播放采样作为主时钟给视频帧对时。Go 层负责参数、状态机、回调与 CLI。
//
// 使用约束：SDL 窗口和事件循环必须在同一个进程主线程运行。调用方应在
// main goroutine 里先 runtime.LockOSThread()，再 Open，然后 Run。
package player

/*
#cgo CFLAGS: -D_CRT_SECURE_NO_WARNINGS
#cgo LDFLAGS: -lavformat -lavcodec -lswresample -lswscale -lavutil -lSDL2 -limm32 -lole32 -loleaut32 -luuid -lversion -lwinmm -lsetupapi -lgdi32 -luser32 -ladvapi32 -lshell32 -lbcrypt
#include <stdlib.h>
#include "engine.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"sync"
	"time"
	"unsafe"
)

// Options 是一次播放的启动参数。
type Options struct {
	URL            string  // 本地路径或 http(s) 地址
	Title          string  // 窗口标题
	DeviceName     string  // 播放器 UI 顶部显示的设备名
	Width, Height  int     // 窗口尺寸；0 表示按视频尺寸（上限 1600 宽）
	Fullscreen     bool    // 无边框全屏启动
	Volume         int     // 0-100
	Mute           bool    // 静音
	SoftwareDecode bool    // true 强制软解，用于对比硬解 CPU
	Renderer       string  // 目前只有 "layer"
	StartPosition  float64 // 起播位置（秒）
	Speed          float64 // 0.25-4，0 表示 1.0
	Aspect         string  // auto / 16:9 / 4:3 / fill
	Loop           bool    // 单文件循环
	AudioTrack     int     // 1 起，0 自动
	SubtitleTrack  int     // 1 起，0 自动选第一条；显式关闭用 SetSubtitleTrack(0)
	UserAgent      string  // HTTP User-Agent，空用 FFmpeg 默认
	Referer        string  // HTTP Referer，空不发送
}

// Status 是播放器当前状态快照，供 UI/回调使用。
type Status struct {
	Position     float64 // 当前播放位置（秒），以音频时钟为准
	Duration     float64 // 总时长（秒）
	Clock        float64 // 原始主时钟
	VideoPTS     float64 // 最后显示帧的 PTS
	DriftMS      float64 // 最近一帧 video_pts - clock
	DriftAvgMS   float64 // 已显示帧 pacing 误差均值
	DriftP95MS   float64 // pacing 误差 p95
	DriftMaxMS   float64 // pacing 误差最大值
	FramesShown  int64
	FramesDroped int64
	FirstFrameMS float64
	LastSeekMS   float64
	CPUPercent   float64
	BufferedMS   float64
	Width        int
	Height       int
	FPS          int
	Paused       bool
	Ended        bool
	Closed       bool // 用户关掉了窗口
	Fullscreen   bool
	Hardware     bool // 当前视频帧确实来自 VideoToolbox
	HasVideo     bool
	HasAudio     bool
	Volume       int
	Muted        bool
	WindowNumber int

	// 高级播放状态
	Speed          float64
	Loop           bool
	Aspect         string
	AudioTrack     int // 1 起，0 = 无
	SubtitleTrack  int // 0 = 关闭
	AudioTracks    int
	SubtitleTracks int
	Buffering      bool
	IOError        bool
}

// Track 是一条音轨/字幕轨。
type Track struct {
	ID          int
	StreamIndex int
	Type        string
	Lang        string
	Title       string
	Codec       string
	Channels    int
	Selected    bool
}

type Player struct {
	mu  sync.RWMutex
	ptr *C.PePlayer

	opts Options

	cbMu     sync.Mutex
	onUpdate func(Status)
	onClose  func()

	pollStop chan struct{}
	pollOnce sync.Once

	closeOnce sync.Once

	runMu      sync.Mutex
	runStarted bool
	runDone    chan struct{}
	runOnce    sync.Once
	closing    bool // Close 已经开始，Run 不要再进事件循环
	destroyed  bool // PePlayer 已释放，Run 绝不能再碰它
}

// Open 创建窗口并开始播放。必须在主线程调用（见包注释）。
func Open(opts Options) (*Player, error) {
	if opts.URL == "" {
		return nil, errors.New("player: 播放地址为空")
	}
	if opts.Width <= 0 {
		opts.Width = 1280
	}
	if opts.Height <= 0 {
		opts.Height = 720
	}
	if opts.Volume < 0 {
		opts.Volume = 0
	}
	if opts.Volume > 100 {
		opts.Volume = 100
	}
	if opts.Renderer == "" {
		opts.Renderer = "layer"
	}

	cURL := C.CString(opts.URL)
	defer C.free(unsafe.Pointer(cURL))
	cTitle := C.CString(opts.Title)
	defer C.free(unsafe.Pointer(cTitle))
	cDevice := C.CString(opts.DeviceName)
	defer C.free(unsafe.Pointer(cDevice))
	cRenderer := C.CString(opts.Renderer)
	defer C.free(unsafe.Pointer(cRenderer))
	aspect := opts.Aspect
	if aspect == "" {
		aspect = "auto"
	}
	cAspect := C.CString(aspect)
	defer C.free(unsafe.Pointer(cAspect))
	cUA := C.CString(opts.UserAgent)
	defer C.free(unsafe.Pointer(cUA))
	cReferer := C.CString(opts.Referer)
	defer C.free(unsafe.Pointer(cReferer))

	var cerr [512]C.char
	cfg := C.PeConfig{
		url:            cURL,
		title:          cTitle,
		device_name:    cDevice,
		width:          C.int(opts.Width),
		height:         C.int(opts.Height),
		fullscreen:     cBool(opts.Fullscreen),
		volume:         C.int(opts.Volume),
		muted:          cBool(opts.Mute),
		hardware:       cBool(!opts.SoftwareDecode),
		renderer:       cRenderer,
		user_agent:     cUA,
		referer:        cReferer,
		start_position: C.double(opts.StartPosition),
		speed:          C.double(opts.Speed),
		aspect:         cAspect,
		loop:           cBool(opts.Loop),
		audio_track:    C.int(opts.AudioTrack),
		subtitle_track: C.int(opts.SubtitleTrack),
	}
	ptr := C.pe_open(&cfg, &cerr[0], C.int(len(cerr)))
	if ptr == nil {
		msg := C.GoString(&cerr[0])
		if msg == "" {
			msg = "打开播放器失败（详情见 stderr 日志）"
		}
		return nil, errors.New(msg)
	}
	p := &Player{ptr: ptr, opts: opts, pollStop: make(chan struct{}), runDone: make(chan struct{})}
	p.startPolling()
	return p, nil
}

func cBool(v bool) C.int {
	if v {
		return 1
	}
	return 0
}

// Version 返回链接进来的 FFmpeg 版本。
func Version() string {
	return C.GoString(C.pe_ffmpeg_version())
}

// HardwareDevice 返回硬解设备类型名（Windows 版目前是软解）。
func HardwareDevice() string {
	return "software"
}

// do 在持有读锁时执行 C 调用：Close 释放 ptr 前要拿写锁，
// 这样控件指令不会打到已经销毁的 PePlayer 上。
func (p *Player) do(fn func(*C.PePlayer)) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return
	}
	fn(p.ptr)
}

func (p *Player) Play()   { p.do(func(ptr *C.PePlayer) { C.pe_play(ptr) }) }
func (p *Player) Pause()  { p.do(func(ptr *C.PePlayer) { C.pe_pause(ptr) }) }
func (p *Player) Toggle() { p.do(func(ptr *C.PePlayer) { C.pe_toggle_pause(ptr) }) }
func (p *Player) Stop()   { p.do(func(ptr *C.PePlayer) { C.pe_stop(ptr) }) }

func (p *Player) Seek(seconds float64) {
	p.do(func(ptr *C.PePlayer) { C.pe_seek(ptr, C.double(seconds)) })
}

func (p *Player) SeekRelative(delta float64) {
	p.do(func(ptr *C.PePlayer) { C.pe_seek_relative(ptr, C.double(delta)) })
}

func (p *Player) SetVolume(vol int) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_volume(ptr, C.int(vol)) })
}

func (p *Player) Volume() int {
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	if ptr == nil {
		return 0
	}
	return int(C.pe_get_volume(ptr))
}

func (p *Player) SetMute(mute bool) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_mute(ptr, cBool(mute)) })
}

func (p *Player) Muted() bool {
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	if ptr == nil {
		return false
	}
	return C.pe_get_mute(ptr) != 0
}

func (p *Player) SetFullscreen(on bool) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_fullscreen(ptr, cBool(on)) })
}

func (p *Player) ToggleFullscreen() {
	p.do(func(ptr *C.PePlayer) { C.pe_toggle_fullscreen(ptr) })
}

// CloseWindow 模拟用户点窗口关闭按钮，用于验证关闭回调。
func (p *Player) CloseWindow() {
	p.do(func(ptr *C.PePlayer) { C.pe_close_window(ptr) })
}

func (p *Player) WindowNumber() int {
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	if ptr == nil {
		return 0
	}
	return int(C.pe_window_number(ptr))
}

// Status 读取一次状态快照。读锁要一直持有到 C 调用返回，
// 否则 120ms 轮询可能在 Close 销毁播放器后读到已释放的内存。
func (p *Player) Status() Status {
	p.mu.RLock()
	defer p.mu.RUnlock()
	var st Status
	if p.ptr == nil {
		return st
	}
	var cs C.PeStatus
	C.pe_get_status(p.ptr, &cs)
	st = Status{
		Position:       float64(cs.position),
		Duration:       float64(cs.duration),
		Clock:          float64(cs.clock),
		VideoPTS:       float64(cs.video_pts),
		DriftMS:        float64(cs.drift_ms),
		DriftAvgMS:     float64(cs.drift_avg_ms),
		DriftP95MS:     float64(cs.drift_p95_ms),
		DriftMaxMS:     float64(cs.drift_max_ms),
		FramesShown:    int64(cs.frames_shown),
		FramesDroped:   int64(cs.frames_dropped),
		FirstFrameMS:   float64(cs.first_frame_ms),
		LastSeekMS:     float64(cs.last_seek_ms),
		CPUPercent:     float64(cs.cpu_percent),
		BufferedMS:     float64(cs.buffered_ms),
		Width:          int(cs.width),
		Height:         int(cs.height),
		FPS:            int(cs.fps),
		Paused:         cs.paused != 0,
		Ended:          cs.ended != 0,
		Closed:         cs.closed != 0,
		Fullscreen:     cs.fullscreen != 0,
		Hardware:       cs.hardware_decode != 0,
		HasVideo:       cs.has_video != 0,
		HasAudio:       cs.has_audio != 0,
		Volume:         int(cs.volume),
		Muted:          cs.muted != 0,
		WindowNumber:   int(cs.window_number),
		Speed:          float64(cs.speed),
		Loop:           cs.loop != 0,
		Aspect:         C.GoString(&cs.aspect[0]),
		AudioTrack:     int(cs.audio_track),
		SubtitleTrack:  int(cs.subtitle_track),
		AudioTracks:    int(cs.audio_tracks),
		SubtitleTracks: int(cs.subtitle_tracks),
		Buffering:      cs.buffering != 0,
		IOError:        cs.io_error != 0,
	}
	return st
}

func (p *Player) VideoCodec() string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return ""
	}
	return C.GoString(C.pe_video_codec(p.ptr))
}

func (p *Player) AudioCodec() string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return ""
	}
	return C.GoString(C.pe_audio_codec(p.ptr))
}

// SetSpeed 设置倍速（0.25-4）。
func (p *Player) SetSpeed(v float64) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_speed(ptr, C.double(v)) })
}

func (p *Player) Speed() float64 {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return 1
	}
	return float64(C.pe_get_speed(p.ptr))
}

func (p *Player) SetLoop(on bool) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_loop(ptr, cBool(on)) })
}

func (p *Player) Loop() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return false
	}
	return C.pe_get_loop(p.ptr) != 0
}

func (p *Player) SetAspect(a string) {
	c := C.CString(a)
	defer C.free(unsafe.Pointer(c))
	p.do(func(ptr *C.PePlayer) { C.pe_set_aspect(ptr, c) })
}

func (p *Player) Aspect() string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return "auto"
	}
	return C.GoString(C.pe_get_aspect(p.ptr))
}

func (p *Player) trackList(subtitle bool) []Track {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return nil
	}
	count := int(C.pe_audio_track_count(p.ptr))
	selected := int(C.pe_get_audio_track(p.ptr))
	typ := "audio"
	if subtitle {
		count = int(C.pe_subtitle_track_count(p.ptr))
		selected = int(C.pe_get_subtitle_track(p.ptr))
		typ = "sub"
	}
	out := make([]Track, 0, count)
	for i := 0; i < count; i++ {
		var t C.PeTrackInfo
		var rc C.int
		if subtitle {
			rc = C.pe_subtitle_track_info(p.ptr, C.int(i), &t)
		} else {
			rc = C.pe_audio_track_info(p.ptr, C.int(i), &t)
		}
		if rc != 0 {
			continue
		}
		id := int(t.id)
		out = append(out, Track{
			ID:          id,
			StreamIndex: int(t.stream_index),
			Type:        typ,
			Lang:        C.GoString(&t.lang[0]),
			Title:       C.GoString(&t.title[0]),
			Codec:       C.GoString(&t.codec[0]),
			Channels:    int(t.channels),
			Selected:    id == selected,
		})
	}
	return out
}

func (p *Player) AudioTracks() []Track    { return p.trackList(false) }
func (p *Player) SubtitleTracks() []Track { return p.trackList(true) }

func (p *Player) SetAudioTrack(id int) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_audio_track(ptr, C.int(id)) })
}

func (p *Player) SetSubtitleTrack(id int) {
	p.do(func(ptr *C.PePlayer) { C.pe_set_subtitle_track(ptr, C.int(id)) })
}

func (p *Player) SubtitleText() string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.ptr == nil {
		return ""
	}
	buf := make([]byte, 4096)
	n := C.pe_get_subtitle_text(p.ptr, (*C.char)(unsafe.Pointer(&buf[0])), C.int(len(buf)))
	if n <= 0 {
		return ""
	}
	return string(buf[:n])
}

// Screenshot 把当前视频帧写成 PNG。
func (p *Player) Screenshot(path string) error {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var errb [512]C.char
	p.mu.RLock()
	ptr := p.ptr
	if ptr == nil {
		p.mu.RUnlock()
		return errors.New("播放器已关闭")
	}
	rc := C.pe_screenshot(ptr, cpath, &errb[0], C.int(len(errb)))
	p.mu.RUnlock()
	if rc != 0 {
		msg := C.GoString(&errb[0])
		if msg == "" {
			msg = "截图失败"
		}
		return errors.New(msg)
	}
	return nil
}

func (p *Player) Title() string {
	if p.ptr == nil {
		return ""
	}
	return C.GoString(C.pe_title(p.ptr))
}

func (p *Player) DeviceName() string {
	if p.ptr == nil {
		return ""
	}
	return C.GoString(C.pe_device_name(p.ptr))
}

// ---------- 控件层脚本钩子 ----------

func (p *Player) UISetVisible(visible bool) {
	p.do(func(ptr *C.PePlayer) { C.pe_ui_set_visible(ptr, cBool(visible)) })
}

func (p *Player) UIHover(control string) {
	c := C.CString(control)
	defer C.free(unsafe.Pointer(c))
	p.do(func(ptr *C.PePlayer) { C.pe_ui_hover(ptr, c) })
}

func (p *Player) UIClick(control string) {
	c := C.CString(control)
	defer C.free(unsafe.Pointer(c))
	p.do(func(ptr *C.PePlayer) { C.pe_ui_click(ptr, c) })
}

func (p *Player) UIMenu(menu string) {
	c := C.CString(menu)
	defer C.free(unsafe.Pointer(c))
	p.do(func(ptr *C.PePlayer) { C.pe_ui_menu(ptr, c) })
}

func (p *Player) UIKey(key string) {
	c := C.CString(key)
	defer C.free(unsafe.Pointer(c))
	p.do(func(ptr *C.PePlayer) { C.pe_ui_key(ptr, c) })
}

// OnUpdate 注册状态回调，约每 120ms 调用一次。
func (p *Player) OnUpdate(fn func(Status)) {
	p.cbMu.Lock()
	p.onUpdate = fn
	p.cbMu.Unlock()
}

// OnClose 注册窗口关闭回调。
func (p *Player) OnClose(fn func()) {
	p.cbMu.Lock()
	p.onClose = fn
	p.cbMu.Unlock()
}

func (p *Player) startPolling() {
	go func() {
		ticker := time.NewTicker(120 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-p.pollStop:
				return
			case <-ticker.C:
				st := p.Status()
				p.cbMu.Lock()
				cb := p.onUpdate
				p.cbMu.Unlock()
				if cb != nil {
					cb(st)
				}
				if st.Closed {
					p.notifyClosed()
					return
				}
			}
		}
	}()
}

func (p *Player) notifyClosed() {
	p.cbMu.Lock()
	cb := p.onClose
	p.cbMu.Unlock()
	if cb != nil {
		cb()
	}
	go p.Close()
}

// Run 进入 SDL 事件循环，直到窗口关闭或 Close 被调用。必须主线程调用。
func (p *Player) Run() {
	p.runMu.Lock()
	if p.runStarted || p.closing || p.destroyed {
		// 已经跑过，或者 Close 抢在前面把播放器收了：没有可跑的事件循环。
		p.runMu.Unlock()
		return
	}
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	if ptr == nil {
		p.runMu.Unlock()
		return
	}
	p.runStarted = true
	done := p.runDone
	p.runMu.Unlock()
	C.pe_run(ptr)
	p.runOnce.Do(func() { close(done) })
}

// Close 停止播放、回收线程与窗口。可重复调用。
//
// pe_close 只停媒体线程和事件循环，真正释放 PePlayer 要等 Run 返回之后，
// 并且要拿写锁：轮询 goroutine 可能正在 Status() 里读 C 结构体。
func (p *Player) Close() {
	p.closeOnce.Do(func() {
		p.pollOnce.Do(func() { close(p.pollStop) })
		p.mu.RLock()
		ptr := p.ptr
		p.mu.RUnlock()
		if ptr == nil {
			return
		}
		// 先标明“正在关”，还没进事件的 Run 就直接返回，不会拿到空指针。
		p.runMu.Lock()
		p.closing = true
		p.runMu.Unlock()
		// 再让媒体线程停下来、事件循环退出；未跑过 Run 时直接销毁。
		C.pe_close(ptr)
		p.runMu.Lock()
		started := p.runStarted
		done := p.runDone
		p.runMu.Unlock()
		if started {
			<-done
		}
		p.mu.Lock()
		if p.ptr == ptr {
			C.pe_destroy(ptr)
			p.ptr = nil
		}
		p.mu.Unlock()
		p.runMu.Lock()
		p.destroyed = true
		p.runMu.Unlock()
	})
}

// String 便于日志里显示播放器参数。
func (p *Player) String() string {
	return fmt.Sprintf("player(%s)", p.opts.URL)
}
