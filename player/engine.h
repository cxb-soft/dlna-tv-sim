#ifndef DLNATVSIM_PLAYER_ENGINE_H
#define DLNATVSIM_PLAYER_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PePlayer PePlayer;

typedef struct {
    const char *url;          /* 本地路径或 http(s) 地址 */
    const char *title;        /* 窗口标题，可为 NULL */
    int width;                /* 窗口宽，0 表示 1280 */
    int height;               /* 窗口高，0 表示 720 */
    int fullscreen;           /* 1 = 无边框全屏 */
    int volume;               /* 0..100 */
    int muted;                /* 1 = 静音 */
    int hardware;             /* 1 = 优先 VideoToolbox，失败自动回软解 */
    const char *renderer;     /* "layer"（默认）；保留扩展位 */
    double start_position;    /* 起播位置（秒），0 表示从头 */
} PeConfig;

typedef struct {
    double position;          /* 当前播放位置（秒），音频时钟 */
    double duration;          /* 总时长（秒），未知为 0 */
    double clock;             /* 原始主时钟（秒） */
    double video_pts;         /* 最后显示帧的 PTS（秒） */
    double drift_ms;          /* 最近一帧显示时 video_pts - clock */
    double drift_avg_ms;      /* 已显示帧的 pacing 误差均值 */
    double drift_p95_ms;      /* pacing 误差 p95 */
    double drift_max_ms;      /* pacing 误差最大值 */
    long long frames_shown;   /* 已显示帧数 */
    long long frames_dropped; /* 因迟到丢弃的帧数 */
    double first_frame_ms;    /* open → 首帧显示耗时 */
    double last_seek_ms;      /* 最近一次 seek 的响应耗时 */
    double cpu_percent;       /* 进程 CPU 占用（基于 getrusage 采样） */
    double buffered_ms;       /* 当前缓冲的音视频时长 */
    int width, height;        /* 视频尺寸 */
    int fps;                  /* 标称帧率 */
    int paused;
    int ended;
    int closed;               /* 用户关掉了窗口 */
    int fullscreen;
    int hardware_decode;      /* 1 = 当前视频帧确实是 VideoToolbox 输出 */
    int has_video, has_audio;
    double volume;
    int muted;
    int window_number;        /* NSWindow.windowNumber，用于 screencapture -l */
} PeStatus;

PePlayer *pe_open(const PeConfig *cfg, char *errbuf, int errlen);
void pe_play(PePlayer *p);
void pe_pause(PePlayer *p);
void pe_toggle_pause(PePlayer *p);
void pe_stop(PePlayer *p);
void pe_seek(PePlayer *p, double seconds);
void pe_seek_relative(PePlayer *p, double delta);
void pe_set_volume(PePlayer *p, int volume);
void pe_set_mute(PePlayer *p, int muted);
int  pe_get_volume(PePlayer *p);
int  pe_get_mute(PePlayer *p);
void pe_set_fullscreen(PePlayer *p, int on);
void pe_toggle_fullscreen(PePlayer *p);
void pe_get_status(PePlayer *p, PeStatus *out);
const char *pe_video_codec(PePlayer *p);
const char *pe_audio_codec(PePlayer *p);
const char *pe_hwdevice_name(PePlayer *p);
int  pe_window_number(PePlayer *p);
void pe_run(PePlayer *p);
void pe_stop_run(PePlayer *p);
void pe_close(PePlayer *p);
const char *pe_ffmpeg_version(void);
double pe_now(void);

#ifdef __cplusplus
}
#endif

#endif
