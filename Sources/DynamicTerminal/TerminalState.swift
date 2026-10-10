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
    let state = Unmanaged<TerminalState>.fromOpaque(user!).takeUnretainedValue()
    if prop == VTERM_PROP_ALTSCREEN {
        // Read val immediately — this pointer is owned by libvterm and may be freed after this
        // callback returns. Capturing it in an async block causes a use-after-free where the
        // freed memory can read as 1 (true), permanently locking isAlternateBuffer = true and
        // causing scroll events to be translated to arrow keys forever after exiting vim/man.
        let isAlt = (val?.pointee.boolean ?? 0) != 0
        state.isAlternateBuffer = isAlt
        state.accumulatedScrollDelta = 0
        state.onModeChanged?(isAlt)
    } else if prop == VTERM_PROP_TITLE {
        if let val = val, let strPtr = val.pointee.string.str {
            let len = Int(val.pointee.string.len)
            let titleData = Data(bytes: strPtr, count: len)
            if let titleStr = String(data: titleData, encoding: .utf8) {
                state.onTitleChanged?(titleStr)
            }
        }
    }
    return 1
}
func vterm_on_bell(user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_resize(rows: Int32, cols: Int32, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_sb_pushline(cols: Int32, cells: UnsafePointer<VTermScreenCell>?, user: UnsafeMutableRawPointer?) -> Int32 { 
    let state = Unmanaged<TerminalState>.fromOpaque(user!).takeUnretainedValue()
    state.archivePushedLine(cols: cols, cells: cells)
    return 1 
}
func vterm_on_sb_popline(cols: Int32, cells: UnsafeMutablePointer<VTermScreenCell>?, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }
func vterm_on_sb_clear(user: UnsafeMutableRawPointer?) -> Int32 { 
    let state = Unmanaged<TerminalState>.fromOpaque(user!).takeUnretainedValue()
    state.clearArchive()
    return 1 
}
func vterm_on_sb_pushline4(cols: Int32, cells: UnsafePointer<VTermScreenCell>?, isbottom: Bool, user: UnsafeMutableRawPointer?) -> Int32 { return 1 }

func vterm_on_output(s: UnsafePointer<CChar>?, len: Int, user: UnsafeMutableRawPointer?) {
    let state = Unmanaged<TerminalState>.fromOpaque(user!).takeUnretainedValue()
    if state.ptyFD > 0 {
        _ = write_pty(state.ptyFD, s, len)
    }
}


class TerminalState {
    var vterm: OpaquePointer!
    var vtermScreen: OpaquePointer!
    // Stored as a class property so it lives on the heap for the lifetime of this object.
    // vterm_new_with_allocator stores a RAW POINTER to this struct (vt->allocator = funcs).
    // If this were a local variable in init(), the pointer would dangle after init() returns,
    // and any subsequent libvterm call that allocates memory (e.g. vterm_set_size) would
    // read garbage from the dead stack frame and crash.
    private var vtermAllocator = VTermAllocatorFunctions(malloc: vterm_malloc, free: vterm_free)
    var ptyFD: Int32 = -1
    var pid: Int32 = -1
    
    // Mode Switcher State
    var isAlternateBuffer = false
    var onModeChanged: ((Bool) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    
    // Markdown Code Fence State (persists across scrollback)
    var inCodeBlock = false
    
    // Alternate screen transition state
    var wasInAlternateBuffer = false
    
    // Smooth Trackpad Scrolling State
    var accumulatedScrollDelta: CGFloat = 0.0
    
    // We will render to this view
    weak var textView: NSTextView?
    
    // Interaction Flags
    var userDidInputThisFrame = false
    
    // Performance Optimization
    var needsRender = false
    var renderTimer: Timer?
    private var pendingData = Data()
    private let pendingDataMutex = NSLock()
    
    // Cached link detector (expensive to create on every keystroke)
    private lazy var linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    
    // Scrollback Archive
    var archiveBuffer = NSMutableAttributedString()
    var lastArchiveLength = 0
    let maxArchiveLength = 500000 // characters roughly
    
    // Retain callbacks structure so C doesnt lose it
    var screenCallbacksPtr: UnsafeMutablePointer<VTermScreenCallbacks>!
    
    init() {
        vterm = vterm_new_with_allocator(24, 80, &vtermAllocator, nil)
        vterm_set_utf8(vterm, 1)
        
        // Define Custom ANSI Palette
        if let state = vterm_obtain_state(vterm) {
            let colors = TerminalConfig.current.ansiColorsHex
            for (index, hex) in colors.enumerated() {
                if index < 16, let color = NSColor(hex: hex), let rgbColor = color.usingColorSpace(.deviceRGB) {
                    let r = UInt8(rgbColor.redComponent * 255.0)
                    let g = UInt8(rgbColor.greenComponent * 255.0)
                    let b = UInt8(rgbColor.blueComponent * 255.0)
                    cvterm_set_palette_rgb(state, Int32(index), r, g, b)
                }
            }
        }
        
        vtermScreen = vterm_obtain_screen(vterm)
        vterm_screen_enable_altscreen(vtermScreen, 1)
        vterm_screen_reset(vtermScreen, 1) // 1 = hard reset
        
        setupCallbacks()
        
        // Start 60fps Render Loop Debouncer
        // Instead of rendering on every single PTY byte read, we decouple the UI updates
        // to a maximum of 60 times per second. This prevents N^2 AppKit lag on huge output.
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // First, pull a FIXED MAX QUOTA of data from the background thread to prevent
            // starving the main UI runloop if 100MB of data suddenly arrives
            var dataToProcess = Data()
            let maxBytesPerFrame = 65536 // Max 64KB per 16ms tick (~3.8 MB/s stream rate)
            
            self.pendingDataMutex.lock()
            if !self.pendingData.isEmpty {
                let bytesToTake = min(self.pendingData.count, maxBytesPerFrame)
                dataToProcess = self.pendingData.prefix(bytesToTake)
                self.pendingData.removeFirst(bytesToTake)
                self.needsRender = true
            }
            self.pendingDataMutex.unlock()
            
            if !dataToProcess.isEmpty {
                dataToProcess.withUnsafeBytes { ptr in
                    vterm_input_write(self.vterm, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), dataToProcess.count)
                }
            }
            
            // Second, if the state has changed, render the updated buffers to the screen
            if self.needsRender {
                self.needsRender = false
                self.renderProportional()
            }
        }
        
        // Spawn PTY — pass Resources path so bundled scripts (ai, search) are on PATH
        let resourcesPath = Bundle.main.resourcePath
        pid = spawn_pty(&ptyFD, 24, 80, resourcesPath)
        if pid > 0 {
            startReadingPTY()
        } else {
            print("Failed to spawn PTY")
        }
    }
    
    deinit {
        renderTimer?.invalidate()
        if ptyFD > 0 {
            close(ptyFD)
        }
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
            let bufferSize = 65536 // Increased buffer size for efficiency
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            while true {
                let bytesRead = read_pty(self.ptyFD, buffer, bufferSize)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    
                    // Safely hand off the chunk to be consumed by the 60fps render tick
                    // This creates massive backpressure relief and prevents GCD thread flooding
                    self.pendingDataMutex.lock()
                    self.pendingData.append(data)
                    self.pendingDataMutex.unlock()
                } else {
                    print("PTY closed or error reading")
                    break
                }
            }
        }
    }
    
    func resize(to boundsSize: NSSize) {
        guard ptyFD > 0 else { return }
        let usableWidth = max(0, boundsSize.width - 60)   // 30pt horizontal inset * 2
        let usableHeight = max(0, boundsSize.height - 80)  // 40pt vertical inset * 2

        let colWidth = TerminalConfig.current.columnWidth
        let font = NSFont(name: TerminalConfig.current.proportionalFontName,
                          size: TerminalConfig.current.proportionalFontSize)
            ?? NSFont.systemFont(ofSize: TerminalConfig.current.proportionalFontSize)
        let layoutManager = NSLayoutManager()
        let lineHeight = layoutManager.defaultLineHeight(for: font) * TerminalConfig.current.lineHeightMultiple

        // Subtract 2 cols as a safety margin: box-drawing chars in most mono fonts are
        // fractionally wider than an 'M' (what columnWidth measures), so rounding
        // accumulates and border lines overflow into the next vterm row without this margin.
        let cols = max(40, Int32(usableWidth / colWidth) - 2)
        let rows = max(10, Int32(usableHeight / lineHeight))

        vterm_set_size(vterm, rows, cols)
        resize_pty(ptyFD, rows, cols)
        needsRender = true
    }

    func writeToPTY(string: String) {
        userDidInputThisFrame = true
        guard ptyFD > 0, let data = string.data(using: .utf8) else { return }
        
        let chunkSize = 512
        if data.count <= chunkSize {
            // Fast path: single keystroke or small input
            data.withUnsafeBytes { ptr in
                _ = write_pty(ptyFD, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), data.count)
            }
        } else {
            // Chunked path: large paste — yield between chunks so the 60fps render loop can breathe
            var offset = 0
            func writeNext() {
                guard self.ptyFD > 0, offset < data.count else { return }
                let end = min(offset + chunkSize, data.count)
                let chunk = data[offset..<end]
                chunk.withUnsafeBytes { ptr in
                    _ = write_pty(self.ptyFD, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), chunk.count)
                }
                offset = end
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.002) {
                    writeNext()
                }
            }
            writeNext()
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

    private func mapSymbol(_ char: Character) -> String {
        switch char {
        case "✗": return "✕"
        case "✔": return "✓"
        case "➜": return "→"
        default: return String(char)
        }
    }
    
    // --- Box-Drawing / Block Element Detection ---
    // LLM CLI tools (claude, gemini, openai) use Unicode box-drawing, block elements,
    // and braille patterns for panels and borders. These MUST render in monospace
    // to maintain column alignment. We detect per-line and auto-fallback.
    private func isBoxDrawingChar(_ scalar: UInt32) -> Bool {
        return (scalar >= 0x2500 && scalar <= 0x257F)  // Box Drawing
            || (scalar >= 0x2580 && scalar <= 0x259F)  // Block Elements
            || (scalar >= 0x2800 && scalar <= 0x28FF)  // Braille Patterns
    }
    
    // Characters that should individually render in monospace for consistent width,
    // but do NOT force the entire line to monospace.
    private func isFixedWidthChar(_ scalar: UInt32) -> Bool {
        return (scalar >= 0x25A0 && scalar <= 0x25FF)  // Geometric Shapes (●○■□)
            || (scalar >= 0x2600 && scalar <= 0x26FF)  // Miscellaneous Symbols (⚫⚪)
            || (scalar >= 0x2B00 && scalar <= 0x2BFF)  // Misc Symbols & Arrows (⬤⬢)
            || (scalar >= 0x2700 && scalar <= 0x27BF)  // Dingbats (✓✕✔✗)
    }
    
    // --- URL Detection for Clickable Links ---
    private func detectLinks(in string: NSMutableAttributedString) {
        let text = string.string
        guard let detector = linkDetector else { return }
        // Only scan if the text might contain a link to save CPU
        if text.contains("http") || text.contains("www.") {
            let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            for match in matches {
                if let url = match.url {
                    string.addAttribute(.link, value: url, range: match.range)
                }
            }
        }
    }
    
    // --- Shared Line Builder ---
    // Converts a row of VTermScreenCells into an NSAttributedString.
    // isMono = true: spaces are literal (mono font handles alignment natively).
    // isMono = false: runs of 3+ spaces become NSTextTab stops (proportional font alignment trick).
    private func buildLine(
        cellProvider: (Int) -> VTermScreenCell,
        count: Int,
        font: NSFont,
        isMono: Bool,
        defaultColor: NSColor,
        colWidth: CGFloat
    ) -> (line: NSMutableAttributedString, tabStops: [NSTextTab], colToIndex: [Int: Int]) {
        let result = NSMutableAttributedString()
        var tabStops: [NSTextTab] = []
        var colToIndex = [Int: Int]()

        var i = 0
        while i < count {
            colToIndex[i] = result.length

            let cell = cellProvider(i)
            let cChar = cell.chars.0 != 0 ? Character(UnicodeScalar(cell.chars.0) ?? " ") : " "

            var fgColor = getNSColor(from: cell.fg, isFg: true) ?? defaultColor
            var bgColor = getNSColor(from: cell.bg, isFg: false)

            if cell.attrs.reverse != 0 {
                let temp = fgColor
                fgColor = bgColor ?? TerminalConfig.current.backgroundColor
                bgColor = temp
            }

            var currentFont = font
            if cell.attrs.bold != 0 || cell.attrs.italic != 0 {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if cell.attrs.bold != 0 { traits.insert(.bold) }
                if cell.attrs.italic != 0 { traits.insert(.italic) }
                let newDescriptor = currentFont.fontDescriptor.withSymbolicTraits(traits)
                if let newFont = NSFont(descriptor: newDescriptor, size: currentFont.pointSize) {
                    currentFont = newFont
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: currentFont,
                .foregroundColor: fgColor
            ]
            if let bg = bgColor { attributes[.backgroundColor] = bg }
            if cell.attrs.underline != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if cell.attrs.strike != 0 { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

            if cChar == " " {
                var spaces = 0
                var j = i
                while j < count {
                    let nextCell = cellProvider(j)
                    let nextCharVal = nextCell.chars.0 != 0 ? Character(UnicodeScalar(nextCell.chars.0) ?? " ") : " "
                    if nextCharVal == " " {
                        colToIndex[j] = result.length
                        spaces += 1
                        j += 1
                    } else { break }
                }

                if !isMono && spaces >= 3 {
                    // Proportional-font only: collapse multi-space runs to a tab stop at the
                    // correct column position. This simulates fixed-width column alignment.
                    // NEVER apply to mono lines — mono spaces are already exact width.
                    let tabLocation = CGFloat(j) * colWidth
                    tabStops.append(NSTextTab(textAlignment: .left, location: tabLocation))
                    result.append(NSAttributedString(string: "\t", attributes: attributes))
                } else {
                    result.append(NSAttributedString(string: String(repeating: " ", count: spaces), attributes: attributes))
                }
                i = j
            } else {
                let displayedChar = mapSymbol(cChar)
                if !isMono && cell.chars.0 != 0 && isFixedWidthChar(cell.chars.0) {
                    // Pad symbol chars to column width only in proportional mode;
                    // in mono mode the font's fixed advance width already handles this.
                    let charStr = NSAttributedString(string: displayedChar, attributes: [.font: currentFont])
                    let naturalWidth = charStr.size().width
                    let padding = colWidth - naturalWidth
                    if padding > 0 {
                        attributes[.kern] = padding
                    }
                }
                result.append(NSAttributedString(string: displayedChar, attributes: attributes))
                i += 1
            }
        }

        colToIndex[count] = result.length
        return (result, tabStops, colToIndex)
    }

    // Returns a paragraph style that locks every line to the same height regardless of
    // whether it renders in the proportional or mono font. Mixing font line heights on
    // adjacent lines causes visual jumping in Claude Code / LLM CLI output.
    private func lockedLineStyle(tabStops: [NSTextTab], colWidth: CGFloat, propFont: NSFont) -> NSMutableParagraphStyle {
        let pStyle = NSMutableParagraphStyle()
        pStyle.tabStops = tabStops
        pStyle.defaultTabInterval = colWidth
        let baseHeight = NSLayoutManager().defaultLineHeight(for: propFont) * TerminalConfig.current.lineHeightMultiple
        pStyle.minimumLineHeight = baseHeight
        pStyle.maximumLineHeight = baseHeight
        return pStyle
    }
    
    // --- Scrollback Archiving ---
    func archivePushedLine(cols: Int32, cells: UnsafePointer<VTermScreenCell>?) {
        guard let cells = cells else { return }
        if isAlternateBuffer { return }
        
        let propFont = NSFont(name: TerminalConfig.current.proportionalFontName, size: TerminalConfig.current.proportionalFontSize) ?? NSFont.systemFont(ofSize: TerminalConfig.current.proportionalFontSize)
        let monoFont = NSFont(name: TerminalConfig.current.monoFontName, size: TerminalConfig.current.monoFontSize) ?? NSFont.monospacedSystemFont(ofSize: TerminalConfig.current.monoFontSize, weight: .regular)
        let defaultTextColor = TerminalConfig.current.textColor
        let colWidth: CGFloat = TerminalConfig.current.columnWidth
        
        // Find last non-empty column + detect box-drawing chars
        var lastNonEmptyCol = -1
        var hasBoxDrawing = false
        for c in 0..<Int(cols) {
            let cell = cells[c]
            let charVal = cell.chars.0 != 0 ? Character(UnicodeScalar(cell.chars.0) ?? " ") : " "
            if charVal != " " && cell.chars.0 != 0 { lastNonEmptyCol = c }
            if !hasBoxDrawing && cell.chars.0 != 0 && isBoxDrawingChar(cell.chars.0) { hasBoxDrawing = true }
        }
        let actualCount = lastNonEmptyCol + 1
        
        // Extract raw text to detect code fences.
        // Strip leading box-drawing/pipe chars so ``` inside Claude Code panels is detected.
        var rawLine = ""
        for c in 0..<actualCount {
            let ch = cells[c].chars.0
            rawLine.append(ch != 0 ? Character(UnicodeScalar(ch) ?? " ") : " ")
        }
        let stripped = rawLine
            .trimmingCharacters(in: .whitespaces)
            .drop(while: { isBoxDrawingChar($0.unicodeScalars.first?.value ?? 0) || $0 == "|" })
            .trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("```") {
            inCodeBlock.toggle()
        }

        let isMono = hasBoxDrawing || inCodeBlock
        let lineFont = isMono ? monoFont : propFont

        let (archivedLine, tabStops, _) = buildLine(
            cellProvider: { i in cells[i] },
            count: actualCount,
            font: lineFont,
            isMono: isMono,
            defaultColor: defaultTextColor,
            colWidth: colWidth
        )

        archivedLine.append(NSAttributedString(string: "\n", attributes: [.font: propFont]))

        let pStyle = lockedLineStyle(tabStops: tabStops, colWidth: colWidth, propFont: propFont)
        archivedLine.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: archivedLine.length))
        
        self.detectLinks(in: archivedLine)
        
        self.archiveBuffer.append(archivedLine)
        
        if self.archiveBuffer.length > self.maxArchiveLength {
            let excess = self.archiveBuffer.length - self.maxArchiveLength
            self.archiveBuffer.deleteCharacters(in: NSRange(location: 0, length: excess))
            if self.lastArchiveLength > excess {
                self.lastArchiveLength -= excess
            } else {
                self.lastArchiveLength = 0
            }
        }
    }
    
    func clearArchive() {
        if Thread.isMainThread {
            self.archiveBuffer = NSMutableAttributedString()
            self.lastArchiveLength = 0
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.archiveBuffer = NSMutableAttributedString()
                self?.lastArchiveLength = 0
            }
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
        
        let propFont = NSFont(name: TerminalConfig.current.proportionalFontName, size: TerminalConfig.current.proportionalFontSize) ?? NSFont.systemFont(ofSize: TerminalConfig.current.proportionalFontSize)
        let defaultTextColor = TerminalConfig.current.textColor
        let colWidth: CGFloat = TerminalConfig.current.columnWidth
        
        var currentParagraph = NSMutableAttributedString()
        var accumulatedTabStops: [NSTextTab] = []
        
        let monoFont = NSFont(name: TerminalConfig.current.monoFontName, size: TerminalConfig.current.monoFontSize) ?? NSFont.monospacedSystemFont(ofSize: TerminalConfig.current.monoFontSize, weight: .regular)
        
        // Track code fences across the active grid, starting from the scrollback state
        var gridInCodeBlock = inCodeBlock
        
        for r in 0..<vtermRows {
            var lastNonEmptyCol = -1
            var hasBoxDrawing = false
            var hasNonBoxContent = false  // true if line has non-space, non-box chars

            for c in 0..<vtermCols {
                var cell = VTermScreenCell()
                vterm_screen_get_cell(vtermScreen, VTermPos(row: r, col: c), &cell)
                let charVal = cell.chars.0
                if charVal != 0 && charVal != 32 {
                    lastNonEmptyCol = Int(c)
                    if isBoxDrawingChar(charVal) {
                        hasBoxDrawing = true
                    } else {
                        hasNonBoxContent = true
                    }
                }
            }
            // Pure border lines: ╭────╮, ╰────╯, ────── etc.
            // These are full-width lines where every visible char is a box-drawing char.
            // They must never soft-wrap into the next row (which would prefix the prompt with dashes).
            let isPureBorderLine = hasBoxDrawing && !hasNonBoxContent
            
            var trimCol = lastNonEmptyCol
            if r == cursor.row {
                trimCol = max(trimCol, Int(cursor.col) - 1)
            }
            
            let actualLineCount = trimCol + 1
            let screen = vtermScreen!
            
            // Extract raw text to detect code fences.
            // Strip leading box-drawing chars so ``` inside Claude Code panels is detected.
            var rawLine = ""
            for c in 0..<actualLineCount {
                var cell = VTermScreenCell()
                vterm_screen_get_cell(screen, VTermPos(row: r, col: Int32(c)), &cell)
                let ch = cell.chars.0
                rawLine.append(ch != 0 ? Character(UnicodeScalar(ch) ?? " ") : " ")
            }
            let stripped = rawLine
                .trimmingCharacters(in: .whitespaces)
                .drop(while: { isBoxDrawingChar($0.unicodeScalars.first?.value ?? 0) || $0 == "|" })
                .trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") {
                gridInCodeBlock.toggle()
            }

            // Skip lone overflow chars: a pure border line with ≤3 chars is almost certainly
            // a single `─` that spilled from the previous row due to width rounding.
            // Suppress it entirely rather than rendering a stray dash on its own line.
            if isPureBorderLine && actualLineCount <= 3 && r != cursor.row {
                continue
            }

            let isMono = hasBoxDrawing || gridInCodeBlock
            let lineFont = isMono ? monoFont : propFont

            let (processedLineAttrs, lineTabStops, colToIndex) = buildLine(
                cellProvider: { i in
                    var cell = VTermScreenCell()
                    vterm_screen_get_cell(screen, VTermPos(row: r, col: Int32(i)), &cell)
                    return cell
                },
                count: actualLineCount,
                font: lineFont,
                isMono: isMono,
                defaultColor: defaultTextColor,
                colWidth: colWidth
            )
            accumulatedTabStops.append(contentsOf: lineTabStops)

            if r == cursor.row {
                let safeCol = min(Int(cursor.col), actualLineCount)
                textCursorIndex = fullText.length + currentParagraph.length + (colToIndex[safeCol] ?? processedLineAttrs.length)
                foundCursor = true
            }

            if trimCol >= vtermCols - 2 && trimCol > 0 && r != cursor.row && !isPureBorderLine {
                // Soft wrap — only for genuine long text lines that the shell wrapped.
                // Pure border lines (╭────╮, ╰────╯) also fill the width but must
                // always hard-break so they never merge with the next line's prompt.
                currentParagraph.append(processedLineAttrs)
            } else {
                // Hard wrap
                processedLineAttrs.append(NSAttributedString(string: "\n", attributes: [.font: propFont]))
                currentParagraph.append(processedLineAttrs)

                let pStyle = lockedLineStyle(tabStops: accumulatedTabStops, colWidth: colWidth, propFont: propFont)
                currentParagraph.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: currentParagraph.length))

                fullText.append(currentParagraph)
                currentParagraph = NSMutableAttributedString()
                accumulatedTabStops = []
            }
        }

        if currentParagraph.length > 0 {
            let pStyle = lockedLineStyle(tabStops: accumulatedTabStops, colWidth: colWidth, propFont: propFont)
            currentParagraph.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: currentParagraph.length))
            fullText.append(currentParagraph)
        }
        
        // Scan for links ONLY in the active grid (O(1)), not the whole document
        detectLinks(in: fullText)
        
        let oldSelectedRange = textView.selectedRange()
        
        // --- Delta Memory Rendering for Infinite Scroll ---
        guard let textStorage = textView.textStorage else { return }
        
        let currentTotalLength = textStorage.length
        let targetArchiveLength = archiveBuffer.length
        
        // Check if we should auto-scroll BEFORE modifying the text storage
        var shouldAutoScroll = true
        if let scrollView = textView.enclosingScrollView, let documentView = scrollView.documentView {
            let documentHeight = documentView.bounds.height
            let clipHeight = scrollView.contentView.bounds.height
            let scrollY = scrollView.contentView.bounds.origin.y
            // If we are more than 50 points away from the bottom, lock scroll
            if documentHeight - (scrollY + clipHeight) > 50 {
                shouldAutoScroll = false
            }
        }
        
        // Override scroll lock if the user just typed something, or we just exited
        // the alternate buffer (need to snap back to the shell prompt).
        if userDidInputThisFrame {
            shouldAutoScroll = true
            userDidInputThisFrame = false
        } else if wasInAlternateBuffer {
            shouldAutoScroll = true
        }
        
        textStorage.beginEditing()
        
        // --- Alternate Buffer Rendering (Hide History) ---
        if isAlternateBuffer {
            let replaceRange = NSRange(location: 0, length: currentTotalLength)
            textStorage.replaceCharacters(in: replaceRange, with: fullText)
            textStorage.endEditing()
            
            textView.needsDisplay = true
            wasInAlternateBuffer = true
            
            // Lock to the top so there's no visual offset
            if let scrollView = textView.enclosingScrollView {
                scrollView.contentView.scroll(to: NSZeroPoint)
            }
            
            if let tv = textView as? TerminalTextView {
                tv.isProgrammaticSelection = true
                if foundCursor {
                    tv.setSelectedRange(NSRange(location: textCursorIndex, length: 0))
                } else {
                    tv.setSelectedRange(NSRange(location: textStorage.length, length: 0))
                }
                tv.isProgrammaticSelection = false
            }
            return
        }
        
        // Case 1: The archive buffer grew (or shrank via clear). We need to sync the prefix.
        if !wasInAlternateBuffer && targetArchiveLength > lastArchiveLength && targetArchiveLength < maxArchiveLength {
            // O(1) Delta Append: The archive purely grew. Just insert the new lines at the end of the history.
            // This prevents AppKit from invalidating the layout cache for the entire preceding scrollback.
            let appendedLength = targetArchiveLength - lastArchiveLength
            let newText = archiveBuffer.attributedSubstring(from: NSRange(location: lastArchiveLength, length: appendedLength))
            textStorage.insert(newText, at: lastArchiveLength)
            lastArchiveLength = targetArchiveLength
        } else if wasInAlternateBuffer || lastArchiveLength != targetArchiveLength || currentTotalLength < lastArchiveLength {
            // Brute force sync the archive block if it desyncs (e.g. max capacity rollover, clear, or exiting alt-screen)
            let replaceRange = NSRange(location: 0, length: currentTotalLength)
            textStorage.replaceCharacters(in: replaceRange, with: archiveBuffer)
            lastArchiveLength = targetArchiveLength
            wasInAlternateBuffer = false
        }
        
        // Case 2: Replace only the active grid portion of the screen (O(1) allocation)
        let gridStart = lastArchiveLength
        let gridLength = textStorage.length - gridStart
        let gridRange = NSRange(location: gridStart, length: gridLength >= 0 ? gridLength : 0)
        
        textStorage.replaceCharacters(in: gridRange, with: fullText)
        textStorage.endEditing()
        
        textView.needsDisplay = true
        
        if let tv = textView as? TerminalTextView {
            tv.isProgrammaticSelection = true
            if foundCursor {
                let finalCursorRange = NSRange(location: lastArchiveLength + textCursorIndex, length: 0)
                tv.setSelectedRange(finalCursorRange)
                if shouldAutoScroll {
                    tv.scrollRangeToVisible(finalCursorRange)
                }
            } else if oldSelectedRange.length > 0 {
                tv.setSelectedRange(oldSelectedRange)
            } else {
                tv.setSelectedRange(NSRange(location: textStorage.length, length: 0))
                if shouldAutoScroll {
                    tv.scrollRangeToVisible(NSRange(location: textStorage.length, length: 0))
                }
            }
            tv.isProgrammaticSelection = false
        }
    }
    // --- Smooth Trackpad Scrolling Translation ---
    func handleScrollDelta(_ deltaY: CGFloat) -> Bool {
        // We only translate scrolling into arrow keys when in the alternate buffer (e.g., man, vim).
        // Standard shell history uses the native NSScrollView.
        guard ptyFD > 0, isAlternateBuffer else { return false }
        
        // Reset accumulation if direction changes to prevent rubber-banding
        if (deltaY > 0 && accumulatedScrollDelta < 0) || (deltaY < 0 && accumulatedScrollDelta > 0) {
            accumulatedScrollDelta = 0
        }
        
        // Add the new physical movement to our accumulator
        accumulatedScrollDelta += deltaY
        
        // Define how many pixels of trackpad physical movement equals one terminal row
        let scrollThreshold: CGFloat = 10.0 // roughly one line of text
        
        while accumulatedScrollDelta >= scrollThreshold {
            // Scrolled UP (content moves DOWN) -> Send UP arrow
            vterm_keyboard_key(vterm, VTERM_KEY_UP, VTERM_MOD_NONE)
            accumulatedScrollDelta -= scrollThreshold
        }
        
        while accumulatedScrollDelta <= -scrollThreshold {
            // Scrolled DOWN (content moves UP) -> Send DOWN arrow
            vterm_keyboard_key(vterm, VTERM_KEY_DOWN, VTERM_MOD_NONE)
            accumulatedScrollDelta += scrollThreshold
        }
        
        return true
    }

    // --- Keyboard Handling Mapping to Libvterm ---
    func handleKeyEvent(_ event: NSEvent) {
        if ptyFD <= 0 { return }
        
        userDidInputThisFrame = true
        
        let isCtrl = event.modifierFlags.contains(.control)
        let isOption = event.modifierFlags.contains(.option)
        let isShift = event.modifierFlags.contains(.shift)
        let isCommand = event.modifierFlags.contains(.command)
        
        // Handle specific Command+Key shortcuts natively for the shell
        if isCommand {
            switch event.keyCode {
            case 51: // Cmd+Backspace -> Ctrl+U (Delete line)
                vterm_keyboard_unichar(vterm, 0x15, VTERM_MOD_NONE)
            case 123: // Cmd+Left -> Home
                vterm_keyboard_key(vterm, VTERM_KEY_HOME, VTERM_MOD_NONE)
            case 124: // Cmd+Right -> End
                vterm_keyboard_key(vterm, VTERM_KEY_END, VTERM_MOD_NONE)
            default: break
            }
            return
        }
        
        // Build modifier flags for libvterm
        var mod = VTERM_MOD_NONE
        if isCtrl  { mod = VTermModifier(rawValue: mod.rawValue | VTERM_MOD_CTRL.rawValue) }
        if isOption { mod = VTermModifier(rawValue: mod.rawValue | VTERM_MOD_ALT.rawValue) }
        if isShift  { mod = VTermModifier(rawValue: mod.rawValue | VTERM_MOD_SHIFT.rawValue) }
        
        // Map keyCode to VTermKey — pass modifiers to ALL keys
        switch event.keyCode {
        case 36:  vterm_keyboard_key(vterm, VTERM_KEY_ENTER, mod)
        case 51:  vterm_keyboard_key(vterm, VTERM_KEY_BACKSPACE, mod)
        case 53:  vterm_keyboard_key(vterm, VTERM_KEY_ESCAPE, mod)
        case 48:  vterm_keyboard_key(vterm, VTERM_KEY_TAB, mod)       // Tab & Shift+Tab
        case 123: vterm_keyboard_key(vterm, VTERM_KEY_LEFT, mod)
        case 124: vterm_keyboard_key(vterm, VTERM_KEY_RIGHT, mod)
        case 126: vterm_keyboard_key(vterm, VTERM_KEY_UP, mod)
        case 125: vterm_keyboard_key(vterm, VTERM_KEY_DOWN, mod)
        case 115: vterm_keyboard_key(vterm, VTERM_KEY_HOME, mod)      // Home / Fn+Left
        case 119: vterm_keyboard_key(vterm, VTERM_KEY_END, mod)       // End / Fn+Right
        case 116: vterm_keyboard_key(vterm, VTERM_KEY_PAGEUP, mod)    // Page Up / Fn+Up
        case 121: vterm_keyboard_key(vterm, VTERM_KEY_PAGEDOWN, mod)  // Page Down / Fn+Down
        case 117: vterm_keyboard_key(vterm, VTERM_KEY_DEL, mod)       // Forward Delete
        // Function keys F1-F12
        case 122: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 1), mod)
        case 120: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 2), mod)
        case 99:  vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 3), mod)
        case 118: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 4), mod)
        case 96:  vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 5), mod)
        case 97:  vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 6), mod)
        case 98:  vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 7), mod)
        case 100: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 8), mod)
        case 101: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 9), mod)
        case 109: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 10), mod)
        case 103: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 11), mod)
        case 111: vterm_keyboard_key(vterm, VTermKey(rawValue: VTERM_KEY_FUNCTION_0.rawValue + 12), mod)
        default:
            // Normal character input with modifiers
            if let chars = event.charactersIgnoringModifiers {
                for scalar in chars.unicodeScalars {
                    vterm_keyboard_unichar(vterm, scalar.value, mod)
                }
            }
        }
    }
}
