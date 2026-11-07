import Foundation

// Generate offline, one-to-one display mappings from the system ICU transform.
// Multi-character conversions are intentionally omitted to preserve UTF-16
// source coordinates. This is a character display aid, not linguistic editing.
var maps: [String: String] = [:]
for (name, transform) in [("simplified", "Hant-Hans"), ("traditional", "Hans-Hant")] {
    var pairs = ""
    for range in [0x3400...0x9FFF, 0xF900...0xFAFF] {
        for code in range {
            guard let scalar = UnicodeScalar(code) else { continue }
            let source = String(scalar)
            guard let target = source.applyingTransform(
                StringTransform(rawValue: transform), reverse: false),
                  target != source, target.utf16.count == 1 else { continue }
            pairs += source + target
        }
    }
    maps[name] = pairs
}
let data = try JSONSerialization.data(withJSONObject: maps, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
