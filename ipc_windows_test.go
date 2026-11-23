//go:build windows

package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var testPipeSeq atomic.Int32

// newTestMPVPipe 模拟 mpv 的 IPC 服务端（双工字节管道、重叠 I/O、4 KB 缓冲），
// 返回客户端连接（走 dialIPC，和真实路径一致）与服务端句柄。
func newTestMPVPipe(t *testing.T) (client io.ReadWriteCloser, server *os.File) {
	t.Helper()
	name := fmt.Sprintf(`\\.\pipe\dlna-tv-sim-test-%d-%d`, os.Getpid(), testPipeSeq.Add(1))
	name16, err := windows.UTF16PtrFromString(name)
	if err != nil {
		t.Fatal(err)
	}
	h, err := windows.CreateNamedPipe(name16,
		windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT,
		windows.PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatalf("CreateNamedPipe: %v", err)
	}

	client, err = dialIPC(name, 2*time.Second)
	if err != nil {
		windows.CloseHandle(h)
		t.Fatalf("dialIPC: %v", err)
	}

	// 客户端已经连上，ConnectNamedPipe 通常直接返回 ERROR_PIPE_CONNECTED。
	ev, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(ev)
	ov := windows.Overlapped{HEvent: ev}
	switch err := windows.ConnectNamedPipe(h, &ov); err {
	case nil, windows.ERROR_PIPE_CONNECTED:
	case windows.ERROR_IO_PENDING:
		if _, err := windows.WaitForSingleObject(ev, 2000); err != nil {
			t.Fatalf("ConnectNamedPipe wait: %v", err)
		}
	default:
		t.Fatalf("ConnectNamedPipe: %v", err)
	}
	server = os.NewFile(uintptr(h), name)
	t.Cleanup(func() {
		client.Close()
		server.Close()
	})
	return client, server
}

func within(t *testing.T, d time.Duration, what string, fn func() error) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- fn() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	case <-time.After(d):
		t.Fatalf("%s：%s 内没有完成（读写互相等待？）", what, d)
	}
}

// 根因检查：同步句柄（FILE_SYNCHRONOUS_IO_*）上 Windows 会把读写串行化。
// Wine 不模拟这种串行化，所以这里直接看句柄模式，而不是只靠下面的时序测试。
func TestIPCHandleIsOverlapped(t *testing.T) {
	client, _ := newTestMPVPipe(t)
	f, ok := client.(*os.File)
	if !ok {
		t.Fatalf("dialIPC 返回 %T，期望 *os.File", client)
	}
	rc, err := f.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	const fileModeInformation = 16 // FILE_INFORMATION_CLASS.FileModeInformation
	var mode uint32
	var qerr error
	if err := rc.Control(func(fd uintptr) {
		var iosb windows.IO_STATUS_BLOCK
		qerr = windows.NtQueryInformationFile(windows.Handle(fd), &iosb,
			(*byte)(unsafe.Pointer(&mode)), uint32(unsafe.Sizeof(mode)), fileModeInformation)
	}); err != nil {
		t.Fatal(err)
	}
	if qerr != nil {
		t.Fatalf("NtQueryInformationFile: %v", qerr)
	}
	if mode&(windows.FILE_SYNCHRONOUS_IO_ALERT|windows.FILE_SYNCHRONOUS_IO_NONALERT) != 0 {
		t.Fatalf("mpv 管道是同步句柄（mode=%#x）：挂着的读会挡住每一次写", mode)
	}
}

// mpv 暂停/空闲时不发任何事件。readLoop 挂着读的时候，指令必须照样立刻写出去。
func TestIPCWriteNotBlockedByPendingRead(t *testing.T) {
	client, server := newTestMPVPipe(t)

	lines := make(chan string, 8)
	go func() {
		sc := bufio.NewScanner(server)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()

	got := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(client)
		if sc.Scan() {
			got <- sc.Text()
		}
		close(got)
	}()
	time.Sleep(200 * time.Millisecond) // 让客户端的读真正挂起

	for _, cmd := range []string{
		`{"command":["set_property","pause",false]}`,
		`{"command":["stop"]}`,
		`{"command":["loadfile","http://example.invalid/next.mkv"]}`,
	} {
		within(t, 2*time.Second, "写指令", func() error {
			_, err := client.Write([]byte(cmd + "\n"))
			return err
		})
		select {
		case line := <-lines:
			if line != cmd {
				t.Fatalf("服务端收到 %q，期望 %q", line, cmd)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("服务端 2 秒内没收到 %s", cmd)
		}
	}

	// 读也照常：服务端推一条事件，挂着的读拿到它。
	ev := `{"event":"property-change","id":3,"name":"pause","data":true}`
	if _, err := server.Write([]byte(ev + "\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case line := <-got:
		if line != ev {
			t.Fatalf("客户端读到 %q，期望 %q", line, ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("客户端 2 秒内没读到事件")
	}
}

// Close：挂着读的时候发 quit 再关连接，都不能卡住，挂着的读要返回。
func TestIPCQuitAndCloseWithPendingRead(t *testing.T) {
	client, server := newTestMPVPipe(t)

	lines := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(server)
		if sc.Scan() {
			lines <- sc.Text()
		}
	}()
	readDone := make(chan error, 1)
	go func() {
		_, err := client.Read(make([]byte, 256))
		readDone <- err
	}()
	time.Sleep(200 * time.Millisecond)

	within(t, 2*time.Second, "写 quit", func() error {
		return writeIPC(client, []byte(`{"command":["quit"]}`+"\n"), time.Second)
	})
	select {
	case line := <-lines:
		if !strings.Contains(line, "quit") {
			t.Fatalf("服务端收到 %q", line)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("服务端没收到 quit")
	}
	within(t, 2*time.Second, "Close", client.Close)
	select {
	case err := <-readDone:
		if err == nil {
			t.Fatal("连接关了，挂着的读却没报错")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close 之后挂着的读没有返回")
	}
}

// mpv 整个卡死不读管道时，写指令要按超时返回，不能把调用方永远挂住。
func TestIPCWriteTimesOutWhenMPVStopsReading(t *testing.T) {
	client, _ := newTestMPVPipe(t)

	chunk := []byte(strings.Repeat("x", 1023) + "\n")
	start := time.Now()
	var err error
	for i := 0; i < 1024 && err == nil; i++ { // 最多 1 MB，远超管道缓冲
		err = writeIPC(client, chunk, 300*time.Millisecond)
	}
	if err == nil {
		t.Fatal("服务端从不读，写了 1 MB 仍然没有超时")
	}
	if !os.IsTimeout(err) {
		t.Fatalf("期望超时错误，得到 %v", err)
	}
	if el := time.Since(start); el > 5*time.Second {
		t.Fatalf("超时花了 %s", el)
	}
}
