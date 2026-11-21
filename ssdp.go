package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/ipv4"
)

const ssdpGroupIP = "239.255.255.250"

var ssdpGroupAddr = &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}

// SSDP 负责 UPnP 的发现部分：收 M-SEARCH、回 200 OK、周期发 ssdp:alive、
// 退出时发 ssdp:byebye。真电视在局域网里就是靠这一套被手机和播放器找到的。
type SSDP struct {
	dev    *Device
	conn   *net.UDPConn
	pconn  *ipv4.PacketConn
	ifaces []net.Interface
	ips    map[int]string
	mu     sync.Mutex // 保护"换网卡再发送"这一对操作
	closed chan struct{}
	once   sync.Once
	wg     sync.WaitGroup
}

func NewSSDP(dev *Device) *SSDP {
	return &SSDP{dev: dev, ips: map[int]string{}, closed: make(chan struct{})}
}

func (s *SSDP) Start() error {
	lc := net.ListenConfig{Control: reuseAddrControl}
	pc, err := lc.ListenPacket(context.Background(), "udp4", "0.0.0.0:1900")
	if err != nil {
		return fmt.Errorf("绑定 UDP 1900 失败（SSDP 需要它）: %w", err)
	}
	conn, ok := pc.(*net.UDPConn)
	if !ok {
		pc.Close()
		return fmt.Errorf("UDP 套接字类型异常")
	}
	s.conn = conn
	s.pconn = ipv4.NewPacketConn(conn)
	_ = s.pconn.SetControlMessage(ipv4.FlagInterface, true)
	_ = s.pconn.SetMulticastTTL(4)
	_ = s.pconn.SetMulticastLoopback(true)

	ifaces, err := net.Interfaces()
	if err != nil {
		return fmt.Errorf("枚举网卡失败: %w", err)
	}
	for i := range ifaces {
		ifi := ifaces[i]
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagMulticast == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		ip := firstIPv4(ifi)
		if ip == "" {
			continue
		}
		if err := s.pconn.JoinGroup(&ifi, ssdpGroupAddr); err != nil {
			s.dev.logf("ssdp", "加入组播失败 %s: %v", ifi.Name, err)
			continue
		}
		s.ifaces = append(s.ifaces, ifi)
		s.ips[ifi.Index] = ip
		s.dev.logf("ssdp", "监听网卡 %s (%s)", ifi.Name, ip)
	}
	if len(s.ifaces) == 0 {
		s.dev.logf("ssdp", "警告：没有找到可用的组播网卡，SSDP 可能收不到广播发现")
	}

	s.wg.Add(2)
	go s.recvLoop()
	go s.advertiseLoop()
	return nil
}

func (s *SSDP) recvLoop() {
	defer s.wg.Done()
	buf := make([]byte, 4096)
	for {
		n, cm, src, err := s.pconn.ReadFrom(buf)
		if err != nil {
			select {
			case <-s.closed:
				return
			default:
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		first, headers := parseSSDP(string(buf[:n]))
		switch {
		case strings.HasPrefix(first, "M-SEARCH"):
			st := strings.TrimSpace(headers["st"])
			if st == "" {
				continue
			}
			if man := strings.Trim(headers["man"], `"`); man != "" && !strings.EqualFold(man, "ssdp:discover") {
				continue
			}
			mx := 1
			if v, err := strconv.Atoi(headers["mx"]); err == nil && v > 0 && v < 10 {
				mx = v
			}
			ip := ""
			if cm != nil {
				ip = s.ips[cm.IfIndex]
			}
			if ip == "" {
				ip = localIPFor(src)
			}
			if ip == "" {
				ip = fallbackIP()
			}
			atomic.AddInt64(&s.dev.msCount, 1)
			s.dev.logf("ssdp", "M-SEARCH 来自 %s  ST=%s", src.String(), st)
			go s.respond(src, st, mx, ip)
		case strings.HasPrefix(first, "NOTIFY"):
			if s.dev.verbose {
				s.dev.logf("ssdp", "NOTIFY %s NT=%s USN=%s", first, headers["nt"], headers["usn"])
			}
		}
	}
}

func (s *SSDP) respond(to net.Addr, st string, mx int, ip string) {
	// UPnP 要求随机延迟，避免整屋设备同时回包把网络打满。
	maxMs := mx * 500
	if maxMs > 3000 {
		maxMs = 3000
	}
	if maxMs > 0 {
		select {
		case <-time.After(time.Duration(rand.Intn(maxMs+1)) * time.Millisecond):
		case <-s.closed:
			return
		}
	}
	targets := s.dev.ssdpTargets(st)
	if len(targets) == 0 {
		return
	}
	for _, t := range targets {
		msg := s.dev.ssdpResponse(t.st, t.usn, ip)
		if _, err := s.pconn.WriteTo([]byte(msg), nil, to); err != nil {
			s.dev.logf("ssdp", "回包失败: %v", err)
			return
		}
	}
	s.dev.logf("ssdp", "已回应 %s（%s）", to.String(), st)
}

func (s *SSDP) advertiseLoop() {
	defer s.wg.Done()
	s.advertise(true)
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-s.closed:
			return
		case <-t.C:
			s.advertise(true)
		}
	}
}

func (s *SSDP) advertise(alive bool) {
	for i := range s.ifaces {
		ifi := s.ifaces[i]
		ip := s.ips[ifi.Index]
		msgs := s.dev.notifyMessages(ip, alive)
		s.mu.Lock()
		err := s.pconn.SetMulticastInterface(&ifi)
		if err == nil {
			for _, m := range msgs {
				if _, werr := s.pconn.WriteTo([]byte(m), nil, ssdpGroupAddr); werr != nil {
					err = werr
					break
				}
			}
		}
		s.mu.Unlock()
		if err != nil {
			s.dev.logf("ssdp", "组播通告失败（%s）: %v", ifi.Name, err)
		}
		// 备用通道：组播被系统或代理拦住时，子网广播有些控制点也能收到
		if bcast := subnetBroadcast(ifi); bcast != nil {
			dst := &net.UDPAddr{IP: bcast, Port: 1900}
			for _, msg := range msgs {
				if _, werr := s.pconn.WriteTo([]byte(msg), nil, dst); werr != nil {
					s.dev.logf("ssdp", "广播通告失败（%s）: %v", ifi.Name, werr)
					break
				}
			}
		}
	}
	if alive {
		s.dev.logf("ssdp", "已发送 ssdp:alive 通告")
	}
}

func (s *SSDP) Close() {
	s.once.Do(func() {
		close(s.closed)
		s.advertise(false)
		time.Sleep(60 * time.Millisecond)
		if s.conn != nil {
			s.conn.Close()
		}
		s.wg.Wait()
	})
}

// ---------- 报文构造 ----------

type ssdpTarget struct {
	st  string
	usn string
}

// ssdpTargets 按 UPnP 规范列出本设备的全部发现目标：
// 根设备、设备 UUID、设备类型、每个服务类型各一条。
func (d *Device) ssdpTargets(filter string) []ssdpTarget {
	uuid := "uuid:" + d.cfg.UUID
	all := []ssdpTarget{
		{"upnp:rootdevice", uuid + "::upnp:rootdevice"},
		{uuid, uuid},
		{"urn:schemas-upnp-org:device:MediaRenderer:1", uuid + "::urn:schemas-upnp-org:device:MediaRenderer:1"},
		{"urn:schemas-upnp-org:service:AVTransport:1", uuid + "::urn:schemas-upnp-org:service:AVTransport:1"},
		{"urn:schemas-upnp-org:service:RenderingControl:1", uuid + "::urn:schemas-upnp-org:service:RenderingControl:1"},
		{"urn:schemas-upnp-org:service:ConnectionManager:1", uuid + "::urn:schemas-upnp-org:service:ConnectionManager:1"},
	}
	f := strings.TrimSpace(filter)
	if f == "" || strings.EqualFold(f, "ssdp:all") {
		return all
	}
	if strings.EqualFold(f, "upnp:rootdevice") {
		return all[:1]
	}
	var out []ssdpTarget
	for _, t := range all {
		if strings.EqualFold(t.st, f) {
			out = append(out, t)
		}
	}
	return out
}

func (d *Device) ssdpResponse(st, usn, ip string) string {
	lines := []string{
		"HTTP/1.1 200 OK",
		"CACHE-CONTROL: max-age=1800",
		"DATE: " + time.Now().UTC().Format(http.TimeFormat),
		"EXT:",
		"LOCATION: " + d.baseURL(ip) + "/dmr.xml",
		"SERVER: " + serverString,
		"ST: " + st,
		"USN: " + usn,
		"BOOTID.UPNP.ORG: " + strconv.Itoa(d.bootID),
		"CONFIGID.UPNP.ORG: 1337",
		"", "",
	}
	return strings.Join(lines, "\r\n")
}

func (d *Device) notifyMessages(ip string, alive bool) []string {
	var msgs []string
	for _, t := range d.ssdpTargets("") {
		lines := []string{"NOTIFY * HTTP/1.1", "HOST: 239.255.255.250:1900"}
		if alive {
			lines = append(lines,
				"CACHE-CONTROL: max-age=1800",
				"LOCATION: "+d.baseURL(ip)+"/dmr.xml",
				"NT: "+t.st,
				"NTS: ssdp:alive",
				"SERVER: "+serverString,
				"USN: "+t.usn,
				"BOOTID.UPNP.ORG: "+strconv.Itoa(d.bootID),
				"CONFIGID.UPNP.ORG: 1337",
			)
		} else {
			lines = append(lines,
				"NT: "+t.st,
				"NTS: ssdp:byebye",
				"USN: "+t.usn,
				"BOOTID.UPNP.ORG: "+strconv.Itoa(d.bootID),
			)
		}
		msgs = append(msgs, strings.Join(append(lines, "", ""), "\r\n"))
	}
	return msgs
}

// ---------- 小工具 ----------

func parseSSDP(text string) (string, map[string]string) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	headers := make(map[string]string, 8)
	if len(lines) == 0 {
		return "", headers
	}
	first := strings.TrimSpace(lines[0])
	for _, ln := range lines[1:] {
		i := strings.Index(ln, ":")
		if i <= 0 {
			continue
		}
		headers[strings.ToLower(strings.TrimSpace(ln[:i]))] = strings.TrimSpace(ln[i+1:])
	}
	return first, headers
}

// subnetBroadcast 算一个网卡的定向广播地址（例如 192.168.31.255）。
// 组播被代理/VPN 拦住时，这条通道还能把通告送到局域网。
func subnetBroadcast(ifi net.Interface) net.IP {
	addrs, err := ifi.Addrs()
	if err != nil {
		return nil
	}
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip4 := ipnet.IP.To4()
		mask := ipnet.Mask
		if ip4 == nil || len(mask) != 4 {
			continue
		}
		out := make(net.IP, 4)
		for i := 0; i < 4; i++ {
			out[i] = ip4[i] | ^mask[i]
		}
		return out
	}
	return nil
}

func firstIPv4(ifi net.Interface) string {
	addrs, err := ifi.Addrs()
	if err != nil {
		return ""
	}
	var linkLocal string
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip4 := ipnet.IP.To4()
		if ip4 == nil || ip4.IsLoopback() {
			continue
		}
		if ip4.IsLinkLocalUnicast() {
			// 直连链路（比如 iPad 用线接过来的 en15）只有 169.254 地址，
			// 这种链路上的设备也要能发现我们，所以留着备用。
			if linkLocal == "" {
				linkLocal = ip4.String()
			}
			continue
		}
		return ip4.String()
	}
	return linkLocal
}

// localIPFor 在只知道对端地址时，挑一个同网段的本机地址。
func localIPFor(remote net.Addr) string {
	ua, ok := remote.(*net.UDPAddr)
	if !ok || ua.IP == nil {
		return ""
	}
	ip4 := ua.IP.To4()
	if ip4 == nil {
		return ""
	}
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, ifi := range ifaces {
		addrs, err := ifi.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			local := ipnet.IP.To4()
			if local == nil || ipnet.Mask == nil || len(ipnet.Mask) != 4 {
				continue
			}
			if ipnet.Contains(ip4) {
				return local.String()
			}
		}
	}
	return ""
}

func fallbackIP() string {
	ips := localIPv4s()
	if len(ips) > 0 {
		return ips[0]
	}
	return "127.0.0.1"
}

func (d *Device) baseURL(ip string) string {
	d.mu.RLock()
	port := d.httpPort
	d.mu.RUnlock()
	if port == 0 {
		d.mu.RLock()
		port = d.cfg.HTTPPort
		d.mu.RUnlock()
	}
	return fmt.Sprintf("http://%s:%d", ip, port)
}
