import Foundation
import AppKit

let font = NSFont.systemFont(ofSize: 14)
let attrStr = NSAttributedString(string: "Hello", attributes: [.font: font])
print(attrStr.size().width)

let kerned = NSAttributedString(string: " ", attributes: [.font: font, .kern: 50.0])
print(kerned.size().width)
