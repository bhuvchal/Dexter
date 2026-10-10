import Foundation
import AppKit

class TerminalTextView: NSTextView {
    var onKeyEvent: ((NSEvent) -> Void)?
    var onScrollDelta: ((CGFloat) -> Bool)?
    var onPaste: ((String) -> Void)?
    var isProgrammaticSelection = false
    var lastCursorPosition: Int = 0
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        if isProgrammaticSelection {
            // Track the cursor position set by the render loop
            if let first = ranges.first, first.rangeValue.length == 0 {
                lastCursorPosition = first.rangeValue.location
            }
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
            return
        }
        
        let allEmpty = ranges.allSatisfy { $0.rangeValue.length == 0 }
        if allEmpty {
            // Click to deselect: restore cursor to the command line position
            let maxPos = textStorage?.length ?? 0
            let safePos = min(lastCursorPosition, maxPos)
            super.setSelectedRanges([NSValue(range: NSRange(location: safePos, length: 0))], affinity: affinity, stillSelecting: stillSelectingFlag)
            return
        }
        
        // Allow drag selection (length > 0) for text copying
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let keyCode = event.keyCode
            // Cmd+Backspace (51), Cmd+Left (123), Cmd+Right (124) → forward to PTY
            if keyCode == 51 || keyCode == 123 || keyCode == 124 {
                onKeyEvent?(event)
                return
            }
            // Cmd+C (8), Cmd+V (9), Cmd+A (0), Cmd+X (7), Cmd+Z (6) → standard text editing
            let textEditingKeys: Set<UInt16> = [0, 6, 7, 8, 9]
            if textEditingKeys.contains(keyCode) {
                super.keyDown(with: event)
                return
            }
            // All other Cmd shortcuts: swallow silently — the menu/event monitor handles them
            return
        }
        onKeyEvent?(event)
    }
    
    override func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string) {
            onPaste?(string)
        }
    }
    
    override func scrollWheel(with event: NSEvent) {
        // macOS scrollingDeltaY is positive for scrolling UP (content moves down)
        let handled = onScrollDelta?(event.scrollingDeltaY) ?? false
        if !handled {
            super.scrollWheel(with: event)
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

class TerminalWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var terminalState: TerminalState!
    var textView: TerminalTextView!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        guard let window = self.window else { return }
        window.center()
        window.title = "Terminal"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.delegate = self
        
        // --- THIS IS THE MAGIC LINE THAT ENABLES SAFARI-STYLE RIBBON TABS ---
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "DynamicTerminalTab"
        
        // Setup Vibrancy (Frosted Glass Background)
        let visualEffectView = NSVisualEffectView(frame: window.contentView!.bounds)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .underWindowBackground // Enforces strong dark mode contrast
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        window.contentView?.addSubview(visualEffectView)
        
        // Setup Proportional Text View
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.scrollerKnobStyle = .light
        
        textView = TerminalTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = true // Must be true to become first responder
        textView.isSelectable = true
        textView.font = NSFont(name: TerminalConfig.current.proportionalFontName, size: TerminalConfig.current.proportionalFontSize) ?? NSFont.systemFont(ofSize: TerminalConfig.current.proportionalFontSize)
        
        // For vibrancy to bleed through, the exact background color must have alpha transparency
        let baseColor = TerminalConfig.current.backgroundColor
        textView.backgroundColor = baseColor.withAlphaComponent(0.85) 
        
        textView.insertionPointColor = TerminalConfig.current.cursorColor
        textView.textColor = TerminalConfig.current.textColor
        
        // Massive UI upgrade: Premium breathing room around the edges
        textView.textContainerInset = NSSize(width: 30, height: 40)
        
        // Enable clickable links
        textView.isAutomaticLinkDetectionEnabled = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(hex: "#61afef") ?? NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        
        // Custom selection color (muted dark blue, matching palette)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(hex: "#2a3a4a") ?? NSColor.selectedTextBackgroundColor
        ]
        
        scrollView.documentView = textView
        // Ensure scrollview doesn't block vibrancy
        scrollView.drawsBackground = false 
        
        window.contentView?.addSubview(scrollView)
        
        terminalState = TerminalState()
        terminalState.textView = textView
        
        terminalState.onTitleChanged = { [weak self] newTitle in
            self?.window?.title = newTitle
        }
        
        textView.delegate = self
        
        textView.onKeyEvent = { [weak self] event in
            self?.terminalState.handleKeyEvent(event)
        }
        
        textView.onPaste = { [weak self] string in
            self?.terminalState.writeToPTY(string: string)
        }
        
        textView.onScrollDelta = { [weak self] deltaY in
            return self?.terminalState.handleScrollDelta(deltaY) ?? false
        }
        
        window.makeFirstResponder(textView)
        window.makeKeyAndOrderFront(nil)

        // Set initial terminal size based on actual view dimensions once layout has settled
        DispatchQueue.main.async {
            if let scrollView = self.textView.enclosingScrollView {
                self.terminalState.resize(to: scrollView.bounds.size)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidChange),
            name: .terminalConfigChanged,
            object: nil
        )
    }

    @objc func configDidChange() {
        let config = TerminalConfig.current
        textView.backgroundColor = config.backgroundColor.withAlphaComponent(0.85)
        textView.insertionPointColor = config.cursorColor
        // Don't set textView.font — the render loop builds attributed strings with the
        // correct fonts from TerminalConfig.current on every frame. Just trigger a resize
        // so the next render cycle picks up the new config values.
        if let scrollView = textView.enclosingScrollView {
            terminalState?.resize(to: scrollView.bounds.size)
        }
    }
    
    // MARK: - NSTextViewDelegate for link clicking
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        }
        if let str = link as? String, let url = URL(string: str) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }
    
    // MARK: - NSWindowDelegate Resize
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let scrollView = textView?.enclosingScrollView else { return }
        terminalState?.resize(to: scrollView.bounds.size)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let scrollView = self.textView?.enclosingScrollView else { return }
            self.terminalState?.resize(to: scrollView.bounds.size)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let scrollView = self.textView?.enclosingScrollView else { return }
            self.terminalState?.resize(to: scrollView.bounds.size)
        }
    }

    // MARK: - NSWindowDelegate Teardown
    func windowWillClose(_ notification: Notification) {
        // Broadcast that this tab is dead so the AppDelegate drops the strong reference
        NotificationCenter.default.post(name: NSNotification.Name("TerminalWindowWillClose"), object: self)
        
        // Ensure PTY is aggressively torn down
        terminalState = nil
        textView.delegate = nil
        textView.onKeyEvent = nil
        textView.onPaste = nil
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowControllers: Set<TerminalWindowController> = []
    
    func setupMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
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
        
        // File Menu / Tab Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newTerminalWindow), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTerminalTab), keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)
        
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenu()

        // Intercept Cmd+, (keyCode 43) before NSTextView can swallow it
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let onlyCmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if onlyCmd && event.keyCode == 43 {
                SettingsWindowController.shared.show()
                return nil // consume — don't pass to NSTextView
            }
            return event
        }

        // Listen for tab deaths to clean up memory
        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowClose(_:)), name: NSNotification.Name("TerminalWindowWillClose"), object: nil)

        // Spawn the first terminal instance on launch
        newTerminalWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func newTerminalWindow() {
        let windowController = TerminalWindowController()
        windowControllers.insert(windowController)
        windowController.windowDidLoad()
    }
    
    @objc func newTerminalTab() {
        // macOS automatically handles tab grouping if tabbingMode = .preferred
        // Just spawning a new window controller does the trick.
        newTerminalWindow()
    }
    
    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc func handleWindowClose(_ notification: Notification) {
        if let controller = notification.object as? TerminalWindowController {
            windowControllers.remove(controller)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
