import Cocoa
import Darwin
import FlutterMacOS
import IOKit.pwr_mgt
import IOKit.ps
import Network
import UniformTypeIdentifiers

enum ReaderNativeTestHost {
  static var isRunning: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || NSClassFromString("XCTestCase") != nil
    #else
    return false
    #endif
  }
}

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private(set) var readerPlatform: ReaderNativePlatform?
  private(set) var fullScreenTransitioning = false

  override func awakeFromNib() {
    // XCTest exercises the native helpers with its own temporary files.
    // Do not boot Dart's production main or touch everyday reader preferences.
    // Flutter/plugin startup is covered separately by the platform and AOT tests.
    if ReaderNativeTestHost.isRunning {
      super.awakeFromNib()
      return
    }
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    title = "番茄Reader"
    collectionBehavior.insert(.fullScreenPrimary)
    contentMinSize = NSSize(width: 720, height: 540)
    setContentSize(NSSize(width: 1024, height: 768))
    center()
    let isClient = Bundle.main.object(forInfoDictionaryKey: "FanqieBuildTarget") as? String
      == "lib/main.dart"
    if isClient {
      if !setFrameUsingName("ReaderMainWindow") { center() }
    }
    if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
      center()
    }
    // Integration/AOT test entry points must not overwrite the user's saved
    // window geometry. Only the normal client restores and persists it.
    if isClient { setFrameAutosaveName("ReaderMainWindow") }
    delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)
    readerPlatform = ReaderNativePlatform(
      window: self, messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  func showReaderWindow() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    makeKeyAndOrderFront(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    readerPlatform?.releaseDisplayAssertion()
    orderOut(nil)
    readerPlatform?.channel.invokeMethod("onWindowHidden", arguments: nil)
    return false
  }

  func windowDidResignKey(_ notification: Notification) {
    readerPlatform?.releaseDisplayAssertion()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    readerPlatform?.refreshDisplayAssertion()
  }

  func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransitioning = true }
  func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransitioning = true }
  func windowDidEnterFullScreen(_ notification: Notification) { fullScreenTransitioning = false }
  func windowDidExitFullScreen(_ notification: Notification) { fullScreenTransitioning = false }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenTransitioning = false }
  func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenTransitioning = false }
}

/// The same channel name and callback contract as Android; no playback stubs
/// pretend to implement the explicitly deferred macOS listening milestone.
final class ReaderNativePlatform: NSObject, NSMenuItemValidation {
  let channel: FlutterMethodChannel
  private weak var window: MainFlutterWindow?
  private let monitor = NWPathMonitor()
  private let networkLock = NSLock()
  private var networkType = "unknown"
  private var displayAssertion: IOPMAssertionID = 0
  private var wantsDisplayAwake = false
  private var readerCommandsEnabled = false
  private let decoder = ReaderTextDecoder()
  private lazy var exporter = ReaderFileExporter(window: window)

  init(window: MainFlutterWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(
      name: "com.fanqie.fanqie_flutter/download", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      let kind: String
      if path.status != .satisfied {
        kind = "offline"
      } else if path.usesInterfaceType(.wifi) {
        kind = "wifi"
      } else if path.usesInterfaceType(.wiredEthernet) {
        kind = "ethernet"
      } else if path.usesInterfaceType(.cellular) {
        kind = "mobile"
      } else {
        kind = "unknown"
      }
      self.networkLock.lock()
      self.networkType = kind
      self.networkLock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "com.fanqie.reader.network"))
    DispatchQueue.main.async { [weak self] in self?.installMenus() }
  }

  deinit {
    monitor.cancel()
    releaseDisplayAssertion()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getReaderCapabilities":
      result([
        "tts": false, "mediaPlayback": false, "secureStorage": false,
        "windowBrightnessControl": false, "volumeKeys": false, "haptics": false,
        "battery": Self.batteryLevel() >= 0, "keepAwake": true,
        "networkType": true, "textDecoder": true, "fileExport": true,
        "platform": "macos", "architecture": "arm64",
        "foreground": window?.isKeyWindow ?? false,
        "windowVisible": window?.isVisible ?? false,
      ])
    case "getNetworkType":
      networkLock.lock()
      let kind = networkType
      networkLock.unlock()
      result(kind)
    case "getBatteryLevel":
      result(Self.batteryLevel())
    case "setKeepScreenOn":
      wantsDisplayAwake = args["enabled"] as? Bool == true
      refreshDisplayAssertion()
      result(true)
    case "normalizeTextFile":
      decoder.normalize(args, result: result)
    case "cancelTextDecode":
      decoder.cancel(args["id"] as? String ?? "")
      result(true)
    case "saveExportFile":
      exporter.save(args, result: result)
    case "cancelExport":
      exporter.cancel(args["id"] as? String ?? "")
      result(true)
    case "showMainWindow":
      window?.showReaderWindow()
      result(true)
    case "setReaderCommandsEnabled":
      readerCommandsEnabled = args["enabled"] as? Bool == true
      result(true)
    case "requestQuit":
      result(true)
      NSApp.terminate(nil)
    #if DEBUG
    case "setTestWindowSize":
      if let width = args["width"] as? Double, let height = args["height"] as? Double {
        window?.setContentSize(NSSize(width: max(720, width), height: max(540, height)))
      }
      result(true)
    case "getTestWindowState":
      result([
        "visible": window?.isVisible ?? false,
        "displayAssertion": displayAssertion != 0,
        "width": window?.contentView?.bounds.width ?? 0,
        "height": window?.contentView?.bounds.height ?? 0,
        "fullScreen": window?.styleMask.contains(.fullScreen) ?? false,
        "fullScreenTransitioning": window?.fullScreenTransitioning ?? false,
        "backingScaleFactor": window?.backingScaleFactor ?? 0,
        "applicationActive": NSApp.isActive,
        "activationPolicy": NSApp.activationPolicy().rawValue,
        "keyWindow": window?.isKeyWindow ?? false,
        "collectionBehavior": window?.collectionBehavior.rawValue ?? 0,
        "styleMask": window?.styleMask.rawValue ?? 0,
      ])
    case "setTestFullScreen":
      let enabled = args["enabled"] as? Bool == true
      if let window = window, !window.fullScreenTransitioning,
        window.styleMask.contains(.fullScreen) != enabled {
        window.showReaderWindow()
        window.toggleFullScreen(nil)
      }
      result(true)
    case "hideTestWindow":
      window?.performClose(nil)
      result(true)
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func installMenus() {
    guard let menu = NSApp.mainMenu else { return }
    if let appMenu = menu.items.first?.submenu,
      let settings = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
      settings.title = "阅读设置…"
      settings.target = self
      settings.action = #selector(openSettings)
    }
    let file = NSMenu(title: "文件")
    let importItem = NSMenuItem(
      title: "导入本地小说…", action: #selector(importBook), keyEquivalent: "o")
    importItem.target = self
    file.addItem(importItem)
    let bookmark = NSMenuItem(
      title: "添加／移除阅读书签", action: #selector(toggleBookmark), keyEquivalent: "d")
    bookmark.target = self
    file.addItem(bookmark)
    file.addItem(.separator())
    file.addItem(NSMenuItem(
      title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    let fileRoot = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
    fileRoot.submenu = file
    menu.insertItem(fileRoot, at: 1)
    updateFindMenu(menu)
  }

  private func updateFindMenu(_ menu: NSMenu) {
    for item in menu.items {
      if item.keyEquivalent == "f", item.keyEquivalentModifierMask == .command {
        item.title = "查找书籍／正文…"
        item.action = #selector(findContent)
        item.target = self
      }
      if let child = item.submenu { updateFindMenu(child) }
    }
  }

  @objc private func importBook() { sendCommand("import") }
  @objc private func openSettings() { sendCommand("settings") }
  @objc private func findContent() { sendCommand("find") }
  @objc private func toggleBookmark() { sendCommand("bookmark") }

  private func sendCommand(_ name: String) {
    window?.showReaderWindow()
    channel.invokeMethod("onDesktopCommand", arguments: name)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(toggleBookmark) { return readerCommandsEnabled }
    return window?.attachedSheet == nil
  }

  static func batteryLevel() -> Int {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return -1 }
    for source in sources {
      guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
        as? [String: Any],
        values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = values[kIOPSCurrentCapacityKey] as? Int,
        let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0
      else { continue }
      return min(100, max(0, current * 100 / maximum))
    }
    return -1
  }

  func refreshDisplayAssertion() {
    releaseDisplayAssertion()
    guard wantsDisplayAwake, window?.isKeyWindow == true else { return }
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), "番茄Reader 阅读" as CFString,
      &displayAssertion)
    if status != kIOReturnSuccess { displayAssertion = 0 }
  }

  func releaseDisplayAssertion() {
    if displayAssertion != 0 {
      IOPMAssertionRelease(displayAssertion)
      displayAssertion = 0
    }
  }
}

enum ReaderFileError: Error, Equatable {
  case cancelled
  case invalidInput
  case invalidEncoding
}

/// iconv preserves incomplete multibyte sequences between bounded reads.
/// Strict conversion never publishes replacement characters or a partial file.
final class ReaderTextDecoder {
  private let queue = DispatchQueue(label: "com.fanqie.reader.decode", qos: .userInitiated)
  private let lock = NSLock()
  private var cancelled = Set<String>()
  private var pending = Set<String>()

  func cancel(_ id: String) {
    lock.lock()
    if pending.contains(id) { cancelled.insert(id) }
    lock.unlock()
  }

  private func check(_ id: String) throws {
    lock.lock()
    let stopped = cancelled.contains(id)
    lock.unlock()
    if stopped { throw ReaderFileError.cancelled }
  }

  func normalize(_ args: [String: Any], result: @escaping FlutterResult) {
    let id = args["id"] as? String ?? ""
    let path = args["path"] as? String ?? ""
    let requested = args["encoding"] as? String ?? "auto"
    lock.lock()
    pending.insert(id)
    lock.unlock()
    queue.async {
      let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("reader-normalized-\(UUID().uuidString).txt")
      do {
        let source = URL(fileURLWithPath: path)
        let values = try source.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024
        else { throw ReaderFileError.invalidInput }
        let encodings: [String]
        if requested == "auto" {
          let handle = try FileHandle(forReadingFrom: source)
          let header = try handle.read(upToCount: 4) ?? Data()
          try handle.close()
          if header.starts(with: [0xff, 0xfe]) {
            encodings = ["UTF-16LE"]
          } else if header.starts(with: [0xfe, 0xff]) {
            encodings = ["UTF-16BE"]
          } else {
            encodings = ["UTF-8", "GB18030", "Big5"]
          }
        } else {
          guard ["UTF-8", "UTF-16LE", "UTF-16BE", "GB18030", "GBK", "Big5"]
            .contains(requested) else { throw ReaderFileError.invalidEncoding }
          encodings = [requested]
        }
        var selected: String?
        for encoding in encodings {
          try self.check(id)
          do {
            try Self.convert(source, to: target, encoding: encoding) { try self.check(id) }
            selected = encoding
            break
          } catch ReaderFileError.invalidEncoding {
            try? FileManager.default.removeItem(at: target)
          }
        }
        guard let encoding = selected else { throw ReaderFileError.invalidEncoding }
        try self.check(id)
        DispatchQueue.main.async { result(["path": target.path, "encoding": encoding]) }
      } catch {
        try? FileManager.default.removeItem(at: target)
        let isCancelled = (error as? ReaderFileError) == .cancelled
        DispatchQueue.main.async {
          result(FlutterError(
            code: isCancelled ? "IMPORT_CANCELLED" : "TEXT_DECODE",
            message: isCancelled ? "导入已取消" : "文本解码失败，请检查文件或手动选择编码",
            details: nil))
        }
      }
      self.lock.lock()
      self.cancelled.remove(id)
      self.pending.remove(id)
      self.lock.unlock()
    }
  }

  static func convert(
    _ source: URL, to destination: URL, encoding: String,
    check: () throws -> Void = {}
  ) throws {
    if encoding == "GB18030" {
      try convertGB18030(source, to: destination, check: check)
      return
    }
    guard let converter = iconv_open("UTF-8", encoding),
      converter != OpaquePointer(bitPattern: -1)
    else { throw ReaderFileError.invalidEncoding }
    defer { iconv_close(converter) }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    try output.truncate(atOffset: 0)
    defer { try? output.close() }
    var pending = Data()
    var sourceBytes = 0
    while true {
      try check()
      let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
      let finished = chunk.isEmpty
      sourceBytes += chunk.count
      guard sourceBytes <= 128 * 1024 * 1024 else { throw ReaderFileError.invalidInput }
      pending.append(chunk)
      var consumed = 0
      try pending.withUnsafeMutableBytes { raw in
        var cursor = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
        var remaining = raw.count
        while remaining > 0 {
          try check()
          var bytes = [UInt8](repeating: 0, count: 64 * 1024)
          var outputRemaining = bytes.count
          let converted = bytes.withUnsafeMutableBytes { buffer in
            var write = buffer.baseAddress?.assumingMemoryBound(to: CChar.self)
            return iconv(converter, &cursor, &remaining, &write, &outputRemaining)
          }
          let conversionError = errno
          try output.write(contentsOf: bytes.prefix(bytes.count - outputRemaining))
          consumed = raw.count - remaining
          if converted == -1 {
            if conversionError == E2BIG { continue }
            if conversionError == EINVAL && !finished { break }
            throw ReaderFileError.invalidEncoding
          }
        }
      }
      pending.removeFirst(consumed)
      if finished {
        guard pending.isEmpty else { throw ReaderFileError.invalidEncoding }
        break
      }
    }
    try output.synchronize()
  }

  // Darwin iconv rejects valid supplementary-plane GB18030 characters.
  // CoreFoundation supports the complete mapping. Split only at validated
  // character boundaries, retaining at most three bytes between bounded reads.
  private static func convertGB18030(
    _ source: URL, to destination: URL, check: () throws -> Void
  ) throws {
    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    try output.truncate(atOffset: 0)
    defer { try? output.close() }
    var pending = Data()
    var total = 0
    while true {
      try check()
      let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
      total += chunk.count
      guard total <= 128 * 1024 * 1024 else { throw ReaderFileError.invalidInput }
      pending.append(chunk)
      let bytes = [UInt8](pending)
      var offset = 0
      while offset < bytes.count {
        if bytes[offset] <= 0x7f { offset += 1; continue }
        guard (0x81...0xfe).contains(bytes[offset]) else {
          throw ReaderFileError.invalidEncoding
        }
        if offset + 1 >= bytes.count { break }
        let next = bytes[offset + 1]
        if (0x30...0x39).contains(next) {
          if offset + 3 >= bytes.count { break }
          guard (0x81...0xfe).contains(bytes[offset + 2]),
            (0x30...0x39).contains(bytes[offset + 3])
          else { throw ReaderFileError.invalidEncoding }
          offset += 4
        } else {
          guard (0x40...0xfe).contains(next), next != 0x7f else {
            throw ReaderFileError.invalidEncoding
          }
          offset += 2
        }
      }
      if offset > 0 {
        guard let text = String(data: Data(bytes.prefix(offset)), encoding: encoding) else {
          throw ReaderFileError.invalidEncoding
        }
        try output.write(contentsOf: Data(text.utf8))
        pending = Data(bytes.dropFirst(offset))
      }
      if chunk.isEmpty {
        guard pending.isEmpty else { throw ReaderFileError.invalidEncoding }
        break
      }
    }
    try output.synchronize()
  }
}

/// Sheets are serialized. The replacement is committed only after a complete,
/// cancellable streaming copy; cancellation never truncates an existing file.
final class ReaderFileExporter {
  private weak var window: MainFlutterWindow?
  private let worker = DispatchQueue(label: "com.fanqie.reader.export", qos: .userInitiated)
  private let lock = NSLock()
  private var cancelled = Set<String>()
  private var requests: [([String: Any], FlutterResult)] = []
  private var activePanel: NSSavePanel?
  private var activeID: String?

  init(window: MainFlutterWindow?) { self.window = window }

  func save(_ args: [String: Any], result: @escaping FlutterResult) {
    requests.append((args, result))
    presentNext()
  }

  func cancel(_ id: String) {
    guard activeID == id || requests.contains(where: { $0.0["id"] as? String == id })
    else { return }
    lock.lock()
    cancelled.insert(id)
    lock.unlock()
    if activeID == id { activePanel?.cancel(nil) }
  }

  private func isCancelled(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled.contains(id)
  }

  private func presentNext() {
    guard activeID == nil, !requests.isEmpty else { return }
    let (args, result) = requests.removeFirst()
    let id = args["id"] as? String ?? UUID().uuidString
    activeID = id
    if isCancelled(id) {
      finish(id, result: result, value: ["status": "cancelled"])
      return
    }
    let source = URL(fileURLWithPath: args["filePath"] as? String ?? "")
    let name = (args["fileName"] as? String ?? "export.txt") as NSString
    guard let window = window else {
      finish(id, result: result, value: ["status": "failed", "error": "阅读窗口不可用"])
      return
    }
    window.showReaderWindow()
    let panel = NSSavePanel()
    panel.title = "保存导出文件"
    panel.nameFieldStringValue = name.lastPathComponent
    panel.canCreateDirectories = true
    if let mime = args["mimeType"] as? String, let type = UTType(mimeType: mime) {
      panel.allowedContentTypes = [type]
    }
    activePanel = panel
    panel.beginSheetModal(for: window) { response in
      self.activePanel = nil
      guard response == .OK, let destination = panel.url, !self.isCancelled(id) else {
        self.finish(id, result: result, value: ["status": "cancelled"])
        return
      }
      self.worker.async {
        var value: [String: Any]
        do {
          try Self.copy(source, to: destination) {
            if self.isCancelled(id) { throw ReaderFileError.cancelled }
          }
          value = ["status": "saved", "path": destination.path]
        } catch {
          value = (error as? ReaderFileError) == .cancelled
            ? ["status": "cancelled"]
            : ["status": "failed", "error": "文件保存失败，请检查权限与存储空间"]
        }
        DispatchQueue.main.async { self.finish(id, result: result, value: value) }
      }
    }
  }

  private func finish(_ id: String, result: FlutterResult, value: [String: Any]) {
    lock.lock()
    cancelled.remove(id)
    lock.unlock()
    activeID = nil
    result(value)
    presentNext()
  }

  static func copy(
    _ source: URL, to destination: URL, check: () throws -> Void = {}
  ) throws {
    let scoped = destination.startAccessingSecurityScopedResource()
    defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      source.standardizedFileURL != destination.standardizedFileURL
    else { throw ReaderFileError.invalidInput }
    if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path) {
      // attributesOfItem also sees dangling symlinks, unlike fileExists.
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw ReaderFileError.invalidInput
      }
    }
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var operationError: Error?
    coordinator.coordinate(writingItemAt: destination, options: .forReplacing,
      error: &coordinationError) { target in
      do {
        try check()
        let replacement = try FileManager.default.url(
          for: .itemReplacementDirectory, in: .userDomainMask,
          appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let staging = replacement.appendingPathComponent(target.lastPathComponent)
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        while true {
          try check()
          let bytes = try input.read(upToCount: 64 * 1024) ?? Data()
          if bytes.isEmpty { break }
          try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        try output.close()
        try check()
        if FileManager.default.fileExists(atPath: target.path) {
          _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
          try FileManager.default.moveItem(at: staging, to: target)
        }
      } catch { operationError = error }
    }
    if let error = operationError { throw error }
    if let error = coordinationError { throw error }
  }
}
