import Foundation
import AppKit
import CVTerm

// --- Global C-Compatible Allocators for Libvterm ---
func vterm_malloc(size: Int, user: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? { return malloc(size) }
func vterm_free(ptr: UnsafeMutableRawPointer?, user: UnsafeMutableRawPointer?) { free(ptr) }


// --- Global C-Compatible Callbacks for Libvterm ---
func vterm_on_damage(rect: VTermRect, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_moverect(dest: VTermRect, src: VTermRect, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_movecursor(pos: VTermPos, oldpos: VTermPos, visible: Int32, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_settermprop(prop: VTermProp, val: UnsafeMutablePointer<VTermValue>?, user: UnsafeMutableRawPointer?) -> Int32 {
    if prop == VTERM_PROP_ALTSCREEN {
        let state = Unmanaged<TerminalState>.fromOpaque(user!).takeUnretainedValue()
        DispatchQueue.main.async {
            let isAlt = val?.pointee.boolean ?? 0 != 0
            state.isAlternateBuffer = isAlt
            state.onModeChanged?(isAlt)
        }
    }
    return 1
}
func vterm_on_bell(user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_resize(rows: Int32, cols: Int32, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_sb_pushline(cols: Int32, cells: UnsafePointer<VTermScreenCell>?, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_sb_popline(cols: Int32, cells: UnsafeMutablePointer<VTermScreenCell>?, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_sb_clear(user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_sb_pushline4(cols: Int32, cells: UnsafePointer<VTermScreenCell>?, isbottom: Bool, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }

func vterm_on_output(s: UnsafePointer<CChar>?, len: Int, user: UnsafeMutableRawPointer?) {
    guard let s = s else { return }
    let state = Unmanaged<TerminalState>.fromOpaque(user!).takeUnretainedValue()
    if state.ptyFD > 0 {
        print("> Sending \(len) bytes to PTY via vterm_on_output")
        _ = write_pty(state.ptyFD, s, len)
    }
}


class TerminalState {
    var vterm: OpaquePointer!
    var vtermScreen: OpaquePointer!
    var ptyFD: Int32 = -1
    var pid: Int32 = -1
    
    // Timer for rendering
    var renderTimer: Timer?
    var isDirty = false
    
    // Mode Switcher State
    var isAlternateBuffer = false
    var onModeChanged: ((Bool) -> Void)?
    
    // We will render to this view
    weak var textView: NSTextView?
    
    // Retain callbacks structure so C doesnt lose it
    var screenCallbacksPtr: UnsafeMutablePointer<VTermScreenCallbacks>!
    
    init() {
        // Initialize VTerm Allocator
        var allocator = VTermAllocatorFunctions(malloc: vterm_malloc, free: vterm_free)
        vterm = vterm_new_with_allocator(24, 80, &allocator, nil)
        vterm_set_utf8(vterm, 1)
        
        vtermScreen = vterm_obtain_screen(vterm)
        vterm_screen_reset(vtermScreen, 1) // 1 = hard reset
        
        setupCallbacks()
        
        // Spawn PTY
        pid = spawn_pty(&ptyFD, 24, 80)
        if pid > 0 {
            startReadingPTY()
            startRenderLoop()
        } else {
            print("Failed to spawn PTY")
        }
    }
    
    deinit {
        if screenCallbacksPtr != nil {
            screenCallbacksPtr.deinitialize(count: 1)
            screenCallbacksPtr.deallocate()
        }
    }
    
    private func setupCallbacks() {
        screenCallbacksPtr = UnsafeMutablePointer<VTermScreenCallbacks>.allocate(capacity: 1)
        screenCallbacksPtr.initialize(to: VTermScreenCallbacks(
            damage: vterm_on_damage,
            moverect: vterm_on_moverect,
            movecursor: vterm_on_movecursor,
            settermprop: vterm_on_settermprop,
            bell: vterm_on_bell,
            resize: vterm_on_resize,
            sb_pushline: vterm_on_sb_pushline,
            sb_popline: vterm_on_sb_popline,
            sb_clear: vterm_on_sb_clear,
            sb_pushline4: vterm_on_sb_pushline4
        ))
        
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        vterm_screen_set_callbacks(vtermScreen, screenCallbacksPtr, unmanagedSelf)
        vterm_output_set_callback(vterm, vterm_on_output, unmanagedSelf)
    }
    
    func startReadingPTY() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            let bufferSize = 8192
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            while true {
                let bytesRead = read_pty(self.ptyFD, buffer, bufferSize)
                if bytesRead > 0 {
                    print("> Read \(bytesRead) bytes from PTY")
                    vterm_input_write(self.vterm, buffer, bytesRead)
                    
                    DispatchQueue.main.async {
                        if self.isAlternateBuffer {
                            self.renderGrid()
                        } else {
                            self.renderProportional()
                        }
                    }
                } else {
                    print("PTY closed or error reading")
                    break
                }
            }
        }
    }
    
    func startRenderLoop() {
        // Obsolete: We render synchronously after reading PTY now
    }
    
    func writeToPTY(string: String) {
        if ptyFD > 0 {
            let data = string.data(using: .utf8)!
            data.withUnsafeBytes { ptr in
                _ = write_pty(ptyFD, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), data.count)
            }
        }
    }
    
    // Helper to get NSColor from VTermColor
    private func getNSColor(from vtermColor: VTermColor, isFg: Bool) -> NSColor? {
        if isFg && (vtermColor.type & 0x02) != 0 { return nil }
        if !isFg && (vtermColor.type & 0x04) != 0 { return nil }
        
        var c = vtermColor
        vterm_screen_convert_color_to_rgb(vtermScreen, &c)
        return NSColor(srgbRed: CGFloat(c.rgb.red)/255.0,
                       green: CGFloat(c.rgb.green)/255.0,
                       blue: CGFloat(c.rgb.blue)/255.0,
                       alpha: 1.0)
    }

    // --- Grid Rendering (TUI View) ---
    func renderGrid() {
        guard let textView = textView else { return }
        
        var vtermRows = Int32(0)
        var vtermCols = Int32(0)
        vterm_get_size(vterm, &vtermRows, &vtermCols)
        
        var cursor = VTermPos()
        if let vtermState = vterm_obtain_state(vterm) {
            vterm_state_get_cursorpos(vtermState, &cursor)
        }
        var textCursorIndex = 0
        var foundCursor = false
        
        let fullText = NSMutableAttributedString()
        let monoFont = NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let defaultTextColor = NSColor.textColor
        
        for r in 0..<vtermRows {
            var lineStr = ""
            let lineAttr = NSMutableAttributedString()
            
            for c in 0..<vtermCols {
                if r == cursor.row && c == cursor.col {
                    textCursorIndex = fullText.length + lineAttr.length
                    foundCursor = true
                }
                
                var cell = VTermScreenCell()
                vterm_screen_get_cell(vtermScreen, VTermPos(row: r, col: c), &cell)
                
                let charVal = cell.chars.0 != 0 ? Character(UnicodeScalar(cell.chars.0) ?? " ") : " "
                
                let fgColor = getNSColor(from: cell.fg, isFg: true) ?? defaultTextColor
                let bgColor = getNSColor(from: cell.bg, isFg: false)
                
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: monoFont,
                    .foregroundColor: fgColor
                ]
                if let bg = bgColor { attributes[.backgroundColor] = bg }
                
                lineAttr.append(NSAttributedString(string: String(charVal), attributes: attributes))
                lineStr.append(charVal)
            }
            if r == cursor.row && cursor.col >= vtermCols {
                textCursorIndex = fullText.length + lineAttr.length
                foundCursor = true
            }
            lineAttr.append(NSAttributedString(string: "\n", attributes: [.font: monoFont, .foregroundColor: defaultTextColor]))
            fullText.append(lineAttr)
        }
        
        textView.textStorage?.setAttributedString(fullText)
        textView.needsDisplay = true
        
        if foundCursor {
            textView.setSelectedRange(NSRange(location: textCursorIndex, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: fullText.length, length: 0))
        }
    }
    
    // --- Proportional Rendering (Flowing View) ---
    func renderProportional() {
        guard let textView = textView else { return }
        
        var vtermRows = Int32(0)
        var vtermCols = Int32(0)
        vterm_get_size(vterm, &vtermRows, &vtermCols)
        
        var cursor = VTermPos()
        if let vtermState = vterm_obtain_state(vterm) {
            vterm_state_get_cursorpos(vtermState, &cursor)
        }
        var textCursorIndex = 0
        var foundCursor = false
        
        let fullText = NSMutableAttributedString()
        
        let propFont = NSFont(name: "Charter", size: 18) ?? NSFont.systemFont(ofSize: 18)
        let defaultTextColor = NSColor.textColor
        let colWidth: CGFloat = 10.8 // Standard Menlo 18 advance
        
        var currentParagraph = NSMutableAttributedString()
        var tabStops: [NSTextTab] = []
        
        for r in 0..<vtermRows {
            var lineStr = ""
            var lastNonEmptyCol = -1
            
            for c in 0..<vtermCols {
                var cell = VTermScreenCell()
                vterm_screen_get_cell(vtermScreen, VTermPos(row: r, col: c), &cell)
                
                let charVal = cell.chars.0 != 0 ? Character(UnicodeScalar(cell.chars.0) ?? " ") : " "
                lineStr.append(charVal)
                if charVal != " " && cell.chars.0 != 0 {
                    lastNonEmptyCol = Int(c)
                }
            }
            
            var trimCol = lastNonEmptyCol
            if r == cursor.row {
                trimCol = max(trimCol, Int(cursor.col) - 1)
            }
            
            var actualLine = ""
            if trimCol >= 0 {
                let endIdx = min(trimCol + 1, lineStr.count)
                actualLine = String(lineStr.prefix(endIdx))
            }
            
            let processedLineAttrs = NSMutableAttributedString()
            var localCursorIdx = -1
            var i = 0
            
            while i < actualLine.count {
                if r == cursor.row && i == Int(cursor.col) {
                    localCursorIdx = processedLineAttrs.length
                }
                
                let charIdx = actualLine.index(actualLine.startIndex, offsetBy: i)
                let cChar = actualLine[charIdx]
                
                var cell = VTermScreenCell()
                vterm_screen_get_cell(vtermScreen, VTermPos(row: r, col: Int32(i)), &cell)
                
                let fgColor = getNSColor(from: cell.fg, isFg: true) ?? defaultTextColor
                let bgColor = getNSColor(from: cell.bg, isFg: false)
                
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: propFont,
                    .foregroundColor: fgColor
                ]
                if let bg = bgColor { attributes[.backgroundColor] = bg }
                
                if cChar == " " {
                    var spaces = 0
                    var j = i
                    while j < actualLine.count {
                        let jIdx = actualLine.index(actualLine.startIndex, offsetBy: j)
                        if actualLine[jIdx] == " " {
                            if r == cursor.row && j == Int(cursor.col) && j > i {
                                localCursorIdx = processedLineAttrs.length + 1
                            }
                            spaces += 1
                            j += 1
                        } else { break }
                    }
                    
                    if spaces >= 2 {
                        let tabLocation = CGFloat(j) * colWidth
                        tabStops.append(NSTextTab(textAlignment: .left, location: tabLocation))
                        processedLineAttrs.append(NSAttributedString(string: "\t", attributes: attributes))
                    } else {
                        processedLineAttrs.append(NSAttributedString(string: " ", attributes: attributes))
                    }
                    i = j
                } else {
                    processedLineAttrs.append(NSAttributedString(string: String(cChar), attributes: attributes))
                    i += 1
                }
            }
            
            if r == cursor.row && Int(cursor.col) >= actualLine.count {
                localCursorIdx = processedLineAttrs.length
            }
            
            if r == cursor.row {
                if localCursorIdx == -1 { localCursorIdx = 0 }
                textCursorIndex = fullText.length + currentParagraph.length + localCursorIdx
                foundCursor = true
            }
            
            if trimCol >= vtermCols - 2 && trimCol > 0 {
                // Soft wrap
                currentParagraph.append(processedLineAttrs)
            } else {
                // Hard wrap
                processedLineAttrs.append(NSAttributedString(string: "\n", attributes: [.font: propFont]))
                currentParagraph.append(processedLineAttrs)
                
                let pStyle = NSMutableParagraphStyle()
                pStyle.tabStops = tabStops
                pStyle.defaultTabInterval = colWidth
                currentParagraph.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: currentParagraph.length))
                
                fullText.append(currentParagraph)
                currentParagraph = NSMutableAttributedString()
                tabStops = []
            }
        }
        
        if currentParagraph.length > 0 {
            let pStyle = NSMutableParagraphStyle()
            pStyle.tabStops = tabStops
            pStyle.defaultTabInterval = colWidth
            currentParagraph.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: currentParagraph.length))
            fullText.append(currentParagraph)
        }
        
        textView.textStorage?.setAttributedString(fullText)
        textView.needsDisplay = true
        
        if foundCursor {
            textView.setSelectedRange(NSRange(location: textCursorIndex, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: fullText.length, length: 0))
        }
        
        let scrollView = textView.enclosingScrollView
        if let docView = scrollView?.documentView as? NSView {
            let pt = NSPoint(x: 0, y: docView.bounds.height)
            docView.scroll(pt)
        }
    }

    // --- Keyboard Handling Mapping to Libvterm ---
    func handleKeyEvent(_ event: NSEvent) {
        if ptyFD <= 0 { return }
        
        print("> TerminalState received NSEvent keyCode: \(event.keyCode)")
        
        // Control Keys
        let isCtrl = event.modifierFlags.contains(.control)
        let isOption = event.modifierFlags.contains(.option)
        let isCommand = event.modifierFlags.contains(.command)
        
        // If command is pressed, let it pass to the OS (e.g., Cmd+C, Cmd+V)
        if isCommand { return }
        
        // Special Key Mapping
        switch event.keyCode {
        case 36: // Return
            vterm_keyboard_key(vterm, VTERM_KEY_ENTER, VTERM_MOD_NONE)
        case 51: // Backspace
            vterm_keyboard_key(vterm, VTERM_KEY_BACKSPACE, VTERM_MOD_NONE)
        case 53: // Escape
            vterm_keyboard_key(vterm, VTERM_KEY_ESCAPE, VTERM_MOD_NONE)
        case 48: // Tab
            vterm_keyboard_key(vterm, VTERM_KEY_TAB, VTERM_MOD_NONE)
        case 123: // Left Arrow
            vterm_keyboard_key(vterm, VTERM_KEY_LEFT, VTERM_MOD_NONE)
        case 124: // Right Arrow
            vterm_keyboard_key(vterm, VTERM_KEY_RIGHT, VTERM_MOD_NONE)
        case 126: // Up Arrow
            vterm_keyboard_key(vterm, VTERM_KEY_UP, VTERM_MOD_NONE)
        case 125: // Down Arrow
            vterm_keyboard_key(vterm, VTERM_KEY_DOWN, VTERM_MOD_NONE)
        default:
            // Normal Character Input
            if let chars = event.charactersIgnoringModifiers {
                var mod = VTERM_MOD_NONE
                if isCtrl { mod = VTermModifier(rawValue: mod.rawValue | VTERM_MOD_CTRL.rawValue) }
                if isOption { mod = VTermModifier(rawValue: mod.rawValue | VTERM_MOD_ALT.rawValue) }
                
                for scalar in chars.unicodeScalars {
                    vterm_keyboard_unichar(vterm, scalar.value, mod)
                }
            }
        }
    }
}
