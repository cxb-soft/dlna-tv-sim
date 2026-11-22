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
  private var engineMenu: EngineMenuController?

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
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.installEngineMenu()
    }
  }

  func installEngineMenu(retries: Int = 10) {
    logEngineMenu("installEngineMenu retries=\(retries) vc=\(contentViewController != nil)")
    if let engineMenu {
      engineMenu.install()
      return
    }
    guard let flutterViewController = contentViewController as? FlutterViewController else {
      if retries > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.installEngineMenu(retries: retries - 1)
        }
      }
      return
    }
    let menu = EngineMenuController(messenger: flutterViewController.engine.binaryMessenger)
    engineMenu = menu
    menu.install()
  }
}

private func logEngineMenu(_ message: String) {
  let line = "\(Date()) \(message)\n"
  guard let data = line.data(using: .utf8) else { return }
  let url = URL(fileURLWithPath: "/tmp/dlna-engine-menu.log")
  if FileManager.default.fileExists(atPath: url.path),
     let handle = try? FileHandle(forWritingTo: url) {
    handle.seekToEndOfFile()
    handle.write(data)
    try? handle.close()
  } else {
    try? data.write(to: url)
  }
}

/// 原生「播放引擎」菜单：Flutter 在 macOS 的 AX 桥目前读不到内容，
/// 菜单栏是 AppKit 原生可访问控件，VoiceOver / AX 可直接读取和按下。
final class EngineMenuController: NSObject {
  private let channel: FlutterMethodChannel
  private var playerItems: [String: NSMenuItem] = [:]
  private var restartItem: NSMenuItem?
  private var preferred = "auto"
  private var adopted = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.cxbsoft.dlna-tv-sim/engine_menu",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      if call.method == "engineState", let args = call.arguments as? [String: Any] {
        self.preferred = args["preferred"] as? String ?? "auto"
        self.adopted = args["adopted"] as? Bool ?? false
        self.applyState()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func install(attempt: Int = 0) {
    guard let mainMenu = NSApp.mainMenu else {
      logEngineMenu("menu install mainMenu nil attempt=\(attempt)")
      if attempt < 10 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.install(attempt: attempt + 1)
        }
      }
      return
    }
    logEngineMenu("menu install mainMenu items=\(mainMenu.items.count) attempt=\(attempt)")
    if mainMenu.items.contains(where: { $0.title == "播放引擎" }) {
      logEngineMenu("menu install already present")
      return
    }

    let top = NSMenuItem(title: "播放引擎", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "播放引擎")
    let options: [(String, String)] = [
      ("auto", "自动（优先 mpv）"),
      ("mpv", "mpv"),
      ("native", "自研 native"),
      ("web", "网页播放"),
    ]
    for (player, title) in options {
      let item = NSMenuItem(
        title: title,
        action: #selector(selectEngine(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = player
      submenu.addItem(item)
      playerItems[player] = item
    }
    submenu.addItem(.separator())
    let restart = NSMenuItem(
      title: "重启引擎",
      action: #selector(restartEngine),
      keyEquivalent: ""
    )
    restart.target = self
    submenu.addItem(restart)
    restartItem = restart

    top.submenu = submenu
    mainMenu.addItem(top)
    logEngineMenu("menu install added items=\(mainMenu.items.count)")
    applyState()
  }

  @objc private func selectEngine(_ sender: NSMenuItem) {
    guard !adopted, let player = sender.representedObject as? String else { return }
    preferred = player
    applyState()
    channel.invokeMethod("switchEngine", arguments: player)
  }

  @objc private func restartEngine() {
    guard !adopted else { return }
    channel.invokeMethod("restartEngine", arguments: nil)
  }

  private func applyState() {
    for (player, item) in playerItems {
      item.state = player == preferred ? .on : .off
      item.isEnabled = !adopted
    }
    restartItem?.isEnabled = !adopted
  }
}
