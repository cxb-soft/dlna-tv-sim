package main

import (
	"embed"
	"net/http"
)

//go:embed web/index.html web/screen.html web/hls.min.js
var webAssets embed.FS

func serveAsset(w http.ResponseWriter, name, ctype string) {
	data, err := webAssets.ReadFile(name)
	if err != nil {
		http.NotFound(w, nil)
		return
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(data)
}

func (d *Device) handleUI(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	serveAsset(w, "web/index.html", "text/html; charset=utf-8")
}

func (d *Device) handleScreenPage(w http.ResponseWriter, r *http.Request) {
	serveAsset(w, "web/screen.html", "text/html; charset=utf-8")
}

func (d *Device) handleHLSJS(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "max-age=86400")
	data, err := webAssets.ReadFile("web/hls.min.js")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	_, _ = w.Write(data)
}
