import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../theme.dart';
import '../util/format.dart';
import '../services/update_service.dart';
import 'widgets.dart';

class SidePanels extends StatelessWidget {
  const SidePanels({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CastPanel(controller: controller),
          const SizedBox(height: 12),
          DevicePanel(controller: controller),
          const SizedBox(height: 12),
          DiagPanel(controller: controller),
        ],
      ),
    );
  }
}

class CastPanel extends StatefulWidget {
  const CastPanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<CastPanel> createState() => _CastPanelState();
}

class _CastPanelState extends State<CastPanel> {
  final TextEditingController _url = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit([String? text]) async {
    if (_submitting) return;
    if (text != null) _url.text = text;
    setState(() => _submitting = true);
    final ok = await widget.controller.cast(_url.text);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      _url.clear();
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final ready = controller.phase == EnginePhase.ready;
    final recents = controller.recents;

    return Panel(
      title: '投屏',
      trailing: Text(
        '本机 ${controller.port}',
        style: T.mono.copyWith(fontSize: 10.5, color: C.textFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  controller: _url,
                  hint: '视频 / 直播地址',
                  enabled: ready,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _submit(),
                  onChanged: (_) => controller.clearCastError(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 37,
                child: PrimaryButton(
                  label: controller.castBusy ? '投屏中' : '投屏',
                  onPressed: ready && !controller.castBusy ? _submit : null,
                ),
              ),
            ],
          ),
          if (controller.castError != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 13, color: C.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    controller.castError!,
                    style: T.meta.copyWith(color: C.red, fontSize: 11.5),
                  ),
                ),
                GestureDetector(
                  onTap: controller.clearCastError,
                  child: const Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: C.textFaint,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                '最近',
                style: T.meta.copyWith(fontSize: 11, color: C.textFaint),
              ),
              const Spacer(),
              if (recents.isNotEmpty)
                Text(
                  '点一下重新投屏',
                  style: T.meta.copyWith(fontSize: 10.5, color: C.textFaint),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (recents.isEmpty)
            Text(
              '还没有投过东西。手机上发起的投屏也会记在下方事件流里。',
              style: T.bodyDim.copyWith(fontSize: 11.5, color: C.textFaint),
            )
          else
            for (final url in recents)
              _RecentRow(
                url: url,
                enabled: ready,
                onCast: () => _submit(url),
                onRemove: () => controller.removeRecent(url),
              ),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.url,
    required this.enabled,
    required this.onCast,
    required this.onRemove,
  });

  final String url;
  final bool enabled;
  final VoidCallback onCast;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        width: double.infinity,
        child: SoftButton(
          onPressed: enabled ? onCast : null,
          tooltip: url,
          radius: 8,
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          child: Row(
            children: [
              const Icon(
                Icons.play_circle_outline_rounded,
                size: 15,
                color: C.textFaint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      urlLabel(url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.body.copyWith(fontSize: 12),
                    ),
                    Text(
                      urlHost(url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.meta.copyWith(fontSize: 10, color: C.textFaint),
                    ),
                  ],
                ),
              ),
              IconSoftButton(
                icon: Icons.close_rounded,
                size: 26,
                iconSize: 13,
                tooltip: '从列表移除',
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DevicePanel extends StatefulWidget {
  const DevicePanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> {
  late final TextEditingController _name = TextEditingController(
    text: widget.controller.state?.friendlyName ?? '',
  );
  final FocusNode _focus = FocusNode();
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _syncFromState();
      setState(() {});
    });
    widget.controller.addListener(_syncFromState);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromState);
    _focus.dispose();
    _name.dispose();
    super.dispose();
  }

  /// 引擎那边改名成功、或刚连上时，把输入框同步成真实设备名；
  /// 用户正在编辑时不覆盖他的输入。
  void _syncFromState() {
    if (!mounted) return;
    final name = widget.controller.state?.friendlyName ?? '';
    if (name.isEmpty || _focus.hasFocus || _dirty) return;
    if (_name.text != name) {
      setState(() => _name.text = name);
    }
  }

  Future<void> _save() async {
    final ok = await widget.controller.rename(_name.text);
    if (!mounted) return;
    if (ok) {
      _dirty = false;
      final saved = widget.controller.state?.friendlyName ?? _name.text;
      _name.text = saved;
      _focus.unfocus();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('设备名已保存，重新广播后手机会看到新名字'),
            duration: Duration(seconds: 3),
          ),
        );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = controller.state;
    final addresses =
        state == null
            ? ''
            : state.addresses
                .take(3)
                .map((ip) => '$ip:${state.port}')
                .join('\n');
    final extra =
        (state?.addresses.length ?? 0) > 3
            ? '\n还有 ${state!.addresses.length - 3} 个地址'
            : '';

    return Panel(
      title: '设备',
      trailing: Text(
        'v${state?.version.isNotEmpty == true ? state!.version : controller.version}',
        style: T.mono.copyWith(fontSize: 10.5, color: C.textFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  controller: _name,
                  hint: '设备名，手机投屏时看到的名字',
                  enabled: state != null,
                  textInputAction: TextInputAction.done,
                  onChanged: (value) {
                    final changed = value.trim() != (state?.friendlyName ?? '');
                    if (changed != _dirty) setState(() => _dirty = changed);
                  },
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 37,
                child: PrimaryButton(
                  label: '保存',
                  dense: true,
                  onPressed: _dirty && state != null ? _save : null,
                ),
              ),
            ],
          ),
          if (controller.renameError != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.renameError!,
              style: T.meta.copyWith(color: C.red, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 10),
          KeyValueRow(label: '地址', value: '$addresses$extra', mono: true),
          KeyValueRow(
            label: 'UUID',
            value: state?.uuid ?? '',
            mono: true,
            trailing:
                state == null || state.uuid.isEmpty
                    ? null
                    : IconSoftButton(
                      icon: Icons.copy_rounded,
                      size: 24,
                      iconSize: 12,
                      tooltip: '复制 UUID',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: state.uuid));
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            const SnackBar(
                              content: Text('UUID 已复制'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                      },
                    ),
          ),
          KeyValueRow(
            label: '运行',
            value: state == null ? '' : fmtUptime(state.uptimeSeconds),
          ),
          KeyValueRow(
            label: '订阅',
            value: state == null ? '' : '${state.subscribers} 个控制点',
          ),
        ],
      ),
    );
  }
}

class DiagPanel extends StatelessWidget {
  const DiagPanel({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final diag = controller.diag;
    final ready = controller.phase == EnginePhase.ready;
    final busy = controller.diagBusy;

    return Panel(
      title: '网络自检',
      trailing:
          diag == null
              ? null
              : Text(
                diag.checkedAt.isEmpty ? '' : '上次 ${diag.checkedAt}',
                style: T.mono.copyWith(fontSize: 10.5, color: C.textFaint),
              ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  diag == null ? '手机搜不到这台电视时，先跑一次自检。' : '组播通不通，决定手机能不能自动发现设备。',
                  style: T.bodyDim.copyWith(fontSize: 11.5, color: C.textFaint),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 32,
                child: SoftButton(
                  onPressed: ready && !busy ? controller.runDiag : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy)
                        const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      else
                        const Icon(
                          Icons.radar_rounded,
                          size: 14,
                          color: C.textDim,
                        ),
                      const SizedBox(width: 5),
                      Text(
                        busy ? '检测中' : (diag == null ? '开始自检' : '重新自检'),
                        style: T.button.copyWith(fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (diag != null) ...[
            const SizedBox(height: 12),
            DotLabel(
              label: '组播 239.255.255.250',
              color: diag.multicastOk ? C.green : C.red,
              value: diag.multicastOk ? '正常' : '发不出去',
            ),
            const SizedBox(height: 6),
            DotLabel(
              label: '子网广播',
              color:
                  diag.broadcastOk
                      ? C.green
                      : (diag.broadcastAddr.isEmpty ? C.textFaint : C.red),
              value:
                  diag.broadcastOk
                      ? '正常'
                      : (diag.broadcastAddr.isEmpty ? '无网卡' : '失败'),
            ),
            const SizedBox(height: 6),
            DotLabel(
              label: 'M-SEARCH 收到',
              color: C.blue,
              value: '${diag.msearchCount} 次',
            ),
            if (diag.hints.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                decoration: BoxDecoration(
                  color: C.amber.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: C.amber.withValues(alpha: 0.18)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final hint in diag.hints)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(
                                Icons.lightbulb_outline_rounded,
                                size: 12,
                                color: C.amber,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                hint,
                                style: T.meta.copyWith(
                                  fontSize: 11.5,
                                  color: C.textDim,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
          if (diag != null && !diag.multicastOk) ...[
            const SizedBox(height: 8),
            SoftButton(
              onPressed:
                  () => openExternalUrl(
                    'x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork',
                  ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                '打开「本地网络」设置',
                style: T.button.copyWith(fontSize: 11.5),
              ),
            ),
          ],
          if (controller.diagError != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.diagError!,
              style: T.meta.copyWith(color: C.red, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }
}
