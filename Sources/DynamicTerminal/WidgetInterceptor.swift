import AppKit
import Foundation

class ProgressAttachmentCell: NSTextAttachmentCell {
    var progress: Double = 0.0
    
    init(progress: Double) {
        self.progress = progress
        super.init(textCell: "")
    }
    
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func cellSize() -> NSSize {
        return NSSize(width: 80, height: 12)
    }
    
    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }
    
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let bgPath = NSBezierPath(roundedRect: cellFrame, xRadius: 4, yRadius: 4)
        NSColor.darkGray.withAlphaComponent(0.5).setFill()
        bgPath.fill()
        
        let fillWidth = max(0, cellFrame.width * CGFloat(progress))
        if fillWidth > 0 {
            let fillRect = NSRect(x: cellFrame.minX, y: cellFrame.minY, width: fillWidth, height: cellFrame.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
            NSColor.systemBlue.setFill()
            fillPath.fill()
        }
    }
}

class ButtonAttachmentCell: NSTextAttachmentCell {
    var displayText: String = ""
    var command: String = ""
    var isPressed = false
    
    init(title: String, command: String) {
        self.displayText = title
        self.command = command
        super.init(textCell: "")
    }
    
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func cellSize() -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        let size = (displayText as NSString).size(withAttributes: attrs)
        return NSSize(width: size.width + 16, height: 16)
    }
    
    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -3)
    }
    
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let path = NSBezierPath(roundedRect: cellFrame, xRadius: 4, yRadius: 4)
        if isPressed {
            NSColor.lightGray.withAlphaComponent(0.3).setFill()
        } else {
            NSColor.darkGray.withAlphaComponent(0.3).setFill()
        }
        path.fill()
        
        NSColor.lightGray.setStroke()
        path.lineWidth = 1
        path.stroke()
        
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let size = (displayText as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: cellFrame.midX - size.width/2, y: cellFrame.midY - size.height/2, width: size.width, height: size.height)
        (displayText as NSString).draw(in: textRect, withAttributes: attrs)
    }
    
    override func wantsToTrackMouse() -> Bool {
        return true
    }
    
    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, untilMouseUp flag: Bool) -> Bool {
        self.isPressed = true
        controlView?.needsDisplay = true
        
        var event = theEvent
        while event.type != .leftMouseUp {
            guard let nextEvent = controlView?.window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            event = nextEvent
        }
        
        self.isPressed = false
        controlView?.needsDisplay = true
        
        let location = controlView?.convert(event.locationInWindow, from: nil) ?? .zero
        if cellFrame.contains(location) {
            WidgetInterceptor.shared.onCommandTriggered?(command)
        }
        
        return true
    }
}

class WidgetInterceptor {
    static let shared = WidgetInterceptor()
    var onCommandTriggered: ((String) -> Void)?
    
    init() {}
    
    func parseAndInjectWidgets(into string: NSMutableAttributedString) {
        injectProgressBars(into: string)
        injectGitButtons(into: string)
    }
    
    private func injectProgressBars(into string: NSMutableAttributedString) {
        let text = string.string
        let pattern = "\\[(=+|#+)[>›]?(\\s*|-*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches.reversed() {
            let fullRange = match.range
            let filledRange = match.range(at: 1)
            let emptyRange = match.range(at: 2)
            
            var filledCount = 0.0
            var emptyCount = 0.0
            
            if filledRange.location != NSNotFound { filledCount = Double(filledRange.length) }
            if emptyRange.location != NSNotFound { emptyCount = Double(emptyRange.length) }
            
            let total = filledCount + emptyCount
            let percentage = total > 0 ? (filledCount / total) : 0.0
            
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ProgressAttachmentCell(progress: percentage)
            let attachmentStr = NSAttributedString(attachment: attachment)
            
            string.replaceCharacters(in: fullRange, with: attachmentStr)
        }
    }

    private func injectGitButtons(into string: NSMutableAttributedString) {
        let text = string.string
        let pattern = "\\[(Stage|Revert)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches.reversed() {
            let fullRange = match.range
            let titleRange = match.range(at: 1)
            
            if let swiftRange = Range(titleRange, in: text) {
                let title = String(text[swiftRange])
                let command = title == "Stage" ? "git add .\n" : "git checkout .\n"
                
                let attachment = NSTextAttachment()
                attachment.attachmentCell = ButtonAttachmentCell(title: title, command: command)
                let attachmentStr = NSAttributedString(attachment: attachment)
                
                string.replaceCharacters(in: fullRange, with: attachmentStr)
            }
        }
    }
}
