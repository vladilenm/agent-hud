import Foundation

/// Внутреннее событие, общее для всех агентов. Адаптер переводит в него события своего агента.
public struct AgentEvent: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case sessionStarted(source: String?, model: String?)
        case promptSubmitted(String)
        case toolStarted(toolName: String, input: JSONValue, toolUseId: String?)
        case toolFinished(toolName: String, input: JSONValue, toolUseId: String?, durationMs: Int?, failed: Bool)
        /// `suggestions` — правила «разрешать и дальше», которые предлагает сам агент (`permission_suggestions`).
        case permissionRequested(requestId: String, toolName: String, input: JSONValue, deadline: Date, suggestions: [JSONValue])
        case questionAsked(requestId: String, questions: [Question], rawInput: JSONValue, deadline: Date)
        case subagentStarted(agentId: String, agentType: String?)
        case subagentStopped(agentId: String)
        case stopped(lastMessage: String?, failed: Bool)
        case interrupted
        /// Запрос разрешения проверяет сам агент (Codex auto_review): пользователя он не ждёт.
        case autoReviewing(requestId: String)
        /// Служебная сессия самого приложения (не диалог пользователя) — убрать и больше не показывать.
        case internalSession
        case sessionEnded(reason: String?)
        case notification(type: String?, message: String?)
    }

    public var kind: AgentKind
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var agentId: String?      // событие пришло изнутри субагента
    public var host: HostInfo?
    public var time: Date
    public var body: Body

    public init(kind: AgentKind, sessionId: String, cwd: String? = nil, transcriptPath: String? = nil,
                agentId: String? = nil, host: HostInfo? = nil, time: Date, body: Body) {
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.agentId = agentId
        self.host = host
        self.time = time
        self.body = body
    }

    public var sessionKey: String { "\(kind.rawValue):\(sessionId)" }
}

/// Адаптер конкретного агента. Ядро и UI знают только этот интерфейс.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }

    /// Нужно ли вообще отправлять это событие в приложение (иначе хук молча выходит).
    func shouldForward(mode: HookMode, payload: JSONValue) -> Bool

    /// Событие хука → внутренние события.
    func events(from message: HookMessage, now: Date) -> [AgentEvent]

    /// Решение пользователя → stdout хука. `nil` — пустой вывод (агент спросит сам).
    func hookOutput(for decision: Decision, mode: HookMode, payload: JSONValue) -> String?

    /// Краткая суть вызова инструмента для ленты шагов.
    func summarize(toolName: String, input: JSONValue, cwd: String?) -> String
}

public enum Adapters {
    public static func adapter(for kind: AgentKind) -> AgentAdapter {
        switch kind {
        case .claude: return ClaudeCodeAdapter()
        case .codex: return CodexAdapter()
        }
    }
}

/// Отпечаток входа инструмента: сопоставляет запрос разрешения и последующий PostToolUse.
public func fingerprint(toolName: String, input: JSONValue) -> String {
    "\(toolName)|\(input.compact())"
}
