package main

import (
	"net"
	"time"
)

// Diag 做一次网络自检，专门回答"为什么手机发现不了这台电视"。
// 组播和广播各试发一次，把内核错误原样带回来，不猜。
func (d *Device) Diag() map[string]any {
	d.mu.RLock()
	port := d.httpPort
	d.mu.RUnlock()

	multicastErr := trySendErr("239.255.255.250", 1900)

	subnet := ""
	var subnetErr error
	if ifaces, err := net.Interfaces(); err == nil {
		for _, ifi := range ifaces {
			if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagMulticast == 0 || ifi.Flags&net.FlagLoopback != 0 {
				continue
			}
			if b := subnetBroadcast(ifi); b != nil {
				subnet = b.String()
				subnetErr = trySendErr(subnet, 1900)
				break
			}
		}
	}

	var hints []string
	if multicastErr != nil {
		hints = append(hints,
			"组播发不出去，控制点基本不可能自动发现这台设备。",
			"常见原因：带 TUN 的代理（Clash/Surge 等）把 224.0.0.0/4 收进了隧道，或 macOS「本地网络」权限没给。",
			"Clash Verge 可在 tun.route-exclude-address 里加上 224.0.0.0/4 和本机网段来放行，不必关闭 TUN。",
		)
		if subnetErr == nil {
			hints = append(hints, "子网广播能发，程序会额外用它发通告；但多数控制点只认组播。")
		}
	}

	return map[string]any{
		"port":           port,
		"addresses":      localIPv4s(),
		"multicast_ok":   multicastErr == nil,
		"multicast_err":  errString(multicastErr),
		"broadcast_addr": subnet,
		"broadcast_ok":   subnetErr == nil,
		"broadcast_err":  errString(subnetErr),
		"msearch_count":  d.msCount,
		"subscribers":    d.subs.count(),
		"hints":          hints,
		"checked_at":     time.Now().Format("15:04:05"),
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// trySendErr 用一次性 socket 试发一包，返回内核给的真实错误。
// 用 WriteTo 而不是 Dial：组播被拒时，connect+write 会把错误换成 broken pipe。
func trySendErr(ip string, port int) error {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetWriteDeadline(time.Now().Add(800 * time.Millisecond))
	_, err = conn.WriteTo([]byte("X"), &net.UDPAddr{IP: net.ParseIP(ip), Port: port})
	return err
}
