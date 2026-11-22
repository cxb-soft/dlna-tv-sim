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

#include <SDL.h>

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
    int W, H, hb, py;
    SDL_Rect play;
    SDL_Rect barhit;
    SDL_Rect volhit;
    SDL_Rect fullhit;
    int bar_x, bar_y, bar_w, bar_h;
    int time_x, time_y, time_scale;
} PeLayout;

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
    double open_t0;
    double last_seek_ms;
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

    int show_controls, dragging;
    double drag_frac;
    double hide_at;
    int mouse_x, mouse_y;
    int win_w, win_h;

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
            if (!p->audio_started) {
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
                if (!p->has_video) p->buffering = 0;
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
        if (p->has_audio && p->adev) {
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
                        /* SDL 音频设备默认是暂停的，必须显式开声。 */
                        SDL_PauseAudioDevice(p->adev, 0);
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

    if (p->start_position > 0) {
        p->seek_req = 1;
        p->seek_pos = p->start_position;
    }
    if (!p->has_audio) {
        p->clock_base = p->start_position;
        p->clock_mono_base = p->start_position;
        p->mono_wall_base = pe_now();
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
    if (p->adev) SDL_PauseAudioDevice(p->adev, 0);
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
    p->seek_pos = seconds;
    p->seek_req = 1;
    p->ended = 0;
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

static void pe_draw_text(SDL_Renderer *r, int x, int y, const char *s, int scale,
                         Uint8 cr, Uint8 cg, Uint8 cb, Uint8 ca) {
    SDL_SetRenderDrawColor(r, cr, cg, cb, ca);
    for (const char *q = s; *q; q++) {
        int gi = pe_glyph_index(*q);
        if (gi < 0) { x += 6 * scale; continue; }
        for (int row = 0; row < 7; row++) {
            uint8_t bits = kGlyphs[gi][row];
            for (int col = 0; col < 5; col++) {
                if (bits & (1u << (4 - col))) {
                    SDL_Rect px = {x + col * scale, y + row * scale, scale, scale};
                    SDL_RenderFillRect(r, &px);
                }
            }
        }
        x += 6 * scale;
    }
}

static void pe_draw_speaker(SDL_Renderer *r, int x, int y, int size, Uint8 cr, Uint8 cg, Uint8 cb) {
    SDL_SetRenderDrawColor(r, cr, cg, cb, 255);
    SDL_Rect body = {x, y + size / 3, size / 4, size / 3};
    SDL_RenderFillRect(r, &body);
    for (int i = 0; i < size / 2; i++) {
        int h = (size / 3) + (size / 2 - i) * 2;
        int cy = y + size / 2;
        SDL_RenderDrawLine(r, x + size / 4 + i, cy - h / 2, x + size / 4 + i, cy + h / 2);
    }
}

static void pe_draw_fullscreen_icon(SDL_Renderer *r, int x, int y, int size) {
    SDL_SetRenderDrawColor(r, 255, 255, 255, 235);
    int L = size / 3;
    SDL_RenderDrawLine(r, x, y, x + L, y);
    SDL_RenderDrawLine(r, x, y, x, y + L);
    SDL_RenderDrawLine(r, x + size, y, x + size - L, y);
    SDL_RenderDrawLine(r, x + size, y, x + size, y + L);
    SDL_RenderDrawLine(r, x, y + size, x + L, y + size);
    SDL_RenderDrawLine(r, x, y + size, x, y + size - L);
    SDL_RenderDrawLine(r, x + size, y + size, x + size - L, y + size);
    SDL_RenderDrawLine(r, x + size, y + size, x + size, y + size - L);
}

static void pe_draw_play_icon(SDL_Renderer *r, int x, int y, int size, int paused) {
    SDL_SetRenderDrawColor(r, 255, 255, 255, 240);
    if (paused) {
        for (int i = 0; i < size; i++) {
            int h = size - abs(i * 2 - size) * 2;
            if (h < 1) h = 1;
            SDL_RenderDrawLine(r, x + i, y + (size - h) / 2, x + i, y + (size + h) / 2);
        }
    } else {
        SDL_Rect a = {x + 2, y + 2, size / 3, size - 4};
        SDL_Rect b = {x + 2 + size / 3 + 3, y + 2, size / 3, size - 4};
        SDL_RenderFillRect(r, &a);
        SDL_RenderFillRect(r, &b);
    }
}

static void pe_draw_circle(SDL_Renderer *r, int cx, int cy, int radius) {
    for (int y = -radius; y <= radius; y++) {
        int w = (int)sqrt((double)(radius * radius - y * y));
        SDL_RenderDrawLine(r, cx - w, cy + y, cx + w, cy + y);
    }
}

static void pe_fmt_time(char *buf, size_t n, double sec) {
    if (sec < 0 || !isfinite(sec)) sec = 0;
    int t = (int)(sec + 0.5);
    int h = t / 3600, m = (t % 3600) / 60, s = t % 60;
    if (h > 0) snprintf(buf, n, "%d:%02d:%02d", h, m, s);
    else snprintf(buf, n, "%02d:%02d", m, s);
}

static void pe_layout(PePlayer *p, PeLayout *L, int outW, int outH) {
    memset(L, 0, sizeof(*L));
    L->W = outW;
    L->H = outH;
    L->hb = outH < 420 ? 52 : 68;
    L->py = outH - L->hb;
    int scale = outH < 420 ? 1 : 2;
    L->time_scale = scale;
    L->play.x = 20;
    L->play.y = L->py + (L->hb - 28) / 2;
    L->play.w = 28;
    L->play.h = 28;
    L->time_x = 64;
    L->time_y = L->py + (L->hb - 7 * scale) / 2;
    L->bar_x = 64 + 19 * 6 * scale + 16;
    if (L->bar_x > outW - 260) L->bar_x = outW / 2;
    L->bar_w = outW - 130 - L->bar_x;
    if (L->bar_w < 60) L->bar_w = 60;
    L->bar_h = 6;
    L->bar_y = L->py + (L->hb - L->bar_h) / 2;
    L->barhit.x = L->bar_x - 8;
    L->barhit.y = L->py + 12;
    L->barhit.w = L->bar_w + 16;
    L->barhit.h = L->hb - 24;
    L->volhit.x = outW - 112;
    L->volhit.y = L->py + 12;
    L->volhit.w = 72;
    L->volhit.h = L->hb - 24;
    L->fullhit.x = outW - 44;
    L->fullhit.y = L->py + 12;
    L->fullhit.w = 36;
    L->fullhit.h = L->hb - 24;
    (void)p;
}

static int pe_in_rect(const SDL_Rect *r, int x, int y) {
    return x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h;
}

static void pe_video_rect(PePlayer *p, PeLayout *L, int tex_w, int tex_h, SDL_Rect *dst) {
    double dar = (double)tex_w / (double)tex_h * (p->sar > 0 ? p->sar : 1.0);
    if (strcmp(p->aspect, "16:9") == 0) dar = 16.0 / 9.0;
    else if (strcmp(p->aspect, "4:3") == 0) dar = 4.0 / 3.0;
    if (strcmp(p->aspect, "fill") == 0) {
        dst->x = 0; dst->y = 0; dst->w = L->W; dst->h = L->H;
        return;
    }
    double sw = (double)L->W / (double)tex_w;
    double sh = (double)L->H / (double)tex_h;
    double s = sw < sh ? sw : sh;
    int w = (int)(tex_w * s + 0.5);
    int h = (int)(tex_h * s + 0.5);
    if (strcmp(p->aspect, "auto") == 0 && fabs(dar - (double)tex_w / tex_h) < 0.02) {
        /* 方形像素，按纹理比例 */
    } else {
        h = (int)(w / dar + 0.5);
        if (h > L->H) { h = L->H; w = (int)(h * dar + 0.5); }
    }
    dst->w = w;
    dst->h = h;
    dst->x = (L->W - w) / 2;
    dst->y = (L->H - h) / 2;
}

static void pe_render(PePlayer *p, PeLayout *L) {
    SDL_SetRenderDrawColor(p->ren, 0, 0, 0, 255);
    SDL_RenderClear(p->ren);

    if (p->tex && p->tex_w > 0 && p->tex_h > 0) {
        SDL_Rect dst;
        pe_video_rect(p, L, p->tex_w, p->tex_h, &dst);
        SDL_RenderCopy(p->ren, p->tex, NULL, &dst);
    }

    if (!p->show_controls) {
        SDL_RenderPresent(p->ren);
        return;
    }

    SDL_SetRenderDrawColor(p->ren, 0, 0, 0, 165);
    SDL_Rect bar = {0, L->py, L->W, L->hb};
    SDL_RenderFillRect(p->ren, &bar);
    SDL_SetRenderDrawColor(p->ren, 255, 255, 255, 22);
    SDL_Rect line = {0, L->py, L->W, 1};
    SDL_RenderFillRect(p->ren, &line);

    pe_draw_play_icon(p->ren, L->play.x, L->play.y, L->play.w, p->paused);

    double pos = p->dragging ? p->drag_frac * p->duration : pe_clock(p);
    if (p->ended && p->duration > 0) pos = p->duration;
    char cur[32], total[32], label[96];
    pe_fmt_time(cur, sizeof(cur), pos);
    pe_fmt_time(total, sizeof(total), p->duration);
    snprintf(label, sizeof(label), "%s / %s", cur, total);
    pe_draw_text(p->ren, L->time_x, L->time_y, label, L->time_scale, 255, 255, 255, 235);

    double frac = p->duration > 0 ? pos / p->duration : 0;
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;
    SDL_SetRenderDrawColor(p->ren, 255, 255, 255, 70);
    SDL_Rect track = {L->bar_x, L->bar_y, L->bar_w, L->bar_h};
    SDL_RenderFillRect(p->ren, &track);
    SDL_SetRenderDrawColor(p->ren, 30, 144, 255, 255);
    SDL_Rect played = {L->bar_x, L->bar_y, (int)(L->bar_w * frac), L->bar_h};
    SDL_RenderFillRect(p->ren, &played);
    int knobx = L->bar_x + (int)(L->bar_w * frac);
    pe_draw_circle(p->ren, knobx, L->bar_y + L->bar_h / 2, 7);

    pe_draw_speaker(p->ren, L->W - 108, L->py + 20, 24, 255, 255, 255);
    char vol[8];
    snprintf(vol, sizeof(vol), "%d", p->volume);
    pe_draw_text(p->ren, L->W - 74, L->py + (L->hb - 14) / 2, vol, 2, 255, 255, 255, 200);

    pe_draw_fullscreen_icon(p->ren, L->W - 40, L->py + 20, 24);

    SDL_RenderPresent(p->ren);
}

static void pe_show_controls(PePlayer *p) {
    p->show_controls = 1;
    p->hide_at = pe_now() + 2.5;
}

static void pe_handle_key(PePlayer *p, SDL_Keycode key) {
    switch (key) {
    case SDLK_ESCAPE:
        if (p->fullscreen) pe_set_fullscreen(p, 0);
        else { p->closed = 1; p->run_stop = 1; }
        break;
    case SDLK_SPACE:
        pe_toggle_pause(p);
        pe_show_controls(p);
        break;
    case SDLK_LEFT:
        pe_seek_relative(p, -10);
        pe_show_controls(p);
        break;
    case SDLK_RIGHT:
        pe_seek_relative(p, 10);
        pe_show_controls(p);
        break;
    case SDLK_UP:
        pe_set_volume(p, p->volume + 5);
        pe_show_controls(p);
        break;
    case SDLK_DOWN:
        pe_set_volume(p, p->volume - 5);
        pe_show_controls(p);
        break;
    case SDLK_m:
        p->muted = !p->muted;
        pe_show_controls(p);
        break;
    case SDLK_f:
        pe_toggle_fullscreen(p);
        pe_show_controls(p);
        break;
    case SDLK_HOME:
        pe_seek(p, 0);
        pe_show_controls(p);
        break;
    case SDLK_END:
        pe_seek(p, p->duration);
        pe_show_controls(p);
        break;
    default:
        break;
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
        pe_show_controls(p);
        if (p->dragging && L->bar_w > 0) {
            double f = (double)(mx - L->bar_x) / (double)L->bar_w;
            if (f < 0) f = 0;
            if (f > 1) f = 1;
            p->drag_frac = f;
        }
        break;
    }
    case SDL_MOUSEBUTTONDOWN: {
        int mx = (int)(ev->button.x * sx);
        int my = (int)(ev->button.y * sy);
        if (ev->button.button != SDL_BUTTON_LEFT) break;
        if (p->show_controls && pe_in_rect(&L->barhit, mx, my)) {
            if (p->duration > 0) {
                double f = (double)(mx - L->bar_x) / (double)L->bar_w;
                if (f < 0) f = 0;
                if (f > 1) f = 1;
                p->drag_frac = f;
                p->dragging = 1;
            }
        } else if (p->show_controls && pe_in_rect(&L->play, mx, my)) {
            pe_toggle_pause(p);
            pe_show_controls(p);
        } else if (p->show_controls && pe_in_rect(&L->volhit, mx, my)) {
            p->muted = !p->muted;
            pe_show_controls(p);
        } else if (p->show_controls && pe_in_rect(&L->fullhit, mx, my)) {
            pe_toggle_fullscreen(p);
            pe_show_controls(p);
        } else if (ev->button.clicks >= 2) {
            pe_toggle_fullscreen(p);
            pe_show_controls(p);
        } else {
            p->show_controls = !p->show_controls;
            p->hide_at = pe_now() + 2.5;
        }
        break;
    }
    case SDL_MOUSEBUTTONUP:
        if (ev->button.button == SDL_BUTTON_LEFT && p->dragging) {
            p->dragging = 0;
            if (p->duration > 0) pe_seek(p, p->drag_frac * p->duration);
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
    AVFrame *show = NULL;
    double show_pts = 0;
    SDL_LockMutex(p->mu);
    while (p->fcount > 0) {
        PeFrameNode *n = &p->frames[p->fhead];
        if (n->pts <= clock + 0.008) {
            if (show) { av_frame_free(&show); p->frames_dropped++; }
            show = n->frame;
            show_pts = n->pts;
            n->frame = NULL;
            p->fhead = (p->fhead + 1) % PE_MAX_FRAMES;
            p->fcount--;
        } else {
            break;
        }
    }
    SDL_UnlockMutex(p->mu);

    if (show) {
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
        SDL_LockMutex(p->mu);
        if (p->current) av_frame_free(&p->current);
        p->current = show;
        p->current_pts = show_pts;
        p->video_pts = show_pts;
        p->drift_ms = (show_pts - clock) * 1000.0;
        pe_drift_add(p, p->drift_ms);
        p->frames_shown++;
        if (p->first_frame_ms <= 0) p->first_frame_ms = (pe_now() - p->open_t0) * 1000.0;
        p->buffering = 0;
        SDL_UnlockMutex(p->mu);
    }
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

        if (!p->paused && !p->dragging && pe_now() > p->hide_at) p->show_controls = 0;

        pe_update_frame(p);
        pe_render(p, &L);
        SDL_Delay(2);
    }

    p->stop = 1;
    if (p->adev) SDL_PauseAudioDevice(p->adev, 1);
    p->run_returned = 1;
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
}

void pe_ui_hover(PePlayer *p, const char *control) {
    if (!p || !control) return;
    pe_show_controls(p);
    if (strcmp(control, "progress") == 0) return;
    if (strncmp(control, "progress:", 9) == 0 && p->duration > 0) {
        double f = atof(control + 9);
        p->drag_frac = f;
    }
}

void pe_ui_click(PePlayer *p, const char *control) {
    if (!p || !control) return;
    if (strcmp(control, "play") == 0) pe_toggle_pause(p);
    else if (strcmp(control, "pause") == 0) pe_pause(p);
    else if (strcmp(control, "fullscreen") == 0) pe_toggle_fullscreen(p);
    else if (strcmp(control, "mute") == 0) p->muted = !p->muted;
    else if (strncmp(control, "progress:", 9) == 0 && p->duration > 0) {
        pe_seek(p, atof(control + 9) * p->duration);
    }
    pe_show_controls(p);
}

void pe_ui_menu(PePlayer *p, const char *menu) {
    (void)p;
    (void)menu;
}

void pe_ui_key(PePlayer *p, const char *key) {
    if (!p || !key) return;
    if (strcmp(key, "space") == 0) pe_toggle_pause(p);
    else if (strcmp(key, "left") == 0) pe_seek_relative(p, -10);
    else if (strcmp(key, "right") == 0) pe_seek_relative(p, 10);
    else if (strcmp(key, "up") == 0) pe_set_volume(p, p->volume + 5);
    else if (strcmp(key, "down") == 0) pe_set_volume(p, p->volume - 5);
    else if (strcmp(key, "m") == 0) p->muted = !p->muted;
    else if (strcmp(key, "f") == 0) pe_toggle_fullscreen(p);
    else if (strcmp(key, "esc") == 0) pe_set_fullscreen(p, 0);
    pe_show_controls(p);
}

#endif /* _WIN32 || PE_ENGINE_PORTABLE */
