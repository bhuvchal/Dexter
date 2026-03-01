import Foundation
import AppKit

class TerminalTextView: NSTextView {
    var onKeyEvent: ((NSEvent) -> Void)?
    var onPaste: ((String) -> Void)?
    var isProgrammaticSelection = false
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        if !isProgrammaticSelection {
            let allEmpty = ranges.allSatisfy { $0.rangeValue.length == 0 }
            if allEmpty {
                return // Totally reject simple mouse-down visual cursor jumps
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    }
    
    override func keyDown(with event: NSEvent) {
        // If it's a command key (e.g. Cmd+C, Cmd+V), let super handle it for standard menu actions
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        
        // Forward all other key events to our handler
        onKeyEvent?(event)
        // Do NOT call super.keyDown(with: event) because we don't want the OS
        // inserting text directly into our view. We want the PTY to echo it back.
    }
    
    override func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string) {
            onPaste?(string)
        }
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
    
    func setupMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        // Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()
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
        textView.font = NSFont(name: TerminalConfig.current.proportionalFontName, size: TerminalConfig.current.proportionalFontSize) ?? NSFont.systemFont(ofSize: TerminalConfig.current.proportionalFontSize)
        textView.backgroundColor = TerminalConfig.current.backgroundColor
        textView.insertionPointColor = TerminalConfig.current.cursorColor
        textView.textColor = TerminalConfig.current.textColor
        textView.textContainerInset = NSSize(width: 20, height: 20)
        
        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
        window.backgroundColor = TerminalConfig.current.backgroundColor
        
        // Initialize State Machine
        terminalState = TerminalState()
        terminalState.textView = textView
        
        textView.onKeyEvent = { [weak self] event in
            self?.terminalState.handleKeyEvent(event)
        }
        
        textView.onPaste = { [weak self] string in
            self?.terminalState.writeToPTY(string: string)
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
