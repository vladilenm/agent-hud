import Foundation

/// Адаптер Codex CLI: хуки из `~/.codex/hooks.json`.
/// Документация: https://learn.chatgpt.com/docs/hooks
///
/// Отличия от Claude Code:
/// - нет хука для вопросов агента — в HUD только статусы, шаги и разрешения;
/// - нет `Notification` и `PostToolUseFailure`, зато есть `Interrupt` (пользователь прервал ход);
/// - `PermissionRequest` нельзя отвечать с `updatedInput` — только allow/deny.
public struct CodexAdapter: AgentAdapter {
    public init() {}

    public var kind: AgentKind { .codex }

    public func shouldForward(mode: HookMode, payload: JSONValue) -> Bool {
        switch mode {
        case .event, .permission: return payload["session_id"]?.stringValue != nil
        case .question: return false
        }
    }

    public func events(from message: HookMessage, now: Date) -> [AgentEvent] {
        let p = message.payload
        guard let sid = p["session_id"]?.stringValue else { return [] }
        let name = p["hook_event_name"]?.stringValue ?? ""
        let toolName = p["tool_name"]?.stringValue ?? ""
        let input = p["tool_input"] ?? .object(JSONObject())
        let toolUseId = p["tool_use_id"]?.stringValue
        let deadline = message.deadline ?? HookTiming.deadline(now: now, hookTimeout: HookTiming.defaultTimeout)

        func make(_ body: AgentEvent.Body) -> AgentEvent {
            AgentEvent(kind: .codex, sessionId: sid, cwd: p["cwd"]?.stringValue,
                       transcriptPath: p["transcript_path"]?.stringValue,
                       agentId: name.hasPrefix("Subagent") ? nil : p["agent_id"]?.stringValue,
                       host: message.host.isEmpty ? nil : message.host, time: now, body: body)
        }

        if message.mode == .permission {
            var out = [make(.permissionRequested(requestId: message.requestId, toolName: toolName, input: input,
                                                 deadline: deadline, suggestions: []))]
            // В режиме auto_review запрос решает встроенный ревьюер Codex, не дожидаясь хука.
            if Self.approvalsReviewer(sessionId: sid, transcriptPath: p["transcript_path"]?.stringValue) == "auto_review" {
                out.append(make(.autoReviewing(requestId: message.requestId)))
            }
            return out
        }
        guard message.mode == .event else { return [] }

        switch name {
        case "SessionStart":
            return [make(.sessionStarted(source: p["source"]?.stringValue, model: p["model"]?.stringValue))]
        case "UserPromptSubmit":
            let prompt = p["prompt"]?.stringValue ?? ""
            if Self.isAppGenerated(prompt) { return [make(.internalSession)] }
            return [make(.promptSubmitted(prompt))]
        case "PreToolUse":
            return [make(.toolStarted(toolName: toolName, input: input, toolUseId: toolUseId))]
        case "PostToolUse":
            return [make(.toolFinished(toolName: toolName, input: input, toolUseId: toolUseId,
                                       durationMs: nil, failed: Self.looksFailed(p["tool_response"])))]
        case "SubagentStart":
            guard let aid = p["agent_id"]?.stringValue else { return [] }
            return [make(.subagentStarted(agentId: aid, agentType: p["agent_type"]?.stringValue))]
        case "SubagentStop":
            guard let aid = p["agent_id"]?.stringValue else { return [] }
            return [make(.subagentStopped(agentId: aid))]
        case "Stop":
            return [make(.stopped(lastMessage: p["last_assistant_message"]?.stringValue, failed: false))]
        case "Interrupt":
            return [make(.interrupted)]
        case "SessionEnd":
            return [make(.sessionEnded(reason: p["reason"]?.stringValue))]
        default:
            return []
        }
    }

    public func hookOutput(for decision: Decision, mode: HookMode, payload: JSONValue) -> String? {
        guard mode == .permission else { return nil }
        switch decision {
        case .allow, .allowWith:
            // Правил «разрешать всегда» в ответе хука Codex нет — только разовое allow.
            return ClaudeCodeAdapter.permissionOutput(["behavior": "allow"])
        case .deny(let reason):
            let msg = (reason?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Пользователь отклонил это действие в AgentHUD."
            return ClaudeCodeAdapter.permissionOutput(["behavior": "deny", "message": .string(msg)])
        case .answer, .passthrough:
            return nil
        }
    }

    // MARK: - Режим проверки запросов

    /// Кто решает запросы разрешения в треде: `user` или `auto_review`.
    /// В событие хука Codex это не передаёт, но пишет в файл треда (`turn_context`, `thread_settings_applied`);
    /// берём последнее значение — его могли поменять посреди треда.
    public static func approvalsReviewer(sessionId: String, transcriptPath: String?, sessionsRoot: URL? = nil, now: Date = Date()) -> String? {
        guard let url = rolloutFile(sessionId: sessionId, transcriptPath: transcriptPath, sessionsRoot: sessionsRoot, now: now),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let key = Data("\"approvals_reviewer\":".utf8)
        guard let r = data.range(of: key, options: .backwards) else { return nil }
        var i = r.upperBound
        while i < data.count, data[i] == UInt8(ascii: " ") { i += 1 }
        guard i < data.count, data[i] == UInt8(ascii: "\"") else { return nil }
        let start = i + 1
        guard let end = data[start...].firstIndex(of: UInt8(ascii: "\"")), end - start < 64 else { return nil }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    /// Файл треда: `transcript_path` из события, иначе поиск `rollout-*-<id>.jsonl` за последние дни.
    static func rolloutFile(sessionId: String, transcriptPath: String?, sessionsRoot: URL?, now: Date) -> URL? {
        let fm = FileManager.default
        if let t = transcriptPath, !t.isEmpty, fm.fileExists(atPath: t) { return URL(fileURLWithPath: t) }
        guard sessionId.count >= 8 else { return nil }
        let root = sessionsRoot ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        for back in 0..<3 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            if let f = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix("\(sessionId).jsonl") }) {
                return dir.appendingPathComponent(f)
            }
        }
        return nil
    }

    /// Приложение Codex после каждого ответа запускает служебный тред (заголовки, подсказки)
    /// с промптом «This is an app-generated request…». Это не диалог пользователя.
    static func isAppGenerated(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("this is an app-generated request")
    }

    /// Ненулевой код выхода команды — шаг с ошибкой.
    static func looksFailed(_ response: JSONValue?) -> Bool {
        guard let r = response else { return false }
        if let code = r["exit_code"]?.intValue ?? r["exitCode"]?.intValue { return code != 0 }
        if let ok = r["success"]?.boolValue { return !ok }
        return false
    }

    public func summarize(toolName: String, input: JSONValue, cwd: String?) -> String {
        switch toolName {
        case "Bash", "shell", "exec_command", "local_shell", "unified_exec":
            let cmd = input["command"]?.stringValue
                ?? input["cmd"]?.stringValue
                ?? input["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? ""
            let line = cmd.split(separator: "\n").first.map(String.init) ?? ""
            return "$ " + (line.count > 80 ? String(line.prefix(79)) + "…" : line)
        case "apply_patch", "Edit", "Write":
            let files = Self.patchFiles(input["command"]?.stringValue ?? input["patch"]?.stringValue ?? input["input"]?.stringValue ?? "")
                .map { ClaudeCodeAdapter.shortPath($0, cwd: cwd) }
            if files.isEmpty { return "Правка файлов" }
            return "Patch " + files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " +\(files.count - 3)" : "")
        case "update_plan": return "Обновил план"
        case "web_search": return "WebSearch \"\(input["query"]?.stringValue ?? "")\""
        case "view_image": return "Смотрит картинку"
        case "request_user_input", "request_user_input_async":
            let q = SessionStore.questionText(input) ?? ""
            return q.isEmpty ? "Вопрос пользователю" : "Вопрос: " + (q.count > 70 ? String(q.prefix(69)) + "…" : q)
        default:
            return ClaudeCodeAdapter().summarize(toolName: toolName, input: input, cwd: cwd)
        }
    }

    /// Файлы из патча формата Codex: `*** Update File: path`, `*** Add File:`, `*** Delete File:`.
    static func patchFiles(_ patch: String) -> [String] {
        var out: [String] = []
        for line in patch.split(separator: "\n") {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                let f = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !out.contains(f) { out.append(f) }
            }
        }
        return out
    }
}
