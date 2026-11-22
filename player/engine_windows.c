/*
 * engine_windows.c — DLNA 电视模拟器 Windows 自研播放核心。
 *
 * 管线：FFmpeg 解封装 + 软解 → SDL2 纹理（D3D11 渲染后端）出画；
 * FFmpeg 解码 → swresample 转 48k 立体声 S16 → SDL2 audio（WASAPI）出声。
 * 主时钟是音频已播放采样数，视频帧按 PTS 对时钟显示；没有音轨时用墙钟。
 *
 * 线程约束（和 macOS 版一致）：
 *   pe_open / pe_run 必须在同一个进程主线程调用（SDL 窗口和事件循环）。
 *   Play/Pause/Seek/音量等控制接口可从任意 goroutine 调。
 *   pe_destroy 在所有线程退出后调用。
 *
 * 这个文件也会被 darwin/linux 的 cgo 编译到（player 包里所有 .c 都会被编译），
 * 所以整个实现包在 #ifdef _WIN32 里，其它平台得到空翻译单元。
 */
#if defined(_WIN32) || defined(PE_ENGINE_PORTABLE)

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#define SDL_MAIN_HANDLED

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>

#include <SDL.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#include "engine.h"

#ifdef _WIN32
#define PE_LOG(...) do { \
    fprintf(stderr, "[player-win] " __VA_ARGS__); fprintf(stderr, "\n"); fflush(stderr); \
    FILE *pe_lf = pe_log_file(); \
    if (pe_lf) { fprintf(pe_lf, "[player-win] " __VA_ARGS__); fprintf(pe_lf, "\n"); fflush(pe_lf); } \
} while (0)
#else
#define PE_LOG(...) do { fprintf(stderr, "[player-win] " __VA_ARGS__); fprintf(stderr, "\n"); fflush(stderr); } while (0)
#endif

#define PE_MAX_FRAMES 16
#define PE_AUDIO_RATE 48000
#define PE_AUDIO_CHANNELS 2
#define PE_AUDIO_SECONDS 4

typedef struct PeFrameNode {
    AVFrame *frame;
    double pts;
} PeFrameNode;

typedef struct PeLayout {
    int W, H;
    double ui;
    int top_h, bottom_y;
    SDL_Rect play, back, fwd, mute, volume, volume_hit;
    SDL_Rect speed, audio, sub, aspect, shot, full, close;
    SDL_Rect progress_hit;
    int bar_x, bar_y, bar_w, bar_h;
    int time_x, time_y, dur_x, dur_y;
    int title_x, title_y, device_x, device_y;
    int meta_y, row_y;
} PeLayout;

#define PE_TEXT_CACHE 32

typedef struct PeTextCache {
    SDL_Texture *tex;
    int w, h, px, weight;
    unsigned used;
    char text[192];
} PeTextCache;

enum {
    PE_CTL_NONE = 0, PE_CTL_PLAY, PE_CTL_BACK, PE_CTL_FWD, PE_CTL_PROGRESS,
    PE_CTL_MUTE, PE_CTL_VOLUME, PE_CTL_SPEED, PE_CTL_AUDIO, PE_CTL_SUB,
    PE_CTL_ASPECT, PE_CTL_SHOT, PE_CTL_FULL, PE_CTL_CLOSE
};

enum {
    PE_MENU_NONE = 0, PE_MENU_SPEED, PE_MENU_AUDIO, PE_MENU_SUB, PE_MENU_ASPECT
};

struct PePlayer {
    SDL_Window *win;
    SDL_Renderer *ren;
    SDL_Texture *tex;
    int tex_w, tex_h;
    SDL_AudioDeviceID adev;
    SDL_mutex *mu;
    SDL_Thread *th;
    int th_started, th_joined;

    AVFormatContext *fmt;
    AVCodecContext *vctx, *actx;
    int vstream, astream;
    struct SwsContext *vsws;
    struct SwsContext *shotsws;
    struct SwrContext *swr;
    int swr_rate, swr_speed;

    uint8_t *ring;
    size_t ring_cap, ring_len, ring_read;
    uint8_t *convbuf;
    size_t convbuf_cap;

    PeFrameNode frames[PE_MAX_FRAMES];
    int fhead, fcount;
    AVFrame *current;      /* 主线程持有；截图时加锁读 */
    double current_pts;
    int64_t frames_shown, frames_dropped;
    double video_pts, drift_ms, drift_avg, drift_max;
    double drift_hist[120];
    int drift_hn, drift_hi;
    double first_frame_ms;
    double first_audio_ms;
    double open_t0;
    double last_seek_ms;
    double seek_request_t0, seek_target;
    int seek_first_frame_logged;
    int64_t audio_dropped_bytes;
    double discard_before;

    char url[2048];
    char title[512];
    char device[256];
    char aspect[16];
    char vcodec[64];
    char acodec[64];
    int volume, muted, fullscreen, loop, speed_milli;
    volatile int fullscreen_req; /* 由控制线程投递，主线程真正调 SDL */
    double start_position, duration;

    int width, height, fps;
    double sar;
    int64_t start_offset;    /* fmt->start_time，单位微秒，用于把 PTS 归一化到 0 */

    volatile int stop, run_stop, closed, paused, ended, eof, io_error, buffering;
    volatile int seek_req, switch_audio_req;
    volatile int video_primed, seeking;
    double seek_pos;

    double clock_base;       /* 音频时钟基准（媒体秒） */
    double clock_mono_base;  /* 无音频 / 等待音频时的墙钟基准 */
    double audio_base_hint;  /* seek 后第一段音频的基准位置 */
    int has_audio_hint;
    double mono_wall_base;
    double clock_paused;
    int64_t clock_samples_base, audio_played;
    int audio_out_rate;
    int has_video, has_audio, audio_started;

    double last_read_ok;

    int show_controls, dragging, vol_drag;
    int hover_ctl, menu, menu_sel;
    double drag_frac, hover_frac;
    double hide_at;
    int mouse_x, mouse_y;
    int win_w, win_h;
    char toast[256];
    int toast_error;
    double toast_until;
    int shot_busy;
    char debug_capture_path[600];
    volatile int debug_capture_req;
    PeTextCache text_cache[PE_TEXT_CACHE];
    unsigned text_tick;
    double spinner_phase;

    PeTrackInfo *atracks;
    int natracks;
    PeTrackInfo *stracks;
    int nstracks;
    int want_audio_id;
    int cur_audio_id, cur_sub_id;

    int gfx_done;
    int run_started, run_returned;
};

/* ---------- 小工具 ---------- */

double pe_now(void) { return (double)av_gettime_relative() / 1000000.0; }

#ifdef _WIN32
static FILE *pe_log_file(void);
static FILE *pe_log_file(void) {
    static FILE *f = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        const char *tmp = getenv("TEMP");
        char path[600];
        if (!tmp || !tmp[0]) tmp = ".";
        snprintf(path, sizeof(path), "%s\\dlna-tv-native.log", tmp);
        f = fopen(path, "a");
    }
    return f;
}
#endif

static void pe_seterr(char *buf, int len, const char *fmt, ...) {
    if (!buf || len <= 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, (size_t)len, fmt, ap);
    va_end(ap);
}

static void pe_strdup(char *dst, size_t n, const char *src) {
    if (!dst || n == 0) return;
    if (!src) src = "";
    snprintf(dst, n, "%s", src);
}

static int pe_is_yuv420p(int fmt) {
    return fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P;
}

static double pe_frame_time(PePlayer *p, AVFrame *f, int stream_index) {
    AVStream *st = p->fmt->streams[stream_index];
    int64_t ts = f->best_effort_timestamp;
    if (ts == AV_NOPTS_VALUE) ts = f->pts;
    double t = 0;
    if (ts != AV_NOPTS_VALUE) t = (double)ts * av_q2d(st->time_base);
    if (p->start_offset > 0) t -= (double)p->start_offset / AV_TIME_BASE;
    if (t < 0) t = 0;
    return t;
}

static int pe_ring_len(PePlayer *p) {
    if (!p->adev) return 0;
    SDL_LockAudioDevice(p->adev);
    int n = (int)p->ring_len;
    SDL_UnlockAudioDevice(p->adev);
    return n;
}

/* 媒体时钟：有音频且已启动时以音频已播放采样为准，否则用墙钟。 */
static double pe_clock(PePlayer *p) {
    if (p->paused) return p->clock_paused;
    /* 起播/seek 后首帧未出：位置钉在目标，不让音频/墙钟先跑。 */
    if (p->seeking || (p->has_video && !p->video_primed)) return p->clock_base;
    double pos;
    if (p->has_audio && p->audio_started && p->adev) {
        pos = p->clock_base +
              ((double)(p->audio_played - p->clock_samples_base) / (double)p->audio_out_rate) *
                  ((double)p->speed_milli / 1000.0);
    } else {
        pos = p->clock_mono_base + (pe_now() - p->mono_wall_base) * ((double)p->speed_milli / 1000.0);
    }
    if (p->duration > 0 && pos > p->duration) pos = p->duration;
    if (pos < 0) pos = 0;
    return pos;
}

static void pe_reset_clock(PePlayer *p, double pos) {
    p->clock_base = pos;
    p->clock_samples_base = p->audio_played;
    p->clock_mono_base = pos;
    p->mono_wall_base = pe_now();
    p->clock_paused = pos;
    p->audio_started = 0;
}

static void pe_drift_add(PePlayer *p, double d) {
    p->drift_hist[p->drift_hi] = d;
    p->drift_hi = (p->drift_hi + 1) % 120;
    if (p->drift_hn < 120) p->drift_hn++;
    double sum = 0;
    for (int i = 0; i < p->drift_hn; i++) sum += p->drift_hist[i];
    p->drift_avg = sum / p->drift_hn;
    double max = 0;
    for (int i = 0; i < p->drift_hn; i++) {
        double a = fabs(p->drift_hist[i]);
        if (a > max) max = a;
    }
    p->drift_max = max;
}

static double pe_drift_p95(PePlayer *p) {
    if (p->drift_hn <= 0) return 0;
    double tmp[120];
    int n = p->drift_hn;
    for (int i = 0; i < n; i++) tmp[i] = fabs(p->drift_hist[i]);
    for (int i = 1; i < n; i++) {
        double v = tmp[i];
        int j = i - 1;
        while (j >= 0 && tmp[j] > v) { tmp[j + 1] = tmp[j]; j--; }
        tmp[j + 1] = v;
    }
    int idx = (int)(0.95 * (n - 1));
    return tmp[idx];
}

/* ---------- 音量 / 音频回调 ---------- */

static void pe_apply_gain(int16_t *dst, const uint8_t *src, int bytes, double gain) {
    int samples = bytes / 2;
    const int16_t *in = (const int16_t *)src;
    for (int i = 0; i < samples; i++) {
        int v = (int)((double)in[i] * gain);
        if (v > 32767) v = 32767;
        if (v < -32768) v = -32768;
        dst[i] = (int16_t)v;
    }
}

static void SDLCALL pe_audio_cb(void *userdata, Uint8 *stream, int len) {
    PePlayer *p = (PePlayer *)userdata;
    SDL_memset(stream, 0, (size_t)len);
    if (!p || p->stop || p->paused) return;
    if (p->seeking) return;
    int n = (int)p->ring_len;
    if (n > len) n = len;
    n -= n % (PE_AUDIO_CHANNELS * 2);
    if (n <= 0) return;

    double vol = (double)p->volume / 100.0;
    if (p->muted) vol = 0;
    if (vol < 0) vol = 0;
    if (vol > 1) vol = 1;

    int copied = 0;
    size_t r = p->ring_read;
    int16_t *dst = (int16_t *)stream;
    while (copied < n) {
        size_t chunk = p->ring_cap - r;
        if (chunk > (size_t)(n - copied)) chunk = (size_t)(n - copied);
        pe_apply_gain(dst, p->ring + r, (int)chunk, vol);
        dst += chunk / 2;
        copied += (int)chunk;
        r = (r + chunk) % p->ring_cap;
    }
    p->ring_read = r;
    p->ring_len -= (size_t)n;
    p->audio_played += n / (PE_AUDIO_CHANNELS * 2);
    if (p->first_audio_ms <= 0) {
        p->first_audio_ms = (pe_now() - p->open_t0) * 1000.0;
        PE_LOG("首音频 %.0fms（首视频 %.0fms）", p->first_audio_ms, p->first_frame_ms);
    }
}

/* ---------- 队列 / 缓冲 ---------- */

static void pe_clear_frames(PePlayer *p) {
    SDL_LockMutex(p->mu);
    for (int i = 0; i < p->fcount; i++) {
        int idx = (p->fhead + i) % PE_MAX_FRAMES;
        av_frame_free(&p->frames[idx].frame);
        p->frames[idx].pts = 0;
    }
    p->fhead = 0;
    p->fcount = 0;
    SDL_UnlockMutex(p->mu);
}

static void pe_clear_ring(PePlayer *p) {
    if (!p->adev) return;
    SDL_LockAudioDevice(p->adev);
    p->ring_len = 0;
    p->ring_read = 0;
    SDL_UnlockAudioDevice(p->adev);
}

static int pe_queue_count(PePlayer *p) {
    SDL_LockMutex(p->mu);
    int n = p->fcount;
    SDL_UnlockMutex(p->mu);
    return n;
}

/* ---------- 视频解码 ---------- */

static int pe_enqueue_video(PePlayer *p, AVFrame *f) {
    AVFrame *out = f;
    /* 必须在转格式之前取时间戳：新建的转换帧不带 pts。 */
    double pts = pe_frame_time(p, f, p->vstream);
#ifdef PE_DEBUG_PTS
    static int dbg_pts = 0;
    if (dbg_pts < 12) {
        AVStream *st = p->fmt->streams[p->vstream];
        PE_LOG("vframe#%d pts=%lld bet=%lld tb=%d/%d off=%lld fmt=%d",
               dbg_pts, (long long)f->pts, (long long)f->best_effort_timestamp,
               st->time_base.num, st->time_base.den, (long long)p->start_offset, f->format);
        dbg_pts++;
    }
#endif
    if (!pe_is_yuv420p(f->format)) {
        out = av_frame_alloc();
        if (!out) { av_frame_free(&f); return -1; }
        out->format = AV_PIX_FMT_YUV420P;
        out->width = f->width;
        out->height = f->height;
        if (av_frame_get_buffer(out, 32) < 0) { av_frame_free(&out); av_frame_free(&f); return -1; }
        p->vsws = sws_getCachedContext(p->vsws, f->width, f->height, (enum AVPixelFormat)f->format,
                                       f->width, f->height, AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
        if (!p->vsws) { av_frame_free(&out); av_frame_free(&f); return -1; }
        sws_scale(p->vsws, (const uint8_t *const *)f->data, f->linesize, 0, f->height,
                  out->data, out->linesize);
        av_frame_free(&f);
    }

    if (pts + 0.001 < p->discard_before) {
        av_frame_free(&out);
        return 0;
    }
    p->discard_before = 0;

    while (!p->stop && !p->seek_req && !p->switch_audio_req) {
        SDL_LockMutex(p->mu);
        int full = p->fcount >= PE_MAX_FRAMES;
        if (!full) {
            int idx = (p->fhead + p->fcount) % PE_MAX_FRAMES;
            p->frames[idx].frame = out;
            p->frames[idx].pts = pts;
            p->fcount++;
            if (p->width != out->width || p->height != out->height) {
                p->width = out->width;
                p->height = out->height;
            }
        }
        SDL_UnlockMutex(p->mu);
        if (!full) return 0;
        SDL_Delay(4);
    }
    av_frame_free(&out);
    return -1;
}

static int pe_receive_video(PePlayer *p) {
    for (;;) {
        AVFrame *f = av_frame_alloc();
        if (!f) return -1;
        int r = avcodec_receive_frame(p->vctx, f);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) {
            av_frame_free(&f);
            return r == AVERROR_EOF ? AVERROR_EOF : 0;
        }
        if (r < 0) {
            av_frame_free(&f);
            return r;
        }
        if (pe_enqueue_video(p, f) < 0) return AVERROR_EXIT;
    }
}

static int pe_decode_video(PePlayer *p, AVPacket *pkt) {
    int r = avcodec_send_packet(p->vctx, pkt);
    if (r == AVERROR(EAGAIN)) {
        if (pe_receive_video(p) == AVERROR_EXIT) return AVERROR_EXIT;
        r = avcodec_send_packet(p->vctx, pkt);
    }
    if (r < 0 && r != AVERROR_EOF) return r;
    if (pe_receive_video(p) == AVERROR_EXIT) return AVERROR_EXIT;
    return 0;
}

/* ---------- 音频解码 ---------- */

static int pe_build_swr(PePlayer *p, AVFrame *f) {
    int in_rate = (int)((double)f->sample_rate * ((double)p->speed_milli / 1000.0));
    if (in_rate < 1000) in_rate = 1000;
    if (p->swr && p->swr_rate == f->sample_rate && p->swr_speed == p->speed_milli) return 0;

    swr_free(&p->swr);
    AVChannelLayout outl;
    av_channel_layout_default(&outl, PE_AUDIO_CHANNELS);
    AVChannelLayout inl;
    av_channel_layout_copy(&inl, &f->ch_layout);
    int rc = swr_alloc_set_opts2(&p->swr, &outl, AV_SAMPLE_FMT_S16, p->audio_out_rate,
                                 &inl, (enum AVSampleFormat)f->format, in_rate, 0, NULL);
    av_channel_layout_uninit(&inl);
    av_channel_layout_uninit(&outl);
    if (rc < 0 || !p->swr) return -1;
    if (swr_init(p->swr) < 0) { swr_free(&p->swr); return -1; }
    p->swr_rate = f->sample_rate;
    p->swr_speed = p->speed_milli;
    return 0;
}

static int pe_append_audio(PePlayer *p, const uint8_t *data, int bytes, double pts) {
    if (!p->adev || bytes <= 0) return 0;
    while (!p->stop) {
        SDL_LockAudioDevice(p->adev);
        size_t space = p->ring_cap - p->ring_len;
        if (space >= (size_t)bytes) {
            if (!p->audio_started && (!p->has_video || p->video_primed)) {
                double base = pts;
                if (p->has_audio_hint) {
                    if (fabs(pts - p->audio_base_hint) > 0.15) base = p->audio_base_hint;
                    p->has_audio_hint = 0;
                }
                p->clock_base = base;
                p->clock_samples_base = p->audio_played;
                p->clock_mono_base = base;
                p->mono_wall_base = pe_now();
                p->audio_started = 1;
                p->seeking = 0;
                if (!p->has_video) p->buffering = 0;
                if (!p->paused) SDL_PauseAudioDevice(p->adev, 0);
            }
            size_t w = (p->ring_read + p->ring_len) % p->ring_cap;
            size_t first = p->ring_cap - w;
            if (first > (size_t)bytes) first = (size_t)bytes;
            memcpy(p->ring + w, data, first);
            if ((size_t)bytes > first) memcpy(p->ring, data + first, (size_t)bytes - first);
            p->ring_len += (size_t)bytes;
            SDL_UnlockAudioDevice(p->adev);
            return 0;
        }
        SDL_UnlockAudioDevice(p->adev);
        if (p->seek_req || p->switch_audio_req) return 0;
        /* 视频队列见底时优先让解复用继续走；宁可丢这包音频，避免黑屏/seek 卡住。 */
        if (p->has_video && (!p->video_primed || p->fcount < 4)) {
            p->audio_dropped_bytes += bytes;
            return 0;
        }
        SDL_Delay(5);
    }
    return -1;
}

static int pe_receive_audio(PePlayer *p) {
    for (;;) {
        AVFrame *f = av_frame_alloc();
        if (!f) return -1;
        int r = avcodec_receive_frame(p->actx, f);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) {
            av_frame_free(&f);
            return r == AVERROR_EOF ? AVERROR_EOF : 0;
        }
        if (r < 0) { av_frame_free(&f); return r; }
        if (pe_build_swr(p, f) < 0) { av_frame_free(&f); continue; }

        int in_rate = (int)((double)f->sample_rate * ((double)p->speed_milli / 1000.0));
        if (in_rate < 1000) in_rate = 1000;
        int64_t delay = swr_get_delay(p->swr, in_rate);
        int out_max = (int)av_rescale_rnd(delay + f->nb_samples, p->audio_out_rate, in_rate, AV_ROUND_UP);
        if (out_max < 1) out_max = 1;
        size_t need = (size_t)out_max * PE_AUDIO_CHANNELS * 2;
        if (need > p->convbuf_cap) {
            uint8_t *nb = (uint8_t *)realloc(p->convbuf, need);
            if (!nb) { av_frame_free(&f); return -1; }
            p->convbuf = nb;
            p->convbuf_cap = need;
        }
        uint8_t *outp = p->convbuf;
        int got = swr_convert(p->swr, &outp, out_max,
                              (const uint8_t **)f->extended_data, f->nb_samples);
        double pts = pe_frame_time(p, f, p->astream);
        av_frame_free(&f);
        if (got > 0) {
            if (pe_append_audio(p, p->convbuf, got * PE_AUDIO_CHANNELS * 2, pts) < 0) {
                return AVERROR_EXIT;
            }
        }
    }
}

static int pe_decode_audio(PePlayer *p, AVPacket *pkt) {
    int r = avcodec_send_packet(p->actx, pkt);
    if (r == AVERROR(EAGAIN)) {
        pe_receive_audio(p);
        r = avcodec_send_packet(p->actx, pkt);
    }
    if (r < 0 && r != AVERROR_EOF) return r;
    return pe_receive_audio(p);
}

/* ---------- seek / 音轨切换 ---------- */

static void pe_do_seek(PePlayer *p, double target) {
    if (p->duration > 0 && target > p->duration) target = p->duration;
    if (target < 0) target = 0;
    double t0 = pe_now();
    p->video_primed = p->has_video ? 0 : 1;
    p->seeking = 1;
    p->audio_started = 0;
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
    p->seek_target = target;
    if (p->seek_request_t0 <= 0) p->seek_request_t0 = pe_now();
    p->seek_first_frame_logged = 0;

    int64_t ts = (int64_t)((target + (double)p->start_offset / AV_TIME_BASE) * AV_TIME_BASE);
    if (av_seek_frame(p->fmt, -1, ts, AVSEEK_FLAG_BACKWARD) < 0) {
        PE_LOG("seek %.2f 失败", target);
    }
    if (p->vctx) avcodec_flush_buffers(p->vctx);
    if (p->actx) avcodec_flush_buffers(p->actx);
    pe_clear_frames(p);
    pe_clear_ring(p);
    if (p->swr) {
        swr_free(&p->swr);
        p->swr_rate = 0;
        p->swr_speed = 0;
    }

    p->discard_before = target - 0.05;
    if (p->discard_before < 0) p->discard_before = 0;
    p->audio_base_hint = target;
    p->has_audio_hint = p->has_audio ? 1 : 0;
    p->ended = 0;
    p->eof = 0;
    p->io_error = 0;
    p->buffering = 1;
    p->video_pts = target;
    if (p->paused) {
        p->clock_paused = target;
        p->clock_base = target;
        p->clock_samples_base = p->audio_played;
        p->clock_mono_base = target;
        p->mono_wall_base = pe_now();
        p->audio_started = 0;
    } else {
        pe_reset_clock(p, target);
    }
    p->last_seek_ms = (pe_now() - t0) * 1000.0;
    p->last_read_ok = pe_now();
    PE_LOG("seek %.2f 完成 %.0fms", target, p->last_seek_ms);
}

static int pe_open_audio_codec(PePlayer *p, int id) {
    if (p->actx) { avcodec_free_context(&p->actx); p->actx = NULL; }
    if (p->swr) { swr_free(&p->swr); }
    p->swr_rate = 0;
    p->swr_speed = 0;
    p->astream = -1;
    p->cur_audio_id = 0;
    if (id <= 0 || id > p->natracks) return 0;
    int idx = p->atracks[id - 1].stream_index;
    AVStream *st = p->fmt->streams[idx];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        PE_LOG("音轨 %d 没有可用解码器（%s）", id, avcodec_get_name(st->codecpar->codec_id));
        return -1;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return -1;
    if (avcodec_parameters_to_context(ctx, st->codecpar) < 0 || avcodec_open2(ctx, codec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return -1;
    }
    ctx->pkt_timebase = st->time_base;
    p->actx = ctx;
    p->astream = idx;
    p->cur_audio_id = id;
    p->has_audio = 1;
    return 0;
}

static void pe_switch_audio(PePlayer *p) {
    double pos = pe_clock(p);
    if (p->actx) { avcodec_flush_buffers(p->actx); }
    pe_clear_ring(p);
    if (pe_open_audio_codec(p, p->want_audio_id) < 0) {
        PE_LOG("切换到音轨 %d 失败，继续用当前音轨", p->want_audio_id);
    }
    p->audio_started = 0;
    p->seek_req = 1;
    p->seek_pos = pos;
    p->switch_audio_req = 0;
}

/* ---------- 打开媒体 ---------- */

static int pe_interrupt_cb(void *opaque) {
    PePlayer *p = (PePlayer *)opaque;
    if (!p) return 0;
    if (p->stop || p->run_stop) return 1;
    if (p->seek_req || p->switch_audio_req) return 1;
    if (p->last_read_ok > 0 && pe_now() - p->last_read_ok > 20.0) return 1;
    return 0;
}

static int pe_copy_track(PeTrackInfo *dst, AVStream *st, int id, int ordinal) {
    memset(dst, 0, sizeof(*dst));
    dst->id = id;
    dst->stream_index = st->index;
    if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        dst->channels = st->codecpar->ch_layout.nb_channels;
    }
    const AVDictionaryEntry *e;
    if ((e = av_dict_get(st->metadata, "language", NULL, 0))) pe_strdup(dst->lang, sizeof(dst->lang), e->value);
    if ((e = av_dict_get(st->metadata, "title", NULL, 0))) pe_strdup(dst->title, sizeof(dst->title), e->value);
    if (dst->title[0] == 0) {
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            snprintf(dst->title, sizeof(dst->title), "音轨 %d", ordinal + 1);
        } else {
            snprintf(dst->title, sizeof(dst->title), "字幕 %d", ordinal + 1);
        }
    }
    pe_strdup(dst->codec, sizeof(dst->codec), avcodec_get_name(st->codecpar->codec_id));
    return 0;
}

static void pe_build_tracks(PePlayer *p) {
    p->natracks = 0;
    p->nstracks = 0;
    for (unsigned i = 0; i < p->fmt->nb_streams; i++) {
        AVStream *st = p->fmt->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) p->natracks++;
        else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) p->nstracks++;
    }
    if (p->natracks > 0) {
        p->atracks = (PeTrackInfo *)calloc((size_t)p->natracks, sizeof(PeTrackInfo));
    }
    if (p->nstracks > 0) {
        p->stracks = (PeTrackInfo *)calloc((size_t)p->nstracks, sizeof(PeTrackInfo));
    }
    int ai = 0, si = 0;
    for (unsigned i = 0; i < p->fmt->nb_streams; i++) {
        AVStream *st = p->fmt->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && p->atracks) {
            pe_copy_track(&p->atracks[ai], st, ai + 1, ai);
            ai++;
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && p->stracks) {
            pe_copy_track(&p->stracks[si], st, si + 1, si);
            si++;
        }
    }
}

static void pe_fill_video_info(PePlayer *p) {
    if (p->vstream < 0) return;
    AVStream *st = p->fmt->streams[p->vstream];
    p->width = st->codecpar->width;
    p->height = st->codecpar->height;
    AVRational fr = st->avg_frame_rate;
    if (fr.num <= 0 || fr.den <= 0) fr = st->r_frame_rate;
    if (fr.num > 0 && fr.den > 0) p->fps = (int)((double)fr.num / fr.den + 0.5);
    AVRational sar = st->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0) sar = st->codecpar->sample_aspect_ratio;
    p->sar = (sar.num > 0 && sar.den > 0) ? (double)sar.num / sar.den : 1.0;
    pe_strdup(p->vcodec, sizeof(p->vcodec), avcodec_get_name(st->codecpar->codec_id));
    if (st->duration != AV_NOPTS_VALUE && st->duration > 0) {
        double d = (double)st->duration * av_q2d(st->time_base);
        if (d > 0) p->duration = d;
    }
}

/* ---------- 媒体线程 ---------- */

static void pe_flush_decoders(PePlayer *p) {
    if (p->vctx) {
        avcodec_send_packet(p->vctx, NULL);
        pe_receive_video(p);
    }
    if (p->actx) {
        avcodec_send_packet(p->actx, NULL);
        pe_receive_audio(p);
    }
}

static void pe_handle_eof(PePlayer *p) {
    p->eof = 1;
    pe_flush_decoders(p);
    for (int i = 0; i < 3000 && !p->stop; i++) {
        if (p->seek_req || p->switch_audio_req) return;
        int fc = pe_queue_count(p);
        int al = pe_ring_len(p);
        if (fc == 0 && al < p->audio_out_rate * 4 / 10) break;
        if (p->paused) break;
        SDL_Delay(10);
    }
    if (p->stop || p->seek_req) return;
    if (p->loop) {
        p->seek_req = 1;
        p->seek_pos = 0;
        return;
    }
    p->ended = 1;
    p->buffering = 0;
    p->video_pts = p->duration > 0 ? p->duration : p->video_pts;
    if (p->duration > 0) p->clock_paused = p->duration;
    PE_LOG("播放结束（约 %.1f 秒）", p->duration);
}

static int SDLCALL pe_media_thread(void *ud) {
    PePlayer *p = (PePlayer *)ud;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return -1;
    while (!p->stop) {
        if (p->switch_audio_req) pe_switch_audio(p);
        if (p->seek_req) {
            double t = p->seek_pos;
            p->seek_req = 0;
            pe_do_seek(p, t);
        }
        if (p->ended) { SDL_Delay(10); continue; }

        if (p->has_video && pe_queue_count(p) >= PE_MAX_FRAMES) { SDL_Delay(4); continue; }
        if (p->has_audio && p->adev && p->video_primed && p->fcount >= 4) {
            int al = pe_ring_len(p);
            if ((size_t)al > p->ring_cap * 3 / 4) { SDL_Delay(4); continue; }
        }

        p->last_read_ok = pe_now();
        int r = av_read_frame(p->fmt, pkt);
        if (r < 0) {
            av_packet_unref(pkt);
            if (p->stop) break;
            if (p->seek_req || p->switch_audio_req) continue;
            if (r == AVERROR(EAGAIN)) { SDL_Delay(10); continue; }
            if (r == AVERROR_EOF) { pe_handle_eof(p); if (p->loop) continue; continue; }
            char eb[128] = {0};
            av_strerror(r, eb, sizeof(eb));
            PE_LOG("读流中断：%s", eb);
            p->io_error = 1;
            p->ended = 1;
            p->buffering = 0;
            continue;
        }

        if (p->vstream >= 0 && pkt->stream_index == p->vstream) {
            int dr = pe_decode_video(p, pkt);
            if (dr == AVERROR_EXIT) { av_packet_unref(pkt); break; }
        } else if (p->astream >= 0 && pkt->stream_index == p->astream) {
            int dr = pe_decode_audio(p, pkt);
            if (dr == AVERROR_EXIT) { av_packet_unref(pkt); break; }
        } else if (p->astream < 0 && p->has_audio) {
            /* 正在切音轨的空档：丢弃旧音轨的包 */
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    PE_LOG("媒体线程退出");
    return 0;
}

/* ---------- 打开 / 关闭 ---------- */

static int p_sdl_users = 0;

static int pe_sdl_init(char *errbuf, int errlen) {
    if (p_sdl_users > 0) { p_sdl_users++; return 0; }
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER | SDL_INIT_EVENTS) < 0) {
        pe_seterr(errbuf, errlen, "SDL 初始化失败：%s", SDL_GetError());
        return -1;
    }
    p_sdl_users = 1;
    return 0;
}

static void pe_sdl_quit(void) {
    if (p_sdl_users <= 0) return;
    p_sdl_users--;
    if (p_sdl_users == 0) SDL_Quit();
}

PePlayer *pe_open(const PeConfig *cfg, char *errbuf, int errlen) {
    if (errbuf && errlen > 0) errbuf[0] = 0;
    if (!cfg || !cfg->url || !cfg->url[0]) {
        pe_seterr(errbuf, errlen, "播放地址为空");
        return NULL;
    }
    if (pe_sdl_init(errbuf, errlen) < 0) return NULL;

    PePlayer *p = (PePlayer *)calloc(1, sizeof(PePlayer));
    if (!p) { pe_sdl_quit(); pe_seterr(errbuf, errlen, "内存不足"); return NULL; }
    p->mu = SDL_CreateMutex();
    if (!p->mu) { free(p); pe_sdl_quit(); pe_seterr(errbuf, errlen, "创建互斥锁失败"); return NULL; }

    pe_strdup(p->url, sizeof(p->url), cfg->url);
    pe_strdup(p->title, sizeof(p->title), cfg->title && cfg->title[0] ? cfg->title : cfg->url);
    pe_strdup(p->device, sizeof(p->device), cfg->device_name);
    pe_strdup(p->aspect, sizeof(p->aspect), cfg->aspect && cfg->aspect[0] ? cfg->aspect : "auto");
    p->volume = cfg->volume < 0 ? 0 : (cfg->volume > 100 ? 100 : cfg->volume);
    p->muted = cfg->muted ? 1 : 0;
    p->fullscreen = cfg->fullscreen ? 1 : 0;
    p->loop = cfg->loop ? 1 : 0;
    p->speed_milli = (int)((cfg->speed > 0.05 ? cfg->speed : 1.0) * 1000.0);
    if (p->speed_milli < 250) p->speed_milli = 250;
    if (p->speed_milli > 4000) p->speed_milli = 4000;
    p->start_position = cfg->start_position > 0 ? cfg->start_position : 0;
    p->audio_out_rate = PE_AUDIO_RATE;
    p->want_audio_id = cfg->audio_track;
    p->vstream = -1;
    p->astream = -1;
    p->open_t0 = pe_now();
    pe_reset_clock(p, p->start_position);

    int w = cfg->width > 0 ? cfg->width : 1280;
    int h = cfg->height > 0 ? cfg->height : 720;
    Uint32 flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
    if (p->fullscreen) flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    p->win = SDL_CreateWindow(p->title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, w, h, flags);
    if (!p->win) {
        pe_seterr(errbuf, errlen, "创建窗口失败：%s", SDL_GetError());
        goto fail;
    }
    p->ren = SDL_CreateRenderer(p->win, -1, SDL_RENDERER_ACCELERATED);
    if (!p->ren) {
        p->ren = SDL_CreateRenderer(p->win, -1, SDL_RENDERER_SOFTWARE);
    }
    if (!p->ren) {
        pe_seterr(errbuf, errlen, "创建渲染器失败：%s", SDL_GetError());
        goto fail;
    }
    SDL_SetRenderDrawBlendMode(p->ren, SDL_BLENDMODE_BLEND);
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");

    p->fmt = avformat_alloc_context();
    if (!p->fmt) { pe_seterr(errbuf, errlen, "分配解封装上下文失败"); goto fail; }
    p->fmt->interrupt_callback.callback = pe_interrupt_cb;
    p->fmt->interrupt_callback.opaque = p;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rw_timeout", "15000000", 0);
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_delay_max", "3", 0);
    if (cfg->user_agent && cfg->user_agent[0]) av_dict_set(&opts, "user_agent", cfg->user_agent, 0);
    if (cfg->referer && cfg->referer[0]) av_dict_set(&opts, "referer", cfg->referer, 0);

    p->last_read_ok = pe_now();
    int rc = avformat_open_input(&p->fmt, p->url, NULL, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        char eb[128] = {0};
        av_strerror(rc, eb, sizeof(eb));
        pe_seterr(errbuf, errlen, "打不开媒体：%s", eb);
        goto fail;
    }
    if (avformat_find_stream_info(p->fmt, NULL) < 0) {
        pe_seterr(errbuf, errlen, "读取媒体信息失败");
        goto fail;
    }
    if (p->fmt->start_time != AV_NOPTS_VALUE) p->start_offset = p->fmt->start_time;
    if (p->fmt->duration != AV_NOPTS_VALUE && p->fmt->duration > 0) {
        p->duration = (double)p->fmt->duration / AV_TIME_BASE;
    }

    int vidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vidx >= 0) {
        AVStream *st = p->fmt->streams[vidx];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (codec) {
            AVCodecContext *ctx = avcodec_alloc_context3(codec);
            if (ctx && avcodec_parameters_to_context(ctx, st->codecpar) >= 0 &&
                avcodec_open2(ctx, codec, NULL) >= 0) {
                ctx->pkt_timebase = st->time_base;
                p->vctx = ctx;
                p->vstream = vidx;
                p->has_video = 1;
                pe_strdup(p->vcodec, sizeof(p->vcodec), avcodec_get_name(st->codecpar->codec_id));
            } else if (ctx) {
                avcodec_free_context(&ctx);
            }
        }
    }
    pe_build_tracks(p);

    if (p->natracks > 0) {
        int want = p->want_audio_id;
        if (want <= 0 || want > p->natracks) {
            int aidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
            want = 1;
            for (int i = 0; i < p->natracks; i++) {
                if (p->atracks[i].stream_index == aidx) { want = i + 1; break; }
            }
        }
        if (pe_open_audio_codec(p, want) == 0) {
            int rates[2] = {PE_AUDIO_RATE, 44100};
            for (int ri = 0; ri < 2 && !p->adev; ri++) {
                SDL_AudioSpec want_spec, have;
                SDL_zero(want_spec);
                want_spec.freq = rates[ri];
                want_spec.format = AUDIO_S16SYS;
                want_spec.channels = PE_AUDIO_CHANNELS;
                want_spec.samples = 1024;
                want_spec.callback = pe_audio_cb;
                want_spec.userdata = p;
                p->adev = SDL_OpenAudioDevice(NULL, 0, &want_spec, &have, 0);
                if (p->adev) {
                    p->audio_out_rate = have.freq > 0 ? have.freq : rates[ri];
                    p->ring_cap = (size_t)p->audio_out_rate * PE_AUDIO_CHANNELS * 2 * PE_AUDIO_SECONDS;
                    p->ring = (uint8_t *)malloc(p->ring_cap);
                    if (!p->ring) {
                        SDL_CloseAudioDevice(p->adev);
                        p->adev = 0;
                        p->ring_cap = 0;
                    } else {
                        /* 有视频时等首帧显示再开声；纯音频立即开声。 */
                        SDL_PauseAudioDevice(p->adev, p->has_video ? 1 : 0);
                    }
                }
            }
            if (!p->adev) {
                PE_LOG("音频设备打开失败，先只出画面：%s", SDL_GetError());
                p->has_audio = 0;
            }
        } else {
            p->has_audio = 0;
        }
    }
    pe_fill_video_info(p);
    if (!p->has_video && !p->has_audio) {
        pe_seterr(errbuf, errlen, "这个媒体没有可解码的音视频流");
        goto fail;
    }
    p->buffering = 1;
    p->video_primed = p->has_video ? 0 : 1;
    p->clock_base = p->start_position;
    p->clock_samples_base = p->audio_played;
    p->clock_mono_base = p->start_position;
    p->mono_wall_base = pe_now();
    p->clock_paused = p->start_position;
    p->seeking = p->start_position > 0 ? 1 : 0;
    p->seek_target = p->start_position;
    p->seek_request_t0 = p->start_position > 0 ? pe_now() : 0;
    if (p->start_position > 0) {
        p->seek_req = 1;
        p->seek_pos = p->start_position;
    }

    p->th = SDL_CreateThread(pe_media_thread, "pe-media", p);
    if (!p->th) {
        pe_seterr(errbuf, errlen, "创建媒体线程失败：%s", SDL_GetError());
        goto fail;
    }
    p->th_started = 1;
    PE_LOG("打开成功：%s（视频=%d 音频=%d %.1fs）", p->url, p->has_video, p->has_audio, p->duration);
    return p;

fail:
    if (p->th_started) { p->stop = 1; SDL_WaitThread(p->th, NULL); p->th_started = 0; }
    if (p->adev) { SDL_CloseAudioDevice(p->adev); p->adev = 0; }
    if (p->vctx) avcodec_free_context(&p->vctx);
    if (p->actx) avcodec_free_context(&p->actx);
    if (p->fmt) avformat_close_input(&p->fmt);
    if (p->vsws) sws_freeContext(p->vsws);
    if (p->shotsws) sws_freeContext(p->shotsws);
    if (p->swr) swr_free(&p->swr);
    if (p->tex) SDL_DestroyTexture(p->tex);
    if (p->ren) SDL_DestroyRenderer(p->ren);
    if (p->win) SDL_DestroyWindow(p->win);
    free(p->atracks);
    free(p->stracks);
    free(p->ring);
    free(p->convbuf);
    SDL_DestroyMutex(p->mu);
    free(p);
    pe_sdl_quit();
    return NULL;
}

/* ---------- 控制接口 ---------- */

void pe_play(PePlayer *p) {
    if (!p) return;
    if (p->ended) {
        p->seek_req = 1;
        p->seek_pos = 0;
        p->ended = 0;
    }
    if (!p->paused) return;
    p->paused = 0;
    p->clock_base = p->clock_paused;
    p->clock_samples_base = p->audio_played;
    p->clock_mono_base = p->clock_paused;
    p->mono_wall_base = pe_now();
    if (p->adev && (!p->has_video || p->video_primed))
        SDL_PauseAudioDevice(p->adev, 0);
}

void pe_pause(PePlayer *p) {
    if (!p || p->paused) return;
    p->clock_paused = pe_clock(p);
    p->paused = 1;
    p->clock_base = p->clock_paused;
    p->clock_samples_base = p->audio_played;
    p->clock_mono_base = p->clock_paused;
    p->mono_wall_base = pe_now();
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
}

void pe_toggle_pause(PePlayer *p) {
    if (!p) return;
    if (p->ended) { pe_play(p); return; }
    if (p->paused) pe_play(p);
    else pe_pause(p);
}

void pe_restart(PePlayer *p) {
    if (!p) return;
    p->ended = 0;
    p->seek_req = 1;
    p->seek_pos = 0;
    pe_play(p);
}

void pe_stop(PePlayer *p) {
    if (!p) return;
    p->ended = 0;
    p->paused = 1;
    p->clock_paused = 0;
    p->seek_req = 1;
    p->seek_pos = 0;
    pe_clear_frames(p);
    pe_clear_ring(p);
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
}

void pe_seek(PePlayer *p, double seconds) {
    if (!p) return;
    double target = seconds;
    if (p->duration > 0 && target > p->duration) target = p->duration;
    if (target < 0) target = 0;
    p->seek_pos = target;
    p->seek_target = target;
    p->seek_request_t0 = pe_now();
    p->seek_first_frame_logged = 0;
    p->seek_req = 1;
    p->seeking = 1;
    p->video_primed = p->has_video ? 0 : 1;
    p->ended = 0;
    p->eof = 0;
    p->io_error = 0;
    p->buffering = 1;
    p->audio_started = 0;
    p->clock_base = target;
    p->clock_samples_base = p->audio_played;
    p->clock_mono_base = target;
    p->mono_wall_base = pe_now();
    p->clock_paused = target;
    p->video_pts = target;
    p->discard_before = target - 0.05;
    if (p->discard_before < 0) p->discard_before = 0;
    p->audio_base_hint = target;
    p->has_audio_hint = p->has_audio ? 1 : 0;
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
    pe_clear_frames(p);
    pe_clear_ring(p);
    PE_LOG("seek 请求 %.2f", target);
}

void pe_seek_relative(PePlayer *p, double delta) {
    if (!p) return;
    double pos = pe_clock(p) + delta;
    if (pos < 0) pos = 0;
    if (p->duration > 0 && pos > p->duration) pos = p->duration;
    pe_seek(p, pos);
}

void pe_set_volume(PePlayer *p, int volume) {
    if (!p) return;
    if (volume < 0) volume = 0;
    if (volume > 100) volume = 100;
    p->volume = volume;
}

int pe_get_volume(PePlayer *p) { return p ? p->volume : 0; }

void pe_set_mute(PePlayer *p, int muted) {
    if (p) p->muted = muted ? 1 : 0;
}

int pe_get_mute(PePlayer *p) { return p ? p->muted : 0; }

void pe_set_fullscreen(PePlayer *p, int on) {
    if (!p) return;
    p->fullscreen = on ? 1 : 0;
    p->fullscreen_req = on ? 1 : -1;
}

void pe_toggle_fullscreen(PePlayer *p) {
    if (p) pe_set_fullscreen(p, !p->fullscreen);
}

void pe_close_window(PePlayer *p) {
    if (!p) return;
    p->closed = 1;
    p->run_stop = 1;
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = SDL_QUIT;
    SDL_PushEvent(&ev);
}

void pe_get_status(PePlayer *p, PeStatus *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!p) return;
    double pos = pe_clock(p);
    if (p->ended && p->duration > 0) pos = p->duration;
    out->position = pos;
    out->duration = p->duration;
    out->clock = pos;
    out->video_pts = p->video_pts;
    out->drift_ms = p->drift_ms;
    out->drift_avg_ms = p->drift_avg;
    out->drift_p95_ms = pe_drift_p95(p);
    out->drift_max_ms = p->drift_max;
    out->frames_shown = p->frames_shown;
    out->frames_dropped = p->frames_dropped;
    out->first_frame_ms = p->first_frame_ms;
    out->last_seek_ms = p->last_seek_ms;
    out->cpu_percent = 0;
    int al = p->stop ? 0 : pe_ring_len(p);
    double buffered = (double)al / (double)(PE_AUDIO_CHANNELS * 2 * p->audio_out_rate) * 1000.0;
    if (p->fps > 0) buffered += (double)pe_queue_count(p) * (1000.0 / p->fps) / 2.0;
    out->buffered_ms = buffered;
    SDL_LockMutex(p->mu);
    out->width = p->width;
    out->height = p->height;
    out->fps = p->fps;
    SDL_UnlockMutex(p->mu);
    out->paused = p->paused;
    out->ended = p->ended;
    out->closed = p->closed;
    out->fullscreen = p->fullscreen;
    out->hardware_decode = 0;
    out->has_video = p->has_video;
    out->has_audio = p->has_audio;
    out->volume = p->volume;
    out->muted = p->muted;
    out->window_number = p->win ? (int)SDL_GetWindowID(p->win) : 0;
    out->speed = (double)p->speed_milli / 1000.0;
    out->loop = p->loop;
    pe_strdup(out->aspect, sizeof(out->aspect), p->aspect);
    out->audio_track = p->cur_audio_id;
    out->subtitle_track = p->cur_sub_id;
    out->audio_tracks = p->natracks;
    out->subtitle_tracks = p->nstracks;
    out->buffering = p->buffering;
    out->io_error = p->io_error;
}

const char *pe_video_codec(PePlayer *p) { return p ? p->vcodec : ""; }
const char *pe_audio_codec(PePlayer *p) { return p ? p->acodec : ""; }
const char *pe_hwdevice_name(PePlayer *p) { (void)p; return "none"; }
int pe_window_number(PePlayer *p) { return p && p->win ? (int)SDL_GetWindowID(p->win) : 0; }

const char *pe_ffmpeg_version(void) { return av_version_info(); }

void pe_set_speed(PePlayer *p, double speed) {
    if (!p) return;
    if (speed < 0.25) speed = 0.25;
    if (speed > 4.0) speed = 4.0;
    double pos = pe_clock(p);
    p->clock_base = pos;
    p->clock_samples_base = p->audio_played;
    p->clock_mono_base = pos;
    p->mono_wall_base = pe_now();
    p->clock_paused = p->paused ? pos : p->clock_paused;
    p->speed_milli = (int)(speed * 1000.0);
}

double pe_get_speed(PePlayer *p) { return p ? (double)p->speed_milli / 1000.0 : 1.0; }

void pe_set_loop(PePlayer *p, int on) { if (p) p->loop = on ? 1 : 0; }
int pe_get_loop(PePlayer *p) { return p ? p->loop : 0; }

void pe_set_aspect(PePlayer *p, const char *aspect) {
    if (!p || !aspect) return;
    pe_strdup(p->aspect, sizeof(p->aspect), aspect);
}

const char *pe_get_aspect(PePlayer *p) { return p ? p->aspect : "auto"; }

int pe_audio_track_count(PePlayer *p) { return p ? p->natracks : 0; }

int pe_audio_track_info(PePlayer *p, int ordinal, PeTrackInfo *out) {
    if (!p || !out || ordinal < 0 || ordinal >= p->natracks) return -1;
    *out = p->atracks[ordinal];
    return 0;
}

int pe_subtitle_track_count(PePlayer *p) { return p ? p->nstracks : 0; }

int pe_subtitle_track_info(PePlayer *p, int ordinal, PeTrackInfo *out) {
    if (!p || !out || ordinal < 0 || ordinal >= p->nstracks) return -1;
    *out = p->stracks[ordinal];
    return 0;
}

void pe_set_audio_track(PePlayer *p, int id) {
    if (!p || id < 0 || id > p->natracks) return;
    if (id == p->cur_audio_id) return;
    if (id == 0) {
        /* id 0 表示关掉音频：暂不支持，忽略 */
        return;
    }
    p->want_audio_id = id;
    p->switch_audio_req = 1;
}

void pe_set_subtitle_track(PePlayer *p, int id) {
    if (!p || id < 0 || id > p->nstracks) return;
    p->cur_sub_id = id;
}

int pe_get_audio_track(PePlayer *p) { return p ? p->cur_audio_id : 0; }
int pe_get_subtitle_track(PePlayer *p) { return p ? p->cur_sub_id : 0; }

int pe_get_subtitle_text(PePlayer *p, char *buf, int len) {
    (void)p;
    if (buf && len > 0) buf[0] = 0;
    return 0;
}

void *pe_copy_subtitle_image(PePlayer *p) { (void)p; return NULL; }

const char *pe_title(PePlayer *p) { return p ? p->title : ""; }
const char *pe_device_name(PePlayer *p) { return p ? p->device : ""; }

/* ---------- 截图 ---------- */

int pe_screenshot(PePlayer *p, const char *path, char *errbuf, int errlen) {
    if (errbuf && errlen > 0) errbuf[0] = 0;
    if (!p || !path) return -1;
    SDL_LockMutex(p->mu);
    AVFrame *src = p->current ? av_frame_clone(p->current) : NULL;
    SDL_UnlockMutex(p->mu);
    if (!src) { pe_seterr(errbuf, errlen, "还没有可截图的画面"); return -1; }

    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_PNG);
    if (!codec) { av_frame_free(&src); pe_seterr(errbuf, errlen, "FFmpeg 没有 PNG 编码器"); return -1; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) { av_frame_free(&src); pe_seterr(errbuf, errlen, "分配编码器失败"); return -1; }
    ctx->width = src->width;
    ctx->height = src->height;
    ctx->pix_fmt = AV_PIX_FMT_RGBA;
    ctx->time_base = (AVRational){1, 25};
    if (avcodec_open2(ctx, codec, NULL) < 0) {
        avcodec_free_context(&ctx);
        av_frame_free(&src);
        pe_seterr(errbuf, errlen, "打开 PNG 编码器失败");
        return -1;
    }
    AVFrame *rgba = av_frame_alloc();
    rgba->format = AV_PIX_FMT_RGBA;
    rgba->width = src->width;
    rgba->height = src->height;
    if (av_frame_get_buffer(rgba, 32) < 0) {
        avcodec_free_context(&ctx);
        av_frame_free(&src);
        av_frame_free(&rgba);
        pe_seterr(errbuf, errlen, "分配截图缓冲失败");
        return -1;
    }
    p->shotsws = sws_getCachedContext(p->shotsws, src->width, src->height, (enum AVPixelFormat)src->format,
                                      src->width, src->height, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!p->shotsws) {
        avcodec_free_context(&ctx);
        av_frame_free(&src);
        av_frame_free(&rgba);
        pe_seterr(errbuf, errlen, "创建截图缩放器失败");
        return -1;
    }
    sws_scale(p->shotsws, (const uint8_t *const *)src->data, src->linesize, 0, src->height,
              rgba->data, rgba->linesize);
    int rc = avcodec_send_frame(ctx, rgba);
    SDL_RWops *rw = NULL;
    if (rc >= 0) {
        /* SDL_RWFromFile 按 UTF-8 打开，Windows 中文路径也能写。 */
        rw = SDL_RWFromFile(path, "wb");
        if (!rw) rc = -1;
    }
    AVPacket *pkt = av_packet_alloc();
    while (rc >= 0 && avcodec_receive_packet(ctx, pkt) == 0) {
        if (SDL_RWwrite(rw, pkt->data, 1, (size_t)pkt->size) != (size_t)pkt->size) rc = -1;
        av_packet_unref(pkt);
    }
    if (rw && SDL_RWclose(rw) < 0) rc = -1;
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    av_frame_free(&src);
    av_frame_free(&rgba);
    if (rc < 0) pe_seterr(errbuf, errlen, "写截图失败");
    return rc < 0 ? -1 : 0;
}

/* ---------- 主线程：渲染与事件 ---------- */

#define PE_PI 3.14159265358979323846
#ifndef FW_SEMIBOLD
#define FW_SEMIBOLD 600
#endif
#ifndef FW_NORMAL
#define FW_NORMAL 400
#endif

static const uint32_t kUiBg = 0x0E1014;
static const uint32_t kUiPanel = 0x121418;
static const uint32_t kUiPanelAlt = 0x171A1F;
static const uint32_t kUiText = 0xE9EBEF;
static const uint32_t kUiTextDim = 0x9AA1AC;
static const uint32_t kUiAmber = 0xEBB15D;
static const uint32_t kUiAccentTop = 0xF2C27C;
static const uint32_t kUiAccentBottom = 0xD99447;
static const uint32_t kUiRed = 0xF0655E;

static SDL_Color pe_col(uint32_t rgb, Uint8 a) {
    SDL_Color c;
    c.r = (Uint8)((rgb >> 16) & 255);
    c.g = (Uint8)((rgb >> 8) & 255);
    c.b = (Uint8)(rgb & 255);
    c.a = a;
    return c;
}

static void pe_setc(SDL_Renderer *r, SDL_Color c) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
}

static void pe_fill(SDL_Renderer *r, SDL_Rect rc, SDL_Color c) {
    pe_setc(r, c);
    SDL_RenderFillRect(r, &rc);
}

static void pe_fill_circle(SDL_Renderer *r, int cx, int cy, int rad, SDL_Color c) {
    if (rad <= 0) return;
    pe_setc(r, c);
    for (int y = -rad; y <= rad; y++) {
        int w = (int)sqrt((double)(rad * rad - y * y));
        SDL_RenderDrawLine(r, cx - w, cy + y, cx + w, cy + y);
    }
}

static void pe_fill_round(SDL_Renderer *r, SDL_Rect rc, int rad, SDL_Color c) {
    if (rc.w <= 0 || rc.h <= 0) return;
    if (rad * 2 > rc.w) rad = rc.w / 2;
    if (rad * 2 > rc.h) rad = rc.h / 2;
    if (rad <= 0) { pe_fill(r, rc, c); return; }
    pe_fill(r, (SDL_Rect){rc.x + rad, rc.y, rc.w - 2 * rad, rc.h}, c);
    pe_fill(r, (SDL_Rect){rc.x, rc.y + rad, rc.w, rc.h - 2 * rad}, c);
    pe_fill_circle(r, rc.x + rad, rc.y + rad, rad, c);
    pe_fill_circle(r, rc.x + rc.w - rad - 1, rc.y + rad, rad, c);
    pe_fill_circle(r, rc.x + rad, rc.y + rc.h - rad - 1, rad, c);
    pe_fill_circle(r, rc.x + rc.w - rad - 1, rc.y + rc.h - rad - 1, rad, c);
}

static void pe_draw_arc(SDL_Renderer *r, int cx, int cy, int rad, double a0, double a1,
                        SDL_Color c, int thick) {
    pe_setc(r, c);
    int steps = (int)(fabs(a1 - a0) * rad / 2.0) + 8;
    if (thick < 1) thick = 1;
    int lo = -(thick / 2), hi = thick / 2;
    for (int i = 0; i <= steps; i++) {
        double a = a0 + (a1 - a0) * (double)i / (double)steps;
        int x = cx + (int)(cos(a) * (double)rad);
        int y = cy + (int)(sin(a) * (double)rad);
        for (int dx = lo; dx <= hi; dx++)
            for (int dy = lo; dy <= hi; dy++)
                SDL_RenderDrawPoint(r, x + dx, y + dy);
    }
}

static void pe_stroke_round(SDL_Renderer *r, SDL_Rect rc, int rad, SDL_Color c, int thick) {
    if (rc.w <= 0 || rc.h <= 0) return;
    if (rad * 2 > rc.w) rad = rc.w / 2;
    if (rad * 2 > rc.h) rad = rc.h / 2;
    if (rad < 2) rad = 2;
    pe_setc(r, c);
    for (int i = 0; i < thick; i++) {
        int y0 = rc.y + i, y1 = rc.y + rc.h - 1 - i;
        int x0 = rc.x + i, x1 = rc.x + rc.w - 1 - i;
        SDL_RenderDrawLine(r, rc.x + rad, y0, rc.x + rc.w - rad, y0);
        SDL_RenderDrawLine(r, rc.x + rad, y1, rc.x + rc.w - rad, y1);
        SDL_RenderDrawLine(r, x0, rc.y + rad, x0, rc.y + rc.h - rad);
        SDL_RenderDrawLine(r, x1, rc.y + rad, x1, rc.y + rc.h - rad);
    }
    pe_draw_arc(r, rc.x + rad, rc.y + rad, rad, PE_PI, 1.5 * PE_PI, c, thick);
    pe_draw_arc(r, rc.x + rc.w - rad - 1, rc.y + rad, rad, -0.5 * PE_PI, 0, c, thick);
    pe_draw_arc(r, rc.x + rc.w - rad - 1, rc.y + rc.h - rad - 1, rad, 0, 0.5 * PE_PI, c, thick);
    pe_draw_arc(r, rc.x + rad, rc.y + rc.h - rad - 1, rad, 0.5 * PE_PI, PE_PI, c, thick);
}

static void pe_fill_tri(SDL_Renderer *r, float x1, float y1, float x2, float y2,
                        float x3, float y3, SDL_Color c) {
    SDL_Vertex v[3];
    v[0].position = (SDL_FPoint){x1, y1};
    v[1].position = (SDL_FPoint){x2, y2};
    v[2].position = (SDL_FPoint){x3, y3};
    v[0].color = c;
    v[1].color = c;
    v[2].color = c;
    v[0].tex_coord = (SDL_FPoint){0, 0};
    v[1].tex_coord = (SDL_FPoint){0, 0};
    v[2].tex_coord = (SDL_FPoint){0, 0};
    SDL_RenderGeometry(r, NULL, v, 3, NULL, 0);
}

static void pe_hgrad(SDL_Renderer *r, int x, int y, int w, int h, SDL_Color c0, SDL_Color c1) {
    if (w <= 0 || h <= 0) return;
    for (int i = 0; i < w; i++) {
        double t = w > 1 ? (double)i / (double)(w - 1) : 0;
        SDL_Color c;
        c.r = (Uint8)(c0.r + (c1.r - c0.r) * t);
        c.g = (Uint8)(c0.g + (c1.g - c0.g) * t);
        c.b = (Uint8)(c0.b + (c1.b - c0.b) * t);
        c.a = (Uint8)(c0.a + (c1.a - c0.a) * t);
        SDL_Rect px = {x + i, y, 1, h};
        pe_fill(r, px, c);
    }
}

static void pe_vgrad(SDL_Renderer *r, int x, int y, int w, int h, Uint8 a0, Uint8 a1) {
    if (w <= 0 || h <= 0) return;
    SDL_Color c = {0, 0, 0, 0};
    for (int i = 0; i < h; i++) {
        double t = h > 1 ? (double)i / (double)(h - 1) : 0;
        c.a = (Uint8)(a0 + (a1 - a0) * t);
        SDL_Rect line = {x, y + i, w, 1};
        pe_fill(r, line, c);
    }
}

/* ---------- 文本：Windows 用 GDI 画中文，本机自测退回 5x7 点阵 ---------- */

static void pe_utf8_copy(char *dst, size_t n, const char *src) {
    if (!dst || n == 0) return;
    size_t o = 0;
    const unsigned char *q = (const unsigned char *)(src ? src : "");
    while (*q) {
        int len = 1;
        if ((*q & 0xE0) == 0xC0) len = 2;
        else if ((*q & 0xF0) == 0xE0) len = 3;
        else if ((*q & 0xF8) == 0xF0) len = 4;
        if (o + (size_t)len >= n) break;
        memcpy(dst + o, q, (size_t)len);
        o += (size_t)len;
        q += len;
    }
    dst[o] = 0;
}

static int pe_glyph_index(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c == ':') return 10;
    if (c == '/') return 11;
    if (c == '.') return 12;
    if (c == 'x') return 13;
    return -1;
}

static const uint8_t kGlyphs[14][7] = {
    {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E},
    {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F},
    {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E},
    {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},
    {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
    {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E},
    {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
    {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E},
    {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C},
    {0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00},
    {0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10},
    {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C},
    {0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x00},
};

#ifdef _WIN32
static SDL_Texture *pe_text_render_gdi(PePlayer *p, const char *text, int px, int weight,
                                       int *out_w, int *out_h) {
    int wlen = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (wlen <= 1) return NULL;
    wchar_t *wt = (wchar_t *)calloc((size_t)wlen, sizeof(wchar_t));
    if (!wt) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wt, wlen);

    HDC screen = GetDC(NULL);
    HDC dc = CreateCompatibleDC(screen);
    if (!dc) { ReleaseDC(NULL, screen); free(wt); return NULL; }
    HFONT font = CreateFontW(-px, 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                             DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
    if (!font) { DeleteDC(dc); ReleaseDC(NULL, screen); free(wt); return NULL; }
    HGDIOBJ old_font = SelectObject(dc, font);
    SIZE sz;
    memset(&sz, 0, sizeof(sz));
    GetTextExtentPoint32W(dc, wt, wlen - 1, &sz);
    int w = sz.cx + 8;
    int h = sz.cy + 8;
    if (w < 8) w = 8;
    if (h < 8) h = 8;

    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HBITMAP bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    HGDIOBJ old_bmp = SelectObject(dc, bmp);
    if (!bmp || !bits) {
        SelectObject(dc, old_bmp);
        DeleteObject(bmp);
        SelectObject(dc, old_font);
        DeleteObject(font);
        DeleteDC(dc);
        ReleaseDC(NULL, screen);
        free(wt);
        return NULL;
    }
    memset(bits, 0, (size_t)w * (size_t)h * 4);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    TextOutW(dc, 4, 4, wt, wlen - 1);

    uint32_t *src = (uint32_t *)bits;
    uint32_t *argb = (uint32_t *)malloc((size_t)w * (size_t)h * 4);
    SDL_Texture *tex = NULL;
    if (argb) {
        for (int i = 0; i < w * h; i++) {
            uint32_t v = src[i];
            int b = (int)(v & 255);
            int g = (int)((v >> 8) & 255);
            int r = (int)((v >> 16) & 255);
            int a = (r + g + b) / 3;
            argb[i] = ((uint32_t)a << 24) | 0x00FFFFFFu;
        }
        tex = SDL_CreateTexture(p->ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, w, h);
        if (tex) {
            SDL_UpdateTexture(tex, NULL, argb, w * 4);
            SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        }
        free(argb);
    }

    SelectObject(dc, old_bmp);
    DeleteObject(bmp);
    SelectObject(dc, old_font);
    DeleteObject(font);
    DeleteDC(dc);
    ReleaseDC(NULL, screen);
    free(wt);
    if (tex) {
        *out_w = w;
        *out_h = h;
    }
    return tex;
}
#endif

static SDL_Texture *pe_text_render_bitmap(PePlayer *p, const char *text, int px,
                                          int *out_w, int *out_h) {
    int scale = px / 10;
    if (scale < 1) scale = 1;
    int len = (int)strlen(text);
    if (len <= 0) return NULL;
    int w = len * 6 * scale;
    int h = 7 * scale;
    uint32_t *pix = (uint32_t *)calloc((size_t)w * (size_t)h, 4);
    if (!pix) return NULL;
    int x = 0, drawn = 0;
    const unsigned char *q = (const unsigned char *)text;
    while (*q) {
        int glen = 1;
        if ((*q & 0xE0) == 0xC0) glen = 2;
        else if ((*q & 0xF0) == 0xE0) glen = 3;
        else if ((*q & 0xF8) == 0xF0) glen = 4;
        if (glen > 1 || *q >= 0x80) {
            q += glen;
            x += 6 * scale;
            continue;
        }
        int gi = pe_glyph_index((char)*q);
        if (gi >= 0) {
            for (int row = 0; row < 7; row++) {
                uint8_t bits = kGlyphs[gi][row];
                for (int col = 0; col < 5; col++) {
                    if (bits & (1u << (4 - col))) {
                        for (int yy = 0; yy < scale; yy++)
                            for (int xx = 0; xx < scale; xx++)
                                pix[(row * scale + yy) * w + x + col * scale + xx] = 0xFFFFFFFFu;
                    }
                }
            }
            drawn = 1;
        }
        x += 6 * scale;
        q++;
    }
    if (!drawn) {
        free(pix);
        return NULL;
    }
    SDL_Texture *tex = SDL_CreateTexture(p->ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, w, h);
    if (tex) {
        SDL_UpdateTexture(tex, NULL, pix, w * 4);
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        *out_w = w;
        *out_h = h;
    }
    free(pix);
    return tex;
}

static void pe_text_cache_clear(PePlayer *p) {
    if (!p) return;
    for (int i = 0; i < PE_TEXT_CACHE; i++) {
        if (p->text_cache[i].tex) {
            SDL_DestroyTexture(p->text_cache[i].tex);
            p->text_cache[i].tex = NULL;
        }
        p->text_cache[i].text[0] = 0;
        p->text_cache[i].w = p->text_cache[i].h = 0;
        p->text_cache[i].used = 0;
    }
}

static SDL_Texture *pe_text_texture(PePlayer *p, const char *text, int px, int weight,
                                    int *out_w, int *out_h) {
    if (!p || !p->ren || !text || !text[0] || px < 6) return NULL;
    char clipped[192];
    pe_utf8_copy(clipped, sizeof(clipped), text);
    if (!clipped[0]) return NULL;
    for (int i = 0; i < PE_TEXT_CACHE; i++) {
        PeTextCache *c = &p->text_cache[i];
        if (c->tex && c->px == px && c->weight == weight && strcmp(c->text, clipped) == 0) {
            c->used = ++p->text_tick;
            *out_w = c->w;
            *out_h = c->h;
            return c->tex;
        }
    }
    int slot = -1;
    unsigned oldest = 0xFFFFFFFFu;
    for (int i = 0; i < PE_TEXT_CACHE; i++) {
        if (!p->text_cache[i].tex) { slot = i; break; }
        if (p->text_cache[i].used < oldest) { oldest = p->text_cache[i].used; slot = i; }
    }
    if (slot < 0) return NULL;
    PeTextCache *c = &p->text_cache[slot];
    if (c->tex) { SDL_DestroyTexture(c->tex); c->tex = NULL; }
    int w = 0, h = 0;
    SDL_Texture *tex = NULL;
#ifdef _WIN32
    tex = pe_text_render_gdi(p, clipped, px, weight, &w, &h);
#endif
    if (!tex) tex = pe_text_render_bitmap(p, clipped, px, &w, &h);
    if (!tex) return NULL;
    c->tex = tex;
    c->w = w;
    c->h = h;
    c->px = px;
    c->weight = weight;
    c->used = ++p->text_tick;
    pe_utf8_copy(c->text, sizeof(c->text), clipped);
    *out_w = w;
    *out_h = h;
    return tex;
}

static int pe_text_width(PePlayer *p, const char *text, int px, int weight) {
    int w = 0, h = 0;
    if (!pe_text_texture(p, text, px, weight, &w, &h)) return 0;
    return w;
}

static void pe_blit_text(PePlayer *p, SDL_Texture *tex, int x, int y, SDL_Color c) {
    SDL_SetTextureColorMod(tex, c.r, c.g, c.b);
    SDL_SetTextureAlphaMod(tex, c.a);
    SDL_Rect dst = {x, y, 0, 0};
    SDL_QueryTexture(tex, NULL, NULL, &dst.w, &dst.h);
    SDL_RenderCopy(p->ren, tex, NULL, &dst);
    SDL_SetTextureColorMod(tex, 255, 255, 255);
    SDL_SetTextureAlphaMod(tex, 255);
}

static void pe_draw_text(PePlayer *p, const char *text, int x, int y, int px, int weight,
                         SDL_Color c, int align, int shadow) {
    int w = 0, h = 0;
    SDL_Texture *tex = pe_text_texture(p, text, px, weight, &w, &h);
    if (!tex) return;
    if (align == 1) x -= w;
    else if (align == 2) x -= w / 2;
    if (shadow) {
        SDL_SetTextureColorMod(tex, 0, 0, 0);
        SDL_SetTextureAlphaMod(tex, 120);
        SDL_Rect d = {x + 1, y + 2, w, h};
        SDL_RenderCopy(p->ren, tex, NULL, &d);
    }
    pe_blit_text(p, tex, x, y, c);
}

static void pe_fmt_time(char *buf, size_t n, double sec) {
    if (sec < 0 || !isfinite(sec)) sec = 0;
    int t = (int)(sec + 0.5);
    int h = t / 3600, m = (t % 3600) / 60, s = t % 60;
    if (h > 0) snprintf(buf, n, "%d:%02d:%02d", h, m, s);
    else snprintf(buf, n, "%d:%02d", m, s);
}

static void pe_speed_label(double v, char *buf, size_t n) {
    if (fabs(v - 1.0) < 0.01) snprintf(buf, n, "1.0×");
    else snprintf(buf, n, "%.3g×", v);
}

/* ---------- 图标 ---------- */

static void pe_icon_play(SDL_Renderer *r, SDL_Rect rc, SDL_Color c, int paused) {
    int pad = rc.w / 5;
    if (rc.w <= 0 || rc.h <= 0) return;
    if (paused) {
        pe_fill_tri(r, (float)(rc.x + pad), (float)(rc.y + pad),
                    (float)(rc.x + rc.w - pad), (float)(rc.y + rc.h / 2),
                    (float)(rc.x + pad), (float)(rc.y + rc.h - pad), c);
    } else {
        int bw = (int)(rc.w * 0.24);
        int gap = (int)(rc.w * 0.14);
        pe_fill_round(r, (SDL_Rect){rc.x + pad, rc.y + pad, bw, rc.h - 2 * pad}, 2, c);
        pe_fill_round(r, (SDL_Rect){rc.x + pad + bw + gap, rc.y + pad, bw, rc.h - 2 * pad}, 2, c);
    }
}

static void pe_icon_seek(SDL_Renderer *r, SDL_Rect rc, int forward, SDL_Color c) {
    int cx = rc.x + rc.w / 2, cy = rc.y + rc.h / 2;
    int rad = rc.w / 2 - 3;
    if (rad < 4) rad = 4;
    double a0 = forward ? 0.6 : PE_PI - 0.6;
    double a1 = forward ? 2.0 * PE_PI - 0.6 : PE_PI + 0.6;
    pe_draw_arc(r, cx, cy, rad, a0, a1, c, 2);
    double ae = forward ? a1 : a0;
    int ax = cx + (int)(cos(ae) * (double)rad);
    int ay = cy + (int)(sin(ae) * (double)rad);
    int d = 5;
    if (forward)
        pe_fill_tri(r, (float)ax, (float)(ay - d), (float)(ax + d), (float)ay,
                    (float)(ax - d / 2), (float)(ay + d), c);
    else
        pe_fill_tri(r, (float)ax, (float)(ay - d), (float)(ax - d), (float)ay,
                    (float)(ax + d / 2), (float)(ay + d), c);
}

static void pe_icon_speaker(SDL_Renderer *r, SDL_Rect rc, int muted, SDL_Color c) {
    int x = rc.x + rc.w / 5, y = rc.y + rc.h / 5;
    int w = rc.w - 2 * (rc.w / 5), h = rc.h - 2 * (rc.h / 5);
    SDL_Rect body = {x, y + h / 3, w / 4, h / 3};
    pe_fill(r, body, c);
    pe_fill_tri(r, (float)(x + w / 4), (float)(y + h / 3),
                (float)(x + w * 0.58f), (float)y,
                (float)(x + w * 0.58f), (float)(y + h), c);
    if (muted) {
        pe_setc(r, c);
        for (int i = 0; i < 2; i++) {
            SDL_RenderDrawLine(r, x + (int)(w * 0.62f), y + (int)(h * 0.25f) + i,
                               x + w - 1, y + (int)(h * 0.75f) + i);
            SDL_RenderDrawLine(r, x + w - 1, y + (int)(h * 0.25f) + i,
                               x + (int)(w * 0.62f), y + (int)(h * 0.75f) + i);
        }
    } else {
        pe_draw_arc(r, x + (int)(w * 0.60f), y + h / 2, (int)(w * 0.22f), -0.8, 0.8, c, 2);
        pe_draw_arc(r, x + (int)(w * 0.60f), y + h / 2, (int)(w * 0.38f), -0.8, 0.8, c, 2);
    }
}

static void pe_icon_fullscreen(SDL_Renderer *r, SDL_Rect rc, int on, SDL_Color c) {
    int x = rc.x + rc.w / 4, y = rc.y + rc.h / 4;
    int w = rc.w / 2, h = rc.h / 2, L = 5;
    pe_setc(r, c);
    for (int t = 0; t < 2; t++) {
        int yy0 = y + t, yy1 = y + h - 1 - t;
        int xx0 = x + t, xx1 = x + w - 1 - t;
        int l = on ? L - t : L;
        SDL_RenderDrawLine(r, xx0, yy0, xx0 + l, yy0);
        SDL_RenderDrawLine(r, xx0, yy0, xx0, yy0 + l);
        SDL_RenderDrawLine(r, xx1 - l, yy0, xx1, yy0);
        SDL_RenderDrawLine(r, xx1, yy0, xx1, yy0 + l);
        SDL_RenderDrawLine(r, xx0, yy1, xx0 + l, yy1);
        SDL_RenderDrawLine(r, xx0, yy1 - l, xx0, yy1);
        SDL_RenderDrawLine(r, xx1 - l, yy1, xx1, yy1);
        SDL_RenderDrawLine(r, xx1, yy1 - l, xx1, yy1);
    }
}

static void pe_icon_close(SDL_Renderer *r, SDL_Rect rc, SDL_Color c) {
    int x = rc.x + rc.w / 3, y = rc.y + rc.h / 3;
    int w = rc.w / 3, h = rc.h / 3;
    pe_setc(r, c);
    for (int i = 0; i < 2; i++) {
        SDL_RenderDrawLine(r, x, y + i, x + w, y + h + i);
        SDL_RenderDrawLine(r, x, y + h + i, x + w, y + i);
    }
}

static void pe_icon_camera(SDL_Renderer *r, SDL_Rect rc, SDL_Color c) {
    int w = rc.w / 2, h = rc.h / 3;
    int x = rc.x + (rc.w - w) / 2, y = rc.y + (rc.h - h) / 2 + 1;
    pe_stroke_round(r, (SDL_Rect){x, y, w, h}, 3, c, 1);
    pe_fill_round(r, (SDL_Rect){x + w / 2 - 3, y - 3, 8, 4}, 1, c);
    pe_fill_circle(r, x + w / 2, y + h / 2, h / 4, c);
    pe_fill_circle(r, x + w / 2, y + h / 2, h / 4 - 2, pe_col(kUiBg, 255));
}

static void pe_icon_check(SDL_Renderer *r, int x, int y, int size, SDL_Color c) {
    pe_setc(r, c);
    SDL_RenderDrawLine(r, x, y + size / 2, x + size / 3, y + size - 1);
    SDL_RenderDrawLine(r, x + size / 3, y + size - 1, x + size, y + 1);
    SDL_RenderDrawLine(r, x, y + size / 2 + 1, x + size / 3, y + size);
    SDL_RenderDrawLine(r, x + size / 3, y + size, x + size, y + 2);
}

/* ---------- 布局 ---------- */

static void pe_layout(PePlayer *p, PeLayout *L, int outW, int outH) {
    memset(L, 0, sizeof(*L));
    L->W = outW;
    L->H = outH;
    double ui = (double)outH / 720.0;
    if (ui < 0.85) ui = 0.85;
    if (ui > 1.6) ui = 1.6;
    L->ui = ui;
    int pad = (int)(24 * ui);
    int row = (int)(40 * ui);
    int row_y = outH - (int)(52 * ui);
    int compact = outW < (int)(1020 * ui);

    L->row_y = row_y;
    L->play = (SDL_Rect){pad, row_y, row, row};
    L->back = (SDL_Rect){pad + (int)(52 * ui), row_y + 2, (int)(36 * ui), (int)(36 * ui)};
    L->fwd = (SDL_Rect){L->back.x + (int)(40 * ui), row_y + 2, (int)(36 * ui), (int)(36 * ui)};
    L->mute = (SDL_Rect){L->fwd.x + (int)(44 * ui), row_y + 2, (int)(36 * ui), (int)(36 * ui)};
    if (!compact) {
        L->volume = (SDL_Rect){L->mute.x + (int)(42 * ui), row_y + (int)(11 * ui),
                               (int)(96 * ui), (int)(18 * ui)};
        L->volume_hit = (SDL_Rect){L->volume.x - 6, L->volume.y - 11,
                                   L->volume.w + 12, L->volume.h + 22};
    }

    L->bar_x = pad;
    L->bar_y = outH - (int)(88 * ui);
    L->bar_h = (int)(4 * ui);
    if (L->bar_h < 3) L->bar_h = 3;
    L->bar_w = outW - 2 * pad;
    L->progress_hit = (SDL_Rect){L->bar_x - 6, L->bar_y - (int)(12 * ui),
                                 L->bar_w + 12, (int)(30 * ui)};
    L->time_x = pad;
    L->time_y = outH - (int)(72 * ui);
    L->dur_x = outW - pad;
    L->dur_y = L->time_y;

    int close_w = (int)(36 * ui);
    L->close = (SDL_Rect){outW - pad - close_w, row_y, close_w, row};
    int x = L->close.x - (int)(42 * ui);
    L->full = (SDL_Rect){x, row_y, (int)(36 * ui), row};
    if (!compact) {
        x -= (int)(42 * ui);
        L->shot = (SDL_Rect){x, row_y, (int)(36 * ui), row};
    }
    int pill_w = compact ? (int)(58 * ui) : (int)(70 * ui);
    x = (compact ? L->full.x : L->shot.x) - (int)(6 * ui) - pill_w;
    L->aspect = (SDL_Rect){x, row_y + (int)(3 * ui), pill_w, (int)(34 * ui)};
    x -= (int)(6 * ui) + pill_w;
    L->sub = (SDL_Rect){x, L->aspect.y, pill_w, L->aspect.h};
    x -= (int)(6 * ui) + pill_w;
    L->audio = (SDL_Rect){x, L->aspect.y, pill_w, L->aspect.h};
    int speed_w = compact ? (int)(54 * ui) : (int)(62 * ui);
    x -= (int)(6 * ui) + speed_w;
    L->speed = (SDL_Rect){x, L->aspect.y, speed_w, L->aspect.h};

    L->top_h = (int)(120 * ui);
    L->bottom_y = outH - (int)(180 * ui);
    L->title_x = pad;
    L->device_x = pad + (int)(12 * ui);
    L->title_y = (int)(26 * ui);
    L->device_y = (int)(50 * ui);
    L->meta_y = (int)(20 * ui);
    (void)p;
}

static int pe_in_rect(const SDL_Rect *r, int x, int y) {
    return r && r->w > 0 && r->h > 0 &&
           x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h;
}

static int pe_control_at(PePlayer *p, PeLayout *L, int x, int y) {
    if (!p->show_controls) return PE_CTL_NONE;
    if (pe_in_rect(&L->play, x, y)) return PE_CTL_PLAY;
    if (pe_in_rect(&L->back, x, y)) return PE_CTL_BACK;
    if (pe_in_rect(&L->fwd, x, y)) return PE_CTL_FWD;
    if (pe_in_rect(&L->mute, x, y)) return PE_CTL_MUTE;
    if (pe_in_rect(&L->speed, x, y)) return PE_CTL_SPEED;
    if (pe_in_rect(&L->audio, x, y)) return PE_CTL_AUDIO;
    if (pe_in_rect(&L->sub, x, y)) return PE_CTL_SUB;
    if (pe_in_rect(&L->aspect, x, y)) return PE_CTL_ASPECT;
    if (pe_in_rect(&L->shot, x, y)) return PE_CTL_SHOT;
    if (pe_in_rect(&L->full, x, y)) return PE_CTL_FULL;
    if (pe_in_rect(&L->close, x, y)) return PE_CTL_CLOSE;
    if (pe_in_rect(&L->volume_hit, x, y)) return PE_CTL_VOLUME;
    if (pe_in_rect(&L->progress_hit, x, y)) return PE_CTL_PROGRESS;
    return PE_CTL_NONE;
}

/* ---------- 菜单 ---------- */

static const double kSpeeds[6] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0};
static const char *kAspects[4] = {"auto", "16:9", "4:3", "fill"};

static int pe_menu_count(PePlayer *p) {
    switch (p->menu) {
    case PE_MENU_SPEED: return 6;
    case PE_MENU_AUDIO: return p->natracks;
    case PE_MENU_SUB: return p->nstracks;
    case PE_MENU_ASPECT: return 4;
    default: return 0;
    }
}

static int pe_menu_selected(PePlayer *p, int i) {
    if (p->menu == PE_MENU_SPEED) return fabs((double)p->speed_milli / 1000.0 - kSpeeds[i]) < 0.01;
    if (p->menu == PE_MENU_AUDIO) return p->cur_audio_id == i + 1;
    if (p->menu == PE_MENU_SUB) return p->cur_sub_id == i + 1;
    if (p->menu == PE_MENU_ASPECT) return strcmp(p->aspect, kAspects[i]) == 0;
    return 0;
}

static void pe_menu_item_text(PePlayer *p, int i, char *buf, size_t n) {
    buf[0] = 0;
    if (p->menu == PE_MENU_SPEED) {
        pe_speed_label(kSpeeds[i], buf, n);
    } else if (p->menu == PE_MENU_ASPECT) {
        snprintf(buf, n, "%s", kAspects[i]);
    } else {
        PeTrackInfo t;
        memset(&t, 0, sizeof(t));
        int rc = p->menu == PE_MENU_AUDIO
                     ? pe_audio_track_info(p, i, &t)
                     : pe_subtitle_track_info(p, i, &t);
        if (rc != 0) return;
        if (p->menu == PE_MENU_AUDIO) {
            if (t.title[0])
                snprintf(buf, n, "%s  %s · %dch", t.title, t.codec, t.channels);
            else
                snprintf(buf, n, "音轨 %d  %s · %dch", i + 1, t.codec, t.channels);
        } else {
            if (t.title[0])
                snprintf(buf, n, "%s  %s", t.title, t.codec);
            else
                snprintf(buf, n, "字幕 %d  %s", i + 1, t.codec);
        }
    }
}

static void pe_menu_geometry(PePlayer *p, PeLayout *L, SDL_Rect *panel,
                             int *title_h, int *item_h, int *count) {
    *count = pe_menu_count(p);
    double ui = L->ui;
    int w = (p->menu == PE_MENU_AUDIO || p->menu == PE_MENU_SUB)
                ? (int)(330 * ui)
                : (int)(200 * ui);
    int th = (int)(34 * ui);
    int ih = (int)(40 * ui);
    if (w > L->W - 24) w = L->W - 24;
    int h = th + (*count > 0 ? *count : 1) * ih + (int)(10 * ui);
    SDL_Rect a = p->menu == PE_MENU_SPEED ? L->speed
                 : p->menu == PE_MENU_AUDIO ? L->audio
                 : p->menu == PE_MENU_SUB ? L->sub : L->aspect;
    int x = a.x + a.w / 2 - w / 2;
    int minx = (int)(12 * ui);
    if (x < minx) x = minx;
    if (x + w > L->W - minx) x = L->W - minx - w;
    int y = a.y - h - (int)(10 * ui);
    if (y < minx) y = a.y + a.h + (int)(10 * ui);
    panel->x = x;
    panel->y = y;
    panel->w = w;
    panel->h = h;
    *title_h = th;
    *item_h = ih;
}

static void pe_open_menu(PePlayer *p, int menu) {
    p->menu = menu;
    p->menu_sel = 0;
    int n = pe_menu_count(p);
    for (int i = 0; i < n; i++) {
        if (pe_menu_selected(p, i)) { p->menu_sel = i; break; }
    }
    p->show_controls = 1;
    p->hide_at = pe_now() + 3600;
}

static void pe_menu_apply(PePlayer *p, int idx) {
    if (idx < 0 || idx >= pe_menu_count(p)) return;
    if (p->menu == PE_MENU_SPEED) {
        pe_set_speed(p, kSpeeds[idx]);
        char b[32], t[64];
        pe_speed_label(kSpeeds[idx], b, sizeof(b));
        snprintf(t, sizeof(t), "倍速 %s", b);
        p->toast_error = 0;
        snprintf(p->toast, sizeof(p->toast), "%s", t);
        p->toast_until = pe_now() + 1.6;
    } else if (p->menu == PE_MENU_AUDIO) {
        pe_set_audio_track(p, idx + 1);
    } else if (p->menu == PE_MENU_SUB) {
        pe_set_subtitle_track(p, idx + 1);
        p->toast_error = 0;
        snprintf(p->toast, sizeof(p->toast), "字幕轨已选择（Windows 版暂不渲染）");
        p->toast_until = pe_now() + 2.5;
    } else if (p->menu == PE_MENU_ASPECT) {
        pe_set_aspect(p, kAspects[idx]);
    }
    p->menu = PE_MENU_NONE;
    p->show_controls = 1;
    p->hide_at = pe_now() + 2.5;
}

/* ---------- 提示 / 截图 ---------- */

static void pe_show_controls(PePlayer *p) {
    p->show_controls = 1;
    p->hide_at = pe_now() + 2.5;
}

static void pe_show_toast(PePlayer *p, const char *text, int error) {
    snprintf(p->toast, sizeof(p->toast), "%s", text ? text : "");
    p->toast_error = error;
    p->toast_until = pe_now() + 3.0;
}

static void pe_take_screenshot(PePlayer *p) {
    if (!p || p->shot_busy) return;
    p->shot_busy = 1;
    time_t t = time(NULL);
    struct tm tmv;
    memset(&tmv, 0, sizeof(tmv));
    struct tm *lt = localtime(&t);
    if (lt) tmv = *lt;
    char path[1200];
    char err[256];
    err[0] = 0;
    int rc = -1;
    int used_temp = 0;
#ifdef _WIN32
    const char *home = getenv("USERPROFILE");
    const char *tmp = getenv("TEMP");
    for (int i = 0; i < 2 && rc != 0; i++) {
        const char *dir = i == 0 ? home : tmp;
        if (!dir || !dir[0]) continue;
        if (i == 0)
            snprintf(path, sizeof(path),
                     "%s\\Desktop\\DLNA 截图 %04d-%02d-%02d %02d-%02d-%02d.png",
                     dir, tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                     tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        else
            snprintf(path, sizeof(path),
                     "%s\\DLNA 截图 %04d-%02d-%02d %02d-%02d-%02d.png",
                     dir, tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                     tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        err[0] = 0;
        rc = pe_screenshot(p, path, err, sizeof(err));
        used_temp = i == 1;
    }
#else
    snprintf(path, sizeof(path), "/tmp/DLNA 截图 %04d-%02d-%02d %02d-%02d-%02d.png",
             tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    rc = pe_screenshot(p, path, err, sizeof(err));
#endif
    p->shot_busy = 0;
    if (rc == 0) {
        pe_show_toast(p, used_temp ? "截图已保存到临时目录" : "截图已保存到桌面", 0);
    } else {
        char msg[320];
        snprintf(msg, sizeof(msg), "截图失败：%s", err[0] ? err : "未知错误");
        pe_show_toast(p, msg, 1);
    }
    p->show_controls = 1;
    p->hide_at = pe_now() + 2.5;
}

/* ---------- 绘制 ---------- */

static void pe_video_rect(PePlayer *p, PeLayout *L, int tex_w, int tex_h, SDL_Rect *dst) {
    double dar = (double)tex_w / (double)tex_h * (p->sar > 0 ? p->sar : 1.0);
    if (strcmp(p->aspect, "16:9") == 0) dar = 16.0 / 9.0;
    else if (strcmp(p->aspect, "4:3") == 0) dar = 4.0 / 3.0;
    if (strcmp(p->aspect, "fill") == 0) {
        dst->x = 0;
        dst->y = 0;
        dst->w = L->W;
        dst->h = L->H;
        return;
    }
    double sw = (double)L->W / (double)tex_w;
    double sh = (double)L->H / (double)tex_h;
    double s = sw < sh ? sw : sh;
    int w = (int)(tex_w * s + 0.5);
    int h = (int)(tex_h * s + 0.5);
    if (!(strcmp(p->aspect, "auto") == 0 && fabs(dar - (double)tex_w / tex_h) < 0.02)) {
        h = (int)(w / dar + 0.5);
        if (h > L->H) {
            h = L->H;
            w = (int)(h * dar + 0.5);
        }
    }
    dst->w = w;
    dst->h = h;
    dst->x = (L->W - w) / 2;
    dst->y = (L->H - h) / 2;
}

static void pe_draw_pill(PePlayer *p, SDL_Rect r, const char *text, int hover, int active) {
    if (r.w <= 0 || r.h <= 0) return;
    double ui = ((double)r.h / 34.0);
    SDL_Color bg = pe_col(0xFFFFFF, (Uint8)((0.08 + 0.06 * hover) * 255));
    pe_fill_round(p->ren, r, r.h / 2, bg);
    pe_stroke_round(p->ren, r, r.h / 2, pe_col(0xFFFFFF, 30), 1);
    SDL_Color fg = active ? pe_col(kUiAmber, 255) : pe_col(kUiText, 235);
    int px = (int)(13 * ui);
    if (px < 10) px = 10;
    int w = 0, h = 0;
    SDL_Texture *tex = pe_text_texture(p, text, px, FW_SEMIBOLD, &w, &h);
    if (tex) pe_blit_text(p, tex, r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, fg);
}

static void pe_draw_icon_button(PePlayer *p, SDL_Rect r, int hover, int kind,
                                int fullscreen, int paused) {
    if (r.w <= 0) return;
    if (hover) pe_fill_round(p->ren, r, r.h / 2, pe_col(0xFFFFFF, 26));
    SDL_Color fg = pe_col(kUiText, 235);
    switch (kind) {
    case PE_CTL_PLAY: pe_icon_play(p->ren, r, fg, paused); break;
    case PE_CTL_BACK: pe_icon_seek(p->ren, r, 0, fg); break;
    case PE_CTL_FWD: pe_icon_seek(p->ren, r, 1, fg); break;
    case PE_CTL_MUTE: pe_icon_speaker(p->ren, r, p->muted, fg); break;
    case PE_CTL_SHOT: pe_icon_camera(p->ren, r, fg); break;
    case PE_CTL_FULL: pe_icon_fullscreen(p->ren, r, fullscreen, fg); break;
    case PE_CTL_CLOSE: pe_icon_close(p->ren, r, fg); break;
    default: break;
    }
    if (kind == PE_CTL_BACK || kind == PE_CTL_FWD) {
        double ui = (double)r.h / 36.0;
        pe_draw_text(p, "10", r.x + r.w / 2, r.y + r.h / 2 - (int)(5 * ui),
                     (int)(9 * ui), FW_SEMIBOLD, fg, 2, 0);
    }
}

static void pe_render_menu(PePlayer *p, PeLayout *L) {
    if (!p->menu) return;
    SDL_Rect panel;
    int th = 0, ih = 0, count = 0;
    pe_menu_geometry(p, L, &panel, &th, &ih, &count);
    double ui = L->ui;
    pe_fill_round(p->ren, (SDL_Rect){panel.x, panel.y + (int)(4 * ui), panel.w, panel.h},
                  (int)(12 * ui), pe_col(0x000000, 110));
    pe_fill_round(p->ren, panel, (int)(12 * ui), pe_col(kUiPanelAlt, 248));
    pe_stroke_round(p->ren, panel, (int)(12 * ui), pe_col(0xFFFFFF, 30), 1);

    const char *title = p->menu == PE_MENU_SPEED ? "倍速"
                        : p->menu == PE_MENU_AUDIO ? "音轨"
                        : p->menu == PE_MENU_SUB ? "字幕" : "画面比例";
    pe_draw_text(p, title, panel.x + (int)(16 * ui), panel.y + (int)(10 * ui),
                 (int)(11 * ui), FW_NORMAL, pe_col(kUiTextDim, 230), 0, 0);

    if (count == 0) {
        pe_draw_text(p, p->menu == PE_MENU_SUB ? "没有字幕轨" : "没有可切换的音轨",
                     panel.x + (int)(16 * ui), panel.y + th + (int)(10 * ui),
                     (int)(13 * ui), FW_NORMAL, pe_col(kUiTextDim, 220), 0, 0);
        return;
    }

    for (int i = 0; i < count; i++) {
        SDL_Rect item = {panel.x + (int)(8 * ui), panel.y + th + i * ih,
                         panel.w - (int)(16 * ui), ih - 2};
        int sel = pe_menu_selected(p, i);
        int hot = (i == p->menu_sel);
        if (hot) pe_fill_round(p->ren, item, (int)(8 * ui), pe_col(0xFFFFFF, 20));
        char label[320];
        pe_menu_item_text(p, i, label, sizeof(label));
        SDL_Color fg = sel ? pe_col(kUiAmber, 255) : pe_col(kUiText, 235);
        SDL_Rect old_clip;
        int had_clip = SDL_RenderIsClipEnabled(p->ren);
        if (had_clip) SDL_RenderGetClipRect(p->ren, &old_clip);
        SDL_Rect clip = {item.x + (int)(10 * ui), item.y, item.w - (int)(40 * ui), item.h};
        SDL_RenderSetClipRect(p->ren, &clip);
        pe_draw_text(p, label, item.x + (int)(10 * ui),
                     item.y + (item.h - (int)(17 * ui)) / 2,
                     (int)(13 * ui), FW_NORMAL, fg, 0, 0);
        if (had_clip) SDL_RenderSetClipRect(p->ren, &old_clip);
        else SDL_RenderSetClipRect(p->ren, NULL);
        if (sel) {
            pe_icon_check(p->ren, item.x + item.w - (int)(24 * ui),
                          item.y + (item.h - (int)(12 * ui)) / 2,
                          (int)(12 * ui), pe_col(kUiAmber, 255));
        }
    }
}

static void pe_render(PePlayer *p, PeLayout *L) {
    SDL_SetRenderDrawColor(p->ren, 0, 0, 0, 255);
    SDL_RenderClear(p->ren);

    if (p->tex && p->tex_w > 0 && p->tex_h > 0) {
        SDL_Rect dst;
        pe_video_rect(p, L, p->tex_w, p->tex_h, &dst);
        SDL_RenderCopy(p->ren, p->tex, NULL, &dst);
    }

    double ui = L->ui;
    if (p->show_controls) {
        pe_vgrad(p->ren, 0, 0, L->W, L->top_h, 150, 0);
        pe_vgrad(p->ren, 0, L->bottom_y, L->W, L->H - L->bottom_y, 0, 200);

        char title[160];
        pe_utf8_copy(title, sizeof(title), p->title[0] ? p->title : p->url);
        SDL_Rect title_clip = {L->title_x, L->title_y - (int)(4 * ui),
                               L->W - L->title_x - (int)(300 * ui), (int)(32 * ui)};
        SDL_RenderSetClipRect(p->ren, &title_clip);
        pe_draw_text(p, title, L->title_x, L->title_y, (int)(17 * ui), FW_SEMIBOLD,
                     pe_col(kUiText, 238), 0, 1);
        SDL_RenderSetClipRect(p->ren, NULL);

        pe_fill_circle(p->ren, L->title_x + (int)(3 * ui), L->device_y + (int)(7 * ui),
                       (int)(3 * ui), pe_col(kUiAccentTop, 242));
        char dev[320];
        snprintf(dev, sizeof(dev), "%s · 投屏中", p->device[0] ? p->device : "DLNA 电视");
        pe_draw_text(p, dev, L->device_x, L->device_y, (int)(12 * ui), FW_NORMAL,
                     pe_col(0xFFFFFF, 145), 0, 0);

        if (p->has_video && L->W > (int)(760 * ui)) {
            char codec[64];
            int ci = 0;
            for (; p->vcodec[ci] && ci < 63; ci++) {
                char c = p->vcodec[ci];
                codec[ci] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
            }
            codec[ci] = 0;
            char meta[160];
            snprintf(meta, sizeof(meta), "%s · %dx%d · %dfps · 软解", codec,
                     p->width, p->height, p->fps);
            int tw = pe_text_width(p, meta, (int)(12 * ui), FW_NORMAL);
            int cw = tw + (int)(22 * ui);
            int ch = (int)(24 * ui);
            SDL_Rect pill = {L->W - (int)(24 * ui) - cw, L->meta_y, cw, ch};
            pe_fill_round(p->ren, pill, (int)(8 * ui), pe_col(0x000000, 97));
            pe_stroke_round(p->ren, pill, (int)(8 * ui), pe_col(0xFFFFFF, 26), 1);
            int w = 0, h = 0;
            SDL_Texture *tex = pe_text_texture(p, meta, (int)(12 * ui), FW_NORMAL, &w, &h);
            if (tex) pe_blit_text(p, tex, pill.x + (pill.w - w) / 2,
                                  pill.y + (pill.h - h) / 2, pe_col(0xFFFFFF, 145));
        }

        double dur = p->duration > 0 ? p->duration : 0;
        double pos = p->dragging ? p->drag_frac * dur : pe_clock(p);
        if (p->ended && dur > 0) pos = dur;
        double frac = dur > 0 ? pos / dur : 0;
        if (frac < 0) frac = 0;
        if (frac > 1) frac = 1;

        SDL_Rect track = {L->bar_x, L->bar_y, L->bar_w, L->bar_h};
        pe_fill_round(p->ren, track, L->bar_h / 2, pe_col(0xFFFFFF, 46));
        if (dur > 0) {
            double buffered_ms = p->audio_out_rate > 0
                ? (double)pe_ring_len(p) / (double)(p->audio_out_rate * 4) * 1000.0 : 0;
            double buf = pos + buffered_ms / 1000.0;
            double bf = buf / dur;
            if (bf < 0) bf = 0;
            if (bf > 1) bf = 1;
            if (bf > frac) {
                SDL_Rect br = {L->bar_x, L->bar_y, (int)(L->bar_w * bf), L->bar_h};
                pe_fill_round(p->ren, br, L->bar_h / 2, pe_col(0xFFFFFF, 68));
            }
        }
        int pw = (int)(L->bar_w * frac);
        if (pw > 0) {
            SDL_Rect played = {L->bar_x, L->bar_y, pw, L->bar_h};
            pe_hgrad(p->ren, played.x, played.y, played.w, played.h,
                     pe_col(kUiAccentTop, 255), pe_col(kUiAccentBottom, 255));
        }
        int knobx = L->bar_x + pw;
        int show_preview = p->dragging || p->hover_ctl == PE_CTL_PROGRESS ||
                           pe_in_rect(&L->progress_hit, p->mouse_x, p->mouse_y);
        if (show_preview) {
            double pf = p->dragging ? p->drag_frac : p->hover_frac;
            knobx = L->bar_x + (int)(L->bar_w * pf);
            SDL_SetRenderDrawColor(p->ren, 255, 255, 255, 210);
            SDL_RenderDrawLine(p->ren, knobx, L->bar_y - (int)(4 * ui),
                               knobx, L->bar_y + L->bar_h + (int)(4 * ui));
            pe_fill_circle(p->ren, knobx, L->bar_y + L->bar_h / 2, (int)(6 * ui),
                           pe_col(0xFFFFFF, 240));
            char tip[32];
            pe_fmt_time(tip, sizeof(tip), pf * dur);
            int tw = pe_text_width(p, tip, (int)(11 * ui), FW_SEMIBOLD);
            int bw = tw + (int)(18 * ui), bh = (int)(24 * ui);
            int bx = knobx - bw / 2;
            if (bx < (int)(12 * ui)) bx = (int)(12 * ui);
            if (bx + bw > L->W - (int)(12 * ui)) bx = L->W - (int)(12 * ui) - bw;
            SDL_Rect bubble = {bx, L->bar_y - (int)(38 * ui), bw, bh};
            pe_fill_round(p->ren, bubble, (int)(8 * ui), pe_col(kUiPanelAlt, 245));
            pe_stroke_round(p->ren, bubble, (int)(8 * ui), pe_col(0xFFFFFF, 26), 1);
            pe_draw_text(p, tip, bubble.x + bubble.w / 2,
                         bubble.y + (bubble.h - (int)(17 * ui)) / 2,
                         (int)(11 * ui), FW_SEMIBOLD, pe_col(0xFFFFFF, 235), 2, 0);
        }

        char cur[32], total[32];
        pe_fmt_time(cur, sizeof(cur), pos);
        pe_fmt_time(total, sizeof(total), dur);
        pe_draw_text(p, cur, L->time_x, L->time_y, (int)(12 * ui), FW_NORMAL,
                     pe_col(0xFFFFFF, 235), 0, 0);
        if (dur > 0)
            pe_draw_text(p, total, L->dur_x, L->dur_y, (int)(12 * ui), FW_NORMAL,
                         pe_col(0xFFFFFF, 140), 1, 0);

        int hp = p->hover_ctl == PE_CTL_PLAY;
        pe_fill_round(p->ren, L->play, L->play.h / 2,
                      pe_col(0xFFFFFF, (Uint8)((0.10 + 0.08 * hp) * 255)));
        pe_draw_icon_button(p, L->play, hp, PE_CTL_PLAY, p->fullscreen, p->paused);
        pe_draw_icon_button(p, L->back, p->hover_ctl == PE_CTL_BACK, PE_CTL_BACK, 0, 0);
        pe_draw_icon_button(p, L->fwd, p->hover_ctl == PE_CTL_FWD, PE_CTL_FWD, 0, 0);
        pe_draw_icon_button(p, L->mute, p->hover_ctl == PE_CTL_MUTE, PE_CTL_MUTE, 0, 0);

        if (L->volume.w > 0) {
            SDL_Rect vt = {L->volume.x, L->volume.y + L->volume.h / 2 - 2,
                           L->volume.w, 4};
            pe_fill_round(p->ren, vt, 2, pe_col(0xFFFFFF, 46));
            double vf = (double)p->volume / 100.0;
            if (p->muted) vf = 0;
            if (vf > 0.01) {
                SDL_Rect vfill = {vt.x, vt.y, (int)(vt.w * vf), vt.h};
                pe_fill_round(p->ren, vfill, 2, pe_col(kUiAmber, 255));
            }
            pe_fill_circle(p->ren, vt.x + (int)(vt.w * vf), vt.y + vt.h / 2,
                           (int)(5 * ui), pe_col(0xFFFFFF, 245));
        }

        char sp[32];
        pe_speed_label((double)p->speed_milli / 1000.0, sp, sizeof(sp));
        pe_draw_pill(p, L->speed,
                     p->speed_milli != 1000 ? sp : "1.0×",
                     p->hover_ctl == PE_CTL_SPEED, p->speed_milli != 1000);
        char audio[64];
        if (p->natracks > 1 && p->cur_audio_id > 0)
            snprintf(audio, sizeof(audio), "音轨 %d", p->cur_audio_id);
        else
            snprintf(audio, sizeof(audio), "音轨");
        pe_draw_pill(p, L->audio, audio, p->hover_ctl == PE_CTL_AUDIO,
                     p->natracks > 1 || p->menu == PE_MENU_AUDIO);
        char sub[64];
        if (p->cur_sub_id > 0) snprintf(sub, sizeof(sub), "字幕 %d", p->cur_sub_id);
        else snprintf(sub, sizeof(sub), "字幕");
        pe_draw_pill(p, L->sub, sub, p->hover_ctl == PE_CTL_SUB,
                     p->cur_sub_id > 0 || p->menu == PE_MENU_SUB);
        pe_draw_pill(p, L->aspect, p->aspect, p->hover_ctl == PE_CTL_ASPECT,
                     strcmp(p->aspect, "auto") != 0);
        if (L->shot.w > 0)
            pe_draw_icon_button(p, L->shot, p->hover_ctl == PE_CTL_SHOT, PE_CTL_SHOT, 0, 0);
        pe_draw_icon_button(p, L->full, p->hover_ctl == PE_CTL_FULL, PE_CTL_FULL,
                            p->fullscreen, 0);
        pe_draw_icon_button(p, L->close, p->hover_ctl == PE_CTL_CLOSE, PE_CTL_CLOSE, 0, 0);
    }

    if (p->menu) pe_render_menu(p, L);

    if (p->buffering) {
        double a = pe_now() * 3.2;
        int cx = L->W / 2, cy = L->H / 2;
        int rad = (int)(28 * ui);
        for (int i = 0; i < 40; i++) {
            double t = a + (double)i * 0.045;
            int x = cx + (int)(cos(t) * (double)rad);
            int y = cy + (int)(sin(t) * (double)rad);
            Uint8 al = (Uint8)(40 + 215 * (double)i / 40.0);
            pe_fill_circle(p->ren, x, y, 2, pe_col(kUiAccentTop, al));
        }
        pe_draw_text(p, p->seeking ? "跳转中…" : "准备中…",
                     L->W / 2, L->H / 2 + (int)(42 * ui),
                     (int)(14 * ui), FW_NORMAL, pe_col(kUiText, 220), 2, 1);
    }

    if (p->toast[0] && pe_now() < p->toast_until) {
        int tw = pe_text_width(p, p->toast, (int)(13 * ui), FW_NORMAL);
        int bw = tw + (int)(44 * ui);
        int bh = (int)(36 * ui);
        int bx = (L->W - bw) / 2;
        int by = L->H - (int)(140 * ui);
        pe_fill_round(p->ren, (SDL_Rect){bx, by + (int)(3 * ui), bw, bh},
                      (int)(10 * ui), pe_col(0x000000, 100));
        pe_fill_round(p->ren, (SDL_Rect){bx, by, bw, bh}, (int)(10 * ui),
                      pe_col(kUiPanel, 242));
        pe_stroke_round(p->ren, (SDL_Rect){bx, by, bw, bh}, (int)(10 * ui),
                        pe_col(0xFFFFFF, 28), 1);
        pe_fill_circle(p->ren, bx + (int)(18 * ui), by + bh / 2, (int)(4 * ui),
                       pe_col(p->toast_error ? kUiRed : kUiAmber, 255));
        pe_draw_text(p, p->toast, bx + (int)(30 * ui),
                     by + (bh - (int)(17 * ui)) / 2,
                     (int)(13 * ui), FW_NORMAL, pe_col(kUiText, 235), 0, 0);
    }

    if (p->debug_capture_req) {
        p->debug_capture_req = 0;
        SDL_Surface *surf = SDL_CreateRGBSurfaceWithFormat(0, L->W, L->H, 32,
                                                           SDL_PIXELFORMAT_ARGB8888);
        if (surf) {
            if (SDL_RenderReadPixels(p->ren, NULL, SDL_PIXELFORMAT_ARGB8888,
                                     surf->pixels, surf->pitch) == 0)
                SDL_SaveBMP(surf, p->debug_capture_path);
            SDL_FreeSurface(surf);
        }
    }

    SDL_RenderPresent(p->ren);
}

void pe_debug_capture(PePlayer *p, const char *path) {
    if (!p || !path) return;
    pe_utf8_copy(p->debug_capture_path, sizeof(p->debug_capture_path), path);
    p->debug_capture_req = 1;
}

/* ---------- 事件 ---------- */

static void pe_handle_key(PePlayer *p, SDL_Keycode key) {
    if (p->menu) {
        int n = pe_menu_count(p);
        if (key == SDLK_ESCAPE) {
            p->menu = PE_MENU_NONE;
            pe_show_controls(p);
            return;
        }
        if (key == SDLK_UP && n > 0) {
            p->menu_sel = (p->menu_sel + n - 1) % n;
            return;
        }
        if (key == SDLK_DOWN && n > 0) {
            p->menu_sel = (p->menu_sel + 1) % n;
            return;
        }
        if (n == 0 && (key == SDLK_RETURN || key == SDLK_KP_ENTER || key == SDLK_SPACE))
            return;
        if ((key == SDLK_RETURN || key == SDLK_KP_ENTER || key == SDLK_SPACE) && n > 0) {
            pe_menu_apply(p, p->menu_sel);
            return;
        }
    }
    switch (key) {
    case SDLK_ESCAPE:
        if (p->fullscreen) pe_set_fullscreen(p, 0);
        else { p->closed = 1; p->run_stop = 1; }
        break;
    case SDLK_SPACE: pe_toggle_pause(p); pe_show_controls(p); break;
    case SDLK_LEFT: pe_seek_relative(p, -10); pe_show_controls(p); break;
    case SDLK_RIGHT: pe_seek_relative(p, 10); pe_show_controls(p); break;
    case SDLK_UP: pe_set_volume(p, p->volume + 5); pe_show_controls(p); break;
    case SDLK_DOWN: pe_set_volume(p, p->volume - 5); pe_show_controls(p); break;
    case SDLK_m: p->muted = !p->muted; pe_show_controls(p); break;
    case SDLK_f: pe_toggle_fullscreen(p); pe_show_controls(p); break;
    case SDLK_s: pe_take_screenshot(p); break;
    case SDLK_HOME: pe_seek(p, 0); pe_show_controls(p); break;
    case SDLK_END: pe_seek(p, p->duration); pe_show_controls(p); break;
    default: break;
    }
}

static void pe_handle_event(PePlayer *p, SDL_Event *ev, PeLayout *L, double sx, double sy) {
    switch (ev->type) {
    case SDL_QUIT:
        p->closed = 1;
        p->run_stop = 1;
        break;
    case SDL_WINDOWEVENT:
        if (ev->window.event == SDL_WINDOWEVENT_CLOSE) {
            p->closed = 1;
            p->run_stop = 1;
        }
        break;
    case SDL_KEYDOWN:
        if (!ev->key.repeat) pe_handle_key(p, ev->key.keysym.sym);
        break;
    case SDL_MOUSEMOTION: {
        int mx = (int)(ev->motion.x * sx);
        int my = (int)(ev->motion.y * sy);
        p->mouse_x = mx;
        p->mouse_y = my;
        if (!p->menu) pe_show_controls(p);
        p->hover_ctl = p->menu ? PE_CTL_NONE : pe_control_at(p, L, mx, my);
        if (p->dragging && L->bar_w > 0) {
            double f = (double)(mx - L->bar_x) / (double)L->bar_w;
            if (f < 0) f = 0;
            if (f > 1) f = 1;
            p->drag_frac = f;
        } else if (L->bar_w > 0) {
            double f = (double)(mx - L->bar_x) / (double)L->bar_w;
            if (f < 0) f = 0;
            if (f > 1) f = 1;
            p->hover_frac = f;
        }
        if (p->vol_drag && L->volume.w > 0) {
            double f = (double)(mx - L->volume.x) / (double)L->volume.w;
            if (f < 0) f = 0;
            if (f > 1) f = 1;
            pe_set_volume(p, (int)(f * 100 + 0.5));
        }
        if (p->menu) {
            SDL_Rect panel;
            int th = 0, ih = 0, count = 0;
            pe_menu_geometry(p, L, &panel, &th, &ih, &count);
            p->menu_sel = -1;
            for (int i = 0; i < count; i++) {
                SDL_Rect item = {panel.x + (int)(8 * L->ui), panel.y + th + i * ih,
                                 panel.w - (int)(16 * L->ui), ih - 2};
                if (pe_in_rect(&item, mx, my)) { p->menu_sel = i; break; }
            }
        }
        break;
    }
    case SDL_MOUSEBUTTONDOWN: {
        int mx = (int)(ev->button.x * sx);
        int my = (int)(ev->button.y * sy);
        if (ev->button.button != SDL_BUTTON_LEFT) break;
        if (p->menu) {
            SDL_Rect panel;
            int th = 0, ih = 0, count = 0;
            pe_menu_geometry(p, L, &panel, &th, &ih, &count);
            int handled = 0;
            for (int i = 0; i < count; i++) {
                SDL_Rect item = {panel.x + (int)(8 * L->ui), panel.y + th + i * ih,
                                 panel.w - (int)(16 * L->ui), ih - 2};
                if (pe_in_rect(&item, mx, my)) {
                    pe_menu_apply(p, i);
                    handled = 1;
                    break;
                }
            }
            if (!handled) p->menu = PE_MENU_NONE;
            pe_show_controls(p);
            break;
        }
        int ctl = pe_control_at(p, L, mx, my);
        switch (ctl) {
        case PE_CTL_PLAY: pe_toggle_pause(p); pe_show_controls(p); break;
        case PE_CTL_BACK: pe_seek_relative(p, -10); pe_show_controls(p); break;
        case PE_CTL_FWD: pe_seek_relative(p, 10); pe_show_controls(p); break;
        case PE_CTL_MUTE: p->muted = !p->muted; pe_show_controls(p); break;
        case PE_CTL_PROGRESS:
            if (p->duration > 0) {
                double f = (double)(mx - L->bar_x) / (double)L->bar_w;
                if (f < 0) f = 0;
                if (f > 1) f = 1;
                p->drag_frac = f;
                p->dragging = 1;
            }
            break;
        case PE_CTL_VOLUME:
            if (L->volume.w > 0) {
                double f = (double)(mx - L->volume.x) / (double)L->volume.w;
                if (f < 0) f = 0;
                if (f > 1) f = 1;
                pe_set_volume(p, (int)(f * 100 + 0.5));
                p->vol_drag = 1;
            }
            break;
        case PE_CTL_SPEED: pe_open_menu(p, PE_MENU_SPEED); break;
        case PE_CTL_AUDIO: pe_open_menu(p, PE_MENU_AUDIO); break;
        case PE_CTL_SUB: pe_open_menu(p, PE_MENU_SUB); break;
        case PE_CTL_ASPECT: pe_open_menu(p, PE_MENU_ASPECT); break;
        case PE_CTL_SHOT: pe_take_screenshot(p); break;
        case PE_CTL_FULL: pe_toggle_fullscreen(p); pe_show_controls(p); break;
        case PE_CTL_CLOSE: p->closed = 1; p->run_stop = 1; break;
        default:
            if (ev->button.clicks >= 2) {
                pe_toggle_fullscreen(p);
                pe_show_controls(p);
            } else if (!p->show_controls) {
                pe_show_controls(p);
            } else {
                pe_toggle_pause(p);
            }
            break;
        }
        break;
    }
    case SDL_MOUSEBUTTONUP:
        if (ev->button.button == SDL_BUTTON_LEFT) {
            if (p->dragging) {
                p->dragging = 0;
                if (p->duration > 0) pe_seek(p, p->drag_frac * p->duration);
            }
            p->vol_drag = 0;
        }
        break;
    case SDL_MOUSEWHEEL:
        pe_set_volume(p, p->volume + (ev->wheel.y > 0 ? 5 : -5));
        pe_show_controls(p);
        break;
    default:
        break;
    }
}

static void pe_update_frame(PePlayer *p) {
    double clock = pe_clock(p);
    int prime = p->has_video && !p->video_primed;
    AVFrame *show = NULL;
    double show_pts = 0;
    SDL_LockMutex(p->mu);
    if (p->fcount > 0) {
        PeFrameNode *n = &p->frames[p->fhead];
        if (prime || n->pts <= clock + 0.008) {
            show = n->frame;
            show_pts = n->pts;
            n->frame = NULL;
            p->fhead = (p->fhead + 1) % PE_MAX_FRAMES;
            p->fcount--;
            if (!prime) {
                while (p->fcount > 0) {
                    PeFrameNode *m = &p->frames[p->fhead];
                    if (m->pts <= clock + 0.008) {
                        if (show) { av_frame_free(&show); p->frames_dropped++; }
                        show = m->frame;
                        show_pts = m->pts;
                        m->frame = NULL;
                        p->fhead = (p->fhead + 1) % PE_MAX_FRAMES;
                        p->fcount--;
                    } else {
                        break;
                    }
                }
            }
        }
    }
    SDL_UnlockMutex(p->mu);
    if (!show) return;

    int ring = (p->has_audio && p->adev) ? pe_ring_len(p) : 0;
    int w = show->width, h = show->height;
    if (!p->tex || p->tex_w != w || p->tex_h != h) {
        if (p->tex) SDL_DestroyTexture(p->tex);
        p->tex = SDL_CreateTexture(p->ren, SDL_PIXELFORMAT_IYUV, SDL_TEXTUREACCESS_STREAMING, w, h);
        p->tex_w = w;
        p->tex_h = h;
        if (!p->tex) PE_LOG("创建视频纹理失败：%s", SDL_GetError());
    }
    if (p->tex) {
        SDL_UpdateYUVTexture(p->tex, NULL,
                             show->data[0], show->linesize[0],
                             show->data[1], show->linesize[1],
                             show->data[2], show->linesize[2]);
    }

    int unpause_audio = 0;
    SDL_LockMutex(p->mu);
    if (p->current) av_frame_free(&p->current);
    p->current = show;
    p->current_pts = show_pts;
    p->video_pts = show_pts;
    p->drift_ms = (show_pts - clock) * 1000.0;
    pe_drift_add(p, p->drift_ms);
    p->frames_shown++;
    if (prime) {
        double base = p->clock_base;
        p->video_primed = 1;
        p->seeking = 0;
        p->clock_base = base;
        p->clock_samples_base = p->audio_played;
        p->clock_mono_base = base;
        p->mono_wall_base = pe_now();
        p->clock_paused = base;
        p->audio_base_hint = base;
        p->has_audio_hint = p->has_audio ? 1 : 0;
        if (p->has_audio && p->adev) {
            p->audio_started = ring > 0 ? 1 : 0;
            unpause_audio = !p->paused;
        } else {
            p->audio_started = 0;
        }
        if (p->seek_request_t0 > 0 && !p->seek_first_frame_logged) {
            p->seek_first_frame_logged = 1;
            PE_LOG("seek 首帧 %.0fms target=%.2f pts=%.2f",
                   (pe_now() - p->seek_request_t0) * 1000.0, p->seek_target, show_pts);
        }
    }
    if (p->first_frame_ms <= 0) {
        p->first_frame_ms = (pe_now() - p->open_t0) * 1000.0;
        PE_LOG("首视频 %.0fms（首音频 %.0fms）", p->first_frame_ms, p->first_audio_ms);
    }
    p->buffering = 0;
    SDL_UnlockMutex(p->mu);
    if (unpause_audio) SDL_PauseAudioDevice(p->adev, 0);
}

void pe_run(PePlayer *p) {
    if (!p) return;
    if (p->run_started) return;
    p->run_started = 1;
    SDL_ShowWindow(p->win);
    p->show_controls = 1;
    p->hide_at = pe_now() + 2.5;

    while (!p->run_stop) {
        int winw = 0, winh = 0;
        SDL_GetWindowSize(p->win, &winw, &winh);
        int outw = winw, outh = winh;
        SDL_GetRendererOutputSize(p->ren, &outw, &outh);
        if (outw <= 0) outw = winw;
        if (outh <= 0) outh = winh;
        double sx = winw > 0 ? (double)outw / winw : 1.0;
        double sy = winh > 0 ? (double)outh / winh : 1.0;
        PeLayout L;
        pe_layout(p, &L, outw, outh);

        SDL_Event ev;
        while (SDL_PollEvent(&ev)) pe_handle_event(p, &ev, &L, sx, sy);

        if (p->fullscreen_req != 0) {
            int on = p->fullscreen_req > 0;
            p->fullscreen_req = 0;
            p->fullscreen = on;
            SDL_SetWindowFullscreen(p->win, on ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
        }

        if (p->paused || p->dragging || p->vol_drag || p->menu) {
            p->show_controls = 1;
            p->hide_at = pe_now() + 2.5;
        } else if (pe_now() > p->hide_at) {
            p->show_controls = 0;
            p->hover_ctl = PE_CTL_NONE;
        }

        pe_update_frame(p);
        pe_render(p, &L);
        SDL_Delay(2);
    }

    p->stop = 1;
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
    p->run_returned = 1;
    pe_text_cache_clear(p);
    if (p->tex) { SDL_DestroyTexture(p->tex); p->tex = NULL; }
    if (p->ren) { SDL_DestroyRenderer(p->ren); p->ren = NULL; }
    if (p->win) { SDL_DestroyWindow(p->win); p->win = NULL; }
    p->gfx_done = 1;
    PE_LOG("事件循环退出");
}

void pe_stop_run(PePlayer *p) {
    if (!p) return;
    p->run_stop = 1;
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = SDL_QUIT;
    SDL_PushEvent(&ev);
}

void pe_close(PePlayer *p) {
    if (!p) return;
    p->stop = 1;
    p->run_stop = 1;
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
    if (p->th_started && !p->th_joined) {
        SDL_WaitThread(p->th, NULL);
        p->th_joined = 1;
        p->th_started = 0;
    }
    if (p->adev) { SDL_CloseAudioDevice(p->adev); p->adev = 0; }
    if (!p->run_started && !p->gfx_done) {
        pe_text_cache_clear(p);
        if (p->tex) { SDL_DestroyTexture(p->tex); p->tex = NULL; }
        if (p->ren) { SDL_DestroyRenderer(p->ren); p->ren = NULL; }
        if (p->win) { SDL_DestroyWindow(p->win); p->win = NULL; }
        p->gfx_done = 1;
    }
}

void pe_destroy(PePlayer *p) {
    if (!p) return;
    pe_close(p);
    pe_clear_frames(p);
    if (p->current) { av_frame_free(&p->current); p->current = NULL; }
    if (p->vctx) avcodec_free_context(&p->vctx);
    if (p->actx) avcodec_free_context(&p->actx);
    if (p->fmt) avformat_close_input(&p->fmt);
    if (p->vsws) sws_freeContext(p->vsws);
    if (p->shotsws) sws_freeContext(p->shotsws);
    if (p->swr) swr_free(&p->swr);
    free(p->atracks);
    free(p->stracks);
    free(p->ring);
    free(p->convbuf);
    if (p->mu) SDL_DestroyMutex(p->mu);
    pe_sdl_quit();
    free(p);
}

/* ---------- 脚本/验证钩子 ---------- */

void pe_ui_set_visible(PePlayer *p, int visible) {
    if (!p) return;
    p->show_controls = visible ? 1 : 0;
    if (visible) p->hide_at = pe_now() + 3600;
    else { p->hover_ctl = PE_CTL_NONE; p->menu = PE_MENU_NONE; }
}

void pe_ui_hover(PePlayer *p, const char *control) {
    if (!p || !control) return;
    pe_show_controls(p);
    if (strncmp(control, "progress:", 9) == 0 && p->duration > 0) {
        double f = atof(control + 9);
        if (f < 0) f = 0;
        if (f > 1) f = 1;
        p->hover_frac = f;
        p->hover_ctl = PE_CTL_PROGRESS;
        return;
    }
    p->hover_ctl = PE_CTL_NONE;
    if (strcmp(control, "play") == 0) p->hover_ctl = PE_CTL_PLAY;
    else if (strcmp(control, "back") == 0) p->hover_ctl = PE_CTL_BACK;
    else if (strcmp(control, "forward") == 0) p->hover_ctl = PE_CTL_FWD;
    else if (strcmp(control, "mute") == 0) p->hover_ctl = PE_CTL_MUTE;
    else if (strcmp(control, "volume") == 0) p->hover_ctl = PE_CTL_VOLUME;
    else if (strcmp(control, "speed") == 0) p->hover_ctl = PE_CTL_SPEED;
    else if (strcmp(control, "audio") == 0) p->hover_ctl = PE_CTL_AUDIO;
    else if (strcmp(control, "subtitle") == 0) p->hover_ctl = PE_CTL_SUB;
    else if (strcmp(control, "aspect") == 0) p->hover_ctl = PE_CTL_ASPECT;
    else if (strcmp(control, "screenshot") == 0) p->hover_ctl = PE_CTL_SHOT;
    else if (strcmp(control, "fullscreen") == 0) p->hover_ctl = PE_CTL_FULL;
    else if (strcmp(control, "close") == 0) p->hover_ctl = PE_CTL_CLOSE;
}

void pe_ui_click(PePlayer *p, const char *control) {
    if (!p || !control) return;
    pe_show_controls(p);
    if (strcmp(control, "play") == 0 || strcmp(control, "toggle") == 0) pe_toggle_pause(p);
    else if (strcmp(control, "pause") == 0) pe_pause(p);
    else if (strcmp(control, "back") == 0) pe_seek_relative(p, -10);
    else if (strcmp(control, "forward") == 0) pe_seek_relative(p, 10);
    else if (strcmp(control, "fullscreen") == 0) pe_toggle_fullscreen(p);
    else if (strcmp(control, "mute") == 0) p->muted = !p->muted;
    else if (strcmp(control, "screenshot") == 0) pe_take_screenshot(p);
    else if (strcmp(control, "close") == 0) { p->closed = 1; p->run_stop = 1; }
    else if (strncmp(control, "progress:", 9) == 0 && p->duration > 0)
        pe_seek(p, atof(control + 9) * p->duration);
    else if (strncmp(control, "volume:", 7) == 0) pe_set_volume(p, atoi(control + 7));
    else if (strncmp(control, "speed:", 6) == 0) pe_set_speed(p, atof(control + 6));
    else if (strncmp(control, "audio:", 6) == 0) pe_set_audio_track(p, atoi(control + 6));
    else if (strncmp(control, "subtitle:", 9) == 0) pe_set_subtitle_track(p, atoi(control + 9));
    else if (strncmp(control, "aspect:", 7) == 0) pe_set_aspect(p, control + 7);
    else if (strcmp(control, "menu:speed") == 0) pe_open_menu(p, PE_MENU_SPEED);
    else if (strcmp(control, "menu:audio") == 0) pe_open_menu(p, PE_MENU_AUDIO);
    else if (strcmp(control, "menu:subtitle") == 0) pe_open_menu(p, PE_MENU_SUB);
    else if (strcmp(control, "menu:aspect") == 0) pe_open_menu(p, PE_MENU_ASPECT);
    else if (strcmp(control, "menu:close") == 0 || strcmp(control, "menu:none") == 0) {
        p->menu = PE_MENU_NONE;
        pe_show_controls(p);
    }
}

void pe_ui_menu(PePlayer *p, const char *menu) {
    if (!p || !menu) return;
    if (strcmp(menu, "speed") == 0) pe_open_menu(p, PE_MENU_SPEED);
    else if (strcmp(menu, "audio") == 0) pe_open_menu(p, PE_MENU_AUDIO);
    else if (strcmp(menu, "subtitle") == 0 || strcmp(menu, "sub") == 0) pe_open_menu(p, PE_MENU_SUB);
    else if (strcmp(menu, "aspect") == 0) pe_open_menu(p, PE_MENU_ASPECT);
    else if (strcmp(menu, "close") == 0 || strcmp(menu, "none") == 0) {
        p->menu = PE_MENU_NONE;
        pe_show_controls(p);
    }
}

void pe_ui_key(PePlayer *p, const char *key) {
    if (!p || !key) return;
    SDL_Keycode k = 0;
    if (strcmp(key, "space") == 0) k = SDLK_SPACE;
    else if (strcmp(key, "left") == 0) k = SDLK_LEFT;
    else if (strcmp(key, "right") == 0) k = SDLK_RIGHT;
    else if (strcmp(key, "up") == 0) k = SDLK_UP;
    else if (strcmp(key, "down") == 0) k = SDLK_DOWN;
    else if (strcmp(key, "m") == 0) k = SDLK_m;
    else if (strcmp(key, "f") == 0) k = SDLK_f;
    else if (strcmp(key, "s") == 0 || strcmp(key, "screenshot") == 0) k = SDLK_s;
    else if (strcmp(key, "esc") == 0 || strcmp(key, "escape") == 0) k = SDLK_ESCAPE;
    else if (strcmp(key, "enter") == 0 || strcmp(key, "return") == 0) k = SDLK_RETURN;
    else if (strcmp(key, "home") == 0) k = SDLK_HOME;
    else if (strcmp(key, "end") == 0) k = SDLK_END;
    if (k) pe_handle_key(p, k);
    pe_show_controls(p);
}

#endif /* _WIN32 || PE_ENGINE_PORTABLE */
