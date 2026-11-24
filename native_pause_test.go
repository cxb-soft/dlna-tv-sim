//go:build darwin && cgo

package main

import (
	"testing"
	"time"

	"dlnatvsim/player"
)

// TestNativeStatusRenderingSync 固住自研核心的音量/静音/倍速/循环回写：
// 自绘控件和快捷键调音、在窗口里切换倍速都不会发 SOAP，
// 只有 120ms 的 Status 轮询能把这些变化告诉 DLNA。
// 不回写的话远程遥控器上显示的音量和倍速都是旧值。
func TestNativeStatusRenderingSync(t *testing.T) {
	dev := newTestDevice(t)
	dev.mu.Lock()
	dev.state = statePlaying
	dev.volume = 30
	dev.speed = 1
	dev.mu.Unlock()

	scr := &nativeScreen{dev: dev}
	sess := &nativeSession{screen: scr}

	// 窗口里把音量拉到 66、静音，同时倍速改成 1.5x、开循环。
	scr.onPlayerStatus(player.Status{
		Paused: false, Ended: false, Closed: false,
		Position: 10, Duration: 120,
		Volume: 66, Muted: true, Speed: 1.5, Loop: true,
	}, sess)

	s := dev.Snapshot()
	if s.Volume != 66 {
		t.Errorf("音量应回写为 66，实际 %d", s.Volume)
	}
	if !s.Mute {
		t.Errorf("静音应回写为 true")
	}
	if s.Speed != 1.5 {
		t.Errorf("倍速应回写为 1.5，实际 %v", s.Speed)
	}
	if !s.Loop {
		t.Errorf("循环应回写为 true")
	}

	// 已结束/已关闭的窗口不该再改音量，避免关窗时把音量写成 0。
	scr.onPlayerStatus(player.Status{
		Ended: true, Position: 120, Duration: 120,
		Volume: 0, Muted: false, Speed: 1,
	}, sess)
	if got := dev.Snapshot().Volume; got != 66 {
		t.Errorf("播完后的回调不应改音量，实际 %d", got)
	}
}

// TestNativeStatusPauseSync 固住自研核心的上报路径：
// 播放器窗口里按空格暂停时，自研核心只会在 Status().Paused 里体现，
// 必须经 onPlayerStatus 回写到设备状态，否则 DLNA 侧一直报 PLAYING，
// 而 positionLocked 会按 pos+since(posAt) 继续算，控制点看到的进度一路往前走。
func TestNativeStatusPauseSync(t *testing.T) {
	dev := newTestDevice(t)
	dev.mu.Lock()
	dev.state = statePlaying
	dev.pos = 20 * time.Second
	dev.posAt = time.Now()
	dev.mu.Unlock()

	scr := &nativeScreen{dev: dev}
	sess := &nativeSession{screen: scr}

	// 自研核心报暂停（用户在窗口里按了空格）。
	scr.onPlayerStatus(player.Status{Paused: true, Position: 20, Duration: 120}, sess)
	if st := dev.Snapshot().State; st != statePaused {
		t.Fatalf("自研核心暂停后应为 %s，实际 %s", statePaused, st)
	}
	frozen := dev.Position()
	time.Sleep(700 * time.Millisecond)
	if moved := dev.Position(); moved != frozen {
		t.Errorf("自研核心暂停后位置应冻结，实际 %v → %v", frozen, moved)
	}

	// 从暂停恢复（pe_play）→ 状态回 PLAYING，位置继续走。
	scr.onPlayerStatus(player.Status{Paused: false, Position: 20, Duration: 120}, sess)
	if st := dev.Snapshot().State; st != statePlaying {
		t.Fatalf("自研核心继续后应为 %s，实际 %s", statePlaying, st)
	}
	time.Sleep(600 * time.Millisecond)
	if moved := dev.Position(); moved <= frozen {
		t.Errorf("继续后位置应重新前进，实际 %v（暂停时 %v）", moved, frozen)
	}

	// 播完就交给 onPlaybackEnded，不能被当成 PAUSED。
	scr.onPlayerStatus(player.Status{Ended: true, Position: 120, Duration: 120}, sess)
	if st := dev.Snapshot().State; st != stateStopped {
		t.Errorf("播完后应为 %s，实际 %s", stateStopped, st)
	}
}
