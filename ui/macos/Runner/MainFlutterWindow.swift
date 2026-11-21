import Cocoa
import Darwin
import FlutterMacOS

/// 记录本 App 拉起的引擎 PID，退出时由 AppKit 直接收掉。
/// 放在这个文件里，避免新增 Swift 源文件还要改 pbxproj。
final class EngineProcessRegistry {
  static let shared = EngineProcessRegistry()

  private var pid: pid_t = 0

  func update(pid newPid: pid_t) {
    pid = newPid
  }

  func terminateIfNeeded() {
    guard pid > 1 else { return }
    kill(pid, SIGTERM)
    pid = 0
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 桌面端控制台：给内容留出足够空间，同时不允许缩到布局撑不开的尺寸。
    self.minSize = NSSize(width: 1040, height: 720)
    self.title = "DLNA 电视"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.backgroundColor = NSColor(calibratedRed: 0.043, green: 0.047, blue: 0.055, alpha: 1)
    self.isMovableByWindowBackground = false

    if windowFrame.width < 1180 || windowFrame.height < 800 {
      var frame = self.frame
      frame.size = NSSize(width: 1180, height: 800)
      self.setFrame(frame, display: true)
    }
    self.center()

    // Dart 拉起引擎后把 PID 传过来，退出时兜底 SIGTERM。
    let engineChannel = FlutterMethodChannel(
      name: "com.cxbsoft.dlna-tv-sim/engine",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    engineChannel.setMethodCallHandler { call, result in
      if call.method == "setEnginePid", let pid = call.arguments as? Int {
        EngineProcessRegistry.shared.update(pid: pid_t(pid))
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
