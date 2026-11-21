package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// GENA（事件订阅）是 DLNA 里最容易被做残的一块：控制点 SUBSCRIBE 之后，
// 渲染器要立刻推一次全量状态，之后每次变化推一条带 SEQ 序号的 NOTIFY。
// 少这一步，很多手机投屏 App 会一直显示"正在连接"。

type Subscriptions struct {
	dev  *Device
	mu   sync.Mutex
	subs map[string]*subscription
}

type subscription struct {
	mu        sync.Mutex
	owner     *Device
	sid       string
	service   string
	callbacks []string
	seq       uint32
	timeout   time.Duration
	expires   time.Time
	lastSent  map[string]string
	queue     chan map[string]string
	done      chan struct{}
	closed    bool
}

func newSubscriptions(d *Device) *Subscriptions {
	s := &Subscriptions{dev: d, subs: make(map[string]*subscription)}
	go s.sweeper()
	return s
}

func (s *Subscriptions) Subscribe(service string, callbacks []string, timeout time.Duration) *subscription {
	if timeout <= 0 {
		timeout = 30 * time.Minute
	}
	sub := &subscription{
		owner:     s.dev,
		sid:       "uuid:" + newUUID(),
		service:   service,
		callbacks: callbacks,
		timeout:   timeout,
		expires:   time.Now().Add(timeout),
		lastSent:  map[string]string{},
		queue:     make(chan map[string]string, 8),
		done:      make(chan struct{}),
	}
	s.mu.Lock()
	s.subs[sub.sid] = sub
	s.mu.Unlock()
	go sub.worker()
	// 订阅成功后立刻推一次全量状态（SEQ=0）
	sub.push(s.dev.eventedVars(service))
	return sub
}

func (s *Subscriptions) Renew(sid string, timeout time.Duration) *subscription {
	s.mu.Lock()
	sub := s.subs[sid]
	s.mu.Unlock()
	if sub == nil {
		return nil
	}
	if timeout <= 0 {
		timeout = sub.timeout
	}
	sub.mu.Lock()
	sub.timeout = timeout
	sub.expires = time.Now().Add(timeout)
	sub.mu.Unlock()
	return sub
}

func (s *Subscriptions) Unsubscribe(sid string) bool {
	s.mu.Lock()
	sub := s.subs[sid]
	delete(s.subs, sid)
	s.mu.Unlock()
	if sub == nil {
		return false
	}
	sub.close()
	return true
}

func (s *Subscriptions) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.subs)
}

// notify 把最新变量分发给所有相关订阅；实际发送在各订阅自己的队列里做，
// 这样慢的控制点不会拖住 SOAP 响应。
func (s *Subscriptions) notify(service string, vars map[string]string) {
	s.mu.Lock()
	list := make([]*subscription, 0, 4)
	for _, sub := range s.subs {
		if sub.service == service {
			list = append(list, sub)
		}
	}
	s.mu.Unlock()
	for _, sub := range list {
		sub.push(vars)
	}
}

func (s *Subscriptions) sweeper() {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for range t.C {
		now := time.Now()
		var expired []*subscription
		s.mu.Lock()
		for sid, sub := range s.subs {
			sub.mu.Lock()
			dead := now.After(sub.expires)
			sub.mu.Unlock()
			if dead {
				expired = append(expired, sub)
				delete(s.subs, sid)
			}
		}
		s.mu.Unlock()
		for _, sub := range expired {
			sub.close()
		}
	}
}

func (s *Subscriptions) closeAll() {
	s.mu.Lock()
	all := make([]*subscription, 0, len(s.subs))
	for _, sub := range s.subs {
		all = append(all, sub)
	}
	s.subs = map[string]*subscription{}
	s.mu.Unlock()
	for _, sub := range all {
		sub.close()
	}
}

func (sub *subscription) close() {
	sub.mu.Lock()
	if !sub.closed {
		sub.closed = true
		close(sub.done)
	}
	sub.mu.Unlock()
}

func (sub *subscription) push(vars map[string]string) {
	sub.mu.Lock()
	if sub.closed {
		sub.mu.Unlock()
		return
	}
	select {
	case sub.queue <- vars:
	default:
		// 队列堵住了就以最新状态为准
		select {
		case <-sub.queue:
		default:
		}
		select {
		case sub.queue <- vars:
		default:
		}
	}
	sub.mu.Unlock()
}

func (sub *subscription) worker() {
	for {
		select {
		case <-sub.done:
			return
		case vars := <-sub.queue:
			sub.mu.Lock()
			changed := make(map[string]string, len(vars))
			for k, v := range vars {
				if old, ok := sub.lastSent[k]; !ok || old != v {
					changed[k] = v
				}
			}
			if len(changed) == 0 {
				sub.mu.Unlock()
				continue
			}
			for k, v := range changed {
				sub.lastSent[k] = v
			}
			seq := sub.seq
			sub.seq++
			cbs := append([]string(nil), sub.callbacks...)
			sid := sub.sid
			service := sub.service
			sub.mu.Unlock()

			body := propertyset(buildLastChange(service, changed))
			if err := deliver(cbs, sid, seq, body); err != nil {
				sub.devLog("事件推送失败 %s: %v", sid, err)
			}
		}
	}
}

func (sub *subscription) devLog(format string, args ...any) {
	// 只记到设备日志里，避免刷屏
	dev := sub.owner
	if dev != nil {
		dev.logf("gena", format, args...)
	}
}

// deliver 按顺序尝试回调地址，任意一个成功就算送达。
func deliver(callbacks []string, sid string, seq uint32, body string) error {
	client := &http.Client{
		Timeout: 5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	var lastErr error
	for _, cb := range callbacks {
		req, err := http.NewRequest("NOTIFY", cb, strings.NewReader(body))
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
		req.Header.Set("NT", "upnp:event")
		req.Header.Set("NTS", "upnp:propchange")
		req.Header.Set("SID", sid)
		req.Header.Set("SEQ", strconv.FormatUint(uint64(seq), 10))
		req.Header.Set("Connection", "close")
		req.Header.Set("User-Agent", serverString)
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return nil
		}
		lastErr = fmt.Errorf("回调返回 %s", resp.Status)
	}
	return lastErr
}

// buildLastChange 拼出 Event 里的状态桶。AVTransport 用 AVT 命名空间，
// RenderingControl 用 RCS，并且每个变量要带 Channel="Master"。
func buildLastChange(service string, vars map[string]string) string {
	ns := "urn:schemas-upnp-org:metadata-1-0/AVT/"
	channel := ""
	if service == serviceRenderingControl {
		ns = "urn:schemas-upnp-org:metadata-1-0/RCS/"
		channel = "Master"
	}
	keys := make([]string, 0, len(vars))
	for k := range vars {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var b strings.Builder
	b.WriteString(`<Event xmlns="` + ns + `"><InstanceID val="0">`)
	for _, k := range keys {
		if channel != "" && k != "PresetNameList" {
			fmt.Fprintf(&b, `<%s channel="%s" val="%s"/>`, k, channel, xmlEscape(vars[k]))
		} else {
			fmt.Fprintf(&b, `<%s val="%s"/>`, k, xmlEscape(vars[k]))
		}
	}
	b.WriteString(`</InstanceID></Event>`)
	return b.String()
}

func propertyset(event string) string {
	var b bytes.Buffer
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	b.WriteString(`<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><LastChange>`)
	b.WriteString(xmlEscape(event))
	b.WriteString(`</LastChange></e:property></e:propertyset>`)
	return b.String()
}

func xmlEscape(s string) string {
	var b bytes.Buffer
	xml.EscapeText(&b, []byte(s))
	return b.String()
}

// ---------- HTTP 侧的 SUBSCRIBE / UNSUBSCRIBE ----------

var reCallback = regexp.MustCompile(`<([^>]+)>`)

func parseTimeout(v string) time.Duration {
	v = strings.TrimSpace(v)
	if v == "" || strings.EqualFold(v, "infinite") || strings.HasPrefix(strings.ToLower(v), "second-infinite") {
		return 30 * time.Minute
	}
	low := strings.ToLower(v)
	if strings.HasPrefix(low, "second-") {
		if n, err := strconv.Atoi(strings.TrimPrefix(low, "second-")); err == nil && n > 0 {
			if n > 24*3600 {
				n = 24 * 3600
			}
			return time.Duration(n) * time.Second
		}
	}
	return 30 * time.Minute
}

func parseCallbacks(v string) []string {
	var out []string
	for _, m := range reCallback.FindAllStringSubmatch(v, -1) {
		u := strings.TrimSpace(m[1])
		if strings.HasPrefix(u, "http://") {
			out = append(out, u)
		}
	}
	return out
}

func (d *Device) handleGENA(service string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sid := strings.TrimSpace(r.Header.Get("SID"))
		switch r.Method {
		case "SUBSCRIBE":
			timeout := parseTimeout(r.Header.Get("TIMEOUT"))
			if sid != "" {
				// 续订：只能带 SID 和 TIMEOUT
				if r.Header.Get("CALLBACK") != "" || r.Header.Get("NT") != "" {
					http.Error(w, "invalid subscription", http.StatusBadRequest)
					return
				}
				sub := d.subs.Renew(sid, timeout)
				if sub == nil {
					http.Error(w, "unknown SID", http.StatusPreconditionFailed)
					return
				}
				w.Header().Set("SID", sub.sid)
				w.Header().Set("TIMEOUT", "Second-"+strconv.Itoa(int(timeout.Seconds())))
				w.WriteHeader(http.StatusOK)
				d.logf("gena", "续订 %s（%s）", service, sub.sid)
				return
			}
			nt := strings.TrimSpace(r.Header.Get("NT"))
			if !strings.EqualFold(nt, "upnp:event") {
				http.Error(w, "invalid NT", http.StatusPreconditionFailed)
				return
			}
			cbs := parseCallbacks(r.Header.Get("CALLBACK"))
			if len(cbs) == 0 {
				http.Error(w, "invalid CALLBACK", http.StatusPreconditionFailed)
				return
			}
			sub := d.subs.Subscribe(service, cbs, timeout)
			w.Header().Set("SID", sub.sid)
			w.Header().Set("TIMEOUT", "Second-"+strconv.Itoa(int(timeout.Seconds())))
			w.Header().Set("Content-Length", "0")
			w.WriteHeader(http.StatusOK)
			d.logf("gena", "%s 新订阅 %s → %s", service, sub.sid, strings.Join(cbs, ","))
		case "UNSUBSCRIBE":
			if sid == "" {
				http.Error(w, "missing SID", http.StatusBadRequest)
				return
			}
			if !d.subs.Unsubscribe(sid) {
				http.Error(w, "unknown SID", http.StatusPreconditionFailed)
				return
			}
			w.WriteHeader(http.StatusOK)
			d.logf("gena", "%s 取消订阅 %s", service, sid)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}
