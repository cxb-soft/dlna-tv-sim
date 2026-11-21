//go:build windows

package main

import (
	"syscall"

	"golang.org/x/sys/windows"
)

func reuseAddrControl(network, address string, c syscall.RawConn) error {
	var serr error
	if err := c.Control(func(fd uintptr) {
		// Windows 的 SSDPSRV 已占用 1900，必须带 SO_REUSEADDR 才能共享。
		if err := windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_REUSEADDR, 1); err != nil {
			serr = err
			return
		}
		_ = windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_BROADCAST, 1)
	}); err != nil {
		return err
	}
	return serr
}
