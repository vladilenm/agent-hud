import AgentHUDCore
import AppKit
import Foundation

/// `AgentHUD --selftest <папка с фикстурами>`: настоящий сокет-сервер и AppModel
/// против настоящего `agenthud-hook`, решения принимаются программно вместо кликов.
@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print((ok ? "  ok   " : "  FAIL ") + name + (ok ? "" : "  → \(detail())"))
        if !ok { failures += 1 }
    }

    static func run(fixtures: URL) -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sock = "/tmp/ahud-selftest-\(getpid()).sock"   // путь сокета ограничен 104 байтами
        setenv("AGENTHUD_SUPPORT_DIR", dir.path, 1)       // журнал решений — во временную папку
        defer { try? FileManager.default.removeItem(at: dir); unlink(sock) }

        let model = AppModel(settings: Settings())
        do { try model.start(socketPath: sock) } catch { print("не стартовал сервер: \(error)"); return 1 }
        guard let hook = HookSetup.bundledHook() else { print("нет agenthud-hook рядом с приложением"); return 1 }

        func fixture(_ n: String, _ agent: String) -> Data {
            let dir = agent == "claude" ? fixtures : fixtures.deletingLastPathComponent().appendingPathComponent(agent)
            return (try? Data(contentsOf: dir.appendingPathComponent(n + ".json"))) ?? Data()
        }

        /// Запустить хук в фоне; вернуть процесс и пайп stdout.
        func spawn(_ mode: String, _ fx: String, timeout: Int = 600, agent: String = "claude") -> (Process, Pipe) {
            let p = Process()
            p.executableURL = hook
            p.arguments = [agent, mode] + (mode == "event" ? [] : ["--timeout", "\(timeout)"])
            var env = ProcessInfo.processInfo.environment
            env["AGENTHUD_SOCKET"] = sock
            env["AGENTHUD_ANY_HOST"] = "1"
            p.environment = env
            let inp = Pipe(), out = Pipe()
            p.standardInput = inp
            p.standardOutput = out
            try? p.run()
            inp.fileHandleForWriting.write(fixture(fx, agent))
            try? inp.fileHandleForWriting.close()
            return (p, out)
        }

        func pump(_ seconds: Double, until: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }

        func finish(_ p: Process, _ out: Pipe) -> String {
            pump(5) { !p.isRunning }
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let key = "claude:11111111-2222-3333-4444-555555555555"

        print("События доходят до модели")
        for fx in ["SessionStart", "UserPromptSubmit", "PreToolUse-Bash"] {
            let (p, _) = spawn("event", fx); p.waitUntilExit()
        }
        pump(2) { model.store.session(key)?.steps.isEmpty == false }
        let s = model.store.session(key)
        check("сессия создана", s != nil)
        check("заголовок из промпта", s?.title.hasPrefix("First use") == true, s?.title ?? "nil")
        check("шаг Bash в ленте", s?.steps.first?.toolName == "Bash", "\(s?.steps ?? [])")
        check("TTY агента определён", s?.host.tty != nil || s?.host.agentPid != nil, "\(s?.host as Any)")

        print("Разрешить из HUD")
        var (p, out) = spawn("permission", "permission-PermissionRequest")
        pump(3) { model.store.session(key)?.activePending != nil }
        check("окошко открылось", model.store.session(key)?.state == .waitingPermission)
        check("карточка выбрана автоматически", model.selectedKey == key)
        if let rid = model.store.session(key)?.activePending?.id { model.decide(rid, .allow) }
        var o = finish(p, out)
        check("хук вернул allow", o.contains("\"behavior\":\"allow\""), o)
        check("окошко закрылось", model.store.session(key)?.activePending == nil)

        print("Отклонить с причиной")
        (p, out) = spawn("permission", "permission-PermissionRequest")
        pump(3) { model.store.session(key)?.activePending != nil }
        if let rid = model.store.session(key)?.activePending?.id { model.decide(rid, .deny(reason: "не сейчас")) }
        o = finish(p, out)
        check("хук вернул deny + причину", o.contains("\"behavior\":\"deny\"") && o.contains("не сейчас"), o)

        print("Ответ на вопрос")
        (p, out) = spawn("question", "question-PreToolUse-AskUserQuestion")
        pump(3) { model.store.session(key)?.activePending != nil }
        if let pend = model.store.session(key)?.activePending, case .question(let qs, _) = pend.kind {
            check("ждёт ответа", model.store.session(key)?.state == .waitingAnswer)
            model.decide(pend.id, .answer([qs[0].question: "Green, Blue"]))
        } else { check("вопрос пришёл", false) }
        o = finish(p, out)
        check("answers в updatedInput", o.contains("\"answers\"") && o.contains("Green, Blue"), o)

        print("Ответили в терминале → PostToolUse снимает окошко и отпускает хук")
        (p, out) = spawn("permission", "permission-PermissionRequest")
        pump(3) { model.store.session(key)?.activePending != nil }
        let (p2, _) = spawn("event", "PostToolUse-Bash"); p2.waitUntilExit()
        o = finish(p, out)
        check("хук отпущен с пустым выводом", !p.isRunning && o.isEmpty, "running=\(p.isRunning) out=\(o)")
        check("окошко снято", model.store.session(key)?.activePending == nil)

        print("Агент убил хук → окошко снимается")
        (p, out) = spawn("permission", "permission-PermissionRequest")
        pump(3) { model.store.session(key)?.activePending != nil }
        p.terminate()
        pump(3) { model.store.session(key)?.activePending == nil }
        check("окошко снято", model.store.session(key)?.activePending == nil)

        print("Просрочка")
        (p, out) = spawn("permission", "permission-PermissionRequest", timeout: 7)
        o = finish(p, out)
        pump(2) { model.store.session(key)?.state == .expired }
        check("хук ушёл сам и молча", !p.isRunning && o.isEmpty, o)
        check("в HUD «Просрочено»", model.store.session(key)?.state == .expired, "\(model.store.session(key)?.state as Any)")
        let (p3, _) = spawn("event", "Stop"); p3.waitUntilExit()
        pump(2) { model.store.session(key)?.state == .done }
        check("Stop → «Готово», просрочка убрана", model.store.session(key)?.state == .done && model.store.session(key)?.expiredPending == nil)

        print("Codex: события и разрешение")
        let ckey = "codex:cdx-1111"
        for fx in ["SessionStart", "UserPromptSubmit", "PreToolUse-apply_patch"] {
            let (p, _) = spawn("event", fx, agent: "codex"); p.waitUntilExit()
        }
        pump(2) { model.store.session(ckey)?.steps.isEmpty == false }
        check("сессия Codex создана", model.store.session(ckey)?.kind == .codex)
        check("шаг патча в ленте", model.store.session(ckey)?.steps.first?.summary.hasPrefix("Patch") == true,
              model.store.session(ckey)?.steps.first?.summary ?? "nil")
        (p, out) = spawn("permission", "permission-PermissionRequest", agent: "codex")
        pump(3) { model.store.session(ckey)?.activePending != nil }
        if let rid = model.store.session(ckey)?.activePending?.id { model.decide(rid, .allow) }
        o = finish(p, out)
        check("Codex получил allow без updatedInput", o.contains("\"behavior\":\"allow\"") && !o.contains("updatedInput"), o)
        let (p4, _) = spawn("event", "Interrupt", agent: "codex"); p4.waitUntilExit()
        pump(2) { model.store.session(ckey)?.state == .idle }
        check("Interrupt → «ждёт задачу»", model.store.session(ckey)?.state == .idle)

        print("Выход приложения отпускает висящие хуки")
        (p, out) = spawn("question", "question-PreToolUse-AskUserQuestion")
        pump(3) { model.store.session(key)?.activePending != nil }
        model.stop()
        o = finish(p, out)
        check("хук отпущен", !p.isRunning && o.isEmpty, o)

        print()
        print("ИТОГ:", failures == 0 ? "все проверки прошли" : "провалов: \(failures)")
        return failures == 0 ? 0 : 1
    }
}

/// `AgentHUD --placement-test`: window geometry and persistence without a WindowServer.
enum PlacementTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ result: Bool) {
            print((result ? "  ok   " : "  FAIL ") + name)
            if !result { failures += 1 }
        }

        let upperLeftDisplay = CGRect(x: -1280, y: 940, width: 1280, height: 860)
        let size = CGSize(width: 380, height: 300)
        let offset = CGPoint(x: 12, y: 8)
        for corner in HUDCorner.allCases {
            let frame = corner.frame(size: size, in: upperLeftDisplay, offset: offset)
            check("HUD \(corner.rawValue) stays inside a vertically offset display", upperLeftDisplay.contains(frame))
            check("HUD \(corner.rawValue) restores a dragged offset", corner.offset(of: frame, in: upperLeftDisplay) == offset)
            let smaller = corner.frame(size: CGSize(width: 120, height: 64), in: upperLeftDisplay, offset: offset)
            check("HUD \(corner.rawValue) keeps its anchor when resized", corner.offset(of: smaller, in: upperLeftDisplay) == offset)
        }

        let placeholder = CGRect(x: -80, y: 940, width: 18, height: 20)
        let fullScreen = CGRect(x: -1280, y: 940, width: 1280, height: 900)
        check("Menu ignores a status item whose window has not been positioned",
              WindowPlacement.statusButton(placeholder, in: fullScreen, above: upperLeftDisplay) == nil)
        let positionedButton = CGRect(x: -90, y: 1804, width: 35, height: 24)
        check("Menu accepts the status item in its display menu bar",
              WindowPlacement.statusButton(positionedButton, in: fullScreen, above: upperLeftDisplay) == positionedButton)
        let button = CGRect(x: -90, y: 1780, width: 35, height: 24)
        let menu = WindowPlacement.menuFrame(size: size, in: upperLeftDisplay, button: button, offset: nil)
        check("Menu stays below the status item, including its right edge", menu.maxY == button.minY && menu.maxX == 0)
        let dragOffset = CGPoint(x: 12, y: 45)
        let moved = WindowPlacement.menuFrame(size: size, in: upperLeftDisplay, button: nil, offset: dragOffset)
        let restoredWithButton = WindowPlacement.menuFrame(size: size, in: upperLeftDisplay, button: button, offset: dragOffset)
        check("Menu restores the display-relative offset after the status item becomes available",
              moved == restoredWithButton && moved.minX == upperLeftDisplay.minX + dragOffset.x &&
              moved.maxY == upperLeftDisplay.maxY - dragOffset.y)
        let cramped = CGRect(x: 0, y: -570, width: 500, height: 440)
        let tall = WindowPlacement.menuFrame(size: CGSize(width: 340, height: 860), in: cramped, button: nil,
                                             offset: CGPoint(x: 850, y: 500))
        check("A short display fits a scrollable menu after an out-of-bounds drag", cramped.contains(tall) && tall.height == cramped.height)

        let domain = "dev.agenthud.placement-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { return 1 }
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = Settings(defaults: defaults)
        check("Existing installations default to the primary display and top-right corner", settings.hudDisplay.isEmpty && settings.hudCorner == .topRight)
        settings.hudDisplay = "external"
        settings.hudCorner = .bottomLeft
        settings.setHUDOffset(offset, on: "external")
        settings.setMenuOffset(offset, on: "external")
        settings.setMenuOffset(.zero, on: "primary")
        let restored = Settings(defaults: defaults)
        check("HUD display, corner and offset survive reload", restored.hudDisplay == "external" &&
              restored.hudCorner == .bottomLeft && restored.hudOffset(on: "external") == offset)
        check("Menu offsets survive reload independently by display",
              restored.menuOffset(on: "external") == offset && restored.menuOffset(on: "primary") == .zero)
        restored.setMenuOffset(nil, on: "external")
        check("Reset only clears that menu position", restored.menuOffset(on: "external") == nil && restored.menuOffset(on: "primary") == .zero)
        return failures == 0 ? 0 : 1
    }
}

/// `AgentHUD --uitest`: настоящая панель HUD с демо-сессиями, синтетические клики и клавиши.
@MainActor
enum UITest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print((ok ? "  ok   " : "  FAIL ") + name + (ok ? "" : "  → \(detail())"))
            if !ok { failures += 1 }
        }
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-ui-\(getpid())")
        setenv("AGENTHUD_SUPPORT_DIR", dir.path, 1)       // журнал решений — во временную папку
        defer { try? FileManager.default.removeItem(at: dir) }
        let domain = "dev.agenthud.ui-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain), let screen = NSScreen.screens.first else {
            print("UI tests require a macOS display.")
            return 1
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(settings: Settings(defaults: defaults))
        Demo.populate(model)
        let hud = HUDController(model: model)
        hud.updateVisibility()
        let panel = hud.panel
        let layoutDeadline = Date().addingTimeInterval(5)
        while panel.frame.width <= 80, Date() < layoutDeadline { pump(0.05) }
        check("панель показана и получила размер содержимого", panel.isVisible && panel.frame.width > 80)
        guard panel.isVisible, panel.frame.width > 80 else { return 1 }
        let h = panel.frame.height, w = panel.frame.width
        check("панель в правом верхнем углу", abs(panel.frame.maxX - screen.visibleFrame.maxX) < 20,
              "\(panel.frame)")

        func click(_ p: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.sendEvent(e)
                }
                pump(0.05)
            }
        }

        print("Клик по персонажу открывает окошко")
        // Самый правый персонаж: отступ 14 + 8 по краю, персонаж 40 pt; ряд сверху.
        let rowY = h - (14 + 6 + 20)
        click(NSPoint(x: w - (14 + 8 + 20), y: rowY))
        pump(0.6)
        let first = model.selectedKey
        check("окошко открылось", first != nil, "selectedKey=nil")
        check("панель выросла под окошко", panel.frame.height > h + 100, "\(panel.frame.height)")

        print("Повторный клик закрывает")
        let h2 = panel.frame.height
        click(NSPoint(x: panel.frame.width - (14 + 8 + 20), y: h2 - (14 + 6 + 20)))
        pump(0.6)
        check("окошко закрылось", model.selectedKey == nil, "\(model.selectedKey ?? "")")

        print("⌘↩ разрешает запрос в открытом окошке")
        model.selectedKey = "claude:demo-a"
        model.selectedByUser = true
        pump(0.6)
        panel.makeKey()
        pump(0.2)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                    isARepeat: false, keyCode: 36) {
            _ = panel.performKeyEquivalent(with: e)
        }
        pump(0.5)
        check("запрос demo-a снят", model.store.session("claude:demo-a")?.activePending == nil,
              "\(model.store.session("claude:demo-a")?.state as Any)")

        print("Скрытие сессии")
        model.hide("codex:demo-d")
        pump(0.4)
        check("сессия скрыта", !model.visibleSessions.contains { $0.id == "codex:demo-d" })

        hud.setCorner(.bottomLeft)
        pump(0.4)
        check("HUD ушёл в левый нижний угол",
              abs(panel.frame.minX - screen.visibleFrame.minX) < 20 && abs(panel.frame.minY - screen.visibleFrame.minY) < 20)
        model.settings.hudDisplay = "disconnected-test-display"
        pump(0.2)
        check("Для отключённого дисплея HUD остаётся на основном",
              model.settings.hudDisplay == "disconnected-test-display" && screen.visibleFrame.contains(panel.frame))
        if let otherScreen = NSScreen.screens.dropFirst().first {
            model.settings.hudDisplay = otherScreen.placementID
            pump(0.3)
            check("HUD перемещается на выбранный дисплей",
                  otherScreen.visibleFrame.contains(panel.frame))
        } else {
            print("  skip Перемещение HUD на второй дисплей: доступен один дисплей")
        }
        model.settings.hudDisplay = ""
        pump(0.2)
        let rowOrigin = panel.frame.origin
        model.select("codex:demo-c")
        pump(0.5)
        check("Карточка растёт вверх от нижнего угла", panel.frame.origin == rowOrigin && panel.frame.height > h + 100)

        print("Панель в строке меню")
        let menu = StatusMenu(model: model, hud: hud)
        let menuWindow = menu.shownWindow
        let clickLocation = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 2)
        pump(0.2)
        menu.show(clickLocation: clickLocation)
        pump(0.6)
        check("панель открыта", menu.isShown)
        if let menuScreen = menuWindow.screen {
            let bounds = menuScreen.menuWindowBounds
            let initial = menuWindow.frame
            let dx: CGFloat = initial.minX - bounds.minX > 50 ? -50 : 50
            check("панель открылась ниже строки меню и внутри экрана", initial.height > 100 && bounds.contains(initial),
                  "\(initial) за пределами \(bounds)")
            menuWindow.setFrameOrigin(CGPoint(x: initial.minX + dx, y: initial.minY - 45))
            menu.finishDrag()
            let moved = menuWindow.frame
            check("позиция панели изменилась", moved.origin != initial.origin, "\(initial) → \(moved)")
            menu.close()
            menu.show(clickLocation: clickLocation)
            pump(0.6)
            let reopened = menuWindow.frame
            check("позиция восстановлена при открытии", reopened.minX == moved.minX && reopened.maxY == moved.maxY,
                  "\(moved) → \(reopened)")
            menu.resetPosition()
            pump(0.2)
            let reset = menuWindow.frame
            let offsetCleared = model.settings.menuOffset(on: menuScreen.placementID) == nil
            menu.close()
            menu.show(clickLocation: clickLocation)
            pump(0.6)
            let unmodified = menuWindow.frame
            check("сброс возвращает панель под значок",
                  offsetCleared && bounds.contains(reset) && bounds.contains(unmodified) &&
                  reset.maxY > moved.maxY && unmodified.maxY > moved.maxY,
                  "\(moved) → \(reset) → \(unmodified)")
        } else {
            check("открытая панель находится на дисплее", false)
        }
        if let otherScreen = NSScreen.screens.dropFirst().first {
            menu.close()
            menu.show(clickLocation: CGPoint(x: otherScreen.frame.midX, y: otherScreen.frame.maxY - 2))
            pump(0.3)
            check("панель открылась на экране нажатой иконки", otherScreen.menuWindowBounds.contains(menuWindow.frame))
        }
        menu.close()
        pump(0.4)
        check("панель закрыта", !menu.isShown)

        panel.orderOut(nil)
        print()
        print("ИТОГ:", failures == 0 ? "все проверки прошли" : "провалов: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
