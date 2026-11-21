// 播放器控件层：全部自绘（AppKit + CoreAnimation），不依赖第三方 UI。
// 风格跟应用主题走：近黑背景、低饱和灰、唯一高饱和色是琥珀。
#import "player_ui_darwin.h"
#include "engine.h"

#include <math.h>
#include <string.h>
#import <QuartzCore/QuartzCore.h>

// ---------------- 颜色与文字 ----------------

static NSColor *Col(uint32_t rgb, CGFloat alpha) {
    return [NSColor colorWithCalibratedRed:(CGFloat)((rgb >> 16) & 0xFF) / 255.0
                                     green:(CGFloat)((rgb >> 8) & 0xFF) / 255.0
                                      blue:(CGFloat)(rgb & 0xFF) / 255.0
                                     alpha:alpha];
}

static const uint32_t kBg = 0x0E1014;
static const uint32_t kPanel = 0x121418;
static const uint32_t kPanelAlt = 0x171A1F;
static const uint32_t kLine = 0x23262C;
static const uint32_t kLineStrong = 0x31353D;
static const uint32_t kText = 0xE9EBEF;
static const uint32_t kTextDim = 0x9AA1AC;
static const uint32_t kTextFaint = 0x69707B;
static const uint32_t kAmber = 0xEBB15D;
static const uint32_t kAmberInk = 0x201605;
static const uint32_t kRed = 0xF0655E;
static const uint32_t kGreen = 0x5FC08A;

static void FillRound(NSRect r, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
}

static void StrokeRound(NSRect r, CGFloat radius, NSColor *color, CGFloat width) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
    p.lineWidth = width;
    [color setStroke];
    [p stroke];
}

static NSSize DrawText(NSString *s, NSRect rect, NSFont *font, NSColor *color,
                       NSTextAlignment align, CGFloat kern, CGFloat alpha) {
    if (!s || s.length == 0) return NSZeroSize;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = align;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSFontAttributeName] = font;
    attrs[NSForegroundColorAttributeName] = [color colorWithAlphaComponent:color.alphaComponent * alpha];
    attrs[NSParagraphStyleAttributeName] = ps;
    if (kern != 0) attrs[NSKernAttributeName] = @(kern);
    NSSize size = [s sizeWithAttributes:attrs];
    CGFloat y = rect.origin.y + (rect.size.height - size.height) / 2.0;
    NSRect r = NSMakeRect(rect.origin.x, y, rect.size.width, size.height);
    [s drawInRect:r withAttributes:attrs];
    return size;
}

static NSString *FmtTime(double seconds) {
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    int total = (int)llround(seconds);
    int h = total / 3600;
    int m = (total % 3600) / 60;
    int s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%d:%02d:%02d", h, m, s];
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

static NSString *SpeedLabel(double v) {
    if (fabs(v - 1.0) < 0.01) return @"1.0×";
    return [NSString stringWithFormat:@"%.3g×", v];
}

// ---------------- 控件/菜单枚举 ----------------

typedef NS_ENUM(NSInteger, PeCtrlId) {
    PeCtrlNone = 0,
    PeCtrlPlay,
    PeCtrlBack,
    PeCtrlForward,
    PeCtrlProgress,
    PeCtrlVolume,
    PeCtrlMute,
    PeCtrlSpeed,
    PeCtrlAudio,
    PeCtrlSub,
    PeCtrlAspect,
    PeCtrlFullscreen,
    PeCtrlClose,
};

typedef NS_ENUM(NSInteger, PeMenuKind) {
    PeMenuNone = 0,
    PeMenuSpeed,
    PeMenuAudio,
    PeMenuSub,
    PeMenuAspect,
};

@interface PeOverlayView () {
    PePlayer *_player;
    PeStatus _st;
    NSTimer *_timer;
    NSTrackingArea *_tracking;
    CGFloat _fade;             // 0..1 控件透明度
    BOOL _targetVisible;
    NSTimeInterval _hideAt;
    NSPoint _mouse;
    PeCtrlId _hoverCtrl;
    CGFloat _hoverFrac;
    BOOL _draggingProgress;
    BOOL _draggingVolume;
    CGFloat _dragFrac;
    BOOL _mouseInside;
    PeMenuKind _menu;
    NSRect _menuRect;
    NSInteger _menuHover;
    NSMutableArray<NSDictionary *> *_menuItems;
    NSRect _menuAnchor;
    CGFloat _spinnerPhase;
    BOOL _buffering;
    double _lastPos;
    NSTimeInterval _stallSince;
    NSString *_toast;
    BOOL _toastError;
    NSTimeInterval _toastUntil;
    CGFloat _toastFade;
    BOOL _ioToastShown;
    BOOL _endedShown;
    NSString *_videoMeta;
    NSString *_menuHeader;
    BOOL _curtainDone;
    NSTimer *_singleClickTimer;
    BOOL _screenshotBusy;
}
@property (nonatomic, copy) NSString *mediaTitle;
@property (nonatomic, copy) NSString *deviceName;
@end

@implementation PeOverlayView

- (instancetype)initWithFrame:(NSRect)frame
                       player:(void *)player
                        title:(NSString *)title
                       device:(NSString *)device {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _player = (PePlayer *)player;
    self.mediaTitle = title.length ? title : @"正在播放";
    self.deviceName = device.length ? device : @"DLNA 电视";
    _menuItems = [NSMutableArray array];
    _fade = 1.0;
    _targetVisible = YES;
    _hideAt = [NSDate timeIntervalSinceReferenceDate] + 3.0;
    _menu = PeMenuNone;
    _menuHover = -1;
    _toastFade = 0;
    _videoMeta = @"";
    self.wantsLayer = YES;
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    self.layer.opaque = NO;
    self.layer.masksToBounds = YES;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak PeOverlayView *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [weakSelf tick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (void)shutdown {
    [_timer invalidate];
    _timer = nil;
    [_singleClickTimer invalidate];
    _singleClickTimer = nil;
    if (_tracking) {
        [self removeTrackingArea:_tracking];
        _tracking = nil;
    }
    _player = NULL;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    if (!_curtainDone && self.window) {
        _curtainDone = YES;
        CALayer *curtain = [CALayer layer];
        curtain.frame = self.bounds;
        curtain.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        [self.layer addSublayer:curtain];
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @1.0;
        a.toValue = @0.0;
        a.duration = 0.55;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [curtain addAnimation:a forKey:@"fade"];
        curtain.opacity = 0.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [curtain removeFromSuperlayer];
        });
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    NSTrackingAreaOptions opt = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:opt owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

// ---------------- 布局 ----------------

- (CGFloat)W { return self.bounds.size.width; }
- (CGFloat)H { return self.bounds.size.height; }
- (BOOL)compact { return self.W < 1020; }

- (NSRect)progressRect { return NSMakeRect(28, 94, MAX(120, self.W - 56), 6); }
- (NSRect)progressHitRect { return NSInsetRect([self progressRect], -2, -10); }
- (NSRect)playRect { return NSMakeRect(28, 12, 48, 48); }
- (NSRect)backRect { return NSMakeRect(86, 16, 40, 40); }
- (NSRect)fwdRect { return NSMakeRect(130, 16, 40, 40); }
- (NSRect)muteRect { return NSMakeRect(178, 18, 36, 36); }
- (NSRect)volumeRect {
    if ([self compact]) return NSZeroRect;
    return NSMakeRect(218, 25, 92, 22);
}
- (NSRect)volumeHitRect {
    if ([self compact]) return NSZeroRect;
    return NSInsetRect([self volumeRect], -6, -9);
}

- (CGFloat)pillWidth { return [self compact] ? 58 : 70; }
- (NSRect)closeRect { return NSMakeRect(self.W - 28 - 36, 18, 36, 36); }
- (NSRect)fsRect { return NSMakeRect(self.W - 28 - 36 - 42, 18, 36, 36); }
- (NSRect)aspectRect {
    CGFloat w = [self pillWidth];
    return NSMakeRect(self.W - 28 - 36 - 42 - 36 - 8 - w, 19, w, 34);
}
- (NSRect)subRect {
    CGFloat w = [self pillWidth];
    return NSMakeRect([self aspectRect].origin.x - 6 - w, 19, w, 34);
}
- (NSRect)audioRect {
    CGFloat w = [self pillWidth];
    return NSMakeRect([self subRect].origin.x - 6 - w, 19, w, 34);
}
- (NSRect)speedRect {
    CGFloat w = [self compact] ? 54 : 62;
    return NSMakeRect([self audioRect].origin.x - 6 - w, 19, w, 34);
}

- (NSRect)hitRect:(NSRect)r {
    if (r.size.width <= 1) return r;
    if (r.size.height >= 40) return r;
    CGFloat dy = (40 - r.size.height) / 2.0;
    return NSInsetRect(r, -2, -dy);
}

- (NSRect)rectForControl:(PeCtrlId)ctrl {
    switch (ctrl) {
        case PeCtrlPlay: return [self playRect];
        case PeCtrlBack: return [self backRect];
        case PeCtrlForward: return [self fwdRect];
        case PeCtrlProgress: return [self progressHitRect];
        case PeCtrlVolume: return [self volumeHitRect];
        case PeCtrlMute: return [self muteRect];
        case PeCtrlSpeed: return [self speedRect];
        case PeCtrlAudio: return [self audioRect];
        case PeCtrlSub: return [self subRect];
        case PeCtrlAspect: return [self aspectRect];
        case PeCtrlFullscreen: return [self fsRect];
        case PeCtrlClose: return [self closeRect];
        default: return NSZeroRect;
    }
}

- (PeCtrlId)controlAtPoint:(NSPoint)p {
    if (_fade < 0.35) return PeCtrlNone;
    // 从上层/小控件往大控件查，进度条放最后。
    const PeCtrlId order[] = {PeCtrlPlay, PeCtrlBack, PeCtrlForward, PeCtrlMute,
                              PeCtrlSpeed, PeCtrlAudio, PeCtrlSub, PeCtrlAspect,
                              PeCtrlFullscreen, PeCtrlClose, PeCtrlVolume, PeCtrlProgress};
    for (int i = 0; i < (int)(sizeof(order) / sizeof(order[0])); i++) {
        NSRect r = [self rectForControl:order[i]];
        if (r.size.width > 1 && NSPointInRect(p, r)) return order[i];
    }
    return PeCtrlNone;
}

// ---------------- 状态轮询 ----------------

- (void)tick {
    if (!_player) return;
    pe_get_status(_player, &_st);
    double now = [NSDate timeIntervalSinceReferenceDate];

    NSString *codec = @"";
    if (_st.has_video) {
        const char *vc = pe_video_codec(_player);
        if (vc && vc[0]) codec = [[NSString stringWithUTF8String:vc] uppercaseString];
        _videoMeta = [NSString stringWithFormat:@"%@ · %dx%d · %dfps · %@", codec,
                      _st.width, _st.height, _st.fps, _st.hardware_decode ? @"硬解" : @"软解"];
    } else {
        _videoMeta = @"音频";
    }

    // 缓冲判定：起播/seek 中，或播放位置长时间不前进。
    BOOL buffering = _st.buffering != 0 || (!_st.paused && !_st.ended && _st.frames_shown == 0);
    if (!_st.paused && !_st.ended) {
        if (fabs(_st.position - _lastPos) > 0.02) {
            _lastPos = _st.position;
            _stallSince = now;
        } else if (_stallSince == 0) {
            _stallSince = now;
        }
        if (_stallSince > 0 && now - _stallSince > 0.9) buffering = YES;
    } else {
        _stallSince = 0;
        _lastPos = _st.position;
    }
    _buffering = buffering;

    if (_st.io_error && !_ioToastShown) {
        _ioToastShown = YES;
        [self showToast:@"播放中断：网络或媒体源不可用" error:YES];
    }
    if (_st.ended && !_endedShown) {
        _endedShown = YES;
        [self showToast:@"播放结束" error:NO];
    }
    if (!_st.ended) _endedShown = NO;

    // 控件自动淡出
    if (_targetVisible && !_st.paused && !_st.ended && _menu == PeMenuNone &&
        !_draggingProgress && !_draggingVolume) {
        if (now >= _hideAt) _targetVisible = NO;
    }
    if (!_targetVisible && _fade > 0) _fade = MAX(0.0, _fade - 0.07);
    if (_targetVisible && _fade < 1) _fade = MIN(1.0, _fade + 0.09);

    if (_toastUntil > 0 && now > _toastUntil) {
        _toastFade = MAX(0.0, _toastFade - 0.08);
        if (_toastFade <= 0) _toastUntil = 0;
    } else if (_toastUntil > 0) {
        _toastFade = MIN(1.0, _toastFade + 0.12);
    }

    if (_buffering) _spinnerPhase += 0.18;
    BOOL animate = _fade > 0 || _buffering || _toastUntil > 0 || _menu != PeMenuNone;
    if (animate) [self setNeedsDisplay:YES];
}

- (void)showToast:(NSString *)text error:(BOOL)error {
    _toast = text;
    _toastError = error;
    _toastUntil = [NSDate timeIntervalSinceReferenceDate] + 4.5;
    _toastFade = 0;
    [self setNeedsDisplay:YES];
}

// ---------------- 绘制 ----------------

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat w = self.W, h = self.H;
    if (w < 4 || h < 4) return;

    if (_fade > 0.01) {
        // 顶部/底部渐变
        NSGradient *top = [[NSGradient alloc] initWithColorsAndLocations:
            Col(0x000000, 0.62 * _fade), 0.0,
            Col(0x000000, 0.0), 1.0, nil];
        [top drawInRect:NSMakeRect(0, h - 104, w, 104) angle:90];
        NSGradient *bottom = [[NSGradient alloc] initWithColorsAndLocations:
            Col(0x000000, 0.0), 0.0,
            Col(0x000000, 0.72 * _fade), 0.42,
            Col(0x000000, 0.84 * _fade), 1.0, nil];
        [bottom drawInRect:NSMakeRect(0, 0, w, 142) angle:90];
    }

    [self drawSubtitles];

    if (_fade > 0.01) [self drawTopBar];
    if (_fade > 0.01) [self drawBottomBar];
    if (_menu != PeMenuNone) [self drawMenu];
    if (_buffering) [self drawSpinner];
    if (_toastUntil > 0 && _toastFade > 0.01) [self drawToast];
}

- (void)drawTopBar {
    CGFloat w = self.W, h = self.H;
    CGFloat a = _fade;
    DrawText(self.mediaTitle, NSMakeRect(28, h - 52, w - 300, 26),
             [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold],
             Col(kText, 1.0), NSTextAlignmentLeft, -0.2, a);
    NSRect dot = NSMakeRect(28, h - 70, 5, 5);
    FillRound(dot, 2.5, Col(kAmber, 0.9 * a));
    DrawText([NSString stringWithFormat:@"%@ · 投屏中", self.deviceName],
             NSMakeRect(40, h - 78, w - 320, 18),
             [NSFont systemFontOfSize:11.5 weight:NSFontWeightRegular],
             Col(kTextDim, 1.0), NSTextAlignmentLeft, 0, a);
    if (w > 760) {
        DrawText(_videoMeta, NSMakeRect(w - 328, h - 48, 300, 18),
                 [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                 Col(kTextFaint, 1.0), NSTextAlignmentRight, 0, a);
    }
}

- (void)drawBottomBar {
    CGFloat a = _fade;
    NSRect pr = [self progressRect];
    double dur = _st.duration > 0 ? _st.duration : 0;
    double pos = _st.position;
    CGFloat frac = dur > 0 ? (CGFloat)(pos / dur) : 0;
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;

    // 轨道
    FillRound(pr, 3, Col(0xFFFFFF, 0.16 * a));
    // 缓冲
    if (dur > 0) {
        double buf = pos + _st.buffered_ms / 1000.0;
        CGFloat bf = (CGFloat)(buf / dur);
        if (bf > 1) bf = 1;
        if (bf > frac) {
            NSRect br = pr;
            br.size.width = pr.size.width * bf;
            FillRound(br, 3, Col(0xFFFFFF, 0.24 * a));
        }
    }
    // 已播
    NSRect played = pr;
    played.size.width = pr.size.width * frac;
    if (played.size.width > 1) FillRound(played, 3, Col(kAmber, 0.95 * a));

    // 悬停/拖动预览
    BOOL showPreview = (_draggingProgress || (_hoverCtrl == PeCtrlProgress && _mouseInside));
    CGFloat previewFrac = _draggingProgress ? _dragFrac : _hoverFrac;
    if (showPreview && dur > 0) {
        CGFloat x = pr.origin.x + pr.size.width * previewFrac;
        NSRect line = NSMakeRect(x - 0.75, pr.origin.y - 5, 1.5, pr.size.height + 10);
        FillRound(line, 0.75, Col(0xFFFFFF, 0.85 * a));
        NSString *tip = FmtTime(previewFrac * dur);
        NSFont *f = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        NSSize ts = [tip sizeWithAttributes:@{NSFontAttributeName: f}];
        CGFloat tw = ts.width + 18, th = 24;
        CGFloat tx = x - tw / 2;
        tx = MAX(10, MIN(self.W - tw - 10, tx));
        NSRect bubble = NSMakeRect(tx, pr.origin.y + 16, tw, th);
        NSShadow *sh = [[NSShadow alloc] init];
        sh.shadowBlurRadius = 12;
        sh.shadowOffset = NSMakeSize(0, -2);
        sh.shadowColor = Col(0x000000, 0.5 * a);
        [NSGraphicsContext saveGraphicsState];
        [sh set];
        FillRound(bubble, 8, Col(kPanelAlt, 0.96 * a));
        [NSGraphicsContext restoreGraphicsState];
        StrokeRound(bubble, 8, Col(kLineStrong, 0.8 * a), 1);
        DrawText(tip, bubble, f, Col(kText, 1.0), NSTextAlignmentCenter, 0.2, a);
        if (_draggingProgress) {
            FillRound(NSMakeRect(x - 5, pr.origin.y - 2, 10, 10), 5, Col(kAmber, a));
        }
    }

    // 时间
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    DrawText(FmtTime(pos), NSMakeRect(28, 66, 110, 18), mono, Col(kText, 1.0),
             NSTextAlignmentLeft, 0.2, a);
    NSString *right = dur > 0 ? FmtTime(dur) : FmtTime(pos);
    DrawText(right, NSMakeRect(self.W - 28 - 220, 66, 220, 18), mono, Col(kTextDim, 1.0),
             NSTextAlignmentRight, 0.2, a);

    // 播放/暂停
    NSRect play = [self playRect];
    BOOL playHover = (_hoverCtrl == PeCtrlPlay);
    FillRound(play, 24, Col(kAmber, (playHover ? 1.0 : 0.96) * a));
    [self drawPlayPause:NSInsetRect(play, 15, 15) color:Col(kAmberInk, a) paused:_st.paused];

    [self drawIconButton:[self backRect] hover:_hoverCtrl == PeCtrlBack];
    [self drawSeekIcon:[self backRect] forward:NO color:Col(kText, 0.94 * a) alpha:a];
    [self drawIconButton:[self fwdRect] hover:_hoverCtrl == PeCtrlForward];
    [self drawSeekIcon:[self fwdRect] forward:YES color:Col(kText, 0.94 * a) alpha:a];

    [self drawIconButton:[self muteRect] hover:_hoverCtrl == PeCtrlMute];
    [self drawSpeaker:[self muteRect] muted:_st.muted != 0 color:Col(kText, 0.94 * a) alpha:a];

    if (![self compact]) {
        NSRect vr = [self volumeRect];
        FillRound(NSMakeRect(vr.origin.x, vr.origin.y + 9, vr.size.width, 4), 2, Col(0xFFFFFF, 0.18 * a));
        CGFloat vf = (CGFloat)_st.volume / 100.0;
        if (_st.muted) vf = 0;
        FillRound(NSMakeRect(vr.origin.x, vr.origin.y + 9, vr.size.width * vf, 4), 2, Col(kAmber, 0.9 * a));
        FillRound(NSMakeRect(vr.origin.x + vr.size.width * vf - 5, vr.origin.y + 6, 10, 10), 5,
                  Col(kText, a));
    }

    // 右侧胶囊
    BOOL speedActive = fabs(_st.speed - 1.0) > 0.01;
    [self drawPill:[self speedRect] title:SpeedLabel(_st.speed)
             hover:_hoverCtrl == PeCtrlSpeed active:speedActive];
    NSString *audioTitle = @"音轨";
    if (_st.audio_tracks > 0 && ![self compact]) {
        audioTitle = [NSString stringWithFormat:@"音轨 %d", _st.audio_track];
    }
    [self drawPill:[self audioRect] title:audioTitle hover:_hoverCtrl == PeCtrlAudio
            active:_menu == PeMenuAudio];
    NSString *subTitle = _st.subtitle_track > 0
        ? [NSString stringWithFormat:@"字幕 %d", _st.subtitle_track] : @"字幕";
    if ([self compact] && _st.subtitle_track > 0) subTitle = @"字幕";
    [self drawPill:[self subRect] title:subTitle hover:_hoverCtrl == PeCtrlSub
            active:_st.subtitle_track > 0 || _menu == PeMenuSub];
    [self drawPill:[self aspectRect] title:[NSString stringWithUTF8String:_st.aspect]
             hover:_hoverCtrl == PeCtrlAspect active:strcmp(_st.aspect, "auto") != 0];

    [self drawIconButton:[self fsRect] hover:_hoverCtrl == PeCtrlFullscreen];
    [self drawFullscreen:[self fsRect] color:Col(kText, 0.94 * a) alpha:a];
    [self drawIconButton:[self closeRect] hover:_hoverCtrl == PeCtrlClose];
    [self drawClose:[self closeRect] color:Col(kText, 0.9 * a) alpha:a];
}

- (void)drawIconButton:(NSRect)r hover:(BOOL)hover {
    if (!hover) return;
    FillRound(NSInsetRect(r, -2, -2), 9, Col(0xFFFFFF, 0.10 * _fade));
}

- (void)drawPill:(NSRect)r title:(NSString *)title hover:(BOOL)hover active:(BOOL)active {
    NSColor *bg = active ? Col(kAmber, 0.16 * _fade) : Col(0xFFFFFF, (hover ? 0.12 : 0.06) * _fade);
    FillRound(r, 9, bg);
    StrokeRound(r, 9, active ? Col(kAmber, 0.35 * _fade) : Col(0xFFFFFF, 0.08 * _fade), 1);
    NSColor *fg = active ? Col(kAmber, 1.0) : Col(kText, 1.0);
    if (hover && !active) fg = Col(0xFFFFFF, 1.0);
    DrawText(title, r, [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
             fg, NSTextAlignmentCenter, 0.1, _fade);
}

- (void)drawPlayPause:(NSRect)r color:(NSColor *)color paused:(BOOL)paused {
    if (!paused) {
        CGFloat bw = r.size.width * 0.28;
        FillRound(NSMakeRect(r.origin.x + r.size.width * 0.08, r.origin.y, bw, r.size.height), 1.5, color);
        FillRound(NSMakeRect(r.origin.x + r.size.width * 0.62, r.origin.y, bw, r.size.height), 1.5, color);
    } else {
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(r.origin.x + r.size.width * 0.18, r.origin.y)];
        [p lineToPoint:NSMakePoint(r.origin.x + r.size.width, r.origin.y + r.size.height / 2)];
        [p lineToPoint:NSMakePoint(r.origin.x + r.size.width * 0.18, r.origin.y + r.size.height)];
        [p closePath];
        [color setFill];
        [p fill];
    }
}

- (void)drawSeekIcon:(NSRect)r forward:(BOOL)forward color:(NSColor *)color alpha:(CGFloat)a {
    NSRect c = NSInsetRect(r, 9, 9);
    CGFloat cx = NSMidX(c), cy = NSMidY(c);
    CGFloat radius = c.size.width / 2.0;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:radius
                                startAngle:forward ? 40 : 140
                                  endAngle:forward ? 320 : 220
                                 clockwise:forward];
    arc.lineWidth = 1.6;
    [color setStroke];
    [arc stroke];
    // 箭头
    CGFloat ax = forward ? cx + radius * cos(40 * M_PI / 180) : cx + radius * cos(140 * M_PI / 180);
    CGFloat ay = cy + radius * sin(40 * M_PI / 180);
    NSBezierPath *head = [NSBezierPath bezierPath];
    if (forward) {
        [head moveToPoint:NSMakePoint(ax, ay + 4)];
        [head lineToPoint:NSMakePoint(ax + 4, ay)];
        [head lineToPoint:NSMakePoint(ax - 2, ay - 3)];
    } else {
        [head moveToPoint:NSMakePoint(ax, ay + 4)];
        [head lineToPoint:NSMakePoint(ax - 4, ay)];
        [head lineToPoint:NSMakePoint(ax + 2, ay - 3)];
    }
    head.lineWidth = 1.6;
    [head stroke];
    DrawText(@"10", NSInsetRect(c, 4, 4), [NSFont systemFontOfSize:8.5 weight:NSFontWeightSemibold],
             color, NSTextAlignmentCenter, 0, a);
}

- (void)drawSpeaker:(NSRect)r muted:(BOOL)muted color:(NSColor *)color alpha:(CGFloat)a {
    NSRect c = NSInsetRect(r, 10, 10);
    CGFloat x = c.origin.x, y = c.origin.y, h = c.size.height, w = c.size.width;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x, y + h * 0.32)];
    [p lineToPoint:NSMakePoint(x + w * 0.28, y + h * 0.32)];
    [p lineToPoint:NSMakePoint(x + w * 0.58, y)];
    [p lineToPoint:NSMakePoint(x + w * 0.58, y + h)];
    [p lineToPoint:NSMakePoint(x + w * 0.28, y + h * 0.68)];
    [p lineToPoint:NSMakePoint(x, y + h * 0.68)];
    [p closePath];
    [color setFill];
    [p fill];
    if (!muted) {
        for (int i = 0; i < 2; i++) {
            NSBezierPath *arc = [NSBezierPath bezierPath];
            [arc appendBezierPathWithArcWithCenter:NSMakePoint(x + w * 0.58, y + h / 2)
                                           radius:w * (0.22 + 0.18 * i)
                                       startAngle:-48 endAngle:48];
            arc.lineWidth = 1.3;
            [color setStroke];
            [arc stroke];
        }
    } else {
        NSBezierPath *slash = [NSBezierPath bezierPath];
        [slash moveToPoint:NSMakePoint(x + w * 0.55, y + h * 0.2)];
        [slash lineToPoint:NSMakePoint(x + w * 0.95, y + h * 0.8)];
        slash.lineWidth = 1.6;
        [color setStroke];
        [slash stroke];
    }
}

- (void)drawFullscreen:(NSRect)r color:(NSColor *)color alpha:(CGFloat)a {
    NSRect c = NSInsetRect(r, 12, 12);
    CGFloat x = c.origin.x, y = c.origin.y, w = c.size.width, h = c.size.height, L = 4.5;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(x, y + L)]; [p lineToPoint:NSMakePoint(x, y)]; [p lineToPoint:NSMakePoint(x + L, y)];
    [p moveToPoint:NSMakePoint(x + w - L, y)]; [p lineToPoint:NSMakePoint(x + w, y)]; [p lineToPoint:NSMakePoint(x + w, y + L)];
    [p moveToPoint:NSMakePoint(x + w, y + h - L)]; [p lineToPoint:NSMakePoint(x + w, y + h)]; [p lineToPoint:NSMakePoint(x + w - L, y + h)];
    [p moveToPoint:NSMakePoint(x + L, y + h)]; [p lineToPoint:NSMakePoint(x, y + h)]; [p lineToPoint:NSMakePoint(x, y + h - L)];
    p.lineWidth = 1.6;
    p.lineCapStyle = NSLineCapStyleRound;
    [color setStroke];
    [p stroke];
}

- (void)drawClose:(NSRect)r color:(NSColor *)color alpha:(CGFloat)a {
    NSRect c = NSInsetRect(r, 13, 13);
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(c.origin.x, c.origin.y)];
    [p lineToPoint:NSMakePoint(NSMaxX(c), NSMaxY(c))];
    [p moveToPoint:NSMakePoint(NSMinX(c), NSMaxY(c))];
    [p lineToPoint:NSMakePoint(NSMaxX(c), NSMinY(c))];
    p.lineWidth = 1.7;
    p.lineCapStyle = NSLineCapStyleRound;
    [color setStroke];
    [p stroke];
}

- (void)drawSubtitles {
    if (!_player) return;
    char buf[4096];
    int n = pe_get_subtitle_text(_player, buf, sizeof(buf));
    if (n <= 0) return;
    NSString *text = [NSString stringWithUTF8String:buf];
    if (!text.length) return;

    CGFloat maxW = self.W * 0.82;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineSpacing = 4;
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowBlurRadius = 6;
    shadow.shadowOffset = NSMakeSize(0, -1);
    shadow.shadowColor = Col(0x000000, 0.9);
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:26 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: Col(0xFFFFFF, 0.98),
        NSStrokeColorAttributeName: Col(0x000000, 0.92),
        NSStrokeWidthAttributeName: @(-3.2),
        NSParagraphStyleAttributeName: ps,
        NSShadowAttributeName: shadow,
    };
    NSSize size = [text boundingRectWithSize:NSMakeSize(maxW, 400)
                                    options:NSStringDrawingUsesLineFragmentOrigin
                                 attributes:attrs].size;
    CGFloat bottom = (_fade > 0.4 ? 150 : 52);
    NSRect r = NSMakeRect((self.W - size.width) / 2.0, bottom, size.width + 4, size.height + 4);
    [text drawWithRect:r options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
}

- (void)drawSpinner {
    CGFloat cx = self.W / 2.0, cy = self.H / 2.0;
    CGFloat radius = 17;
    NSRect ring = NSMakeRect(cx - radius, cy - radius, radius * 2, radius * 2);
    NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:ring];
    track.lineWidth = 3;
    [Col(0xFFFFFF, 0.14) setStroke];
    [track stroke];
    NSBezierPath *arc = [NSBezierPath bezierPath];
    CGFloat start = _spinnerPhase;
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:radius
                                startAngle:start * 180 / M_PI
                                  endAngle:(start + 1.5) * 180 / M_PI];
    arc.lineWidth = 3;
    arc.lineCapStyle = NSLineCapStyleRound;
    [Col(kAmber, 0.95) setStroke];
    [arc stroke];
    DrawText(@"正在缓冲", NSMakeRect(cx - 80, cy - radius - 30, 160, 18),
             [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],
             Col(kTextDim, 1.0), NSTextAlignmentCenter, 0.3, 1.0);
}

- (void)drawToast {
    NSFont *f = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    NSSize ts = [_toast sizeWithAttributes:@{NSFontAttributeName: f}];
    CGFloat tw = MIN(self.W - 80, ts.width + 58);
    CGFloat th = 42;
    NSRect r = NSMakeRect((self.W - tw) / 2.0, self.H - 128, tw, th);
    NSShadow *sh = [[NSShadow alloc] init];
    sh.shadowBlurRadius = 16;
    sh.shadowOffset = NSMakeSize(0, -3);
    sh.shadowColor = Col(0x000000, 0.55);
    [NSGraphicsContext saveGraphicsState];
    [sh set];
    FillRound(r, 10, Col(kPanelAlt, 0.97));
    [NSGraphicsContext restoreGraphicsState];
    StrokeRound(r, 10, Col(kLineStrong, 0.9), 1);
    CGFloat dotX = r.origin.x + 18;
    FillRound(NSMakeRect(dotX, NSMidY(r) - 3, 6, 6), 3, _toastError ? Col(kRed, 1) : Col(kGreen, 1));
    DrawText(_toast, NSMakeRect(dotX + 14, r.origin.y, tw - 38, th), f,
             Col(kText, 1.0), NSTextAlignmentLeft, 0, _toastFade);
}

// ---------------- 菜单 ----------------

- (void)buildMenu:(PeMenuKind)menu {
    [_menuItems removeAllObjects];
    NSString *header = @"";
    if (menu == PeMenuSpeed) {
        header = @"播放速度";
        NSArray *speeds = @[@0.5, @0.75, @1.0, @1.25, @1.5, @2.0];
        for (NSNumber *n in speeds) {
            double v = n.doubleValue;
            BOOL sel = fabs(_st.speed - v) < 0.01;
            [_menuItems addObject:@{@"label": SpeedLabel(v),
                                    @"detail": v == 1.0 ? @"原速" : @"变速不变调",
                                    @"selected": @(sel), @"kind": @"speed", @"value": n}];
        }
        [_menuItems addObject:@{@"label": @"循环播放",
                                @"detail": _st.loop ? @"开" : @"关",
                                @"selected": @(_st.loop), @"kind": @"loop", @"value": @(_st.loop ? 0 : 1)}];
    } else if (menu == PeMenuAudio) {
        header = @"音轨";
        int n = pe_audio_track_count(_player);
        for (int i = 0; i < n; i++) {
            PeTrackInfo t;
            if (pe_audio_track_info(_player, i, &t) != 0) continue;
            NSString *lang = [NSString stringWithUTF8String:t.lang];
            NSString *title = [NSString stringWithUTF8String:t.title];
            NSString *label = title.length ? title : (lang.length ? lang : [NSString stringWithFormat:@"音轨 %d", t.id]);
            NSString *detail = [NSString stringWithFormat:@"%s · %dch", t.codec, t.channels];
            if (lang.length && title.length) detail = [NSString stringWithFormat:@"%@ · %@", lang, detail];
            [_menuItems addObject:@{@"label": label, @"detail": detail,
                                    @"selected": @(_st.audio_track == t.id),
                                    @"kind": @"audio", @"value": @(t.id)}];
        }
        if (_menuItems.count == 0) {
            [_menuItems addObject:@{@"label": @"无音轨", @"detail": @"", @"selected": @NO,
                                    @"kind": @"none", @"value": @0}];
        }
    } else if (menu == PeMenuSub) {
        header = @"字幕";
        [_menuItems addObject:@{@"label": @"关闭字幕", @"detail": @"",
                                @"selected": @(_st.subtitle_track == 0),
                                @"kind": @"sub", @"value": @0}];
        int n = pe_subtitle_track_count(_player);
        for (int i = 0; i < n; i++) {
            PeTrackInfo t;
            if (pe_subtitle_track_info(_player, i, &t) != 0) continue;
            NSString *lang = [NSString stringWithUTF8String:t.lang];
            NSString *title = [NSString stringWithUTF8String:t.title];
            NSString *label = title.length ? title : (lang.length ? lang : [NSString stringWithFormat:@"字幕 %d", t.id]);
            [_menuItems addObject:@{@"label": label, @"detail": [NSString stringWithUTF8String:t.codec],
                                    @"selected": @(_st.subtitle_track == t.id),
                                    @"kind": @"sub", @"value": @(t.id)}];
        }
    } else if (menu == PeMenuAspect) {
        header = @"画面比例";
        NSArray *items = @[
            @{@"label": @"自动", @"detail": @"适应窗口", @"kind": @"aspect", @"value": @"auto"},
            @{@"label": @"16:9", @"detail": @"宽屏", @"kind": @"aspect", @"value": @"16:9"},
            @{@"label": @"4:3", @"detail": @"经典", @"kind": @"aspect", @"value": @"4:3"},
            @{@"label": @"填充", @"detail": @"裁剪铺满", @"kind": @"aspect", @"value": @"fill"},
        ];
        for (NSDictionary *d in items) {
            BOOL sel = [d[@"value"] isEqualToString:[NSString stringWithUTF8String:_st.aspect]];
            NSMutableDictionary *m = [d mutableCopy];
            m[@"selected"] = @(sel);
            [_menuItems addObject:m];
        }
    }
    _menuHeader = header;
}

- (void)openMenu:(PeMenuKind)menu anchor:(NSRect)anchor {
    if (_menu == menu) {
        _menu = PeMenuNone;
        [self setNeedsDisplay:YES];
        return;
    }
    _menu = menu;
    _menuAnchor = anchor;
    [self buildMenu:menu];
    CGFloat width = 232;
    CGFloat headerH = 30;
    CGFloat rowH = 36;
    CGFloat height = headerH + rowH * (CGFloat)_menuItems.count + 10;
    CGFloat x = NSMidX(anchor) - width / 2.0;
    x = MAX(16, MIN(self.W - width - 16, x));
    CGFloat y = NSMaxY(anchor) + 10;
    if (y + height > self.H - 20) y = NSMinY(anchor) - height - 10;
    if (y < 20) y = 20;
    _menuRect = NSMakeRect(x, y, width, height);
    _menuHover = -1;
    _targetVisible = YES;
    _hideAt = [NSDate timeIntervalSinceReferenceDate] + 30;
    [self setNeedsDisplay:YES];
}

- (void)drawMenu {
    NSRect r = _menuRect;
    NSShadow *sh = [[NSShadow alloc] init];
    sh.shadowBlurRadius = 22;
    sh.shadowOffset = NSMakeSize(0, -6);
    sh.shadowColor = Col(0x000000, 0.6);
    [NSGraphicsContext saveGraphicsState];
    [sh set];
    FillRound(r, 12, Col(kPanelAlt, 0.985));
    [NSGraphicsContext restoreGraphicsState];
    StrokeRound(r, 12, Col(kLineStrong, 0.95), 1);

    DrawText(_menuHeader, NSMakeRect(r.origin.x + 16, NSMaxY(r) - 26, r.size.width - 32, 16),
             [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
             Col(kTextFaint, 1.0), NSTextAlignmentLeft, 0.8, 1.0);

    CGFloat rowH = 36;
    CGFloat y = NSMaxY(r) - 30 - rowH;
    for (NSInteger i = 0; i < (NSInteger)_menuItems.count; i++) {
        NSDictionary *item = _menuItems[i];
        NSRect row = NSMakeRect(r.origin.x + 6, y, r.size.width - 12, rowH);
        if ((NSInteger)_menuHover == i) {
            FillRound(row, 8, Col(0xFFFFFF, 0.08));
        }
        BOOL sel = [item[@"selected"] boolValue];
        NSColor *labelColor = sel ? Col(kAmber, 1.0) : Col(kText, 1.0);
        DrawText(item[@"label"], NSMakeRect(row.origin.x + 12, row.origin.y + 2, row.size.width - 60, 20),
                 [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium],
                 labelColor, NSTextAlignmentLeft, 0, 1.0);
        NSString *detail = item[@"detail"];
        if (detail.length) {
            DrawText(detail, NSMakeRect(row.origin.x + 12, row.origin.y + 18, row.size.width - 60, 14),
                     [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular],
                     Col(kTextFaint, 1.0), NSTextAlignmentLeft, 0, 1.0);
        }
        if (sel) {
            NSBezierPath *check = [NSBezierPath bezierPath];
            CGFloat cx = NSMaxX(row) - 20, cy = NSMidY(row);
            [check moveToPoint:NSMakePoint(cx - 5, cy)];
            [check lineToPoint:NSMakePoint(cx - 1, cy - 4)];
            [check lineToPoint:NSMakePoint(cx + 5, cy + 4)];
            check.lineWidth = 1.8;
            check.lineCapStyle = NSLineCapStyleRound;
            [Col(kAmber, 1.0) setStroke];
            [check stroke];
        }
        y -= rowH;
    }
}

// ---------------- 交互 ----------------

- (void)showControls {
    _targetVisible = YES;
    _hideAt = [NSDate timeIntervalSinceReferenceDate] + 2.5;
    if (_fade < 0.35) _fade = 0.35;
    [self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event { _mouseInside = YES; [self showControls]; }
- (void)mouseExited:(NSEvent *)event {
    _mouseInside = NO;
    _hoverCtrl = PeCtrlNone;
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    _mouse = [self convertPoint:event.locationInWindow fromView:nil];
    _mouseInside = YES;
    [self showControls];
    if (_menu != PeMenuNone) {
        NSInteger idx = [self menuRowAtPoint:_mouse];
        if (idx != _menuHover) {
            _menuHover = idx;
            [self setNeedsDisplay:YES];
        }
        return;
    }
    PeCtrlId c = [self controlAtPoint:_mouse];
    if (c != _hoverCtrl) {
        _hoverCtrl = c;
    }
    if (c == PeCtrlProgress) {
        NSRect pr = [self progressRect];
        CGFloat f = (_mouse.x - pr.origin.x) / MAX(1, pr.size.width);
        _hoverFrac = MAX(0, MIN(1, f));
    }
    [self setNeedsDisplay:YES];
}

- (NSInteger)menuRowAtPoint:(NSPoint)p {
    if (_menu == PeMenuNone || !NSPointInRect(p, _menuRect)) return -1;
    CGFloat rowH = 36;
    CGFloat top = NSMaxY(_menuRect) - 30;
    for (NSInteger i = 0; i < (NSInteger)_menuItems.count; i++) {
        NSRect row = NSMakeRect(_menuRect.origin.x + 6, top - rowH * (i + 1), _menuRect.size.width - 12, rowH);
        if (NSPointInRect(p, row)) return i;
    }
    return -1;
}

- (void)mouseDown:(NSEvent *)event {
    _mouse = [self convertPoint:event.locationInWindow fromView:nil];
    [self showControls];
    if (_menu != PeMenuNone) {
        NSInteger idx = [self menuRowAtPoint:_mouse];
        if (idx >= 0) {
            [self activateMenuItem:idx];
            return;
        }
        if (!NSPointInRect(_mouse, _menuRect)) {
            _menu = PeMenuNone;
            [self setNeedsDisplay:YES];
        }
        return;
    }
    if (_fade < 0.35) return;
    PeCtrlId c = [self controlAtPoint:_mouse];
    if (c == PeCtrlProgress) {
        _draggingProgress = YES;
        NSRect pr = [self progressRect];
        _dragFrac = MAX(0, MIN(1, (_mouse.x - pr.origin.x) / MAX(1, pr.size.width)));
        _hideAt = [NSDate timeIntervalSinceReferenceDate] + 30;
        [self setNeedsDisplay:YES];
        return;
    }
    if (c == PeCtrlVolume) {
        _draggingVolume = YES;
        [self setVolumeFromPoint:_mouse];
        return;
    }
    if (c != PeCtrlNone) {
        [self activateControl:c frac:0];
        return;
    }
    if (event.clickCount >= 2) {
        [_singleClickTimer invalidate];
        _singleClickTimer = nil;
        pe_toggle_fullscreen(_player);
        return;
    }
    // 单击视频区域：延迟一会儿再切换播放，避免和双击全屏打架。
    [_singleClickTimer invalidate];
    __weak PeOverlayView *weakSelf = self;
    _singleClickTimer = [NSTimer scheduledTimerWithTimeInterval:0.22 repeats:NO block:^(NSTimer *t) {
        (void)t;
        PeOverlayView *s = weakSelf;
        if (!s || !s->_player) return;
        if (s->_st.ended) pe_restart(s->_player);
        else pe_toggle_pause(s->_player);
        [s showControls];
    }];
}

- (void)mouseDragged:(NSEvent *)event {
    _mouse = [self convertPoint:event.locationInWindow fromView:nil];
    if (_draggingProgress) {
        NSRect pr = [self progressRect];
        _dragFrac = MAX(0, MIN(1, (_mouse.x - pr.origin.x) / MAX(1, pr.size.width)));
        [self setNeedsDisplay:YES];
    } else if (_draggingVolume) {
        [self setVolumeFromPoint:_mouse];
    }
}

- (void)mouseUp:(NSEvent *)event {
    _mouse = [self convertPoint:event.locationInWindow fromView:nil];
    if (_draggingProgress) {
        double dur = _st.duration;
        if (dur > 0) pe_seek(_player, _dragFrac * dur);
        _draggingProgress = NO;
        _hideAt = [NSDate timeIntervalSinceReferenceDate] + 2.5;
        [self setNeedsDisplay:YES];
        return;
    }
    if (_draggingVolume) {
        _draggingVolume = NO;
        _hideAt = [NSDate timeIntervalSinceReferenceDate] + 2.5;
        return;
    }
}

- (void)setVolumeFromPoint:(NSPoint)p {
    NSRect vr = [self volumeRect];
    if (vr.size.width <= 1) return;
    CGFloat f = (p.x - vr.origin.x) / vr.size.width;
    f = MAX(0, MIN(1, f));
    pe_set_volume(_player, (int)llround(f * 100));
    if (_st.muted) pe_set_mute(_player, 0);
    [self setNeedsDisplay:YES];
}

- (void)activateControl:(PeCtrlId)ctrl frac:(double)frac {
    if (!_player) return;
    switch (ctrl) {
        case PeCtrlPlay:
            if (_st.ended) pe_restart(_player);
            else pe_toggle_pause(_player);
            break;
        case PeCtrlBack:
            pe_seek_relative(_player, -10);
            break;
        case PeCtrlForward:
            pe_seek_relative(_player, 10);
            break;
        case PeCtrlProgress:
            if (_st.duration > 0) pe_seek(_player, frac * _st.duration);
            break;
        case PeCtrlMute:
            pe_set_mute(_player, _st.muted ? 0 : 1);
            break;
        case PeCtrlSpeed:
            [self openMenu:PeMenuSpeed anchor:[self speedRect]];
            return;
        case PeCtrlAudio:
            [self openMenu:PeMenuAudio anchor:[self audioRect]];
            return;
        case PeCtrlSub:
            [self openMenu:PeMenuSub anchor:[self subRect]];
            return;
        case PeCtrlAspect:
            [self openMenu:PeMenuAspect anchor:[self aspectRect]];
            return;
        case PeCtrlFullscreen:
            pe_toggle_fullscreen(_player);
            break;
        case PeCtrlClose:
            [self animateClose];
            return;
        default:
            break;
    }
    [self showControls];
}

- (void)activateMenuItem:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_menuItems.count) return;
    NSDictionary *item = _menuItems[idx];
    NSString *kind = item[@"kind"];
    id value = item[@"value"];
    if (!_player) return;
    if ([kind isEqualToString:@"speed"]) {
        pe_set_speed(_player, [value doubleValue]);
    } else if ([kind isEqualToString:@"loop"]) {
        pe_set_loop(_player, [value boolValue]);
    } else if ([kind isEqualToString:@"audio"]) {
        pe_set_audio_track(_player, [value intValue]);
    } else if ([kind isEqualToString:@"sub"]) {
        pe_set_subtitle_track(_player, [value intValue]);
    } else if ([kind isEqualToString:@"aspect"]) {
        pe_set_aspect(_player, [value UTF8String]);
    }
    _menu = PeMenuNone;
    [self showControls];
    [self setNeedsDisplay:YES];
}

- (void)animateClose {
    [_singleClickTimer invalidate];
    NSWindow *win = self.window;
    if (!win) {
        pe_close_window(_player);
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.22;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        win.animator.alphaValue = 0.0;
    } completionHandler:^{
        pe_close_window(self->_player);
    }];
}

// ---------------- 键盘 ----------------

- (void)keyDown:(NSEvent *)event {
    if ([self handleKeyEvent:event]) return;
    [super keyDown:event];
}

- (BOOL)handleKeyEvent:(NSEvent *)event {
    unsigned short code = event.keyCode;
    NSString *chars = [event.charactersIgnoringModifiers lowercaseString];
    if (code == 49) { // space
        if (_st.ended) pe_restart(_player); else pe_toggle_pause(_player);
    } else if (code == 123) { // left
        pe_seek_relative(_player, -10);
    } else if (code == 124) { // right
        pe_seek_relative(_player, 10);
    } else if (code == 126) { // up
        pe_set_volume(_player, MIN(100, _st.volume + 5));
        if (_st.muted) pe_set_mute(_player, 0);
    } else if (code == 125) { // down
        pe_set_volume(_player, MAX(0, _st.volume - 5));
    } else if (code == 53) { // esc
        if (_st.fullscreen) pe_set_fullscreen(_player, 0);
        return YES;
    } else if ([chars isEqualToString:@"m"]) {
        pe_set_mute(_player, _st.muted ? 0 : 1);
    } else if ([chars isEqualToString:@"f"]) {
        pe_toggle_fullscreen(_player);
    } else if ([chars isEqualToString:@"s"]) {
        [self takeScreenshot];
    } else {
        return NO;
    }
    [self showControls];
    return YES;
}

- (void)takeScreenshot {
    if (!_player || _screenshotBusy) return;
    _screenshotBusy = YES;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"DLNA 截图 %@.png", [fmt stringFromDate:[NSDate date]]];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:[@"Desktop" stringByAppendingPathComponent:name]];
    char err[256] = {0};
    int rc = pe_screenshot(_player, [path fileSystemRepresentation], err, (int)sizeof(err));
    if (rc == 0) {
        [self showToast:@"截图已保存到桌面" error:NO];
    } else {
        [self showToast:[NSString stringWithFormat:@"截图失败：%s", err] error:YES];
    }
    _screenshotBusy = NO;
}

// ---------------- 脚本钩子 ----------------

- (void)debugSetControlsVisible:(BOOL)visible {
    _targetVisible = visible;
    _fade = visible ? 1.0 : 0.0;
    if (visible) _hideAt = [NSDate timeIntervalSinceReferenceDate] + 3600;
    [self setNeedsDisplay:YES];
}

- (BOOL)parseControl:(NSString *)name ctrl:(PeCtrlId *)out frac:(double *)frac {
    NSString *n = name.lowercaseString;
    NSArray *parts = [n componentsSeparatedByString:@":"];
    NSString *base = parts[0];
    if (frac) *frac = parts.count > 1 ? [parts[1] doubleValue] : 0;
    PeCtrlId c = PeCtrlNone;
    if ([base isEqualToString:@"play"]) c = PeCtrlPlay;
    else if ([base isEqualToString:@"back"]) c = PeCtrlBack;
    else if ([base isEqualToString:@"forward"]) c = PeCtrlForward;
    else if ([base isEqualToString:@"progress"]) c = PeCtrlProgress;
    else if ([base isEqualToString:@"volume"]) c = PeCtrlVolume;
    else if ([base isEqualToString:@"mute"]) c = PeCtrlMute;
    else if ([base isEqualToString:@"speed"]) c = PeCtrlSpeed;
    else if ([base isEqualToString:@"audio"]) c = PeCtrlAudio;
    else if ([base isEqualToString:@"sub"]) c = PeCtrlSub;
    else if ([base isEqualToString:@"aspect"]) c = PeCtrlAspect;
    else if ([base isEqualToString:@"fullscreen"]) c = PeCtrlFullscreen;
    else if ([base isEqualToString:@"close"]) c = PeCtrlClose;
    if (c == PeCtrlNone) return NO;
    if (out) *out = c;
    return YES;
}

- (void)debugHoverControl:(NSString *)control {
    PeCtrlId c = PeCtrlNone;
    double frac = 0;
    if (![self parseControl:control ctrl:&c frac:&frac]) return;
    _targetVisible = YES;
    _fade = 1.0;
    _hideAt = [NSDate timeIntervalSinceReferenceDate] + 3600;
    if (c == PeCtrlProgress) {
        NSRect pr = [self progressRect];
        _mouse = NSMakePoint(pr.origin.x + pr.size.width * frac, NSMidY(pr));
        _hoverFrac = frac;
        _mouseInside = YES;
    } else {
        _mouse = NSMakePoint(NSMidX([self rectForControl:c]), NSMidY([self rectForControl:c]));
        _mouseInside = YES;
    }
    _hoverCtrl = c;
    [self setNeedsDisplay:YES];
}

- (void)debugClickControl:(NSString *)control {
    PeCtrlId c = PeCtrlNone;
    double frac = 0;
    if (![self parseControl:control ctrl:&c frac:&frac]) return;
    [self debugHoverControl:control];
    if (c == PeCtrlProgress) {
        [self activateControl:c frac:frac];
    } else {
        [self activateControl:c frac:0];
    }
}

- (void)debugOpenMenu:(NSString *)menu {
    NSString *m = menu.lowercaseString;
    _targetVisible = YES;
    _fade = 1.0;
    _hideAt = [NSDate timeIntervalSinceReferenceDate] + 3600;
    if ([m isEqualToString:@"speed"]) [self openMenu:PeMenuSpeed anchor:[self speedRect]];
    else if ([m isEqualToString:@"audio"]) [self openMenu:PeMenuAudio anchor:[self audioRect]];
    else if ([m isEqualToString:@"sub"]) [self openMenu:PeMenuSub anchor:[self subRect]];
    else if ([m isEqualToString:@"aspect"]) [self openMenu:PeMenuAspect anchor:[self aspectRect]];
    else _menu = PeMenuNone;
    [self setNeedsDisplay:YES];
}

- (void)debugKey:(NSString *)key {
    NSString *k = key.lowercaseString;
    unichar ch = 0;
    unsigned short code = 0;
    if ([k isEqualToString:@"space"]) code = 49;
    else if ([k isEqualToString:@"left"]) code = 123;
    else if ([k isEqualToString:@"right"]) code = 124;
    else if ([k isEqualToString:@"up"]) code = 126;
    else if ([k isEqualToString:@"down"]) code = 125;
    else if ([k isEqualToString:@"esc"]) code = 53;
    else if (k.length) ch = [k characterAtIndex:0];
    if (!_player) return;
    if (code == 49) {
        if (_st.ended) pe_restart(_player); else pe_toggle_pause(_player);
    } else if (code == 123) pe_seek_relative(_player, -10);
    else if (code == 124) pe_seek_relative(_player, 10);
    else if (code == 126) pe_set_volume(_player, MIN(100, _st.volume + 5));
    else if (code == 125) pe_set_volume(_player, MAX(0, _st.volume - 5));
    else if (code == 53) { if (_st.fullscreen) pe_set_fullscreen(_player, 0); }
    else if (ch == 'm') pe_set_mute(_player, _st.muted ? 0 : 1);
    else if (ch == 'f') pe_toggle_fullscreen(_player);
    else if (ch == 's') [self takeScreenshot];
    [self showControls];
}

@end
