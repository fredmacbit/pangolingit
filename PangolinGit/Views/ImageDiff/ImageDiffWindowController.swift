import Foundation
import Cocoa
import ImageIO
import PangolinGitCore

/// Image comparison mirroring TortoiseGitIDiff (`src/TortoiseIDiff/`): side by side (linked or
/// independent, horizontal or vertical), overlay with an alpha slider, difference blend (TortoiseIDiff's
/// XOR mode), curtain; zoom, fit, original size, pan by dragging, multi-frame navigation and an info
/// line with size, resolution and bit depth per image.
public final class ImageDiffWindowController: NSWindowController {

    public enum DiffMode: Int {
        case sideBySide = 0
        case alphaBlend = 1
        case difference = 2
        case curtain = 3
    }

    private let oldImageURL: URL?
    private let newImageURL: URL?
    private let oldSource: ImageSource?
    private let newSource: ImageSource?
    private var frameIndex = 0

    private var modeSegment: NSSegmentedControl!
    private var blendSlider: NSSlider!
    private var zoomLabel: NSTextField!
    private var linkCheckbox: NSButton!
    private var verticalCheckbox: NSButton!
    private var frameStepper: NSStepper?
    private var frameLabel: NSTextField?
    private var infoLabel: NSTextField!

    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let overlayScroll = NSScrollView()
    private let leftCanvas = ImageCanvasView()
    private let rightCanvas = ImageCanvasView()
    private let overlayCanvas = ImageCanvasView()
    private var paneStack: NSStackView!
    private var isSyncing = false

    public init(oldImageURL: URL?, newImageURL: URL?) {
        self.oldImageURL = oldImageURL
        self.newImageURL = newImageURL
        self.oldSource = oldImageURL.flatMap(ImageSource.init)
        self.newSource = newImageURL.flatMap(ImageSource.init)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let titleName = newImageURL?.lastPathComponent ?? oldImageURL?.lastPathComponent ?? "Image"
        window.title = "Image Diff — \(titleName)"
        window.minSize = NSSize(width: 720, height: 480)

        super.init(window: window)
        setupUI()
        showFrame(0)
        updateMode(.sideBySide)
        DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        modeSegment = NSSegmentedControl(labels: ["Side by Side", "Overlay", "Difference", "Curtain"], trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeSegment.selectedSegment = 0
        modeSegment.toolTip = "Difference highlights changed pixels (TortoiseIDiff's XOR blend)"

        blendSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(blendChanged))
        blendSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        blendSlider.toolTip = "Alpha of the new image / curtain position"

        func button(_ title: String, _ tip: String, _ action: Selector, key: String = "") -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            if !key.isEmpty {
                button.keyEquivalent = key
                button.keyEquivalentModifierMask = [.command]
            }
            return button
        }
        let zoomOut = button("−", "Zoom out (⌘-)", #selector(onZoomOut), key: "-")
        let zoomIn = button("+", "Zoom in (⌘+)", #selector(onZoomIn), key: "=")
        let fit = button("Fit", "Fit in window (⌘0)", #selector(onFit), key: "0")
        let original = button("1:1", "Original size (⌘1)", #selector(onOriginalSize), key: "1")
        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        linkCheckbox = NSButton(checkboxWithTitle: "Link", target: self, action: #selector(onLinkChanged))
        linkCheckbox.state = .on
        linkCheckbox.toolTip = "Scroll and zoom both images together"
        verticalCheckbox = NSButton(checkboxWithTitle: "Vertical", target: self, action: #selector(onArrangementChanged))
        verticalCheckbox.toolTip = "Arrange the images above each other"

        var items: [NSView] = [modeSegment, blendSlider, zoomOut, zoomLabel, zoomIn, fit, original, linkCheckbox, verticalCheckbox]
        let frames = max(oldSource?.frameCount ?? 1, newSource?.frameCount ?? 1)
        if frames > 1 {
            let stepper = NSStepper()
            stepper.minValue = 0
            stepper.maxValue = Double(frames - 1)
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(onFrameChanged)
            let label = NSTextField(labelWithString: "Frame 1/\(frames)")
            frameStepper = stepper
            frameLabel = label
            items += [label, stepper]
        }
        let toolbar = NSStackView(views: items)
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)

        for (scroll, canvas) in [(leftScroll, leftCanvas), (rightScroll, rightCanvas), (overlayScroll, overlayCanvas)] {
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.05
            scroll.maxMagnification = 32
            scroll.backgroundColor = .underPageBackgroundColor
            scroll.documentView = canvas
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(magnified(_:)), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        }
        leftCanvas.mode = .single(0)
        rightCanvas.mode = .single(1)

        paneStack = NSStackView(views: [leftScroll, rightScroll, overlayScroll])
        paneStack.distribution = .fillEqually
        paneStack.spacing = 6
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(paneStack)

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            paneStack.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            paneStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            paneStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            paneStack.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -8),
            infoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            infoLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Frames and info

    private func showFrame(_ index: Int) {
        frameIndex = index
        let old = oldSource?.image(at: index)
        let new = newSource?.image(at: index)
        for canvas in [leftCanvas, rightCanvas, overlayCanvas] {
            canvas.images = [old, new]
        }
        frameLabel?.stringValue = "Frame \(index + 1)/\(Int(frameStepper?.maxValue ?? 0) + 1)"
        infoLabel.stringValue = "Old: \(oldSource?.info ?? "none") ➔ New: \(newSource?.info ?? "none")"
    }

    @objc private func onFrameChanged() {
        showFrame(Int(frameStepper?.integerValue ?? 0))
    }

    // MARK: - Modes

    @objc private func modeChanged() {
        updateMode(DiffMode(rawValue: modeSegment.selectedSegment) ?? .sideBySide)
    }

    private func updateMode(_ mode: DiffMode) {
        let sideBySide = mode == .sideBySide
        leftScroll.isHidden = !sideBySide
        rightScroll.isHidden = !sideBySide
        overlayScroll.isHidden = sideBySide
        blendSlider.isEnabled = mode == .alphaBlend || mode == .curtain
        linkCheckbox.isEnabled = sideBySide
        verticalCheckbox.isEnabled = sideBySide
        switch mode {
        case .alphaBlend: overlayCanvas.mode = .overlay
        case .difference: overlayCanvas.mode = .difference
        case .curtain: overlayCanvas.mode = .curtain
        case .sideBySide: break
        }
        overlayCanvas.blend = CGFloat(blendSlider.doubleValue)
        if !sideBySide { overlayScroll.magnification = leftScroll.magnification }
        updateZoomLabel()
    }

    @objc private func blendChanged() {
        overlayCanvas.blend = CGFloat(blendSlider.doubleValue)
    }

    @objc private func onArrangementChanged() {
        paneStack.orientation = verticalCheckbox.state == .on ? .vertical : .horizontal
    }

    @objc private func onLinkChanged() {
        if linkCheckbox.state == .on { sync(from: leftScroll) }
    }

    // MARK: - Zoom

    private var visibleScrolls: [NSScrollView] {
        [leftScroll, rightScroll, overlayScroll].filter { !$0.isHidden }
    }

    private func setMagnification(_ value: CGFloat) {
        for scroll in [leftScroll, rightScroll, overlayScroll] {
            let clamped = min(max(value, scroll.minMagnification), scroll.maxMagnification)
            scroll.setMagnification(clamped, centeredAt: NSPoint(x: scroll.documentVisibleRect.midX, y: scroll.documentVisibleRect.midY))
        }
        updateZoomLabel()
    }

    @objc private func onZoomIn() { setMagnification((visibleScrolls.first?.magnification ?? 1) * 1.25) }
    @objc private func onZoomOut() { setMagnification((visibleScrolls.first?.magnification ?? 1) / 1.25) }
    @objc private func onOriginalSize() { setMagnification(1) }
    @objc private func onFit() { fitToWindow() }

    private func fitToWindow() {
        guard let scroll = visibleScrolls.first else { return }
        let size = leftCanvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let available = scroll.contentSize
        setMagnification(min(available.width / size.width, available.height / size.height, 1))
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(Int(round((visibleScrolls.first?.magnification ?? 1) * 100)))%"
    }

    // MARK: - Linked scrolling

    @objc private func scrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView,
              let source = [leftScroll, rightScroll].first(where: { $0.contentView === clip }) else { return }
        sync(from: source)
    }

    @objc private func magnified(_ notification: Notification) {
        guard let source = notification.object as? NSScrollView else { return }
        if linkCheckbox.state == .on || source === overlayScroll {
            setMagnification(source.magnification)
        }
        updateZoomLabel()
    }

    private func sync(from source: NSScrollView) {
        guard linkCheckbox.state == .on, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let other = source === leftScroll ? rightScroll : leftScroll
        if abs(other.magnification - source.magnification) > 0.001 { other.magnification = source.magnification }
        other.contentView.scroll(to: source.contentView.bounds.origin)
        other.reflectScrolledClipView(other.contentView)
    }
}

/// One image file with its frames (animated GIF, multi-page TIFF) and properties.
private struct ImageSource {
    let source: CGImageSource
    let frameCount: Int
    let info: String

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        self.source = source
        frameCount = max(1, CGImageSourceGetCount(source))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var parts = ["\(width)×\(height) px"]
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double { parts.append("\(Int(dpi)) dpi") }
        if let depth = properties[kCGImagePropertyDepth] as? Int { parts.append("\(depth)-bit") }
        if properties[kCGImagePropertyHasAlpha] as? Bool == true { parts.append("alpha") }
        if frameCount > 1 { parts.append("\(frameCount) frames") }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        info = parts.joined(separator: ", ")
    }

    /// The frame as an image whose point size equals its pixel size, so 100 % shows real pixels.
    func image(at index: Int) -> NSImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, min(index, frameCount - 1), nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Document view drawing one image or a blend of both; drag to pan (TortoiseIDiff's hand tool).
private final class ImageCanvasView: NSView {
    enum Mode: Equatable {
        case single(Int)
        case overlay
        case difference
        case curtain
    }

    var images: [NSImage?] = [nil, nil] {
        didSet { resize() }
    }
    var mode: Mode = .overlay {
        didSet { needsDisplay = true }
    }
    var blend: CGFloat = 0.5 {
        didSet { needsDisplay = true }
    }
    private var dragStart: NSPoint?

    override var isFlipped: Bool { true }

    private func resize() {
        let sizes = images.compactMap { $0?.size }
        let size = NSSize(width: sizes.map(\.width).max() ?? 1, height: sizes.map(\.height).max() ?? 1)
        setFrameSize(size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCheckerboard(in: dirtyRect)
        let old = images.first ?? nil
        let new = images.count > 1 ? images[1] : nil
        func draw(_ image: NSImage?, operation: NSCompositingOperation = .sourceOver, fraction: CGFloat = 1) {
            guard let image else { return }
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: operation, fraction: fraction, respectFlipped: true, hints: nil)
        }
        switch mode {
        case .single(let index):
            draw(index == 0 ? old : new)
        case .overlay:
            draw(old)
            draw(new, fraction: blend)
        case .difference:
            NSColor.black.setFill()
            bounds.fill()
            draw(old)
            draw(new, operation: .difference)
        case .curtain:
            let split = bounds.width * blend
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: 0, width: split, height: bounds.height).clip()
            draw(old)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: split, y: 0, width: bounds.width - split, height: bounds.height).clip()
            draw(new)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setFill()
            NSRect(x: split - 1, y: 0, width: 2, height: bounds.height).fill()
        }
    }

    /// Transparent areas show a checkerboard, as in TortoiseIDiff.
    private func drawCheckerboard(in rect: NSRect) {
        let tile: CGFloat = 8
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        let startX = floor(rect.minX / tile), endX = ceil(rect.maxX / tile)
        let startY = floor(rect.minY / tile), endY = ceil(rect.maxY / tile)
        var y = startY
        while y < endY {
            var x = startX
            while x < endX {
                if (Int(x) + Int(y)) % 2 == 0 { NSRect(x: x * tile, y: y * tile, width: tile, height: tile).fill() }
                x += 1
            }
            y += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let clip = enclosingScrollView?.contentView else { return }
        let scale = enclosingScrollView?.magnification ?? 1
        let delta = NSPoint(x: (event.locationInWindow.x - start.x) / scale, y: (event.locationInWindow.y - start.y) / scale)
        var origin = clip.bounds.origin
        origin.x -= delta.x
        origin.y += delta.y
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        dragStart = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        NSCursor.pop()
    }
}
