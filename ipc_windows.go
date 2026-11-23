//go:build windows

package main

import (
	"io"
	"os"
	"time"

	"golang.org/x/sys/windows"
)

// Windows 上 mpv 的 IPC 是命名管道，必须用重叠 I/O（FILE_FLAG_OVERLAPPED）打开。
//
// 普通 os.OpenFile 得到的是同步句柄，系统会把同一句柄上的 I/O 串行化：
// readLoop 挂着一个 ReadFile，每次 Write 都要等到 mpv 发来下一条事件才能写出去。
// 播放中 time-pos 一直在推，看不出问题；mpv 暂停、空闲或卡在取流时一条事件都不发，
// Play/Stop/loadfile 就会卡十几秒甚至更久（iPad 上表现为 SOAP 超时、下一集卡在旧画面）。
//
// 重叠句柄交给 Go 运行时的 IOCP（Go 1.26 起 OpenFile 接受 O_FILE_FLAG_OVERLAPPED），
// 读写各自独立、互不等待；Close 会用 CancelIoEx 打断挂着的读；还支持写超时。
func dialIPC(path string, timeout time.Duration) (io.ReadWriteCloser, error) {
	deadline := time.Now().Add(timeout)
	for {
		f, err := os.OpenFile(path, os.O_RDWR|windows.O_FILE_FLAG_OVERLAPPED, 0)
		if err == nil {
			return f, nil
		}
		if time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(50 * time.Millisecond)
	}
}
