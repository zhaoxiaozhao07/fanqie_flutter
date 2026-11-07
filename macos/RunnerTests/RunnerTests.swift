import Cocoa
import FlutterMacOS
import XCTest
import AVFoundation
@testable import FanqieReader

final class RunnerTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
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
}
