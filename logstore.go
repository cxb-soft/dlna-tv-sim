package main

import (
	"fmt"
	"sync"
	"time"
)

// LogEntry 是给网页控制台看的一条事件流。
type LogEntry struct {
	ID   int64  `json:"id"`
	At   string `json:"at"`
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// EventLog 是一个固定容量的环形日志，兼做终端输出和网页轮询源。
type EventLog struct {
	mu      sync.Mutex
	entries []LogEntry
	nextID  int64
	max     int
}

func NewEventLog(max int) *EventLog {
	if max <= 0 {
		max = 300
	}
	return &EventLog{max: max}
}

func (l *EventLog) Add(kind, format string, args ...any) {
	text := fmt.Sprintf(format, args...)
	l.mu.Lock()
	l.nextID++
	e := LogEntry{
		ID:   l.nextID,
		At:   time.Now().Format("15:04:05"),
		Kind: kind,
		Text: text,
	}
	l.entries = append(l.entries, e)
	if len(l.entries) > l.max {
		l.entries = l.entries[len(l.entries)-l.max:]
	}
	l.mu.Unlock()
	fmt.Printf("%s  %-7s %s\n", e.At, kind, text)
}

func (l *EventLog) Since(id int64) []LogEntry {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]LogEntry, 0, 16)
	for _, e := range l.entries {
		if e.ID > id {
			out = append(out, e)
		}
	}
	return out
}
