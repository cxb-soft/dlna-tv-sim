// Windows 更新脚本的静态校验。
//
// 本机没有 PowerShell，没法真的执行这段脚本，所以这里做能在 mac 上做的检查：
//   - 脚本里 param() 声明的参数，和 Dart 侧 Process.start 传的 -X 参数一一对应；
//   - 没有用 PowerShell 的只读/自动变量当参数名（$PID 是只读自动变量，
//     param([int]$Pid) 会让参数绑定直接失败）；
//   - 大括号/圆括号/方括号和引号成对；
//   - 进程清理按 target 路径匹配（不是见名就杀），复制有重试。
//
// 这是替代品，不是等价物：真正的 PowerShell 语法解析只能在 Windows 上做。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PowerShell 里不能当参数名的自动/只读变量（大小写不敏感）。
const _reservedVars = {
  'pid',
  'host',
  'args',
  'input',
  'error',
  'true',
  'false',
  'null',
  'this',
  'matches',
  'lastexitcode',
  'psscriptroot',
  'pscommandpath',
  'psscriptname',
  'myinvocation',
  'executioncontext',
  'psitem',
  'stacktrace',
  'shellid',
  'executionpolicy',
  'home',
  'pwd',
  '?',
  '_',
};

String _readSource() =>
    File('lib/src/services/update_service.dart').readAsStringSync();

/// 取出 _installWindows 里的 PowerShell 脚本正文。
String _extractWindowsScript(String source) {
  final fnStart = source.indexOf('Future<InstallOutcome> _installWindows');
  if (fnStart < 0) throw StateError('找不到 _installWindows');

  final paramStart = source.indexOf('param([int]', fnStart);
  if (paramStart < 0) throw StateError('找不到 param() 声明');

  final end = source.indexOf("''');", paramStart);
  if (end < 0) throw StateError('找不到脚本结束标记');
  return source.substring(paramStart, end);
}

/// _installWindows 里传给 powershell 的参数名（-Xxx）。
Set<String> _extractPassedArgs(String source) {
  final fnStart = source.indexOf('Future<InstallOutcome> _installWindows');
  final callStart = source.indexOf("Process.start('powershell'", fnStart);
  if (callStart < 0) throw StateError('找不到 Process.start 调用');
  final callEnd = source.indexOf('mode: ProcessStartMode.detached', callStart);
  if (callEnd < 0) throw StateError('找不到 ProcessStartMode.detached');

  final call = source.substring(callStart, callEnd);
  // 只看传给脚本的参数：`-File <空本>` 之前的是 powershell 自己的开关。
  final scriptArgAt = call.indexOf('script.path');
  if (scriptArgAt < 0) throw StateError('找不到 script.path 实参');
  final afterScript = call.substring(scriptArgAt);
  return RegExp(
    r"'-(?<name>[A-Za-z][A-Za-z0-9_]*)'",
  ).allMatches(afterScript).map((m) => m.namedGroup('name')!).toSet();
}

/// param(...) 里声明的参数名。
Set<String> _extractDeclaredParams(String script) {
  final paramLine = script.split('\n').first;
  return RegExp(
    r'\$(?<name>[A-Za-z_][A-Za-z0-9_]*)',
  ).allMatches(paramLine).map((m) => m.namedGroup('name')!).toSet();
}

void main() {
  late String source;
  late String script;

  setUpAll(() {
    source = _readSource();
    script = _extractWindowsScript(source);
  });

  test('param 声明的参数与传入的 -X 参数一致', () {
    final declared = _extractDeclaredParams(script);
    final passed = _extractPassedArgs(source);

    expect(declared, isNotEmpty);
    expect(
      declared.map((e) => e.toLowerCase()).toSet(),
      passed.map((e) => e.toLowerCase()).toSet(),
      reason: '声明的 $declared 与传入的 $passed 对不上',
    );
  });

  test('不用 PowerShell 只读自动变量当参数名', () {
    final declared = _extractDeclaredParams(script);
    final bad =
        declared
            .where((name) => _reservedVars.contains(name.toLowerCase()))
            .toList();
    expect(bad, isEmpty, reason: '这些参数名是 PowerShell 自动变量：$bad');
  });

  test('括号与引号成对', () {
    int count(RegExp re) => re.allMatches(script).length;
    expect(count(_re('{')), count(_re('}')), reason: '大括号不成对');
    expect(count(_re(r'\(')), count(_re(r'\)')), reason: '圆括号不成对');
    expect(count(_re('[')), count(_re(']')), reason: '方括号不成对');
    expect(count(_re("'")) % 2, 0, reason: '单引号不成对');
    // 这里只数未转义的双引号；脚本里的 \" 都在 Dart 字符串里已被处理。
    expect(count(_re('"')) % 2, 0, reason: '双引号不成对');
  });

  test('进程清理按 target 路径匹配，不是见名就杀', () {
    expect(
      script,
      isNot(contains(r"Get-Process -Name 'dlna-tv-sim'")),
      reason: '整机按名字杀进程会误伤其他安装目录的实例',
    );
    for (final exe in ['dlna_tv_sim.exe', 'dlna-tv-sim.exe', 'mpv.exe']) {
      expect(script, contains(exe), reason: '没有处理 $exe');
    }
    expect(
      RegExp(
        r'\.ExecutablePath\.StartsWith\(\$Target',
      ).allMatches(script).length,
      3,
      reason: r'三个进程过滤器都应该按 $Target 前缀匹配',
    );
  });

  test('复制有重试，失败会退出并记日志', () {
    expect(script, contains(r'for ($i = 0; $i -lt 20; $i++)'));
    expect(script, contains('Start-Sleep -Milliseconds 500'));
    expect(script, contains(r'if (-not $copied)'));
    expect(script, contains('Start-Transcript'));
  });

  test('等待 App 退出后才动手', () {
    expect(script, contains(r'Wait-Process -Id $TargetPid'));
  });
}

RegExp _re(String s) => RegExp(RegExp.escape(s));
