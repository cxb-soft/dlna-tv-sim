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
    const char *device_name;  /* 播放器 UI 顶部显示的设备名，可为 NULL */
    int width;                /* 窗口宽，0 表示 1280 */
    int height;               /* 窗口高，0 表示 720 */
    int fullscreen;           /* 1 = 无边框全屏 */
    int volume;               /* 0..100 */
    int muted;                /* 1 = 静音 */
    int hardware;             /* 1 = 优先 VideoToolbox，失败自动回软解 */
    const char *renderer;     /* "layer"（默认）；保留扩展位 */
    const char *user_agent;   /* HTTP User-Agent，NULL 默认 */
    const char *referer;      /* HTTP Referer，NULL 不发送 */
    double start_position;    /* 起播位置（秒），0 表示从头 */
    double speed;             /* 0.25..4，1 = 原速 */
    const char *aspect;       /* auto / 16:9 / 4:3 / fill */
    int loop;                 /* 1 = 单文件循环 */
    int audio_track;          /* 1 起的音轨编号，0 = 自动 */
    int subtitle_track;       /* 1 起的字幕轨编号，0 = 自动选第一条 */
} PeConfig;

/* 一条音轨/字幕轨。id 是给 UI 和 DLNA 用的稳定编号（1 起）。 */
typedef struct {
    int id;
    int stream_index;         /* FFmpeg 流索引 */
    int channels;             /* 音轨声道数，字幕为 0 */
    char lang[32];
    char title[160];
    char codec[40];
} PeTrackInfo;

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

    /* 高级播放状态 */
    double speed;
    int loop;
    char aspect[8];
    int audio_track;          /* 当前音轨编号，0 = 无 */
    int subtitle_track;       /* 当前字幕编号，0 = 关闭 */
    int audio_tracks;
    int subtitle_tracks;
    int buffering;            /* 1 = 起播/seek 后还没出画面 */
    int io_error;             /* 1 = 读流中断（网络/媒体源错误） */
} PeStatus;

PePlayer *pe_open(const PeConfig *cfg, char *errbuf, int errlen);
void pe_play(PePlayer *p);
void pe_pause(PePlayer *p);
void pe_toggle_pause(PePlayer *p);
void pe_restart(PePlayer *p);   /* 播完后回到开头继续 */
void pe_stop(PePlayer *p);
void pe_seek(PePlayer *p, double seconds);
void pe_seek_relative(PePlayer *p, double delta);
void pe_set_volume(PePlayer *p, int volume);
void pe_set_mute(PePlayer *p, int muted);
int  pe_get_volume(PePlayer *p);
int  pe_get_mute(PePlayer *p);
void pe_set_fullscreen(PePlayer *p, int on);
void pe_toggle_fullscreen(PePlayer *p);
void pe_close_window(PePlayer *p);
void pe_get_status(PePlayer *p, PeStatus *out);
const char *pe_video_codec(PePlayer *p);
const char *pe_audio_codec(PePlayer *p);
const char *pe_hwdevice_name(PePlayer *p);
int  pe_window_number(PePlayer *p);
void pe_run(PePlayer *p);
void pe_stop_run(PePlayer *p);
void pe_close(PePlayer *p);
void pe_destroy(PePlayer *p);
const char *pe_ffmpeg_version(void);
double pe_now(void);

/* ---------- 高级播放控制 ---------- */

void pe_set_speed(PePlayer *p, double speed);
double pe_get_speed(PePlayer *p);
void pe_set_loop(PePlayer *p, int on);
int  pe_get_loop(PePlayer *p);
void pe_set_aspect(PePlayer *p, const char *aspect);
const char *pe_get_aspect(PePlayer *p);

int pe_audio_track_count(PePlayer *p);
int pe_audio_track_info(PePlayer *p, int ordinal, PeTrackInfo *out); /* ordinal 0 起 */
int pe_subtitle_track_count(PePlayer *p);
int pe_subtitle_track_info(PePlayer *p, int ordinal, PeTrackInfo *out);
void pe_set_audio_track(PePlayer *p, int id);      /* 1 起，越界忽略 */
void pe_set_subtitle_track(PePlayer *p, int id);   /* 0 = 关闭 */
int  pe_get_audio_track(PePlayer *p);
int  pe_get_subtitle_track(PePlayer *p);

/* 当前正在显示的字幕文本（UTF-8，多行用 \n），返回写入字节数。 */
int  pe_get_subtitle_text(PePlayer *p, char *buf, int len);

/* 当前字幕 RGBA 位图（libass 渲染，CGImageRef）；调用方 CGImageRelease。 */
void *pe_copy_subtitle_image(PePlayer *p);

/* 把当前视频帧写成 PNG，成功返回 0。可从任意线程调用。 */
int  pe_screenshot(PePlayer *p, const char *path, char *errbuf, int errlen);

const char *pe_title(PePlayer *p);
const char *pe_device_name(PePlayer *p);

/* ---------- 验证/脚本钩子（都投递到主线程执行） ---------- */

void pe_ui_set_visible(PePlayer *p, int visible);
void pe_ui_hover(PePlayer *p, const char *control);   /* "play"、"progress:0.5" */
void pe_ui_click(PePlayer *p, const char *control);
void pe_ui_menu(PePlayer *p, const char *menu);        /* speed/audio/sub/aspect */
void pe_ui_key(PePlayer *p, const char *key);          /* space/left/right/up/down/m/f/s/esc */

#ifdef __cplusplus
}
#endif

#endif
