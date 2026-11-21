//go:build !windows

package main

import (
	"io"
	"net"
	"time"
)

func dialIPC(path string, timeout time.Duration) (io.ReadWriteCloser, error) {
	return net.DialTimeout("unix", path, timeout)
}
