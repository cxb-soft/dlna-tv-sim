package main

import (
	"strings"
	"sync"
)

// limitedBuffer 只保留前 limit 个字节，用来收集 VLC 的启动报错，
// 避免把它的长篇日志灌进内存。
type limitedBuffer struct {
	mu    sync.Mutex
	limit int
	buf   []byte
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.limit <= 0 {
		b.limit = 4096
	}
	remain := b.limit - len(b.buf)
	if remain > 0 {
		if len(p) > remain {
			b.buf = append(b.buf, p[:remain]...)
		} else {
			b.buf = append(b.buf, p...)
		}
	}
	return len(p), nil
}

func (b *limitedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}

// firstLine 取第一行有内容的话，给日志用。
func firstLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			return t
		}
	}
	return ""
}
