import AgentHUDCore
import AppKit
@preconcurrency import UserNotifications

// AgentHUD — HUD для ИИ-агентов: VS Code, терминал, приложения Claude и Codex.
//
//   AgentHUD                      обычный запуск (строка меню + плавающая панель)
//   AgentHUD --demo               с демонстрационными сессиями (без настоящих агентов)
//   AgentHUD --summary [ГГГГ-ММ-ДД]  сводка агентов за день в Markdown (по умолчанию — сегодня)
//   AgentHUD --render-previews D  нарисовать персонажей и окошки в PNG в папку D и выйти

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var model = AppModel(settings: settings)
    var hud: HUDController!
    var menu: StatusMenu!
    var map: AgentMapController!
    let demo = CommandLine.arguments.contains("--demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
        do {
            try model.start()
        } catch {
            if case SocketServer.StartError.alreadyRunning = error {
                NSLog("AgentHUD уже запущен — выходим")
                NSApp.terminate(nil)
                return
            }
            HookSetup.info("AgentHUD не запустился", "\(error)", style: .critical)
            NSApp.terminate(nil)
            return
        }
        hud = HUDController(model: model)
        menu = StatusMenu(model: model, hud: hud)
        map = AgentMapController(model: model)
        model.onRequestNeedsAttention = { [weak self] s in self?.notifyIfHidden(s) }
        model.onOpenMap = { [weak self] in self?.map.show() }
        if demo { Demo.populate(model) }
        hud.updateVisibility()
        if CommandLine.arguments.contains("--map") { map.show() }

        // Первый запуск: предложить подключиться (не в демо и не в тестовом режиме со своим сокетом).
        let testMode = ProcessInfo.processInfo.environment["AGENTHUD_SOCKET"] != nil
        if !demo, !testMode, !UserDefaults.standard.bool(forKey: "askedInstall") {
            UserDefaults.standard.set(true, forKey: "askedInstall")
            for kind in AgentKind.allCases where HookSetup.agentPresent(kind) && !HookSetup.isInstalled(kind) {
                HookSetup.install(kind, timeout: settings.hookTimeout)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func notifyIfHidden(_ s: AgentSession) {
        guard settings.notifications, !hud.isShown, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            let center = UNUserNotificationCenter.current()
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "\(s.projectName): \(s.state.title.lowercased())"
            c.body = s.title.isEmpty ? "Агент ждёт ответа" : s.title
            center.add(UNNotificationRequest(identifier: s.activePending?.id ?? UUID().uuidString, content: c, trigger: nil))
        }
    }
}

// Подключение без диалогов: AgentHUD --connect claude|codex|all [--timeout N], --disconnect …, --status
if let i = CommandLine.arguments.firstIndex(where: { $0 == "--connect" || $0 == "--disconnect" || $0 == "--status" }) {
    let args = CommandLine.arguments
    let verb = args[i]
    let target = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "all"
    // «all» — только агенты, которые есть на машине: не создаём ~/.codex без Codex.
    let kinds: [AgentKind] = MainActor.assumeIsolated {
        guard target == "all" else { return AgentKind(rawValue: target).map { [$0] } ?? [] }
        return AgentKind.allCases.filter { verb == "--connect" ? HookSetup.agentPresent($0) : true }
    }
    var timeout = HookTiming.defaultTimeout
    if let t = args.firstIndex(of: "--timeout"), t + 1 < args.count, let v = Int(args[t + 1]) { timeout = v }
    let code: Int32 = MainActor.assumeIsolated {
        guard !kinds.isEmpty else { print("Неизвестный агент: \(target). Варианты: claude, codex, all"); return 2 }
        var failed = false
        for kind in kinds {
            let file = HookSetup.tilde(kind.hooksFile.path)
            do {
                switch verb {
                case "--connect":
                    let r = try HookSetup.connect(kind, timeout: timeout)
                    print("\(kind.displayName): подключено → \(file)" + (r.backup.map { " (копия: \(HookSetup.tilde($0.path)))" } ?? " (без изменений)"))
                    if kind == .codex { print("  " + HookSetup.trustNote(kind)) }
                case "--disconnect":
                    let r = try HookSetup.disconnect(kind)
                    print("\(kind.displayName): отключено → \(file)" + (r.backup.map { " (копия: \(HookSetup.tilde($0.path)))" } ?? " (не было подключено)"))
                default:
                    print("\(kind.displayName): \(HookSetup.isInstalled(kind) ? "подключено" : "не подключено") (\(file))")
                }
            } catch {
                print("\(kind.displayName): ошибка — \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
    exit(code)
}

// Сводка за день: AgentHUD --summary [ГГГГ-ММ-ДД] — Markdown в stdout (для стендапа).
if let i = CommandLine.arguments.firstIndex(of: "--summary") {
    var day = Date()
    if i + 1 < CommandLine.arguments.count {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: CommandLine.arguments[i + 1]) else {
            print("Дата в формате ГГГГ-ММ-ДД, например 2026-11-20")
            exit(2)
        }
        day = d
    }
    print(DailySummary.markdown(DailySummary.build(ActivityLog.read(day: day)), day: day), terminator: "")
    exit(0)
}

// Автозапуск: AgentHUD --login-item on|off|status
if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
    do {
        switch arg {
        case "on": try LoginItem.set(true)
        case "off": try LoginItem.set(false)
        default: break
        }
        print("Автозапуск: \(LoginItem.statusText)")
        exit(0)
    } catch {
        print("Автозапуск: ошибка — \(error.localizedDescription). Сейчас: \(LoginItem.statusText)")
        exit(1)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-readme"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { FontLoader.register(); Previews.renderReadme(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    _ = NSApplication.shared
    MainActor.assumeIsolated { FontLoader.register(); Previews.render(to: dir) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let code = MainActor.assumeIsolated { SelfTest.run(fixtures: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(code)
}

if CommandLine.arguments.contains("--uitest") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let code = MainActor.assumeIsolated { UITest.run() }
    exit(code)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
