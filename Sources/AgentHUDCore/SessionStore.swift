import Foundation

/// Состояние всех сессий. Чистая структура без побочных эффектов — её легко тестировать.
public struct SessionStore: Sendable, Equatable {
    public private(set) var sessions: [String: AgentSession] = [:]
    public private(set) var order: [String] = []
    /// Служебные сессии приложений: их события игнорируем.
    public private(set) var ignored: [String] = []

    /// Сколько держать завершившуюся (`SessionEnd`) сессию перед удалением — для анимации.
    public static let endedLinger: TimeInterval = 2

    public init() {}

    public var visibleSessions: [AgentSession] {
        order.compactMap { sessions[$0] }.filter { !$0.hidden && $0.revealed }
    }

    /// Запросы, которые ждут именно пользователя (без авто-проверяемых агентом).
    public var openRequestCount: Int {
        sessions.values.reduce(0) { $0 + $1.pending.filter { $0.status == .open && !$0.autoReview }.count }
    }

    /// Сколько ждать решения встроенного ревьюера агента, прежде чем снять запрос из HUD.
    /// Ревьюер Codex отвечает за 15–30 с; если он отклонил команду, она не выполнится и PostToolUse не придёт.
    public static let autoReviewLinger: TimeInterval = 90

    public func session(_ key: String) -> AgentSession? { sessions[key] }

    public func session(forRequest requestId: String) -> AgentSession? {
        sessions.values.first { $0.pending.contains { $0.id == requestId } }
    }

    // MARK: - События

    /// Применить событие. Возвращает id запросов, которые больше не актуальны
    /// (ответили в терминале) — приложение отпустит их хуки.
    @discardableResult
    public mutating func apply(_ e: AgentEvent, adapter: AgentAdapter? = nil) -> [String] {
        let key = e.sessionKey
        if ignored.contains(key) {
            // Служебная сессия: синхронные запросы сразу отпускаем.
            switch e.body {
            case .permissionRequested(let rid, _, _, _, _), .questionAsked(let rid, _, _, _): return [rid]
            default: return []
            }
        }
        if case .internalSession = e.body {
            let released = sessions[key]?.pending.filter { $0.status == .open }.map(\.id) ?? []
            remove(key)
            ignored.append(key)
            if ignored.count > 500 { ignored.removeFirst(ignored.count - 500) }
            return released
        }
        var s = sessions[key] ?? AgentSession(kind: e.kind, sessionId: e.sessionId, cwd: e.cwd ?? "", now: e.time)
        if sessions[key] == nil {
            order.append(key)
            // Сессия без задачи появляется в HUD только с первым делом (промпт, шаг, запрос):
            // приложение Codex открывает служебные треды, а VS Code — сессию на каждую открытую панель Claude.
            if case .sessionStarted = e.body, e.kind == .codex || e.host?.isEditor == true { s.revealed = false }
        }
        let summarizer = adapter ?? Adapters.adapter(for: e.kind)

        if let cwd = e.cwd, !cwd.isEmpty, s.cwd.isEmpty || e.agentId == nil { s.cwd = cwd }
        if let t = e.transcriptPath { s.transcriptPath = t }
        if let h = e.host { s.host = Self.merge(s.host, h) }
        s.lastEventAt = e.time
        if s.baseState == .ended, !Self.isEnd(e.body) { s.baseState = .idle }
        // Скрытая сессия возвращается с новой задачей или когда ждёт тебя — не на каждом шаге:
        // иначе в VS Code, где события идут постоянно, «Скрыть» не действовало дольше секунды.
        if Self.unhides(e.body) { s.hidden = false }

        var released: [String] = []

        switch e.body {
        case .sessionStarted(_, let model):
            if let model { s.model = model }
            if s.baseState == .starting { s.baseState = .idle }

        case .promptSubmitted(let text):
            // Заголовок — первая настоящая задача. Служебные вставки (<task-notification>, <command-name>…) — не задача.
            // Последний промпт заголовком не берём: им часто бывает короткий ответ на вопрос агента («красный»).
            if s.title.isEmpty, !Self.isInjectedPrompt(text) { s.title = Self.makeTitle(text) }
            s.revealed = true
            s.waitingNote = nil
            s.askedUserThisTurn = false
            s.baseState = .working
            s.lastMessage = nil
            s.finishedAt = nil
            s.turnStartedAt = e.time
            released += Self.resolveAll(&s)

        case .toolStarted(let tool, let input, let toolUseId):
            s.baseState = .working
            s.revealed = true
            s.waitingNote = nil
            if Self.isAskUserTool(tool) {
                s.askedUserThisTurn = true
                s.waitingNote = Self.questionText(input)
            }
            let step = Step(
                id: toolUseId ?? UUID().uuidString, toolName: tool,
                summary: summarizer.summarize(toolName: tool, input: input, cwd: s.cwd),
                startedAt: e.time, agentId: e.agentId,
                inputFingerprint: fingerprint(toolName: tool, input: input))
            if !s.steps.contains(where: { $0.id == step.id }) { s.steps.append(step) }

        case .toolFinished(let tool, let input, let toolUseId, let durationMs, let failed):
            if s.baseState != .ended { s.baseState = .working }
            let fp = fingerprint(toolName: tool, input: input)
            let idx = s.steps.lastIndex { st in
                if let id = toolUseId, st.id == id { return true }
                return st.status == .running && st.inputFingerprint == fp
            }
            if let i = idx {
                s.steps[i].status = failed ? .failed : .ok
                s.steps[i].durationMs = durationMs ?? Int(e.time.timeIntervalSince(s.steps[i].startedAt) * 1000)
            } else {
                s.steps.append(Step(
                    id: toolUseId ?? UUID().uuidString, toolName: tool,
                    summary: summarizer.summarize(toolName: tool, input: input, cwd: s.cwd),
                    startedAt: e.time, durationMs: durationMs, status: failed ? .failed : .ok,
                    agentId: e.agentId, inputFingerprint: fp))
            }
            released += Self.resolve(&s, toolName: tool, fingerprint: fp, command: Self.commandText(input))

        case .permissionRequested(let rid, let tool, let input, let deadline, let suggestions):
            s.baseState = .working
            s.revealed = true
            if !s.pending.contains(where: { $0.id == rid }) {
                // Агент спрашивает следующее — значит, на прошлый его запрос уже ответили
                // (например, «No» в VS Code: PostToolUse тогда не придёт, и запрос висел бы до конца хода).
                released += Self.resolveSuperseded(&s, agentId: e.agentId)
                let kind: PendingKind = tool == ClaudeCodeAdapter.planTool
                    ? .plan(text: input["plan"]?.stringValue ?? "", rawInput: input)
                    : .permission(toolName: tool, toolInput: input)
                s.pending.append(PendingRequest(
                    id: rid, kind: kind, createdAt: e.time,
                    deadline: deadline, status: .open, inputFingerprint: fingerprint(toolName: tool, input: input),
                    suggestions: suggestions, agentId: e.agentId))
            }

        case .questionAsked(let rid, let qs, let raw, let deadline):
            s.baseState = .working
            s.revealed = true
            if !s.pending.contains(where: { $0.id == rid }) {
                released += Self.resolveSuperseded(&s, agentId: e.agentId)
                s.pending.append(PendingRequest(
                    id: rid, kind: .question(qs, rawInput: raw), createdAt: e.time,
                    deadline: deadline, status: .open, inputFingerprint: fingerprint(toolName: "AskUserQuestion", input: raw),
                    agentId: e.agentId))
            }

        case .subagentStarted(let aid, let type):
            let id = "subagent:\(aid)"
            if !s.steps.contains(where: { $0.id == id }) {
                s.steps.append(Step(id: id, toolName: "Subagent", summary: "Субагент: \(type ?? "general")",
                                    startedAt: e.time, isSubagent: true))
            }
            s.baseState = .working

        case .subagentStopped(let aid):
            if let i = s.steps.firstIndex(where: { $0.id == "subagent:\(aid)" }) {
                s.steps[i].status = .ok
                s.steps[i].durationMs = Int(e.time.timeIntervalSince(s.steps[i].startedAt) * 1000)
            }
            // Субагент закончил — его запросы больше никто не ждёт.
            let stale = s.pending.filter { $0.agentId == aid }
            s.pending.removeAll { $0.agentId == aid }
            released += stale.filter { $0.status == .open }.map(\.id)
            if s.activePending == nil, s.baseState == .waitingPermission { s.baseState = .working }

        case .stopped(let msg, let failed):
            // Агент задал вопрос в приложении и закончил ход — он ждёт ответа, а не «готов».
            s.baseState = failed ? .error : (s.askedUserThisTurn ? .waitingAnswer : .done)
            if s.askedUserThisTurn, s.waitingNote == nil { s.waitingNote = msg }
            s.lastMessage = msg
            s.finishedAt = e.time
            for i in s.steps.indices where s.steps[i].status == .running && !s.steps[i].isSubagent {
                s.steps[i].status = .ok
            }
            released += Self.resolveAll(&s)

        case .interrupted:
            // Пользователь прервал ход (Esc): агент ждёт новую задачу.
            s.baseState = .idle
            s.finishedAt = e.time
            for i in s.steps.indices where s.steps[i].status == .running { s.steps[i].status = .failed }
            released += Self.resolveAll(&s)

        case .sessionEnded:
            released += Self.resolveAll(&s)
            if s.kind == .codex, s.host.isDesktopApp {
                // Приложение Codex выгружает тред из памяти, но диалог в приложении жив —
                // оставляем последнее состояние, уберёт автоскрытие готовых.
                if s.finishedAt == nil { s.finishedAt = e.time }
                if s.baseState == .working || s.baseState == .starting { s.baseState = .idle }
            } else {
                s.baseState = .ended
                s.finishedAt = e.time
            }

        case .internalSession:
            break

        case .autoReviewing(let rid):
            if let i = s.pending.firstIndex(where: { $0.id == rid }) { s.pending[i].autoReview = true }

        case .notification(let type, _):
            // Агент ждёт в самом терминале (например, после «ответить в терминале» или ExitPlanMode).
            // Только посреди хода: уведомление приходит с задержкой и после конца хода включало ложное «ждёт».
            if (type == "permission_prompt" || type == "elicitation_dialog"), s.activePending == nil,
               s.baseState == .working || s.baseState == .starting {
                s.baseState = .waitingPermission
            }
        }

        if s.steps.count > AgentSession.maxSteps { s.steps.removeFirst(s.steps.count - AgentSession.maxSteps) }
        sessions[key] = s
        return released
    }

    // MARK: - Запросы

    /// Пользователь ответил в HUD.
    public mutating func markAnswered(_ requestId: String) {
        mutateSession(forRequest: requestId) { s in
            s.pending.removeAll { $0.id == requestId }
        }
    }

    /// Хук отключился. До дедлайна — значит ответили в терминале, после — просрочка.
    public mutating func connectionClosed(_ requestId: String, now: Date) {
        mutateSession(forRequest: requestId) { s in
            guard let i = s.pending.firstIndex(where: { $0.id == requestId }), s.pending[i].status == .open else { return }
            if now >= s.pending[i].deadline.addingTimeInterval(-2) {
                s.pending[i].status = .expired
            } else {
                s.pending.remove(at: i)
            }
        }
    }

    /// Раз в секунду: просрочка запросов и уборка закончившихся сессий.
    /// Возвращает id запросов, которые стали просроченными.
    @discardableResult
    public mutating func tick(now: Date, autoHideDoneAfter: TimeInterval?) -> [String] {
        var expired: [String] = []
        for key in order {
            guard var s = sessions[key] else { continue }
            for i in s.pending.indices where s.pending[i].status == .open && now > s.pending[i].deadline.addingTimeInterval(1) {
                s.pending[i].status = .expired
                expired.append(s.pending[i].id)
            }
            if let limit = autoHideDoneAfter, s.state == .done, let f = s.finishedAt, now.timeIntervalSince(f) > limit {
                s.hidden = true
            }
            sessions[key] = s
            if s.baseState == .ended, s.activePending == nil, let f = s.finishedAt,
               now.timeIntervalSince(f) > Self.endedLinger {
                remove(key)
            }
        }
        return expired
    }

    public mutating func hide(_ key: String) {
        guard var s = sessions[key] else { return }
        s.hidden = true
        s.pending.removeAll { $0.status != .open }
        if s.baseState == .waitingPermission || s.baseState == .waitingAnswer { s.baseState = .idle }
        sessions[key] = s
    }

    /// Вернуть скрытую сессию (карта агентов показывает и скрытые).
    public mutating func unhide(_ key: String) {
        guard var s = sessions[key] else { return }
        s.hidden = false
        sessions[key] = s
    }

    /// Убрать просроченное окошко без скрытия сессии.
    public mutating func dismissExpired(_ key: String) {
        guard var s = sessions[key] else { return }
        s.pending.removeAll { $0.status == .expired }
        if s.baseState == .waitingPermission { s.baseState = .idle }
        sessions[key] = s
    }

    public mutating func remove(_ key: String) {
        sessions[key] = nil
        order.removeAll { $0 == key }
    }

    /// Процесс агента умер без SessionEnd.
    public mutating func markEnded(_ key: String, now: Date) -> [String] {
        guard var s = sessions[key] else { return [] }
        s.baseState = .ended
        s.finishedAt = now
        let released = Self.resolveAll(&s)
        sessions[key] = s
        return released
    }

    // MARK: - Внутреннее

    private mutating func mutateSession(forRequest rid: String, _ body: (inout AgentSession) -> Void) {
        guard let key = order.first(where: { sessions[$0]?.pending.contains { $0.id == rid } == true }),
              var s = sessions[key] else { return }
        body(&s)
        sessions[key] = s
    }

    /// Сессия пошла дальше: открытые запросы сняты (ответили в терминале), просроченные убраны.
    private static func resolveAll(_ s: inout AgentSession) -> [String] {
        let released = s.pending.filter { $0.status == .open }.map(\.id)
        s.pending.removeAll()
        if s.baseState == .waitingPermission { s.baseState = .working }
        return released
    }

    /// Новый запрос того же агента (основного или того же субагента) вытесняет его прошлые открытые запросы:
    /// агент не спросит следующее, пока ему не ответили на предыдущее.
    private static func resolveSuperseded(_ s: inout AgentSession, agentId: String?) -> [String] {
        let old = s.pending.filter { $0.status == .open && $0.agentId == agentId && !$0.autoReview }
        guard !old.isEmpty else { return [] }
        s.pending.removeAll { p in old.contains { $0.id == p.id } }
        return old.map(\.id)
    }

    /// События, с которыми скрытая сессия снова показывается.
    static func unhides(_ b: AgentEvent.Body) -> Bool {
        switch b {
        case .promptSubmitted, .permissionRequested, .questionAsked: return true
        default: return false
        }
    }

    /// Вставки самого Claude Code в поток промптов: уведомления фоновых задач, слэш-команды, вывод команд.
    /// Начинаются с тега вида `<task-notification>`; живой промпт так почти никогда не начинается.
    public static func isInjectedPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<"), let close = t.firstIndex(of: ">") else { return false }
        let tag = t[t.index(after: t.startIndex)..<close]
        return !tag.isEmpty && tag.count <= 40 && tag.allSatisfy { $0.isLowercase || $0 == "-" || $0 == "_" || $0.isNumber }
    }

    /// Инструмент выполнился — снять запрос, который относился к нему.
    private static func resolve(_ s: inout AgentSession, toolName: String, fingerprint fp: String, command fpCommand: String? = nil) -> [String] {
        if s.baseState == .waitingPermission { s.baseState = .working }
        let match: (PendingRequest) -> Bool = { p in
            switch p.kind {
            case .question: return toolName == "AskUserQuestion"
            case .plan: return toolName == ClaudeCodeAdapter.planTool
            case .permission(let t, let input):
                if p.inputFingerprint == fp { return true }
                // У команд сверяем саму команду: агент может добавить в запрос описание
                // (Codex), а параллельно выполняются другие команды того же инструмента.
                if let want = Self.commandText(input), let got = fpCommand { return want == got }
                return t == toolName
            }
        }
        guard let i = s.pending.firstIndex(where: match) else { return [] }
        let p = s.pending.remove(at: i)
        return p.status == .open ? [p.id] : []
    }

    /// Текст команды из входа инструмента (Bash у Claude, exec_command у Codex).
    static func commandText(_ input: JSONValue) -> String? {
        if let c = input["command"]?.stringValue ?? input["cmd"]?.stringValue {
            return c.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = input["command"]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
            // ["/bin/zsh", "-lc", "команда"] → «команда»
            return (parts.count >= 3 && parts[1].hasPrefix("-") ? parts[2] : parts.joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Авто-проверяемые запросы, которые висят дольше `autoReviewLinger`: ревьюер их уже решил
    /// (скорее всего отклонил). Убираем из HUD и отпускаем хук.
    public mutating func dropStaleAutoReviews(now: Date) -> [String] {
        var released: [String] = []
        for key in order {
            guard var s = sessions[key] else { continue }
            let stale = s.pending.filter { $0.autoReview && $0.status == .open && now.timeIntervalSince($0.createdAt) > Self.autoReviewLinger }
            guard !stale.isEmpty else { continue }
            s.pending.removeAll { p in stale.contains { $0.id == p.id } }
            released += stale.map(\.id)
            sessions[key] = s
        }
        return released
    }

    /// Инструмент «спросить пользователя в приложении» (Codex: request_user_input, request_user_input_async).
    static func isAskUserTool(_ name: String) -> Bool { name.hasPrefix("request_user_input") }

    static func questionText(_ input: JSONValue) -> String? {
        let candidates = [input["questions"]?[0]?["question"], input["question"], input["prompt"], input["message"], input["title"]]
        return candidates.compactMap { $0?.stringValue }.first { !$0.isEmpty }
    }

    private static func isEnd(_ b: AgentEvent.Body) -> Bool {
        if case .sessionEnded = b { return true }
        return false
    }

    static func merge(_ old: HostInfo, _ new: HostInfo) -> HostInfo {
        HostInfo(termProgram: new.termProgram ?? old.termProgram,
                 tty: new.tty ?? old.tty,
                 agentPid: new.agentPid ?? old.agentPid,
                 herdrPaneId: new.herdrPaneId ?? old.herdrPaneId,
                 herdrSocket: new.herdrSocket ?? old.herdrSocket,
                 processChain: new.processChain.isEmpty ? old.processChain : new.processChain,
                 appBundleId: new.appBundleId ?? old.appBundleId,
                 appName: new.appName ?? old.appName,
                 hostSessionId: new.hostSessionId ?? old.hostSessionId,
                 entrypoint: new.entrypoint ?? old.entrypoint)
    }

    static func makeTitle(_ prompt: String) -> String {
        let oneLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = oneLine.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(59)) + "…" : t
    }
}
