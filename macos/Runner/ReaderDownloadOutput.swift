import Cocoa
import Darwin
import FlutterMacOS

enum ReaderDownloadError: Error, Equatable, LocalizedError {
  case invalidInput, invalidBookmark, authorityExpired, authorityDenied
  case atomicUnavailable, tooManyCollisions

  var errorDescription: String? {
    switch self {
    case .invalidInput: return "下载文件或目录无效，不允许链接、路径跳转或非普通文件"
    case .invalidBookmark: return "保存目录授权记录损坏，请重新选择保存位置"
    case .authorityExpired: return "保存目录授权已过期或已移动，请重新选择保存位置"
    case .authorityDenied: return "无法访问已选择的保存目录，请重新授权；未更换保存位置"
    case .atomicUnavailable: return "此存储卷不支持原子无覆盖保存，请选择其他保存目录"
    case .tooManyCollisions: return "同名文件过多，请更换文件名或保存目录"
    }
  }
}

struct ReaderResolvedDownloadBookmark {
  let directory: URL
  let isStale: Bool
}

protocol ReaderDownloadBookmarkAccess {
  func create(for directory: URL) throws -> Data
  func resolve(_ data: Data) throws -> ReaderResolvedDownloadBookmark
  func start(_ directory: URL) -> Bool
  func stop(_ directory: URL)
}

struct ReaderSecurityScopedDownloadBookmarks: ReaderDownloadBookmarkAccess {
  func create(for directory: URL) throws -> Data {
    try directory.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  func resolve(_ data: Data) throws -> ReaderResolvedDownloadBookmark {
    var stale = false
    let directory = try URL(resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI, .withoutMounting],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    return ReaderResolvedDownloadBookmark(directory: directory, isStale: stale)
  }

  func start(_ directory: URL) -> Bool { directory.startAccessingSecurityScopedResource() }
  func stop(_ directory: URL) { directory.stopAccessingSecurityScopedResource() }
}

struct ReaderDownloadFileMetadata {
  let size: Int64
  let path: String
  var exists: Bool { size > 0 }
}

/// Only the native Downloads entitlement or an explicitly selected directory
/// bookmark is authority. Remember every selected root so exact old history
/// paths can be checked after restart; never search by basename or recreate a
/// missing external directory.
final class ReaderDownloadDirectoryStore {
  static let preferencesKey = "macos_download_directories_v1"
  private let defaults: UserDefaults
  private let downloadsDirectory: () throws -> URL
  private let bookmarks: ReaderDownloadBookmarkAccess

  init(
    defaults: UserDefaults = .standard,
    downloadsDirectory: @escaping () throws -> URL = {
      try FileManager.default.url(
        for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    },
    bookmarks: ReaderDownloadBookmarkAccess = ReaderSecurityScopedDownloadBookmarks()
  ) {
    self.defaults = defaults
    self.downloadsDirectory = downloadsDirectory
    self.bookmarks = bookmarks
  }

  private func state() throws -> (current: String, roots: [String: Any])? {
    guard let stored = defaults.object(forKey: Self.preferencesKey) else { return nil }
    guard let values = stored as? [String: Any],
      let current = values["current"] as? String, current.hasPrefix("/"),
      let roots = values["bookmarks"] as? [String: Any], roots[current] is Data
    else { throw ReaderDownloadError.invalidBookmark }
    return (current, roots)
  }

  func remember(_ directory: URL) throws -> URL {
    guard directory.isFileURL, bookmarks.start(directory) else {
      throw ReaderDownloadError.authorityDenied
    }
    defer { bookmarks.stop(directory) }
    let descriptor = try ReaderDownloadWriter.directoryDescriptor(directory)
    defer { close(descriptor) }
    let selected = directory.standardizedFileURL
    let data = try bookmarks.create(for: directory)
    // Explicit user selection may repair corrupt state. Resolution never does.
    // Preserve all recoverable older records rather than just the current one.
    var roots = (defaults.dictionary(forKey: Self.preferencesKey)?["bookmarks"]
      as? [String: Any]) ?? [:]
    roots[selected.path] = data
    defaults.set(["current": selected.path, "bookmarks": roots], forKey: Self.preferencesKey)
    return selected
  }

  private func withBookmark<T>(
    path: String, data: Data, _ operation: (URL) throws -> T
  ) throws -> T {
    let restored: ReaderResolvedDownloadBookmark
    do { restored = try bookmarks.resolve(data) }
    catch { throw ReaderDownloadError.invalidBookmark }
    guard !restored.isStale,
      restored.directory.isFileURL, restored.directory.standardizedFileURL.path == path
    else { throw ReaderDownloadError.authorityExpired }
    guard bookmarks.start(restored.directory) else { throw ReaderDownloadError.authorityDenied }
    defer { bookmarks.stop(restored.directory) }
    let descriptor = try ReaderDownloadWriter.directoryDescriptor(restored.directory)
    defer { close(descriptor) }
    return try operation(restored.directory)
  }

  private func defaultDirectory(create: Bool) throws -> URL {
    // Foundation may return a sandbox-container alias for the system Downloads
    // folder. Canonicalize ONLY this native provider, never an incoming hint or
    // a chosen link; actual access still requires the narrow Downloads grant.
    let downloads = try downloadsDirectory().resolvingSymlinksInPath()
    let descriptor = try ReaderDownloadWriter.directoryDescriptor(downloads)
    defer { close(descriptor) }
    if create {
      let made = "fanqie".withCString { mkdirat(descriptor, $0, mode_t(0o755)) }
      if made != 0 && errno != EEXIST { throw ReaderDownloadWriter.posixError() }
    }
    let output = downloads.appendingPathComponent("fanqie", isDirectory: true)
    if create {
      let child = try ReaderDownloadWriter.directoryDescriptor(output)
      close(child)
    }
    return output
  }

  func withAuthorizedDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    if let saved = try state() {
      guard let data = saved.roots[saved.current] as? Data else {
        throw ReaderDownloadError.invalidBookmark
      }
      return try withBookmark(path: saved.current, data: data, operation)
    }
    return try operation(defaultDirectory(create: true))
  }

  func resolve() throws -> URL { try withAuthorizedDirectory { $0 } }

  func check(filePath: String, contentUri: String = "") throws -> ReaderDownloadFileMetadata {
    guard contentUri.isEmpty, filePath.hasPrefix("/"), !filePath.contains("\0"),
      !filePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { throw ReaderDownloadError.invalidInput }
    let file = URL(fileURLWithPath: filePath)
    try ReaderDownloadWriter.validateName(file.lastPathComponent)
    let parent = file.deletingLastPathComponent().standardizedFileURL
    // Look up only the recorded parent. A current bookmark cannot validate an
    // earlier same-named file in a different or no-longer-authorized directory.
    if let saved = try state(), let stored = saved.roots[parent.path] {
      guard let data = stored as? Data else { throw ReaderDownloadError.invalidBookmark }
      return try withBookmark(path: parent.path, data: data) {
        try metadata(filePath: filePath, name: file.lastPathComponent, directory: $0)
      }
    }
    let output = try defaultDirectory(create: false)
    guard parent.path == output.standardizedFileURL.path else {
      throw ReaderDownloadError.authorityDenied
    }
    return try metadata(filePath: filePath, name: file.lastPathComponent, directory: output)
  }

  private func metadata(
    filePath: String, name: String, directory: URL
  ) throws -> ReaderDownloadFileMetadata {
    let directoryFD = try ReaderDownloadWriter.directoryDescriptor(directory)
    defer { close(directoryFD) }
    let descriptor = name.withCString {
      openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      if errno == ENOENT { return ReaderDownloadFileMetadata(size: 0, path: filePath) }
      throw ReaderDownloadWriter.posixError()
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw ReaderDownloadWriter.posixError() }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw ReaderDownloadError.invalidInput
    }
    return ReaderDownloadFileMetadata(size: max(0, Int64(info.st_size)), path: filePath)
  }
}

/// Bounded streaming copy into the SAME directory, followed exclusively by
/// Darwin's atomic no-replace rename. A failure/cancel unlinks only our unique
/// staging name, never an existing destination. Directory/file descriptors
/// pin identities and O_NOFOLLOW rejects final-component link swaps.
final class ReaderDownloadWriter {
  typealias Rename = (Int32, String, String) throws -> Void
  private let rename: Rename

  init(rename: @escaping Rename = ReaderDownloadWriter.renameExclusive) {
    self.rename = rename
  }

  static func posixError(_ code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
  }

  static func validateName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..",
      !name.contains("/"), !name.contains("\\"), !name.contains("\0")
    else { throw ReaderDownloadError.invalidInput }
  }

  static func directoryDescriptor(_ directory: URL) throws -> Int32 {
    guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0")
    else { throw ReaderDownloadError.invalidInput }
    let descriptor = directory.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw posixError() }
    var info = stat()
    if fstat(descriptor, &info) != 0 {
      let error = posixError()
      close(descriptor)
      throw error
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      close(descriptor)
      throw ReaderDownloadError.invalidInput
    }
    return descriptor
  }

  static func renameExclusive(_ directory: Int32, _ staging: String, _ name: String) throws {
    let renamed = staging.withCString { from in
      name.withCString { to in
        renameatx_np(directory, from, directory, to, UInt32(RENAME_EXCL))
      }
    }
    guard renamed == 0 else {
      let code = errno
      if code == ENOTSUP || code == ENOSYS || code == EINVAL {
        throw ReaderDownloadError.atomicUnavailable
      }
      throw posixError(code)
    }
  }

  func commit(
    _ source: URL, named name: String, in directory: URL,
    check: () throws -> Void = {},
    publish: (_ operation: () throws -> Void) throws -> Void = { try $0() }
  ) throws -> URL {
    try check()
    try Self.validateName(name)
    guard source.isFileURL, source.path.hasPrefix("/"), !source.path.contains("\0"),
      source.standardizedFileURL != directory.appendingPathComponent(name).standardizedFileURL
    else { throw ReaderDownloadError.invalidInput }
    let inputFD = source.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
    guard inputFD >= 0 else { throw Self.posixError() }
    let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
    defer { try? input.close() }
    var info = stat()
    guard fstat(inputFD, &info) == 0 else { throw Self.posixError() }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw ReaderDownloadError.invalidInput
    }
    let directoryFD = try Self.directoryDescriptor(directory)
    defer { close(directoryFD) }
    let staging = ".fanqie-download-\(UUID().uuidString).pending"
    let outputFD = staging.withCString {
      openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard outputFD >= 0 else { throw Self.posixError() }
    defer { staging.withCString { _ = unlinkat(directoryFD, $0, 0) } }
    let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
    defer { try? output.close() }
    while true {
      try check()
      let bytes = try input.read(upToCount: 64 * 1024) ?? Data()
      if bytes.isEmpty { break }
      try output.write(contentsOf: bytes)
    }
    try output.synchronize()
    try output.close()
    let extensionName = (name as NSString).pathExtension
    let stem = extensionName.isEmpty ? name : (name as NSString).deletingPathExtension
    for number in 1...10000 {
      try check()
      let candidate = number == 1 ? name
        : "\(stem) (\(number))" + (extensionName.isEmpty ? "" : ".\(extensionName)")
      do {
        try publish { try rename(directoryFD, staging, candidate) }
        // Publication is the success boundary. Never check cancellation again.
        return directory.appendingPathComponent(candidate)
      } catch let error as NSError
        where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
        var existing = stat()
        let found = candidate.withCString {
          fstatat(directoryFD, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        if found == 0 {
          guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ReaderDownloadError.invalidInput
          }
        } else if errno != ENOENT { throw Self.posixError() }
      }
    }
    throw ReaderDownloadError.tooManyCollisions
  }
}

/// The cancellation/commit lock linearizes a cancel against publication.
/// After publication succeeds, queued late cancellation cannot rewrite saved.
final class ReaderExportRequest {
  let id: String
  var onCancel: (() -> Void)?
  private let lock = NSLock()
  private var cancelled = false

  init(id: String) { self.id = id }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw ReaderFileError.cancelled }
  }

  func publish(_ operation: () throws -> Void) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw ReaderFileError.cancelled }
    try operation()
  }

  fileprivate func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
    onCancel?()
  }
}

/// Manual export sheets and uninterrupted download commits share one ID queue,
/// one serial background worker and one cancelExport entry point. Queue state
/// and Flutter results stay on main; only bounded I/O runs in the worker.
final class ReaderExportQueue {
  typealias Completion = ([String: Any]) -> Void
  typealias Start = (ReaderExportRequest, @escaping Completion) -> Void
  private struct Entry {
    let request: ReaderExportRequest
    let result: FlutterResult
    let start: Start
  }
  private let worker = DispatchQueue(label: "com.fanqie.reader.export", qos: .userInitiated)
  private var waiting = [Entry]()
  private var active: Entry?

  func enqueue(id: String, result: @escaping FlutterResult, start: @escaping Start) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !id.isEmpty, active?.request.id != id,
      !waiting.contains(where: { $0.request.id == id })
    else {
      result(["status": "failed", "error": "文件保存请求 ID 为空或已在队列中"])
      return
    }
    waiting.append(Entry(request: ReaderExportRequest(id: id), result: result, start: start))
    startNext()
  }

  func cancel(_ id: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    let request = active?.request.id == id ? active?.request
      : waiting.first(where: { $0.request.id == id })?.request
    request?.cancel()
  }

  func perform(_ work: @escaping () -> [String: Any], completion: @escaping Completion) {
    worker.async {
      let value = work()
      DispatchQueue.main.async { completion(value) }
    }
  }

  private func startNext() {
    guard active == nil, !waiting.isEmpty else { return }
    let entry = waiting.removeFirst()
    active = entry
    let finish: Completion = { value in
      dispatchPrecondition(condition: .onQueue(.main))
      guard self.active?.request === entry.request else { return }
      entry.request.onCancel = nil
      self.active = nil
      entry.result(value)
      self.startNext()
    }
    do { try entry.request.check() }
    catch { finish(["status": "cancelled"]); return }
    entry.start(entry.request, finish)
  }
}

final class ReaderDownloadOutput {
  private weak var window: MainFlutterWindow?
  private let store: ReaderDownloadDirectoryStore
  private let queue: ReaderExportQueue
  private let writer: ReaderDownloadWriter
  private var activePanel: NSOpenPanel?

  init(
    window: MainFlutterWindow? = nil,
    store: ReaderDownloadDirectoryStore = ReaderDownloadDirectoryStore(),
    queue: ReaderExportQueue = ReaderExportQueue(),
    writer: ReaderDownloadWriter = ReaderDownloadWriter()
  ) {
    self.window = window
    self.store = store
    self.queue = queue
    self.writer = writer
  }

  private static func failure(_ error: Error) -> [String: Any] {
    ["status": "failed", "error": "文件保存失败：\(error.localizedDescription)"]
  }

  func getDirectory(result: @escaping FlutterResult) {
    queue.perform({
      do { return ["status": "saved", "path": try self.store.resolve().path] }
      catch { return Self.failure(error) }
    }, completion: { result($0) })
  }

  func pickDirectory(result: @escaping FlutterResult) {
    guard activePanel == nil, let window = window else {
      result(["status": "failed", "error": "目录选择器或阅读窗口不可用"])
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择下载保存目录"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    activePanel = panel
    window.showReaderWindow()
    panel.beginSheetModal(for: window) { response in
      self.activePanel = nil
      guard response == .OK, let directory = panel.url else {
        result(["status": "cancelled"])
        return
      }
      do { result(["status": "saved", "path": try self.store.remember(directory).path]) }
      catch { result(Self.failure(error)) }
    }
  }

  func commit(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let id = args["id"] as? String, !id.isEmpty,
      let path = args["sourcePath"] as? String, path.hasPrefix("/"), !path.contains("\0"),
      let name = args["fileName"] as? String
    else { result(Self.failure(ReaderDownloadError.invalidInput)); return }
    // Deliberately do not read args["directory"] as authority (or as a hint).
    queue.enqueue(id: id, result: result) { request, finish in
      self.queue.perform({
        do {
          try request.check()
          let target = try self.store.withAuthorizedDirectory {
            try self.writer.commit(URL(fileURLWithPath: path), named: name, in: $0,
              check: { try request.check() }, publish: { try request.publish($0) })
          }
          return ["status": "saved", "path": target.path]
        } catch {
          if (error as? ReaderFileError) == .cancelled { return ["status": "cancelled"] }
          return Self.failure(error)
        }
      }, completion: finish)
    }
  }

  func checkFile(_ args: [String: Any], result: @escaping FlutterResult) {
    let path = args["filePath"] as? String ?? ""
    guard args["filePath"] is String,
      args["contentUri"] == nil || args["contentUri"] is String
    else {
      result(["exists": false, "size": 0, "path": path, "error": "下载记录参数无效"])
      return
    }
    queue.perform({
      do {
        let checked = try self.store.check(
          filePath: path, contentUri: args["contentUri"] as? String ?? "")
        return ["exists": checked.exists, "size": checked.size, "path": checked.path]
      } catch {
        return ["exists": false, "size": 0, "path": path, "error": error.localizedDescription]
      }
    }, completion: { result($0) })
  }
}
