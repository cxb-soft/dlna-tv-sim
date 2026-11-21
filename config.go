package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

// Config 是这个"电视"的身份与端口设置，持久化在用户配置目录里，
// 这样同一个 UUID 一直不变——控制点会按 UUID 记住这台设备。
type Config struct {
	FriendlyName string `json:"friendly_name"`
	Manufacturer string `json:"manufacturer"`
	ModelName    string `json:"model_name"`
	ModelNumber  string `json:"model_number"`
	SerialNumber string `json:"serial_number"`
	UUID         string `json:"uuid"`
	HTTPPort     int    `json:"http_port"`
	Player       string `json:"player"` // auto / vlc / web
}

func DefaultConfig() Config {
	return Config{
		FriendlyName: "[TV] 客厅电视 (DLNA 模拟器)",
		Manufacturer: "Friend Lab",
		ModelName:    "DLNA-TV-SIM",
		ModelNumber:  "1.0",
		HTTPPort:     8090,
		Player:       "auto",
	}
}

func configPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "dlna-tv-sim", "config.json"), nil
}

func loadConfig(path string) (Config, error) {
	cfg := DefaultConfig()
	data, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(data, &cfg); err != nil {
			return cfg, fmt.Errorf("配置文件损坏: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return cfg, err
	}
	if cfg.UUID == "" {
		cfg.UUID = newUUID()
	}
	if cfg.HTTPPort == 0 {
		cfg.HTTPPort = 8090
	}
	if cfg.FriendlyName == "" {
		cfg.FriendlyName = DefaultConfig().FriendlyName
	}
	if cfg.Player == "" {
		cfg.Player = "auto"
	}
	return cfg, nil
}

func (c Config) save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

// newUUID 生成标准 UUID v4 字符串（不带 uuid: 前缀）。
func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// 极端情况下退化为时间派生，仍然保证唯一性够用
		n := os.Getpid()
		for i := range b {
			b[i] = byte(n >> (uint(i%4) * 8))
		}
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	hexs := "0123456789abcdef"
	out := make([]byte, 0, 36)
	for i, v := range b {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out = append(out, '-')
		}
		out = append(out, hexs[v>>4], hexs[v&0x0f])
	}
	return string(out)
}

// serialFor 给没有序列号的配置派生一个稳定的、像电视一样的序列号。
func serialFor(uuid string) string {
	sum := 0
	for _, c := range uuid {
		sum = (sum*31 + int(c)) % 1000000
	}
	return "TVSIM-" + strconv.Itoa(100000+sum)
}
