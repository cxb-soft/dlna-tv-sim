import Cocoa
import FlutterMacOS
import Network

@main
class AppDelegate: FlutterAppDelegate {
  private var localNetworkProbe: NWBrowser?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 整个 App（含标题栏、菜单、弹窗）统一走深色外观，避免和 Flutter 页面拼色。
    NSApp.appearance = NSAppearance(named: .darkAqua)
    startLocalNetworkProbe()
    super.applicationDidFinishLaunching(notification)
    if let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }) as? MainFlutterWindow {
      DispatchQueue.main.async { window.installEngineMenu() }
    }
  }

  /// 触发 macOS 的「本地网络」授权。
  /// 直接发原始组播包不会弹窗（表现为 no route to host），必须走
  /// Network.framework 的 Bonjour 浏览，系统才会把这个 App 登记进本地网络列表。
  /// 引擎是 App 的子进程，授权后它的 SSDP 组播才能发出去。
  private func startLocalNetworkProbe() {
    let params = NWParameters()
    params.includePeerToPeer = false
    let browser = NWBrowser(for: .bonjour(type: "_ssdp._udp", domain: nil), using: params)
    browser.stateUpdateHandler = { state in
      if case .failed = state { browser.cancel() }
    }
    browser.start(queue: .main)
    localNetworkProbe = browser
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      self?.localNetworkProbe?.cancel()
      self?.localNetworkProbe = nil
    }
  }

  /// 兜底：即使 Dart 侧来不及跑完 shutdown，也要把本 App 拉起的引擎收掉。
  override func applicationWillTerminate(_ notification: Notification) {
    EngineProcessRegistry.shared.terminateIfNeeded()
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
