//go:build windows

package main

import (
	"io"
	"os"
	"time"
)

// Windows 上 mpv 的 IPC 是命名管道，用普通文件打开即可读写。
func dialIPC(path string, timeout time.Duration) (io.ReadWriteCloser, error) {
	deadline := time.Now().Add(timeout)
	for {
		f, err := os.OpenFile(path, os.O_RDWR, 0)
		if err == nil {
			return f, nil
		}
		if time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(50 * time.Millisecond)
	}
}
