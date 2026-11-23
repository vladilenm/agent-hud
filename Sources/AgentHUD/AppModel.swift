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
    private let d: UserDefaults

    @Published var avatarStyle: AvatarStyle { didSet { d.set(avatarStyle.rawValue, forKey: "avatarStyle") } }
    @Published var hideWhenNothingWaits: Bool { didSet { d.set(hideWhenNothingWaits, forKey: "hideWhenNothingWaits") } }
    @Published var openCardOnRequest: Bool { didSet { d.set(openCardOnRequest, forKey: "openCardOnRequest") } }
    @Published var hudVisible: Bool { didSet { d.set(hudVisible, forKey: "hudVisible") } }
    @Published var autoHideDoneMinutes: Int { didSet { d.set(autoHideDoneMinutes, forKey: "autoHideDoneMinutes") } }
    @Published var hookTimeout: Int { didSet { d.set(hookTimeout, forKey: "hookTimeout") } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var animations: Bool { didSet { d.set(animations, forKey: "animations") } }

    @Published var hudDisplay: String { didSet { d.set(hudDisplay, forKey: "hudDisplay") } }
    @Published var hudCorner: HUDCorner { didSet { d.set(hudCorner.rawValue, forKey: "hudCorner") } }

    var legacyHUDAnchor: CGPoint? {
        guard d.object(forKey: "anchorX") != nil, d.object(forKey: "anchorY") != nil else { return nil }
        return CGPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
    }

    func clearLegacyHUDAnchor() {
        d.removeObject(forKey: "anchorX")
        d.removeObject(forKey: "anchorY")
    }

    func hudOffset(on display: String) -> CGPoint? { offset(for: "hudOffsets", on: display) }
    func menuOffset(on display: String) -> CGPoint? { offset(for: "menuOffsets", on: display) }
    func setHUDOffset(_ point: CGPoint?, on display: String) { setOffset(point, for: "hudOffsets", on: display) }
    func setMenuOffset(_ point: CGPoint?, on display: String) { setOffset(point, for: "menuOffsets", on: display) }
    func clearHUDOffsets() { d.removeObject(forKey: "hudOffsets") }

    private func offset(for key: String, on display: String) -> CGPoint? {
        (d.dictionary(forKey: key)?[display] as? String).map(NSPointFromString)
    }

    private func setOffset(_ point: CGPoint?, for key: String, on display: String) {
        var offsets = d.dictionary(forKey: key) ?? [:]
        if let point {
            offsets[display] = NSStringFromPoint(point)
        } else {
            offsets.removeValue(forKey: display)
        }
        d.set(offsets, forKey: key)
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        hudDisplay = d.string(forKey: "hudDisplay") ?? ""
        hudCorner = d.string(forKey: "hudCorner").flatMap(HUDCorner.init(rawValue:)) ?? .topRight
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
        for e in adapter.events(from: m, now: now) {
            let released = store.apply(e, adapter: adapter)
            var event = m.payload["hook_event_name"]?.stringValue ?? m.mode.rawValue
            if case .autoReviewing = e.body { event = "auto_review" }
            let state = store.session(e.sessionKey)?.state.rawValue ?? "-"
            hudLog.notice("\(m.agent.rawValue, privacy: .public) \(event, privacy: .public) → \(state, privacy: .public) [\(e.sessionId.prefix(8), privacy: .public)]")
            release(released)
        }
        // После всех событий: запрос мог оказаться авто-проверяемым (Codex auto_review) — тогда не открываем окошко.
        if m.mode.isSync, let s = store.session(forRequest: m.requestId),
           let p = s.pending.first(where: { $0.id == m.requestId }), !p.autoReview {
            requestArrived(s.id)
        }
        if let k = selectedKey, store.session(k) == nil || store.session(k)?.hidden == true { selectedKey = nil }
    }

    private func requestArrived(_ key: String) {
        if settings.openCardOnRequest, selectedKey == nil || store.session(selectedKey!)?.activePending == nil {
            selectedKey = key
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
        if let k = selectedKey, store.session(k) == nil || store.session(k)?.hidden == true { selectedKey = nil }
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
        if case .passthrough = decision { TerminalFocus.focus(s) }
        if selectedKey == s.id, !selectedByUser, store.session(s.id)?.activePending == nil { selectedKey = nil }
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

    // MARK: - Для демо и превью

    func inject(_ events: [AgentEvent]) {
        for e in events { store.apply(e) }
    }

    var visibleSessions: [AgentSession] { store.visibleSessions }

    var hasAttention: Bool {
        store.visibleSessions.contains { $0.state.needsUser || $0.state == .expired }
    }
}

/// Журнал решений: что разрешено/отклонено/отвечено и когда.
enum DecisionLog {
    static func append(session: AgentSession, request: PendingRequest, decision: Decision) {
        let f = ISO8601DateFormatter()
        var what = ""
        switch request.kind {
        case .permission(let tool, let input):
            what = Adapters.adapter(for: session.kind).summarize(toolName: tool, input: input, cwd: session.cwd)
        case .question(let qs, _):
            what = "Вопрос: " + (qs.first?.question ?? "")
        }
        var detail = ""
        switch decision {
        case .deny(let r): detail = r ?? ""
        case .answer(let a): detail = a.map { "\($0.key) → \($0.value)" }.joined(separator: "; ")
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
