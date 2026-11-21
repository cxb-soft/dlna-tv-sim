//go:build !windows

package main

import (
	"syscall"

	"golang.org/x/sys/unix"
)

// reuseAddrControl 让 SSDP 端口在"已经有人占用 1900"时仍能绑定，
// 这一点在 Windows 上尤其重要：那边的 SSDPSRV 服务常年占着 1900。
func reuseAddrControl(network, address string, c syscall.RawConn) error {
	var serr error
	if err := c.Control(func(fd uintptr) {
		if err := unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); err != nil {
			serr = err
			return
		}
		if err := unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEPORT, 1); err != nil {
			serr = err
			return
		}
		// 组播被拦时用广播通告作备用通道
		_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_BROADCAST, 1)
	}); err != nil {
		return err
	}
	return serr
}
