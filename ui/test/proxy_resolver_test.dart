import 'dart:io';

import 'package:dlna_tv_sim/src/services/proxy_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('macOS scutil 解析', () {
    test('优先 HTTPS 代理', () {
      const text = '''
<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7891
  HTTPSProxy : 10.0.0.2
  SOCKSEnable : 0
}''';
      expect(ProxyResolver.parseMacOSProxy(text), 'PROXY 10.0.0.2:7891');
    });

    test('HTTPS 关闭时回退 HTTP', () {
      const text = '''
<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 0
}''';
      expect(ProxyResolver.parseMacOSProxy(text), 'PROXY 127.0.0.1:7890');
    });

    test('全部关闭时返回 null', () {
      const text = '''
<dictionary> {
  HTTPEnable : 0
  HTTPSEnable : 0
}''';
      expect(ProxyResolver.parseMacOSProxy(text), isNull);
    });
  });

  group('Windows 注册表解析', () {
    test('裸 host:port', () {
      const text = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:7890
''';
      expect(ProxyResolver.parseWindowsProxy(text), 'PROXY 127.0.0.1:7890');
    });

    test('分协议写法优先 https', () {
      const text = '''
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http=127.0.0.1:7890;https=127.0.0.1:7891
''';
      expect(ProxyResolver.parseWindowsProxy(text), 'PROXY 127.0.0.1:7891');
    });

    test('未启用时不走代理', () {
      const text = '''
    ProxyEnable    REG_DWORD    0x0
    ProxyServer    REG_SZ    127.0.0.1:7890
''';
      expect(ProxyResolver.parseWindowsProxy(text), isNull);
    });
  });

  group('代理 URL', () {
    test('带协议与不带协议都能解析', () {
      expect(
        ProxyResolver.parseProxyUrl('127.0.0.1:7890'),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        ProxyResolver.parseProxyUrl('http://127.0.0.1:7890'),
        'PROXY 127.0.0.1:7890',
      );
    });
  });

  group('本地地址', () {
    test('回环与 .local 直连', () {
      const proxy = 'PROXY 127.0.0.1:7890';
      expect(
        ProxyResolver.forUri(Uri.parse('http://127.0.0.1:8090'), proxy),
        'DIRECT',
      );
      expect(
        ProxyResolver.forUri(Uri.parse('http://localhost:8090'), proxy),
        'DIRECT',
      );
      expect(
        ProxyResolver.forUri(Uri.parse('https://api.github.com'), proxy),
        proxy,
      );
    });
  });

  test('本机系统代理（有配置时应该读到）', () async {
    if (!Platform.isMacOS) return;
    final result = await ProxyResolver.resolve();
    // 没设置代理的机器会返回 DIRECT，这里只断言返回值是 findProxy 认识的形式。
    expect(result == 'DIRECT' || result.startsWith('PROXY '), isTrue);
  });
}
