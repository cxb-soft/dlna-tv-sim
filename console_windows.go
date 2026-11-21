//go:build windows

package main

import "golang.org/x/sys/windows"

// enableUTF8Console 把 Windows 控制台切到 UTF-8，避免中文日志变成乱码。
func enableUTF8Console() {
	kernel32 := windows.NewLazySystemDLL("kernel32.dll")
	if p := kernel32.NewProc("SetConsoleOutputCP"); p.Find() == nil {
		p.Call(65001)
	}
	if p := kernel32.NewProc("SetConsoleCP"); p.Find() == nil {
		p.Call(65001)
	}
}
