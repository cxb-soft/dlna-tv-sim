#import <Cocoa/Cocoa.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct PePlayer PePlayer;
#ifdef __cplusplus
}
#endif

// 自绘的播放器控件层：深色影院风，叠在 AVSampleBufferDisplayLayer 之上。
// 所有方法都必须在主线程调用；engine_darwin.m 会通过 UI 队列投递。
@interface PeOverlayView : NSView
- (instancetype)initWithFrame:(NSRect)frame
                       player:(void *)player
                        title:(NSString *)title
                       device:(NSString *)device;
- (void)shutdown;

// 脚本/验证钩子
- (void)debugSetControlsVisible:(BOOL)visible;
- (void)debugHoverControl:(NSString *)control;
- (void)debugClickControl:(NSString *)control;
- (void)debugOpenMenu:(NSString *)menu;
- (void)debugKey:(NSString *)key;
@end
