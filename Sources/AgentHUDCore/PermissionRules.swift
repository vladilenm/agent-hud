import Foundation

/// Варианты «Разрешить всегда» для запроса разрешения.
///
/// Claude Code принимает в ответе хука `updatedPermissions` — те же записи, что присылает
/// в `permission_suggestions` (https://code.claude.com/docs/en/hooks, PermissionRequest).
/// Подсказки агента часто — точная команда (`kill 41684 41849`), из-за чего список правил
/// разрастается. Поэтому для простых команд добавляем шаблон по первым словам: `Bash(npm run *)`.
public struct RuleOption: Equatable, Sendable, Identifiable {
    public var id: String { update.compact() }
    /// «Bash(npm run *)»
    public var title: String
    /// «в этом проекте», «во всех проектах», «до конца сессии»
    public var scope: String
    /// Одна запись для `updatedPermissions`.
    public var update: JSONValue
    /// Шаблон, придуманный HUD (а не подсказка агента).
    public var generated: Bool
}

public enum PermissionRules {
    /// Где хранится правило. https://code.claude.com/docs/en/hooks — «Permission update entries».
    public static func scopeTitle(_ destination: String?) -> String {
        switch destination {
        case "session": return "до конца сессии"
        case "localSettings": return "в этом проекте"
        case "projectSettings": return "в проекте (общий файл)"
        case "userSettings": return "во всех проектах"
        default: return destination ?? ""
        }
    }

    public static func options(toolName: String, input: JSONValue, suggestions: [JSONValue]) -> [RuleOption] {
        var out: [RuleOption] = []
        func add(_ o: RuleOption) { if !out.contains(where: { $0.id == o.id }) { out.append(o) } }

        if toolName == "Bash", let cmd = input["command"]?.stringValue, let pattern = bashPattern(cmd) {
            for dest in ["localSettings", "userSettings"] {
                add(RuleOption(title: "Bash(\(pattern))", scope: scopeTitle(dest),
                               update: addRule(tool: "Bash", content: pattern, destination: dest), generated: true))
            }
        }
        for s in suggestions {
            guard let title = describe(s) else { continue }
            add(RuleOption(title: title, scope: scopeTitle(s["destination"]?.stringValue), update: s, generated: false))
        }
        // MCP-инструменты: правило на весь инструмент (без ruleContent — иначе правило ничего не совпадёт).
        if toolName.hasPrefix("mcp__"), !out.contains(where: { $0.update["type"]?.stringValue == "addRules" }) {
            add(RuleOption(title: toolName, scope: scopeTitle("localSettings"),
                           update: addRule(tool: toolName, content: nil, destination: "localSettings"), generated: true))
        }
        return out
    }

    static func addRule(tool: String, content: String?, destination: String) -> JSONValue {
        var rule = JSONObject()
        rule["toolName"] = .string(tool)
        if let content { rule["ruleContent"] = .string(content) }
        return ["type": "addRules", "rules": [.object(rule)], "behavior": "allow", "destination": .string(destination)]
    }

    /// Подпись для записи `updatedPermissions`. `nil` — запись не про «разрешить».
    public static func describe(_ entry: JSONValue) -> String? {
        switch entry["type"]?.stringValue {
        case "addRules", "replaceRules":
            guard entry["behavior"]?.stringValue == "allow" else { return nil }
            let rules = (entry["rules"]?.arrayValue ?? []).compactMap { r -> String? in
                guard let tool = r["toolName"]?.stringValue else { return nil }
                if let c = r["ruleContent"]?.stringValue, !c.isEmpty {
                    return "\(tool)(\(c.count > 60 ? String(c.prefix(59)) + "…" : c))"
                }
                return tool
            }
            return rules.isEmpty ? nil : rules.joined(separator: ", ")
        case "setMode":
            switch entry["mode"]?.stringValue {
            case "acceptEdits": return "Принимать правки файлов без вопросов"
            case "default", "manual": return "Обычный режим"
            case "plan": return "Режим планирования"
            default: return nil   // остальные режимы (в том числе без вопросов) из HUD не включаем
            }
        case "addDirectories":
            let dirs = (entry["directories"]?.arrayValue ?? []).compactMap(\.stringValue)
            return dirs.isEmpty ? nil : "Доступ к папке " + dirs.joined(separator: ", ")
        default:
            return nil
        }
    }

    /// Первые слова, после которых обычно идёт аргумент: `npm run build` → `npm run *`.
    static let subcommandTools: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "npx", "bunx", "git", "gh", "docker", "kubectl", "go", "cargo", "swift",
        "pod", "expo", "eas", "flutter", "dart", "pip", "pip3", "brew", "make", "xcodebuild", "xcrun", "adb",
        "fastlane", "bundle", "composer", "dotnet", "uv", "poetry", "nx", "turbo", "vite", "next", "jest", "vitest",
        "tsc", "eslint", "prettier", "prisma", "supabase", "firebase", "react-native",
    ]

    /// Команды, для которых шаблон слишком широк (выполняют произвольный код или опасны) — только точное правило.
    static let noPattern: Set<String> = [
        "rm", "sudo", "su", "dd", "chmod", "chown", "mkfs", "curl", "wget", "ssh", "scp", "rsync", "eval", "exec",
        "xargs", "env", "node", "python", "python3", "ruby", "perl", "php", "bash", "sh", "zsh", "fish", "osascript",
        "open", "mv", "cp", "tee", "find", "awk", "sed", "deno",
    ]

    /// Шаблон для простой команды или `nil`, если шаблон не нужен или опасен.
    public static func bashPattern(_ command: String) -> String? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        // Составные команды Claude Code проверяет по частям — шаблон на всю строку не поможет.
        for bad in ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n", "&"] where cmd.contains(bad) { return nil }
        let words = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first, !first.contains("="), !first.hasPrefix("."), !first.hasPrefix("/"),
              !noPattern.contains(first) else { return nil }
        if subcommandTools.contains(first) {
            // `git status` → `git status *` (совпадает и без аргументов). Флаг вторым словом — непонятно, что шаблонить.
            guard words.count >= 2, !words[1].hasPrefix("-") else { return nil }
            return "\(first) \(words[1]) *"
        }
        // `kill 41684 41849` → `kill *`. Одно слово — точное правило не хуже шаблона.
        return words.count >= 2 ? "\(first) *" : nil
    }

    /// Обновления для одобрения плана: в каком режиме агент продолжит.
    public static func planApproval(acceptEdits: Bool) -> [JSONValue] {
        [["type": "setMode", "mode": .string(acceptEdits ? "acceptEdits" : "default"), "destination": "session"]]
    }
}
