import Cocoa

/// Observes one reader window without consuming, scaling or redispatching input.
final class ReaderScrollInput {
  private weak var window: NSWindow?
  private let notify: ([String: Any]) -> Void
  private var monitor: Any?

  init(window: NSWindow, notify: @escaping ([String: Any]) -> Void) {
    self.window = window
    self.notify = notify
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      self?.forward(event, from: event.window) ?? event
    }
  }

  deinit {
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
  }

  func forward(_ event: NSEvent, from sourceWindow: NSWindow?) -> NSEvent {
    guard let window = window, sourceWindow === window,
          let input = Self.notification(for: event) else { return event }
    // Invoke the shared channel before AppKit forwards the unchanged event to
    // Flutter. Dart still fails closed if pointer/channel delivery is reordered.
    notify(input)
    return event
  }

  static func notification(for event: NSEvent) -> [String: Any]? {
    guard event.type == .scrollWheel,
          let micros = timestampMicros(event.timestamp) else { return nil }
    return ["timestampMicros": micros, "precise": event.hasPreciseScrollingDeltas]
  }

  static func timestampMicros(_ timestamp: TimeInterval) -> Int64? {
    // Pinned FlutterViewController 3.47.9: static_cast<size_t>(seconds * 1e6).
    let micros = (timestamp * 1_000_000).rounded(.towardZero)
    guard timestamp.isFinite, micros.isFinite, micros >= 1,
          micros < Double(Int64.max) else { return nil }
    return Int64(micros)
  }
}
