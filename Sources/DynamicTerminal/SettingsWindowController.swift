import AppKit

extension NSNotification.Name {
    static let terminalConfigChanged = NSNotification.Name("TerminalConfigChanged")
}

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var hasBuiltUI = false

    // Controls
    private var propFontField: NSTextField!
    private var monoFontField: NSTextField!
    private var fontSizeStepper: NSStepper!
    private var fontSizeValueLabel: NSTextField!
    private var lineHeightSlider: NSSlider!
    private var lineHeightValueLabel: NSTextField!
    private var bgColorWell: NSColorWell!
    private var textColorWell: NSColorWell!
    private var cursorColorWell: NSColorWell!

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 510),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        self.init(window: panel)
    }

    func show() {
        if !hasBuiltUI, let cv = window?.contentView {
            buildUI(in: cv)
            hasBuiltUI = true
        }
        loadValues()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI Construction

    private func buildUI(in cv: NSView) {
        cv.wantsLayer = true
        cv.layer?.backgroundColor = NSColor(hex: "#16161a")?.cgColor

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        outer.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: cv.topAnchor),
            outer.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
        ])

        // Header
        outer.addArrangedSubview(lbl("⟡  Settings", size: 16, weight: .semibold, color: .white))
        outer.addArrangedSubview(sep())

        // ── Font ──────────────────────────────────────────
        outer.addArrangedSubview(sectionHdr("Font"))

        propFontField = inputField("e.g. Copernicus Trial")
        propFontField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        outer.addArrangedSubview(row("Proportional", propFontField))

        monoFontField = inputField("e.g. JetBrainsMono")
        monoFontField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        outer.addArrangedSubview(row("Mono", monoFontField))

        fontSizeStepper = NSStepper()
        fontSizeStepper.minValue = 8; fontSizeStepper.maxValue = 36; fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self; fontSizeStepper.action = #selector(fontSizeChanged)
        fontSizeValueLabel = lbl("14", size: 12, color: .white)
        fontSizeValueLabel.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let sizeCtrl = hstack([fontSizeStepper, fontSizeValueLabel], spacing: 6)
        outer.addArrangedSubview(row("Size", sizeCtrl))

        lineHeightSlider = NSSlider(value: 1.3, minValue: 1.0, maxValue: 2.0,
                                    target: self, action: #selector(lineHeightChanged))
        lineHeightSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        lineHeightValueLabel = lbl("1.3", size: 12, color: .white)
        lineHeightValueLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let lhCtrl = hstack([lineHeightSlider, lineHeightValueLabel], spacing: 8)
        outer.addArrangedSubview(row("Line Height", lhCtrl))

        outer.addArrangedSubview(sep())

        // ── Colors ───────────────────────────────────────
        outer.addArrangedSubview(sectionHdr("Colors"))

        bgColorWell = colorWell()
        outer.addArrangedSubview(row("Background", bgColorWell))

        textColorWell = colorWell()
        outer.addArrangedSubview(row("Text", textColorWell))

        cursorColorWell = colorWell()
        outer.addArrangedSubview(row("Cursor", cursorColorWell))

        outer.addArrangedSubview(sep())

        // ── Themes ───────────────────────────────────────
        outer.addArrangedSubview(sectionHdr("Themes"))

        let themeRow = NSStackView()
        themeRow.orientation = .horizontal
        themeRow.spacing = 8
        for (name, _) in Self.themes {
            let b = NSButton(title: name, target: self, action: #selector(applyTheme(_:)))
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 11)
            themeRow.addArrangedSubview(b)
        }
        outer.addArrangedSubview(themeRow)

        // Flexible spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        outer.addArrangedSubview(spacer)

        // ── Buttons (right-aligned) ───────────────────────
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(doCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"

        let applyBtn = NSButton(title: "Apply", target: self, action: #selector(doApply))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"

        let btnSpacer = NSView()
        btnSpacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let btnRow = NSStackView(views: [btnSpacer, cancelBtn, applyBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        outer.addArrangedSubview(btnRow)
    }

    // MARK: - Helpers

    private func lbl(_ text: String, size: CGFloat,
                     weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = NSFont.systemFont(ofSize: size, weight: weight)
        t.textColor = color
        return t
    }

    private func sectionHdr(_ text: String) -> NSTextField {
        lbl(text.uppercased(), size: 10, weight: .semibold,
            color: NSColor(hex: "#666688") ?? .gray)
    }

    private func inputField(_ placeholder: String) -> NSTextField {
        let t = NSTextField()
        t.placeholderString = placeholder
        t.font = NSFont.systemFont(ofSize: 12)
        t.bezelStyle = .roundedBezel
        return t
    }

    private func colorWell() -> NSColorWell {
        let w = NSColorWell()
        w.widthAnchor.constraint(equalToConstant: 44).isActive = true
        w.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return w
    }

    private func sep() -> NSView {
        let b = NSBox(); b.boxType = .separator; return b
    }

    private func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .centerY
        return s
    }

    private func row(_ labelText: String, _ control: NSView, expand: Bool = false) -> NSView {
        let l = lbl(labelText, size: 12, color: NSColor(hex: "#9999bb") ?? .lightGray)
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let s = NSStackView(views: [l, control])
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 12
        return s
    }

    // MARK: - Data

    private func loadValues() {
        let c = TerminalConfig.current
        propFontField?.stringValue = c.proportionalFontName
        monoFontField?.stringValue = c.monoFontName
        fontSizeStepper?.doubleValue = Double(c.proportionalFontSize)
        fontSizeValueLabel?.stringValue = "\(Int(c.proportionalFontSize))"
        lineHeightSlider?.doubleValue = Double(c.lineHeightMultiple)
        lineHeightValueLabel?.stringValue = String(format: "%.1f", c.lineHeightMultiple)
        bgColorWell?.color = c.backgroundColor
        textColorWell?.color = c.textColor
        cursorColorWell?.color = c.cursorColor
    }

    private func collectValues() -> TerminalConfig? {
        var c = TerminalConfig.current
        let pf = propFontField.stringValue.trimmingCharacters(in: .whitespaces)
        let mf = monoFontField.stringValue.trimmingCharacters(in: .whitespaces)
        if !pf.isEmpty {
            guard NSFont(name: pf, size: 14) != nil else {
                showFontError(pf)
                return nil
            }
            c.proportionalFontName = pf
        }
        if !mf.isEmpty {
            guard NSFont(name: mf, size: 14) != nil else {
                showFontError(mf)
                return nil
            }
            c.monoFontName = mf
        }
        let sz = CGFloat(fontSizeStepper.doubleValue)
        c.proportionalFontSize = sz
        c.monoFontSize = sz
        c.lineHeightMultiple = CGFloat(lineHeightSlider.doubleValue)
        c.backgroundColorHex = bgColorWell.color.toHex()
        c.textColorHex = textColorWell.color.toHex()
        c.cursorColorHex = cursorColorWell.color.toHex()
        return c
    }

    private func showFontError(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Font not found"
        alert.informativeText = "\"\(name)\" is not installed. Check the name in Font Book."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func fontSizeChanged() {
        fontSizeValueLabel.stringValue = "\(Int(fontSizeStepper.doubleValue))"
    }

    @objc private func lineHeightChanged() {
        lineHeightValueLabel.stringValue = String(format: "%.1f", lineHeightSlider.doubleValue)
    }

    @objc private func applyTheme(_ sender: NSButton) {
        guard let t = Self.themes.first(where: { $0.0 == sender.title })?.1 else { return }
        propFontField.stringValue = t.proportionalFontName
        monoFontField.stringValue = t.monoFontName
        fontSizeStepper.doubleValue = Double(t.proportionalFontSize)
        fontSizeValueLabel.stringValue = "\(Int(t.proportionalFontSize))"
        lineHeightSlider.doubleValue = Double(t.lineHeightMultiple)
        lineHeightValueLabel.stringValue = String(format: "%.1f", t.lineHeightMultiple)
        bgColorWell.color = t.backgroundColor
        textColorWell.color = t.textColor
        cursorColorWell.color = t.cursorColor
    }

    @objc private func doApply() {
        guard let c = collectValues() else { return }
        TerminalConfig.current = c
        c.save()
        NotificationCenter.default.post(name: .terminalConfigChanged, object: nil)
        window?.close()
    }

    @objc private func doCancel() {
        window?.close()
    }

    // MARK: - Built-in Themes

    static let themes: [(String, TerminalConfig)] = [
        ("One Dark", TerminalConfig()),
        ("Dracula", {
            var c = TerminalConfig()
            c.backgroundColorHex = "#282a36"; c.textColorHex = "#f8f8f2"; c.cursorColorHex = "#ff79c6"
            c.ansiColorsHex = [
                "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
            ]
            return c
        }()),
        ("Nord", {
            var c = TerminalConfig()
            c.backgroundColorHex = "#2e3440"; c.textColorHex = "#eceff4"; c.cursorColorHex = "#88c0d0"
            c.ansiColorsHex = [
                "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
            ]
            return c
        }()),
        ("Tokyo Night", {
            var c = TerminalConfig()
            c.backgroundColorHex = "#1a1b26"; c.textColorHex = "#a9b1d6"; c.cursorColorHex = "#7aa2f7"
            c.ansiColorsHex = [
                "#15161e", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                "#414868", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
            ]
            return c
        }()),
    ]
}
