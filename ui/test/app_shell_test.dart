import 'package:dlna_tv_sim/src/app.dart';
import 'package:dlna_tv_sim/src/controller/app_controller.dart';
import 'package:dlna_tv_sim/src/models/engine_state.dart';
import 'package:dlna_tv_sim/src/models/update_info.dart';
import 'package:dlna_tv_sim/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;

/// 不发网络请求的控制器：只记录 UI 发出的指令，验证按钮接线和布局。
class _FakeController extends AppController {
  _FakeController({
    required this.fakeState,
    this.fakePhase = EnginePhase.ready,
    this.fakeUpdate,
    this.fakeError,
    this.fakeDetail,
  }) : super(port: 8099, version: '0.3.0');

  final EngineState? fakeState;
  final EnginePhase fakePhase;
  final UpdateInfo? fakeUpdate;
  final String? fakeError;
  final String? fakeDetail;

  final List<String> calls = [];

  @override
  EnginePhase get phase => fakePhase;

  @override
  EngineState? get state => fakeState;

  @override
  List<LogEntry> get logs => const [];

  @override
  List<String> get recents => const [];

  @override
  bool get commandBusy => false;

  @override
  String? get commandError => null;

  @override
  bool get castBusy => false;

  @override
  String? get castError => null;

  @override
  String? get renameError => null;

  @override
  bool get diagBusy => false;

  @override
  DiagResult? get diag => null;

  @override
  String? get diagError => null;

  @override
  UpdateInfo? get update => fakeUpdate;

  @override
  bool get hasUpdate => fakeUpdate != null;

  @override
  bool get updateChecking => false;

  @override
  bool get updateDismissed => false;

  @override
  String? get fatalError => fakeError;

  @override
  String? get fatalDetail => fakeDetail;

  @override
  Future<void> control(String action, [num? value]) async {
    calls.add('control:$action:${value ?? ''}');
  }

  @override
  Future<void> playerAction(
    String action, {
    num? value,
    String? text,
    String? kind,
    int? id,
  }) async {
    calls.add('player:$action:${value ?? ''}');
  }

  @override
  Future<bool> cast(String rawUrl) async {
    calls.add('cast:$rawUrl');
    return true;
  }

  @override
  Future<void> runDiag() async {
    calls.add('diag');
  }
}

EngineState _playingState() => EngineState.fromJson(const {
  'friendly_name': '客厅电视',
  'state': 'PLAYING',
  'status': 'OK',
  'uri': 'http://192.168.1.23:8000/video/Interstellar.2014.mkv',
  'title': '星际穿越 · Interstellar (2014) 2160p HDR',
  'duration': 10140.0,
  'position': 754.0,
  'volume': 46,
  'player': 'mpv',
  'version': '0.3.0',
  'speed': 1.0,
  'loop': false,
  'addresses': ['192.168.1.23'],
  'port': 8099,
  'uptime': 120,
  'capabilities': ['speed', 'loop', 'aspect', 'tracks', 'stats'],
  'stats': {'bitrate_kbps': 8421.5, 'fps': 23.976},
  'meta': '<dc:creator>小蔡的 iPhone</dc:creator>',
  'probe': {'status': 'streaming', 'content_type': 'video/x-matroska'},
});

Future<void> _pumpApp(
  WidgetTester tester,
  _FakeController controller,
  Size size,
) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(DlnaTvApp(controller: controller));
  await tester.pump();
}

void main() {
  testWidgets('播放控制按钮把指令发给引擎', (tester) async {
    final controller = _FakeController(fakeState: _playingState());
    await _pumpApp(tester, controller, const Size(1180, 800));

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(controller.calls, contains('control:pause:'));

    await tester.tap(find.byTooltip('后退 10 秒'));
    await tester.pump();
    expect(controller.calls, contains('player:seekrel:-10'));

    await tester.tap(find.byTooltip('循环播放'));
    await tester.pump();
    expect(controller.calls, contains('player:loop:1'));

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(controller.calls, contains('control:mute:1'));
  });

  testWidgets('投屏输入框和按钮接到 /api/cast', (tester) async {
    final controller = _FakeController(fakeState: _playingState());
    await _pumpApp(tester, controller, const Size(1180, 800));

    await tester.enterText(
      find.byType(TextField).first,
      'http://example.com/a.m3u8',
    );
    await tester.tap(find.widgetWithText(PrimaryButton, '投屏'));
    await tester.pump();

    expect(controller.calls, contains('cast:http://example.com/a.m3u8'));
  });

  testWidgets('最小窗口 1040×720 下播放态布局不溢出', (tester) async {
    final controller = _FakeController(fakeState: _playingState());
    await _pumpApp(tester, controller, const Size(1040, 720));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('星际穿越 · Interstellar (2014) 2160p HDR'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有新版本时显示更新横幅', (tester) async {
    final controller = _FakeController(
      fakeState: _playingState(),
      fakeUpdate: const UpdateInfo(
        version: '0.3.9',
        tagName: 'v0.3.9',
        notes: '## 更新内容\n- 支持 HDR 亮度映射\n- 修复投屏后进度条不同步',
        releaseUrl:
            'https://github.com/cxb-soft/dlna-tv-sim/releases/tag/v0.3.9',
      ),
    );
    await _pumpApp(tester, controller, const Size(1180, 800));

    expect(find.textContaining('有新版本'), findsOneWidget);
    expect(find.textContaining('v0.3.9'), findsWidgets);
    expect(find.textContaining('HDR 亮度映射'), findsOneWidget);
    expect(find.text('查看更新'), findsOneWidget);
    expect(find.widgetWithText(PrimaryButton, '立即更新'), findsOneWidget);
  });

  testWidgets('引擎启动失败时给出错误卡片而不是白屏', (tester) async {
    final controller = _FakeController(
      fakeState: null,
      fakePhase: EnginePhase.failed,
      fakeError: '找不到引擎可执行文件',
      fakeDetail:
          '找过这些位置：\n/Applications/DLNA 电视.app/Contents/Resources/engine/dlna-tv-sim',
    );
    await _pumpApp(tester, controller, const Size(1180, 800));

    expect(find.text('引擎没起来'), findsOneWidget);
    expect(find.text('找不到引擎可执行文件'), findsOneWidget);
    expect(find.widgetWithText(PrimaryButton, '重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动中显示端口和进度，不白屏', (tester) async {
    final controller = _FakeController(
      fakeState: null,
      fakePhase: EnginePhase.booting,
    );
    await _pumpApp(tester, controller, const Size(1180, 800));

    expect(find.text('正在启动引擎'), findsOneWidget);
    expect(find.textContaining('端口 8099'), findsOneWidget);
  });
}
