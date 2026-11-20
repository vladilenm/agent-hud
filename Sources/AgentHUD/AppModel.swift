import AgentHUDCore
import AppKit
import Combine
import Foundation
import os

/// Служебный лог: только тип агента, событие и состояние — без промптов и команд.
/// Смотреть: log stream --predicate 'subsystem == "dev.agenthud"'
let hudLog = Logger(subsystem: "dev.agenthud", category: "events")

enum AvatarStyle: String, CaseIterable, Identifiable {
    case logo, blob, bot, pixel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logo: return "Логотипы"
        case .blob: return "Капля"
        case .bot: return "Бот"
        case .pixel: return "Пиксель"
        }
    }
}

/// Настройки в UserDefaults.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var avatarStyle: AvatarStyle { didSet { d.set(avatarStyle.rawValue, forKey: "avatarStyle") } }
    @Published var hideWhenNothingWaits: Bool { didSet { d.set(hideWhenNothingWaits, forKey: "hideWhenNothingWaits") } }
    @Published var openCardOnRequest: Bool { didSet { d.set(openCardOnRequest, forKey: "openCardOnRequest") } }
    @Published var hudVisible: Bool { didSet { d.set(hudVisible, forKey: "hudVisible") } }
    @Published var autoHideDoneMinutes: Int { didSet { d.set(autoHideDoneMinutes, forKey: "autoHideDoneMinutes") } }
    @Published var hookTimeout: Int { didSet { d.set(hookTimeout, forKey: "hookTimeout") } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var animations: Bool { didSet { d.set(animations, forKey: "animations") } }
    /// Подпись проекта под иконкой агента (когда агент один, иконки одинаковые).
    @Published var projectLabels: Bool { didSet { d.set(projectLabels, forKey: "projectLabels") } }
    /// Журнал активности для сводки за день и вкладки «Сегодня» (только локально).
    @Published var activityLog: Bool { didSet { d.set(activityLog, forKey: "activityLog") } }
    /// Быстрые промпты для сессий в VS Code (вставляются в поле ввода сессии).
    @Published var quickPrompts: [String] { didSet { d.set(quickPrompts, forKey: "quickPrompts") } }
    /// HUD прижат к левому краю экрана: якорь — левый верхний угол, окошко раскрывается вправо.
    @Published var anchorLeft: Bool { didSet { d.set(anchorLeft, forKey: "anchorLeft") } }

    static let defaultQuickPrompts = ["Продолжай", "Прогони тесты и почини, что упало", "Проверь линтер и типы", "Сделай коммит"]

    /// Верхний угол HUD в координатах экрана (правый, а при `anchorLeft` — левый); nil — по умолчанию.
    var anchor: CGPoint? {
        get {
            guard d.object(forKey: "anchorX") != nil else { return nil }
            return CGPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
        }
        set {
            if let p = newValue { d.set(p.x, forKey: "anchorX"); d.set(p.y, forKey: "anchorY") }
            else { d.removeObject(forKey: "anchorX"); d.removeObject(forKey: "anchorY") }
        }
    }

    init() {
        avatarStyle = AvatarStyle(rawValue: d.string(forKey: "avatarStyle") ?? "") ?? .logo
        // Логотипы агентов стали стилем по умолчанию — один раз переключаем и тех, у кого был выбран персонаж.
        if !d.bool(forKey: "logoStyleIntroduced") {
            d.set(true, forKey: "logoStyleIntroduced")
            avatarStyle = .logo
            d.set(AvatarStyle.logo.rawValue, forKey: "avatarStyle")
        }
        hideWhenNothingWaits = d.object(forKey: "hideWhenNothingWaits") as? Bool ?? false
        openCardOnRequest = d.object(forKey: "openCardOnRequest") as? Bool ?? true
        hudVisible = d.object(forKey: "hudVisible") as? Bool ?? true
        autoHideDoneMinutes = d.object(forKey: "autoHideDoneMinutes") as? Int ?? 30
        hookTimeout = d.object(forKey: "hookTimeout") as? Int ?? HookTiming.defaultTimeout
        notifications = d.object(forKey: "notifications") as? Bool ?? true
        animations = d.object(forKey: "animations") as? Bool ?? true
        projectLabels = d.object(forKey: "projectLabels") as? Bool ?? true
        activityLog = d.object(forKey: "activityLog") as? Bool ?? true
        quickPrompts = (d.stringArray(forKey: "quickPrompts") ?? Self.defaultQuickPrompts).filter { !$0.isEmpty }
        anchorLeft = d.bool(forKey: "anchorLeft")
    }
}

/// Состояние приложения: сессии, выбранная карточка, связь с сокетом.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = SessionStore()
    @Published var selectedKey: String?
    /// Карточку открыли кликом (можно забрать фокус клавиатуры) или сама открылась на запрос.
    @Published var selectedByUser = false

    let settings: Settings
    private var server: SocketServer?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var notified = Set<String>()
    var onRequestNeedsAttention: ((AgentSession) -> Void)?
    /// Открыть окно «Карта агентов» (его держит AppDelegate).
    var onOpenMap: (() -> Void)?
    /// Все папки проектов, встреченные за время работы, плюс открытые окна VS Code. Метки проектов
    /// считаются по этому набору, а не по видимым сейчас сессиям — иначе метки менялись бы
    /// каждый раз, когда сессия появляется или пропадает.
    private var knownProjects = Set<String>()
    private var editorFolders = Set<String>()
    private var editorFoldersReadAt = Date.distantPast

    init(settings: Settings) {
        self.settings = settings
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Запуск

    func start(socketPath: String = AgentHUDPaths.socketPath) throws {
        let s = SocketServer(path: socketPath)
        s.onMessage = { [weak self] m in self?.handle(m) }
        s.onClosed = { [weak self] rid in self?.connectionClosed(rid) }
        try s.start()
        server = s
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        // Отпустить все ждущие хуки — агенты спросят в терминале.
        for s in store.sessions.values {
            for p in s.pending where p.status == .open {
                server?.reply(HookReply(requestId: p.id, decision: .passthrough))
            }
        }
        server?.stop()
    }

    // MARK: - События

    func handle(_ m: HookMessage) {
        let adapter = Adapters.adapter(for: m.agent)
        let now = Date()
        // Все события сообщения применяем к копии и публикуем один раз: каждая публикация — перерисовка HUD.
        var next = store
        var released: [String] = []
        for e in adapter.events(from: m, now: now) {
            released += next.apply(e, adapter: adapter)
            logActivity(e, session: next.session(e.sessionKey))
            var event = m.payload["hook_event_name"]?.stringValue ?? m.mode.rawValue
            if case .autoReviewing = e.body { event = "auto_review" }
            let state = next.session(e.sessionKey)?.state.rawValue ?? "-"
            hudLog.notice("\(m.agent.rawValue, privacy: .public) \(event, privacy: .public) → \(state, privacy: .public) [\(e.sessionId.prefix(8), privacy: .public)]")
        }
        if next != store { store = next }
        release(released)
        rememberProjects(now: now)
        // После всех событий: запрос мог оказаться авто-проверяемым (Codex auto_review) — тогда не открываем окошко.
        if m.mode.isSync, let s = store.session(forRequest: m.requestId),
           let p = s.pending.first(where: { $0.id == m.requestId }), !p.autoReview {
            requestArrived(s.id)
        }
        if let k = selectedKey, store.session(k) == nil || store.session(k)?.hidden == true { selectedKey = nil }
        scheduleAutoClose()
    }

    /// Окошко, которое открылось само на запрос, закрывается, когда запрос решён (в HUD, в VS Code или в терминале).
    /// С паузой: если агент сразу спросит следующее, окошко не мигает закрытием-открытием.
    private var autoCloseTask: Task<Void, Never>?
    static let autoCloseDelay: Duration = .seconds(1)

    private func autoOpenedCardIsIdle() -> Bool {
        guard let k = selectedKey, !selectedByUser, let s = store.session(k) else { return false }
        return s.activePending == nil && s.expiredPending == nil && !s.state.needsUser
    }

    private func scheduleAutoClose() {
        guard autoOpenedCardIsIdle() else { autoCloseTask?.cancel(); autoCloseTask = nil; return }
        guard autoCloseTask == nil else { return }
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoCloseDelay)
            guard let self, !Task.isCancelled else { return }
            self.autoCloseTask = nil
            if self.autoOpenedCardIsIdle() { self.selectedKey = nil }
        }
    }

    /// Промпт и конец хода — в журнал активности (для сводки за день и вкладки «Сегодня»).
    private func logActivity(_ e: AgentEvent, session: AgentSession?) {
        guard settings.activityLog, let s = session, e.agentId == nil else { return }
        switch e.body {
        case .promptSubmitted(let text):
            guard !SessionStore.isInjectedPrompt(text) else { return }
            ActivityLog.append(ActivityRecord(kind: .prompt, time: e.time, agent: s.kind.rawValue, session: s.sessionId,
                                              project: s.projectName, cwd: s.cwd, text: String(text.prefix(600))))
        case .stopped(let msg, let failed):
            ActivityLog.append(ActivityRecord(kind: .stop, time: e.time, agent: s.kind.rawValue, session: s.sessionId,
                                              project: s.projectName, cwd: s.cwd, text: String((msg ?? "").prefix(600)),
                                              failed: failed, stats: s.turnStats(until: e.time)))
        default:
            break
        }
    }

    private func requestArrived(_ key: String) {
        if settings.openCardOnRequest, selectedKey == nil || store.session(selectedKey!)?.activePending == nil {
            autoCloseTask?.cancel()
            autoCloseTask = nil
            if selectedKey != key { selectedKey = key }
            selectedByUser = false
        }
    }

    private func release(_ ids: [String]) {
        for id in ids { server?.reply(HookReply(requestId: id, decision: .passthrough)) }
    }

    private func connectionClosed(_ rid: String) {
        store.connectionClosed(rid, now: Date())
    }

    private func tick() {
        let now = Date()
        let minutes = settings.autoHideDoneMinutes
        // Работаем с копией и публикуем, только если что-то изменилось, —
        // иначе SwiftUI перерисовывал бы HUD каждую секунду.
        var next = store
        next.tick(now: now, autoHideDoneAfter: minutes > 0 ? TimeInterval(minutes * 60) : nil)
        // Процесс агента умер без SessionEnd (закрыли вкладку терминала).
        var released: [String] = []
        for s in next.sessions.values where s.baseState != .ended {
            if let pid = s.host.agentPid, now.timeIntervalSince(s.lastEventAt) > 5, !HostProbe.isAlive(pid) {
                released += next.markEnded(s.id, now: now)
            }
        }
        released += next.dropStaleAutoReviews(now: now)
        if next != store { store = next }
        release(released)
        rememberProjects(now: now)
        if let k = selectedKey, store.session(k) == nil || store.session(k)?.hidden == true { selectedKey = nil }
        scheduleAutoClose()
        // Уведомление, если запрос висит дольше 10 с, а HUD не виден.
        for s in store.sessions.values {
            guard let p = s.activePending, !p.autoReview, !notified.contains(p.id), now.timeIntervalSince(p.createdAt) > 10 else { continue }
            notified.insert(p.id)
            onRequestNeedsAttention?(s)
        }
    }

    // MARK: - Действия пользователя

    func decide(_ requestId: String, _ decision: Decision) {
        guard let s = store.session(forRequest: requestId),
              let p = s.pending.first(where: { $0.id == requestId }), p.status == .open else { return }
        server?.reply(HookReply(requestId: requestId, decision: decision))
        store.markAnswered(requestId)
        DecisionLog.append(session: s, request: p, decision: decision)
        if settings.activityLog {
            ActivityLog.append(ActivityRecord(kind: .decision, time: Date(), agent: s.kind.rawValue, session: s.sessionId,
                                              project: s.projectName, cwd: s.cwd,
                                              text: DecisionLog.describe(session: s, request: p), detail: decision.logLabel))
        }
        if case .passthrough = decision { TerminalFocus.focus(s) }
        // Ждёт ещё кто-то — показываем его запрос сразу; иначе окошко, открытое самим запросом, закроется с паузой.
        if selectedKey == s.id, store.session(s.id)?.activePending == nil,
           let other = store.visibleSessions.first(where: { $0.id != s.id && $0.activePending.map { !$0.autoReview } == true }) {
            selectedKey = other.id
            selectedByUser = false
        }
        scheduleAutoClose()
    }

    func select(_ key: String?) {
        selectedKey = (selectedKey == key) ? nil : key
        selectedByUser = true
    }

    func open(_ key: String) {
        guard let s = store.session(key) else { return }
        TerminalFocus.focus(s)
    }

    func hide(_ key: String) {
        if let s = store.session(key) {
            for p in s.pending where p.status == .open { release([p.id]) }
        }
        store.hide(key)
        if selectedKey == key { selectedKey = nil }
    }

    func dismissExpired(_ key: String) { store.dismissExpired(key) }

    func unhide(_ key: String) { store.unhide(key) }

    /// Следующий промпт для сессии в VS Code: откроется её чат с текстом в поле ввода (отправляешь сам).
    func prefillPrompt(_ key: String, _ text: String) {
        guard let s = store.session(key), s.host.canPrefillPrompt else { return }
        TerminalFocus.focusEditor(s, prompt: text)
    }

    /// Короткие метки проектов для видимых сессий («mobile», «web»…), устойчивые к приходу и уходу сессий.
    var projectShortLabels: [String: String] {
        let visible = store.visibleSessions.map(\.cwd)
        let universe = knownProjects.union(editorFolders).union(visible)
        let all = ProjectNames.shortLabels(for: Array(universe))
        return all.filter { visible.contains($0.key) }
    }

    /// Запомнить папки сессий и раз в полминуты перечитать окна VS Code (для меток проектов).
    private func rememberProjects(now: Date) {
        for s in store.sessions.values where !s.cwd.isEmpty { knownProjects.insert(s.cwd) }
        guard now.timeIntervalSince(editorFoldersReadAt) > 30 else { return }
        editorFoldersReadAt = now
        editorFolders = EditorWorkspaces.openFolders()
    }

    func openMap() { onOpenMap?() }

    /// Сводка за день в Markdown: файл в папке приложения (его же можно открыть или скопировать).
    @discardableResult
    func writeSummary(day: Date = Date()) -> URL {
        let md = DailySummary.markdown(DailySummary.build(ActivityLog.read(day: day)), day: day)
        let url = AgentHUDPaths.supportDirectory.appendingPathComponent("summaries/\(ActivityLog.file(for: day).deletingPathExtension().lastPathComponent).md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(md.utf8).write(to: url)
        return url
    }

    // MARK: - Для демо и превью

    func inject(_ events: [AgentEvent]) {
        var next = store
        for e in events { next.apply(e) }
        store = next
        rememberProjects(now: Date())
    }

    var visibleSessions: [AgentSession] { store.visibleSessions }

    var hasAttention: Bool {
        store.visibleSessions.contains { $0.state.needsUser || $0.state == .expired }
    }
}

/// Журнал решений: что разрешено/отклонено/отвечено и когда.
enum DecisionLog {
    static func describe(session: AgentSession, request: PendingRequest) -> String {
        switch request.kind {
        case .permission(let tool, let input):
            return Adapters.adapter(for: session.kind).summarize(toolName: tool, input: input, cwd: session.cwd)
        case .question(let qs, _):
            return "Вопрос: " + (qs.first?.question ?? "")
        case .plan(let text, _):
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return "План: " + first.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }
    }

    static func append(session: AgentSession, request: PendingRequest, decision: Decision) {
        let f = ISO8601DateFormatter()
        let what = describe(session: session, request: request)
        var detail = ""
        switch decision {
        case .deny(let r): detail = r ?? ""
        case .answer(let a): detail = a.map { "\($0.key) → \($0.value)" }.joined(separator: "; ")
        case .allowWith(let updates): detail = updates.compactMap(PermissionRules.describe).joined(separator: "; ")
        default: break
        }
        let line = [f.string(from: Date()), session.projectName, decision.logLabel, what, detail]
            .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t") + "\n"
        let url = AgentHUDPaths.decisionsLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
