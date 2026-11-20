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
    private var settingFrame = false
    private var cancellables = Set<AnyCancellable>()
    private var settleTask: Task<Void, Never>?
    /// Сколько раз окно реально меняло рамку (для --uitest: в покое и при открытии окошка — единицы, не десятки).
    private(set) var framesApplied = 0
    /// Прозрачные поля вокруг содержимого под тень (padding в HUDRootView).
    static let shadowPad: CGFloat = 14

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
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placeWindow() }
        }
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

    /// Переставить окно по текущим настройкам (после смены якоря из кода, для --uitest).
    func refreshPlacement() { placeWindow() }

    func resetPosition() {
        model.settings.anchor = nil
        model.settings.anchorLeft = false
        placeWindow()
    }

    private func contentSizeChanged(_ s: CGSize) {
        // Целые точки: дробные размеры (хвосты анимаций) не должны дёргать окно.
        let r = CGSize(width: ceil(s.width), height: ceil(s.height))
        guard r.width > 0, r.height > 0, r != size else { return }
        size = r
        placeWindow()
    }

    /// Угол-якорь держим в одной точке: у правого края — правый верхний (окошко растёт влево и вниз),
    /// у левого — левый верхний (растёт вправо и вниз). Рамку прижимаем к видимой части экрана:
    /// содержимое не уходит за края и под строку меню, тень может выходить за край.
    private func placeWindow() {
        let left = model.settings.anchorLeft
        // По умолчанию — основной экран (со строкой меню), а не NSScreen.main: тот означает «экран с фокусом»,
        // и при двух мониторах HUD перепрыгивал на другой экран при каждом изменении размера.
        guard let defaultScreen = NSScreen.screens.first ?? NSScreen.main else { return }
        var anchor = model.settings.anchor ?? Self.defaultAnchor(defaultScreen.visibleFrame, left: left)
        // Якорь вне всех экранов (отключили монитор) — в угол по умолчанию.
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(anchor) }) {
            anchor = Self.defaultAnchor(defaultScreen.visibleFrame, left: left)
        }
        let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(anchor) }) ?? defaultScreen
        let raw = NSRect(x: left ? anchor.x : anchor.x - size.width, y: anchor.y - size.height,
                         width: size.width, height: size.height)
        let frame = Self.clamp(raw, to: screen.visibleFrame, pad: Self.shadowPad)
        guard frame != panel.frame else { return }
        settingFrame = true
        panel.setFrame(frame, display: true)
        settingFrame = false
        framesApplied += 1
    }

    static func defaultAnchor(_ vf: NSRect, left: Bool) -> CGPoint {
        CGPoint(x: left ? vf.minX + 2 : vf.maxX - 2, y: vf.maxY + 2)
    }

    /// Рамка внутри видимой части экрана с допуском на прозрачные поля под тень.
    /// Если окно выше экрана, побеждает верх: ряд иконок и кнопки запроса важнее хвоста ленты.
    static func clamp(_ f: NSRect, to vf: NSRect, pad: CGFloat) -> NSRect {
        var r = f
        let area = vf.insetBy(dx: -pad, dy: -pad)
        if r.maxX > area.maxX { r.origin.x = area.maxX - r.width }
        if r.minX < area.minX { r.origin.x = area.minX }
        if r.minY < area.minY { r.origin.y = area.minY }
        if r.maxY > area.maxY { r.origin.y = area.maxY - r.height }
        return r
    }

    /// Пока HUD тащат, ничего не трогаем; когда отпустили — решаем, у какого края он теперь,
    /// запоминаем угол-якорь и возвращаем рамку в пределы экрана (не за край и не на строку меню).
    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !self.settingFrame else { return }
            self.settleTask?.cancel()
            self.settleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.settleAfterDrag()
            }
        }
    }

    private func settleAfterDrag() {
        let f = panel.frame
        let probe = NSPoint(x: f.midX, y: f.maxY - Self.shadowPad - 20)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let left = f.midX < vf.midX
        if model.settings.anchorLeft != left { model.settings.anchorLeft = left }
        // Сам угол-якорь — в пределах экрана: ряд иконок не остаётся на строке меню или за краем.
        let area = vf.insetBy(dx: -Self.shadowPad, dy: -Self.shadowPad)
        let x = left ? max(area.minX, min(f.minX, area.maxX - 80)) : min(area.maxX, max(f.maxX, area.minX + 80))
        let y = min(area.maxY, max(f.maxY, area.minY + 80))
        model.settings.anchor = CGPoint(x: x, y: y)
        placeWindow()
    }
}
