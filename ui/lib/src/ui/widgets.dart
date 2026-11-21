import 'package:flutter/material.dart';

import '../theme.dart';

/// 侧栏/主区的统一卡片：深一档的底色 + 1px 边框，不用阴影。
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 12, 11),
            child: Row(
              children: [
                Text(title, style: T.section),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Container(height: 1, color: C.line),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 带 hover 的普通按钮。禁用时变淡、不响应。
class SoftButton extends StatefulWidget {
  const SoftButton({
    super.key,
    required this.child,
    this.onPressed,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.background,
    this.borderColor,
    this.radius = 9,
    this.tooltip,
    this.expand = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final Color? background;
  final Color? borderColor;
  final double radius;
  final String? tooltip;
  final bool expand;

  @override
  State<SoftButton> createState() => _SoftButtonState();
}

class _SoftButtonState extends State<SoftButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final base = widget.background ?? C.panelAlt;
    final background = !enabled
        ? base.withValues(alpha: 0.45)
        : _hover
            ? Color.lerp(base, Colors.white, 0.07) ?? base
            : base;

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: widget.borderColor ?? (enabled ? C.lineStrong : C.line),
        ),
      ),
      child: Opacity(opacity: enabled ? 1 : 0.5, child: widget.child),
    );

    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: content,
      ),
    );

    final wrapped = widget.expand
        ? SizedBox(height: 36, child: Center(child: button))
        : button;

    if (widget.tooltip == null || widget.tooltip!.isEmpty) return wrapped;
    return Tooltip(message: widget.tooltip!, child: wrapped);
  }
}

/// 方形图标按钮（播放控制、面板里的小动作）。
class IconSoftButton extends StatefulWidget {
  const IconSoftButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.size = 36,
    this.iconSize = 17,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool active;
  final Color? activeColor;

  @override
  State<IconSoftButton> createState() => _IconSoftButtonState();
}

class _IconSoftButtonState extends State<IconSoftButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final accent = widget.activeColor ?? C.amber;
    final Color iconColor;
    if (!enabled) {
      iconColor = C.textFaint.withValues(alpha: 0.5);
    } else if (widget.active) {
      iconColor = accent;
    } else {
      iconColor = _hover ? C.text : C.textDim;
    }

    final Color background;
    if (widget.active && enabled) {
      background = accent.withValues(alpha: 0.12);
    } else if (_hover && enabled) {
      background = const Color(0xFF1C2026);
    } else {
      background = Colors.transparent;
    }

    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(widget.size / 2.8),
          ),
          child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
        ),
      ),
    );

    if (widget.tooltip == null || widget.tooltip!.isEmpty) return button;
    return Tooltip(message: widget.tooltip!, child: button);
  }
}

/// 琥珀色的主按钮（投屏、重试、查看更新）。
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool dense;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final base = enabled
        ? (_hover ? const Color(0xFFF3BE70) : C.amber)
        : C.amber.withValues(alpha: 0.35);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: widget.dense ? 32 : 36,
          padding: EdgeInsets.symmetric(horizontal: widget.dense ? 12 : 16),
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 15, color: C.amberInk),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: T.button.copyWith(
                  color: C.amberInk,
                  fontWeight: FontWeight.w600,
                  fontSize: widget.dense ? 12 : 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.pulse = false,
  });

  final String label;
  final Color color;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: color, pulse: pulse),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulse});

  final Color color;
  final bool pulse;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.pulse && !reduce) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 0.6;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final glow = 0.35 + 0.65 * _controller.value;
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: widget.pulse ? 0.45 + 0.55 * _controller.value : 1),
            shape: BoxShape.circle,
            boxShadow: [
              if (widget.pulse)
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.45 * glow),
                  blurRadius: 4,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 圆角输入框：聚焦时边框变琥珀，和按钮的 hover 一样克制。
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.onSubmitted,
    this.onChanged,
    this.suffix,
    this.textInputAction,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Widget? suffix;
  final TextInputAction? textInputAction;
  final bool enabled;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.only(left: 11, right: 4),
      decoration: BoxDecoration(
        color: C.panelAlt,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: focused ? C.amber.withValues(alpha: 0.55) : C.line,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              style: T.body.copyWith(fontSize: 12.5),
              cursorColor: C.amber,
              cursorWidth: 1.4,
              textInputAction: widget.textInputAction,
              onSubmitted: widget.onSubmitted,
              onChanged: widget.onChanged,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: T.bodyDim.copyWith(color: C.textFaint),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          if (widget.suffix != null) widget.suffix!,
        ],
      ),
    );
  }
}

/// 面板里「标签 → 值」的一行。
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
    this.trailing,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(label, style: T.meta.copyWith(fontSize: 11.5)),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: (mono ? T.mono : T.bodyDim.copyWith(fontSize: 12.5)).copyWith(
                color: valueColor ?? (mono ? C.textDim : C.text),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 小圆点 + 文本，自检结果和「最近」列表里用。
class DotLabel extends StatelessWidget {
  const DotLabel({
    super.key,
    required this.label,
    required this.color,
    this.value,
  });

  final String label;
  final Color color;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Text(label, style: T.bodyDim.copyWith(fontSize: 12)),
        if (value != null) ...[
          const Spacer(),
          Text(
            value!,
            style: T.mono.copyWith(fontSize: 11, color: color),
          ),
        ],
      ],
    );
  }
}
