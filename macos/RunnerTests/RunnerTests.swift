import Cocoa
import FlutterMacOS
import XCTest
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
}
