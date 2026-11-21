import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../theme.dart';
import '../util/format.dart';
import 'widgets.dart';

/// 有新版本时从顶部滑出一条不打断操作的横幅。
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final info = controller.update;
    if (info == null || controller.updateDismissed) {
      return const SizedBox.shrink();
    }

    final notes = summarizeNotes(info.notes);
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Container(
        decoration: BoxDecoration(
          color: C.amber.withValues(alpha: 0.055),
          border: Border(
            bottom: BorderSide(color: C.amber.withValues(alpha: 0.16)),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, size: 15, color: C.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: '有新版本 '),
                        TextSpan(
                          text: 'v${info.version}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: C.amber,
                          ),
                        ),
                        TextSpan(
                          text: '  ·  当前 v${controller.version}',
                          style: const TextStyle(
                            color: C.textFaint,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    style: T.body.copyWith(fontSize: 12.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Tooltip(
                      message: notes,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        notes,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: T.meta.copyWith(
                          fontSize: 11.5,
                          color: C.textDim,
                        ),
                      ),
                    ),
                  ],
                  if (controller.installMessage != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      controller.installMessage!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.meta.copyWith(fontSize: 11.5, color: C.amber),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 14),
            SoftButton(
              onPressed: controller.openReleasePage,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text('查看更新', style: T.body.copyWith(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            PrimaryButton(
              label:
                  controller.installing
                      ? (controller.installProgress > 0
                          ? '下载中 ${(controller.installProgress * 100).round()}%'
                          : '准备中…')
                      : '立即更新',
              dense: true,
              onPressed:
                  controller.installing
                      ? null
                      : () => controller.installUpdate(),
            ),
            const SizedBox(width: 4),
            IconSoftButton(
              icon: Icons.close_rounded,
              tooltip: '稍后再说',
              size: 28,
              iconSize: 14,
              onPressed: controller.dismissUpdate,
            ),
          ],
        ),
      ),
    );
  }
}
