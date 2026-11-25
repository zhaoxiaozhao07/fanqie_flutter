import Cocoa
import FlutterMacOS
import XCTest
import AVFoundation
import Darwin
@testable import FanqieReader

final class RunnerTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("reader-native-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func file(_ name: String, _ bytes: Data) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
  }

  func testNativeHostNeverBootsProductionDart() {
    XCTAssertTrue(ReaderNativeTestHost.isRunning)
    let windows = NSApp.windows.compactMap { $0 as? MainFlutterWindow }
    XCTAssertFalse(windows.contains { $0.readerPlatform != nil })
  }

  private func nativeScroll(
    _ units: CGScrollEventUnit, timestamp: CGEventTimestamp = 1_000_000_900
  ) throws -> NSEvent {
    let cgEvent = try XCTUnwrap(CGEvent(
      scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
      wheel1: 3, wheel2: 0, wheel3: 0))
    cgEvent.setIntegerValueField(
      .scrollWheelEventIsContinuous, value: units == .pixel ? 1 : 0)
    cgEvent.timestamp = timestamp
    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
  }

  func testLineScrollNotifiesDiscretePrecisionAndTruncatedSourceTimestamp() throws {
    let event = try nativeScroll(.line)
    XCTAssertFalse(event.hasPreciseScrollingDeltas)
    let input = try XCTUnwrap(ReaderScrollInput.notification(for: event))
    // CGEvent uses nanoseconds; Flutter 3.47.9 casts NSEvent seconds * 1e6.
    // The fractional 0.9 microsecond must not be rounded up to 1_000_001.
    XCTAssertEqual(event.timestamp, 1.0000009, accuracy: 0.00000001)
    XCTAssertEqual(input["timestampMicros"] as? Int64, 1_000_000)
    XCTAssertEqual(input["precise"] as? Bool, false)
    XCTAssertEqual(Set(input.keys), Set(["timestampMicros", "precise"]))
  }

  func testPixelScrollNotifiesPreciseWithoutGuessingFromDeltaSize() throws {
    // Both fixtures use wheel1 == 3. Only the native precision property differs.
    let event = try nativeScroll(.pixel)
    XCTAssertTrue(event.hasPreciseScrollingDeltas)
    let input = try XCTUnwrap(ReaderScrollInput.notification(for: event))
    XCTAssertEqual(input["timestampMicros"] as? Int64, 1_000_000)
    XCTAssertEqual(input["precise"] as? Bool, true)
  }

  func testScrollSourceTimestampRejectsInvalidOrUnrepresentableValues() {
    XCTAssertEqual(ReaderScrollInput.timestampMicros(1.0000009), 1_000_000)
    XCTAssertNil(ReaderScrollInput.timestampMicros(0))
    XCTAssertNil(ReaderScrollInput.timestampMicros(-1))
    XCTAssertNil(ReaderScrollInput.timestampMicros(0.0000001))
    XCTAssertNil(ReaderScrollInput.timestampMicros(.nan))
    XCTAssertNil(ReaderScrollInput.timestampMicros(.infinity))
    XCTAssertNil(ReaderScrollInput.timestampMicros(.greatestFiniteMagnitude))
    XCTAssertNil(ReaderScrollInput.timestampMicros(Double(Int64.max) / 1_000_000))
  }

  func testScrollMonitorOnlyNotifiesItsReaderWindowAndReturnsOriginalEvent() throws {
    let reader = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: .borderless, backing: .buffered, defer: false)
    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: .borderless, backing: .buffered, defer: false)
    var notifications = [[String: Any]]()
    let monitor = ReaderScrollInput(window: reader) { notifications.append($0) }
    let event = try nativeScroll(.line)
    XCTAssertTrue(monitor.forward(event, from: other) === event)
    XCTAssertTrue(monitor.forward(event, from: nil) === event)
    XCTAssertTrue(notifications.isEmpty)
    XCTAssertTrue(monitor.forward(event, from: reader) === event)
    XCTAssertEqual(notifications.count, 1)
    XCTAssertEqual(notifications.first?["timestampMicros"] as? Int64, 1_000_000)
    XCTAssertEqual(notifications.first?["precise"] as? Bool, false)
    let key = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
      windowNumber: reader.windowNumber, context: nil, characters: "a",
      charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    XCTAssertTrue(monitor.forward(key, from: reader) === key)
    XCTAssertEqual(notifications.count, 1)
  }

  func testScrollMonitorDoesNotRetainItsOwner() {
    let reader = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: .borderless, backing: .buffered, defer: false)
    var monitor: ReaderScrollInput? = ReaderScrollInput(window: reader) { _ in }
    weak var weakMonitor = monitor
    monitor = nil
    XCTAssertNil(weakMonitor)
    withExtendedLifetime(reader) {}
  }

  func testExternalImportStagesExactBytesAndKeepsOriginal() throws {
    let original = try file("中文 文件.TXT", Data("第一章\n完整原文😀".utf8))
    let root = directory.appendingPathComponent("external", isDirectory: true)
    let staged = try ReaderExternalFileInbox.stage(
      original, in: root, id: UUID().uuidString)
    XCTAssertNotEqual(staged, original)
    XCTAssertEqual(staged.lastPathComponent, "中文 文件.TXT")
    XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: original))
    XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: staged.deletingLastPathComponent().appendingPathComponent("source.pending").path))
  }

  func testExternalImportRejectsUnsupportedLinksEmptyFilesAndLimits() throws {
    let root = directory.appendingPathComponent("external", isDirectory: true)
    let unsupported = try file("other.pdf", Data("not a book".utf8))
    XCTAssertThrowsError(try ReaderExternalFileInbox.stage(
      unsupported, in: root, id: UUID().uuidString))
    XCTAssertFalse(ReaderExternalFileInbox.accepts(URL(string: "https://example.com/book.txt")!))
    let empty = try file("empty.txt", Data())
    XCTAssertThrowsError(try ReaderExternalFileInbox.stage(empty, in: root, id: UUID().uuidString))
    let source = try file("source.txt", Data("valid text".utf8))
    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertThrowsError(try ReaderExternalFileInbox.stage(link, in: root, id: UUID().uuidString))
    XCTAssertThrowsError(try ReaderExternalFileInbox.stage(
      source, in: root, id: UUID().uuidString, limit: 4))
    XCTAssertThrowsError(try ReaderExternalFileInbox.stage(source, in: root, id: "../escape"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testExternalInboxBuffersAndDeduplicatesBeforeDartIsReady() throws {
    let source = try file("buffered.txt", Data("原文件不得被删除".utf8))
    let inbox = ReaderExternalFileInbox(
      root: directory.appendingPathComponent("inbox", isDirectory: true))
    let ready = expectation(description: "staged")
    inbox.onReady = { ready.fulfill() }
    inbox.enqueue([source, source])
    wait(for: [ready], timeout: 3)
    XCTAssertFalse(inbox.hasTransfers)
    let pending = inbox.takePending()
    XCTAssertEqual(pending.count, 1)
    XCTAssertTrue(inbox.takePending().isEmpty)
    let id = try XCTUnwrap(pending.first?["id"] as? String)
    let path = try XCTUnwrap(pending.first?["path"] as? String)
    inbox.release("../../original")
    inbox.release(id)
    let released = expectation(description: "released")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { released.fulfill() }
    wait(for: [released], timeout: 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testTraditionalChineseEncodings() throws {
    let fixtures: [(String, [UInt8], String)] = [
      ("GB18030", [0xd6, 0xd0, 0xce, 0xc4, 0x94, 0x39, 0xfc, 0x36], "中文😀"),
      ("GBK", [0xd6, 0xd0, 0xce, 0xc4], "中文"),
      ("Big5", [0xa4, 0xa4, 0xa4, 0xe5], "中文"),
      ("UTF-16LE", [0xff, 0xfe, 0x2d, 0x4e, 0x87, 0x65], "中文"),
      ("UTF-16BE", [0xfe, 0xff, 0x4e, 0x2d, 0x65, 0x87], "中文"),
    ]
    for (encoding, bytes, expected) in fixtures {
      let input = try file("source-\(encoding)", Data(bytes))
      let output = directory.appendingPathComponent("output-\(encoding)")
      try ReaderTextDecoder.convert(input, to: output, encoding: encoding)
      XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), expected, encoding)
      XCTAssertEqual(try Data(contentsOf: input), Data(bytes))
    }
  }

  func testMultibyteSequenceSpansReadBoundary() throws {
    var bytes = Data(repeating: 0x61, count: 65535)
    bytes.append(contentsOf: [0xd6, 0xd0])
    let input = try file("split-gbk", bytes)
    let output = directory.appendingPathComponent("split-output")
    try ReaderTextDecoder.convert(input, to: output, encoding: "GBK")
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8),
                   String(repeating: "a", count: 65535) + "中")
  }

  func testInvalidAndTruncatedEncodingIsRejected() throws {
    let fixtures: [(String, [UInt8])] = [
      ("UTF-8", [0xff]), ("GB18030", [0x81, 0x30, 0x81]),
      ("Big5", [0xa4]), ("UTF-16LE", [0x00, 0xd8]),
    ]
    for (encoding, bytes) in fixtures {
      let input = try file("invalid-\(encoding)", Data(bytes))
      XCTAssertThrowsError(try ReaderTextDecoder.convert(
        input, to: directory.appendingPathComponent("invalid-out"), encoding: encoding)) {
          XCTAssertEqual($0 as? ReaderFileError, .invalidEncoding)
      }
    }
  }

  func testNormalizeAutoDetectionAndInputLimits() throws {
    let decoder = ReaderTextDecoder()
    let input = try file("auto-gbk", Data([0xd6, 0xd0, 0xce, 0xc4]))
    let converted = expectation(description: "native normalized result")
    decoder.normalize(["id": "auto", "path": input.path, "encoding": "auto"]) { value in
      guard let result = value as? [String: String], let path = result["path"] else {
        XCTFail("Missing normalized result: \(String(describing: value))")
        converted.fulfill()
        return
      }
      XCTAssertEqual(result["encoding"], "GB18030")
      XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "中文")
      try? FileManager.default.removeItem(atPath: path)
      converted.fulfill()
    }
    wait(for: [converted], timeout: 10)

    let oversized = try file("oversized", Data())
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: 128 * 1024 * 1024 + 1)
    try handle.close()
    let rejected = expectation(description: "128 MB limit")
    decoder.normalize(["id": "large", "path": oversized.path]) { value in
      XCTAssertEqual((value as? FlutterError)?.code, "TEXT_DECODE")
      rejected.fulfill()
    }
    wait(for: [rejected], timeout: 10)
  }

  func testDecoderCancellationDoesNotPublishPartialText() throws {
    let decoder = ReaderTextDecoder()
    let input = try file("cancel-decode", Data(repeating: 0x61, count: 8 * 1024 * 1024))
    let stopped = expectation(description: "cancelled conversion")
    decoder.normalize(["id": "cancel", "path": input.path]) { value in
      XCTAssertEqual((value as? FlutterError)?.code, "IMPORT_CANCELLED")
      stopped.fulfill()
    }
    decoder.cancel("cancel")
    wait(for: [stopped], timeout: 10)
    XCTAssertEqual(try Data(contentsOf: input).count, 8 * 1024 * 1024)
  }

  func testStreamingExportAndAtomicReplacement() throws {
    let bytes = Data(repeating: 0x61, count: 3 * 1024 * 1024 + 1)
    let source = try file("source", bytes)
    let target = directory.appendingPathComponent("new-export")
    try ReaderFileExporter.copy(source, to: target)
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    try Data("old content".utf8).write(to: target)
    try ReaderFileExporter.copy(source, to: target)
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
  }

  func testCancelledExportPreservesExistingDestination() throws {
    let source = try file("cancel-source", Data(repeating: 0x61, count: 200000))
    let target = try file("existing", Data("must survive".utf8))
    var checks = 0
    XCTAssertThrowsError(try ReaderFileExporter.copy(source, to: target) {
      checks += 1
      if checks >= 3 { throw ReaderFileError.cancelled }
    }) { XCTAssertEqual($0 as? ReaderFileError, .cancelled) }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must survive")
  }

  func testExportRejectsSameSourceAndSymbolicLinks() throws {
    let source = try file("original", Data("book".utf8))
    let target = try file("other", Data("safe".utf8))
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertThrowsError(try ReaderFileExporter.copy(source, to: source))
    XCTAssertThrowsError(try ReaderFileExporter.copy(link, to: target))
    XCTAssertThrowsError(try ReaderFileExporter.copy(target, to: link))
    let dangling = directory.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(
      at: dangling, withDestinationURL: directory.appendingPathComponent("absent"))
    XCTAssertThrowsError(try ReaderFileExporter.copy(source, to: dangling))
    XCTAssertThrowsError(try ReaderFileExporter.copy(source, to: directory))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "book")
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "safe")
  }

  private func downloadDirectory(_ name: String = "downloads") throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func downloadDefaults() throws -> UserDefaults {
    let suite = "com.fanqie.reader.download-tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
  }

  func testDownloadExactBytesAndNumericCollisions() throws {
    let output = try downloadDirectory()
    var bytes = Data(repeating: 0x61, count: 3 * 1024 * 1024 + 7)
    bytes.append(Data("中文😀".utf8))
    let source = try file("download-source", bytes)
    let writer = ReaderDownloadWriter()
    let first = try writer.commit(source, named: "书.epub", in: output)
    let second = try writer.commit(source, named: "书.epub", in: output)
    let third = try writer.commit(source, named: "书.epub", in: output)
    XCTAssertEqual(first.lastPathComponent, "书.epub")
    XCTAssertEqual(second.lastPathComponent, "书 (2).epub")
    XCTAssertEqual(third.lastPathComponent, "书 (3).epub")
    for target in [first, second, third] {
      XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    XCTAssertEqual(try Data(contentsOf: source), bytes)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 3)
  }

  func testDownloadExclusiveRenameDoesNotOverwriteARacingFile() throws {
    let output = try downloadDirectory()
    let original = Data("racer must survive".utf8)
    let bytes = Data("complete new download".utf8)
    let source = try file("racing-source", bytes)
    let target = output.appendingPathComponent("race.epub")
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      if name == "race.epub" { try original.write(to: target) }
      // Exercise the real Darwin no-replace operation, not a mock move.
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
    })
    let saved = try writer.commit(source, named: "race.epub", in: output)
    XCTAssertEqual(saved.lastPathComponent, "race (2).epub")
    XCTAssertEqual(try Data(contentsOf: target), original)
    XCTAssertEqual(try Data(contentsOf: saved), bytes)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 2)
  }

  func testDownloadConcurrentWritersPublishDistinctCompleteFiles() throws {
    let output = try downloadDirectory()
    let fixtures = try (0..<8).map { index -> (URL, Data) in
      let bytes = Data(repeating: UInt8(index + 1), count: 65537)
      return (try file("concurrent-\(index)", bytes), bytes)
    }
    let results = DownloadRaceResults()
    let group = DispatchGroup()
    for (source, bytes) in fixtures {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        do {
          let target = try ReaderDownloadWriter().commit(source, named: "same.txt", in: output)
          results.append(target, bytes: bytes)
        } catch { results.fail(error) }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
    XCTAssertEqual(Set(results.files.map { $0.0.path }).count, 8)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 8)
    for (target, bytes) in results.files { XCTAssertEqual(try Data(contentsOf: target), bytes) }
  }

  func testDownloadRejectsInvalidNamesAndNonregularSources() throws {
    let output = try downloadDirectory()
    let source = try file("valid-download", Data("safe".utf8))
    let writer = ReaderDownloadWriter()
    for name in ["", ".", "..", "../escape", "/absolute", "with\\slash", "nul\0.txt"] {
      XCTAssertThrowsError(try writer.commit(source, named: name, in: output), name)
    }
    XCTAssertThrowsError(try writer.commit(directory, named: "book.txt", in: output))
    XCTAssertThrowsError(try writer.commit(
      URL(string: "https://example.invalid/book.txt")!, named: "book.txt", in: output))
    let fifo = directory.appendingPathComponent("input-fifo")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    XCTAssertThrowsError(try writer.commit(fifo, named: "book.txt", in: output))
    XCTAssertThrowsError(try writer.commit(source, named: "book.txt", in: source))
    XCTAssertThrowsError(try writer.commit(
      output.appendingPathComponent("missing"), named: "book.txt", in: output))
    let same = output.appendingPathComponent("same.txt")
    try Data("original".utf8).write(to: same)
    XCTAssertThrowsError(try writer.commit(same, named: "same.txt", in: output))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["same.txt"])
  }

  func testDownloadRejectsSourceDirectoryAndDestinationLinks() throws {
    let output = try downloadDirectory()
    let source = try file("original-download", Data("must survive".utf8))
    let sourceLink = directory.appendingPathComponent("source-link")
    try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
    let directoryLink = directory.appendingPathComponent("directory-link")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: output)
    let target = output.appendingPathComponent("book.txt")
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
    let writer = ReaderDownloadWriter()
    XCTAssertThrowsError(try writer.commit(sourceLink, named: "other.txt", in: output))
    XCTAssertThrowsError(try writer.commit(source, named: "other.txt", in: directoryLink))
    XCTAssertThrowsError(try writer.commit(source, named: "book.txt", in: output))
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(
      at: target, withDestinationURL: directory.appendingPathComponent("absent"))
    XCTAssertThrowsError(try writer.commit(source, named: "book.txt", in: output))
    XCTAssertEqual(try Data(contentsOf: source), Data("must survive".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["book.txt"])
  }

  func testDownloadEarlyCancellationHasNoOutputSideEffects() throws {
    let output = try downloadDirectory()
    let source = try file("cancel-early-download", Data("complete source".utf8))
    XCTAssertThrowsError(try ReaderDownloadWriter().commit(
      source, named: "cancel.txt", in: output, check: { throw ReaderFileError.cancelled }
    )) { XCTAssertEqual($0 as? ReaderFileError, .cancelled) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), Data("complete source".utf8))
  }

  func testDownloadCopyCancellationIsBoundedTo64KiBAndCleansStaging() throws {
    let output = try downloadDirectory()
    let source = try file("cancel-copy-download", Data(repeating: 0x61, count: 200000))
    let existing = output.appendingPathComponent("cancel.txt")
    try Data("old output".utf8).write(to: existing)
    var checks = 0
    XCTAssertThrowsError(try ReaderDownloadWriter().commit(
      source, named: "cancel.txt", in: output, check: {
        checks += 1
        if checks == 3 {
          let staging = try FileManager.default.contentsOfDirectory(
            at: output, includingPropertiesForKeys: nil).filter {
              $0.lastPathComponent.hasPrefix(".fanqie-download-")
            }
          XCTAssertEqual(staging.count, 1)
          XCTAssertEqual(try Data(contentsOf: XCTUnwrap(staging.first)).count, 64 * 1024)
          throw ReaderFileError.cancelled
        }
      }
    )) { XCTAssertEqual($0 as? ReaderFileError, .cancelled) }
    XCTAssertEqual(checks, 3)
    XCTAssertEqual(try Data(contentsOf: existing), Data("old output".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["cancel.txt"])
  }

  func testDownloadCancellationAtPublicationPreservesOldFiles() throws {
    let output = try downloadDirectory()
    let source = try file("cancel-publish-download", Data("new complete bytes".utf8))
    let existing = output.appendingPathComponent("book.txt")
    try Data("old complete bytes".utf8).write(to: existing)
    XCTAssertThrowsError(try ReaderDownloadWriter().commit(
      source, named: "book.txt", in: output,
      publish: { _ in throw ReaderFileError.cancelled }
    )) { XCTAssertEqual($0 as? ReaderFileError, .cancelled) }
    XCTAssertEqual(try Data(contentsOf: existing), Data("old complete bytes".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["book.txt"])
  }

  func testDownloadSuccessfulPublicationWinsOverLaterCancellation() throws {
    let output = try downloadDirectory()
    let source = try file("committed-download", Data("complete bytes".utf8))
    var cancelled = false
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
      cancelled = true
    })
    let saved = try writer.commit(source, named: "book.txt", in: output, check: {
      if cancelled { throw ReaderFileError.cancelled }
    })
    XCTAssertTrue(cancelled)
    XCTAssertEqual(try Data(contentsOf: saved), Data("complete bytes".utf8))
  }

  func testDownloadUnsupportedAtomicPublicationNeverFallsBackToMove() throws {
    let output = try downloadDirectory()
    let source = try file("unsupported-volume-source", Data("new".utf8))
    let writer = ReaderDownloadWriter(rename: { _, _, _ in
      throw ReaderDownloadError.atomicUnavailable
    })
    XCTAssertThrowsError(try writer.commit(source, named: "book.txt", in: output)) {
      XCTAssertEqual($0 as? ReaderDownloadError, .atomicUnavailable)
      XCTAssertFalse($0.localizedDescription.isEmpty)
    }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
  }

  func testDownloadDefaultStoreCreatesOnlyItsInjectedDownloadsChild() throws {
    let downloads = try downloadDirectory()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    let output = try store.resolve()
    XCTAssertEqual(output, downloads.appendingPathComponent("fanqie", isDirectory: true))
    XCTAssertEqual(try store.resolve(), output)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["fanqie"])
  }

  func testDownloadNativeDownloadsProviderMayReturnASystemDirectoryAlias() throws {
    let downloads = try downloadDirectory()
    let alias = directory.appendingPathComponent("system-downloads-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: downloads)
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { alias })
    // A native system-directory URL may be a container alias. Only that
    // provider is canonicalized; a Dart hint or selected link is not authority.
    XCTAssertEqual(try store.resolve(), downloads.appendingPathComponent("fanqie", isDirectory: true))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["fanqie"])
  }

  func testDownloadNativeBookmarksRoundTripWithoutPickerOrUserDirectories() throws {
    let downloads = try downloadDirectory()
    let selected = try downloadDirectory("selected-real-bookmark")
    let secondRoot = try downloadDirectory("selected-second-real-bookmark")
    let defaults = try downloadDefaults()
    let original = selected.appendingPathComponent("book.txt")
    let bytes = Data("native scoped bookmark original".utf8)
    try bytes.write(to: original)
    let secondFile = secondRoot.appendingPathComponent("book.txt")
    let secondBytes = Data("other original, not a replacement".utf8)
    try secondBytes.write(to: secondFile)
    // Construct scoped fixture URLs with Foundation over directories already
    // owned by this sandbox, rather than opening a real NSOpenPanel. Plain
    // file URLs do not themselves carry the panel's security-scope token.
    let nativeBookmarks = ReaderSecurityScopedDownloadBookmarks()
    let firstGrant = try nativeBookmarks.resolve(nativeBookmarks.create(for: selected))
    let secondGrant = try nativeBookmarks.resolve(nativeBookmarks.create(for: secondRoot))
    XCTAssertFalse(firstGrant.isStale)
    XCTAssertFalse(secondGrant.isStale)
    let first = ReaderDownloadDirectoryStore(defaults: defaults, downloadsDirectory: { downloads })
    _ = try first.remember(firstGrant.directory)
    _ = try first.remember(secondGrant.directory)
    let restarted = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads })
    XCTAssertEqual(try restarted.resolve(), secondRoot)
    let checked = try restarted.check(filePath: original.path)
    XCTAssertTrue(checked.exists)
    XCTAssertEqual(checked.path, original.path)
    XCTAssertEqual(checked.size, Int64(bytes.count))
    let secondChecked = try restarted.check(filePath: secondFile.path)
    XCTAssertTrue(secondChecked.exists)
    XCTAssertEqual(secondChecked.path, secondFile.path)
    XCTAssertEqual(secondChecked.size, Int64(secondBytes.count))
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    XCTAssertEqual(try Data(contentsOf: secondFile), secondBytes)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: downloads.appendingPathComponent("fanqie").path))
  }

  func testDownloadRestartRetainsTwoScopedRootsAndOriginalIdentities() throws {
    let downloads = try downloadDirectory()
    let firstRoot = try downloadDirectory("selected-first")
    let secondRoot = try downloadDirectory("selected-second")
    let defaults = try downloadDefaults()
    let access = DownloadBookmarkFixture()
    let firstFile = firstRoot.appendingPathComponent("same.txt")
    let secondFile = secondRoot.appendingPathComponent("same.txt")
    try Data("first original".utf8).write(to: firstFile)
    try Data("second original".utf8).write(to: secondFile)
    let store = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(firstRoot)
    _ = try store.remember(secondRoot)
    let restarted = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    XCTAssertEqual(try restarted.resolve(), secondRoot)
    for (path, size) in [(firstFile.path, 14), (secondFile.path, 15)] {
      let checked = try restarted.check(filePath: path)
      XCTAssertEqual(checked.path, path)
      XCTAssertEqual(checked.size, Int64(size))
      XCTAssertTrue(checked.exists)
    }
    XCTAssertEqual(try Data(contentsOf: firstFile), Data("first original".utf8))
    XCTAssertEqual(try Data(contentsOf: secondFile), Data("second original".utf8))
    XCTAssertEqual(access.starts, access.stops)
    XCTAssertTrue(access.starts.contains(firstRoot))
    XCTAssertTrue(access.starts.contains(secondRoot))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: downloads.appendingPathComponent("fanqie").path))
  }

  func testDownloadStaleCorruptRevokedOrMovedAuthorityDoesNotFallBack() throws {
    let downloads = try downloadDirectory()
    let selected = try downloadDirectory("selected")
    let defaults = try downloadDefaults()
    let access = DownloadBookmarkFixture()
    let store = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(selected)
    access.stale.insert(selected.path)
    XCTAssertThrowsError(try store.resolve()) {
      XCTAssertEqual($0 as? ReaderDownloadError, .authorityExpired)
    }
    access.stale.removeAll()
    access.denied.insert(selected.path)
    XCTAssertThrowsError(try store.resolve()) {
      XCTAssertEqual($0 as? ReaderDownloadError, .authorityDenied)
    }
    access.denied.removeAll()
    access.moved[selected.path] = downloads
    XCTAssertThrowsError(try store.resolve())
    access.moved.removeAll()
    defaults.set(Data("corrupt stored authorization".utf8),
      forKey: ReaderDownloadDirectoryStore.preferencesKey)
    XCTAssertThrowsError(try store.resolve())
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: downloads.appendingPathComponent("fanqie").path))
    // Explicit selection repairs corrupt state; a resolver never repairs it implicitly.
    XCTAssertEqual(try store.remember(selected), selected)
    XCTAssertEqual(try store.resolve(), selected)
  }

  func testDownloadOldStaleBookmarkCannotBorrowTheCurrentRootsSameName() throws {
    let downloads = try downloadDirectory()
    let firstRoot = try downloadDirectory("old-root")
    let secondRoot = try downloadDirectory("current-root")
    let defaults = try downloadDefaults()
    let access = DownloadBookmarkFixture()
    let store = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(firstRoot)
    _ = try store.remember(secondRoot)
    try Data("old".utf8).write(to: firstRoot.appendingPathComponent("book.txt"))
    try Data("new".utf8).write(to: secondRoot.appendingPathComponent("book.txt"))
    access.stale.insert(firstRoot.path)
    let restarted = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    XCTAssertThrowsError(try restarted.check(
      filePath: firstRoot.appendingPathComponent("book.txt").path))
    XCTAssertTrue(try restarted.check(
      filePath: secondRoot.appendingPathComponent("book.txt").path).exists)
    XCTAssertEqual(access.starts, access.stops)
  }

  func testDownloadMissingSelectedDirectoryIsNotRecreated() throws {
    let downloads = try downloadDirectory()
    let selected = try downloadDirectory("removed-selection")
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads },
      bookmarks: DownloadBookmarkFixture())
    _ = try store.remember(selected)
    try FileManager.default.removeItem(at: selected)
    XCTAssertThrowsError(try store.resolve())
    XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: downloads.appendingPathComponent("fanqie").path))
  }

  func testDownloadHistoryRejectsForeignEscapingLinksAndUnverifiedURIs() throws {
    let downloads = try downloadDirectory()
    let selected = try downloadDirectory("history-root")
    let foreign = try downloadDirectory("history-root-other")
    let access = DownloadBookmarkFixture()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(selected)
    let owned = selected.appendingPathComponent("book.txt")
    try Data("owned original".utf8).write(to: owned)
    let other = foreign.appendingPathComponent("book.txt")
    try Data("same name is not authorization".utf8).write(to: other)
    let outsideDefault = downloads.appendingPathComponent("book.txt")
    try Data("Downloads entitlement is not a general check API".utf8).write(to: outsideDefault)
    let link = selected.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
    for path in [other.path, outsideDefault.path, link.path, "relative/book.txt",
      selected.path + "/../history-root-other/book.txt", "content://media/downloads/17"] {
      XCTAssertThrowsError(try store.check(filePath: path), path)
    }
    for uri in ["content://media/downloads/17", "file://" + owned.path] {
      XCTAssertThrowsError(try store.check(filePath: owned.path, contentUri: uri))
    }
    let empty = selected.appendingPathComponent("empty.txt")
    try Data().write(to: empty)
    XCTAssertFalse(try store.check(filePath: empty.path).exists)
    XCTAssertFalse(try store.check(
      filePath: selected.appendingPathComponent("absent.txt").path).exists)
    XCTAssertEqual(try Data(contentsOf: owned), Data("owned original".utf8))
    XCTAssertEqual(access.starts, access.stops)
  }

  func testDownloadSelectedAndDefaultSymlinkRootsAreRejected() throws {
    let downloads = try downloadDirectory()
    let selected = try downloadDirectory("real-root")
    let link = directory.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: selected)
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads },
      bookmarks: DownloadBookmarkFixture())
    XCTAssertThrowsError(try store.remember(link))
    try FileManager.default.createSymbolicLink(
      at: downloads.appendingPathComponent("fanqie"), withDestinationURL: selected)
    XCTAssertThrowsError(try store.resolve())
  }

  func testDownloadHandlerRunsInBackgroundAndIgnoresDartDirectory() throws {
    let downloads = try downloadDirectory()
    let foreign = try downloadDirectory("dart-directory-is-not-authority")
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      XCTAssertFalse(Thread.isMainThread)
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
    })
    let output = ReaderDownloadOutput(store: store, writer: writer)
    let bytes = Data(repeating: 0x42, count: 131073)
    let source = try file("background-source", bytes)
    let finished = expectation(description: "background download commit")
    output.commit(["id": "job-1", "sourcePath": source.path,
      "fileName": "书.epub", "directory": foreign.path]) { value in
        XCTAssertTrue(Thread.isMainThread)
        let result = value as? [String: Any]
        XCTAssertEqual(result?["status"] as? String, "saved")
        let path = result?["path"] as? String ?? ""
        XCTAssertEqual(path, downloads.appendingPathComponent("fanqie/书.epub").path)
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        finished.fulfill()
      }
    wait(for: [finished], timeout: 10)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
  }

  func testDownloadHandlerExpiredAuthorityCannotUseDartOrDefaultFallback() throws {
    let downloads = try downloadDirectory()
    let selected = try downloadDirectory("expired-handler-root")
    let access = DownloadBookmarkFixture()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(selected)
    access.stale.insert(selected.path)
    let source = try file("expired-handler-source", Data("original bytes".utf8))
    let output = ReaderDownloadOutput(store: store)
    let finished = expectation(description: "expired authority fails explicitly")
    output.commit(["id": "expired", "sourcePath": source.path,
      "fileName": "book.txt", "directory": downloads.path]) { value in
        let result = value as? [String: Any]
        XCTAssertEqual(result?["status"] as? String, "failed")
        XCTAssertTrue((result?["error"] as? String ?? "").contains("授权已过期"))
        finished.fulfill()
      }
    wait(for: [finished], timeout: 10)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
  }

  func testDownloadAndManualExportShareSerializedQueueAndQueuedCancellation() throws {
    let downloads = try downloadDirectory()
    let queue = ReaderExportQueue()
    let source = try file("shared-queue-source", Data("complete original".utf8))
    let target = directory.appendingPathComponent("manual-export.txt")
    var selected: ((URL?) -> Void)?
    let exporter = ReaderFileExporter(window: nil, queue: queue,
      selectDestination: { _, completion in selected = completion })
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    let output = ReaderDownloadOutput(store: store, queue: queue)
    let exported = expectation(description: "manual export without real panel")
    exporter.save(["id": "manual", "filePath": source.path, "fileName": "manual.txt"]) { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
      exported.fulfill()
    }
    XCTAssertNotNil(selected)
    let cancelled = expectation(description: "queued download cancelled")
    output.commit(["id": "queued", "sourcePath": source.path, "fileName": "book.txt"]) { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      cancelled.fulfill()
    }
    queue.cancel("unrelated")
    queue.cancel("queued")
    selected?(target)
    wait(for: [exported, cancelled], timeout: 10)
    XCTAssertEqual(try Data(contentsOf: target), Data("complete original".utf8))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
  }

  func testDownloadQueueCancellationDuringCopyUsesSharedToken() throws {
    let output = try downloadDirectory()
    let queue = ReaderExportQueue()
    let source = try file("shared-copy-source", Data(repeating: 0x61, count: 200000))
    let cancelled = expectation(description: "shared cancellation while copying")
    queue.enqueue(id: "copy", result: { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      cancelled.fulfill()
    }) { request, finish in
      queue.perform({
        var checks = 0
        do {
          _ = try ReaderDownloadWriter().commit(
            source, named: "book.txt", in: output, check: {
              checks += 1
              if checks == 3 { DispatchQueue.main.sync { queue.cancel("copy") } }
              try request.check()
            }, publish: { try request.publish($0) })
          return ["status": "saved"]
        } catch {
          XCTAssertEqual(error as? ReaderFileError, .cancelled)
          return ["status": "cancelled"]
        }
      }, completion: finish)
    }
    wait(for: [cancelled], timeout: 10)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
  }

  func testDownloadHandlerKeepsSavedResultWhenCancelArrivesBeforeReply() throws {
    let downloads = try downloadDirectory()
    let queue = ReaderExportQueue()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    var cancellationDelivered = false
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
      DispatchQueue.main.async {
        queue.cancel("committed")
        cancellationDelivered = true
      }
    })
    let output = ReaderDownloadOutput(store: store, queue: queue, writer: writer)
    let source = try file("native-committed-source", Data("complete original".utf8))
    let finished = expectation(description: "committed success before reply")
    output.commit(["id": "committed", "sourcePath": source.path, "fileName": "book.txt"]) { value in
      XCTAssertTrue(cancellationDelivered)
      let result = value as? [String: Any]
      XCTAssertEqual(result?["status"] as? String, "saved")
      let path = result?["path"] as? String ?? ""
      XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), Data("complete original".utf8))
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
  }

  func testDownloadActiveCancellationBeforeCopyReturnsCancelled() throws {
    let downloads = try downloadDirectory()
    let resolving = expectation(description: "active worker resolving directory")
    let release = DispatchSemaphore(value: 0)
    let queue = ReaderExportQueue()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: {
        XCTAssertFalse(Thread.isMainThread)
        resolving.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        return downloads
      })
    let output = ReaderDownloadOutput(store: store, queue: queue)
    let source = try file("active-cancel-source", Data("must survive".utf8))
    let finished = expectation(description: "active cancellation")
    output.commit(["id": "active-cancel", "sourcePath": source.path,
      "fileName": "book.txt"]) { value in
        XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
        finished.fulfill()
      }
    wait(for: [resolving], timeout: 10)
    queue.cancel("active-cancel")
    release.signal()
    wait(for: [finished], timeout: 10)
    let outputRoot = downloads.appendingPathComponent("fanqie")
    if FileManager.default.fileExists(atPath: outputRoot.path) {
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputRoot.path).isEmpty)
    }
    XCTAssertEqual(try Data(contentsOf: source), Data("must survive".utf8))
  }

  func testDownloadQueueRejectsDuplicateIDsAndForgetsFinishedCancellation() throws {
    let queue = ReaderExportQueue()
    var firstFinish: ReaderExportQueue.Completion?
    let first = expectation(description: "cancelled first request")
    queue.enqueue(id: "reused", result: { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      first.fulfill()
    }) { request, finish in
      firstFinish = finish
      request.onCancel = {
        do {
          try request.check()
          XCTFail("A cancelled request must reject further work")
        } catch {
          XCTAssertEqual(error as? ReaderFileError, .cancelled)
        }
      }
    }
    let duplicate = expectation(description: "duplicate ID rejected")
    queue.enqueue(id: "reused", result: { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "failed")
      duplicate.fulfill()
    }) { _, _ in XCTFail("A duplicate ID must not start") }
    queue.cancel("reused")
    firstFinish?(["status": "cancelled"])
    let resumed = expectation(description: "fresh request ID may resume")
    queue.enqueue(id: "reused", result: { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
      resumed.fulfill()
    }) { request, finish in
      do {
        try request.check()
        finish(["status": "saved"])
      } catch {
        XCTFail("A fresh request must not inherit cancellation: \(error)")
        finish(["status": "failed", "error": error.localizedDescription])
      }
    }
    queue.cancel("already-finished")
    wait(for: [first, duplicate, resumed], timeout: 3)
  }

  private func cancelAndPulseMain(
    _ queue: ReaderExportQueue, id: String, barrier: DownloadIOBarrier,
    cancelled: XCTestExpectation, heartbeat: XCTestExpectation
  ) {
    // The watchdog is independent of Cocoa and the copy worker. Even the old
    // filesystem-held lock must unblock when this bounded watchdog releases.
    DispatchQueue.global(qos: .userInitiated).async { barrier.releaseAfterHeartbeat() }
    DispatchQueue.main.async {
      queue.cancel(id)
      cancelled.fulfill()
      DispatchQueue.main.async {
        barrier.pulse()
        heartbeat.fulfill()
      }
    }
  }

  func testDownloadCancellationBeforePublicationAdmissionNeverRenames() throws {
    let output = try downloadDirectory()
    let source = try file("pre-admission-source", Data("complete source".utf8))
    let queue = ReaderExportQueue()
    let barrier = DownloadIOBarrier()
    defer { barrier.releaseFromBackground() }
    let entered = expectation(description: "before publication admission")
    let cancelled = expectation(description: "cancel entry returned")
    let heartbeat = expectation(description: "main heartbeat")
    let finished = expectation(description: "cancelled without publication")
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      barrier.recordPublication()
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
    })
    queue.enqueue(id: "pre-admission", result: { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      finished.fulfill()
    }) { request, finish in
      queue.perform({
        do {
          _ = try writer.commit(source, named: "book.txt", in: output,
            check: { try request.check() }, publish: { operation in
              entered.fulfill()
              guard barrier.waitForRelease() else { throw ReaderDownloadError.atomicUnavailable }
              try request.publish(operation)
            })
          return ["status": "saved"]
        } catch {
          XCTAssertEqual(error as? ReaderFileError, .cancelled)
          return ["status": "cancelled"]
        }
      }, completion: finish)
    }
    wait(for: [entered], timeout: 5)
    cancelAndPulseMain(queue, id: "pre-admission", barrier: barrier,
      cancelled: cancelled, heartbeat: heartbeat)
    wait(for: [cancelled, heartbeat, finished], timeout: 10)
    XCTAssertFalse(barrier.watchdogReleased)
    XCTAssertEqual(barrier.publications, 0)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), Data("complete source".utf8))
  }

  func testDownloadBlockedPublicationAllowsMainCancellationAndHeartbeat() throws {
    let downloads = try downloadDirectory()
    let source = try file("admitted-source", Data("complete admitted source".utf8))
    let queue = ReaderExportQueue()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    let barrier = DownloadIOBarrier()
    defer { barrier.releaseFromBackground() }
    let entered = expectation(description: "worker blocked inside admitted volume operation")
    let cancelled = expectation(description: "cancel entry returned before volume release")
    let heartbeat = expectation(description: "next main turn before volume release")
    let committed = expectation(description: "admitted operation saved")
    let following = expectation(description: "queued follow-up saved")
    var firstReplies = 0, followingReplies = 0
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      XCTAssertFalse(Thread.isMainThread)
      barrier.recordPublication()
      entered.fulfill()
      guard barrier.waitForRelease() else { throw ReaderDownloadError.atomicUnavailable }
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
    })
    let output = ReaderDownloadOutput(store: store, queue: queue, writer: writer)
    let normal = ReaderDownloadOutput(store: store, queue: queue)
    output.commit(["id": "admitted", "sourcePath": source.path, "fileName": "book.txt"]) { value in
      XCTAssertTrue(Thread.isMainThread)
      firstReplies += 1
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
      committed.fulfill()
    }
    wait(for: [entered], timeout: 5)
    normal.commit(["id": "follow-up", "sourcePath": source.path,
      "fileName": "following.txt"]) { value in
        followingReplies += 1
        XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
        following.fulfill()
      }
    cancelAndPulseMain(queue, id: "admitted", barrier: barrier,
      cancelled: cancelled, heartbeat: heartbeat)
    wait(for: [cancelled, heartbeat, committed, following], timeout: 10)
    XCTAssertFalse(barrier.watchdogReleased,
      "Cocoa cancellation/heartbeat needed a watchdog to unblock volume I/O")
    XCTAssertEqual(barrier.publications, 1)
    XCTAssertEqual(firstReplies, 1)
    XCTAssertEqual(followingReplies, 1)
    let reused = expectation(description: "finished admitted ID can be reused")
    var reusedReplies = 0
    normal.commit(["id": "admitted", "sourcePath": source.path,
      "fileName": "reused.txt"]) { value in
        reusedReplies += 1
        XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
        reused.fulfill()
      }
    wait(for: [reused], timeout: 5)
    XCTAssertEqual(reusedReplies, 1)
    let root = downloads.appendingPathComponent("fanqie")
    for name in ["book.txt", "following.txt", "reused.txt"] {
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)),
        Data("complete admitted source".utf8))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
  }

  private func assertCancelledFailedPublication(colliding: Bool) throws {
    let downloads = try downloadDirectory()
    let source = try file("failed-admission-source", Data("complete source".utf8))
    let queue = ReaderExportQueue()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    let root = try store.resolve()
    let existing = root.appendingPathComponent("book.txt")
    let oldBytes = Data("existing complete file".utf8)
    if colliding { try oldBytes.write(to: existing) }
    let barrier = DownloadIOBarrier()
    defer { barrier.releaseFromBackground() }
    let entered = expectation(description: "failed volume operation entered")
    let cancelled = expectation(description: "failed publication cancel entry")
    let heartbeat = expectation(description: "failed publication main heartbeat")
    let finished = expectation(description: "failed admitted operation cancelled")
    let following = expectation(description: "work queued behind failure")
    var replies = 0, nextReplies = 0
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      let attempts = barrier.recordPublication()
      guard attempts == 1 else {
        XCTFail("Cancellation must prevent another publication attempt")
        throw ReaderDownloadError.atomicUnavailable
      }
      entered.fulfill()
      guard barrier.waitForRelease() else { throw ReaderDownloadError.atomicUnavailable }
      if colliding {
        // Real exclusive rename must report EEXIST and preserve the old bytes.
        try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
      } else {
        throw ReaderDownloadError.atomicUnavailable
      }
    })
    let output = ReaderDownloadOutput(store: store, queue: queue, writer: writer)
    let normal = ReaderDownloadOutput(store: store, queue: queue)
    output.commit(["id": "failed-admission", "sourcePath": source.path,
      "fileName": "book.txt"]) { value in
        replies += 1
        XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
        finished.fulfill()
      }
    wait(for: [entered], timeout: 5)
    normal.commit(["id": "after-failure", "sourcePath": source.path,
      "fileName": "following.txt"]) { value in
        nextReplies += 1
        XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
        following.fulfill()
      }
    cancelAndPulseMain(queue, id: "failed-admission", barrier: barrier,
      cancelled: cancelled, heartbeat: heartbeat)
    wait(for: [cancelled, heartbeat, finished, following], timeout: 10)
    XCTAssertFalse(barrier.watchdogReleased)
    XCTAssertEqual(barrier.publications, 1)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(nextReplies, 1)
    let reused = expectation(description: "failed publication ID is fresh on reuse")
    var reusedReplies = 0
    normal.commit(["id": "failed-admission", "sourcePath": source.path,
      "fileName": "reused.txt"]) { value in
        reusedReplies += 1
        XCTAssertEqual((value as? [String: Any])?["status"] as? String, "saved")
        reused.fulfill()
      }
    wait(for: [reused], timeout: 5)
    XCTAssertEqual(reusedReplies, 1)
    if colliding { XCTAssertEqual(try Data(contentsOf: existing), oldBytes) }
    else { XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path)) }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent("book (2).txt").path))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("following.txt")),
      Data("complete source".utf8))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("reused.txt")),
      Data("complete source".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count,
      colliding ? 3 : 2)
  }

  func testDownloadCancelledFailedPublicationDoesNotRetryOrLeakQueueState() throws {
    try assertCancelledFailedPublication(colliding: false)
  }

  func testDownloadCancelledCollidingPublicationDoesNotRetryOrOverwrite() throws {
    try assertCancelledFailedPublication(colliding: true)
  }

  func testDownloadCancellationAfterCollisionPreventsNextPublication() throws {
    let output = try downloadDirectory()
    let source = try file("post-collision-source", Data("new complete source".utf8))
    let target = output.appendingPathComponent("book.txt")
    try Data("old complete file".utf8).write(to: target)
    let queue = ReaderExportQueue()
    let barrier = DownloadIOBarrier()
    defer { barrier.releaseFromBackground() }
    let collided = expectation(description: "first publication already failed with EEXIST")
    let cancelled = expectation(description: "cancel after collision")
    let heartbeat = expectation(description: "main heartbeat after collision")
    let finished = expectation(description: "cancelled before retry")
    let writer = ReaderDownloadWriter(rename: { descriptor, staging, name in
      barrier.recordPublication()
      try ReaderDownloadWriter.renameExclusive(descriptor, staging, name)
    })
    queue.enqueue(id: "post-collision", result: { value in
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "cancelled")
      finished.fulfill()
    }) { request, finish in
      queue.perform({
        do {
          _ = try writer.commit(source, named: "book.txt", in: output,
            check: { try request.check() }, publish: { operation in
              do { try request.publish(operation) }
              catch let error as NSError
                where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                // Freeze AFTER failed publication, before the writer can
                // inspect the collision and admit its next candidate.
                collided.fulfill()
                guard barrier.waitForRelease() else { throw ReaderDownloadError.atomicUnavailable }
                throw error
              }
            })
          return ["status": "saved"]
        } catch {
          XCTAssertEqual(error as? ReaderFileError, .cancelled)
          return ["status": "cancelled"]
        }
      }, completion: finish)
    }
    wait(for: [collided], timeout: 5)
    cancelAndPulseMain(queue, id: "post-collision", barrier: barrier,
      cancelled: cancelled, heartbeat: heartbeat)
    wait(for: [cancelled, heartbeat, finished], timeout: 10)
    XCTAssertFalse(barrier.watchdogReleased)
    XCTAssertEqual(barrier.publications, 1)
    XCTAssertEqual(try Data(contentsOf: target), Data("old complete file".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["book.txt"])
  }

  func testDownloadDirectorySelectionsUseOrderedWorkerAndRetainScopeWhileQueued() throws {
    let downloads = try downloadDirectory()
    let prior = try downloadDirectory("prior-selection")
    let first = try downloadDirectory("first-selection")
    let second = try downloadDirectory("second-selection")
    let defaults = try downloadDefaults()
    let access = DownloadSelectionBookmarks()
    defer { access.onCreate = nil }
    let store = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(prior)
    access.onCreate = { directory in
      XCTAssertFalse(Thread.isMainThread, "Directory/bookmark selection I/O must run off Cocoa")
      XCTAssertEqual(access.activeScopes(directory), 1)
    }
    let queue = ReaderExportQueue()
    let output = ReaderDownloadOutput(store: store, queue: queue)
    let barrier = DownloadIOBarrier()
    defer { barrier.releaseFromBackground() }
    let entered = expectation(description: "ordered worker occupied")
    let unblocked = expectation(description: "prior ordered work finished")
    queue.perform({
      entered.fulfill()
      guard barrier.waitForRelease() else { return ["status": "failed"] }
      return ["status": "saved"]
    }, completion: { value in
      XCTAssertEqual(value["status"] as? String, "saved")
      unblocked.fulfill()
    })
    wait(for: [entered], timeout: 5)
    let selected = expectation(description: "ordered selection callbacks")
    selected.expectedFulfillmentCount = 2
    output.rememberDirectory(first) { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["path"] as? String, first.path)
      selected.fulfill()
    }
    output.rememberDirectory(second) { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["path"] as? String, second.path)
      selected.fulfill()
    }
    XCTAssertEqual(access.activeScopes(first), 1)
    XCTAssertEqual(access.activeScopes(second), 1)
    XCTAssertEqual(defaults.dictionary(
      forKey: ReaderDownloadDirectoryStore.preferencesKey)?["current"] as? String, prior.path)
    let resolved = expectation(description: "resolve ordered after both selections")
    output.getDirectory { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["path"] as? String, second.path)
      resolved.fulfill()
    }
    let heartbeat = expectation(description: "main runs while selections wait")
    DispatchQueue.global(qos: .userInitiated).async { barrier.releaseAfterHeartbeat() }
    DispatchQueue.main.async { barrier.pulse(); heartbeat.fulfill() }
    wait(for: [heartbeat, unblocked, selected, resolved], timeout: 10)
    XCTAssertFalse(barrier.watchdogReleased)
    XCTAssertEqual(access.created, [prior, first, second])
    XCTAssertEqual(access.activeScopes(first), 0)
    XCTAssertEqual(access.activeScopes(second), 0)
    XCTAssertEqual(access.activeScopes(prior), 0)
    let restarted = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    XCTAssertEqual(try restarted.resolve(), second)
    let roots = defaults.dictionary(
      forKey: ReaderDownloadDirectoryStore.preferencesKey)?["bookmarks"] as? [String: Any]
    XCTAssertNotNil(roots?[prior.path] as? Data)
    XCTAssertNotNil(roots?[first.path] as? Data)
    XCTAssertNotNil(roots?[second.path] as? Data)
  }

  func testDownloadFailedDirectorySelectionReleasesScopeAndKeepsPreviousAuthority() throws {
    let downloads = try downloadDirectory()
    let prior = try downloadDirectory("prior-authority")
    let failing = try downloadDirectory("failing-selection")
    let defaults = try downloadDefaults()
    let access = DownloadSelectionBookmarks()
    defer { access.onCreate = nil }
    let store = ReaderDownloadDirectoryStore(
      defaults: defaults, downloadsDirectory: { downloads }, bookmarks: access)
    _ = try store.remember(prior)
    access.onCreate = { directory in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertEqual(access.activeScopes(directory), 1)
      throw ReaderDownloadError.invalidBookmark
    }
    let output = ReaderDownloadOutput(store: store)
    let failed = expectation(description: "selection creation failed")
    output.rememberDirectory(failing) { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["status"] as? String, "failed")
      failed.fulfill()
    }
    wait(for: [failed], timeout: 5)
    XCTAssertEqual(access.activeScopes(failing), 0)
    XCTAssertEqual(defaults.dictionary(
      forKey: ReaderDownloadDirectoryStore.preferencesKey)?["current"] as? String, prior.path)
    XCTAssertEqual(try store.resolve(), prior)
    XCTAssertEqual(access.activeScopes(prior), 0)
    let roots = defaults.dictionary(
      forKey: ReaderDownloadDirectoryStore.preferencesKey)?["bookmarks"] as? [String: Any]
    XCTAssertNil(roots?[failing.path])
  }

  func testDownloadNativeMetadataHandlerFailsClosedForMalformedOrForeignRequests() throws {
    let downloads = try downloadDirectory()
    let store = ReaderDownloadDirectoryStore(
      defaults: try downloadDefaults(), downloadsDirectory: { downloads })
    let output = ReaderDownloadOutput(store: store)
    let foreign = try file("foreign-history.txt", Data("not downloaded here".utf8))
    let requests: [[String: Any]] = [
      [:], ["filePath": 42], ["filePath": foreign.path, "contentUri": ""],
      ["filePath": foreign.path, "contentUri": "content://unverified/17"],
      ["filePath": foreign.path, "contentUri": 42],
    ]
    let finished = expectation(description: "invalid native metadata requests")
    finished.expectedFulfillmentCount = requests.count
    for args in requests {
      output.checkFile(args) { value in
        XCTAssertTrue(Thread.isMainThread)
        let result = value as? [String: Any]
        XCTAssertEqual(result?["exists"] as? Bool, false)
        XCTAssertEqual((result?["size"] as? NSNumber)?.intValue, 0)
        finished.fulfill()
      }
    }
    wait(for: [finished], timeout: 10)
    XCTAssertEqual(try Data(contentsOf: foreign), Data("not downloaded here".utf8))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
  }

  func testUnknownBatteryIsNotAFabricatedPercentage() {
    let level = ReaderNativePlatform.batteryLevel()
    XCTAssertTrue(level == -1 || (0...100).contains(level))
  }

  private func silentWav(milliseconds: Int = 250) -> Data {
    let count = milliseconds * 16
    var bytes = [UInt8](repeating: 0, count: 44 + count)
    func text(_ offset: Int, _ value: String) {
      for (i, byte) in value.utf8.enumerated() { bytes[offset + i] = byte }
    }
    func word(_ offset: Int, _ value: Int, _ size: Int) {
      for i in 0..<size { bytes[offset + i] = UInt8((value >> (i * 8)) & 255) }
    }
    text(0, "RIFF"); word(4, bytes.count - 8, 4); text(8, "WAVE")
    text(12, "fmt "); word(16, 16, 4); word(20, 1, 2); word(22, 1, 2)
    word(24, 8000, 4); word(28, 16000, 4); word(32, 2, 2); word(34, 16, 2)
    text(36, "data"); word(40, count, 4)
    return Data(bytes)
  }

  func testKeychainRoundTripUsesOnlyAnIsolatedAccount() throws {
    let service = "com.fanqie.reader.native-tests.\(UUID().uuidString)"
    let account = "isolated-tts-test"
    defer { try? ReaderKeychain.write("", service: service, account: account) }
    XCTAssertNil(try ReaderKeychain.read(service: service, account: account))
    try ReaderKeychain.write("synthetic-not-a-real-key", service: service, account: account)
    XCTAssertEqual(try ReaderKeychain.read(service: service, account: account), "synthetic-not-a-real-key")
    try ReaderKeychain.write("updated-synthetic-key", service: service, account: account)
    XCTAssertEqual(try ReaderKeychain.read(service: service, account: account), "updated-synthetic-key")
    try ReaderKeychain.write("", service: service, account: account)
    XCTAssertNil(try ReaderKeychain.read(service: service, account: account))
  }

  func testPlaybackRejectsForeignLinksMalformedAudioAndInvalidState() throws {
    let playback = ReaderPlayback(roots: [directory], mediaControls: false,
      observeOutputChanges: false) { _, _ in XCTFail("Rejected audio must not complete") }
    let valid = try file("tts_1-1-1-1.wav", silentWav())
    XCTAssertTrue(playback.validateAudio(valid))
    let foreign = try file("original.wav", silentWav())
    XCTAssertFalse(playback.validateAudio(foreign))
    let link = directory.appendingPathComponent("tts_1-1-1-2.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
    XCTAssertFalse(playback.validateAudio(link))
    let malformed = try file("tts_1-1-1-3.mp3", Data(repeating: 0x41, count: 80))
    XCTAssertFalse(playback.play(id: "invalid", file: malformed))
    XCTAssertFalse(playback.pauseAudio(id: "wrong"))
    XCTAssertFalse(playback.resumeAudio(id: "wrong"))
    XCTAssertFalse(playback.setVolume(.nan))
    XCTAssertFalse(playback.setVolume(2))
    XCTAssertFalse(playback.speak(id: "invalid", text: "", rate: 1))
    XCTAssertTrue(playback.stop())
    playback.release()
    XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
  }

  func testSilentNativeAudioPauseResumeAndCompletionAreTokenScoped() throws {
    guard ReaderPlayback.hasOutputDevice else { throw XCTSkip("没有音频输出设备；不是播放通过") }
    var events = [(String, String)]()
    let completed = expectation(description: "native decoded silent WAV")
    let playback = ReaderPlayback(roots: [directory], mediaControls: false,
      observeOutputChanges: false) { method, args in
        events.append((method, args["id"] as? String ?? ""))
        if method == "onAudioComplete" { completed.fulfill() }
      }
    let audio = try file("tts_1-2-3-4.wav", silentWav())
    XCTAssertTrue(playback.play(id: "current", file: audio))
    XCTAssertTrue(playback.pauseAudio(id: "current"))
    XCTAssertFalse(playback.stop(id: "stale-token"))
    XCTAssertEqual(playback.playbackState()["id"] as? String, "current")
    XCTAssertTrue(playback.resumeAudio(id: "current"))
    wait(for: [completed], timeout: 5)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.0, "onAudioComplete")
    XCTAssertEqual(events.first?.1, "current")
    XCTAssertFalse(playback.playbackState()["playing"] as? Bool ?? true)
    playback.release()
  }

  // Generated from silence with ffmpeg; no novel or user audio is embedded.
  func testSilentNativeMp3CodecCompletes() throws {
    guard ReaderPlayback.hasOutputDevice else { throw XCTSkip("没有音频输出设备；不是 MP3 播放通过") }
    let done = expectation(description: "native decoded silent MP3")
    let playback = ReaderPlayback(roots: [directory], mediaControls: false,
      observeOutputChanges: false) { method, _ in
        if method == "onAudioComplete" { done.fulfill() }
      }
    let bytes = try XCTUnwrap(Data(base64Encoded: "//NExAAAAANIAAAAAExBTUU0LjBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExFMAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKYAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQu//NExKwAAANIAAAAADBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//NExKwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//NExKwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"))
    let audio = try file("tts_9-8-7-6.mp3", bytes)
    XCTAssertTrue(playback.play(id: "mp3-test", file: audio))
    wait(for: [done], timeout: 5)
    playback.release()
  }

  func testReplacedSleepDeadlineEmitsOnlyTheCurrentDeadline() {
    let expired = expectation(description: "current deadline")
    let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 100
    var calls = 0
    let playback = ReaderPlayback(roots: [directory], mediaControls: false,
      observeOutputChanges: false) { method, args in
        if method == "onAudioSleepTimer" {
          calls += 1
          XCTAssertEqual((args["deadline"] as? NSNumber)?.int64Value, deadline)
          expired.fulfill()
        }
      }
    XCTAssertTrue(playback.setDeadline(deadline - 40))
    XCTAssertTrue(playback.setDeadline(deadline))
    wait(for: [expired], timeout: 3)
    XCTAssertEqual(calls, 1)
    playback.release()
  }

  func testImmersiveAudioValidationProbeDiskAndNamedSecretAccount() throws {
    let playback = ReaderPlayback(roots: [directory], mediaControls: false,
      observeOutputChanges: false) { _, _ in }
    let hashName = String(repeating: "a1b2c3d4", count: 8) + ".mp3"
    let hashWavName = String(repeating: "0f1e2d3c", count: 8) + ".wav"
    let previewName = "immersive_preview_-123456.mp3"
    let wavBytes = silentWav(milliseconds: 300)
    let hashFile = try file(hashName, wavBytes)
    let hashWavFile = try file(hashWavName, wavBytes)
    let previewFile = try file(previewName, wavBytes)
    let badShortHash = try file("deadbeef.mp3", wavBytes)
    let foreignFile = try file("user_voice.mp3", wavBytes)

    XCTAssertTrue(playback.validateAudio(hashFile))
    XCTAssertTrue(playback.validateAudio(hashWavFile))
    XCTAssertTrue(playback.validateAudio(previewFile))
    XCTAssertFalse(playback.validateAudio(badShortHash))
    XCTAssertFalse(playback.validateAudio(foreignFile))

    let tmpWav = try file("job_probe_a1_f1.tmp", wavBytes)
    let probed = ReaderPlayback.probeAudioDuration(file: tmpWav)
    XCTAssertEqual(probed["valid"] as? Bool, true)
    XCTAssertEqual(probed["mime"] as? String, "audio/wav")
    let durationMs = (probed["durationMs"] as? NSNumber)?.intValue ?? 0
    XCTAssertGreaterThanOrEqual(durationMs, 250)
    XCTAssertLessThanOrEqual(durationMs, 350)

    let badTmp = try file("corrupt_probe.tmp", Data(repeating: 0x55, count: 64))
    let badProbed = ReaderPlayback.probeAudioDuration(file: badTmp)
    XCTAssertEqual(badProbed["valid"] as? Bool, false)
    XCTAssertEqual((badProbed["durationMs"] as? NSNumber)?.intValue, 0)

    let missingSubdir = directory.appendingPathComponent("not-created-yet/audio").path
    XCTAssertGreaterThan(ReaderPlayback.freeDiskBytes(at: missingSubdir), 0)

    XCTAssertTrue(ReaderKeychain.isValidAccount("immersive_text_model_api_key_tm_minimax_m31_flash_v1"))
    XCTAssertTrue(ReaderKeychain.isValidAccount("webdav_password_v1"))
    XCTAssertFalse(ReaderKeychain.isValidAccount(""))
    XCTAssertFalse(ReaderKeychain.isValidAccount("bad\0key"))
    XCTAssertFalse(ReaderKeychain.isValidAccount(String(repeating: "x", count: 257)))
    playback.release()
  }

  func testImmersivePreloadSeamlessTransitionWithGapAndPlaybackRate() throws {
    guard ReaderPlayback.hasOutputDevice else { throw XCTSkip("没有音频输出设备；不是播放通过") }
    var events = [(String, [String: Any])]()
    let transitioned = expectation(description: "seamless preload transition")
    let finishedSecond = expectation(description: "second preloaded segment completed")
    let playback = ReaderPlayback(roots: [directory], mediaControls: false,
      observeOutputChanges: false) { method, args in
        events.append((method, args))
        if method == "onAudioTransition" { transitioned.fulfill() }
        if method == "onAudioComplete", args["id"] as? String == "immersive:seg2" {
          finishedSecond.fulfill()
        }
      }
    let seg1 = try file(String(repeating: "11", count: 32) + ".wav", silentWav(milliseconds: 400))
    let seg2 = try file(String(repeating: "22", count: 32) + ".wav", silentWav(milliseconds: 220))

    XCTAssertTrue(playback.play(id: "immersive:seg1", file: seg1, rate: 1.5, preservePitch: true, startPositionMs: 0))
    XCTAssertTrue(playback.setPlaybackRate(1.25, preservePitch: true))
    let pos = playback.audioPosition()
    XCTAssertEqual(pos["id"] as? String, "immersive:seg1")
    XCTAssertEqual(pos["playing"] as? Bool, true)
    XCTAssertGreaterThanOrEqual((pos["durationMs"] as? NSNumber)?.intValue ?? 0, 350)

    XCTAssertTrue(playback.preloadNext(
      afterID: "immersive:seg1", id: "immersive:seg2", file: seg2,
      rate: 1.25, preservePitch: true, gapMs: 80))

    wait(for: [transitioned, finishedSecond], timeout: 6)
    let transitionEvent = events.first(where: { $0.0 == "onAudioTransition" })
    XCTAssertEqual(transitionEvent?.1["completedId"] as? String, "immersive:seg1")
    XCTAssertEqual(transitionEvent?.1["startedId"] as? String, "immersive:seg2")
    XCTAssertFalse(events.contains(where: { $0.0 == "onAudioComplete" && ($0.1["id"] as? String) == "immersive:seg1" }))
    playback.release()
  }
}

/// Deterministic stale/denied/moved bookmark fixtures. Real bookmark creation
/// and restoration are also exercised above, exclusively in our temporary root.
private final class DownloadBookmarkFixture: ReaderDownloadBookmarkAccess {
  var stale = Set<String>()
  var denied = Set<String>()
  var moved = [String: URL]()
  var starts = [URL]()
  var stops = [URL]()

  func create(for directory: URL) throws -> Data { Data(directory.path.utf8) }

  func resolve(_ data: Data) throws -> ReaderResolvedDownloadBookmark {
    guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else {
      throw ReaderDownloadError.invalidBookmark
    }
    return ReaderResolvedDownloadBookmark(
      directory: moved[path] ?? URL(fileURLWithPath: path, isDirectory: true),
      isStale: stale.contains(path))
  }

  func start(_ directory: URL) -> Bool {
    guard !denied.contains(directory.path) else { return false }
    starts.append(directory)
    return true
  }

  func stop(_ directory: URL) { stops.append(directory) }
}

private final class DownloadRaceResults {
  private let lock = NSLock()
  private var saved = [(URL, Data)]()
  private var failures = [Error]()
  var files: [(URL, Data)] {
    lock.lock()
    defer { lock.unlock() }
    return saved
  }
  var errors: [Error] {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }
  func append(_ target: URL, bytes: Data) {
    lock.lock()
    defer { lock.unlock() }
    saved.append((target, bytes))
  }
  func fail(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    failures.append(error)
  }
}

/// A fake stalled volume, not a physical-latency benchmark. Both the worker's
/// wait and the independent watchdog are bounded; cleanup never needs Cocoa.
private final class DownloadIOBarrier {
  private let release = DispatchSemaphore(value: 0)
  private let heartbeat = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var timedOut = false
  private var attempts = 0

  func waitForRelease() -> Bool { release.wait(timeout: .now() + 5) == .success }
  func pulse() { heartbeat.signal() }

  func releaseAfterHeartbeat() {
    let progressed = heartbeat.wait(timeout: .now() + 2) == .success
    lock.lock()
    timedOut = !progressed
    lock.unlock()
    release.signal()
  }

  func releaseFromBackground() {
    DispatchQueue.global(qos: .userInitiated).async { self.release.signal() }
  }

  @discardableResult
  func recordPublication() -> Int {
    lock.lock()
    defer { lock.unlock() }
    attempts += 1
    return attempts
  }

  var watchdogReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return timedOut
  }

  var publications: Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts
  }
}

private final class DownloadSelectionBookmarks: ReaderDownloadBookmarkAccess {
  var onCreate: ((URL) throws -> Void)?
  private let lock = NSLock()
  private var active = [String: Int]()
  private var creations = [URL]()

  func create(for directory: URL) throws -> Data {
    try onCreate?(directory)
    lock.lock()
    creations.append(directory)
    lock.unlock()
    return Data(directory.path.utf8)
  }

  func resolve(_ data: Data) throws -> ReaderResolvedDownloadBookmark {
    guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else {
      throw ReaderDownloadError.invalidBookmark
    }
    return ReaderResolvedDownloadBookmark(
      directory: URL(fileURLWithPath: path, isDirectory: true), isStale: false)
  }

  func start(_ directory: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    active[directory.path, default: 0] += 1
    return true
  }

  func stop(_ directory: URL) {
    lock.lock()
    defer { lock.unlock() }
    active[directory.path, default: 0] -= 1
  }

  func activeScopes(_ directory: URL) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return active[directory.path, default: 0]
  }

  var created: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return creations
  }
}
