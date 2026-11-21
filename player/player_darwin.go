//go:build darwin && cgo

// Package player 是 DLNA 电视模拟器的自研播放核心（macOS spike）。
//
// 媒体管线在 C/ObjC 层：FFmpeg 解封装 → VideoToolbox 硬解 →
// AVSampleBufferDisplayLayer 显示；音频 FFmpeg 解码 → AVAudioEngine 播放，
// 并以音频渲染时间作为主时钟给视频帧对时。Go 层负责参数、状态机、回调与 CLI。
//
// 使用约束：macOS 的 NSApplication 事件循环必须在主线程运行。调用方应在
// main goroutine 里先 runtime.LockOSThread()，再 Open，然后 Run。
package player

/*
#cgo pkg-config: libavformat libavcodec libavutil libswscale libswresample
#cgo CFLAGS: -fobjc-arc -Wno-deprecated-declarations
#cgo LDFLAGS: -framework Cocoa -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore
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
	Width, Height  int     // 窗口尺寸；0 表示按视频尺寸（上限 1600 宽）
	Fullscreen     bool    // 无边框全屏启动
	Volume         int     // 0-100
	Mute           bool    // 静音
	SoftwareDecode bool    // true 强制软解，用于对比硬解 CPU
	Renderer       string  // 目前只有 "layer"
	StartPosition  float64 // 起播位置（秒）
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
	cRenderer := C.CString(opts.Renderer)
	defer C.free(unsafe.Pointer(cRenderer))

	var cerr [512]C.char
	cfg := C.PeConfig{
		url:            cURL,
		title:          cTitle,
		width:          C.int(opts.Width),
		height:         C.int(opts.Height),
		fullscreen:     cBool(opts.Fullscreen),
		volume:         C.int(opts.Volume),
		muted:          cBool(opts.Mute),
		hardware:       cBool(!opts.SoftwareDecode),
		renderer:       cRenderer,
		start_position: C.double(opts.StartPosition),
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

// HardwareDevice 返回硬解设备类型名（videotoolbox）。
func HardwareDevice() string {
	return "videotoolbox"
}

func (p *Player) do(fn func(*C.PePlayer)) {
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	if ptr == nil {
		return
	}
	fn(ptr)
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

// Status 读取一次状态快照。
func (p *Player) Status() Status {
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	var st Status
	if ptr == nil {
		return st
	}
	var cs C.PeStatus
	C.pe_get_status(ptr, &cs)
	st = Status{
		Position:     float64(cs.position),
		Duration:     float64(cs.duration),
		Clock:        float64(cs.clock),
		VideoPTS:     float64(cs.video_pts),
		DriftMS:      float64(cs.drift_ms),
		DriftAvgMS:   float64(cs.drift_avg_ms),
		DriftP95MS:   float64(cs.drift_p95_ms),
		DriftMaxMS:   float64(cs.drift_max_ms),
		FramesShown:  int64(cs.frames_shown),
		FramesDroped: int64(cs.frames_dropped),
		FirstFrameMS: float64(cs.first_frame_ms),
		LastSeekMS:   float64(cs.last_seek_ms),
		CPUPercent:   float64(cs.cpu_percent),
		BufferedMS:   float64(cs.buffered_ms),
		Width:        int(cs.width),
		Height:       int(cs.height),
		FPS:          int(cs.fps),
		Paused:       cs.paused != 0,
		Ended:        cs.ended != 0,
		Closed:       cs.closed != 0,
		Fullscreen:   cs.fullscreen != 0,
		Hardware:     cs.hardware_decode != 0,
		HasVideo:     cs.has_video != 0,
		HasAudio:     cs.has_audio != 0,
		Volume:       int(cs.volume),
		Muted:        cs.muted != 0,
		WindowNumber: int(cs.window_number),
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

// Run 进入 macOS 事件循环，直到窗口关闭或 Close 被调用。必须主线程调用。
func (p *Player) Run() {
	p.mu.RLock()
	ptr := p.ptr
	p.mu.RUnlock()
	if ptr == nil {
		return
	}
	p.runMu.Lock()
	p.runStarted = true
	done := p.runDone
	p.runMu.Unlock()
	C.pe_run(ptr)
	p.runOnce.Do(func() { close(done) })
}

// Close 停止播放、回收线程与窗口。可重复调用。
func (p *Player) Close() {
	p.closeOnce.Do(func() {
		p.pollOnce.Do(func() { close(p.pollStop) })
		p.mu.Lock()
		ptr := p.ptr
		if ptr == nil {
			p.mu.Unlock()
			return
		}
		// 先让媒体线程停下来、事件循环退出；未跑过 Run 时直接销毁。
		C.pe_close(ptr)
		p.runMu.Lock()
		started := p.runStarted
		done := p.runDone
		p.runMu.Unlock()
		if started {
			<-done
		}
		C.pe_destroy(ptr)
		p.ptr = nil
		p.mu.Unlock()
	})
}

// String 便于日志里显示播放器参数。
func (p *Player) String() string {
	return fmt.Sprintf("player(%s)", p.opts.URL)
}
