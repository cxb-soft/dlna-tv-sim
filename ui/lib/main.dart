import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/controller/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(DlnaTvApp(controller: controller));
  // 首帧先铺满界面，再去找引擎，避免白屏。
  controller.bootstrap();
}
