//go:build !darwin || !cgo

package player

import "errors"

// Options 是一次播放的启动参数。
type Options struct {
	URL            string
	Title          string
	Width, Height  int
	Fullscreen     bool
	Volume         int
	Mute           bool
	SoftwareDecode bool
	Renderer       string
	StartPosition  float64
}

// Status 与 darwin 实现保持同构，便于上层代码跨平台编译。
type Status struct {
	Position     float64
	Duration     float64
	Clock        float64
	VideoPTS     float64
	DriftMS      float64
	DriftAvgMS   float64
	DriftP95MS   float64
	DriftMaxMS   float64
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
	Closed       bool
	Fullscreen   bool
	Hardware     bool
	HasVideo     bool
	HasAudio     bool
	Volume       int
	Muted        bool
	WindowNumber int
}

type Player struct{ opts Options }

var errUnsupported = errors.New("player: 自研播放核心目前只实现了 macOS（darwin + cgo）")

func Open(opts Options) (*Player, error) { return nil, errUnsupported }

func Version() string        { return "" }
func HardwareDevice() string { return "" }

func (p *Player) Play()                 {}
func (p *Player) Pause()                {}
func (p *Player) Toggle()               {}
func (p *Player) Stop()                 {}
func (p *Player) Seek(float64)          {}
func (p *Player) SeekRelative(float64)  {}
func (p *Player) SetVolume(int)         {}
func (p *Player) Volume() int           { return 0 }
func (p *Player) SetMute(bool)          {}
func (p *Player) Muted() bool           { return false }
func (p *Player) SetFullscreen(bool)    {}
func (p *Player) ToggleFullscreen()     {}
func (p *Player) CloseWindow()          {}
func (p *Player) WindowNumber() int     { return 0 }
func (p *Player) Status() Status        { return Status{} }
func (p *Player) VideoCodec() string    { return "" }
func (p *Player) AudioCodec() string    { return "" }
func (p *Player) OnUpdate(func(Status)) {}
func (p *Player) OnClose(func())        {}
func (p *Player) Run()                  {}
func (p *Player) Close()                {}
