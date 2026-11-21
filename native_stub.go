//go:build !darwin || !cgo

package main

import "sync"

// 自研播放核心只有 macOS + cgo 实现。其它平台保留同构的 host，
// 让 main() 的启动/退出流程和 -player native 的降级逻辑保持一致。

func nativeAvailable() bool { return false }

type nativeHost struct {
	done chan struct{}
	once sync.Once
}

func newNativeHost() *nativeHost {
	return &nativeHost{done: make(chan struct{})}
}

func (h *nativeHost) Start() {}

// Run 在没有自研核心的平台上只负责等退出信号，占住主 goroutine。
func (h *nativeHost) Run() { <-h.done }

func (h *nativeHost) Shutdown() { h.once.Do(func() { close(h.done) }) }

// newNativeScreen 在这个平台上没有实现，调用方会退回 mpv/VLC/网页。
func newNativeScreen(*Device) screen { return nil }
