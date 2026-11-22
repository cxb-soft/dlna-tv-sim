package main

import (
	"bytes"
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

// lineLogWriter 把写入的字节按行拆开交给 log，避免 mpv 的多行错误
// 在事件日志里粘成一大块。只用于 mpv 的 stderr（已限定只输出 error）。
type lineLogWriter struct {
	mu  sync.Mutex
	buf []byte
	log func(string)
}

func (w *lineLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimSpace(string(w.buf[:i]))
		w.buf = w.buf[i+1:]
		if line != "" && w.log != nil {
			w.log(line)
		}
	}
	if len(w.buf) > 8192 {
		w.buf = w.buf[len(w.buf)-4096:]
	}
	return len(p), nil
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
