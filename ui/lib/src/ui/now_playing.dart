import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../models/engine_state.dart';
import '../theme.dart';
import '../util/format.dart';
import 'widgets.dart';

/// 主区：启动中 / 启动失败 / 正在播放 三种形态。
class NowPlayingSection extends StatelessWidget {
  const NowPlayingSection({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.phase) {
      case EnginePhase.booting:
        return _BootingCard(controller: controller);
      case EnginePhase.failed:
        return _FailureCard(controller: controller);
      case EnginePhase.ready:
        return NowPlayingCard(controller: controller);
    }
  }
}

Color _stateColor(EngineState? s) {
  if (s == null) return C.green;
  if (s.playing) return C.amber;
  if (s.paused) return C.blue;
  if (s.transitioning) return C.blue;
  return s.hasMedia ? C.textDim : C.green;
}

String _engineTag(String player) {
  switch (player) {
    case 'mpv':
      return 'MPV';
    case 'vlc':
      return 'VLC';
    case 'web':
      return 'WEB';
    default:
      return player.toUpperCase();
  }
}

String engineLabel(String player) {
  switch (player) {
    case 'mpv':
      return 'mpv';
    case 'vlc':
      return 'VLC';
    case 'web':
      return '网页播放';
    default:
      return player.isEmpty ? '未选择' : player;
  }
}

class NowPlayingCard extends StatefulWidget {
  const NowPlayingCard({super.key, required this.controller});

  final AppController controller;

  @override
  State<NowPlayingCard> createState() => _NowPlayingCardState();
}

class _NowPlayingCardState extends State<NowPlayingCard> with SingleTickerProviderStateMixin {
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
    value: 0.5,
  );

  double? _seekDrag;
  double? _volumeDrag;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncAmbient);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncAmbient);
    _ambient.dispose();
    super.dispose();
  }

  /// 播放时屏幕里那层琥珀微光缓慢呼吸；暂停/待机就停住，不做无意义的动画。
  void _syncAmbient() {
    if (!mounted) return;
    final playing = widget.controller.state?.playing ?? false;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (playing && !reduce) {
      if (!_ambient.isAnimating) _ambient.repeat(reverse: true);
    } else if (_ambient.isAnimating) {
      _ambient.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = controller.state;
    return Container(
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.line),
      ),
      padding: const EdgeInsets.fromLTRB(18, 15, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(controller, state),
          const SizedBox(height: 13),
          Expanded(child: _screen(state)),
          const SizedBox(height: 14),
          _controls(state),
          if (controller.commandError != null) ...[
            const SizedBox(height: 10),
            _inlineError(controller, controller.commandError!),
          ],
        ],
      ),
    );
  }

  Widget _header(AppController controller, EngineState? state) {
    return Row(
      children: [
        Text('播放器', style: T.section),
        if (state != null) ...[
          const SizedBox(width: 10),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: _stateColor(state),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            state.stateLabel,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.1,
              color: _stateColor(state),
            ),
          ),
        ],
        const Spacer(),
        if (state != null && state.sourceLabel.isNotEmpty)
          Text(
            '来自 ${state.sourceLabel}',
            style: T.meta.copyWith(fontSize: 11, color: C.textFaint),
          ),
      ],
    );
  }

  Widget _screen(EngineState? state) {
    final hasMedia = state?.hasMedia ?? false;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.62),
            radius: 1.25,
            colors: [Color(0xFF1E232B), Color(0xFF111318), Color(0xFF0B0D10)],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _ambient,
                builder: (context, _) {
                  final t = _ambient.value;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, -0.1),
                        radius: 1.05,
                        colors: [
                          C.amber.withValues(alpha: 0.035 + 0.05 * t),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _screenTopBar(state),
                    Expanded(
                      child: Center(
                        child: hasMedia ? _nowPlayingBody(state!) : _idleBody(state),
                      ),
                    ),
                    _progressRow(state),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _screenTopBar(EngineState? state) {
    final stats = <String>[
      if (state != null) fmtBitrate(state.stats.bitrateKbps),
      if (state != null) fmtFps(state.stats.fps),
    ].where((s) => s.isNotEmpty).join('  ·  ');

    return Row(
      children: [
        if (state != null && state.player.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
            ),
            child: Text(
              _engineTag(state.player),
              style: T.mono.copyWith(
                fontSize: 9,
                letterSpacing: 1.6,
                color: C.textFaint,
              ),
            ),
          ),
        const Spacer(),
        if (stats.isNotEmpty)
          Text(stats, style: T.mono.copyWith(fontSize: 10, color: C.textFaint)),
      ],
    );
  }

  Widget _nowPlayingBody(EngineState state) {
    final subtitle = <String>[
      if (state.status.isNotEmpty) state.status,
      if (state.probe.contentType.isNotEmpty) state.probe.contentType,
      if (state.probe.contentType.isEmpty && state.sourceLabel.isNotEmpty) state.sourceLabel,
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state.displayTitle.isEmpty ? '未知媒体' : state.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: T.display.copyWith(fontSize: 26),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: T.bodyDim.copyWith(color: C.textDim, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _idleBody(EngineState? state) {
    final name = (state?.friendlyName.isNotEmpty ?? false) ? state!.friendlyName : '这台电视';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: C.line),
            ),
            child: const Icon(Icons.cast_rounded, size: 21, color: C.textFaint),
          ),
          const SizedBox(height: 16),
          Text('等待投屏', style: T.title.copyWith(fontSize: 17)),
          const SizedBox(height: 7),
          Text(
            '在手机上选择「$name」开始播放',
            textAlign: TextAlign.center,
            style: T.bodyDim.copyWith(color: C.textFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _progressRow(EngineState? state) {
    if (state == null || !state.hasMedia) {
      return const SizedBox(height: 20);
    }
    final seekable = state.duration > 0;
    final max = seekable ? state.duration : 1.0;
    final value = ((_seekDrag ?? state.position).clamp(0.0, max)).toDouble();
    final shown = _seekDrag ?? state.position;

    return Row(
      children: [
        Text(
          fmtClock(shown),
          style: T.mono.copyWith(fontSize: 10.5, color: C.textDim),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value,
              max: max,
              onChanged: seekable
                  ? (v) => setState(() => _seekDrag = v)
                  : null,
              onChangeEnd: seekable
                  ? (v) {
                      setState(() => _seekDrag = null);
                      widget.controller.control('seek', v);
                    }
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          seekable ? fmtClock(state.duration) : '--:--',
          style: T.mono.copyWith(fontSize: 10.5, color: C.textFaint),
        ),
      ],
    );
  }

  Widget _controls(EngineState? state) {
    final controller = widget.controller;
    final hasMedia = state?.hasMedia ?? false;
    final playing = state?.playing ?? false;
    final muted = state?.mute ?? false;
    final volume = (_volumeDrag ?? (state?.volume ?? 0).toDouble()).clamp(0.0, 100.0).toDouble();

    return Row(
      children: [
        IconSoftButton(
          icon: Icons.replay_10_rounded,
          tooltip: '后退 10 秒',
          onPressed: hasMedia ? () => controller.playerAction('seekrel', value: -10) : null,
        ),
        const SizedBox(width: 6),
        _PlayButton(
          playing: playing,
          enabled: state != null,
          onPressed: () => controller.control(playing ? 'pause' : 'play'),
        ),
        const SizedBox(width: 6),
        IconSoftButton(
          icon: Icons.stop_rounded,
          tooltip: '停止',
          onPressed: hasMedia ? () => controller.control('stop') : null,
        ),
        const SizedBox(width: 6),
        IconSoftButton(
          icon: Icons.forward_10_rounded,
          tooltip: '前进 10 秒',
          onPressed: hasMedia ? () => controller.playerAction('seekrel', value: 10) : null,
        ),
        const SizedBox(width: 16),
        IconSoftButton(
          icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          tooltip: muted ? '取消静音' : '静音',
          active: muted,
          onPressed: state == null ? null : () => controller.control('mute', muted ? 0 : 1),
        ),
        SizedBox(
          width: 88,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
            ),
            child: Slider(
              value: volume,
              max: 100,
              onChanged: (v) => setState(() => _volumeDrag = v),
              onChangeEnd: (v) {
                setState(() => _volumeDrag = null);
                controller.control('volume', v.round());
              },
            ),
          ),
        ),
        SizedBox(
          width: 28,
          child: Text(
            '${volume.round()}',
            textAlign: TextAlign.right,
            style: T.mono.copyWith(fontSize: 10.5, color: C.textDim),
          ),
        ),
        const Spacer(),
        _SpeedMenu(controller: controller, state: state),
        const SizedBox(width: 6),
        IconSoftButton(
          icon: Icons.repeat_rounded,
          tooltip: (state?.loop ?? false) ? '关闭循环' : '循环播放',
          active: state?.loop ?? false,
          onPressed: state == null
              ? null
              : () => controller.playerAction('loop', value: state.loop ? 0 : 1),
        ),
      ],
    );
  }

  Widget _inlineError(AppController controller, String message) {
    return Row(
      children: [
        const Icon(Icons.error_outline_rounded, size: 14, color: C.red),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: T.meta.copyWith(color: C.red, fontSize: 11.5),
          ),
        ),
        GestureDetector(
          onTap: controller.clearCommandError,
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.close_rounded, size: 13, color: C.textFaint),
          ),
        ),
      ],
    );
  }
}

class _PlayButton extends StatefulWidget {
  const _PlayButton({
    required this.playing,
    required this.enabled,
    required this.onPressed,
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final background = !widget.enabled
        ? C.lineStrong
        : (_hover ? const Color(0xFFF3BE70) : C.amber);
    return Tooltip(
      message: widget.playing ? '暂停' : '播放',
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
              boxShadow: widget.enabled
                  ? [
                      BoxShadow(
                        color: C.amber.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 24,
              color: widget.enabled ? C.amberInk : C.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedMenu extends StatelessWidget {
  const _SpeedMenu({required this.controller, required this.state});

  final AppController controller;
  final EngineState? state;

  static const _options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  String _label(double speed) =>
      speed == speed.roundToDouble() ? '${speed.toInt()}.0×' : '$speed×';

  @override
  Widget build(BuildContext context) {
    final current = state?.speed ?? 1;
    return PopupMenuButton<double>(
      tooltip: '播放速度',
      enabled: state != null,
      offset: const Offset(0, -6),
      onSelected: (value) => controller.playerAction('speed', value: value),
      itemBuilder: (context) => [
        for (final option in _options)
          PopupMenuItem<double>(
            value: option,
            height: 34,
            child: Row(
              children: [
                Text(
                  _label(option),
                  style: T.body.copyWith(
                    fontSize: 12.5,
                    color: (option - current).abs() < 0.001 ? C.amber : C.text,
                  ),
                ),
                const Spacer(),
                if ((option - current).abs() < 0.001)
                  const Icon(Icons.check_rounded, size: 14, color: C.amber),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: C.panelAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: C.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(current),
              style: T.mono.copyWith(
                fontSize: 11,
                color: state == null ? C.textFaint : C.text,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.unfold_more_rounded, size: 13, color: C.textFaint),
          ],
        ),
      ),
    );
  }
}

class _BootingCard extends StatelessWidget {
  const _BootingCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.line),
      ),
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 20),
            Text('正在启动引擎', style: T.title.copyWith(fontSize: 17)),
            const SizedBox(height: 8),
            Text(
              controller.bootMessage,
              textAlign: TextAlign.center,
              style: T.bodyDim.copyWith(color: C.textDim),
            ),
            const SizedBox(height: 22),
            Text(
              '端口 ${controller.port} · 引擎在后台运行，不会弹出终端窗口',
              style: T.meta.copyWith(fontSize: 11, color: C.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final detail = controller.fatalDetail;
    return Container(
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.red.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: C.red.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: C.red.withValues(alpha: 0.26)),
                ),
                child: const Icon(Icons.wifi_off_rounded, size: 17, color: C.red),
              ),
              const SizedBox(width: 12),
              Text('引擎没起来', style: T.title.copyWith(fontSize: 17)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            controller.fatalError ?? '未知错误',
            textAlign: TextAlign.center,
            style: T.body.copyWith(fontSize: 13, color: C.text),
          ),
          if (detail != null && detail.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620, maxHeight: 170, minWidth: 380),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0C0E11),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: C.line),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    detail,
                    style: T.mono.copyWith(fontSize: 11, color: C.textDim),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PrimaryButton(
                label: '重试',
                icon: Icons.refresh_rounded,
                onPressed: controller.restartEngine,
              ),
              const SizedBox(width: 10),
              SoftButton(
                onPressed: () {
                  final text = [
                    '端口: ${controller.port}',
                    '错误: ${controller.fatalError ?? ''}',
                    if (detail != null) detail,
                  ].join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('诊断信息已复制'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.copy_rounded, size: 14, color: C.textDim),
                    const SizedBox(width: 6),
                    Text('复制诊断信息', style: T.button.copyWith(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '提示：引擎二进制要和 App 一起打包，或放在 dist/ 里供开发期使用',
            style: T.meta.copyWith(fontSize: 11, color: C.textFaint),
          ),
        ],
      ),
    );
  }
}
