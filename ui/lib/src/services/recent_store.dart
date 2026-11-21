import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

/// 最近投屏地址：内存里保存一份，落盘到应用数据目录，重启后还能点。
class RecentCastStore {
  static const int _limit = 6;

  final List<String> _items = [];
  bool _loaded = false;

  List<String> get items => List.unmodifiable(_items);

  File get _file => File('${AppPaths.supportDir().path}/recent-casts.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = _file;
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _items
          ..clear()
          ..addAll(decoded.whereType<String>().take(_limit));
      }
    } catch (_) {
      // 文件坏了就当空的，不影响启动。
    }
  }

  Future<List<String>> add(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return items;
    _items
      ..remove(trimmed)
      ..insert(0, trimmed);
    if (_items.length > _limit) {
      _items.removeRange(_limit, _items.length);
    }
    await _save();
    return items;
  }

  Future<List<String>> remove(String url) async {
    _items.remove(url);
    await _save();
    return items;
  }

  Future<void> _save() async {
    try {
      await AppPaths.supportDir().create(recursive: true);
      await _file.writeAsString(jsonEncode(_items), flush: true);
    } catch (_) {
      // 写不进去不影响使用，下次启动只是没有历史。
    }
  }
}
