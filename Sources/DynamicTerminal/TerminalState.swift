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
    } else if prop == VTERM_PROP_MOUSE {
        // Programs like Claude Code, vim (mouse=a) and htop ask for mouse reporting;
        // scrolling then has to reach them as wheel events, not arrow keys.
        state.mouseReportingEnabled = (val?.pointee.number ?? 0) != Int32(VTERM_PROP_MOUSE_NONE)
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
// Returning 1 tells libvterm we filled `cells`; we don't, and its zero-width cells make
// resize_buffer loop forever. Scrollback lives in our own archive, so decline.
func vterm_on_sb_popline(cols: Int32, cells: UnsafeMutablePointer<VTermScreenCell>?, user: UnsafeMutableRawPointer?) -> Int32 { return 0 }
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
    var mouseReportingEnabled = false
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
    // Main-thread side of the hand-off: bytes taken from pendingData, consumed in slices.
    private var inputBuffer = Data()
    private var inputOffset = 0
    // Bytes read from the PTY but not yet fed to libvterm (guarded by pendingDataMutex).
    private var queuedBytes = 0
    private let maxQueuedBytes = 1 << 20
    private var lastRenderTime: TimeInterval = 0
    
    // Cached link detector (expensive to create on every keystroke)
    private lazy var linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    
    // Fonts and metrics are expensive to look up per line; rebuilt when resize() runs,
    // which also happens on every config change.
    private struct RenderMetrics {
        let propFont: NSFont
        let monoFont: NSFont
        let textColor: NSColor
        let colWidth: CGFloat
        let lineHeight: CGFloat
    }
    private var cachedMetrics: RenderMetrics?
    private var metrics: RenderMetrics {
        if let cachedMetrics { return cachedMetrics }
        let config = TerminalConfig.current
        let propFont = NSFont(name: config.proportionalFontName, size: config.proportionalFontSize)
            ?? NSFont.systemFont(ofSize: config.proportionalFontSize)
        let monoFont = NSFont(name: config.monoFontName, size: config.monoFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: config.monoFontSize, weight: .regular)
        let built = RenderMetrics(
            propFont: propFont,
            monoFont: monoFont,
            textColor: config.textColor,
            colWidth: config.columnWidth,
            lineHeight: NSLayoutManager().defaultLineHeight(for: propFont) * config.lineHeightMultiple
        )
        cachedMetrics = built
        return built
    }

    // Scrollback Archive
    var archiveBuffer = NSMutableAttributedString()
    var lastArchiveLength = 0
    let maxArchiveLength = 500000 // characters roughly
    let archiveTrimSlack = 100000
    
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
            
            // First, feed libvterm in small slices for at most ~12ms per tick, so key events
            // (e.g. Ctrl-C) are still handled during a flood. A fixed 64KB chunk could take
            // ~200ms to process once scrollback archiving is included.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.012
            while ProcessInfo.processInfo.systemUptime < deadline {
                if self.inputOffset >= self.inputBuffer.count {
                    // Take everything the reader thread has queued in one O(1) swap.
                    self.pendingDataMutex.lock()
                    self.inputBuffer = self.pendingData
                    self.pendingData = Data()
                    self.pendingDataMutex.unlock()
                    self.inputOffset = 0
                    if self.inputBuffer.isEmpty { break }
                }
                let start = self.inputBuffer.startIndex + self.inputOffset
                let length = min(4096, self.inputBuffer.count - self.inputOffset)
                self.inputBuffer[start..<(start + length)].withUnsafeBytes { ptr in
                    _ = vterm_input_write(self.vterm, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), length)
                }
                self.inputOffset += length
                self.pendingDataMutex.lock()
                self.queuedBytes -= length
                self.pendingDataMutex.unlock()
                self.needsRender = true
            }
            
            // Second, if the state has changed, render the updated buffers to the screen.
            // While input is still backed up, redraw ~10x a second instead of every tick:
            // repainting the window dominated the cost of heavy output.
            let backlogged = self.inputOffset < self.inputBuffer.count
            let now = ProcessInfo.processInfo.systemUptime
            if self.needsRender && (!backlogged || now - self.lastRenderTime >= 0.1) {
                self.needsRender = false
                self.lastRenderTime = now
                self.renderProportional()
            }
        }
        
        // Spawn PTY — pass Resources path so bundled scripts (search) are on PATH
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
                // Backpressure: stop reading while the main thread is far behind. The kernel's
                // PTY buffer then fills and the writer (e.g. `yes`) blocks, instead of this
                // queue growing without bound and Ctrl-C output arriving after the backlog.
                while true {
                    self.pendingDataMutex.lock()
                    let queued = self.queuedBytes
                    self.pendingDataMutex.unlock()
                    if queued < self.maxQueuedBytes { break }
                    usleep(2000)
                }

                let bytesRead = read_pty(self.ptyFD, buffer, bufferSize)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    
                    // Safely hand off the chunk to be consumed by the 60fps render tick
                    // This creates massive backpressure relief and prevents GCD thread flooding
                    self.pendingDataMutex.lock()
                    self.pendingData.append(data)
                    self.queuedBytes += data.count
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

        cachedMetrics = nil
        let colWidth = metrics.colWidth
        let lineHeight = metrics.lineHeight

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
    // Cells with the same style are appended as one run; per-character attributed strings
    // made heavy output slow.
    private struct CellStyle: Equatable {
        let fg: UInt32
        let bg: UInt32
        let flags: UInt8

        init(_ cell: VTermScreenCell) {
            fg = CellStyle.pack(cell.fg)
            bg = CellStyle.pack(cell.bg)
            var f: UInt8 = 0
            if cell.attrs.bold != 0 { f |= 1 }
            if cell.attrs.italic != 0 { f |= 2 }
            if cell.attrs.underline != 0 { f |= 4 }
            if cell.attrs.strike != 0 { f |= 8 }
            if cell.attrs.reverse != 0 { f |= 16 }
            flags = f
        }

        private static func pack(_ c: VTermColor) -> UInt32 {
            UInt32(c.type) | UInt32(c.rgb.red) << 8 | UInt32(c.rgb.green) << 16 | UInt32(c.rgb.blue) << 24
        }
    }

    // Blank cells with a background (status bars, highlighted rows) are visible content
    // and must not be trimmed off the end of a line.
    private func hasVisibleBackground(_ cell: VTermScreenCell) -> Bool {
        return cell.attrs.reverse != 0 || (cell.bg.type & 0x04) == 0
    }

    private func isBlankCell(_ cell: VTermScreenCell) -> Bool {
        let ch = cell.chars.0
        return ch == 0 || ch == 32 || UnicodeScalar(ch) == nil
    }

    private func attributes(for cell: VTermScreenCell, font: NSFont, defaultColor: NSColor) -> [NSAttributedString.Key: Any] {
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
        return attributes
    }

    private func buildLine(
        cellProvider: (Int) -> VTermScreenCell,
        count: Int,
        font: NSFont,
        isMono: Bool,
        alignColumns: Bool = false,
        defaultColor: NSColor,
        colWidth: CGFloat
    ) -> (line: NSMutableAttributedString, tabStops: [NSTextTab], colToIndex: [Int]) {
        let result = NSMutableAttributedString()
        var tabStops: [NSTextTab] = []
        var colToIndex = [Int](repeating: 0, count: count + 1)

        var run = ""
        var runLength = 0  // UTF-16 length of `run`
        var runStyle: CellStyle?
        var runAttributes: [NSAttributedString.Key: Any] = [:]
        func flush() {
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: runAttributes))
            run = ""
            runLength = 0
        }

        var i = 0
        while i < count {
            let cell = cellProvider(i)
            let style = CellStyle(cell)
            if style != runStyle {
                flush()
                runStyle = style
                runAttributes = attributes(for: cell, font: font, defaultColor: defaultColor)
            }

            if isBlankCell(cell) {
                // Gather the run of same-styled blanks, so e.g. reverse-video spaces in a
                // status bar keep their background instead of taking the first cell's style.
                var j = i + 1
                while j < count {
                    let next = cellProvider(j)
                    guard isBlankCell(next), CellStyle(next) == style else { break }
                    j += 1
                }
                let spaces = j - i

                // On table-like lines every word is pinned to its terminal column.
                var token = ""
                var tokenEnd = j
                if alignColumns {
                    while tokenEnd < count {
                        let next = cellProvider(tokenEnd)
                        if isBlankCell(next) { break }
                        token.unicodeScalars.append(UnicodeScalar(next.chars.0)!)
                        tokenEnd += 1
                    }
                }
                // Leading indentation keeps its usual handling, except right-aligned numbers.
                let anchorToken = !token.isEmpty && (i > 0 || isNumericToken(token))

                if !isMono && (spaces >= 3 || anchorToken) {
                    // Proportional-font only: collapse multi-space runs to a tab stop at the
                    // correct column position. This simulates fixed-width column alignment.
                    // NEVER apply to mono lines — mono spaces are already exact width.
                    // Numbers in tables are right-aligned (ls sizes, dates, PIDs), so they're
                    // pinned by the column where they end rather than where they start.
                    flush()
                    for k in i..<j { colToIndex[k] = result.length }
                    if anchorToken && isNumericToken(token) {
                        tabStops.append(NSTextTab(textAlignment: .right, location: CGFloat(tokenEnd) * colWidth))
                    } else {
                        tabStops.append(NSTextTab(textAlignment: .left, location: CGFloat(j) * colWidth))
                    }
                    result.append(NSAttributedString(string: "\t", attributes: runAttributes))
                } else {
                    for k in 0..<spaces { colToIndex[i + k] = result.length + runLength + k }
                    run += String(repeating: " ", count: spaces)
                    runLength += spaces
                }
                i = j
                continue
            }

            colToIndex[i] = result.length + runLength
            let displayedChar = mapSymbol(Character(UnicodeScalar(cell.chars.0)!))
            if !isMono && isFixedWidthChar(cell.chars.0) {
                // Pad symbol chars to column width only in proportional mode;
                // in mono mode the font's fixed advance width already handles this.
                flush()
                var symbolAttributes = runAttributes
                let naturalWidth = NSAttributedString(string: displayedChar, attributes: [.font: runAttributes[.font] ?? font]).size().width
                let padding = colWidth - naturalWidth
                if padding > 0 {
                    symbolAttributes[.kern] = padding
                }
                result.append(NSAttributedString(string: displayedChar, attributes: symbolAttributes))
            } else {
                run += displayedChar
                runLength += displayedChar.utf16.count
            }
            i += 1
        }
        flush()

        colToIndex[count] = result.length
        return (result, tabStops, colToIndex)
    }

    // Table-like output (ls -l, ps, df) pads columns with spaces. A line with two or more
    // gaps of 2+ spaces between words gets its words pinned to terminal columns so rows line
    // up in the proportional font. Prose with an occasional double space, and code after a
    // single indent or line-number gap (e.g. in vim), is left alone.
    private func looksTabular(_ line: String) -> Bool {
        var gaps = 0
        var spaces = 0
        var seenText = false
        for ch in line {
            if ch == " " {
                spaces += 1
            } else {
                if seenText && spaces >= 2 { gaps += 1 }
                seenText = true
                spaces = 0
            }
        }
        return gaps >= 2
    }

    // Sizes, counts, dates and times: "224", "4.0K", "460Gi", "13:02", "2026", "12%".
    private func isNumericToken(_ token: String) -> Bool {
        var hasDigit = false
        var unitLength = 0
        for (index, ch) in token.enumerated() {
            if unitLength > 0 {
                // A unit suffix like "K", "Gi" or "%" must end the token.
                guard unitLength < 2, "iBb".contains(ch) else { return false }
                unitLength += 1
            } else if ch.isASCII && ch.isNumber {
                hasDigit = true
            } else if ".,:".contains(ch) || (index == 0 && "+-".contains(ch)) {
                continue
            } else if hasDigit && "%KMGTPBkb".contains(ch) {
                unitLength = 1
            } else {
                return false
            }
        }
        return hasDigit
    }

    // Returns a paragraph style that locks every line to the same height regardless of
    // whether it renders in the proportional or mono font. Mixing font line heights on
    // adjacent lines causes visual jumping in Claude Code / LLM CLI output.
    private func lockedLineStyle(tabStops: [NSTextTab], colWidth: CGFloat) -> NSMutableParagraphStyle {
        let pStyle = NSMutableParagraphStyle()
        pStyle.tabStops = tabStops
        pStyle.defaultTabInterval = colWidth
        pStyle.minimumLineHeight = metrics.lineHeight
        pStyle.maximumLineHeight = metrics.lineHeight
        return pStyle
    }
    
    // --- Scrollback Archiving ---
    func archivePushedLine(cols: Int32, cells: UnsafePointer<VTermScreenCell>?) {
        guard let cells = cells else { return }
        if isAlternateBuffer { return }
        
        let metrics = self.metrics
        let propFont = metrics.propFont
        let monoFont = metrics.monoFont
        let defaultTextColor = metrics.textColor
        let colWidth = metrics.colWidth
        
        // Find last non-empty column + detect box-drawing chars
        var lastNonEmptyCol = -1
        var hasBoxDrawing = false
        for c in 0..<Int(cols) {
            let cell = cells[c]
            let charVal = cell.chars.0 != 0 ? Character(UnicodeScalar(cell.chars.0) ?? " ") : " "
            if (charVal != " " && cell.chars.0 != 0) || hasVisibleBackground(cell) { lastNonEmptyCol = c }
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
        let alignColumns = !isMono && looksTabular(rawLine)
        let lineFont = isMono ? monoFont : propFont

        let (archivedLine, tabStops, _) = buildLine(
            cellProvider: { i in cells[i] },
            count: actualCount,
            font: lineFont,
            isMono: isMono,
            alignColumns: alignColumns,
            defaultColor: defaultTextColor,
            colWidth: colWidth
        )

        archivedLine.append(NSAttributedString(string: "\n", attributes: [.font: propFont]))

        let pStyle = lockedLineStyle(tabStops: tabStops, colWidth: colWidth)
        archivedLine.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: archivedLine.length))
        
        self.detectLinks(in: archivedLine)
        
        self.archiveBuffer.append(archivedLine)
        
        // Trim in batches: deleting from the front memmoves the whole buffer, so doing it
        // per line made heavy output O(n^2). Cut on a line boundary so no partial line remains.
        if self.archiveBuffer.length > self.maxArchiveLength + self.archiveTrimSlack {
            var excess = self.archiveBuffer.length - self.maxArchiveLength
            let text = self.archiveBuffer.mutableString
            let newline = text.range(of: "\n", options: [], range: NSRange(location: excess, length: text.length - excess))
            if newline.location != NSNotFound {
                excess = newline.location + 1
            }
            self.archiveBuffer.deleteCharacters(in: NSRange(location: 0, length: excess))

            // Drop the same prefix from the text view so render can keep delta-appending
            // instead of falling back to a full re-layout every frame.
            let synced = min(excess, self.lastArchiveLength)
            if synced > 0, let textStorage = self.textView?.textStorage, textStorage.length >= synced {
                textStorage.deleteCharacters(in: NSRange(location: 0, length: synced))
            }
            self.lastArchiveLength -= synced
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
        
        let metrics = self.metrics
        let propFont = metrics.propFont
        let monoFont = metrics.monoFont
        let defaultTextColor = metrics.textColor
        let colWidth = metrics.colWidth
        
        var currentParagraph = NSMutableAttributedString()
        var accumulatedTabStops: [NSTextTab] = []
        
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
                } else if hasVisibleBackground(cell) {
                    lastNonEmptyCol = Int(c)
                    hasNonBoxContent = true
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
            // Full-screen apps own every row, so never drop one there.
            if isPureBorderLine && actualLineCount <= 3 && r != cursor.row && !isAlternateBuffer {
                continue
            }

            let isMono = hasBoxDrawing || gridInCodeBlock
            let alignColumns = !isMono && looksTabular(rawLine)
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
                alignColumns: alignColumns,
                defaultColor: defaultTextColor,
                colWidth: colWidth
            )
            accumulatedTabStops.append(contentsOf: lineTabStops)

            if r == cursor.row {
                let safeCol = min(Int(cursor.col), actualLineCount)
                textCursorIndex = fullText.length + currentParagraph.length + colToIndex[safeCol]
                foundCursor = true
            }

            // libvterm marks rows that continue an auto-wrapped line; guessing from the line
            // reaching the right edge glued unrelated full-width lines together.
            var nextRowContinues = false
            if r + 1 < vtermRows, let state = vterm_obtain_state(vterm),
               let info = vterm_state_get_lineinfo(state, r + 1) {
                nextRowContinues = info.pointee.continuation != 0
            }

            if nextRowContinues && r != cursor.row && !isPureBorderLine && !isAlternateBuffer {
                // Soft wrap — only for genuine long text lines that the shell wrapped.
                // Pure border lines (╭────╮, ╰────╯) also fill the width but must
                // always hard-break so they never merge with the next line's prompt.
                currentParagraph.append(processedLineAttrs)
            } else {
                // Hard wrap
                processedLineAttrs.append(NSAttributedString(string: "\n", attributes: [.font: propFont]))
                currentParagraph.append(processedLineAttrs)

                let pStyle = lockedLineStyle(tabStops: accumulatedTabStops, colWidth: colWidth)
                currentParagraph.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: currentParagraph.length))

                fullText.append(currentParagraph)
                currentParagraph = NSMutableAttributedString()
                accumulatedTabStops = []
            }
        }

        if currentParagraph.length > 0 {
            let pStyle = lockedLineStyle(tabStops: accumulatedTabStops, colWidth: colWidth)
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
            
            // Only the visible area: the view spans the whole scrollback, and invalidating
            // all of it made every frame repaint hundreds of thousands of points.
            textView.setNeedsDisplay(textView.visibleRect)
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
        if !wasInAlternateBuffer && targetArchiveLength > lastArchiveLength && currentTotalLength >= lastArchiveLength {
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
        
        textView.setNeedsDisplay(textView.visibleRect)
        
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
    // Maps a point in the text view to the terminal cell under it, for mouse reports.
    // Only exact for the alternate screen, which is pinned to the top of the view.
    private func cell(at point: NSPoint) -> (row: Int32, col: Int32) {
        var rows = Int32(0)
        var cols = Int32(0)
        vterm_get_size(vterm, &rows, &cols)
        let inset = textView?.textContainerInset ?? .zero
        let row = Int32(max(0, (point.y - inset.height) / metrics.lineHeight))
        let col = Int32(max(0, (point.x - inset.width) / metrics.colWidth))
        return (min(row, rows - 1), min(col, cols - 1))
    }

    func handleScrollDelta(_ deltaY: CGFloat, at point: NSPoint? = nil) -> Bool {
        // Programs that asked for mouse reporting get wheel events. Otherwise we only translate
        // scrolling into arrow keys in the alternate buffer (e.g. man, less); the shell's own
        // history uses the native NSScrollView.
        guard ptyFD > 0, isAlternateBuffer || mouseReportingEnabled else { return false }
        
        // Reset accumulation if direction changes to prevent rubber-banding
        if (deltaY > 0 && accumulatedScrollDelta < 0) || (deltaY < 0 && accumulatedScrollDelta > 0) {
            accumulatedScrollDelta = 0
        }
        
        // Add the new physical movement to our accumulator
        accumulatedScrollDelta += deltaY
        
        // Wheel events report the pointer's cell, so e.g. the vim split under it scrolls.
        if mouseReportingEnabled, let point = point {
            let target = cell(at: point)
            vterm_mouse_move(vterm, target.row, target.col, VTERM_MOD_NONE)
        }

        // Define how many pixels of trackpad physical movement equals one terminal row
        let scrollThreshold: CGFloat = 10.0 // roughly one line of text
        
        while accumulatedScrollDelta >= scrollThreshold {
            // Scrolled UP (content moves DOWN) -> wheel up (button 4), or the UP arrow.
            // Arrows would page through Claude Code's prompt history instead of scrolling.
            if mouseReportingEnabled {
                vterm_mouse_button(vterm, 4, true, VTERM_MOD_NONE)
            } else {
                vterm_keyboard_key(vterm, VTERM_KEY_UP, VTERM_MOD_NONE)
            }
            accumulatedScrollDelta -= scrollThreshold
        }
        
        while accumulatedScrollDelta <= -scrollThreshold {
            // Scrolled DOWN (content moves UP) -> wheel down (button 5), or the DOWN arrow
            if mouseReportingEnabled {
                vterm_mouse_button(vterm, 5, true, VTERM_MOD_NONE)
            } else {
                vterm_keyboard_key(vterm, VTERM_KEY_DOWN, VTERM_MOD_NONE)
            }
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
