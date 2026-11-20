import Foundation

/// Режим вызова хука.
public enum HookMode: String, Sendable {
    case event        // асинхронное событие, ответ не нужен
    case permission   // запрос разрешения, ждём решения
    case question     // вопрос агента, ждём ответа

    public var isSync: Bool { self != .event }
}

/// Сообщение от `agenthud-hook` к приложению. Одна JSON-строка в сокете.
public struct HookMessage: Equatable, Sendable {
    public static let version = 1

    public var agent: AgentKind
    public var mode: HookMode
    public var requestId: String
    public var deadline: Date?
    public var host: HostInfo
    public var payload: JSONValue   // вход хука агента как есть

    public init(agent: AgentKind, mode: HookMode, requestId: String, deadline: Date?, host: HostInfo, payload: JSONValue) {
        self.agent = agent
        self.mode = mode
        self.requestId = requestId
        self.deadline = deadline
        self.host = host
        self.payload = payload
    }

    public func encode() -> String {
        var o = JSONObject()
        o["v"] = .int(Self.version)
        o["agent"] = .string(agent.rawValue)
        o["mode"] = .string(mode.rawValue)
        o["request_id"] = .string(requestId)
        if let d = deadline { o["deadline"] = .double(d.timeIntervalSince1970.rounded()) }
        o["host"] = host.toJSON()
        o["payload"] = payload
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> HookMessage? {
        guard let v = try? JSONValue.parse(line),
              let agent = v["agent"]?.stringValue.flatMap(AgentKind.init(rawValue:)),
              let mode = v["mode"]?.stringValue.flatMap(HookMode.init(rawValue:)),
              let rid = v["request_id"]?.stringValue,
              let payload = v["payload"], payload.objectValue != nil
        else { return nil }
        return HookMessage(
            agent: agent, mode: mode, requestId: rid,
            deadline: v["deadline"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            host: HostInfo(json: v["host"]), payload: payload
        )
    }
}

/// Ответ приложения хуку.
public struct HookReply: Equatable, Sendable {
    public var requestId: String
    public var decision: Decision

    public init(requestId: String, decision: Decision) {
        self.requestId = requestId
        self.decision = decision
    }

    public func encode() -> String {
        var o = JSONObject()
        o["request_id"] = .string(requestId)
        switch decision {
        case .allow: o["decision"] = "allow"
        case .allowWith(let updates):
            o["decision"] = "allow"
            o["permissions"] = .array(updates)
        case .deny(let reason):
            o["decision"] = "deny"
            if let r = reason { o["reason"] = .string(r) }
        case .answer(let answers):
            o["decision"] = "answer"
            var a = JSONObject()
            for k in answers.keys.sorted() { a[k] = .string(answers[k]!) }
            o["answers"] = .object(a)
        case .passthrough: o["decision"] = "passthrough"
        }
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> HookReply? {
        guard let v = try? JSONValue.parse(line),
              let rid = v["request_id"]?.stringValue,
              let d = v["decision"]?.stringValue else { return nil }
        switch d {
        case "allow":
            if let updates = v["permissions"]?.arrayValue, !updates.isEmpty {
                return HookReply(requestId: rid, decision: .allowWith(updates))
            }
            return HookReply(requestId: rid, decision: .allow)
        case "deny": return HookReply(requestId: rid, decision: .deny(reason: v["reason"]?.stringValue))
        case "answer":
            var answers: [String: String] = [:]
            for e in v["answers"]?.objectValue?.entries ?? [] {
                if let s = e.value.stringValue { answers[e.key] = s }
            }
            return HookReply(requestId: rid, decision: .answer(answers))
        case "passthrough": return HookReply(requestId: rid, decision: .passthrough)
        default: return nil
        }
    }
}

/// Где живёт сокет приложения.
public enum AgentHUDPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTHUD_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentHUD", isDirectory: true)
    }

    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["AGENTHUD_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("hud.sock").path
    }

    public static var decisionsLog: URL { supportDirectory.appendingPathComponent("decisions.log") }

    public static var hookSymlink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agenthud-hook")
    }

    public static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
}

/// Запас времени: хук отпускает ожидание раньше своего `timeout`,
/// чтобы агент не убил его и спросил пользователя в терминале.
public enum HookTiming {
    public static let safetyMargin: TimeInterval = 5
    public static let defaultTimeout = 600
    public static let connectTimeoutMs: Int32 = 200

    public static func deadline(now: Date, hookTimeout: Int) -> Date {
        now.addingTimeInterval(max(1, TimeInterval(hookTimeout) - safetyMargin))
    }
}
