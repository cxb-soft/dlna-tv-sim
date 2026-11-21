//go:build !darwin || !cgo

package player

import "errors"

// Options 是一次播放的启动参数。
type Options struct {
	URL            string
	Title          string
	DeviceName     string
	Width, Height  int
	Fullscreen     bool
	Volume         int
	Mute           bool
	SoftwareDecode bool
	Renderer       string
	StartPosition  float64
	Speed          float64
	Aspect         string
	Loop           bool
	AudioTrack     int
	SubtitleTrack  int
}

// Track 与 darwin 实现保持同构。
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

	Speed          float64
	Loop           bool
	Aspect         string
	AudioTrack     int
	SubtitleTrack  int
	AudioTracks    int
	SubtitleTracks int
	Buffering      bool
	IOError        bool
}

type Player struct{ opts Options }

var errUnsupported = errors.New("player: 自研播放核心目前只实现了 macOS（darwin + cgo）")

func Open(opts Options) (*Player, error) { return nil, errUnsupported }

func Version() string        { return "" }
func HardwareDevice() string { return "" }

func (p *Player) Play()                 {}
func (p *Player) Pause()                {}
func (p *Player) Toggle()               {}
func (p *Player) Restart()              {}
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

func (p *Player) SetSpeed(float64)        {}
func (p *Player) Speed() float64          { return 1 }
func (p *Player) SetLoop(bool)            {}
func (p *Player) Loop() bool              { return false }
func (p *Player) SetAspect(string)        {}
func (p *Player) Aspect() string          { return "auto" }
func (p *Player) AudioTracks() []Track    { return nil }
func (p *Player) SubtitleTracks() []Track { return nil }
func (p *Player) SetAudioTrack(int)       {}
func (p *Player) SetSubtitleTrack(int)    {}
func (p *Player) SubtitleText() string    { return "" }
func (p *Player) Screenshot(string) error { return errUnsupported }
func (p *Player) Title() string           { return "" }
func (p *Player) DeviceName() string      { return "" }
func (p *Player) UISetVisible(bool)       {}
func (p *Player) UIHover(string)          {}
func (p *Player) UIClick(string)          {}
func (p *Player) UIMenu(string)           {}
func (p *Player) UIKey(string)            {}
