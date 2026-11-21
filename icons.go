package main

import (
	"bytes"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"net/http"
	"strconv"
	"sync"
)

var iconCache sync.Map // size -> []byte

// iconPNG 画一个极简的电视图标：屏幕 + 底座 + 待机红灯。
// 真电视都会在描述里挂图标，控制点列表里就显示这个。
func iconPNG(size int) []byte {
	if v, ok := iconCache.Load(size); ok {
		return v.([]byte)
	}
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	fill(img, img.Bounds(), color.RGBA{0x0b, 0x0f, 0x14, 0xff})

	m := size / 8
	if m < 2 {
		m = 2
	}
	screen := image.Rect(m, m, size-m, size-m-size/6)
	if screen.Dx() > 0 && screen.Dy() > 0 {
		fill(img, screen, color.RGBA{0x07, 0x0d, 0x18, 0xff})
		for x := screen.Min.X; x < screen.Max.X; x++ {
			f := float64(x-screen.Min.X) / float64(max(1, screen.Dx()))
			c := color.RGBA{
				R: uint8(30 + 40*f),
				G: uint8(70 + 110*f),
				B: uint8(140 + 110*f),
				A: 255,
			}
			fill(img, image.Rect(x, screen.Min.Y, x+1, screen.Max.Y), c)
		}
		// 待机指示灯
		dot := size / 26
		if dot < 1 {
			dot = 1
		}
		fill(img, image.Rect(screen.Max.X-dot*2, screen.Max.Y+dot, screen.Max.X-dot, screen.Max.Y+dot*2),
			color.RGBA{0xff, 0x3b, 0x30, 0xff})
	}
	// 底座
	standW := size / 5
	standTop := size - m - size/12
	fill(img, image.Rect(size/2-standW/2, standTop, size/2+standW/2, standTop+size/18),
		color.RGBA{0x33, 0x41, 0x55, 0xff})
	fill(img, image.Rect(size/2-standW/2-size/24, standTop+size/18, size/2+standW/2+size/24, standTop+size/14),
		color.RGBA{0x22, 0x2c, 0x3a, 0xff})

	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	out := buf.Bytes()
	iconCache.Store(size, out)
	return out
}

func fill(img *image.RGBA, r image.Rectangle, c color.Color) {
	if r.Dx() <= 0 || r.Dy() <= 0 {
		return
	}
	draw.Draw(img, r, &image.Uniform{C: c}, image.Point{}, draw.Src)
}

func (d *Device) handleIcon(size int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data := iconPNG(size)
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.Header().Set("Cache-Control", "max-age=86400")
		w.Write(data)
	}
}
