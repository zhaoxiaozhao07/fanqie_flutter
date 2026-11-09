import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var quitPending = false

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard !ReaderNativeTestHost.isRunning else { return }
    ReaderExternalFileInbox.shared.enqueue(urls)
    mainReaderWindow?.showReaderWindow()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    mainReaderWindow?.showReaderWindow()
    return true
  }

  private var mainReaderWindow: MainFlutterWindow? {
    NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if ReaderNativeTestHost.isRunning { return .terminateNow }
    guard !quitPending, let bridge = mainReaderWindow?.readerPlatform else {
      return .terminateCancel
    }
    quitPending = true
    bridge.channel.invokeMethod("onAppQuitRequested", arguments: nil) { [weak self] value in
      guard let self = self, self.quitPending else { return }
      self.finishQuit(value as? Bool == true)
    }
    // Never strand the native termination handshake if Dart is busy/unavailable.
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      guard let self = self, self.quitPending else { return }
      self.finishQuit(false)
    }
    return .terminateLater
  }

  private func finishQuit(_ allowed: Bool) {
    quitPending = false
    NSApp.reply(toApplicationShouldTerminate: allowed)
    if !allowed {
      mainReaderWindow?.showReaderWindow()
      let alert = NSAlert()
      alert.messageText = "暂时无法退出"
      alert.informativeText = "请等待导入、恢复或阅读数据保存完成后重试。原数据与恢复日志不会被清除。"
      alert.addButton(withTitle: "继续使用")
      alert.runModal()
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
