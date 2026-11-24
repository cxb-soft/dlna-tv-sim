package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// Arg 是一个 SOAP 出参。顺序按 UPnP 规范来，某些老客户端会按位置读。
type Arg struct {
	Name  string
	Value string
}

func (d *Device) serviceType(service string) string {
	return "urn:schemas-upnp-org:service:" + service + ":1"
}

// dispatch 是所有 SOAP 动作的唯一入口，返回出参或 UPnP 错误。
func (d *Device) dispatch(service, action string, in map[string]string) ([]Arg, *upnpError) {
	if id := strings.TrimSpace(in["InstanceID"]); id != "" && id != "0" {
		return nil, &upnpError{718, "Invalid InstanceID"}
	}
	switch service {
	case serviceAVTransport:
		return d.avtAction(action, in)
	case serviceRenderingControl:
		return d.rcsAction(action, in)
	case serviceConnectionManager:
		return d.cmAction(action, in)
	}
	return nil, &upnpError{401, "Invalid Action"}
}

// ---------- AVTransport ----------

func (d *Device) avtAction(action string, in map[string]string) ([]Arg, *upnpError) {
	switch action {
	case "SetAVTransportURI":
		d.SetURI(in["CurrentURI"], in["CurrentURIMetaData"])
		return nil, nil

	case "SetNextAVTransportURI":
		uri := strings.TrimSpace(in["NextURI"])
		meta := in["NextAVTransportURIMetaData"]
		d.mu.Lock()
		if d.uri == "" {
			d.mu.Unlock()
			return nil, &upnpError{701, "Transition not available"}
		}
		d.nextURI, d.nextMeta = uri, meta
		d.mu.Unlock()
		d.logf("avt", "设置下一曲: %s", mediaTitle(meta, uri))
		d.emit(serviceAVTransport)
		return nil, nil

	case "GetMediaInfo":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{
			{"NrTracks", strconv.Itoa(d.trackCountLocked())},
			{"MediaDuration", formatTime(d.duration)},
			{"CurrentURI", d.uri},
			{"CurrentURIMetaData", d.uriMeta},
			{"NextURI", d.nextURI},
			{"NextAVTransportURIMetaData", d.nextMeta},
			{"PlayMedium", "NETWORK"},
			{"RecordMedium", "NOT_IMPLEMENTED"},
			{"WriteStatus", "NOT_IMPLEMENTED"},
		}, nil

	case "GetTransportInfo":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{
			{"CurrentTransportState", d.state},
			{"CurrentTransportStatus", d.status},
			{"CurrentSpeed", formatPlaySpeed(d.speed)},
		}, nil

	case "GetPositionInfo":
		d.mu.RLock()
		defer d.mu.RUnlock()
		pos := formatTime(d.positionLocked())
		return []Arg{
			{"Track", strconv.Itoa(d.trackNo)},
			{"TrackDuration", formatTime(d.duration)},
			{"TrackMetaData", d.uriMeta},
			{"TrackURI", d.uri},
			{"RelTime", pos},
			{"AbsTime", pos},
			{"RelCount", "2147483647"},
			{"AbsCount", "2147483647"},
		}, nil

	case "Record":
		// SCPD 里按 AVTransport:1 完整模板声明了 Record，那这个动作就得存在。
		// 不能落到 unknow 分支返回 401 Invalid Action——那是“动作不存在”，跟 SCPD 自相矛盾，
		// 控制点会当成协议不兼容。设备是 MediaRenderer，不做录制，
		// 按规范在不支持的状态下返回 701 Transition not available。
		// 这与 GetDeviceCapabilities 里的 RecMedia=NOT_IMPLEMENTED 一致。
		return nil, &upnpError{701, "Transition not available"}

	case "GetDeviceCapabilities":
		return []Arg{
			{"PlayMedia", "NETWORK"},
			{"RecMedia", "NOT_IMPLEMENTED"},
			{"RecQualityModes", "NOT_IMPLEMENTED"},
		}, nil

	case "GetTransportSettings":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{
			{"PlayMode", d.playMode},
			{"RecQualityMode", "NOT_IMPLEMENTED"},
		}, nil

	case "Stop":
		if err := d.Stop(); err != nil {
			return nil, err
		}
		return nil, nil

	case "Play":
		// 倍速在 SCPD 里已声明支持 0.25–4，这里就得真的认。
		// 以前只认 "1"，其他一律 712，但 SCPD 的 CurrentSpeed 又会如实报出实际倍速，
		// 两边就矛盾了：声明了支持却永远改不了。
		speed := strings.TrimSpace(in["Speed"])
		v, perr := parsePlaySpeed(speed)
		if perr != nil {
			return nil, perr
		}
		// 先写倍速再开播：Show 里的 applySettings 会读 d.speed，
		// 反过来做就存在“播放器已按旧倍速起来”的竞态。
		// 只在显式带了 Speed 时才改：不传 Speed 的 Play 很常见（尤其在暂停后恢复），
		// 那时把用户在本机设的 2x 悄悄拉回 1x 是没人要的行为。
		if speed != "" {
			if serr := d.SetSpeed(v); serr != nil {
				return nil, serr
			}
		}
		if err := d.Play(); err != nil {
			return nil, err
		}
		return nil, nil

	case "Pause":
		if err := d.Pause(); err != nil {
			return nil, err
		}
		return nil, nil

	case "Seek":
		unit := strings.ToUpper(strings.TrimSpace(in["Unit"]))
		target := strings.TrimSpace(in["Target"])
		switch unit {
		case "REL_TIME", "ABS_TIME":
			dur, err := parseTimeTarget(target)
			if err != nil {
				return nil, &upnpError{711, "Illegal seek target"}
			}
			if err := d.Seek(dur); err != nil {
				return nil, err
			}
		case "TRACK_NR":
			n, err := strconv.Atoi(target)
			if err != nil || n != 1 {
				return nil, &upnpError{711, "Illegal seek target"}
			}
			if err := d.Seek(0); err != nil {
				return nil, err
			}
		default:
			return nil, &upnpError{710, "Seek mode not supported"}
		}
		return nil, nil

	case "Next":
		d.mu.Lock()
		if d.nextURI == "" {
			d.mu.Unlock()
			return nil, &upnpError{701, "Transition not available"}
		}
		wasPlaying := d.state == statePlaying
		d.uri, d.uriMeta = d.nextURI, d.nextMeta
		d.nextURI, d.nextMeta = "", ""
		d.duration = durationFromMeta(d.uriMeta)
		d.pos, d.posAt = 0, time.Now()
		d.state = stateStopped
		title := mediaTitle(d.uriMeta, d.uri)
		d.mu.Unlock()
		d.logf("avt", "切到下一曲: %s", title)
		d.emit(serviceAVTransport)
		if wasPlaying {
			if err := d.Play(); err != nil {
				return nil, err
			}
		}
		return nil, nil

	case "Previous":
		d.mu.Lock()
		if d.uri == "" {
			d.mu.Unlock()
			return nil, &upnpError{701, "Transition not available"}
		}
		wasPlaying := d.state == statePlaying
		d.pos, d.posAt = 0, time.Now()
		d.mu.Unlock()
		d.emit(serviceAVTransport)
		if wasPlaying {
			if err := d.Play(); err != nil {
				return nil, err
			}
		}
		return nil, nil

	case "SetPlayMode":
		mode := strings.TrimSpace(in["NewPlayMode"])
		valid := map[string]bool{
			"NORMAL": true, "SHUFFLE": true, "REPEAT_ONE": true,
			"REPEAT_ALL": true, "RANDOM": true, "DIRECT_1": true, "INTRO": true,
		}
		if !valid[mode] {
			return nil, &upnpError{712, "Play mode not supported"}
		}
		d.mu.Lock()
		d.playMode = mode
		d.mu.Unlock()
		d.emit(serviceAVTransport)
		return nil, nil

	case "SetRecordQualityMode":
		return nil, &upnpError{701, "Transition not available"}

	case "GetCurrentTransportActions":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{{"Actions", d.transportActionsLocked()}}, nil
	}
	return nil, &upnpError{401, "Invalid Action"}
}

// ---------- RenderingControl ----------

func (d *Device) rcsAction(action string, in map[string]string) ([]Arg, *upnpError) {
	channel := strings.TrimSpace(in["Channel"])
	if channel != "" && !strings.EqualFold(channel, "Master") {
		return nil, &upnpError{402, "Invalid Args"}
	}
	switch action {
	case "ListPresets":
		return []Arg{{"CurrentPresetNameList", "FactoryDefaults"}}, nil

	case "SelectPreset":
		if !strings.EqualFold(strings.TrimSpace(in["PresetName"]), "FactoryDefaults") {
			return nil, &upnpError{701, "Invalid Name"}
		}
		return nil, nil

	case "GetMute":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{{"CurrentMute", boolStr(d.mute)}}, nil

	case "SetMute":
		v := strings.TrimSpace(in["DesiredMute"])
		mute, err := parseBool(v)
		if err != nil {
			return nil, &upnpError{402, "Invalid Args"}
		}
		d.SetMute(mute)
		return nil, nil

	case "GetVolume":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{{"CurrentVolume", strconv.Itoa(d.volume)}}, nil

	case "SetVolume":
		v, err := strconv.Atoi(strings.TrimSpace(in["DesiredVolume"]))
		if err != nil || v < 0 || v > 100 {
			return nil, &upnpError{402, "Invalid Args"}
		}
		if e := d.SetVolume(v); e != nil {
			return nil, e
		}
		return nil, nil

	case "GetVolumeDB":
		d.mu.RLock()
		defer d.mu.RUnlock()
		return []Arg{{"CurrentVolume", strconv.Itoa(volumeToDB(d.volume))}}, nil

	case "SetVolumeDB":
		db, err := strconv.Atoi(strings.TrimSpace(in["DesiredVolume"]))
		if err != nil || db < -80 || db > 0 {
			return nil, &upnpError{402, "Invalid Args"}
		}
		if e := d.SetVolume(dbToVolume(db)); e != nil {
			return nil, e
		}
		return nil, nil

	case "GetVolumeDBRange":
		return []Arg{{"MinValue", "-80"}, {"MaxValue", "0"}}, nil
	}
	return nil, &upnpError{401, "Invalid Action"}
}

// ---------- ConnectionManager ----------

const sinkProtocolInfo = "http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,http-get:*:video/mpeg:*,http-get:*:video/mp2t:*,http-get:*:video/MP2T:*,http-get:*:video/avi:*,http-get:*:video/x-msvideo:*,http-get:*:video/x-ms-wmv:*,http-get:*:video/quicktime:*,http-get:*:video/webm:*,http-get:*:video/x-flv:*,http-get:*:video/3gpp:*,http-get:*:video/vnd.dlna.mpeg-tts:*,http-get:*:application/vnd.apple.mpegurl:*,http-get:*:application/x-mpegURL:*,http-get:*:application/dash+xml:*,http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,http-get:*:audio/x-wav:*,http-get:*:audio/flac:*,http-get:*:audio/x-flac:*,http-get:*:image/jpeg:*,http-get:*:image/png:*,http-get:*:image/gif:*,http-get:*:*:*"

func (d *Device) cmAction(action string, in map[string]string) ([]Arg, *upnpError) {
	switch action {
	case "GetProtocolInfo":
		return []Arg{
			{"Source", ""},
			{"Sink", sinkProtocolInfo},
		}, nil
	case "GetCurrentConnectionIDs":
		return []Arg{{"ConnectionIDs", "0"}}, nil
	case "GetCurrentConnectionInfo":
		id := strings.TrimSpace(in["ConnectionID"])
		if id != "" && id != "0" {
			return nil, &upnpError{706, "Invalid connection reference"}
		}
		return []Arg{
			{"RcsID", "0"},
			{"AVTransportID", "0"},
			{"ProtocolInfo", ""},
			{"PeerConnectionManager", ""},
			{"PeerConnectionID", "-1"},
			{"Direction", "Input"},
			{"Status", "OK"},
		}, nil
	}
	return nil, &upnpError{401, "Invalid Action"}
}

// ---------- 数值换算 / 解析 ----------

func volumeToDB(v int) int {
	if v <= 0 {
		return -80
	}
	// 20*log10(v/100)，再夹到 -80..0
	x := 20 * math.Log10(float64(v)/100.0)
	if x < -80 {
		x = -80
	}
	if x > 0 {
		x = 0
	}
	return int(x)
}

func dbToVolume(db int) int {
	if db <= -80 {
		return 0
	}
	v := 100 * math.Pow(10, float64(db)/20.0)
	if v > 100 {
		v = 100
	}
	if v < 0 {
		v = 0
	}
	return int(v + 0.5)
}

// parsePlaySpeed 解析 Play 的 Speed 参数。
// UPnP 里倍速既允许 "1"、"2" 这种整数，也允许 "1/2" 这种分数写法（老控制点常用）。
// 空值表示不指定，按 1x 处理；超出 SCPD 声明范围时返回 717。
// 注意 717 才是 “Play speed not supported”，712 是 “Play mode not supported”。
func parsePlaySpeed(v string) (float64, *upnpError) {
	v = strings.TrimSpace(v)
	if v == "" {
		return 1, nil
	}
	if strings.Contains(v, "/") {
		parts := strings.SplitN(v, "/", 2)
		num, err1 := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
		den, err2 := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
		if err1 != nil || err2 != nil || den == 0 {
			return 0, &upnpError{402, "Invalid Args"}
		}
		v = strconv.FormatFloat(num/den, 'f', -1, 64)
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, &upnpError{402, "Invalid Args"}
	}
	if f < 0.25 || f > 4 {
		return 0, &upnpError{717, "Play speed not supported"}
	}
	return f, nil
}

func parseBool(v string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes":
		return true, nil
	case "0", "false", "no":
		return false, nil
	}
	return false, fmt.Errorf("不是布尔值: %q", v)
}

// ---------- SOAP 报文 ----------

type soapReq struct {
	Action  string
	Args    map[string]string
	Service string // 从头里解析出的服务短名，没有则为空
}

func parseSOAP(body []byte, soapAction string) (*soapReq, error) {
	type envelope struct {
		XMLName xml.Name
		Body    struct {
			Inner []byte `xml:",innerxml"`
		} `xml:"Body"`
	}
	var env envelope
	if err := xml.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("SOAP 信封解析失败: %w", err)
	}
	if len(env.Body.Inner) == 0 {
		return nil, fmt.Errorf("SOAP 缺少 Body")
	}
	type anyElem struct {
		XMLName xml.Name
		Value   string `xml:",chardata"`
	}
	var holder struct {
		XMLName  xml.Name
		Children []anyElem `xml:",any"`
	}
	if err := xml.Unmarshal(env.Body.Inner, &holder); err != nil {
		return nil, fmt.Errorf("SOAP 动作解析失败: %w", err)
	}
	req := &soapReq{Action: holder.XMLName.Local, Args: map[string]string{}}
	for _, c := range holder.Children {
		req.Args[c.XMLName.Local] = c.Value
	}
	// SOAPACTION 头更可靠：urn:schemas-upnp-org:service:AVTransport:1#Play
	if soapAction != "" {
		if i := strings.LastIndex(soapAction, "#"); i >= 0 {
			req.Action = soapAction[i+1:]
			urn := soapAction[:i]
			if j := strings.LastIndex(urn, ":"); j >= 0 {
				svc := urn[j+1:]
				if k := strings.LastIndex(svc, ":"); k >= 0 {
					svc = svc[k+1:]
				}
				req.Service = svc
			}
		}
	}
	if req.Action == "" {
		return nil, fmt.Errorf("SOAP 无法确定动作名")
	}
	return req, nil
}

func soapResponse(action, serviceType string, out []Arg) []byte {
	var b bytes.Buffer
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	b.WriteString(`<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">`)
	b.WriteString(`<s:Body><u:` + action + `Response xmlns:u="` + serviceType + `">`)
	for _, a := range out {
		b.WriteString("<" + a.Name + ">" + xmlEscape(a.Value) + "</" + a.Name + ">")
	}
	b.WriteString(`</u:` + action + `Response></s:Body></s:Envelope>`)
	return b.Bytes()
}

func soapFault(code int, desc string) []byte {
	var b bytes.Buffer
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?>` + "\n")
	b.WriteString(`<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">`)
	b.WriteString(`<s:Body><s:Fault>`)
	b.WriteString(`<faultcode>s:Client</faultcode>`)
	b.WriteString(`<faultstring>UPnPError</faultstring>`)
	b.WriteString(`<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">`)
	b.WriteString(`<errorCode>` + strconv.Itoa(code) + `</errorCode>`)
	b.WriteString(`<errorDescription>` + xmlEscape(desc) + `</errorDescription>`)
	b.WriteString(`</UPnPError></detail>`)
	b.WriteString(`</s:Fault></s:Body></s:Envelope>`)
	return b.Bytes()
}
