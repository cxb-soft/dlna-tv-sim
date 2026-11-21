// 自研播放核心（macOS spike）：FFmpeg 解封装/解码 + VideoToolbox 硬解 +
// AVSampleBufferDisplayLayer 显示 + AVAudioEngine 出声，音频时钟作主时钟。
//
// 线程模型：
//   demux  线程：av_read_frame → 视频送 VideoToolbox → 入帧队列；音频解码 → 重采样 → 环形缓冲
//   audio  线程：环形缓冲 → AVAudioPCMBuffer → AVAudioPlayerNode
//   render 线程：按音频时钟取帧 → CMSampleBuffer → 显示层
//   main   线程：NSApplication 事件循环（由 Go 调 pe_run 进入）
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>

#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <sys/resource.h>

#include "engine.h"

#define PE_AUDIO_RATE 48000
#define PE_AUDIO_SECONDS 2.0
#define PE_AUDIO_FRAMES ((size_t)(PE_AUDIO_RATE * PE_AUDIO_SECONDS))
#define PE_SCHED_FRAMES 1024
#define PE_MAX_SCHEDULES 24
#define PE_VIDEO_QUEUE_MAX 8
#define PE_PREFILL_SECONDS 0.20
#define PE_DRIFT_SAMPLES 2048

#define PE_LOG(p, fmt, ...) pe_log((p), fmt, ##__VA_ARGS__)

typedef struct PeFrameNode {
    AVFrame *frame;
    double pts;
    struct PeFrameNode *next;
} PeFrameNode;

struct PePlayer {
    // 配置
    char url[4096];
    char title[256];
    int req_w, req_h, req_fs, req_vol, req_mute, req_hw;
    char renderer[16];
    double start_pos;

    // 媒体
    AVFormatContext *fmt;
    AVCodecContext *vctx;
    AVCodecContext *actx;
    AVBufferRef *hwdev;
    int vidx, aidx;
    AVStream *vst, *ast;
    SwrContext *swr;
    float *scratch;
    int scratch_frames;
    double duration;
    int video_w, video_h;
    int has_video, has_audio;
    char vcodec[64], acodec[64];
    int hw_active;
    int logged_pixfmt;
    double frame_interval;
    double last_video_pts;
    int audio_trim;
    double audio_trim_to;

    // 线程与同步
    pthread_t th_demux, th_render, th_audio;
    pthread_mutex_t mu;
    pthread_cond_t cond;
    int running, abort;
    int paused, ended, closed, eof;
    int stopping;
    int run_started, run_returned;
    int seek_req;
    double seek_target;
    int force_present;
    int discarding;      /* seek/stop 时丢弃旧位置解出的音视频帧 */
    double dropping_until;
    double seek_t0;
    int seek_waiting;
    double last_seek_ms;
    int audio_failed;
    int io_error;

    // 视频队列
    PeFrameNode *vhead, *vtail;
    int vcount;

    // 音频环形缓冲（交错立体声 float32）
    float *aring;
    size_t acap, aread, awrite, alen;
    double ring_start_pts;
    double audio_next_pts;
    int sched_buffers;

    // 时钟
    int clock_started;
    double clock_base;
    double anchor_node_sec;
    double clock_frozen;
    double wall_anchor;

    // 统计
    long long frames_shown, frames_dropped;
    double drift_sum, drift_max, drift_last;
    int drift_frames;
    double drift_buf[PE_DRIFT_SAMPLES];
    int drift_count, drift_pos;
    double video_pts_shown;
    double first_frame_ms;
    int first_frame_done;
    double open_t0;
    double cpu_prev, wall_prev, cpu_percent;
    double last_ui_heartbeat;

    void *ui;
    int window_number;
    int fullscreen;
    int volume, muted;
};

// ---------------- 工具 ----------------

static double now_sec(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

static void pe_log(PePlayer *p, const char *fmt, ...) {
    double t = p && p->open_t0 > 0 ? now_sec() - p->open_t0 : 0;
    fprintf(stderr, "[engine %8.3fs] ", t);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    fflush(stderr);
}

static const char *av_text(int err, char *buf, size_t len) {
    if (av_strerror(err, buf, len) < 0) snprintf(buf, len, "errno %d", err);
    return buf;
}

static void cond_wait_ms(PePlayer *p, int ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += (long)ms * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += ts.tv_nsec / 1000000000L;
        ts.tv_nsec %= 1000000000L;
    }
    pthread_cond_timedwait(&p->cond, &p->mu, &ts);
}

static double frame_pts_of(AVStream *st, AVFrame *f, double fallback, double interval) {
    int64_t ts = f->best_effort_timestamp;
    if (ts == AV_NOPTS_VALUE) ts = f->pts;
    if (ts == AV_NOPTS_VALUE) return fallback + interval;
    return (double)ts * av_q2d(st->time_base);
}

static enum AVPixelFormat pe_get_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    }
    return fmts[0];
}

// ---------------- ObjC UI 声明 ----------------

@interface PeVideoView : NSView
@property (nonatomic, assign) PePlayer *ctx;
@end

@interface PeUI : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) PeVideoView *view;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *layer;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode *audioPlayer;
@property (nonatomic, strong) AVAudioFormat *audioFormat;
@property (nonatomic, assign) PePlayer *ctx;
@property (nonatomic, assign) BOOL fsActive;
@property (nonatomic, assign) NSRect savedFrame;
@property (nonatomic, assign) NSWindowStyleMask savedStyle;
@property (nonatomic, assign) struct SwsContext *sws;
@property (nonatomic, strong) NSMutableArray *uiQueue;
@property (nonatomic, strong) NSLock *uiLock;
@property (nonatomic, strong) NSTimer *uiTimer;

- (void)postUIBlock:(void (^)(void))block;
- (void)drainUIQueue;
- (void)applyStopRun;

- (BOOL)openWindowWidth:(int)w height:(int)h fullscreen:(BOOL)fs title:(NSString *)title;
- (BOOL)startAudio;
- (void)setVolume:(int)vol muted:(BOOL)muted;
- (void)setFullscreen:(BOOL)on;
- (void)presentFrame:(AVFrame *)frame pts:(double)pts;
- (void)scheduleAudioFrames:(const float *)interleaved count:(int)frames completion:(void (^)(void))completion;
- (BOOL)rendererFailed;
- (void)flushVideo;
- (void)togglePause;
- (void)seekRelative:(double)delta;
- (double)nodeSeconds;
- (void)playAudio;
- (void)pauseAudio;
- (void)stopAudio;
- (void)teardown;
@end

// ---------------- 队列 ----------------

static void clear_video_queue_locked(PePlayer *p) {
    PeFrameNode *n = p->vhead;
    while (n) {
        PeFrameNode *next = n->next;
        av_frame_free(&n->frame);
        free(n);
        n = next;
    }
    p->vhead = p->vtail = NULL;
    p->vcount = 0;
}

// ---------------- 打开媒体 ----------------

static int open_video_decoder(PePlayer *p) {
    if (p->vidx < 0) return 0;
    p->vst = p->fmt->streams[p->vidx];
    const AVCodec *codec = avcodec_find_decoder(p->vst->codecpar->codec_id);
    if (!codec) {
        PE_LOG(p, "找不到视频解码器 codec_id=%d", (int)p->vst->codecpar->codec_id);
        return -1;
    }
    int attempts = p->req_hw ? 2 : 1;
    for (int attempt = 0; attempt < attempts; attempt++) {
        int use_hw = p->req_hw && attempt == 0;
        p->vctx = avcodec_alloc_context3(codec);
        if (!p->vctx) return -1;
        avcodec_parameters_to_context(p->vctx, p->vst->codecpar);
        p->vctx->pkt_timebase = p->vst->time_base;
        if (use_hw) {
            if (!p->hwdev) {
                int r = av_hwdevice_ctx_create(&p->hwdev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
                if (r < 0) {
                    char eb[128];
                    PE_LOG(p, "VideoToolbox 设备创建失败：%s，改用软解", av_text(r, eb, sizeof(eb)));
                    p->hwdev = NULL;
                    use_hw = 0;
                }
            }
            if (use_hw && p->hwdev) {
                p->vctx->hw_device_ctx = av_buffer_ref(p->hwdev);
                p->vctx->get_format = pe_get_format;
            }
        }
        int r = avcodec_open2(p->vctx, codec, NULL);
        if (r >= 0) {
            p->hw_active = use_hw && p->vctx->hw_device_ctx != NULL;
            break;
        }
        char eb[128];
        PE_LOG(p, "视频解码器打开失败（%s）：%s", use_hw ? "硬解" : "软解", av_text(r, eb, sizeof(eb)));
        avcodec_free_context(&p->vctx);
        if (!use_hw) return -1;
    }
    if (!p->vctx) return -1;
    p->video_w = p->vst->codecpar->width;
    p->video_h = p->vst->codecpar->height;
    if (p->video_w <= 0) p->video_w = p->vctx->width;
    if (p->video_h <= 0) p->video_h = p->vctx->height;
    snprintf(p->vcodec, sizeof(p->vcodec), "%s", avcodec_get_name(p->vst->codecpar->codec_id));
    AVRational fr = av_guess_frame_rate(p->fmt, p->vst, NULL);
    double fps = (fr.num > 0 && fr.den > 0) ? av_q2d(fr) : 30.0;
    if (fps <= 0 || fps > 240) fps = 30.0;
    p->frame_interval = 1.0 / fps;
    p->has_video = 1;

    // 硬解是否真的被系统支持：VTIsHardwareDecodeSupported 只能佐证设备能力，
    // 实际是否走硬解看首帧 format 是否为 AV_PIX_FMT_VIDEOTOOLBOX（见 render 日志）。
    CMVideoCodecType ct = kCMVideoCodecType_H264;
    if (p->vst->codecpar->codec_id == AV_CODEC_ID_HEVC) ct = kCMVideoCodecType_HEVC;
    PE_LOG(p, "视频：%s %dx%d %.3ffps，请求硬解=%d，VideoToolbox 支持=%d",
           p->vcodec, p->video_w, p->video_h, fps, p->req_hw,
           (int)VTIsHardwareDecodeSupported(ct));
    return 0;
}

static int open_audio_decoder(PePlayer *p) {
    if (p->aidx < 0) return 0;
    p->ast = p->fmt->streams[p->aidx];
    const AVCodec *codec = avcodec_find_decoder(p->ast->codecpar->codec_id);
    if (!codec) {
        PE_LOG(p, "找不到音频解码器 codec_id=%d", (int)p->ast->codecpar->codec_id);
        return -1;
    }
    p->actx = avcodec_alloc_context3(codec);
    if (!p->actx) return -1;
    avcodec_parameters_to_context(p->actx, p->ast->codecpar);
    p->actx->pkt_timebase = p->ast->time_base;
    int r = avcodec_open2(p->actx, codec, NULL);
    if (r < 0) {
        char eb[128];
        PE_LOG(p, "音频解码器打开失败：%s", av_text(r, eb, sizeof(eb)));
        avcodec_free_context(&p->actx);
        return -1;
    }
    if (p->actx->ch_layout.nb_channels <= 0) av_channel_layout_default(&p->actx->ch_layout, 2);
    if (p->actx->sample_rate <= 0) {
        PE_LOG(p, "音频采样率无效，跳过音频");
        avcodec_free_context(&p->actx);
        return -1;
    }
    AVChannelLayout out_ch = AV_CHANNEL_LAYOUT_STEREO;
    r = swr_alloc_set_opts2(&p->swr, &out_ch, AV_SAMPLE_FMT_FLT, PE_AUDIO_RATE,
                            &p->actx->ch_layout, p->actx->sample_fmt, p->actx->sample_rate, 0, NULL);
    if (r < 0 || !p->swr) {
        char eb[128];
        PE_LOG(p, "重采样器创建失败：%s", av_text(r, eb, sizeof(eb)));
        if (p->swr) swr_free(&p->swr);
        avcodec_free_context(&p->actx);
        return -1;
    }
    r = swr_init(p->swr);
    if (r < 0) {
        char eb[128];
        PE_LOG(p, "重采样器初始化失败：%s", av_text(r, eb, sizeof(eb)));
        swr_free(&p->swr);
        avcodec_free_context(&p->actx);
        return -1;
    }
    p->scratch_frames = PE_SCHED_FRAMES * 8;
    p->scratch = malloc(sizeof(float) * 2 * (size_t)p->scratch_frames);
    snprintf(p->acodec, sizeof(p->acodec), "%s", avcodec_get_name(p->ast->codecpar->codec_id));
    p->has_audio = 1;
    PE_LOG(p, "音频：%s %dHz %dch → %dHz 立体声 float32",
           p->acodec, p->actx->sample_rate, p->actx->ch_layout.nb_channels, PE_AUDIO_RATE);
    return 0;
}

static int open_media(PePlayer *p) {
    int r = avformat_open_input(&p->fmt, p->url, NULL, NULL);
    if (r < 0) {
        char eb[128];
        PE_LOG(p, "打开输入失败：%s", av_text(r, eb, sizeof(eb)));
        return -1;
    }
    r = avformat_find_stream_info(p->fmt, NULL);
    if (r < 0) {
        char eb[128];
        PE_LOG(p, "读取流信息失败：%s", av_text(r, eb, sizeof(eb)));
        return -1;
    }
    p->duration = p->fmt->duration > 0 ? (double)p->fmt->duration / AV_TIME_BASE : 0;
    p->vidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    p->aidx = av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    PE_LOG(p, "容器：%s，时长 %.3fs，视频流=%d 音频流=%d",
           p->fmt->iformat->name, p->duration, p->vidx, p->aidx);
    if (p->vidx < 0 && p->aidx < 0) {
        PE_LOG(p, "没有可播放的音视频流");
        return -1;
    }
    if (open_video_decoder(p) < 0) return -1;
    if (open_audio_decoder(p) < 0) {
        // 音频解不出来不影响出画面，主时钟退回墙钟。
    }
    return 0;
}

// ---------------- 时钟 ----------------

static double clock_locked(PePlayer *p) {
    if (!p->clock_started) return p->clock_frozen;
    if (p->paused || p->ended) return p->clock_frozen;
    double pos = p->clock_base;
    if (p->has_audio && !p->audio_failed) {
        double ns = [(__bridge PeUI *)p->ui nodeSeconds];
        if (ns < 0) return p->clock_frozen;
        pos = p->clock_base + (ns - p->anchor_node_sec);
    } else {
        pos = p->clock_base + (now_sec() - p->wall_anchor);
    }
    if (pos < 0) pos = 0;
    if (p->duration > 0 && pos > p->duration) pos = p->duration;
    return pos;
}

// ---------------- 视频解码 ----------------

static void enqueue_video_frame(PePlayer *p, AVFrame *frame, double pts) {
    AVFrame *clone = av_frame_clone(frame);
    if (!clone) return;
    PeFrameNode *node = calloc(1, sizeof(*node));
    if (!node) {
        av_frame_free(&clone);
        return;
    }
    node->frame = clone;
    node->pts = pts;

    pthread_mutex_lock(&p->mu);
    while (!p->abort && !p->seek_req && p->vcount >= PE_VIDEO_QUEUE_MAX + 4) {
        cond_wait_ms(p, 20);
    }
    if (p->abort || p->seek_req || p->discarding) {
        pthread_mutex_unlock(&p->mu);
        av_frame_free(&clone);
        free(node);
        return;
    }
    if (p->dropping_until >= 0 && pts + 0.0005 < p->dropping_until) {
        pthread_mutex_unlock(&p->mu);
        av_frame_free(&clone);
        free(node);
        return;
    }
    if (p->dropping_until >= 0) {
        p->dropping_until = -1;
        p->force_present = 1;
        PE_LOG(p, "seek 后首个视频帧 pts=%.3f", pts);
    }
    if (p->vtail) p->vtail->next = node;
    else p->vhead = node;
    p->vtail = node;
    p->vcount++;
    p->last_video_pts = pts;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);
}

static void decode_video_packet(PePlayer *p, AVPacket *pkt, AVFrame *frame) {
    int r = avcodec_send_packet(p->vctx, pkt);
    if (r < 0 && r != AVERROR(EAGAIN)) return;
    while (avcodec_receive_frame(p->vctx, frame) == 0) {
        if (!p->logged_pixfmt) {
            p->logged_pixfmt = 1;
            PE_LOG(p, "首个视频帧像素格式：%s（videotoolbox=%d）",
                   av_get_pix_fmt_name(frame->format), (int)AV_PIX_FMT_VIDEOTOOLBOX);
        }
        if (!p->hw_active && frame->format == AV_PIX_FMT_VIDEOTOOLBOX) p->hw_active = 1;
        if (p->hw_active && frame->format != AV_PIX_FMT_VIDEOTOOLBOX) p->hw_active = 0;
        double pts = frame_pts_of(p->vst, frame, p->last_video_pts, p->frame_interval);
        enqueue_video_frame(p, frame, pts);
        av_frame_unref(frame);
    }
}

// ---------------- 音频解码 ----------------

static void handle_audio_frame(PePlayer *p, AVFrame *frame) {
    if (!p->swr || frame->nb_samples <= 0) return;
    double fpts = frame_pts_of(p->ast, frame, p->audio_next_pts, 0);
    double dur = (double)frame->nb_samples / frame->sample_rate;
    int max_out = (int)av_rescale_rnd(
        swr_get_delay(p->swr, frame->sample_rate) + frame->nb_samples,
        PE_AUDIO_RATE, frame->sample_rate, AV_ROUND_UP);
    if (max_out <= 0) return;
    if (max_out > p->scratch_frames) {
        int cap = max_out + 1024;
        float *grown = realloc(p->scratch, sizeof(float) * 2 * (size_t)cap);
        if (!grown) return;
        p->scratch = grown;
        p->scratch_frames = cap;
    }
    uint8_t *outp[1] = {(uint8_t *)p->scratch};
    int got = swr_convert(p->swr, outp, max_out,
                          (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (got <= 0) return;

    int skip = 0;
    pthread_mutex_lock(&p->mu);
    if (p->discarding) {
        pthread_mutex_unlock(&p->mu);
        return;
    }
    if (p->audio_trim) {
        if (fpts + dur <= p->audio_trim_to + 0.0005) {
            p->audio_next_pts = fpts + dur;
            pthread_mutex_unlock(&p->mu);
            return;
        }
        if (fpts < p->audio_trim_to) skip = (int)llround((p->audio_trim_to - fpts) * PE_AUDIO_RATE);
        if (skip < 0) skip = 0;
        if (skip >= got) skip = got - 1;
        p->audio_trim = 0;
    }
    int w = skip;
    while (w < got) {
        while (p->alen >= p->acap && !p->abort && !p->seek_req && !p->discarding) cond_wait_ms(p, 20);
        if (p->abort || p->seek_req || p->discarding) break;
        size_t space = p->acap - p->alen;
        size_t n = (size_t)(got - w);
        if (n > space) n = space;
        double chunk_pts = fpts + (double)w / PE_AUDIO_RATE;
        size_t idx = p->awrite;
        size_t first = (n <= p->acap - idx) ? n : p->acap - idx;
        memcpy(p->aring + idx * 2, p->scratch + (size_t)w * 2, first * 2 * sizeof(float));
        if (n > first) {
            memcpy(p->aring, p->scratch + ((size_t)w + first) * 2,
                   (n - first) * 2 * sizeof(float));
        }
        if (p->alen == 0) p->ring_start_pts = chunk_pts;
        p->awrite = (idx + n) % p->acap;
        p->alen += n;
        w += (int)n;
    }
    p->audio_next_pts = fpts + dur;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);
}

static void decode_audio_packet(PePlayer *p, AVPacket *pkt, AVFrame *frame) {
    int r = avcodec_send_packet(p->actx, pkt);
    if (r < 0 && r != AVERROR(EAGAIN)) return;
    while (avcodec_receive_frame(p->actx, frame) == 0) {
        handle_audio_frame(p, frame);
        av_frame_unref(frame);
    }
}

// ---------------- seek / EOF ----------------

static void perform_seek(PePlayer *p, double target) {
    int64_t ts = (int64_t)(target * AV_TIME_BASE);
    int r = avformat_seek_file(p->fmt, -1, INT64_MIN, ts, INT64_MAX, AVSEEK_FLAG_BACKWARD);
    if (r < 0) r = av_seek_frame(p->fmt, -1, ts, AVSEEK_FLAG_BACKWARD);
    if (r < 0) {
        char eb[128];
        PE_LOG(p, "seek 到 %.3f 失败：%s", target, av_text(r, eb, sizeof(eb)));
    }
    if (p->vctx) avcodec_flush_buffers(p->vctx);
    if (p->actx) avcodec_flush_buffers(p->actx);
    if (p->swr) {
        swr_close(p->swr);
        swr_init(p->swr);
    }
    pthread_mutex_lock(&p->mu);
    clear_video_queue_locked(p);
    p->discarding = 0;
    p->alen = 0;
    p->aread = p->awrite = 0;
    p->ring_start_pts = target;
    p->audio_next_pts = target;
    p->audio_trim = 1;
    p->audio_trim_to = target;
    p->eof = 0;
    p->io_error = 0;
    p->dropping_until = target;
    p->force_present = 0;
    p->last_video_pts = target - p->frame_interval;
    p->sched_buffers = 0;
    if (!p->has_audio || p->audio_failed) {
        p->clock_base = target;
        p->wall_anchor = now_sec();
        p->clock_started = 1;
    } else {
        p->clock_started = 0;
    }
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);
    PE_LOG(p, "seek 完成：目标 %.3fs", target);
}

static void drain_decoders(PePlayer *p, AVFrame *frame) {
    if (p->vctx) {
        avcodec_send_packet(p->vctx, NULL);
        while (avcodec_receive_frame(p->vctx, frame) == 0) {
            double pts = frame_pts_of(p->vst, frame, p->last_video_pts, p->frame_interval);
            enqueue_video_frame(p, frame, pts);
            av_frame_unref(frame);
        }
    }
    if (p->actx) {
        avcodec_send_packet(p->actx, NULL);
        while (avcodec_receive_frame(p->actx, frame) == 0) {
            handle_audio_frame(p, frame);
            av_frame_unref(frame);
        }
    }
}

// ---------------- 线程 ----------------

static void *demux_main(void *arg) {
    PePlayer *p = arg;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    while (!p->abort) {
        pthread_mutex_lock(&p->mu);
        while (!p->abort && !p->seek_req &&
               (p->vcount >= PE_VIDEO_QUEUE_MAX ||
                (p->has_audio && p->alen + PE_AUDIO_RATE / 2 >= p->acap))) {
            cond_wait_ms(p, 50);
        }
        if (p->abort) {
            pthread_mutex_unlock(&p->mu);
            break;
        }
        int do_seek = p->seek_req;
        double target = p->seek_target;
        if (do_seek) p->seek_req = 0;
        int at_eof = p->eof;
        pthread_mutex_unlock(&p->mu);

        if (do_seek) {
            perform_seek(p, target);
            continue;
        }
        if (at_eof) {
            pthread_mutex_lock(&p->mu);
            cond_wait_ms(p, 100);
            pthread_mutex_unlock(&p->mu);
            continue;
        }

        int r = av_read_frame(p->fmt, pkt);
        if (r == AVERROR_EOF) {
            drain_decoders(p, frame);
            pthread_mutex_lock(&p->mu);
            p->eof = 1;
            pthread_cond_broadcast(&p->cond);
            pthread_mutex_unlock(&p->mu);
            PE_LOG(p, "读到结尾，解码器已 drain");
            continue;
        }
        if (r < 0) {
            if (r == AVERROR(EAGAIN)) {
                usleep(2000);
                continue;
            }
            char eb[128];
            PE_LOG(p, "读包失败：%s", av_text(r, eb, sizeof(eb)));
            pthread_mutex_lock(&p->mu);
            p->eof = 1;
            p->io_error = 1;
            pthread_cond_broadcast(&p->cond);
            pthread_mutex_unlock(&p->mu);
            continue;
        }
        if (pkt->stream_index == p->vidx && p->vctx) decode_video_packet(p, pkt, frame);
        else if (pkt->stream_index == p->aidx && p->actx) decode_audio_packet(p, pkt, frame);
        av_packet_unref(pkt);
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return NULL;
}

static void record_present_locked(PePlayer *p, double pts, double clock, int forced) {
    p->frames_shown++;
    p->video_pts_shown = pts;
    if (!forced) {
        double drift = (pts - clock) * 1000.0;
        p->drift_last = drift;
        p->drift_sum += drift;
        p->drift_frames++;
        if (fabs(drift) > p->drift_max) p->drift_max = fabs(drift);
        p->drift_buf[p->drift_pos] = fabs(drift);
        p->drift_pos = (p->drift_pos + 1) % PE_DRIFT_SAMPLES;
        if (p->drift_count < PE_DRIFT_SAMPLES) p->drift_count++;
    }
    if (!p->first_frame_done) {
        p->first_frame_done = 1;
        p->first_frame_ms = (now_sec() - p->open_t0) * 1000.0;
        PE_LOG(p, "首帧显示完成：%.1fms", p->first_frame_ms);
    }
    if (p->seek_waiting) {
        p->seek_waiting = 0;
        p->last_seek_ms = (now_sec() - p->seek_t0) * 1000.0;
        PE_LOG(p, "seek 响应：%.1fms（目标 %.3fs，首帧 pts %.3fs）",
               p->last_seek_ms, p->seek_target, pts);
    }
}

static void *render_main(void *arg) {
    PePlayer *p = arg;
    while (!p->abort) {
        pthread_mutex_lock(&p->mu);
        if (p->abort) {
            pthread_mutex_unlock(&p->mu);
            break;
        }
        if (p->paused || p->ended) {
            cond_wait_ms(p, 20);
            pthread_mutex_unlock(&p->mu);
            continue;
        }
        if (p->vcount == 0) {
            pthread_mutex_unlock(&p->mu);
            usleep(3000);
            continue;
        }
        double clk = clock_locked(p);
        int force = p->force_present;
        PeFrameNode *node = p->vhead;
        if (!force && !p->clock_started) {
            pthread_mutex_unlock(&p->mu);
            usleep(3000);
            continue;
        }
        if (!force && node->pts > clk + 0.006) {
            pthread_mutex_unlock(&p->mu);
            usleep(2000);
            continue;
        }
        p->vhead = node->next;
        if (!p->vhead) p->vtail = NULL;
        p->vcount--;
        if (force) p->force_present = 0;
        double pts = node->pts;
        AVFrame *frame = node->frame;
        free(node);
        int drop = !force && (pts < clk - 0.080);
        if (drop) p->frames_dropped++;
        pthread_cond_broadcast(&p->cond);
        pthread_mutex_unlock(&p->mu);

        if (!drop) {
            [(__bridge PeUI *)p->ui presentFrame:frame pts:pts];
            pthread_mutex_lock(&p->mu);
            record_present_locked(p, pts, clock_locked(p), force);
            pthread_mutex_unlock(&p->mu);
        }
        av_frame_free(&frame);
    }
    return NULL;
}

static void *audio_main(void *arg) {
    PePlayer *p = arg;
    float *tmp = malloc(sizeof(float) * 2 * PE_SCHED_FRAMES);
    PeUI *ui = (__bridge PeUI *)p->ui;
    while (!p->abort) {
        pthread_mutex_lock(&p->mu);
        if (p->abort) {
            pthread_mutex_unlock(&p->mu);
            break;
        }
        if (!p->has_audio || p->audio_failed || p->paused || p->ended) {
            cond_wait_ms(p, 20);
            pthread_mutex_unlock(&p->mu);
            continue;
        }
        double need = p->clock_started ? 0.02 : PE_PREFILL_SECONDS;
        if ((double)p->alen / PE_AUDIO_RATE < need || p->sched_buffers >= PE_MAX_SCHEDULES) {
            cond_wait_ms(p, 10);
            pthread_mutex_unlock(&p->mu);
            continue;
        }
        size_t n = p->alen < PE_SCHED_FRAMES ? p->alen : PE_SCHED_FRAMES;
        double buf_pts = p->ring_start_pts;
        for (size_t i = 0; i < n; i++) {
            size_t idx = (p->aread + i) % p->acap;
            tmp[i * 2] = p->aring[idx * 2];
            tmp[i * 2 + 1] = p->aring[idx * 2 + 1];
        }
        p->aread = (p->aread + n) % p->acap;
        p->alen -= n;
        p->ring_start_pts += (double)n / PE_AUDIO_RATE;
        p->sched_buffers++;
        pthread_cond_broadcast(&p->cond);
        pthread_mutex_unlock(&p->mu);

        double node_sec = [ui nodeSeconds];
        if (node_sec < 0) node_sec = 0;

        pthread_mutex_lock(&p->mu);
        int need_play = 0;
        if (!p->clock_started && !p->paused) {
            p->clock_base = buf_pts;
            p->anchor_node_sec = node_sec;
            p->clock_started = 1;
            p->clock_frozen = buf_pts;
            need_play = 1;
            PE_LOG(p, "音频时钟起点 %.3fs（节点时间 %.3fs）", buf_pts, node_sec);
        }
        pthread_mutex_unlock(&p->mu);

        [ui scheduleAudioFrames:tmp count:(int)n completion:^{
            pthread_mutex_lock(&p->mu);
            if (p->sched_buffers > 0) p->sched_buffers--;
            pthread_cond_broadcast(&p->cond);
            pthread_mutex_unlock(&p->mu);
        }];
        if (need_play) [ui playAudio];
    }
    free(tmp);
    return NULL;
}

// ---------------- 公开 API ----------------

const char *pe_ffmpeg_version(void) {
    return av_version_info();
}

double pe_now(void) {
    return now_sec();
}

PePlayer *pe_open(const PeConfig *cfg, char *errbuf, int errlen) {
    if (errbuf && errlen > 0) errbuf[0] = 0;
    if (!cfg || !cfg->url || !cfg->url[0]) {
        if (errbuf) snprintf(errbuf, errlen, "没有给播放地址");
        return NULL;
    }
    PePlayer *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->open_t0 = now_sec();
    snprintf(p->url, sizeof(p->url), "%s", cfg->url);
    snprintf(p->title, sizeof(p->title), "%s", cfg->title ? cfg->title : "DLNA 电视");
    snprintf(p->renderer, sizeof(p->renderer), "%s", cfg->renderer ? cfg->renderer : "layer");
    p->req_w = cfg->width > 0 ? cfg->width : 1280;
    p->req_h = cfg->height > 0 ? cfg->height : 720;
    p->req_fs = cfg->fullscreen != 0;
    p->req_hw = cfg->hardware != 0;
    p->volume = cfg->volume < 0 ? 0 : (cfg->volume > 100 ? 100 : cfg->volume);
    p->muted = cfg->muted != 0;
    p->start_pos = cfg->start_position > 0 ? cfg->start_position : 0;
    p->dropping_until = -1;
    p->paused = 0;
    p->frames_shown = 0;
    p->first_frame_done = 0;
    p->audio_trim = 0;
    p->window_number = 0;
    p->acap = PE_AUDIO_FRAMES;
    p->aring = calloc(p->acap * 2, sizeof(float));
    p->vhead = p->vtail = NULL;

    pthread_mutex_init(&p->mu, NULL);
    pthread_cond_init(&p->cond, NULL);

    PE_LOG(p, "打开 %s", p->url);
    PE_LOG(p, "本线程是否主线程：%d", (int)pthread_main_np());
    PE_LOG(p, "FFmpeg %s，硬件 %s", av_version_info(), av_hwdevice_get_type_name(AV_HWDEVICE_TYPE_VIDEOTOOLBOX));
    if (open_media(p) < 0) {
        if (errbuf) snprintf(errbuf, errlen, "打开媒体失败，详情见日志");
        avformat_close_input(&p->fmt);
        free(p->aring);
        return NULL;
    }

    PeUI *ui = [[PeUI alloc] init];
    ui.ctx = p;
    p->ui = (__bridge_retained void *)ui;
    int win_w = p->req_w;
    int win_h = p->req_h;
    if (p->video_w > 0 && p->video_h > 0 && p->req_w == 1280 && p->req_h == 720) {
        // 默认窗口贴合视频比例
        win_w = p->video_w;
        win_h = p->video_h;
        if (win_w > 1600) {
            win_h = (int)((double)p->video_h * 1600.0 / p->video_w);
            win_w = 1600;
        }
    }
    if (![ui openWindowWidth:win_w height:win_h fullscreen:p->req_fs
                       title:[NSString stringWithUTF8String:p->title]]) {
        if (errbuf) snprintf(errbuf, errlen, "创建窗口失败");
        [ui teardown];
        avformat_close_input(&p->fmt);
        free(p->aring);
        return NULL;
    }
    p->window_number = (int)ui.window.windowNumber;
    if (p->has_audio) {
        if ([ui startAudio]) {
            [ui setVolume:p->volume muted:p->muted];
        } else {
            p->audio_failed = 1;
            p->has_audio = 0;
            PE_LOG(p, "音频引擎启动失败，改用墙钟并静音");
        }
    }
    p->clock_frozen = p->start_pos;
    p->running = 1;
    pthread_create(&p->th_demux, NULL, demux_main, p);
    pthread_create(&p->th_audio, NULL, audio_main, p);
    pthread_create(&p->th_render, NULL, render_main, p);
    if (p->start_pos > 0) pe_seek(p, p->start_pos);
    PE_LOG(p, "播放器就绪：窗口 %dx%d，全屏=%d，音量=%d，静音=%d",
           win_w, win_h, p->req_fs, p->volume, p->muted);
    return p;
}

void pe_play(PePlayer *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    int wasPaused = p->paused && !p->ended;
    pthread_mutex_unlock(&p->mu);
    if (!wasPaused) return;
    // 先让节点真的跑起来，再读节点时间做锚点：pause 后 playerTimeForNodeTime
    // 可能返回 nil，沿用旧锚点会让音频时钟把暂停时长也算进去。
    if (p->has_audio && !p->audio_failed) [(__bridge PeUI *)p->ui playAudio];
    double ns = [(__bridge PeUI *)p->ui nodeSeconds];
    pthread_mutex_lock(&p->mu);
    if (p->paused) {
        p->paused = 0;
        if (p->has_audio && !p->audio_failed && p->clock_started) {
            p->clock_base = p->clock_frozen;
            if (ns >= 0) p->anchor_node_sec = ns;
            PE_LOG(p, "resume：base=%.3f anchor_node=%.3f（读到 %.3f）",
                   p->clock_base, p->anchor_node_sec, ns);
        } else if (!p->has_audio || p->audio_failed) {
            p->clock_base = p->clock_frozen;
            p->wall_anchor = now_sec();
            p->clock_started = 1;
        }
        pthread_cond_broadcast(&p->cond);
    }
    pthread_mutex_unlock(&p->mu);
}

void pe_pause(PePlayer *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    if (!p->paused && !p->ended) {
        p->clock_frozen = clock_locked(p);
        p->paused = 1;
        PE_LOG(p, "pause：pos=%.3f node=%.3f", p->clock_frozen,
               [(__bridge PeUI *)p->ui nodeSeconds]);
    }
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);
    if (p->has_audio && !p->audio_failed) [(__bridge PeUI *)p->ui pauseAudio];
}

void pe_toggle_pause(PePlayer *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    int paused = p->paused;
    pthread_mutex_unlock(&p->mu);
    if (paused) pe_play(p);
    else pe_pause(p);
}

void pe_stop(PePlayer *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->paused = 1;
    p->ended = 0;
    p->clock_frozen = 0;
    p->clock_started = 0;
    p->clock_base = 0;
    p->seek_req = 1;
    p->seek_target = 0;
    p->seek_t0 = now_sec();
    p->seek_waiting = 0;
    p->dropping_until = 0;
    p->force_present = 0;
    p->discarding = 1;
    p->alen = 0;
    p->aread = p->awrite = 0;
    p->ring_start_pts = 0;
    p->audio_next_pts = 0;
    p->audio_trim = 1;
    p->audio_trim_to = 0;
    p->sched_buffers = 0;
    clear_video_queue_locked(p);
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    [ui stopAudio];
    [ui flushVideo];
    PE_LOG(p, "stop");
}

void pe_seek(PePlayer *p, double seconds) {
    if (!p) return;
    if (seconds < 0) seconds = 0;
    pthread_mutex_lock(&p->mu);
    double target = seconds;
    if (p->duration > 0 && target > p->duration - 0.05) target = p->duration - 0.05;
    if (target < 0) target = 0;
    p->seek_req = 1;
    p->seek_target = target;
    p->seek_t0 = now_sec();
    p->seek_waiting = 1;
    p->clock_frozen = target;
    p->clock_started = 0;
    p->clock_base = target;
    p->ended = 0;
    p->force_present = 0;
    p->discarding = 1;
    p->dropping_until = target;
    p->drift_sum = 0;
    p->drift_max = 0;
    p->drift_last = 0;
    p->drift_frames = 0;
    p->drift_count = 0;
    p->drift_pos = 0;
    clear_video_queue_locked(p);
    p->alen = 0;
    p->aread = p->awrite = 0;
    p->ring_start_pts = target;
    p->audio_next_pts = target;
    p->audio_trim = 1;
    p->audio_trim_to = target;
    p->sched_buffers = 0;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);
    [(__bridge PeUI *)p->ui stopAudio];
    PE_LOG(p, "seek 请求：%.3fs", target);
}

void pe_seek_relative(PePlayer *p, double delta) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    double pos = p->paused ? p->clock_frozen : clock_locked(p);
    pthread_mutex_unlock(&p->mu);
    pe_seek(p, pos + delta);
}

void pe_set_volume(PePlayer *p, int volume) {
    if (!p) return;
    if (volume < 0) volume = 0;
    if (volume > 100) volume = 100;
    pthread_mutex_lock(&p->mu);
    p->volume = volume;
    int muted = p->muted;
    pthread_mutex_unlock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    if (!ui) return;
    [ui postUIBlock:^{ [ui setVolume:volume muted:muted != 0]; }];
}

void pe_set_mute(PePlayer *p, int muted) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->muted = muted != 0;
    int vol = p->volume;
    pthread_mutex_unlock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    if (!ui) return;
    [ui postUIBlock:^{ [ui setVolume:vol muted:muted != 0]; }];
}

int pe_get_volume(PePlayer *p) {
    if (!p) return 0;
    pthread_mutex_lock(&p->mu);
    int v = p->volume;
    pthread_mutex_unlock(&p->mu);
    return v;
}

int pe_get_mute(PePlayer *p) {
    if (!p) return 0;
    pthread_mutex_lock(&p->mu);
    int m = p->muted;
    pthread_mutex_unlock(&p->mu);
    return m;
}

void pe_set_fullscreen(PePlayer *p, int on) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->fullscreen = on != 0;
    pthread_mutex_unlock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    if (!ui) return;
    // AppKit 的窗口操作只能在主线程做。
    [ui postUIBlock:^{ [ui setFullscreen:on != 0]; }];
}

void pe_toggle_fullscreen(PePlayer *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->fullscreen = !p->fullscreen;
    int on = p->fullscreen;
    pthread_mutex_unlock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    if (!ui) return;
    [ui postUIBlock:^{ [ui setFullscreen:on != 0]; }];
}

// 仅用于验证“窗口被关掉”的回调路径：像用户点红点一样关闭窗口。
void pe_close_window(PePlayer *p) {
    if (!p) return;
    PeUI *ui = (__bridge PeUI *)p->ui;
    if (!ui) return;
    [ui postUIBlock:^{ [ui.window close]; }];
}
const char *pe_video_codec(PePlayer *p) { return p ? p->vcodec : ""; }
const char *pe_audio_codec(PePlayer *p) { return p ? p->acodec : ""; }

const char *pe_hwdevice_name(PePlayer *p) {
    (void)p;
    return av_hwdevice_get_type_name(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
}

int pe_window_number(PePlayer *p) { return p ? p->window_number : 0; }

static double drift_p95_locked(PePlayer *p) {
    int n = p->drift_count < PE_DRIFT_SAMPLES ? p->drift_count : PE_DRIFT_SAMPLES;
    if (n <= 0) return 0;
    double tmp[PE_DRIFT_SAMPLES];
    memcpy(tmp, p->drift_buf, sizeof(double) * (size_t)n);
    for (int i = 1; i < n; i++) {
        double v = tmp[i];
        int j = i - 1;
        while (j >= 0 && tmp[j] > v) {
            tmp[j + 1] = tmp[j];
            j--;
        }
        tmp[j + 1] = v;
    }
    int idx = (int)((double)n * 0.95);
    if (idx >= n) idx = n - 1;
    return tmp[idx];
}

void pe_get_status(PePlayer *p, PeStatus *out) {
    if (!p || !out) return;
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&p->mu);
    out->position = p->paused || p->ended ? p->clock_frozen : clock_locked(p);
    if (p->ended && p->duration > 0) out->position = p->duration;
    out->duration = p->duration;
    out->clock = clock_locked(p);
    out->video_pts = p->video_pts_shown;
    out->drift_ms = p->drift_last;
    out->drift_avg_ms = p->drift_frames > 0 ? p->drift_sum / (double)p->drift_frames : 0;
    out->drift_p95_ms = drift_p95_locked(p);
    out->drift_max_ms = p->drift_max;
    out->frames_shown = p->frames_shown;
    out->frames_dropped = p->frames_dropped;
    out->first_frame_ms = p->first_frame_ms;
    out->last_seek_ms = p->last_seek_ms;
    out->width = p->video_w;
    out->height = p->video_h;
    out->fps = p->frame_interval > 0 ? (int)llround(1.0 / p->frame_interval) : 0;
    out->paused = p->paused;
    out->ended = p->ended;
    out->closed = p->closed;
    out->fullscreen = p->fullscreen;
    out->hardware_decode = p->hw_active;
    out->has_video = p->has_video;
    out->has_audio = p->has_audio && !p->audio_failed;
    out->volume = p->volume;
    out->muted = p->muted;
    out->window_number = p->window_number;
    out->buffered_ms = ((double)p->vcount * p->frame_interval + (double)p->alen / PE_AUDIO_RATE) * 1000.0;
    pthread_mutex_unlock(&p->mu);

    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double cpu = (double)ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 +
                 (double)ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
    double t = now_sec();
    pthread_mutex_lock(&p->mu);
    if (p->wall_prev > 0 && t > p->wall_prev + 0.001) {
        double inst = (cpu - p->cpu_prev) / (t - p->wall_prev) * 100.0;
        p->cpu_percent = p->cpu_percent > 0 ? p->cpu_percent * 0.6 + inst * 0.4 : inst;
    }
    p->cpu_prev = cpu;
    p->wall_prev = t;
    out->cpu_percent = p->cpu_percent;
    pthread_mutex_unlock(&p->mu);
}

void pe_run(PePlayer *p) {
    if (!p) return;
    PE_LOG(p, "进入 NSApp run（主线程=%d）", (int)pthread_main_np());
    pthread_mutex_lock(&p->mu);
    p->run_started = 1;
    pthread_mutex_unlock(&p->mu);
    [NSApp run];
    PE_LOG(p, "NSApp run 已返回");
    // 事件循环退出后回到主线程，在这里收尾窗口（AppKit 要求主线程）。
    pthread_mutex_lock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    p->ui = NULL;
    p->run_returned = 1;
    pthread_mutex_unlock(&p->mu);
    if (ui) {
        [ui teardown];
        CFRelease((__bridge CFTypeRef)ui);
    }
}

void pe_stop_run(PePlayer *p) {
    (void)p;
    // CFRunLoopStop 线程安全，不依赖主队列是否卡住；再唤醒一次叫 NSApp 收尾。
    CFRunLoopStop(CFRunLoopGetMain());
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp stop:nil];
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0];
        [NSApp postEvent:e atStart:YES];
    });
}
void pe_close(PePlayer *p) {
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    if (p->stopping) {
        pthread_mutex_unlock(&p->mu);
        return;
    }
    p->stopping = 1;
    p->closed = 1;
    p->abort = 1;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mu);

    pthread_join(p->th_demux, NULL);
    pthread_join(p->th_audio, NULL);
    pthread_join(p->th_render, NULL);

    pthread_mutex_lock(&p->mu);
    PeUI *ui = (__bridge PeUI *)p->ui;
    pthread_mutex_unlock(&p->mu);
    if (ui) [ui stopAudio];
    pe_stop_run(p);
}

// 由 Go 在 pe_run 返回后调用，负责释放媒体资源与结构体。
void pe_destroy(PePlayer *p) {
    if (!p) return;
    if (p->vctx) avcodec_free_context(&p->vctx);
    if (p->actx) avcodec_free_context(&p->actx);
    if (p->fmt) avformat_close_input(&p->fmt);
    if (p->swr) swr_free(&p->swr);
    if (p->hwdev) av_buffer_unref(&p->hwdev);
    free(p->scratch);
    free(p->aring);
    PeUI *ui = (__bridge PeUI *)p->ui;
    p->ui = NULL;
    if (ui) {
        // 没进入事件循环就关闭的兼容路径：能上主线程就收尾，否则交给进程退出。
        dispatch_async(dispatch_get_main_queue(), ^{
            [ui teardown];
            CFRelease((__bridge CFTypeRef)ui);
        });
    }
    pthread_mutex_destroy(&p->mu);
    pthread_cond_destroy(&p->cond);
    free(p);
}

// ---------------- UI 实现 ----------------

@implementation PeVideoView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (!self.ctx) return;
    unsigned short code = event.keyCode;
    NSString *chars = event.charactersIgnoringModifiers;
    if (code == 49) { // space
        pe_toggle_pause(self.ctx);
    } else if (code == 53) { // esc
        pe_set_fullscreen(self.ctx, 0);
    } else if (code == 123) { // left
        pe_seek_relative(self.ctx, -10);
    } else if (code == 124) { // right
        pe_seek_relative(self.ctx, 10);
    } else if ([chars isEqualToString:@"f"] || [chars isEqualToString:@"F"]) {
        pe_toggle_fullscreen(self.ctx);
    } else {
        [super keyDown:event];
    }
}
@end

@implementation PeUI

- (BOOL)openWindowWidth:(int)w height:(int)h fullscreen:(BOOL)fs title:(NSString *)title {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSRect rect = NSMakeRect(0, 0, w, h);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:rect
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    if (!self.window) return NO;
    self.window.title = title;
    self.window.backgroundColor = [NSColor blackColor];
    self.window.delegate = self;
    self.window.releasedWhenClosed = NO;
    [self.window center];

    PeVideoView *view = [[PeVideoView alloc] initWithFrame:rect];
    view.ctx = self.ctx;
    view.wantsLayer = YES;
    view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    self.view = view;
    self.window.contentView = view;

    self.layer = [[AVSampleBufferDisplayLayer alloc] init];
    self.layer.frame = view.bounds;
    self.layer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    self.layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [view.layer addSublayer:self.layer];

    [self.window makeFirstResponder:view];
    [self.window makeKeyAndOrderFront:nil];
    [self setupMenu];
    self.uiQueue = [NSMutableArray array];
    self.uiLock = [[NSLock alloc] init];
    PePlayer *p = self.ctx;
    __weak PeUI *weakSelf = self;
    self.uiTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [weakSelf drainUIQueue];
        if (p && pe_now() - p->last_ui_heartbeat > 30.0) {
            p->last_ui_heartbeat = pe_now();
            PE_LOG(p, "主线程事件循环心跳");
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.uiTimer forMode:NSRunLoopCommonModes];
    if (fs) [self setFullscreen:YES];
    return YES;
}

- (void)setupMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    [appMenu addItem:quit];
    appItem.submenu = appMenu;
    NSApp.mainMenu = bar;
}

- (void)windowWillClose:(NSNotification *)note {
    (void)note;
    PePlayer *p = self.ctx;
    if (!p) return;
    pthread_mutex_lock(&p->mu);
    p->closed = 1;
    p->paused = 1;
    pthread_mutex_unlock(&p->mu);
    if (p->has_audio) [self pauseAudio];
    pe_stop_run(p);
}

- (void)windowDidResize:(NSNotification *)note {
    (void)note;
}

- (BOOL)startAudio {
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.audioPlayer = [[AVAudioPlayerNode alloc] init];
    [self.audioEngine attachNode:self.audioPlayer];
    self.audioFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:PE_AUDIO_RATE channels:2];
    [self.audioEngine connect:self.audioPlayer to:self.audioEngine.mainMixerNode format:self.audioFormat];
    self.audioEngine.mainMixerNode.outputVolume = 1.0;
    NSError *err = nil;
    if (![self.audioEngine startAndReturnError:&err]) {
        fprintf(stderr, "[engine] AVAudioEngine 启动失败：%s\n", err ? [[err description] UTF8String] : "unknown");
        return NO;
    }
    return YES;
}

- (void)setVolume:(int)vol muted:(BOOL)muted {
    float v = (float)(vol < 0 ? 0 : (vol > 100 ? 100 : vol)) / 100.0f;
    if (muted) v = 0.0f;
    self.audioEngine.mainMixerNode.outputVolume = v;
}

static int gFullscreenDepth = 0;

- (void)setFullscreen:(BOOL)on {
    if (!self.window) return;
    if (on == self.fsActive) return;
    if (gFullscreenDepth > 0) return;
    gFullscreenDepth++;
    PePlayer *p = self.ctx;
    if (on) {
        self.savedFrame = self.window.frame;
        self.savedStyle = self.window.styleMask;
        NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
        self.window.styleMask = NSWindowStyleMaskBorderless;
        [self.window setFrame:screen.frame display:NO animate:NO];
        self.window.level = NSScreenSaverWindowLevel;
        self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                          NSWindowCollectionBehaviorStationary;
    } else {
        self.window.styleMask = self.savedStyle;
        self.window.level = NSNormalWindowLevel;
        self.window.collectionBehavior = NSWindowCollectionBehaviorDefault;
        [self.window setFrame:self.savedFrame display:NO animate:NO];
    }
    [self.window makeKeyAndOrderFront:nil];
    self.fsActive = on;
    self.layer.frame = self.view.bounds;
    gFullscreenDepth--;
    PE_LOG(p, "全屏切换完成 on=%d 窗口 %.0fx%.0f", on,
           self.window.frame.size.width, self.window.frame.size.height);
}

- (id<AVQueuedSampleBufferRendering>)renderer {
    if (@available(macOS 14.0, *)) {
        return self.layer.sampleBufferRenderer;
    }
    return self.layer;
}

- (void)presentFrame:(AVFrame *)frame pts:(double)pts {
    if (!self.layer) return;
    CVPixelBufferRef pb = NULL;
    BOOL owned = NO;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pb = (CVPixelBufferRef)frame->data[3];
    } else {
        pb = [self pixelBufferFromFrame:frame];
        owned = YES;
    }
    if (!pb) return;
    CMVideoFormatDescriptionRef fd = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fd) == noErr) {
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(pts, 1000), kCMTimeInvalid};
        CMSampleBufferRef sb = NULL;
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fd, &timing, &sb) == noErr) {
            CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sb, true);
            if (arr && CFArrayGetCount(arr) > 0) {
                CFMutableDictionaryRef dict =
                    (CFMutableDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
                CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }
            id<AVQueuedSampleBufferRendering> r = [self renderer];
            if ([self rendererFailed]) {
                [r flush];
            }
            [r enqueueSampleBuffer:sb];
            CFRelease(sb);
        }
        CFRelease(fd);
    }
    if (owned) CVPixelBufferRelease(pb);
}

- (CVPixelBufferRef)pixelBufferFromFrame:(AVFrame *)frame {
    int w = frame->width, h = frame->height;
    if (w <= 0 || h <= 0) return NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst[4] = {(uint8_t *)CVPixelBufferGetBaseAddress(pb), NULL, NULL, NULL};
    int dstStride[4] = {(int)CVPixelBufferGetBytesPerRow(pb), 0, 0, 0};
    self.sws = sws_getCachedContext(self.sws, w, h, (enum AVPixelFormat)frame->format,
                                    w, h, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    if (self.sws) {
        sws_scale(self.sws, (const uint8_t *const *)frame->data, frame->linesize, 0, h,
                  dst, dstStride);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

- (BOOL)rendererFailed {
    if (@available(macOS 14.0, *)) {
        AVSampleBufferVideoRenderer *vr = self.layer.sampleBufferRenderer;
        if (vr) return vr.status == AVQueuedSampleBufferRenderingStatusFailed;
    }
    return self.layer.status == AVQueuedSampleBufferRenderingStatusFailed;
}

- (void)scheduleAudioFrames:(const float *)interleaved count:(int)frames completion:(void (^)(void))completion {
    if (!self.audioPlayer || !self.audioFormat || frames <= 0) return;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioFormat
                                                         frameCapacity:(AVAudioFrameCount)frames];
    if (!buf || !buf.floatChannelData) return;
    buf.frameLength = (AVAudioFrameCount)frames;
    float *left = buf.floatChannelData[0];
    float *right = buf.floatChannelData[1];
    for (int i = 0; i < frames; i++) {
        left[i] = interleaved[i * 2];
        right[i] = interleaved[i * 2 + 1];
    }
    [self.audioPlayer scheduleBuffer:buf completionHandler:completion];
}

- (void)flushVideo {
    id<AVQueuedSampleBufferRendering> r = [self renderer];
    if ([r respondsToSelector:@selector(flushWithRemovalOfDisplayedImage:completionHandler:)]) {
        AVSampleBufferVideoRenderer *vr = (AVSampleBufferVideoRenderer *)r;
        [vr flushWithRemovalOfDisplayedImage:YES completionHandler:^{}];
    } else {
        [r flush];
    }
}

- (void)togglePause {
    if (self.ctx) pe_toggle_pause(self.ctx);
}

- (void)seekRelative:(double)delta {
    if (self.ctx) pe_seek_relative(self.ctx, delta);
}

- (double)nodeSeconds {
    if (!self.audioPlayer || !self.audioEngine.isRunning) return -1;
    AVAudioTime *nt = self.audioPlayer.lastRenderTime;
    if (!nt) return -1;
    AVAudioTime *pt = [self.audioPlayer playerTimeForNodeTime:nt];
    if (!pt || pt.sampleRate <= 0) return -1;
    return (double)pt.sampleTime / pt.sampleRate;
}

- (void)playAudio {
    if (!self.audioEngine.isRunning) {
        NSError *err = nil;
        if (![self.audioEngine startAndReturnError:&err]) return;
    }
    [self.audioPlayer play];
}

- (void)pauseAudio {
    if (self.audioPlayer) [self.audioPlayer pause];
}

- (void)stopAudio {
    if (self.audioPlayer) [self.audioPlayer stop];
}

- (void)postUIBlock:(void (^)(void))block {
    if (!block) return;
    [self.uiLock lock];
    [self.uiQueue addObject:[block copy]];
    [self.uiLock unlock];
}

- (void)drainUIQueue {
    NSArray *blocks;
    [self.uiLock lock];
    blocks = [self.uiQueue copy];
    [self.uiQueue removeAllObjects];
    [self.uiLock unlock];
    for (void (^b)(void) in blocks) b();
}

- (void)applyStopRun {
    [NSApp stop:nil];
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                    location:NSZeroPoint modifierFlags:0 timestamp:0
                                windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [NSApp postEvent:e atStart:YES];
}

- (void)teardown {
    if (self.uiTimer) {
        [self.uiTimer invalidate];
        self.uiTimer = nil;
    }
    [self.uiLock lock];
    [self.uiQueue removeAllObjects];
    [self.uiLock unlock];
    if (self.audioPlayer) [self.audioPlayer stop];
    if (self.audioEngine) [self.audioEngine stop];
    if (self.layer) {
        self.layer = nil;
    }
    if (self.window) {
        self.window.delegate = nil;
        [self.window orderOut:nil];
        [self.window close];
        self.window = nil;
    }
    if (self.sws) {
        sws_freeContext(self.sws);
        self.sws = NULL;
    }
}

@end
