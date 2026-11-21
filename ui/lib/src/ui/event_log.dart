import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../models/engine_state.dart';
import '../theme.dart';

/// 底部可折叠事件流：默认展开，能一眼看到手机投屏、SSDP 搜索和播放动作。
class EventLogPanel extends StatefulWidget {
  const EventLogPanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<EventLogPanel> createState() => _EventLogPanelState();
}

class _EventLogPanelState extends State<EventLogPanel> {
  static const double _bodyHeight = 208;

  bool _expanded = false;
  bool _hover = false;
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void didUpdateWidget(covariant EventLogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.controller.logs.length;
    if (count != _lastCount) {
      _lastCount = count;
      _scrollToBottom();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) _scrollToBottom();
  }

  void _scrollToBottom() {
    if (!_expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      if (position.maxScrollExtent == 0) return;
      if (position.pixels >= position.maxScrollExtent - 160) {
        _scroll.animateTo(
          position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final logs = controller.logs;
    final latest = logs.isEmpty ? '' : logs.last.at;

    return Container(
      decoration: const BoxDecoration(
        color: C.bg,
        border: Border(top: BorderSide(color: C.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                color: _hover ? const Color(0xFF101215) : Colors.transparent,
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: C.textFaint,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('事件流', style: T.section.copyWith(color: C.textDim)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: C.panelAlt,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: C.line),
                      ),
                      child: Text(
                        '${logs.length}',
                        style: T.mono.copyWith(fontSize: 10, color: C.textFaint),
                      ),
                    ),
                    const Spacer(),
                    if (controller.phase == EnginePhase.failed)
                      Text(
                        '引擎未连接，没有新事件',
                        style: T.meta.copyWith(fontSize: 10.5, color: C.red),
                      )
                    else if (latest.isNotEmpty)
                      Text(
                        '最新 $latest',
                        style: T.mono.copyWith(fontSize: 10.5, color: C.textFaint),
                      ),
                    const SizedBox(width: 12),
                    Text(
                      _expanded ? '收起' : '展开',
                      style: T.meta.copyWith(fontSize: 10.5, color: C.textFaint),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? SizedBox(
                      height: _bodyHeight,
                      child: logs.isEmpty ? _empty() : _list(logs),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Text(
        '还没有事件。手机投屏、SSDP 搜索和播放动作都会出现在这里。',
        style: T.bodyDim.copyWith(fontSize: 11.5, color: C.textFaint),
      ),
    );
  }

  Widget _list(List<LogEntry> logs) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 2, 16, 10),
      itemCount: logs.length,
      itemBuilder: (context, index) {
        final entry = logs[index];
        final color = _kindColor(entry.kind);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 62,
                child: Text(
                  entry.at,
                  style: T.mono.copyWith(fontSize: 10, color: C.textFaint),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 54,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      entry.kind.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 9,
                        height: 1.35,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.text,
                  style: T.bodyDim.copyWith(
                    fontSize: 12,
                    height: 1.4,
                    color: entry.kind == 'error' ? C.red : C.textDim,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _kindColor(String kind) {
    switch (kind) {
      case 'http':
        return C.blue;
      case 'soap':
        return C.violet;
      case 'ssdp':
        return C.green;
      case 'play':
      case 'player':
      case 'mpv':
      case 'screen':
        return C.amber;
      case 'config':
        return C.blue;
      case 'error':
        return C.red;
      default:
        return C.textFaint;
    }
  }
}
