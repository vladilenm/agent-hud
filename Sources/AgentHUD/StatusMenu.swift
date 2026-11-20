import AgentHUDCore
import AppKit
import Combine
import SwiftUI

/// Иконка в строке меню со счётчиком ожидающих и панель управления (поповер на SwiftUI).
@MainActor
final class StatusMenu: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let hud: HUDController
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, hud: HUDController) {
        self.model = model
        self.hud = hud
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
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

    private var shownWaiting = -1

    private func updateButton() {
        guard let b = item.button else { return }
        let waiting = model.visibleSessions.filter { $0.state.needsUser }.count
        // Перерисовываем значок в строке меню, только когда меняется число ждущих, а не на каждом событии.
        guard waiting != shownWaiting else { return }
        shownWaiting = waiting
        let img = NSImage(systemSymbolName: waiting > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid",
                          accessibilityDescription: "AgentHUD")
        img?.isTemplate = true
        b.image = img
        b.imagePosition = .imageLeading
        b.title = waiting > 0 ? " \(waiting)" : ""
        b.toolTip = waiting > 0 ? "AgentHUD: ждут тебя — \(waiting)" : "AgentHUD"
    }

    // MARK: - Поповер

    var isShown: Bool { popover.isShown }
    var shownSize: CGSize { popover.contentViewController?.view.fittingSize ?? .zero }
    func close() { closePopover() }
    var windowVisible: Bool { popover.contentViewController?.view.window?.isVisible ?? false }

    /// Закрыть без анимации: анимированное закрытие NSPopover иногда не срабатывает,
    /// пока идёт анимация показа.
    private func closePopover() {
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { closePopover(); return }
        show()
    }

    func show() {
        guard let b = item.button else { return }
        popover.contentViewController = NSHostingController(rootView: panel())
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Статусы конфигов и автозапуска читаются при каждом открытии (и после действий).
    private func panel() -> ControlPanelView {
        var installed: [AgentKind: Bool] = [:]
        var present: [AgentKind: Bool] = [:]
        for k in AgentKind.allCases {
            installed[k] = HookSetup.isInstalled(k)
            present[k] = HookSetup.agentPresent(k)
        }
        return ControlPanelView(model: model, settings: model.settings, actions: actions(),
                                installed: installed, present: present, loginItem: LoginItem.isEnabled)
    }

    private func refresh() {
        guard popover.isShown, let host = popover.contentViewController as? NSHostingController<ControlPanelView> else { return }
        host.rootView = panel()
    }

    /// Диалоги (NSAlert) показываем после закрытия поповера, иначе он перекрывает их.
    private func afterClose(_ body: @escaping @MainActor () -> Void) {
        closePopover()
        Task { @MainActor in body() }
    }

    private func actions() -> PanelActions {
        var a = PanelActions()
        a.openSession = { [weak self] key in
            guard let self else { return }
            self.model.settings.hudVisible = true
            self.model.selectedKey = key
            self.model.selectedByUser = true
            self.closePopover()
        }
        a.focusSession = { [weak self] key in
            self?.closePopover()
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
        a.resetPosition = { [weak self] in
            self?.hud.resetPosition()
            self?.closePopover()
        }
        a.openLog = { [weak self] in
            self?.closePopover()
            let url = AgentHUDPaths.decisionsLog
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: url)
            }
            NSWorkspace.shared.open(url)
        }
        a.openMap = { [weak self] in
            self?.closePopover()
            self?.model.openMap()
        }
        a.openSummary = { [weak self] in
            guard let self else { return }
            self.closePopover()
            NSWorkspace.shared.open(self.model.writeSummary())
        }
        a.quit = { NSApp.terminate(nil) }
        return a
    }
}
