import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Links and files other programs opened with Kumo (a `vless://` link in a browser or a chat, a
  /// file dropped on the icon), kept until the Dart side asks for them. Nothing is added without the
  /// user's answer to the question the app shows first.
  private var pending: [String] = []
  private var channel: FlutterMethodChannel?
  private let maxItems = 20
  private let maxBytes = 1_000_000

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let external = FlutterMethodChannel(
        name: "kumo/external", binaryMessenger: controller.engine.binaryMessenger)
      external.setMethodCallHandler { [weak self] call, result in
        if call.method == "take" {
          let items = self?.pending ?? []
          self?.pending = []
          result(items)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      channel = external
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// A link of a server or subscription.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.isFileURL == false {
      add(url.absoluteString)
    }
    for url in urls where url.isFileURL {
      addFile(url.path)
    }
    announce()
  }

  /// A file dropped on the icon or opened with Kumo.
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    for path in filenames {
      addFile(path)
    }
    announce()
    sender.reply(toOpenOrPrint: .success)
  }

  private func add(_ text: String) {
    if pending.count < maxItems && !text.isEmpty { pending.append(text) }
  }

  private func addFile(_ path: String) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? Int, size <= maxBytes,
      let data = FileManager.default.contents(atPath: path)
    else { return }
    add(String(decoding: data, as: UTF8.self))
  }

  /// Tells the Dart side that something is waiting (it also looks every two seconds).
  private func announce() {
    channel?.invokeMethod("external", arguments: nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
