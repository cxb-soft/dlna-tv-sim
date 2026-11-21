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
	playing := d.state == statePlaying || d.state == stateTransitioning
	if playing {
		d.pos = pos
		d.posAt = time.Now()
	}
	d.mu.Unlock()
}

// onPlaybackEnded：片子播完了，像电视一样回到 STOPPED。
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
	}
}

// fallbackFrom 在某个引擎起不来时换下一个：mpv → VLC → 网页。
func (d *Device) fallbackFrom(failed string) {
	d.mu.RLock()
	uri := d.uri
	title := mediaTitle(d.uriMeta, d.uri)
	d.mu.RUnlock()

	var next screen
	switch failed {
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
