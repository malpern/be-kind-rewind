// CollectionGridAppKit.swift
//
// AppKit helper types extracted from CollectionGridView.swift.
// These types are used by the CollectionGridView Coordinator and must be
// internal (not private) so they are accessible across files within the module.

import AppKit
import SwiftUI
import TaggingKit

// MARK: - Container View

@MainActor
final class CollectionGridContainerView: NSView {
    let scrollView = NSScrollView()
    let collectionView = ClickableCollectionView()
    let flowLayout = NSCollectionViewFlowLayout()

    var onReadyForFlush: (() -> Void)?
    var onBoundsChanged: (() -> Void)?

    private var flushScheduled = false
    private var lastContentWidth: CGFloat = 0
    /// Registered `NSView.boundsDidChangeNotification` observer token.
    /// Stored as `nonisolated(unsafe)` so deinit can tear it down cleanly
    /// across the Objective-C/AppKit boundary, while the rest of the view
    /// remains main-actor isolated.
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    private var initialLayoutTask: Task<Void, Never>?

    var isReadyForCollectionWork: Bool {
        window != nil && contentWidth > 1
    }

    private var contentWidth: CGFloat {
        scrollView.contentView.bounds.width
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViewHierarchy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installBoundsObserverIfNeeded()
            scheduleInitialLayoutStabilization()
        } else {
            removeBoundsObserver()
            cancelInitialLayoutStabilization()
        }
        scheduleFlushIfReady()
    }

    deinit {
        initialLayoutTask?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func layout() {
        super.layout()
        handleWidthChangeIfNeeded()
    }

    func scheduleFlushIfReady() {
        guard isReadyForCollectionWork, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.isReadyForCollectionWork else { return }
            self.onReadyForFlush?()
        }
    }

    private func setupViewHierarchy() {
        wantsLayer = false

        flowLayout.scrollDirection = .vertical
        flowLayout.sectionHeadersPinToVisibleBounds = true

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        collectionView.autoresizingMask = [.width]
        collectionView.register(VideoItemCell.self, forItemWithIdentifier: VideoItemCell.identifier)
        collectionView.register(
            CollectionSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: CollectionSectionHeaderView.reuseIdentifier
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.contentView.postsBoundsChangedNotifications = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func installBoundsObserverIfNeeded() {
        guard boundsObserver == nil else { return }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWidthChangeIfNeeded()
                self?.onBoundsChanged?()
            }
        }
    }

    private func removeBoundsObserver() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    private func scheduleInitialLayoutStabilization() {
        guard initialLayoutTask == nil else { return }
        let delays: [TimeInterval] = [0.0, 0.05, 0.15, 0.3]
        initialLayoutTask = Task { @MainActor [weak self] in
            defer { self?.initialLayoutTask = nil }
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, let self else { return }
                self.forceRelayoutPass()
            }
        }
    }

    private func cancelInitialLayoutStabilization() {
        initialLayoutTask?.cancel()
        initialLayoutTask = nil
    }

    private func forceRelayoutPass() {
        let width = contentWidth
        guard width > 1 else { return }
        lastContentWidth = width
        collectionView.frame.size.width = width
        flowLayout.invalidateLayout()
        collectionView.needsLayout = true
        collectionView.layoutSubtreeIfNeeded()
        scheduleFlushIfReady()
    }

    private func handleWidthChangeIfNeeded() {
        let width = contentWidth
        guard abs(width - lastContentWidth) > 0.5 else { return }
        lastContentWidth = width
        collectionView.frame.size.width = width
        flowLayout.invalidateLayout()
        scheduleFlushIfReady()
    }
}

// MARK: - Section Header Model

enum CollectionSectionHeaderModel {
    case topic(
        name: String,
        count: Int,
        totalCount: Int?,
        topicId: Int64,
        scrollProgress: Double,
        highlightTerms: [String],
        displayMode: TopicDisplayMode,
        channels: [ChannelRecord],
        selectedChannelId: String?,
        videoCountForChannel: (String) -> Int,
        hasRecentContent: (String) -> Bool,
        latestPublishedAtForChannel: (String) -> Date?,
        themeLabelsForChannel: (String) -> [String],
        subscriberCountForChannel: (String) -> String?,
        onSelectChannel: (String) -> Void,
        onOpenCreatorDetail: (String) -> Void
    )
    case creator(
        channelName: String,
        channelIconUrl: URL?,
        channelIconData: Data?,
        channelUrl: URL?,
        count: Int,
        totalCount: Int?,
        topicNames: [String],
        sectionId: String,
        scrollProgress: Double,
        highlightTerms: [String],
        onInspect: () -> Void
    )

    var height: CGFloat {
        switch self {
        case let .topic(name: _, count: _, totalCount: _, topicId: _, scrollProgress: _, highlightTerms: _, displayMode: _, channels: channels, selectedChannelId: _, videoCountForChannel: _, hasRecentContent: _, latestPublishedAtForChannel: _, themeLabelsForChannel: _, subscriberCountForChannel: _, onSelectChannel: _, onOpenCreatorDetail: _):
            return channels.isEmpty ? 48 : 112
        case .creator:
            return 56
        }
    }
}

// MARK: - Video Cell (custom NSCollectionViewItem subclass)

final class VideoItemCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("VideoItemCell")

    private var hostingView: NSHostingView<VideoCellContent>?
    var representedIndexPath: IndexPath?
    var onHoverChange: ((Bool) -> Void)? {
        didSet {
            (view as? HoverTrackingView)?.onHoverChange = onHoverChange
        }
    }
    var onContextMenuRequest: ((NSPoint) -> NSMenu?)? {
        didSet {
            (view as? HoverTrackingView)?.onContextMenuRequest = onContextMenuRequest
        }
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func loadView() {
        let trackingView = HoverTrackingView(frame: .zero)
        trackingView.onHoverChange = onHoverChange
        trackingView.onContextMenuRequest = onContextMenuRequest
        self.view = trackingView
    }

    func configure(
        video: VideoGridItemModel,
        cacheDir: URL,
        thumbnailSize: Double,
        showMetadata: Bool,
        isSelected: Bool,
        highlightTerms: [String]
    ) {
        let content = VideoCellContent(
            video: video, cacheDir: cacheDir,
            thumbnailSize: thumbnailSize, showMetadata: showMetadata,
            isSelected: isSelected,
            highlightTerms: highlightTerms
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            hv.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: view.topAnchor),
                hv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            self.hostingView = hv
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedIndexPath = nil
        onHoverChange = nil
        onContextMenuRequest = nil
    }
}

// MARK: - Hover Tracking View

final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onContextMenuRequest: ((NSPoint) -> NSMenu?)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control),
           let menu = contextMenu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(for: event) ?? super.menu(for: event)
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return onContextMenuRequest?(point)
    }
}

// MARK: - Section Header (custom NSView subclass)

final class CollectionSectionHeaderView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SectionHeader")

    private var hostingView: NSHostingView<SectionHeaderContent>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(model: CollectionSectionHeaderModel) {
        let content = SectionHeaderContent(model: model)
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            hv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: topAnchor),
                hv.leadingAnchor.constraint(equalTo: leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hv
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
    }
}

// MARK: - Clickable Collection View

final class ClickableCollectionView: NSCollectionView {
    var onDoubleClickItem: ((IndexPath) -> Void)?
    var onContextMenuRequest: ((NSPoint) -> NSMenu?)?
    var onMarqueeSelection: ((NSRect, NSEvent.ModifierFlags, Bool) -> Void)?
    var onSaveToWatchLaterShortcut: (() -> Void)?
    var onSaveToPlaylistShortcut: (() -> Void)?
    var onMoveToPlaylistShortcut: (() -> Void)?
    var onDismissShortcut: (() -> Void)?
    var onNotInterestedShortcut: (() -> Void)?
    var onNotForMeShortcut: (() -> Void)?
    var onOpenSelectedShortcut: (() -> Void)?
    var onClearSelectionShortcut: (() -> Void)?

    private let marqueeLayer = CAShapeLayer()
    private var marqueeStartPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown, event.clickCount == 1, indexPathForItem(at: point) == nil {
            marqueeStartPoint = point
            updateMarqueeSelection(currentPoint: point, modifiers: event.modifierFlags, finalize: false)
            return
        }

        super.mouseDown(with: event)

        guard event.clickCount == 2 else { return }
        guard let indexPath = indexPathForItem(at: point) else { return }
        onDoubleClickItem?(indexPath)
    }

    override func mouseDragged(with event: NSEvent) {
        guard marqueeStartPoint != nil else {
            super.mouseDragged(with: event)
            return
        }
        let currentPoint = convert(event.locationInWindow, from: nil)
        updateMarqueeSelection(currentPoint: currentPoint, modifiers: event.modifierFlags, finalize: false)
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeStartPoint != nil {
            let currentPoint = convert(event.locationInWindow, from: nil)
            updateMarqueeSelection(currentPoint: currentPoint, modifiers: event.modifierFlags, finalize: true)
            clearMarqueeSelection()
            return
        }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return onContextMenuRequest?(point)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        // Vim navigation: hjkl → move selection left/down/up/right.
        // Uses NSResponder's move* methods which NSCollectionView
        // implements — they handle the grid layout correctly (j/k
        // move vertically across rows, h/l move within a row).
        if modifiers.isEmpty {
            switch key {
            case "h": moveLeft(nil);  return
            case "j": moveDown(nil);  return
            case "k": moveUp(nil);    return
            case "l": moveRight(nil); return
            default: break
            }
        }

        // Space → open selected video on YouTube (same as Enter).
        // The most natural "do the thing" key for keyboard-driven
        // browsing. Quick Look on macOS also uses space for preview.
        if modifiers.isEmpty, event.keyCode == 49 {
            onOpenSelectedShortcut?()
            return
        }

        // w → save to Watch Later (was "l" before vim keys took it)
        if modifiers.isEmpty, key == "w" {
            onSaveToWatchLaterShortcut?()
            return
        }
        if modifiers.isEmpty, key == "p" {
            onSaveToPlaylistShortcut?()
            return
        }
        if modifiers == [.shift], key == "p" {
            onMoveToPlaylistShortcut?()
            return
        }
        if modifiers.isEmpty, key == "x" {
            onNotForMeShortcut?()
            return
        }
        if modifiers.isEmpty, key == "d" {
            onDismissShortcut?()
            return
        }
        if modifiers.isEmpty, key == "n" {
            onNotInterestedShortcut?()
            return
        }
        // Enter / Return → open on YouTube
        if modifiers.isEmpty,
           event.keyCode == 36 || event.keyCode == 76 {
            onOpenSelectedShortcut?()
            return
        }
        // Escape → clear selection
        if modifiers.isEmpty, event.keyCode == 53 {
            onClearSelectionShortcut?()
            return
        }
        super.keyDown(with: event)
    }

    private func updateMarqueeSelection(currentPoint: NSPoint, modifiers: NSEvent.ModifierFlags, finalize: Bool) {
        guard let marqueeStartPoint else { return }
        let rect = NSRect(
            x: min(marqueeStartPoint.x, currentPoint.x),
            y: min(marqueeStartPoint.y, currentPoint.y),
            width: abs(currentPoint.x - marqueeStartPoint.x),
            height: abs(currentPoint.y - marqueeStartPoint.y)
        )

        if marqueeLayer.superlayer == nil {
            wantsLayer = true
            marqueeLayer.fillColor = NSColor.selectedControlColor.withAlphaComponent(0.12).cgColor
            marqueeLayer.strokeColor = NSColor.selectedControlColor.withAlphaComponent(0.75).cgColor
            marqueeLayer.lineWidth = 1
            marqueeLayer.lineDashPattern = [6, 4]
            layer?.addSublayer(marqueeLayer)
        }

        marqueeLayer.path = CGPath(rect: rect, transform: nil)
        onMarqueeSelection?(rect, modifiers, finalize)
    }

    private func clearMarqueeSelection() {
        marqueeStartPoint = nil
        marqueeLayer.removeFromSuperlayer()
        marqueeLayer.path = nil
    }
}
