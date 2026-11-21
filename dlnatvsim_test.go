package main

import (
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---------- 工具 ----------

func newTestDevice(t *testing.T) *Device {
	t.Helper()
	cfg := DefaultConfig()
	cfg.FriendlyName = "测试电视"
	cfg.HTTPPort = 0
	cfg.Player = "web"
	dev := NewDevice(cfg, filepath.Join(t.TempDir(), "config.json"), false)
	if err := dev.Listen(); err != nil {
		t.Fatalf("启动 HTTP 失败: %v", err)
	}
	t.Cleanup(dev.Close)
	return dev
}

func (d *Device) testBase() string {
	return fmt.Sprintf("http://127.0.0.1:%d", d.httpPort)
}

func getBody(t *testing.T, url string) (int, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读响应: %v", err)
	}
	return resp.StatusCode, string(body)
}

// soapCall 完全按控制点的方式发 SOAP 请求，返回状态码和响应体。
func soapCall(t *testing.T, base, svc, action string, args map[string]string, wantStatus int) string {
	t.Helper()
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>`)
	b.WriteString(`<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`)
	b.WriteString(`<u:` + action + ` xmlns:u="urn:schemas-upnp-org:service:` + svc + `:1">`)
	for k, v := range args {
		b.WriteString("<" + k + ">" + xmlEscape(v) + "</" + k + ">")
	}
	b.WriteString(`</u:` + action + `></s:Body></s:Envelope>`)

	req, err := http.NewRequest(http.MethodPost, base+"/"+svc+"/control", strings.NewReader(b.String()))
	if err != nil {
		t.Fatalf("构造请求: %v", err)
	}
	req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	req.Header.Set("SOAPACTION", `"urn:schemas-upnp-org:service:`+svc+`:1#`+action+`"`)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", action, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != wantStatus {
		t.Fatalf("%s 期望状态 %d，实际 %d：%s", action, wantStatus, resp.StatusCode, string(body))
	}
	return string(body)
}

// soapOut 从响应里取出指定出参的值。
func soapOut(t *testing.T, body, name string) string {
	t.Helper()
	var env struct {
		Body struct {
			Inner []byte `xml:",innerxml"`
		} `xml:"Body"`
	}
	if err := xml.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("解析 SOAP 响应失败: %v\n%s", err, body)
	}
	var holder struct {
		XMLName  xml.Name
		Children []struct {
			XMLName xml.Name
			Value   string `xml:",chardata"`
		} `xml:",any"`
	}
	if err := xml.Unmarshal(env.Body.Inner, &holder); err != nil {
		t.Fatalf("解析动作元素失败: %v", err)
	}
	for _, c := range holder.Children {
		if c.XMLName.Local == name {
			return c.Value
		}
	}
	return ""
}

// ---------- 描述与 SCPD ----------

func TestDescriptionAndSCPD(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	status, body := getBody(t, base+"/dmr.xml")
	if status != 200 {
		t.Fatalf("description 状态码 %d", status)
	}
	for _, want := range []string{
		"urn:schemas-upnp-org:device:MediaRenderer:1",
		"urn:schemas-upnp-org:service:AVTransport:1",
		"urn:schemas-upnp-org:service:RenderingControl:1",
		"urn:schemas-upnp-org:service:ConnectionManager:1",
		"/AVTransport/control",
		"/RenderingControl/event",
		"DMR-1.50",
		dev.cfg.UUID,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("description 缺少 %q", want)
		}
	}
	// 必须是能解析的 XML
	var root struct {
		XMLName xml.Name
	}
	if err := xml.Unmarshal([]byte(body), &root); err != nil {
		t.Fatalf("description 不是合法 XML: %v", err)
	}

	// 三份 SCPD 都要能解析，且包含关键动作
	wantActions := map[string][]string{
		serviceAVTransport:       {"SetAVTransportURI", "Play", "Pause", "Stop", "Seek", "GetPositionInfo", "GetTransportInfo", "GetMediaInfo", "GetCurrentTransportActions"},
		serviceRenderingControl:  {"SetVolume", "GetVolume", "SetMute", "GetMute", "ListPresets"},
		serviceConnectionManager: {"GetProtocolInfo", "GetCurrentConnectionIDs", "GetCurrentConnectionInfo"},
	}
	for svc, actions := range wantActions {
		_, scpd := getBody(t, base+"/"+svc+"/scpd.xml")
		var parsed struct {
			XMLName xml.Name
			Actions []struct {
				Name string `xml:"name"`
			} `xml:"actionList>action"`
			Vars []struct {
				Name string `xml:"name"`
			} `xml:"serviceStateTable>stateVariable"`
		}
		if err := xml.Unmarshal([]byte(scpd), &parsed); err != nil {
			t.Fatalf("%s SCPD 解析失败: %v", svc, err)
		}
		have := map[string]bool{}
		for _, a := range parsed.Actions {
			have[a.Name] = true
		}
		for _, a := range actions {
			if !have[a] {
				t.Errorf("%s SCPD 缺少动作 %s", svc, a)
			}
		}
		if len(parsed.Vars) == 0 {
			t.Errorf("%s SCPD 没有状态变量", svc)
		}
		// AVTransport / RenderingControl 的事件靠 LastChange 桶推送；
		// ConnectionManager 按规范是直接事件变量，没有 LastChange。
		if svc != serviceConnectionManager && !strings.Contains(scpd, "LastChange") {
			t.Errorf("%s SCPD 缺少 LastChange 事件变量", svc)
		}
	}
}

// ---------- 事件订阅 ----------

type notification struct {
	sid  string
	seq  string
	body string
}

func subscribe(t *testing.T, base, svc, callback, timeout string) string {
	t.Helper()
	req, _ := http.NewRequest("SUBSCRIBE", base+"/"+svc+"/event", nil)
	req.Header.Set("CALLBACK", "<"+callback+">")
	req.Header.Set("NT", "upnp:event")
	req.Header.Set("TIMEOUT", timeout)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("SUBSCRIBE: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("SUBSCRIBE 状态 %d", resp.StatusCode)
	}
	sid := resp.Header.Get("SID")
	if !strings.HasPrefix(sid, "uuid:") {
		t.Fatalf("SID 不合法: %q", sid)
	}
	return sid
}

func waitNotification(t *testing.T, ch <-chan notification, d time.Duration, pred func(notification) bool) notification {
	t.Helper()
	deadline := time.After(d)
	for {
		select {
		case n := <-ch:
			if pred == nil || pred(n) {
				return n
			}
		case <-deadline:
			t.Fatalf("等待事件超时")
		}
	}
}

func TestGENAFlow(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	ch := make(chan notification, 64)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if r.Method != "NOTIFY" {
			t.Errorf("回调用了 %s 方法", r.Method)
		}
		if r.Header.Get("NTS") != "upnp:propchange" {
			t.Errorf("NTS 不对: %q", r.Header.Get("NTS"))
		}
		w.WriteHeader(200)
		ch <- notification{sid: r.Header.Get("SID"), seq: r.Header.Get("SEQ"), body: string(body)}
	}))
	defer srv.Close()

	sid := subscribe(t, base, serviceAVTransport, srv.URL+"/", "Second-300")

	// 初始事件必须是 SEQ=0 且带 NO_MEDIA_PRESENT
	first := waitNotification(t, ch, 3*time.Second, nil)
	if first.seq != "0" {
		t.Errorf("初始事件 SEQ 应为 0，实际 %q", first.seq)
	}
	if first.sid != sid {
		t.Errorf("SID 不一致: %q vs %q", first.sid, sid)
	}
	if !strings.Contains(first.body, "NO_MEDIA_PRESENT") {
		t.Errorf("初始事件里没有 TransportState：%s", first.body)
	}

	// 设 URI 后应收到 STOPPED 事件
	soapCall(t, base, serviceAVTransport, "SetAVTransportURI", map[string]string{
		"InstanceID":         "0",
		"CurrentURI":         "http://127.0.0.1:1/movie.mp4",
		"CurrentURIMetaData": `<DIDL-Lite><item><dc:title>测试影片</dc:title></item></DIDL-Lite>`,
	}, 200)
	n := waitNotification(t, ch, 3*time.Second, func(n notification) bool {
		return strings.Contains(n.body, "STOPPED")
	})
	// SEQ 必须递增
	if n.seq == "0" {
		t.Errorf("事件 SEQ 没有递增")
	}

	// 播放：先 TRANSITIONING 再 PLAYING
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "1"}, 200)
	waitNotification(t, ch, 3*time.Second, func(n notification) bool {
		return strings.Contains(n.body, "PLAYING")
	})

	// 续订
	req, _ := http.NewRequest("SUBSCRIBE", base+"/"+serviceAVTransport+"/event", nil)
	req.Header.Set("SID", sid)
	req.Header.Set("TIMEOUT", "Second-600")
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("续订失败: %v %v", err, resp)
	}
	resp.Body.Close()

	// 取消订阅后不该再有事件
	req, _ = http.NewRequest("UNSUBSCRIBE", base+"/"+serviceAVTransport+"/event", nil)
	req.Header.Set("SID", sid)
	resp, err = http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("取消订阅失败: %v", err)
	}
	resp.Body.Close()
	soapCall(t, base, serviceAVTransport, "Stop", map[string]string{"InstanceID": "0"}, 200)

	select {
	case n := <-ch:
		t.Errorf("取消订阅后仍收到事件: %s", n.body)
	case <-time.After(500 * time.Millisecond):
	}
}

// ---------- 播放状态机 ----------

func TestPlaybackStateMachine(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	// 还没有媒体时 Play 应该是 701
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0"}, 500)

	meta := `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item><dc:title>测试</dc:title>` +
		`<res protocolInfo="http-get:*:video/mp4:*" duration="0:02:30.000">http://127.0.0.1:1/a.mp4</res></item></DIDL-Lite>`
	soapCall(t, base, serviceAVTransport, "SetAVTransportURI", map[string]string{
		"InstanceID": "0", "CurrentURI": "http://127.0.0.1:1/a.mp4", "CurrentURIMetaData": meta,
	}, 200)

	info := soapOut(t, soapCall(t, base, serviceAVTransport, "GetTransportInfo", map[string]string{"InstanceID": "0"}, 200), "CurrentTransportState")
	if info != stateStopped {
		t.Errorf("设 URI 后应为 STOPPED，实际 %s", info)
	}
	if dur := soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "TrackDuration"); dur != "00:02:30" {
		t.Errorf("时长解析不对: %q", dur)
	}

	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "1"}, 200)
	deadline := time.Now().Add(3 * time.Second)
	for {
		st := soapOut(t, soapCall(t, base, serviceAVTransport, "GetTransportInfo", map[string]string{"InstanceID": "0"}, 200), "CurrentTransportState")
		if st == statePlaying {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("没有进入 PLAYING，当前 %s", st)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// 位置要往前跑
	p1 := soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "RelTime")
	time.Sleep(1200 * time.Millisecond)
	p2 := soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "RelTime")
	if p1 == p2 {
		t.Errorf("播放中位置没有前进: %s", p1)
	}

	// 暂停 → 位置冻结
	soapCall(t, base, serviceAVTransport, "Pause", map[string]string{"InstanceID": "0"}, 200)
	p3 := soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "RelTime")
	time.Sleep(700 * time.Millisecond)
	p4 := soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "RelTime")
	if p3 != p4 {
		t.Errorf("暂停后位置仍在走: %s → %s", p3, p4)
	}

	// Seek
	soapCall(t, base, serviceAVTransport, "Seek", map[string]string{"InstanceID": "0", "Unit": "REL_TIME", "Target": "00:01:10"}, 200)
	if pos := soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "RelTime"); pos != "00:01:10" {
		t.Errorf("Seek 后位置应为 00:01:10，实际 %s", pos)
	}

	// Stop 回到 0
	soapCall(t, base, serviceAVTransport, "Stop", map[string]string{"InstanceID": "0"}, 200)
	body := soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200)
	if pos := soapOut(t, body, "RelTime"); pos != "00:00:00" {
		t.Errorf("Stop 后位置应归零，实际 %s", pos)
	}
}

// ---------- 音量与错误码 ----------

func TestRenderingControl(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	soapCall(t, base, serviceRenderingControl, "SetVolume", map[string]string{
		"InstanceID": "0", "Channel": "Master", "DesiredVolume": "55",
	}, 200)
	got := soapOut(t, soapCall(t, base, serviceRenderingControl, "GetVolume", map[string]string{
		"InstanceID": "0", "Channel": "Master",
	}, 200), "CurrentVolume")
	if got != "55" {
		t.Errorf("音量应为 55，实际 %s", got)
	}

	// 超出范围 → 402
	soapCall(t, base, serviceRenderingControl, "SetVolume", map[string]string{
		"InstanceID": "0", "Channel": "Master", "DesiredVolume": "200",
	}, 500)

	// 未知动作 → 401
	bad := soapCall(t, base, serviceRenderingControl, "NoSuchAction", map[string]string{"InstanceID": "0"}, 500)
	if !strings.Contains(bad, "<errorCode>401</errorCode>") {
		t.Errorf("未知动作应返回 401：%s", bad)
	}

	// 非法 InstanceID → 718
	bad = soapCall(t, base, serviceRenderingControl, "GetVolume", map[string]string{
		"InstanceID": "7", "Channel": "Master",
	}, 500)
	if !strings.Contains(bad, "<errorCode>718</errorCode>") {
		t.Errorf("非法 InstanceID 应返回 718：%s", bad)
	}

	// 非法 Seek 模式 → 710
	soapCall(t, base, serviceAVTransport, "SetAVTransportURI", map[string]string{
		"InstanceID": "0", "CurrentURI": "http://127.0.0.1:1/a.mp4", "CurrentURIMetaData": "",
	}, 200)
	bad = soapCall(t, base, serviceAVTransport, "Seek", map[string]string{
		"InstanceID": "0", "Unit": "SOMETHING", "Target": "1",
	}, 500)
	if !strings.Contains(bad, "<errorCode>710</errorCode>") {
		t.Errorf("非法 Seek 模式应返回 710：%s", bad)
	}
}

// ---------- 单元测试 ----------

func TestParseTimeTarget(t *testing.T) {
	cases := map[string]time.Duration{
		"00:01:10":    70 * time.Second,
		"1:02:03.500": 3723*time.Second + 500*time.Millisecond,
		"02:30":       150 * time.Second,
	}
	for in, want := range cases {
		got, err := parseTimeTarget(in)
		if err != nil {
			t.Errorf("%s 解析失败: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("%s 应为 %v，实际 %v", in, want, got)
		}
	}
	if _, err := parseTimeTarget("bogus"); err == nil {
		t.Error("非法时间应报错")
	}
}

func TestSSDPTargets(t *testing.T) {
	dev := &Device{cfg: Config{UUID: "abc-123"}}
	all := dev.ssdpTargets("ssdp:all")
	if len(all) != 6 {
		t.Fatalf("ssdp:all 应返回 6 条，实际 %d", len(all))
	}
	one := dev.ssdpTargets("urn:schemas-upnp-org:device:MediaRenderer:1")
	if len(one) != 1 || one[0].usn != "uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1" {
		t.Errorf("设备类型查询结果不对: %+v", one)
	}
	if got := dev.ssdpTargets("urn:schemas-upnp-org:device:MediaServer:1"); len(got) != 0 {
		t.Errorf("不该响应 MediaServer 查询: %+v", got)
	}
	root := dev.ssdpTargets("upnp:rootdevice")
	if len(root) != 1 || root[0].st != "upnp:rootdevice" {
		t.Errorf("rootdevice 查询结果不对: %+v", root)
	}
}

func TestSSDPMessages(t *testing.T) {
	dev := &Device{cfg: Config{UUID: "abc-123"}, httpPort: 8090, bootID: 42}
	resp := dev.ssdpResponse("upnp:rootdevice", "uuid:abc-123::upnp:rootdevice", "192.168.1.9")
	for _, want := range []string{
		"HTTP/1.1 200 OK", "CACHE-CONTROL: max-age=1800", "EXT:",
		"LOCATION: http://192.168.1.9:8090/dmr.xml",
		"ST: upnp:rootdevice", "USN: uuid:abc-123::upnp:rootdevice",
	} {
		if !strings.Contains(resp, want) {
			t.Errorf("SSDP 响应缺少 %q\n%s", want, resp)
		}
	}
	alive := dev.notifyMessages("192.168.1.9", true)
	if len(alive) != 6 || !strings.Contains(alive[0], "NTS: ssdp:alive") {
		t.Errorf("alive 通告不对: %v", alive)
	}
	byebye := dev.notifyMessages("192.168.1.9", false)
	if !strings.Contains(byebye[0], "NTS: ssdp:byebye") {
		t.Errorf("byebye 通告不对: %s", byebye[0])
	}
}

func TestPlaylistRewrite(t *testing.T) {
	in := "#EXTM3U\n" +
		"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n" +
		"#EXTINF:4.0,\n" +
		"seg1.ts\n" +
		"#EXTINF:4.0,\n" +
		"https://cdn.example.com/v/seg2.ts?token=abc\n"
	base, _ := url.Parse("https://cdn.example.com/v/index.m3u8")
	out := string(rewritePlaylist([]byte(in), base))
	if !strings.Contains(out, "/proxy?url=") {
		t.Fatalf("没有改写：%s", out)
	}
	if strings.Contains(out, "\nseg1.ts") {
		t.Errorf("相对分片没有改写：%s", out)
	}
	if !strings.Contains(out, "https%3A%2F%2Fcdn.example.com%2Fv%2Fseg1.ts") {
		t.Errorf("相对地址没有解析成绝对地址：%s", out)
	}
	if !strings.Contains(out, "key.bin") || !strings.Contains(out, "proxy") {
		t.Errorf("URI 属性没有改写：%s", out)
	}
	if !strings.Contains(out, "#EXTM3U") {
		t.Errorf("注释行被破坏了：%s", out)
	}
}

func TestBuildLastChange(t *testing.T) {
	avt := buildLastChange(serviceAVTransport, map[string]string{"TransportState": "PLAYING"})
	if !strings.Contains(avt, `urn:schemas-upnp-org:metadata-1-0/AVT/`) || !strings.Contains(avt, `TransportState val="PLAYING"`) {
		t.Errorf("AVT LastChange 不对: %s", avt)
	}
	rcs := buildLastChange(serviceRenderingControl, map[string]string{"Volume": "40"})
	if !strings.Contains(rcs, `urn:schemas-upnp-org:metadata-1-0/RCS/`) || !strings.Contains(rcs, `channel="Master"`) {
		t.Errorf("RCS LastChange 不对: %s", rcs)
	}
	// 特殊字符必须转义，否则控制点会解析失败
	esc := buildLastChange(serviceAVTransport, map[string]string{"CurrentTrackMetaData": `<a b="c">&</a>`})
	if strings.Contains(esc, `<a b="c">`) {
		t.Errorf("元数据没有转义: %s", esc)
	}
}

func TestVolumeDB(t *testing.T) {
	if v := volumeToDB(100); v != 0 {
		t.Errorf("100 应对应 0 dB，实际 %d", v)
	}
	if v := volumeToDB(0); v != -80 {
		t.Errorf("0 应对应 -80 dB，实际 %d", v)
	}
	if v := dbToVolume(0); v != 100 {
		t.Errorf("0 dB 应对应 100，实际 %d", v)
	}
	if v := dbToVolume(-80); v != 0 {
		t.Errorf("-80 dB 应对应 0，实际 %d", v)
	}
}
