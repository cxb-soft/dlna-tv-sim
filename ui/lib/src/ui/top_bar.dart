import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../theme.dart';
import '../util/format.dart';
import 'now_playing.dart' show engineLabel;
import 'update_banner.dart';
import 'widgets.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;

    late String statusLabel;
    late Color statusColor;
    var pulse = false;
    switch (controller.phase) {
      case EnginePhase.booting:
        statusLabel = '启动中';
        statusColor = C.blue;
        pulse = true;
      case EnginePhase.failed:
        statusLabel = '未连接';
        statusColor = C.red;
      case EnginePhase.ready:
        final s = controller.state;
        if (s == null) {
          statusLabel = '已连接';
          statusColor = C.green;
        } else if (s.playing) {
          statusLabel = '正在播放';
          statusColor = C.amber;
          pulse = true;
        } else if (s.paused) {
          statusLabel = '已暂停';
          statusColor = C.blue;
        } else if (s.transitioning) {
          statusLabel = '准备中';
          statusColor = C.blue;
          pulse = true;
        } else {
          statusLabel = s.hasMedia ? '已停止' : '待机';
          statusColor = C.green;
        }
    }

    final deviceName = (state?.friendlyName.isNotEmpty ?? false)
        ? state!.friendlyName
        : (controller.phase == EnginePhase.booting ? '正在启动引擎…' : '未连接引擎');

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: C.bg,
        border: Border(bottom: BorderSide(color: C.line)),
      ),
      child: Row(
        children: [
          const _Logo(),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DLNA 电视',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: C.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                deviceName,
                style: T.meta.copyWith(fontSize: 11, color: C.textDim),
              ),
            ],
          ),
          const SizedBox(width: 16),
          StatusPill(label: statusLabel, color: statusColor, pulse: pulse),
          const Spacer(),
          _EngineChip(controller: controller),
          const SizedBox(width: 10),
          _UpdateButton(controller: controller),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF2C27C), Color(0xFFD99447)],
        ),
        boxShadow: [
          BoxShadow(
            color: C.amber.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: const Icon(Icons.tv_rounded, size: 18, color: C.amberInk),
    );
  }
}

class _EngineChip extends StatelessWidget {
  const _EngineChip({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final parts = <String>[
      if (state != null && state.player.isNotEmpty) engineLabel(state.player),
      ':${controller.port}',
      if (state != null && state.uptimeSeconds > 0) fmtUptime(state.uptimeSeconds),
    ];

    final connected = controller.phase == EnginePhase.ready;
    final dotColor = connected ? C.green : (controller.phase == EnginePhase.failed ? C.red : C.blue);

    return SoftButton(
      onPressed: controller.phase == EnginePhase.booting ? null : controller.restartEngine,
      tooltip: state == null
          ? '引擎未连接，点击重试'
          : '引擎 v${state.version} · ${state.player} · 点击重启引擎',
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            parts.join('  ·  '),
            style: T.mono.copyWith(fontSize: 10.5, color: C.textDim),
          ),
          const SizedBox(width: 7),
          const Icon(Icons.restart_alt_rounded, size: 13, color: C.textFaint),
        ],
      ),
    );
  }
}

class _UpdateButton extends StatelessWidget {
  const _UpdateButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final hasUpdate = controller.hasUpdate;
    final checking = controller.updateChecking;

    return SoftButton(
      onPressed: checking
          ? null
          : () async {
              final info = await controller.checkForUpdates(manual: true);
              if (!context.mounted) return;
              if (info != null) return;
              final messenger = ScaffoldMessenger.of(context);
              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    controller.updateError ?? '已是最新版本 v${controller.version}',
                  ),
                  duration: const Duration(seconds: 3),
                ),
              );
            },
      background: hasUpdate ? C.amberSoft : C.panelAlt,
      borderColor: hasUpdate ? C.amber.withValues(alpha: 0.4) : C.line,
      tooltip: hasUpdate
          ? '发现新版本 v${controller.update!.version}'
          : '检查 GitHub 上有没有新版本',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (checking)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          else
            Icon(
              Icons.system_update_alt_rounded,
              size: 15,
              color: hasUpdate ? C.amber : C.textDim,
            ),
          const SizedBox(width: 6),
          Text(
            hasUpdate
                ? 'v${controller.update!.version} 可用'
                : (checking ? '检查中' : '检查更新'),
            style: T.button.copyWith(
              fontSize: 12,
              color: hasUpdate ? C.amber : C.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部更新横幅（不打断操作、可关掉）。
class UpdateBannerSlot extends StatelessWidget {
  const UpdateBannerSlot({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => UpdateBanner(controller: controller);
}
