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

// syncPaused 把播放器自身的暂停状态回填到设备状态。
// 用户直接在播放器窗口里按暂停时，控制点不会发任何 SOAP 请求，只有引擎知道这件事；
// 不回写的话 DLNA 侧会一直报 PLAYING，而且 positionLocked 会按 pos+since(posAt) 继续算，
// 控制点看到的进度就一直往前走，跟画面完全对不上。
func (d *Device) syncPaused(paused bool) {
	d.mu.Lock()
	changed := false
	switch {
	case paused && d.state == statePlaying:
		// 先按播放态算出当前位置再冻结，否则冻结后 pos 会丢掉这一段。
		d.pos = d.positionLocked()
		d.posAt = time.Now()
		d.state = statePaused
		changed = true
	case !paused && d.state == statePaused:
		d.state = statePlaying
		d.posAt = time.Now()
		changed = true
	}
	d.mu.Unlock()
	if changed {
		if paused {
			d.logf("screen", "播放器暂停，同步为 PAUSED_PLAYBACK")
		} else {
			d.logf("screen", "播放器继续，同步为 PLAYING")
		}
		d.emit(serviceAVTransport)
	}
}

// syncRendering 把播放器侧的音量/静音变化回写到设备，并推事件给控制点。
// 和暂停一样：用户在播放器窗口（或键盘）里调音时，控制点不会发 SOAP，
// 不回写的话远程遥控器上显示的还是旧值，两边完全对不上。
// 自己发起的 SetVolume 也会回到这里，值没变时直接返回，不会造成事件风暴。
func (d *Device) syncRendering(volume int, mute bool) {
	if volume < 0 {
		volume = 0
	}
	if volume > 100 {
		volume = 100
	}
	d.mu.Lock()
	changed := d.volume != volume || d.mute != mute
	if changed {
		d.volume, d.mute = volume, mute
	}
	d.mu.Unlock()
	if !changed {
		return
	}
	d.logf("rcs", "播放器调音，同步音量 %d 静音 %v", volume, mute)
	d.emit(serviceRenderingControl)
}

// reenterSelected 把设备放回“加载中”，让播放器加载完成后的 startPlayback 能重新推到 PLAYING。
// 用于播放引擎崩溃后自动重拉：崩溃不是用户关窗，不能走 onScreenExit 把状态打成
// STOPPED 并把位置归零，否则重新拉起来的窗口再也推不回 PLAYING，控制点看到的还是停着。
func (d *Device) reenterSelected(pos time.Duration) {
	d.mu.Lock()
	if d.uri == "" {
		d.mu.Unlock()
		return
	}
	d.state = stateTransitioning
	d.pos = pos
	d.posAt = time.Now()
	d.hasPendingSeek = false
	d.mu.Unlock()
	d.logf("avt", "播放器重启，从 %s 重新加载", formatTime(pos))
	d.emit(serviceAVTransport)
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
