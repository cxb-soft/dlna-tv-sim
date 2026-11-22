/*
 * engine_selftest.c — 在没有 Windows 实机时，用同一份引擎代码在本机做运行时自测。
 *
 * 引擎实现本身只依赖 SDL2 + FFmpeg（没有 Windows API），用 PE_ENGINE_PORTABLE
 * 打开后可以在 macOS/Linux 上编译，验证打开、解码、音画时钟、seek、暂停/恢复、
 * 音量、倍速、截图和关窗流程。窗口会真实弹出，不用于自动化 CI。
 *
 * 编译（macOS，依赖 Homebrew SDL2 + LGPL FFmpeg 9）：
 *   PREFIX=$HOME/Library/Caches/dlnatvsim-deps/ffmpeg-lgpl
 *   cc -g -O1 -fsanitize=address -DPE_ENGINE_PORTABLE \
 *     -Iplayer -I"$(brew --prefix sdl2)/include" -I"$PREFIX/include" \
 *     player/engine_windows.c player/win/engine_selftest.c \
 *     $(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --libs sdl2 libavformat libavcodec libavutil libswscale libswresample) \
 *     -o /tmp/pe-selftest
 *
 * 运行：/tmp/pe-selftest /tmp/pe-test.mp4
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL.h>
#include "engine.h"

extern void pe_debug_capture(PePlayer *p, const char *path);

static PePlayer *g_player;
static int g_seeked;
static int g_paused;
static int g_pause_done;
static int g_played;
static int g_shot;
static int g_speed_changed;
static int g_full_mode;
static int g_ui_mode;
static int g_seek_mode;

static int SDLCALL control_thread(void *arg) {
    (void)arg;
    for (int tick = 0; tick < 300; tick++) {
        SDL_Delay(100);
        PeStatus st;
        memset(&st, 0, sizeof(st));
        pe_get_status(g_player, &st);
        if (tick % 10 == 0) {
            printf("[%4.1fs] pos=%6.2f dur=%6.2f paused=%d ended=%d shown=%lld drop=%lld audio=%d/%d buf=%d win=%d pos_ms=%.0f\n",
                   tick / 10.0, st.position, st.duration, st.paused, st.ended,
                   (long long)st.frames_shown, (long long)st.frames_dropped,
                   st.has_video, st.has_audio, st.buffering, st.width, st.buffered_ms);
            printf("        drift=%+.1fms avg=%.1fms p95=%.1fms max=%.1fms seek=%.1fms speed=%.2f\n",
                   st.drift_ms, st.drift_avg_ms, st.drift_p95_ms, st.drift_max_ms,
                   st.last_seek_ms, st.speed);
            fflush(stdout);
        }
        if (g_ui_mode) {
            if (tick == 10) pe_debug_capture(g_player, "/tmp/winui_01_controls.bmp");
            if (tick == 14) pe_ui_menu(g_player, "speed");
            if (tick == 18) pe_debug_capture(g_player, "/tmp/winui_02_speed.bmp");
            if (tick == 20) { pe_ui_menu(g_player, "close"); pe_ui_menu(g_player, "audio"); }
            if (tick == 24) pe_debug_capture(g_player, "/tmp/winui_03_audio.bmp");
            if (tick == 26) { pe_ui_menu(g_player, "close"); pe_pause(g_player); }
            if (tick == 30) pe_debug_capture(g_player, "/tmp/winui_04_paused.bmp");
            if (tick == 34) { pe_play(g_player); pe_ui_click(g_player, "screenshot"); }
            if (tick == 37) pe_debug_capture(g_player, "/tmp/winui_05_toast.bmp");
            if (tick == 38) {
                pe_ui_click(g_player, "speed:1.5");
                pe_ui_click(g_player, "volume:70");
                pe_ui_click(g_player, "aspect:16:9");
                pe_ui_click(g_player, "audio:1");
                pe_ui_click(g_player, "progress:0.5");
                pe_ui_key(g_player, "down");
                pe_ui_hover(g_player, "speed");
            }
            if (tick == 42) {
                PeStatus st;
                pe_get_status(g_player, &st);
                printf("HOOKS speed=%.2f vol=%.0f muted=%d aspect=%s pos=%.2f\n",
                       st.speed, st.volume, st.muted, st.aspect, st.position);
            }
            if (tick >= 45) { pe_close_window(g_player); return 0; }
            continue;
        }
        if (g_seek_mode) {
            if (tick == 12) {
                printf("DRAG_BEFORE pos=%.2f\n", st.position);
                pe_ui_hover(g_player, "progress:0.20");
                pe_ui_hover(g_player, "progress:0.30");
                pe_ui_hover(g_player, "progress:0.40");
            }
            if (tick == 13) pe_ui_click(g_player, "progress:0.5");
            if (tick == 30) {
                printf("SEEK50 pos=%.2f buf=%d shown=%lld seek=%.0fms\n",
                       st.position, st.buffering, (long long)st.frames_shown, st.last_seek_ms);
            }
            if (tick == 40) pe_seek(g_player, 30.0);
            if (tick == 50) {
                printf("SEEK30 pos=%.2f buf=%d shown=%lld seek=%.0fms\n",
                       st.position, st.buffering, (long long)st.frames_shown, st.last_seek_ms);
            }
            if (tick >= 55) { pe_close_window(g_player); return 0; }
            continue;
        }
        if (g_full_mode) {
            if (st.ended || st.io_error) break;
            continue;
        }
        if (!g_seeked && st.position > 1.5) {
            printf("→ seek 8s\n");
            pe_seek(g_player, 8.0);
            g_seeked = 1;
        }
        if (g_seeked && !g_pause_done && st.position > 9.0) {
            printf("→ pause\n");
            pe_pause(g_player);
            g_paused = 1;
            g_pause_done = 1;
        }
        if (g_paused && st.paused) {
            static int paused_ticks;
            if (++paused_ticks > 10) {
                printf("→ play\n");
                pe_play(g_player);
                g_paused = 0;
                g_played = 1;
            }
        }
        if (g_played && !g_shot && st.position > 10.0) {
            char err[256] = {0};
            printf("→ screenshot /tmp/pe-selftest.png\n");
            int rc = pe_screenshot(g_player, "/tmp/pe-selftest.png", err, sizeof(err));
            printf("   screenshot rc=%d %s\n", rc, err);
            pe_set_volume(g_player, 20);
            pe_set_mute(g_player, 1);
            pe_set_mute(g_player, 0);
            pe_set_speed(g_player, 1.5);
            g_speed_changed = 1;
            pe_ui_set_visible(g_player, 1);
            pe_ui_hover(g_player, "progress:0.5");
            pe_ui_key(g_player, "right");
            g_shot = 1;
        }
        if (g_speed_changed && tick == 120) {
            printf("→ speed 1.0 + fullscreen toggle\n");
            pe_set_speed(g_player, 1.0);
            pe_toggle_fullscreen(g_player);
            pe_toggle_fullscreen(g_player);
        }
        if (st.ended || st.io_error) {
            printf("→ ended/io_error\n");
            break;
        }
    }
    printf("→ close window\n");
    pe_close_window(g_player);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) {
        fprintf(stderr, "用法: %s <媒体路径>\n", argv[0]);
        return 1;
    }
    PeConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.url = argv[1];
    cfg.title = "123 456";      /* 本机点阵字体只画数字，便于截图核对顶部位置 */
    cfg.device_name = "789";
    cfg.width = 1280;
    cfg.height = 720;
    cfg.volume = 50;
    cfg.aspect = "auto";
    cfg.speed = 1.0;
    cfg.hardware = 0;

    char err[512] = {0};
    PePlayer *p = pe_open(&cfg, err, sizeof(err));
    if (!p) {
        fprintf(stderr, "pe_open 失败: %s\n", err);
        return 1;
    }
    g_player = p;
    g_full_mode = getenv("PE_SELFTEST_FULL") != NULL;
    g_ui_mode = getenv("PE_SELFTEST_UI") != NULL;
    g_seek_mode = getenv("PE_SELFTEST_SEEK") != NULL;
    printf("FFmpeg %s%s\n", pe_ffmpeg_version(), g_full_mode ? "（连续播放模式）" : "");
    SDL_CreateThread(control_thread, "selftest", NULL);
    pe_run(p);

    PeStatus st;
    memset(&st, 0, sizeof(st));
    pe_get_status(p, &st);
    printf("收尾: shown=%lld dropped=%lld dur=%.2f pos=%.2f closed=%d\n",
           (long long)st.frames_shown, (long long)st.frames_dropped,
           st.duration, st.position, st.closed);
    pe_destroy(p);
    return (st.frames_shown > 0 || (st.has_audio && st.position > 0)) ? 0 : 2;
}
