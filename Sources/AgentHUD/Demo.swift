import AgentHUDCore
import AppKit
import SwiftUI

/// Демонстрационные сессии: посмотреть HUD без настоящих агентов.
@MainActor
enum Demo {
    static let vscodeHost = HostInfo(appBundleId: HostInfo.vscode, appName: "Code", entrypoint: HostInfo.vscodeEntrypoint)

    static func events(now: Date = Date()) -> [AgentEvent] {
        func ev(_ sid: String, _ cwd: String, _ dt: TimeInterval, _ body: AgentEvent.Body, tty: String = "/dev/ttys004",
                agentId: String? = nil) -> AgentEvent {
            // demo-c — Codex в терминале, demo-b — Claude в терминале, остальные — Claude Code в VS Code.
            let kind: AgentKind = sid == "demo-c" ? .codex : .claude
            let host = (sid == "demo-b" || sid == "demo-c") ? HostInfo(termProgram: "Apple_Terminal", tty: tty) : vscodeHost
            return AgentEvent(kind: kind, sessionId: sid, cwd: cwd, agentId: agentId, host: host,
                       time: now.addingTimeInterval(dt), body: body)
        }
        let a = "demo-a", b = "demo-b", c = "demo-c", d = "demo-d", e = "demo-e"
        let pa = "/Users/dev/acme-mobile", pb = "/Users/dev/acme-admin/front", pc = "/Users/dev/acme-api", pd = "/Users/dev/acme-web"
        let deadline = now.addingTimeInterval(540)
        let suggestion: JSONValue = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                     "rules": [["toolName": "Bash", "ruleContent": "npm test -- vacancies"]]]
        let plan = """
        # План: фильтр вакансий по городу

        1. Добавить `city` в `useVacancyFilters` и в запрос `/vacancies`.
        2. Выпадающий список городов в `VacancyFilters.tsx` (данные из `/dictionaries/cities`).
        3. Сохранять выбранный город в URL, чтобы фильтр переживал перезагрузку.
        4. Тесты: хук фильтров и снапшот панели.

        Затронутые файлы: 4. Миграций нет.
        """
        let qInput: JSONValue = ["questions": [[
            "question": "Какую базу данных взять для очереди задач?",
            "header": "База",
            "multiSelect": false,
            "options": [
                ["label": "SQLite", "description": "Один файл, без сервера"],
                ["label": "Postgres", "description": "Уже есть на сервере"],
                ["label": "Redis", "description": "Быстро, но ещё один сервис"],
            ],
        ]]]
        return [
            ev(a, pa, -1500, .sessionStarted(source: "startup", model: "claude-opus-5-5")),
            ev(a, pa, -1490, .promptSubmitted("Почини экран вакансий: список пустой после фильтра")),
            ev(a, pa, -1400, .toolStarted(toolName: "Read", input: ["file_path": .string("\(pa)/feature/vacancies/ui/List.tsx")], toolUseId: "a1")),
            ev(a, pa, -1399, .toolFinished(toolName: "Read", input: ["file_path": .string("\(pa)/feature/vacancies/ui/List.tsx")], toolUseId: "a1", durationMs: 40, failed: false)),
            ev(a, pa, -1380, .subagentStarted(agentId: "sub-1", agentType: "Explore")),
            ev(a, pa, -1370, .toolStarted(toolName: "Grep", input: ["pattern": "useVacancyFilters"], toolUseId: "s1"), agentId: "sub-1"),
            ev(a, pa, -1369, .toolFinished(toolName: "Grep", input: ["pattern": "useVacancyFilters"], toolUseId: "s1", durationMs: 220, failed: false), agentId: "sub-1"),
            ev(a, pa, -1360, .toolStarted(toolName: "Read", input: ["file_path": .string("\(pa)/hooks/useVacancyFilters.ts")], toolUseId: "s2"), agentId: "sub-1"),
            ev(a, pa, -1359, .toolFinished(toolName: "Read", input: ["file_path": .string("\(pa)/hooks/useVacancyFilters.ts")], toolUseId: "s2", durationMs: 30, failed: false), agentId: "sub-1"),
            ev(a, pa, -1340, .subagentStopped(agentId: "sub-1")),
            ev(a, pa, -1300, .toolStarted(toolName: "Edit", input: ["file_path": .string("\(pa)/hooks/useVacancyFilters.ts")], toolUseId: "a2")),
            ev(a, pa, -1298, .toolFinished(toolName: "Edit", input: ["file_path": .string("\(pa)/hooks/useVacancyFilters.ts")], toolUseId: "a2", durationMs: 120, failed: false)),
            ev(a, pa, -60, .toolStarted(toolName: "Bash", input: ["command": "npm test -- vacancies"], toolUseId: "a3")),
            ev(a, pa, -60, .permissionRequested(requestId: "demo-perm", toolName: "Bash",
                                                input: ["command": "npm test -- vacancies",
                                                        "description": "Прогнать тесты экрана вакансий"],
                                                deadline: deadline, suggestions: [suggestion])),

            ev(b, pb, -900, .sessionStarted(source: "startup", model: "claude-sonnet-5-5"), tty: "/dev/ttys005"),
            ev(b, pb, -890, .promptSubmitted("Добавь в админку очередь задач для рассылок"), tty: "/dev/ttys005"),
            ev(b, pb, -800, .toolStarted(toolName: "WebFetch", input: ["url": "https://code.claude.com/docs/en/hooks"], toolUseId: "b1"), tty: "/dev/ttys005"),
            ev(b, pb, -795, .toolFinished(toolName: "WebFetch", input: ["url": "https://code.claude.com/docs/en/hooks"], toolUseId: "b1", durationMs: 4800, failed: false), tty: "/dev/ttys005"),
            ev(b, pb, -20, .toolStarted(toolName: "AskUserQuestion", input: qInput, toolUseId: "b2"), tty: "/dev/ttys005"),
            ev(b, pb, -20, .questionAsked(requestId: "demo-q", questions: ClaudeCodeAdapter.parseQuestions(qInput), rawInput: qInput, deadline: deadline), tty: "/dev/ttys005"),

            ev(c, pc, -300, .sessionStarted(source: "startup", model: "gpt-5.5-codex"), tty: "/dev/ttys006"),
            ev(c, pc, -290, .promptSubmitted("Добавь эндпоинт словаря городов"), tty: "/dev/ttys006"),
            ev(c, pc, -100, .toolStarted(toolName: "Write", input: ["file_path": .string("\(pc)/src/dictionaries/cities.ts")], toolUseId: "c1"), tty: "/dev/ttys006"),
            ev(c, pc, -99, .toolFinished(toolName: "Write", input: ["file_path": .string("\(pc)/src/dictionaries/cities.ts")], toolUseId: "c1", durationMs: 90, failed: false), tty: "/dev/ttys006"),
            ev(c, pc, -5, .toolStarted(toolName: "Bash", input: ["command": "npm run lint"], toolUseId: "c2"), tty: "/dev/ttys006"),

            ev(d, pd, -2000, .sessionStarted(source: "startup", model: "claude-opus-5-5")),
            ev(d, pd, -1990, .promptSubmitted("Обнови тексты на странице тарифов")),
            ev(d, pd, -1900, .toolStarted(toolName: "Read", input: ["file_path": .string("\(pd)/messages/ru.json")], toolUseId: "d1")),
            ev(d, pd, -1899, .toolFinished(toolName: "Read", input: ["file_path": .string("\(pd)/messages/ru.json")], toolUseId: "d1", durationMs: 30, failed: false)),
            ev(d, pd, -1850, .toolStarted(toolName: "Edit", input: ["file_path": .string("\(pd)/messages/ru.json")], toolUseId: "d2")),
            ev(d, pd, -1849, .toolFinished(toolName: "Edit", input: ["file_path": .string("\(pd)/messages/ru.json")], toolUseId: "d2", durationMs: 60, failed: false)),
            ev(d, pd, -1800, .stopped(lastMessage: "Готово: обновил 12 строк в messages/ru.json и messages/tg.json, проверил, что ключи совпадают в обоих языках. Сборка проходит.", failed: false)),

            ev(e, pd, -400, .sessionStarted(source: "startup", model: "claude-opus-5-5")),
            ev(e, pd, -390, .promptSubmitted("Спланируй фильтр вакансий по городу")),
            ev(e, pd, -300, .toolStarted(toolName: "Glob", input: ["pattern": "src/**/Vacanc*.tsx"], toolUseId: "e1")),
            ev(e, pd, -299, .toolFinished(toolName: "Glob", input: ["pattern": "src/**/Vacanc*.tsx"], toolUseId: "e1", durationMs: 15, failed: false)),
            ev(e, pd, -30, .toolStarted(toolName: "ExitPlanMode", input: ["plan": .string(plan)], toolUseId: "e2")),
            ev(e, pd, -30, .permissionRequested(requestId: "demo-plan", toolName: "ExitPlanMode", input: ["plan": .string(plan)],
                                                deadline: deadline, suggestions: [])),
        ]
    }

    static func populate(_ model: AppModel) {
        model.inject(events())
    }

    /// Журнал активности демо-дня — для вкладки «Сегодня» в превью и картинках README.
    static func activity(now: Date = Date()) -> [ActivityRecord] {
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now }
        func turn(_ sid: String, _ cwd: String, _ start: Date, _ mins: Int, _ prompt: String, _ msg: String,
                  edits: Int, cmds: Int, files: [String], failed: Bool = false) -> [ActivityRecord] {
            let project = ProjectNames.displayName(cwd: cwd)
            let stats = TurnStats(tools: ["Edit": edits, "Bash": cmds, "Read": edits + 2], files: files, durationSec: mins * 60)
            return [
                ActivityRecord(kind: .prompt, time: start, agent: "claude", session: sid, project: project, cwd: cwd, text: prompt),
                ActivityRecord(kind: .stop, time: start.addingTimeInterval(TimeInterval(mins * 60)), agent: "claude", session: sid,
                               project: project, cwd: cwd, text: msg, failed: failed, stats: stats),
            ]
        }
        let m = "/Users/dev/acme-mobile", w = "/Users/dev/acme-web", ap = "/Users/dev/acme-api"
        return turn("s1", m, at(9, 40), 18, "Почини экран вакансий: список пустой после фильтра",
                    "Фильтр терял страницу при смене города; поправил хук и добавил тест.", edits: 3, cmds: 4,
                    files: ["hooks/useVacancyFilters.ts", "feature/vacancies/ui/List.tsx"])
            + turn("s2", w, at(10, 25), 9, "Обнови тексты на странице тарифов", "Обновил 12 строк в двух языках.",
                   edits: 2, cmds: 1, files: ["messages/ru.json", "messages/tg.json"])
            + turn("s3", ap, at(11, 5), 34, "Добавь эндпоинт словаря городов", "Эндпоинт и миграция готовы, тесты зелёные.",
                   edits: 6, cmds: 7, files: ["src/dictionaries/cities.ts", "src/routes.ts", "migrations/0042_cities.sql"])
            + turn("s1", m, at(12, 10), 25, "Сделай пустое состояние для списка вакансий", "Линтер упал на типах — нужен ответ по дизайну.",
                   edits: 4, cmds: 3, files: ["feature/vacancies/ui/Empty.tsx"], failed: true)
            + [ActivityRecord(kind: .decision, time: at(12, 20), agent: "claude", session: "s1", project: "acme-mobile", cwd: m,
                              text: "$ npm test -- vacancies", detail: "разрешено всегда")]
    }
}

/// Рендер персонажей и окошек в PNG — для проверки внешнего вида без экрана.
@MainActor
enum Previews {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = Settings()
        let model = AppModel(settings: settings)
        model.inject(Demo.events())

        let states: [AgentState] = [.working, .waitingPermission, .waitingAnswer, .expired, .done, .error, .idle]
        let seeds: [UInt64] = (0..<6).map { stableHash("claude:session-\($0)") }

        for scheme in [ColorScheme.light, .dark] {
            let grid = VStack(alignment: .leading, spacing: 10) {
                ForEach(AvatarStyle.allCases) { style in
                    HStack(spacing: 10) {
                        Text(style.title).font(.system(size: 12, weight: .semibold)).frame(width: 64, alignment: .leading)
                        ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                            AvatarView(seed: seeds[0], state: st, style: style, size: 44, animated: false, kind: .claude)
                        }
                        Divider().frame(height: 40)
                        ForEach(seeds.dropFirst(), id: \.self) { s in
                            AvatarView(seed: s, state: .working, style: style, size: 44, animated: false, kind: s % 2 == 0 ? .claude : .codex)
                        }
                    }
                }
            }
            .padding(20)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
            .environment(\.colorScheme, scheme)
            write(grid, to: dir.appendingPathComponent("avatars-\(scheme == .dark ? "dark" : "light").png"))
        }

        for key in ["claude:demo-a", "claude:demo-b", "claude:demo-d", "claude:demo-e"] {
            model.selectedKey = key
            let v = HUDRootView(model: model)
                .environment(\.solidBackground, true)
                .background(Color(white: 0.85))
            write(v, to: dir.appendingPathComponent("hud-\(key.replacingOccurrences(of: "claude:", with: "")).png"))
        }
        model.selectedKey = nil
        write(HUDRootView(model: model).environment(\.solidBackground, true).background(Color(white: 0.85)),
              to: dir.appendingPathComponent("hud-row.png"))
        model.selectedKey = "claude:demo-b"
        write(HUDRootView(model: model).environment(\.solidBackground, true).environment(\.colorScheme, .dark)
                .background(Color(white: 0.2)),
              to: dir.appendingPathComponent("hud-demo-b-dark.png"))
        // Настоящие AppKit-контролы ImageRenderer не рисует — снимаем живой NSHostingView.
        for (key, scheme) in [("claude:demo-a", "light"), ("claude:demo-b", "light"), ("claude:demo-d", "light"),
                              ("claude:demo-e", "light"), ("claude:demo-b", "dark")] {
            model.selectedKey = key
            snapshot(HUDRootView(model: model).environment(\.solidBackground, true), dark: scheme == "dark",
                     to: dir.appendingPathComponent("live-\(key.replacingOccurrences(of: "claude:", with: ""))-\(scheme).png"))
        }
        // Огромный ввод (как длинный скрипт Workflow): подробности прокручиваются, кнопки на месте.
        let huge = (1...400).map { "  step\($0): agent('проверить гипотезу номер \($0) и вернуть находки', {schema: FINDINGS})," }
            .joined(separator: "\n")
        model.inject([
            AgentEvent(kind: .claude, sessionId: "demo-big", cwd: "/Users/dev/acme-hub", host: Demo.vscodeHost, time: Date(),
                       body: .promptSubmitted("Найди причины мерцания")),
            AgentEvent(kind: .claude, sessionId: "demo-big", cwd: "/Users/dev/acme-hub", host: Demo.vscodeHost, time: Date(),
                       body: .permissionRequested(requestId: "big-1", toolName: "Workflow",
                                                  input: ["script": .string("export const meta = {\n" + huge + "\n}"),
                                                          "args": ["mode": "diagnose", "lenses": 5]],
                                                  deadline: Date().addingTimeInterval(540), suggestions: [])),
        ])
        model.selectedKey = "claude:demo-big"
        snapshot(HUDRootView(model: model).environment(\.solidBackground, true), dark: false,
                 to: dir.appendingPathComponent("live-big-light.png"))
        model.hide("claude:demo-big")
        // Панель в строке меню, светлая и тёмная.
        for dark in [false, true] {
            for tab in [0, 1] {
                snapshot(ControlPanelView(model: model, settings: settings,
                                          installed: [.claude: true, .codex: false], present: [.claude: true, .codex: false],
                                          loginItem: true, tab: tab),
                         dark: dark, to: dir.appendingPathComponent("panel-\(tab)-\(dark ? "dark" : "light").png"))
            }
        }
        // Карта агентов: «Сейчас» и «Сегодня» (журнал — демо-день во временной папке).
        model.selectedKey = nil
        withDemoActivity {
            for dark in [false, true] {
                for tab in [0, 1] {
                    snapshot(AgentMapView(model: model, tab: tab).frame(width: 1100, height: 760), dark: dark,
                             to: dir.appendingPathComponent("map-\(tab == 0 ? "now" : "today")-\(dark ? "dark" : "light").png"))
                }
            }
        }
        print("Превью сохранены в \(dir.path)")
    }

    /// Подменить папку данных на временную с демо-журналом на время рендера.
    static func withDemoActivity(_ body: () -> Void) {
        let old = ProcessInfo.processInfo.environment["AGENTHUD_SUPPORT_DIR"]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-preview-\(getpid())")
        setenv("AGENTHUD_SUPPORT_DIR", tmp.path, 1)
        try? FileManager.default.removeItem(at: tmp)
        for r in Demo.activity() { ActivityLog.append(r) }
        body()
        try? FileManager.default.removeItem(at: tmp)
        if let old { setenv("AGENTHUD_SUPPORT_DIR", old, 1) } else { unsetenv("AGENTHUD_SUPPORT_DIR") }
    }

    /// Картинки для README: настоящие окна HUD и панели на демо-данных.
    static func renderReadme(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = Settings()
        settings.avatarStyle = .logo
        let model = AppModel(settings: settings)
        model.inject(Demo.events())

        // Главная картинка: HUD с запросом разрешения и панель в строке меню.
        let darkBg = NSColor(srgbRed: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0, alpha: 1)
        let lightBg = NSColor(srgbRed: 0xF4 / 255.0, green: 0xF4 / 255.0, blue: 0xF5 / 255.0, alpha: 1)
        let installed: [AgentKind: Bool] = [.claude: true, .codex: false]

        // Главная картинка: HUD с запросом разрешения и панель в строке меню.
        model.selectedKey = "claude:demo-a"
        let hero = HStack(alignment: .top, spacing: 28) {
            HUDRootView(model: model)
            ControlPanelView(model: model, settings: settings, installed: installed, present: installed, loginItem: true)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .padding(.top, 14)
        }
        .padding(28)
        .environment(\.solidBackground, true)
        snapshot(hero, dark: true, to: dir.appendingPathComponent("hero.png"), background: darkBg)

        model.selectedKey = "claude:demo-b"
        snapshot(HUDRootView(model: model).padding(12).environment(\.solidBackground, true), dark: false,
                 to: dir.appendingPathComponent("question.png"), background: lightBg)

        model.selectedKey = "claude:demo-e"
        snapshot(HUDRootView(model: model).padding(12).environment(\.solidBackground, true), dark: false,
                 to: dir.appendingPathComponent("plan.png"), background: lightBg)

        model.selectedKey = "claude:demo-d"
        snapshot(HUDRootView(model: model).padding(12).environment(\.solidBackground, true), dark: true,
                 to: dir.appendingPathComponent("done.png"), background: darkBg)

        snapshot(ControlPanelView(model: model, settings: settings, installed: installed, present: installed, loginItem: true, tab: 1),
                 dark: false, to: dir.appendingPathComponent("settings.png"))

        model.selectedKey = nil
        withDemoActivity {
            snapshot(AgentMapView(model: model, tab: 0).frame(width: 1100, height: 760), dark: true,
                     to: dir.appendingPathComponent("map.png"), background: darkBg)
            snapshot(AgentMapView(model: model, tab: 1).frame(width: 1100, height: 680), dark: false,
                     to: dir.appendingPathComponent("today.png"), background: lightBg)
        }
        print("Картинки для README: \(dir.path)")
    }

    static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL) {
        snapshot(view, dark: dark, to: url, background: dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.85, alpha: 1))
    }

    static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL, background: NSColor) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = background
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Подложка окна в снимок не попадает — кладём на фон.
        let out = NSImage(size: host.bounds.size)
        out.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: host.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: host.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let r = NSBitmapImageRep(data: tiff),
           let png = r.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.close()
    }

    static func write<V: View>(_ view: V, to url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("Не удалось отрисовать \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}
