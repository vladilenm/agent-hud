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

        print("Разрешить всегда (шаблон правила)")
        (p, out) = spawn("permission", "permission-PermissionRequest")
        pump(3) { model.store.session(key)?.activePending != nil }
        if let pend = model.store.session(key)?.activePending {
            check("подсказки Claude дошли до окошка", !pend.suggestions.isEmpty)
            let rule: JSONValue = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                   "rules": [["toolName": "Bash", "ruleContent": "node *"]]]
            model.decide(pend.id, .allowWith([rule]))
        } else { check("запрос пришёл", false) }
        o = finish(p, out)
        check("allow + updatedPermissions", o.contains("\"behavior\":\"allow\"") && o.contains("\"updatedPermissions\"")
              && o.contains("node *"), o)

        print("План: одобрить и принимать правки")
        (p, out) = spawn("permission", "permission-ExitPlanMode")
        pump(3) { model.store.session(key)?.activePending != nil }
        if let pend = model.store.session(key)?.activePending {
            check("окошко плана", pend.kind.isPlan, "\(pend.kind)")
            model.decide(pend.id, .allowWith(PermissionRules.planApproval(acceptEdits: true)))
        } else { check("план пришёл", false) }
        o = finish(p, out)
        check("allow + updatedInput с планом + setMode acceptEdits",
              o.contains("\"updatedInput\"") && o.contains("Добавить фильтр") && o.contains("acceptEdits"), o)

        print("План: доработать с замечанием")
        (p, out) = spawn("permission", "permission-ExitPlanMode")
        pump(3) { model.store.session(key)?.activePending != nil }
        if let rid = model.store.session(key)?.activePending?.id { model.decide(rid, .deny(reason: "без миграций")) }
        o = finish(p, out)
        check("deny + замечание к плану", o.contains("\"behavior\":\"deny\"") && o.contains("без миграций"), o)

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
        let model = AppModel(settings: Settings())
        // Позиция по умолчанию, а не оставшаяся от прошлых запусков (у отладочной сборки свои настройки).
        model.settings.anchor = nil
        model.settings.anchorLeft = false
        Demo.populate(model)
        let hud = HUDController(model: model)
        hud.updateVisibility()
        pump(1.0)
        let panel = hud.panel
        check("панель показана", panel.isVisible)
        let h = panel.frame.height, w = panel.frame.width
        let home = panel.screen ?? NSScreen.screens.first
        check("панель в правом верхнем углу основного экрана", panel.screen == NSScreen.screens.first
                && (home.map { abs(panel.frame.maxX - $0.visibleFrame.maxX) < 20 } ?? false),
              "\(panel.frame) / \(home?.visibleFrame ?? .zero)")

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
        model.hide("claude:demo-d")
        pump(0.4)
        check("сессия скрыта", !model.visibleSessions.contains { $0.id == "claude:demo-d" })

        print("Метки проектов под иконками")
        let labels = model.projectShortLabels
        check("у каждой видимой сессии своя метка", Set(model.visibleSessions.map { labels[$0.cwd] ?? "" }).count
                == Set(model.visibleSessions.map(\.cwd)).count, "\(labels)")

        print("Без мерцания: окно меняет рамку разово, анимации иконок не перевешиваются")
        model.settings.animations = true
        model.selectedKey = nil
        model.selectedByUser = false
        pump(0.6)
        let frames0 = hud.framesApplied, installs0 = MotionClock.installs
        model.selectedKey = "claude:demo-b"
        model.selectedByUser = true
        pump(1.0)
        let openFrames = hud.framesApplied - frames0
        check("открытие окошка: рамка окна меняется ≤ 2 раз (было ~70 в секунду)", openFrames <= 2, "\(openFrames)")
        model.selectedKey = nil
        pump(1.0)
        let closeFrames = hud.framesApplied - frames0 - openFrames
        check("закрытие окошка: рамка окна меняется ≤ 2 раз", closeFrames <= 2, "\(closeFrames)")
        check("анимации иконок не перевешивались при открытии и закрытии", MotionClock.installs == installs0,
              "перевешиваний: \(MotionClock.installs - installs0)")
        let installs1 = MotionClock.installs
        model.inject([AgentEvent(kind: .claude, sessionId: "demo-new", cwd: "/Users/dev/acme-docs", host: Demo.vscodeHost,
                                 time: Date(), body: .promptSubmitted("Новая задача"))])
        pump(1.0)
        check("новая сессия: перевешена только её анимация", MotionClock.installs - installs1 <= 1,
              "перевешиваний: \(MotionClock.installs - installs1)")
        let pad = HUDController.shadowPad
        let vf = (panel.screen ?? NSScreen.screens.first)?.visibleFrame ?? .zero

        print("Огромный ввод не выталкивает кнопки за экран")
        let huge = String(repeating: "export const meta = { name: 'x' } // очень длинная строка без переносов ", count: 900)
        model.inject([
            AgentEvent(kind: .claude, sessionId: "demo-big", cwd: "/Users/dev/acme-big", host: Demo.vscodeHost,
                       time: Date(), body: .promptSubmitted("Огромный запрос")),
            AgentEvent(kind: .claude, sessionId: "demo-big", cwd: "/Users/dev/acme-big", host: Demo.vscodeHost, time: Date(),
                       body: .permissionRequested(requestId: "big-1", toolName: "Workflow", input: ["script": .string(huge)],
                                                  deadline: Date().addingTimeInterval(500), suggestions: [])),
        ])
        model.selectedKey = "claude:demo-big"
        model.selectedByUser = true
        pump(1.0)
        check("окно с огромным вводом не выше экрана", panel.frame.height <= vf.height + 2 * pad + 1,
              "окно \(panel.frame.height) при экране \(vf.height)")
        check("окно с огромным вводом в пределах экрана", vf.insetBy(dx: -pad - 1, dy: -pad - 1).contains(panel.frame),
              "\(panel.frame) / \(vf)")
        check("окошко компактное: подробности прокручиваются", panel.frame.height < 760, "\(panel.frame.height)")

        print("HUD у левого края: окошко раскрывается вправо и остаётся на экране")
        model.settings.anchorLeft = true
        model.settings.anchor = CGPoint(x: vf.minX + 10, y: vf.maxY + 2)
        hud.refreshPlacement()
        pump(0.6)
        check("левый край окна у якоря", abs(panel.frame.minX - (vf.minX + 10)) < 2, "\(panel.frame.minX) vs \(vf.minX + 10)")
        check("окно в пределах экрана", vf.insetBy(dx: -pad - 1, dy: -pad - 1).contains(panel.frame), "\(panel.frame) / \(vf)")

        print("HUD бросили на строку меню — возвращается на экран")
        model.selectedKey = nil
        pump(0.4)
        panel.setFrameOrigin(NSPoint(x: vf.midX + 120, y: vf.maxY + 60 - panel.frame.height + 40))
        pump(1.0)
        check("верх окна не выше видимой части экрана", panel.frame.maxY <= vf.maxY + pad + 1, "\(panel.frame.maxY) vs \(vf.maxY)")
        check("сторона определилась по месту: правая половина → якорь справа", model.settings.anchorLeft == false)
        model.settings.anchor = nil
        model.settings.anchorLeft = false
        hud.refreshPlacement()
        model.hide("claude:demo-big")
        model.hide("claude:demo-new")
        pump(0.3)

        print("Карта агентов")
        let map = AgentMapController(model: model)
        map.show()
        pump(0.6)
        check("окно карты открыто", map.isShown)
        map.close()
        pump(0.3)
        check("окно карты закрыто", !map.isShown)

        print("Панель в строке меню")
        let menu = StatusMenu(model: model, hud: hud)
        menu.show()
        pump(0.6)
        check("поповер открыт", menu.isShown)
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        check("помещается по высоте", menu.shownSize.height > 300 && menu.shownSize.height < screenH,
              "\(menu.shownSize) при экране \(screenH)")
        menu.close()
        pump(0.4)
        check("поповер закрыт", !menu.isShown, "isShown=\(menu.isShown) окно видно=\(menu.windowVisible)")

        panel.orderOut(nil)
        print()
        print("ИТОГ:", failures == 0 ? "все проверки прошли" : "провалов: \(failures)")
        return failures == 0 ? 0 : 1
    }
}
