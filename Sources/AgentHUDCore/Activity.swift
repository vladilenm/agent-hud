import Foundation

/// Запись журнала активности: промпт, конец хода, решение в HUD.
/// Журнал — по файлу на день: `~/Library/Application Support/AgentHUD/activity/ГГГГ-ММ-ДД.jsonl`.
/// Только локально; из него строится сводка за день (для стендапа) и вкладка «Сегодня» на карте агентов.
public struct ActivityRecord: Equatable, Sendable {
    public enum Kind: String, Sendable { case prompt, stop, decision }

    public var kind: Kind
    public var time: Date
    public var agent: String
    public var session: String
    public var project: String
    public var cwd: String
    /// Промпт, итоговое сообщение агента или суть решения.
    public var text: String
    /// Для решения — что решили («разрешено», «отклонено»…).
    public var detail: String?
    public var failed = false
    public var stats: TurnStats?

    public init(kind: Kind, time: Date, agent: String, session: String, project: String, cwd: String,
                text: String, detail: String? = nil, failed: Bool = false, stats: TurnStats? = nil) {
        self.kind = kind
        self.time = time
        self.agent = agent
        self.session = session
        self.project = project
        self.cwd = cwd
        self.text = text
        self.detail = detail
        self.failed = failed
        self.stats = stats
    }

    public func toJSON() -> JSONValue {
        var o = JSONObject()
        o["kind"] = .string(kind.rawValue)
        o["t"] = .double(time.timeIntervalSince1970)
        o["agent"] = .string(agent)
        o["session"] = .string(session)
        o["project"] = .string(project)
        o["cwd"] = .string(cwd)
        o["text"] = .string(text)
        if let detail { o["detail"] = .string(detail) }
        if failed { o["failed"] = true }
        if let s = stats {
            var tools = JSONObject()
            for k in s.tools.keys.sorted() { tools[k] = .int(s.tools[k]!) }
            o["tools"] = .object(tools)
            if !s.files.isEmpty { o["files"] = .array(s.files.map { .string($0) }) }
            if s.subagents > 0 { o["subagents"] = .int(s.subagents) }
            if let d = s.durationSec { o["dur"] = .int(d) }
        }
        return .object(o)
    }

    public init?(json v: JSONValue) {
        guard let kind = v["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let t = v["t"]?.doubleValue else { return nil }
        self.kind = kind
        time = Date(timeIntervalSince1970: t)
        agent = v["agent"]?.stringValue ?? ""
        session = v["session"]?.stringValue ?? ""
        project = v["project"]?.stringValue ?? ""
        cwd = v["cwd"]?.stringValue ?? ""
        text = v["text"]?.stringValue ?? ""
        detail = v["detail"]?.stringValue
        failed = v["failed"]?.boolValue ?? false
        if let tools = v["tools"]?.objectValue {
            var d: [String: Int] = [:]
            for e in tools.entries { if let n = e.value.intValue { d[e.key] = n } }
            stats = TurnStats(tools: d, files: v["files"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                              subagents: v["subagents"]?.intValue ?? 0, durationSec: v["dur"]?.intValue)
        }
    }
}

public enum ActivityLog {
    public static var directory: URL { AgentHUDPaths.supportDirectory.appendingPathComponent("activity", isDirectory: true) }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func file(for day: Date) -> URL { directory.appendingPathComponent(dayString(day) + ".jsonl") }

    public static func append(_ r: ActivityRecord) {
        let url = file(for: r.time)
        let line = r.toJSON().compact() + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    public static func read(day: Date) -> [ActivityRecord] {
        guard let text = try? String(contentsOf: file(for: day), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONValue.parse(String(line))).flatMap(ActivityRecord.init(json:))
        }
    }
}

// MARK: - Сводка за день

public struct DayTurn: Equatable, Sendable {
    public var session: String
    public var start: Date
    public var prompt: String
    public var end: Date?
    public var failed = false
    public var stats = TurnStats()
    public var message: String?
}

public struct DayProject: Equatable, Sendable {
    public var name: String
    public var cwd: String
    public var turns: [DayTurn] = []
    public var decisions: [String: Int] = [:]

    public var workedSec: Int { turns.reduce(0) { $0 + ($1.stats.durationSec ?? 0) } }
    public var edits: Int { turns.reduce(0) { $0 + $1.stats.edits } }
    public var commands: Int { turns.reduce(0) { $0 + $1.stats.commands } }
}

public enum DailySummary {
    /// Записи дня → проекты с ходами (промпт → итог), в порядке первой активности.
    public static func build(_ records: [ActivityRecord]) -> [DayProject] {
        var projects: [String: DayProject] = [:]
        var order: [String] = []
        var open: [String: (project: String, index: Int)] = [:]   // session → незакрытый ход

        func project(_ r: ActivityRecord) -> String {
            let key = r.cwd.isEmpty ? r.project : r.cwd
            if projects[key] == nil {
                projects[key] = DayProject(name: r.project, cwd: r.cwd)
                order.append(key)
            }
            return key
        }

        for r in records.sorted(by: { $0.time < $1.time }) {
            let key = project(r)
            switch r.kind {
            case .prompt:
                projects[key]!.turns.append(DayTurn(session: r.session, start: r.time, prompt: r.text))
                open[r.session] = (key, projects[key]!.turns.count - 1)
            case .stop:
                if let o = open[r.session] {
                    projects[o.project]!.turns[o.index].end = r.time
                    projects[o.project]!.turns[o.index].failed = r.failed
                    projects[o.project]!.turns[o.index].stats = r.stats ?? TurnStats()
                    projects[o.project]!.turns[o.index].message = r.text.isEmpty ? nil : r.text
                    open[r.session] = nil
                }
            case .decision:
                projects[key]!.decisions[r.detail ?? "решение", default: 0] += 1
            }
        }
        return order.compactMap { projects[$0] }.filter { !$0.turns.isEmpty || !$0.decisions.isEmpty }
    }

    public static func markdown(_ projects: [DayProject], day: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"

        var out = "# Сводка агентов · \(df.string(from: day))\n\n"
        guard !projects.isEmpty else { return out + "За этот день агенты ничего не делали.\n" }

        let turns = projects.reduce(0) { $0 + $1.turns.count }
        let worked = projects.reduce(0) { $0 + $1.workedSec }
        let edits = projects.reduce(0) { $0 + $1.edits }
        let commands = projects.reduce(0) { $0 + $1.commands }
        let decisions = projects.reduce(0) { $0 + $1.decisions.values.reduce(0, +) }
        var total = "**Итого:** \(turns) \(plural(turns, "задача", "задачи", "задач")) в \(projects.count) \(plural(projects.count, "проекте", "проектах", "проектах"))"
        if worked > 0 { total += " · агенты работали \(duration(worked))" }
        total += " · правок файлов: \(edits) · команд: \(commands)"
        if decisions > 0 { total += " · решений в HUD: \(decisions)" }
        out += total + "\n"

        for p in projects {
            out += "\n## \(p.name)\n\n"
            var line = "\(p.turns.count) \(plural(p.turns.count, "задача", "задачи", "задач"))"
            if p.workedSec > 0 { line += " · \(duration(p.workedSec))" }
            line += " · правок: \(p.edits) · команд: \(p.commands)"
            out += line + "\n\n"
            for t in p.turns {
                let prompt = oneLine(t.prompt, 120)
                var status: String
                if t.end == nil { status = "не завершена" }
                else if t.failed { status = "ошибка" }
                else { status = "готово" + (t.stats.durationSec.map { " за \(duration($0))" } ?? "") }
                var counters: [String] = []
                if t.stats.edits > 0 { counters.append("правок \(t.stats.edits)") }
                if t.stats.commands > 0 { counters.append("команд \(t.stats.commands)") }
                if t.stats.subagents > 0 { counters.append("субагентов \(t.stats.subagents)") }
                if !counters.isEmpty { status += " · " + counters.joined(separator: " · ") }
                out += "- **\(tf.string(from: t.start))** \(prompt.isEmpty ? "(без текста)" : prompt) — \(status)\n"
                if let m = t.message, !m.isEmpty { out += "  - Итог: \(oneLine(m, 200))\n" }
                if !t.stats.files.isEmpty {
                    let names = t.stats.files.prefix(4).map { ($0 as NSString).lastPathComponent }
                    out += "  - Файлы: \(names.joined(separator: ", "))" + (t.stats.files.count > 4 ? " +\(t.stats.files.count - 4)" : "") + "\n"
                }
            }
            if !p.decisions.isEmpty {
                let d = p.decisions.keys.sorted().map { "\($0) \(p.decisions[$0]!)" }.joined(separator: " · ")
                out += "\nРешения в HUD: \(d)\n"
            }
        }
        return out
    }

    public static func duration(_ sec: Int) -> String {
        if sec < 60 { return "меньше минуты" }
        if sec < 3600 { return "\(sec / 60) мин" }
        return "\(sec / 3600) ч \(String(format: "%02d", sec % 3600 / 60)) мин"
    }

    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
}
