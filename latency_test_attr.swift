import Foundation
import AppKit

let start = DispatchTime.now()

let fullText = NSMutableAttributedString()
let propFont = NSFont(name: "Charter", size: 18) ?? NSFont.systemFont(ofSize: 18)
let defaultTextColor = NSColor.textColor
let attributes: [NSAttributedString.Key: Any] = [
    .font: propFont,
    .foregroundColor: defaultTextColor
]

for _ in 0..<24 {
    let str = String(repeating: "a", count: 80)
    let processedLineAttrs = NSMutableAttributedString(string: str, attributes: attributes)
    fullText.append(processedLineAttrs)
    fullText.append(NSAttributedString(string: "\n", attributes: attributes))
}

let end = DispatchTime.now()
let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
let timeInterval = Double(nanoTime) / 1_000_000_000
print("Time to build 24x80 attributed string: \(timeInterval) seconds")
