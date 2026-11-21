package main

import (
	"strings"
)

// newScreen 选播放引擎：mpv 最稳，其次 VLC，最后是浏览器内播放。
// -player native 用自研播放核心（macOS 进程内），失败时回退 mpv。
func (d *Device) newScreen() screen {
	switch strings.ToLower(strings.TrimSpace(d.cfg.Player)) {
	case "web":
		return &webScreen{dev: d}
	case "native":
		if s := newNativeScreen(d); s != nil {
			return s
		}
		d.logf("screen", "这个平台没有自研播放核心，改用 mpv")
		if p := findMPV(); p != "" {
			return &mpvScreen{dev: d, path: p}
		}
		if p := findVLC(); p != "" {
			return &vlcScreen{dev: d, path: p}
		}
		return &webScreen{dev: d}
	case "vlc":
		if p := findVLC(); p != "" {
			return &vlcScreen{dev: d, path: p}
		}
		d.logf("screen", "配置要求 VLC，但没找到，改用网页播放器")
		return &webScreen{dev: d}
	case "mpv":
		if p := findMPV(); p != "" {
			return &mpvScreen{dev: d, path: p}
		}
		d.logf("screen", "配置要求 mpv，但没找到，改用网页播放器")
		return &webScreen{dev: d}
	}
	if p := findMPV(); p != "" {
		return &mpvScreen{dev: d, path: p}
	}
	if p := findVLC(); p != "" {
		return &vlcScreen{dev: d, path: p}
	}
	d.logf("screen", "没找到 mpv/VLC，用网页播放器兜底")
	return &webScreen{dev: d}
}
