import AgentHUDCore
import AppKit
import Combine
import SwiftUI

/// Иконка в строке меню со счётчиком ожидающих и плавающая панель управления.
@MainActor
final class StatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let hud: HUDController
    private let window = MenuWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    private var host: NSHostingController<MenuWindowContent>?
    private var screenID: String?
    private var buttonFrame: CGRect?
    private var buttonScreenID: String?
    private var measuredHeight: CGFloat = 420
    private var clickMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, hud: HUDController) {
        self.model = model
        self.hud = hud
        super.init()
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.dismiss = { [weak self] in self?.close() }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.screenConfigurationChanged() }
            .store(in: &cancellables)
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateButton()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let b = item.button else { return }
        let waiting = model.visibleSessions.filter { $0.state.needsUser }.count
        let img = NSImage(systemSymbolName: waiting > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid",
                          accessibilityDescription: "AgentHUD")
        img?.isTemplate = true
        b.image = img
        b.imagePosition = .imageLeading
        b.title = waiting > 0 ? " \(waiting)" : ""
        b.toolTip = waiting > 0 ? "AgentHUD: ждут тебя — \(waiting)" : "AgentHUD"
    }

    var isShown: Bool { window.isVisible }
    var shownWindow: NSWindow { window }

    func close() {
        window.orderOut(nil)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    @objc private func toggle(_ sender: Any?) {
        if isShown { close(); return }
        switch NSApp.currentEvent?.type {
        case .leftMouseUp, .rightMouseUp: show(clickLocation: NSEvent.mouseLocation)
        default: show()
        }
    }

    func show(clickLocation: CGPoint? = nil) {
        guard !isShown, let button = item.button, let statusWindow = button.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screens = NSScreen.screens
        let clickedScreen = clickLocation.flatMap { point in screens.first { $0.frame.contains(point) } }
        guard let screen = clickedScreen ?? statusWindow.screen ?? screens.first else { return }
        screenID = screen.placementID
        buttonScreenID = screen.placementID
        let bounds = screen.menuWindowBounds
        buttonFrame = WindowPlacement.statusButton(anchor, in: screen.frame, above: bounds)
            ?? clickLocation.map { CGRect(x: $0.x, y: bounds.maxY, width: 0, height: 0) }
        measuredHeight = 420
        let host = NSHostingController(rootView: content())
        host.sizingOptions = []
        self.host = host
        window.contentViewController = host
        placeWindow(on: screen)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.close()
        }) { clickMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if let self, event.window === self.hud.panel { self.close() }
            return event
        }) { clickMonitors.append(monitor) }
    }

    private var placementScreen: NSScreen? {
        NSScreen.screens.first { $0.placementID == screenID } ?? NSScreen.screens.first
    }

    private func placeWindow(on screen: NSScreen) {
        let bounds = screen.menuWindowBounds
        let frame = WindowPlacement.menuFrame(size: CGSize(width: ControlPanelView.width, height: measuredHeight),
                                              in: bounds,
                                              button: screen.placementID == buttonScreenID ? buttonFrame : nil,
                                              offset: model.settings.menuOffset(on: screen.placementID))
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    private func screenConfigurationChanged() {
        guard isShown, let screen = placementScreen else { return }
        if let button = item.button, let statusWindow = button.window, let statusScreen = statusWindow.screen {
            buttonScreenID = statusScreen.placementID
            let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            buttonFrame = WindowPlacement.statusButton(anchor, in: statusScreen.frame, above: statusScreen.menuWindowBounds)
        } else {
            buttonScreenID = nil
            buttonFrame = nil
        }
        placeWindow(on: screen)
    }

    func finishDrag() {
        guard let screen = window.screen ?? placementScreen else { return }
        screenID = screen.placementID
        let offset = HUDCorner.topLeft.offset(of: window.frame, in: screen.menuWindowBounds)
        model.settings.setMenuOffset(CGPoint(x: max(0, offset.x), y: max(0, offset.y)), on: screen.placementID)
        placeWindow(on: screen)
    }

    func resetPosition() {
        if let screen = placementScreen {
            model.settings.setMenuOffset(nil, on: screen.placementID)
        }
        screenID = buttonScreenID
        if let screen = placementScreen {
            model.settings.setMenuOffset(nil, on: screen.placementID)
            placeWindow(on: screen)
        }
    }

    private func content() -> MenuWindowContent {
        MenuWindowContent(panel: panel(), onSize: { [weak self] height in
            guard let self, self.isShown, let screen = self.placementScreen, self.measuredHeight != height else { return }
            self.measuredHeight = height
            self.placeWindow(on: screen)
        })
    }

    /// Статусы конфигов и автозапуска читаются при каждом открытии (и после действий).
    private func panel() -> ControlPanelView {
        var installed: [AgentKind: Bool] = [:]
        for k in AgentKind.allCases { installed[k] = HookSetup.isInstalled(k) }
        return ControlPanelView(model: model, settings: model.settings, actions: actions(),
                                installed: installed, loginItem: LoginItem.isEnabled)
    }

    private func refresh() {
        guard isShown else { return }
        host?.rootView = content()
    }

    /// Диалоги (NSAlert) показываем после закрытия панели, иначе она перекрывает их.
    private func afterClose(_ body: @escaping @MainActor () -> Void) {
        close()
        Task { @MainActor in body() }
    }

    private func actions() -> PanelActions {
        var a = PanelActions()
        a.openSession = { [weak self] key in
            guard let self else { return }
            self.model.settings.hudVisible = true
            self.model.selectedKey = key
            self.model.selectedByUser = true
            self.close()
        }
        a.focusSession = { [weak self] key in
            self?.close()
            self?.model.open(key)
        }
        a.connect = { [weak self] kind in
            guard let self else { return }
            let timeout = self.model.settings.hookTimeout
            self.afterClose { HookSetup.install(kind, timeout: timeout) }
        }
        a.disconnect = { [weak self] kind in
            self?.afterClose { HookSetup.uninstall(kind) }
        }
        a.setTimeout = { [weak self] seconds in
            guard let self, seconds != self.model.settings.hookTimeout else { return }
            self.model.settings.hookTimeout = seconds
            let kinds = AgentKind.allCases.filter { HookSetup.isInstalled($0) }
            guard !kinds.isEmpty else { self.refresh(); return }
            // Время зашито в команду хука — переустанавливаем с подтверждением.
            self.afterClose { for k in kinds { HookSetup.install(k, timeout: seconds) } }
        }
        a.setLoginItem = { [weak self] on in
            do { try LoginItem.set(on) } catch {
                self?.afterClose { HookSetup.info("Не получилось изменить автозапуск", error.localizedDescription, style: .warning) }
                return
            }
            self?.refresh()
        }
        a.setHUDDisplay = { [weak self] display in
            guard let self else { return }
            self.model.settings.clearLegacyHUDAnchor()
            self.model.settings.hudDisplay = display
        }
        a.setHUDCorner = { [weak self] corner in self?.hud.setCorner(corner) }
        a.resetPosition = { [weak self] in self?.hud.resetPosition() }
        a.resetMenuPosition = { [weak self] in self?.resetPosition() }
        a.finishMenuDrag = { [weak self] in self?.finishDrag() }
        a.openLog = { [weak self] in
            self?.close()
            let url = AgentHUDPaths.decisionsLog
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: url)
            }
            NSWorkspace.shared.open(url)
        }
        a.quit = { NSApp.terminate(nil) }
        return a
    }
}

private final class MenuWindow: NSPanel {
    var dismiss: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss() }
}

private struct MenuWindowContent: View {
    var panel: ControlPanelView
    var onSize: (CGFloat) -> Void

    var body: some View {
        ScrollView {
            panel
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                    Task { @MainActor in onSize(height) }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Brand.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
