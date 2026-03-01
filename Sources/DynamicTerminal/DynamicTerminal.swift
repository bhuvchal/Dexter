import Foundation
import AppKit

class TerminalTextView: NSTextView {
    var onKeyEvent: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        print("> TerminalTextView keyDown: \(event.keyCode)")
        // Forward all key events to our handler
        onKeyEvent?(event)
        // Do NOT call super.keyDown(with: event) because we don't want the OS
        // inserting text directly into our view. We want the PTY to echo it back.
    }
}

@main
struct AppRunner {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var terminalState: TerminalState!
    var textView: TerminalTextView!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Setup Window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Dynamic Terminal"
        window.delegate = self
        
        // Setup Proportional Text View
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        
        textView = TerminalTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = true // Must be true to become first responder
        textView.isSelectable = true
        textView.font = NSFont(name: "Charter", size: 18) ?? NSFont.systemFont(ofSize: 18)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        
        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
        
        // Initialize State Machine
        terminalState = TerminalState()
        terminalState.textView = textView
        
        textView.onKeyEvent = { [weak self] event in
            self?.terminalState.handleKeyEvent(event)
        }
        
        window.makeFirstResponder(textView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func windowDidResize(_ notification: Notification) {
        // Handle window resize here if needed
    }
}
