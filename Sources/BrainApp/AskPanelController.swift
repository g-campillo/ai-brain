import AppKit
import SwiftUI

/// Borderless panels refuse key status unless overridden; key status without
/// `NSApp.activate()` is the whole Spotlight trick (`.nonactivatingPanel`).
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { // Esc, wherever focus sits
        AskPanelController.shared.hide()
    }
}

@MainActor
final class AskPanelController: NSObject, NSWindowDelegate {
    static let shared = AskPanelController()

    static let width: CGFloat = 640
    static let compactHeight: CGFloat = 64
    static let expandedHeight: CGFloat = 520

    private let panel: AskPanel
    private var session: AskSession?

    private override init() {
        panel = AskPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.compactHeight),
            styleMask: [.borderless, .nonactivatingPanel], // key without activating the app
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear // SwiftUI draws the rounded material
        panel.hasShadow = true
        panel.hidesOnDeactivate = false // NSPanel default is true — would vanish wrongly
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        guard !panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let fresh = AskSession() // closing the panel ends the thread; each summon is fresh
        session = fresh
        // Fresh hosting view every show: pristine UI state + reliable .onAppear focus seeding.
        panel.contentView = NSHostingView(rootView: AskView(session: fresh))
        place(height: Self.compactHeight)
        panel.makeKeyAndOrderFront(nil) // deliberately NO NSApp.activate()
    }

    func hide() {
        guard panel.isVisible else { return } // absorbs orderOut → resignKey re-entry
        session?.cancel()
        session = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func setExpanded(_ expanded: Bool) {
        var frame = panel.frame
        let height = expanded ? Self.expandedHeight : Self.compactHeight
        frame.origin.y += frame.height - height // keep top edge fixed, grow downward
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: true)
    }

    private func place(height: CGFloat) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(
                x: visible.midX - Self.width / 2,
                y: visible.maxY - visible.height * 0.25 - height, // top quarter, Spotlight-ish
                width: Self.width,
                height: height
            ),
            display: false
        )
    }

    func windowDidResignKey(_ notification: Notification) {
        hide() // click-away dismiss, Spotlight-like
    }
}
