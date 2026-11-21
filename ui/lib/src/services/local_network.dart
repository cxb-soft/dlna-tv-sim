import 'dart:io';

/// 触发一次本地网络访问，让 macOS 弹出「本地网络」授权。
///
/// 引擎是以 App 的子进程方式启动的，macOS 的本地网络权限按「发起访问的进程」
/// 判定；如果 App 自己从没访问过局域网，子进程的组播会被静默拒绝（表现为
/// sendto: no route to host，连弹窗都没有）。所以 App 启动时先自己发一个
/// 组播包，把授权对话框拉出来，用户点允许之后引擎的 SSDP 才能发出去。
///
/// 返回 true 表示这次发送没有抛错；但权限是否已授予，最终要看引擎的
/// /api/diag（multicast_ok）。
Future<bool> warmUpLocalNetwork() async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.send(const [0x00], InternetAddress('239.255.255.250'), 1900);
    return true;
  } catch (_) {
    // 权限被拒时不同系统版本的表现不一致，这里只负责把请求发出去。
    return false;
  } finally {
    socket?.close();
  }
}
