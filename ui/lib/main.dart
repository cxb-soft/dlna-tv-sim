import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'src/app.dart';
import 'src/controller/app_controller.dart';

const MethodChannel _engineMenuChannel = MethodChannel(
  'com.cxbsoft.dlna-tv-sim/engine_menu',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 保持语义树开启：macOS 辅助功能和 AX 客户端才能读到 Flutter 控件。
  // 注意：Flutter 3.29 的 macOS embedder 还有已知 AX 桥问题（#189683），
  // 所以引擎切换另配了原生菜单栏入口。
  SemanticsBinding.instance.ensureSemantics();
  final controller = AppController();

  _engineMenuChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'switchEngine':
        final player = call.arguments;
        if (player is String && player.isNotEmpty) {
          await controller.switchEngine(player);
        }
        break;
      case 'restartEngine':
        await controller.restartEngine();
        break;
    }
    return null;
  });

  String? lastMenuState;
  void sendMenuState() {
    final state = controller.state;
    final signature =
        '${state?.player ?? ''}|${controller.preferredEngine}|${controller.adoptedEngine}';
    if (signature == lastMenuState) return;
    lastMenuState = signature;
    _engineMenuChannel
        .invokeMethod<void>('engineState', {
          'player': state?.player ?? '',
          'preferred': controller.preferredEngine,
          'adopted': controller.adoptedEngine,
        })
        .catchError((Object _) {});
  }

  controller.addListener(sendMenuState);

  runApp(DlnaTvApp(controller: controller));
  // 首帧先铺满界面，再去找引擎，避免白屏。
  controller.bootstrap();
  sendMenuState();
}
