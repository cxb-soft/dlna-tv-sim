package main

import (
	"time"
)

// 这几个方法是给播放引擎回调用用的：引擎把真实进度、时长、结束事件
// 回填到设备状态，这样 GetPositionInfo 和事件才是真的。

func (d *Device) setDuration(dur time.Duration) {
	d.mu.Lock()
	d.duration = dur
	d.mu.Unlock()
}

func (d *Device) syncPosition(pos time.Duration) {
	d.mu.Lock()
	if d.state == statePlaying {
		d.pos = pos
		d.posAt = time.Now()
	}
	d.mu.Unlock()
}

// startPlayback 由播放器在文件真正加载完成后调用，进入 PLAYING。
func (d *Device) startPlayback() {
	d.mu.Lock()
	changed := d.state == stateTransitioning
	if changed {
		d.state = statePlaying
		d.posAt = time.Now()
	}
	d.mu.Unlock()
	if changed {
		d.emit(serviceAVTransport)
	}
}

// applyPendingSeek 在文件加载完成后应用之前收到的 Seek。
func (d *Device) applyPendingSeek() {
	d.mu.Lock()
	if !d.hasPendingSeek {
		d.mu.Unlock()
		return
	}
	target := d.pendingSeek
	d.hasPendingSeek = false
	d.pos = target
	d.posAt = time.Now()
	scr := d.scr
	d.mu.Unlock()
	if scr != nil {
		scr.Seek(target)
	}
	d.logf("avt", "应用挂起 Seek → %s", formatTime(target))
}

// onPlaybackEnded：片子播完了，像电视一样回到 STOPPED，并把播放器窗口收掉。
func (d *Device) onPlaybackEnded() {
	d.mu.Lock()
	was := d.state == statePlaying || d.state == statePaused
	if was {
		d.state = stateStopped
		d.pos = 0
		d.posAt = time.Now()
	}
	d.mu.Unlock()
	if was {
		d.logf("avt", "播放结束")
		d.emit(serviceAVTransport)
		// Close 会等播放器进程退出，放到另一个 goroutine，避开引擎自己
		// 的回调栈（mpv 的读循环里不能阻塞等自己所控的进程）。
		go d.closeScreen()
	}
}

// fallbackFrom 在某个引擎起不来时换下一个：native → mpv → VLC → 网页。
func (d *Device) fallbackFrom(failed string) {
	d.mu.RLock()
	uri := d.uri
	title := mediaTitle(d.uriMeta, d.uri)
	d.mu.RUnlock()

	var next screen
	switch failed {
	case "native":
		// 自研核心打不开（坏地址、不支持的格式）时退到 mpv，行为与默认引擎一致。
		if p := findMPV(); p != "" {
			next = &mpvScreen{dev: d, path: p}
		} else if p := findVLC(); p != "" {
			next = &vlcScreen{dev: d, path: p}
		} else {
			next = &webScreen{dev: d}
		}
	case "mpv":
		if p := findVLC(); p != "" {
			next = &vlcScreen{dev: d, path: p}
		} else {
			next = &webScreen{dev: d}
		}
	case "vlc":
		next = &webScreen{dev: d}
	default:
		next = &webScreen{dev: d}
	}
	d.mu.Lock()
	d.scr = next
	d.mu.Unlock()
	d.logf("screen", "改用 %s 引擎", next.Kind())
	if uri != "" {
		next.Show(uri, title, d.volumeOf(), d.muteOf())
	}
}
