import 'package:dlna_tv_sim/src/models/engine_state.dart';
import 'package:dlna_tv_sim/src/services/update_service.dart';
import 'package:dlna_tv_sim/src/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('版本比较只认数字，新版本才提示', () {
    expect(UpdateService.isNewer('0.3.1', '0.3.0'), isTrue);
    expect(UpdateService.isNewer('v0.4.0', '0.3.9'), isTrue);
    expect(UpdateService.isNewer('0.10.0', '0.9.9'), isTrue);
    expect(UpdateService.isNewer('0.3.0', '0.3.0'), isFalse);
    expect(UpdateService.isNewer('0.3.0-beta', '0.3.0'), isFalse);
    expect(UpdateService.isNewer('0.2.9', '0.3.0'), isFalse);
  });

  test('时长与运行时间格式化', () {
    expect(fmtClock(0), '00:00');
    expect(fmtClock(65), '01:05');
    expect(fmtClock(3661), '1:01:01');
    expect(fmtUptime(45), '45 秒');
    expect(fmtUptime(90), '1 分钟');
    expect(fmtUptime(3600), '1 小时');
  });

  test('引擎状态解析对缺字段容错', () {
    final state = EngineState.fromJson(const {
      'friendly_name': '客厅电视',
      'state': 'PLAYING',
      'duration': 120.5,
      'position': 3.2,
      'addresses': ['192.168.1.5'],
      'meta': '<dc:creator>小明的手机</dc:creator>',
      'stats': {'bitrate_kbps': 2100, 'fps': 24},
    });
    expect(state.friendlyName, '客厅电视');
    expect(state.playing, isTrue);
    expect(state.hasMedia, isFalse);
    expect(state.stateLabel, '正在播放');
    expect(state.sourceLabel, '小明的手机');
    expect(state.stats.fps, 24);
    expect(state.speed, 1, reason: '缺 speed 时按 1 倍速兜底');
  });

  test('URL 标签取路径最后一段', () {
    expect(
      urlLabel('http://192.168.1.2:8080/video/movie.mp4?token=1'),
      'movie.mp4',
    );
    expect(urlHost('https://example.com/a.m3u8'), 'example.com');
  });
}
