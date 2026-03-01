import Foundation
import AppKit

struct TerminalConfig: Codable {
    var proportionalFontName: String = "Copernicus Trial"
    var proportionalFontSize: CGFloat = 14.0
    
    var monoFontName: String = "JetBrainsMono"
    var monoFontSize: CGFloat = 14.0
    
    var backgroundColorHex: String = "#0f0f10"
    var textColorHex: String = "#dedede"
    var cursorColorHex: String = "#d97757"
    
    // The 16 ANSI colors (0-15) - Premium Matte Palette
    var ansiColorsHex: [String] = [
        "#0f0f10", "#e06c75", "#98c379", "#d19a66",
        "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
        "#5c6370", "#e06c75", "#98c379", "#d19a66",
        "#61afef", "#c678dd", "#56b6c2", "#ffffff"
    ]
    
    var tabInterval: CGFloat = 75.0
    var monoCharacterAdvance: CGFloat = 10.8
    
    static var current: TerminalConfig = .load()
    
    static func load() -> TerminalConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dynamicterminal.json")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TerminalConfig.self, from: data)
        } catch {
            let config = TerminalConfig()
            config.save()
            return config
        }
    }
    
    func save() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dynamicterminal.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self)
            try data.write(to: url)
        } catch {
            print("Failed to save config: \(error)")
        }
    }
    
    var backgroundColor: NSColor {
        return NSColor(hex: backgroundColorHex) ?? NSColor.windowBackgroundColor
    }
    
    var textColor: NSColor {
        return NSColor(hex: textColorHex) ?? NSColor.textColor
    }
    
    var cursorColor: NSColor {
        return NSColor(hex: cursorColorHex) ?? NSColor.textColor
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
