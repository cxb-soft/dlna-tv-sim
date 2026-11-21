package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// Listen 起 HTTP 服务：设备描述、SCPD、控制点、事件订阅、图标、网页控制台全在这里。
func (d *Device) Listen() error {
	addr := fmt.Sprintf(":%d", d.cfg.HTTPPort)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("HTTP 端口 %d 被占用: %w", d.cfg.HTTPPort, err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	d.mu.Lock()
	d.httpPort = port
	d.mu.Unlock()

	srv := &http.Server{
		Handler:           d.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	d.srv = srv
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			d.logf("http", "HTTP 服务退出: %v", err)
		}
	}()
	d.logf("http", "HTTP 服务已就绪，端口 %d", port)
	return nil
}

func (d *Device) Close() {
	d.subs.closeAll()
	d.mu.Lock()
	scr := d.scr
	d.mu.Unlock()
	if scr != nil {
		scr.Close()
	}
	if d.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = d.srv.Shutdown(ctx)
	}
}

func (d *Device) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", d.handleUI)
	mux.HandleFunc("/screen", d.handleScreenPage)
	mux.HandleFunc("/hls.min.js", d.handleHLSJS)
	mux.HandleFunc("/dmr.xml", d.handleDescription)
	mux.HandleFunc("/description.xml", d.handleDescription)
	for _, svc := range []string{serviceAVTransport, serviceRenderingControl, serviceConnectionManager} {
		mux.HandleFunc("/"+svc+"/scpd.xml", d.handleSCPD(svc))
		mux.HandleFunc("/"+svc+"/control", d.handleControl(svc))
		mux.HandleFunc("/"+svc+"/event", d.handleGENA(svc))
	}
	mux.HandleFunc("/icon-48.png", d.handleIcon(48))
	mux.HandleFunc("/icon-120.png", d.handleIcon(120))
	mux.HandleFunc("/api/state", d.handleStateAPI)
	mux.HandleFunc("/api/log", d.handleLogAPI)
	mux.HandleFunc("/api/cast", d.handleCastAPI)
	mux.HandleFunc("/api/control", d.handleControlAPI)
	mux.HandleFunc("/api/player", d.handlePlayerAPI)
	mux.HandleFunc("/api/report", d.handleReportAPI)
	mux.HandleFunc("/api/screenshot", d.handleScreenshotAPI)
	mux.HandleFunc("/api/config", d.handleConfigAPI)
	mux.HandleFunc("/api/diag", d.handleDiagAPI)
	mux.HandleFunc("/proxy", d.handleProxy)
	return mux
}

// ---------- 设备描述 ----------

func (d *Device) handleDescription(w http.ResponseWriter, r *http.Request) {
	host := r.Host
	if host == "" {
		host = fmt.Sprintf("%s:%d", fallbackIP(), d.httpPort)
	}
	w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(d.descriptionXML("http://" + host))
}

func (d *Device) descriptionXML(base string) []byte {
	cfg := d.cfg
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	b.WriteString(`<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">`)
	b.WriteString(`<specVersion><major>1</major><minor>0</minor></specVersion>`)
	b.WriteString(`<device>`)
	write := func(tag, val string) {
		b.WriteString("<" + tag + ">" + xmlEscape(val) + "</" + tag + ">")
	}
	write("deviceType", "urn:schemas-upnp-org:device:MediaRenderer:1")
	write("friendlyName", cfg.FriendlyName)
	write("manufacturer", cfg.Manufacturer)
	write("manufacturerURL", "https://friend.local/")
	write("modelDescription", "DLNA Digital Media Renderer")
	write("modelName", cfg.ModelName)
	write("modelNumber", cfg.ModelNumber)
	write("modelURL", "https://friend.local/")
	write("serialNumber", cfg.SerialNumber)
	write("UDN", "uuid:"+cfg.UUID)
	b.WriteString(`<dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>`)
	b.WriteString(`<dlna:X_DLNACAP></dlna:X_DLNACAP>`)
	b.WriteString(`<iconList>`)
	for _, sz := range []int{48, 120} {
		b.WriteString(`<icon><mimetype>image/png</mimetype><width>` + strconv.Itoa(sz) +
			`</width><height>` + strconv.Itoa(sz) + `</height><depth>24</depth><url>/icon-` +
			strconv.Itoa(sz) + `.png</url></icon>`)
	}
	b.WriteString(`</iconList>`)
	b.WriteString(`<serviceList>`)
	for _, svc := range []string{serviceAVTransport, serviceRenderingControl, serviceConnectionManager} {
		b.WriteString(`<service>`)
		write("serviceType", d.serviceType(svc))
		id := "urn:upnp-org:serviceId:" + svc
		write("serviceId", id)
		write("SCPDURL", "/"+svc+"/scpd.xml")
		write("controlURL", "/"+svc+"/control")
		write("eventSubURL", "/"+svc+"/event")
		b.WriteString(`</service>`)
	}
	b.WriteString(`</serviceList>`)
	write("presentationURL", base+"/")
	b.WriteString(`</device></root>`)
	return []byte(b.String())
}

func (d *Device) handleSCPD(service string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
		w.Header().Set("Cache-Control", "no-cache")
		io.WriteString(w, scpdFor(service))
	}
}

// ---------- 控制（SOAP） ----------

func (d *Device) handleControl(service string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Only POST is allowed", http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "read body failed", http.StatusBadRequest)
			return
		}
		atomic.AddInt64(&d.soapCount, 1)
		sa := strings.Trim(strings.TrimSpace(r.Header.Get("SOAPACTION")), `"`)
		req, err := parseSOAP(body, sa)
		if err != nil {
			d.logf("soap", "%s 请求解析失败: %v", service, err)
			w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
			w.WriteHeader(http.StatusInternalServerError)
			w.Write(soapFault(401, "Invalid Action"))
			return
		}
		out, uerr := d.dispatch(service, req.Action, req.Args)
		if uerr != nil {
			d.logf("soap", "%s#%s → %d %s", service, req.Action, uerr.Code, uerr.Desc)
			w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
			w.WriteHeader(http.StatusInternalServerError)
			w.Write(soapFault(uerr.Code, uerr.Desc))
			return
		}
		d.logf("soap", "%s#%s 成功", service, req.Action)
		w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
		w.Write(soapResponse(req.Action, d.serviceType(service), out))
	}
}

// ---------- 网页控制台 API ----------

func (d *Device) handleStateAPI(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, d.Snapshot())
}

func (d *Device) handleLogAPI(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	writeJSON(w, map[string]any{"entries": d.log.Since(since)})
}

func (d *Device) handleCastAPI(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		URL      string `json:"url"`
		Metadata string `json:"metadata"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	body.URL = strings.TrimSpace(body.URL)
	if body.URL == "" {
		http.Error(w, "url 不能为空", http.StatusBadRequest)
		return
	}
	d.logf("ui", "网页投屏: %s", body.URL)
	if e := d.Cast(body.URL, body.Metadata); e != nil {
		writeJSONStatus(w, http.StatusConflict, map[string]any{"error": e.Desc, "code": e.Code})
		return
	}
	writeJSON(w, d.Snapshot())
}

func (d *Device) handleControlAPI(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Action string  `json:"action"`
		Value  float64 `json:"value"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	var uerr *upnpError
	switch strings.ToLower(body.Action) {
	case "play":
		uerr = d.Play()
	case "pause":
		uerr = d.Pause()
	case "stop":
		uerr = d.Stop()
	case "seek":
		uerr = d.Seek(time.Duration(body.Value * float64(time.Second)))
	case "volume":
		uerr = d.SetVolume(int(body.Value))
	case "mute":
		d.SetMute(body.Value != 0)
	case "clear":
		d.SetURI("", "")
	default:
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}
	if uerr != nil {
		writeJSONStatus(w, http.StatusConflict, map[string]any{"error": uerr.Desc, "code": uerr.Code})
		return
	}
	writeJSON(w, d.Snapshot())
}

func (d *Device) handlePlayerAPI(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, d.PlayerState())
		return
	case http.MethodPost:
	default:
		http.Error(w, "GET or POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Action string  `json:"action"`
		Value  float64 `json:"value"`
		Text   string  `json:"text"`
		Kind   string  `json:"kind"`
		ID     int     `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	var uerr *upnpError
	switch strings.ToLower(body.Action) {
	case "speed":
		uerr = d.SetSpeed(body.Value)
	case "loop":
		uerr = d.SetLoop(body.Value != 0)
	case "aspect":
		uerr = d.SetAspect(body.Text)
	case "track":
		uerr = d.SelectTrack(body.Kind, body.ID)
	case "screenshot":
		_, uerr = d.Screenshot()
	case "seekrel":
		// 相对跳转，单位秒；负值后退
		d.mu.RLock()
		pos := d.positionLocked()
		d.mu.RUnlock()
		target := pos + time.Duration(body.Value*float64(time.Second))
		if target < 0 {
			target = 0
		}
		uerr = d.Seek(target)
	default:
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}
	if uerr != nil {
		writeJSONStatus(w, http.StatusConflict, map[string]any{"error": uerr.Desc, "code": uerr.Code})
		return
	}
	writeJSON(w, d.PlayerState())
}

// handleReportAPI 收网页播放器上报的播放信息（目前只有时长）。
func (d *Device) handleReportAPI(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Duration float64 `json:"duration"`
		Ended    bool    `json:"ended"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if body.Ended {
		d.onPlaybackEnded()
	}
	if body.Duration > 0 && body.Duration < 24*3600 {
		d.ReportDuration(time.Duration(body.Duration * float64(time.Second)))
	}
	writeJSON(w, map[string]any{"ok": true})
}

// handleScreenshotAPI 返回最近一次截图；mpv 写文件是异步的，这里等一小会儿。
func (d *Device) handleScreenshotAPI(w http.ResponseWriter, r *http.Request) {
	path := d.lastScreenshot()
	if path == "" {
		http.Error(w, "还没有截图", http.StatusNotFound)
		return
	}
	var err error
	for i := 0; i < 20; i++ {
		var fi os.FileInfo
		if fi, err = os.Stat(path); err == nil && fi.Size() > 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		http.Error(w, "截图文件还没就绪", http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.ServeFile(w, r, path)
}

func (d *Device) handleConfigAPI(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		FriendlyName string `json:"friendly_name"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(body.FriendlyName)
	if name == "" {
		http.Error(w, "friendly_name 不能为空", http.StatusBadRequest)
		return
	}
	if len([]rune(name)) > 64 {
		http.Error(w, "名字太长", http.StatusBadRequest)
		return
	}
	d.mu.Lock()
	d.cfg.FriendlyName = name
	cfg := d.cfg
	d.mu.Unlock()
	if err := cfg.save(d.cfgPath); err != nil {
		d.logf("config", "保存配置失败: %v", err)
	}
	d.logf("config", "设备名改为 %s（重新广播后生效）", name)
	writeJSON(w, d.Snapshot())
}

func (d *Device) handleDiagAPI(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, d.Diag())
}

func writeJSON(w http.ResponseWriter, v any) {
	writeJSONStatus(w, http.StatusOK, v)
}

func writeJSONStatus(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

// ---------- 媒体代理：网页兜底播放时绕开跨域/防盗链 ----------

const browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

func (d *Device) handleProxy(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("url")
	if raw == "" {
		http.Error(w, "missing url", http.StatusBadRequest)
		return
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		http.Error(w, "bad url", http.StatusBadRequest)
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, raw, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	req.Header.Set("User-Agent", browserUA)
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Referer", u.Scheme+"://"+u.Host+"/")
	if rg := r.Header.Get("Range"); rg != "" {
		req.Header.Set("Range", rg)
	}
	resp, err := d.streamClient.Do(req)
	if err != nil {
		d.logf("proxy", "拉取失败 %s: %v", raw, err)
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")

	ctype := strings.ToLower(resp.Header.Get("Content-Type"))
	isPlaylist := strings.Contains(ctype, "mpegurl") || strings.HasSuffix(strings.ToLower(u.Path), ".m3u8")
	if isPlaylist {
		data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		if err != nil {
			http.Error(w, "read playlist failed", http.StatusBadGateway)
			return
		}
		out := rewritePlaylist(data, resp.Request.URL)
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Content-Length", strconv.Itoa(len(out)))
		w.WriteHeader(resp.StatusCode)
		w.Write(out)
		return
	}

	for _, h := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// rewritePlaylist 把 m3u8 里的分片/密钥地址改写成走本地代理，
// 否则浏览器会直接去请求远端 CDN，跨域或防盗链就断了。
func rewritePlaylist(data []byte, base *url.URL) []byte {
	lines := strings.Split(string(data), "\n")
	var b strings.Builder
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == "":
			b.WriteString("\n")
		case strings.HasPrefix(trimmed, "#"):
			b.WriteString(rewriteURIAttrs(line, base))
			b.WriteString("\n")
		default:
			b.WriteString(proxyURLFor(base, trimmed))
			b.WriteString("\n")
		}
	}
	return []byte(b.String())
}

func rewriteURIAttrs(line string, base *url.URL) string {
	const marker = `URI="`
	var out strings.Builder
	rest := line
	for {
		i := strings.Index(rest, marker)
		if i < 0 {
			out.WriteString(rest)
			break
		}
		out.WriteString(rest[:i+len(marker)])
		rest = rest[i+len(marker):]
		j := strings.Index(rest, `"`)
		if j < 0 {
			out.WriteString(rest)
			break
		}
		uri := rest[:j]
		out.WriteString(proxyURLFor(base, uri))
		out.WriteString(`"`)
		rest = rest[j+1:]
	}
	return out.String()
}

func proxyURLFor(base *url.URL, raw string) string {
	abs := raw
	if base != nil {
		if ref, err := url.Parse(raw); err == nil {
			abs = base.ResolveReference(ref).String()
		}
	}
	return "/proxy?url=" + url.QueryEscape(abs)
}
