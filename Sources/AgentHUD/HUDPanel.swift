import AppKit
import Combine
import SwiftUI

/// Плавающая панель без активации приложения: не крадёт фокус у терминала,
/// видна на всех рабочих столах и поверх полноэкранных окон.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Хостинг SwiftUI, который принимает первый клик даже без фокуса.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class HUDController: NSObject, NSWindowDelegate {
    let panel: HUDPanel
    private let model: AppModel
    private var size = CGSize(width: 80, height: 60)
    private var lastPlacedFrame: CGRect?
    private var movingWindow = false
    private var applyingPlacement = false
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.delegate = self

        let root = HUDRootView(model: model) { [weak self] s in
            Task { @MainActor in self?.contentSizeChanged(s) }
        }
        let host = FirstClickHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        migrateLegacyAnchor()

        Publishers.CombineLatest(model.settings.$hudDisplay, model.settings.$hudCorner)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.placeWindow() }
            .store(in: &cancellables)

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        // Карточку открыли кликом — даём панели фокус клавиатуры (для ⌘↩, Esc и поля ответа).
        model.$selectedKey
            .receive(on: RunLoop.main)
            .sink { [weak self] key in
                guard let self else { return }
                if key != nil, self.model.selectedByUser { self.panel.makeKey() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.migrateLegacyAnchor()
                self?.placeWindow()
            }
            .store(in: &cancellables)
    }

    var isShown: Bool { panel.isVisible }

    func updateVisibility() {
        let s = model.settings
        let any = !model.visibleSessions.isEmpty
        let shouldShow = s.hudVisible && any && (!s.hideWhenNothingWaits || model.hasAttention || model.selectedKey != nil)
        if shouldShow, !panel.isVisible {
            placeWindow()
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func setCorner(_ corner: HUDCorner) {
        model.settings.clearHUDOffsets()
        model.settings.clearLegacyHUDAnchor()
        model.settings.hudCorner = corner
        placeWindow()
    }

    func resetPosition() {
        setCorner(.topRight)
    }

    private func contentSizeChanged(_ s: CGSize) {
        guard s.width > 0, s.height > 0, s != size else { return }
        size = s
        placeWindow()
    }

    private func migrateLegacyAnchor() {
        let settings = model.settings
        guard settings.hudDisplay.isEmpty, let anchor = settings.legacyHUDAnchor,
              let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(anchor) })
        else { return }
        let bounds = screen.visibleFrame
        settings.setHUDOffset(CGPoint(x: bounds.maxX - anchor.x, y: bounds.maxY - anchor.y), on: screen.placementID)
        settings.hudDisplay = screen.placementID
        settings.clearLegacyHUDAnchor()
    }

    private func placeWindow() {
        guard !movingWindow else { return }
        let settings = model.settings
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.placementID == settings.hudDisplay }) ?? screens.first else { return }
        let offset = settings.hudOffset(on: screen.placementID) ?? CGPoint(x: 2, y: 0)
        let frame = settings.hudCorner.frame(size: size, in: screen.visibleFrame, offset: offset)
        applyingPlacement = true
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        applyingPlacement = false
        lastPlacedFrame = panel.frame
    }

    func windowWillMove(_ notification: Notification) {
        guard !applyingPlacement, !movingWindow, (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        movingWindow = true
        // AppKit can consume the mouse-up in a system window drag.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
                timer.invalidate()
                self.movingWindow = false
                self.saveDraggedPosition()
                self.placeWindow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func saveDraggedPosition() {
        guard panel.frame != lastPlacedFrame, let screen = panel.screen else { return }
        let settings = model.settings
        settings.clearLegacyHUDAnchor()
        settings.setHUDOffset(settings.hudCorner.offset(of: panel.frame, in: screen.visibleFrame), on: screen.placementID)
        let movesToOtherScreen = screen.placementID != NSScreen.screens.first?.placementID
        if (!settings.hudDisplay.isEmpty || movesToOtherScreen), settings.hudDisplay != screen.placementID {
            settings.hudDisplay = screen.placementID
        }
    }
}
