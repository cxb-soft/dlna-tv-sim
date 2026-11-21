import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'controller/app_controller.dart';
import 'theme.dart';
import 'ui/event_log.dart';
import 'ui/now_playing.dart';
import 'ui/side_panels.dart';
import 'ui/top_bar.dart';
import 'ui/update_banner.dart';

class DlnaTvApp extends StatefulWidget {
  const DlnaTvApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<DlnaTvApp> createState() => _DlnaTvAppState();
}

class _DlnaTvAppState extends State<DlnaTvApp> {
  /// 关窗/退出时先把自己拉起的引擎收掉，再让 App 退出。
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await widget.controller.shutdown();
      return AppExitResponse.exit;
    },
  );

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DLNA 电视',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: AppShell(controller: widget.controller),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TopBar(controller: controller),
              UpdateBanner(controller: controller),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: NowPlayingSection(controller: controller)),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 336,
                        child: SidePanels(controller: controller),
                      ),
                    ],
                  ),
                ),
              ),
              EventLogPanel(controller: controller),
            ],
          );
        },
      ),
    );
  }
}
