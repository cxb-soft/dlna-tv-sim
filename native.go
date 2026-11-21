//go:build darwin && cgo

package main

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"dlnatvsim/player"
)

// nativeAvailable 表示这台机器/这个构建能不能用自研播放核心。
func nativeAvailable() bool { return true }

var errNativeHostStopped = errors.New("播放器主线程已退出")

// nativeOpenReq 是一次"打开新片"的请求。所有 AppKit 调用都必须在主线程，
// 所以 Open 不在投屏的 goroutine 里做，而是投递给主线程的 host 循环。
type nativeOpenReq struct {
	opts  player.Options
	onNew func(*player.Player) // 主线程上、Run 之前安装回调
	res   chan error
}

// nativeHost 把自研播放核心的事件循环固定在进程主线程。
//
// macOS 的窗口创建和 NSApp 事件循环都必须在主线程：main() 起完 SSDP/HTTP
// 之后进入 Run() 常驻，投屏请求通过 channel 送进来，由主线程 Open 再 Run。
// 播放期间的 Play/Pause/Seek/音量是引擎内部线程安全的调用，可以直接从
// SOAP goroutine 调；只有 Open 和关窗必须回到主线程。
type nativeHost struct {
	mu       sync.Mutex
	current  *player.Player
	ready    bool
	stopping bool

	opens chan nativeOpenReq
	done  chan struct{}
	once  sync.Once
}

func newNativeHost() *nativeHost {
	return &nativeHost{
		opens: make(chan nativeOpenReq, 4),
		done:  make(chan struct{}),
	}
}

// Start 在 main() 起 HTTP 之前调用：告诉 host 主线程马上会进入 Run。
// 这样 Listen() 之后、Run() 之前到达的第一次投屏也能排队等主线程。
func (h *nativeHost) Start() {
	h.mu.Lock()
	h.ready = true
	h.mu.Unlock()
}

// Run 是主线程上的播放器事件循环，阻塞到 Shutdown。必须主线程调用。
func (h *nativeHost) Run() {
	for {
		select {
		case req := <-h.opens:
			p, err := player.Open(req.opts) // 主线程：AppKit 建窗
			if err != nil {
				req.res <- err
				continue
			}
			h.mu.Lock()
			stopping := h.stopping
			if !stopping {
				h.current = p
			}
			h.mu.Unlock()
			if stopping {
				p.Close()
				req.res <- errNativeHostStopped
				continue
			}
			if req.onNew != nil {
				req.onNew(p)
			}
			req.res <- nil
			p.Run() // 阻塞到窗口被关或 Close
			h.mu.Lock()
			if h.current == p {
				h.current = nil
			}
			stopping = h.stopping
			h.mu.Unlock()
			p.Close()
			if stopping {
				return
			}
		case <-h.done:
			return
		}
	}
}

// Shutdown 让主线程的 Run 退出；正在播的窗口会在主线程上收掉。
func (h *nativeHost) Shutdown() {
	h.mu.Lock()
	h.stopping = true
	p := h.current
	h.mu.Unlock()
	h.once.Do(func() { close(h.done) })
	if p != nil {
		p.Close()
	}
}

// requestOpen 把打开请求投递给主线程；host 没在跑（比如单测里）就返回 false。
func (h *nativeHost) requestOpen(req nativeOpenReq) bool {
	h.mu.Lock()
	ready, stopping := h.ready, h.stopping
	h.mu.Unlock()
	if !ready || stopping {
		return false
	}
	select {
	case h.opens <- req:
		return true
	case <-h.done:
		return false
	}
}

func (h *nativeHost) player() *player.Player {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.current
}

func (h *nativeHost) closeCurrent() {
	if p := h.player(); p != nil {
		p.Close()
	}
}

// newNativeScreen 只在这个平台上有真正的实现。
func newNativeScreen(d *Device) screen {
	if d.native == nil {
		return nil
	}
	return &nativeScreen{dev: d, host: d.native}
}

// nativeSession 是一次投屏对应的播放器实例。closing 用来区分"我们自己关的窗"
// 和"用户点了窗口红点"，后者要当成电视被关掉。
type nativeSession struct {
	p       *player.Player
	screen  *nativeScreen
	closing atomic.Bool
	ended   atomic.Bool
}

func (s *nativeSession) close() {
	s.closing.Store(true)
	s.p.Close()
}

type nativeScreen struct {
	dev  *Device
	host *nativeHost

	// 两个投屏指令几乎同时到达时（连点两次投屏），串行地开关窗口。
	showMu sync.Mutex

	mu  sync.Mutex
	cur *nativeSession
}

func (n *nativeScreen) Kind() string { return "native" }

func (n *nativeScreen) session() *nativeSession {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.cur
}

func (n *nativeScreen) Show(uri, title string, volume int, mute bool) {
	n.showMu.Lock()
	defer n.showMu.Unlock()

	// 连续投两个片时，上一个窗口可能还开着：先收掉再开新的。
	n.closeSession()

	res := make(chan error, 1)
	req := nativeOpenReq{
		opts: player.Options{
			URL:        uri,
			Title:      title,
			Fullscreen: true,
			Volume:     volume,
			Mute:       mute,
		},
		res: res,
		onNew: func(p *player.Player) {
			sess := &nativeSession{p: p, screen: n}
			n.mu.Lock()
			n.cur = sess
			n.mu.Unlock()
			n.attach(sess)
		},
	}
	if !n.host.requestOpen(req) {
		n.dev.logf("screen", "自研播放核心的主线程没在跑，改用 mpv")
		n.dev.fallbackFrom("native")
		return
	}

	var err error
	select {
	case err = <-res:
	case <-n.host.done:
		err = errNativeHostStopped
	}
	if err != nil {
		n.dev.logf("screen", "自研播放核心打不开（%v），回退 mpv", err)
		n.dev.fallbackFrom("native")
		return
	}

	sess := n.session()
	if sess == nil {
		n.dev.logf("screen", "自研播放核心没有留下播放器，回退 mpv")
		n.dev.fallbackFrom("native")
		return
	}
	st := sess.p.Status()
	if st.Duration > 0 {
		n.dev.setDuration(toDuration(st.Duration))
	}
	n.dev.logf("screen", "自研播放核心播放: %s（%s %dx%d@%dfps 硬解=%v 时长=%s）",
		title, sess.p.VideoCodec(), st.Width, st.Height, st.FPS, st.Hardware,
		formatTime(toDuration(st.Duration)))
}

// attach 在主线程上、Run 之前安装回调，保证从第一帧起状态就能回填。
func (n *nativeScreen) attach(sess *nativeSession) {
	sess.p.OnUpdate(func(st player.Status) {
		if st.Duration > 0 {
			n.dev.setDuration(toDuration(st.Duration))
		}
		if !st.Paused && !st.Ended {
			n.dev.syncPosition(toDuration(st.Position))
		}
		if st.Ended && !sess.ended.Swap(true) {
			n.dev.logf("screen", "播放到结尾（位置 %s）", formatTime(toDuration(st.Position)))
			n.dev.onPlaybackEnded()
		}
	})
	sess.p.OnClose(func() {
		if sess.closing.Load() {
			return
		}
		n.dev.logf("screen", "用户关闭了播放器窗口")
		n.dev.onScreenExit()
	})
}

func (n *nativeScreen) Play() {
	if s := n.session(); s != nil {
		s.p.Play()
	}
}

func (n *nativeScreen) Pause() {
	if s := n.session(); s != nil {
		s.p.Pause()
	}
}

func (n *nativeScreen) Stop() {
	if s := n.session(); s != nil {
		s.p.Stop()
	}
}

func (n *nativeScreen) Seek(d time.Duration) {
	if s := n.session(); s != nil {
		s.p.Seek(d.Seconds())
	}
}

func (n *nativeScreen) SetVolume(v int) {
	if s := n.session(); s != nil {
		s.p.SetVolume(v)
	}
}

func (n *nativeScreen) SetMute(m bool) {
	if s := n.session(); s != nil {
		s.p.SetMute(m)
	}
}

func (n *nativeScreen) Close() {
	n.closeSession()
}

func (n *nativeScreen) closeSession() {
	n.mu.Lock()
	s := n.cur
	n.cur = nil
	n.mu.Unlock()
	if s != nil {
		s.close()
	}
}

func toDuration(sec float64) time.Duration {
	if sec <= 0 {
		return 0
	}
	return time.Duration(sec * float64(time.Second))
}
