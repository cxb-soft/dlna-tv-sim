package main

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"html"
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

// TestPlayerWindowPauseSync 覆盖“用户直接在播放器窗口里按暂停”这条路：
// 控制点不会发任何 SOAP，只有引擎知道，所以必须由播放器把状态回写给 DLNA。
// 不回写时 DLNA 一直报 PLAYING，而 positionLocked 按 pos+since(posAt) 继续算，
// 控制点（iPad）看到的进度就一直往前走，跟画面完全对不上。
func TestPlayerWindowPauseSync(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	meta := `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item><dc:title>窗口暂停测试</dc:title>` +
		`<res protocolInfo="http-get:*:video/mp4:*" duration="0:02:30.000">http://127.0.0.1:1/a.mp4</res></item></DIDL-Lite>`
	soapCall(t, base, serviceAVTransport, "SetAVTransportURI", map[string]string{
		"InstanceID": "0", "CurrentURI": "http://127.0.0.1:1/a.mp4", "CurrentURIMetaData": meta,
	}, 200)

	transport := func() string {
		return soapOut(t, soapCall(t, base, serviceAVTransport, "GetTransportInfo", map[string]string{"InstanceID": "0"}, 200), "CurrentTransportState")
	}
	relTime := func() string {
		return soapOut(t, soapCall(t, base, serviceAVTransport, "GetPositionInfo", map[string]string{"InstanceID": "0"}, 200), "RelTime")
	}

	// 摆到“正在播、已经放到 30 秒”。
	dev.mu.Lock()
	dev.state = statePlaying
	dev.pos = 30 * time.Second
	dev.posAt = time.Now()
	dev.mu.Unlock()

	// 播放器窗口里按了暂停：设备层同步状态。
	dev.syncPaused(true)
	if st := transport(); st != statePaused {
		t.Fatalf("播放器暂停后 CurrentTransportState 应为 %s，实际 %s", statePaused, st)
	}
	first := relTime()
	time.Sleep(900 * time.Millisecond)
	second := relTime()
	if first != second {
		t.Errorf("播放器暂停后位置应冻结，实际从 %s 走到了 %s", first, second)
	}
	if first == "00:00:00" {
		t.Errorf("暂停不应把位置归零，至少应保留播放到的位置")
	}

	// 窗口里再按继续：回到 PLAYING，位置重新前进。
	dev.syncPaused(false)
	if st := transport(); st != statePlaying {
		t.Fatalf("播放器继续后应为 %s，实际 %s", statePlaying, st)
	}
	resumed := relTime()
	time.Sleep(1200 * time.Millisecond)
	if later := relTime(); later == resumed {
		t.Errorf("播放器继续后位置没有重新前进: %s", later)
	}

	// 已经是 PLAYING 时再收到“未暂停”不该改状态（避免事件风暴）。
	dev.syncPaused(false)
	if st := transport(); st != statePlaying {
		t.Errorf("重复的未暂停信号不应改状态，实际 %s", st)
	}

	// 停止后，空闲播放器窗口报暂停（mpv --idle --force-window 会这样）不能被当成 PAUSED_PLAYBACK。
	soapCall(t, base, serviceAVTransport, "Stop", map[string]string{"InstanceID": "0"}, 200)
	dev.syncPaused(true)
	if st := transport(); st == statePaused {
		t.Errorf("停止后被播放器暂停信号误改成了 %s", st)
	}
}

// TestMpvLoadFileAtCommand 固住续播命令的形状：
// mpv 0.41 上 set_property start 会报 error accessing property 静默失效，
// 续播就变从头播。必须走 loadfile 的 options 参数。
func TestMpvLoadFileAtCommand(t *testing.T) {
	cmd := loadFileAtCommand("http://127.0.0.1:1/a.mp4", 90*time.Second)
	if len(cmd) != 5 {
		t.Fatalf("loadfile 命令应有 5 段，实际 %d: %v", len(cmd), cmd)
	}
	if cmd[0] != "loadfile" {
		t.Errorf("第一条应为 loadfile，实际 %v", cmd[0])
	}
	if cmd[1] != "http://127.0.0.1:1/a.mp4" {
		t.Errorf("地址不对: %v", cmd[1])
	}
	if cmd[2] != "replace" {
		t.Errorf("replace 位置不对: %v", cmd[2])
	}
	// 第四个是选项表下标，-1 表示插到末尾。
	if v, ok := cmd[3].(int); !ok || v != -1 {
		t.Errorf("第四段应为 -1，实际 %v", cmd[3])
	}
	// start 必须是 “start=<秒>” 这种字符串选项，不能是数字（数字会被当成下标）。
	opt, ok := cmd[4].(string)
	if !ok {
		t.Fatalf("第五段应为字符串选项，实际 %T", cmd[4])
	}
	if opt != "start=90.000" {
		t.Errorf("start 选项不对: %q", opt)
	}

	// 负位置要归零，不能把负数传给 mpv。
	neg := loadFileAtCommand("x", -5*time.Second)
	if neg[4] != "start=0.000" {
		t.Errorf("负位置应归零，实际 %q", neg[4])
	}
}

// TestPlayerWindowVolumeSync 覆盖“在播放器窗口里调音量/静音”：
// 与暂停同理，自绘控件和快捷键调音都不走 SOAP，只有引擎知道。
// 不回写时远程遥控器上显示的还是旧值；而且不能把控制点刚设的值反过来盖掉。
func TestPlayerWindowVolumeSync(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	volume := func() string {
		return soapOut(t, soapCall(t, base, serviceRenderingControl, "GetVolume", map[string]string{
			"InstanceID": "0", "Channel": "Master",
		}, 200), "CurrentVolume")
	}
	mute := func() string {
		return soapOut(t, soapCall(t, base, serviceRenderingControl, "GetMute", map[string]string{
			"InstanceID": "0", "Channel": "Master",
		}, 200), "CurrentMute")
	}

	// 播放器窗口里把音量拉到 55。
	dev.syncRendering(55, false)
	if got := volume(); got != "55" {
		t.Errorf("播放器调音后 DLNA 音量应为 55，实际 %s", got)
	}

	// 播放器窗口里静音。
	dev.syncRendering(55, true)
	if got := mute(); got != "1" {
		t.Errorf("播放器静音后 DLNA Mute 应为 1，实际 %s", got)
	}

	// 控制点调音：不能被播放器侧旧值盖回去。
	soapCall(t, base, serviceRenderingControl, "SetVolume", map[string]string{
		"InstanceID": "0", "Channel": "Master", "DesiredVolume": "20",
	}, 200)
	if got := volume(); got != "20" {
		t.Errorf("控制点设音量 20 后应为 20，实际 %s", got)
	}

	// 值没变时不应反复推事件（120ms 轮询会不停回调）。
	// 这里用真实 GENA 订阅数事件，不能用订阅数量代替。
	ch := make(chan notification, 64)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		w.WriteHeader(200)
		ch <- notification{body: string(body)}
	}))
	defer srv.Close()
	subscribe(t, base, serviceRenderingControl, srv.URL+"/", "Second-300")
	waitNotification(t, ch, 3*time.Second, nil) // 初始事件

	// GENA 的 LastChange 是两层转义的：外层 propertyset 把内层 XML 转义一次，
	// 属性里的引号再转成 &#34;。所以先反转义两遍再匹配。
	unescaped := func(n notification) string {
		return html.UnescapeString(html.UnescapeString(n.body))
	}

	// 本测试还没设过订阅前的值，先把当前值对齐，再重复推送同值。
	dev.syncRendering(40, false)
	waitNotification(t, ch, 3*time.Second, func(n notification) bool {
		return strings.Contains(unescaped(n), `<Volume channel="Master" val="40"/>`)
	})
	for i := 0; i < 5; i++ {
		dev.syncRendering(40, false)
	}
	select {
	case n := <-ch:
		t.Errorf("值没变时不应推事件，却收到: %s", unescaped(n))
	case <-time.After(600 * time.Millisecond):
	}

	// 值真变了就要推事件。
	dev.syncRendering(70, false)
	ev := waitNotification(t, ch, 3*time.Second, func(n notification) bool {
		return strings.Contains(unescaped(n), `<Volume channel="Master" val="70"/>`)
	})
	if !strings.Contains(unescaped(ev), "Volume") {
		t.Errorf("音量事件内容不对: %s", unescaped(ev))
	}

	// 越界值要夹到 0–100。
	dev.syncRendering(150, false)
	if got := volume(); got != "100" {
		t.Errorf("超界音量应夹到 100，实际 %s", got)
	}
	dev.syncRendering(-5, false)
	if got := volume(); got != "0" {
		t.Errorf("负音量应夹到 0，实际 %s", got)
	}
}

// TestTransportSpeedSync 固住倍速上报：DLNA 的 CurrentSpeed 和 TransportPlaySpeed
// 原来读的是一个独立字段，而这个字段从来没人写过，永远是 "1"。
// 结果就是不论控制点还是播放器窗口改倍速，iPad 查到的始终是「正在 1 倍速播」。
func TestTransportSpeedSync(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	meta := `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item><dc:title>倍速测试</dc:title>` +
		`<res protocolInfo="http-get:*:video/mp4:*" duration="0:02:30.000">http://127.0.0.1:1/a.mp4</res></item></DIDL-Lite>`
	soapCall(t, base, serviceAVTransport, "SetAVTransportURI", map[string]string{
		"InstanceID": "0", "CurrentURI": "http://127.0.0.1:1/a.mp4", "CurrentURIMetaData": meta,
	}, 200)

	currentSpeed := func() string {
		return soapOut(t, soapCall(t, base, serviceAVTransport, "GetTransportInfo", map[string]string{"InstanceID": "0"}, 200), "CurrentSpeed")
	}

	// 默认应为 1
	if got := currentSpeed(); got != "1" {
		t.Errorf("默认倍速应为 1，实际 %q", got)
	}

	// 控制点设 1.25 → GetTransportInfo 要能读到
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "1"}, 200)
	deadline := time.Now().Add(3 * time.Second)
	for {
		if st := soapOut(t, soapCall(t, base, serviceAVTransport, "GetTransportInfo", map[string]string{"InstanceID": "0"}, 200), "CurrentTransportState"); st == statePlaying {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("没有进入 PLAYING")
		}
		time.Sleep(50 * time.Millisecond)
	}

	dev.SetSpeed(1.25)
	if got := currentSpeed(); got != "1.25" {
		t.Errorf("SetSpeed(1.25) 后 CurrentSpeed 应为 1.25，实际 %q", got)
	}

	// 播放器窗口里改倍速（mpv observe / 自研轮询都走 noteSpeed）→ 也要能读到
	dev.noteSpeed(2)
	if got := currentSpeed(); got != "2" {
		t.Errorf("窗口改 2x 后 CurrentSpeed 应为 2，实际 %q", got)
	}

	// 事件里的 TransportPlaySpeed 也得跟上，否则控制点只能轮询
	ch := make(chan notification, 16)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		w.WriteHeader(200)
		ch <- notification{body: string(body)}
	}))
	defer srv.Close()
	subscribe(t, base, serviceAVTransport, srv.URL+"/", "Second-300")
	waitNotification(t, ch, 3*time.Second, nil) // 初始事件

	dev.noteSpeed(0.75)
	n := waitNotification(t, ch, 3*time.Second, func(n notification) bool {
		return strings.Contains(html.UnescapeString(html.UnescapeString(n.body)), `TransportPlaySpeed val="0.75"`)
	})
	if !strings.Contains(html.UnescapeString(html.UnescapeString(n.body)), "TransportPlaySpeed") {
		t.Errorf("事件里没有 TransportPlaySpeed")
	}

	// 值没变时不应刷事件
	dev.noteSpeed(0.75)
	select {
	case got := <-ch:
		t.Errorf("倍速没变时不应推事件，却收到: %s", html.UnescapeString(html.UnescapeString(got.body)))
	case <-time.After(500 * time.Millisecond):
	}
}

// TestRecordActionDeclared 固住 SCPD 与实现的一致性：
// SCPD 里按 AVTransport:1 模板声明了 Record，于是这个动作就必须存在。
// 设备是 MediaRenderer、不做录制，按规范返回 701 Transition not available；
// 不能因为没写 case 就落到 unknow 分支回 401 Invalid Action——
// 那是“动作不存在”，跟自己的 SCPD 自相矛盾，控制点会当成协议不兼容。
func TestRecordActionDeclared(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	// 先把 SCPD 拿出来，确认确实声明了 Record
	code, scpd := getBody(t, base+"/AVTransport/scpd.xml")
	if code != 200 || !strings.Contains(scpd, "<name>Record</name>") {
		t.Fatalf("SCPD 应声明 Record，实际状态 %d", code)
	}

	body := soapCall(t, base, serviceAVTransport, "Record", map[string]string{
		"InstanceID": "0", "RecordSource": "NETWORK", "RecordTarget": "",
	}, 500)
	if !strings.Contains(body, "<errorCode>701</errorCode>") {
		t.Errorf("Record 应返回 701（不支持的转换），实际：%s", body)
	}
	if strings.Contains(body, "Invalid Action") {
		t.Errorf("Record 已声明，不应回“动作不存在”：%s", body)
	}

	// 录像能力要把话说死，别让控制点试
	caps := soapCall(t, base, serviceAVTransport, "GetDeviceCapabilities", map[string]string{"InstanceID": "0"}, 200)
	if !strings.Contains(caps, "NOT_IMPLEMENTED") {
		t.Errorf("GetDeviceCapabilities 应声明不录制：%s", caps)
	}
}

// TestPlaySpeedSupported 固住 SCPD 声明与实际能力的一致性：
// 以前 SCPD 里 TransportPlaySpeed 只声明了 1，Play 也把非 1 一律拒（当年还用错了错误码）；
// 但引擎、网页控制台、窗口都真支持 0.25–4。现在两边说一致：声明了就要真认。
func TestPlaySpeedSupported(t *testing.T) {
	dev := newTestDevice(t)
	base := dev.testBase()

	// SCPD 里应该声明多个允许值，而不只是 1
	code, spd := getBody(t, base+"/AVTransport/scpd.xml")
	if code != 200 {
		t.Fatalf("取 SCPD 失败: %d", code)
	}
	for _, v := range []string{"0.5", "1.25", "2", "4"} {
		if !strings.Contains(spd, "<allowedValue>"+v+"</allowedValue>") {
			t.Errorf("SCPD 应声明支持 %s 倍速", v)
		}
	}

	meta := `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item><dc:title>倍速</dc:title>` +
		`<res protocolInfo="http-get:*:video/mp4:*" duration="0:02:30.000">http://127.0.0.1:1/a.mp4</res></item></DIDL-Lite>`
	soapCall(t, base, serviceAVTransport, "SetAVTransportURI", map[string]string{
		"InstanceID": "0", "CurrentURI": "http://127.0.0.1:1/a.mp4", "CurrentURIMetaData": meta,
	}, 200)

	currentSpeed := func() string {
		return soapOut(t, soapCall(t, base, serviceAVTransport, "GetTransportInfo", map[string]string{"InstanceID": "0"}, 200), "CurrentSpeed")
	}

	// Play 带倍速 2 → 应该真的生效，而不是被拒掉
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "2"}, 200)
	if got := currentSpeed(); got != "2" {
		t.Errorf("Play(Speed=2) 后 CurrentSpeed 应为 2，实际 %q", got)
	}

	// 分数写法（老控制点常用）
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "1/2"}, 200)
	if got := currentSpeed(); got != "0.5" {
		t.Errorf("Play(Speed=1/2) 后 CurrentSpeed 应为 0.5，实际 %q", got)
	}

	// 超出声明范围要拒绝（717 才是 Play speed not supported；712 是 Play mode not supported）
	body := soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "8"}, 500)
	if !strings.Contains(body, "<errorCode>717</errorCode>") {
		t.Errorf("超范围倍速应回 717（Play speed not supported），实际：%s", body)
	}
	if strings.Contains(body, "<errorCode>712</errorCode>") {
		t.Errorf("712 是 Play mode not supported，不能用作倍速错误：%s", body)
	}

	// 非法写法要是参数错，不是 717
	body = soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "abc"}, 500)
	if !strings.Contains(body, "<errorCode>402</errorCode>") {
		t.Errorf("非法倍速应回 402，实际：%s", body)
	}

	// 播放模式不支持用 712，描述要是 “Play mode not supported”
	body = soapCall(t, base, serviceAVTransport, "SetPlayMode", map[string]string{
		"InstanceID": "0", "NewPlayMode": "BOGUS",
	}, 500)
	if !strings.Contains(body, "<errorCode>712</errorCode>") {
		t.Errorf("非法播放模式应回 712，实际：%s", body)
	}
	if !strings.Contains(body, "Play mode not supported") {
		t.Errorf("712 的描述应为 Play mode not supported，实际：%s", body)
	}

	// 不传 Speed 时不应把本机设的倍速改掉（暂停后恢复很常见）。
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0"}, 200)
	if got := currentSpeed(); got != "0.5" {
		t.Errorf("不传 Speed 时应保留当前倍速 0.5，实际 %q", got)
	}

	// 显式传 1 才回到 1 倍速
	soapCall(t, base, serviceAVTransport, "Play", map[string]string{"InstanceID": "0", "Speed": "1"}, 200)
	if got := currentSpeed(); got != "1" {
		t.Errorf("显式 Speed=1 后应为 1，实际 %q", got)
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

// ---------- 高级播放 ----------

func TestPlayerControls(t *testing.T) {
	dev := newTestDevice(t)

	if e := dev.SetSpeed(1.5); e != nil {
		t.Fatalf("设 1.5x 失败: %+v", e)
	}
	if got := dev.Snapshot().Speed; got != 1.5 {
		t.Fatalf("倍速未生效: %v", got)
	}
	if e := dev.SetSpeed(0.1); e == nil || e.Code != 402 {
		t.Fatalf("过低倍速应 402，得到 %+v", e)
	}
	if e := dev.SetSpeed(9); e == nil || e.Code != 402 {
		t.Fatalf("过高倍速应 402，得到 %+v", e)
	}
	if e := dev.SetAspect("99:1"); e == nil || e.Code != 402 {
		t.Fatalf("非法比例应 402，得到 %+v", e)
	}
	if e := dev.SetAspect("4:3"); e != nil {
		t.Fatalf("合法比例失败: %+v", e)
	}
	dev.SetLoop(true)
	if !dev.Snapshot().Loop {
		t.Fatal("循环未生效")
	}
	dev.ReportDuration(90 * time.Second)
	if got := dev.Snapshot().Duration; got != 90 {
		t.Fatalf("时长上报未生效: %v", got)
	}

	dev.setTracks([]TrackInfo{{ID: 2, Type: "audio"}, {ID: 1, Type: "sub"}})
	if e := dev.SelectTrack("audio", 2); e != nil {
		t.Fatalf("合法音轨切换失败: %+v", e)
	}
	if e := dev.SelectTrack("audio", 7); e == nil || e.Code != 402 {
		t.Fatalf("不存在的轨道应 402，得到 %+v", e)
	}
	if e := dev.SelectTrack("sub", 2); e == nil || e.Code != 402 {
		t.Fatalf("轨道类型不匹配应 402，得到 %+v", e)
	}
	if e := dev.SelectTrack("video", 1); e == nil || e.Code != 402 {
		t.Fatalf("不支持的轨道类型应 402，得到 %+v", e)
	}

	caps := capabilitiesFor("web")
	if len(caps) != 2 || caps[0] != "speed" || caps[1] != "loop" {
		t.Fatalf("网页引擎能力不对: %v", caps)
	}
}

func TestPlayerHTTP(t *testing.T) {
	dev := newTestDevice(t)
	h := dev.routes()

	get := func(path string) (int, map[string]any) {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		var m map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &m)
		return rec.Code, m
	}
	post := func(path, body string) (int, map[string]any) {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		h.ServeHTTP(rec, req)
		var m map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &m)
		return rec.Code, m
	}

	if code, m := get("/api/player"); code != 200 || m["engine"] != "web" {
		t.Fatalf("GET /api/player: %d %v", code, m)
	}
	if code, m := post("/api/player", `{"action":"speed","value":1.25}`); code != 200 || m["speed"] != 1.25 {
		t.Fatalf("设倍速: %d %v", code, m)
	}
	if code, _ := post("/api/player", `{"action":"aspect","text":"1:1"}`); code != http.StatusConflict {
		t.Fatalf("非法比例应 409，得到 %d", code)
	}
	if code, _ := post("/api/player", `{"action":"screenshot"}`); code != http.StatusConflict {
		t.Fatalf("网页引擎截图应冲突，得到 %d", code)
	}
	if code, _ := post("/api/report", `{"duration":125}`); code != 200 {
		t.Fatalf("上报时长: %d", code)
	}
	if got := dev.Snapshot().Duration; got != 125 {
		t.Fatalf("时长未写入: %v", got)
	}
	if code, _ := post("/api/report", `{"ended":true}`); code != 200 {
		t.Fatalf("播完上报: %d", code)
	}
	if code, m := get("/api/player"); code != 200 || m["capabilities"] == nil {
		t.Fatalf("能力列表缺失: %d %v", code, m)
	}
}
