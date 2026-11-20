import AgentHUDCore
import AppKit
import SwiftUI

/// Окно «Карта агентов»: все сессии сразу — по проектам, с текущим шагом, деревом субагентов
/// и последними действиями («Сейчас»), плюс лента и итоги дня из журнала активности («Сегодня»).
@MainActor
final class AgentMapController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    var isShown: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Карта агентов"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("AgentMap")
            w.contentView = NSHostingView(rootView: AgentMapView(model: model))
            w.delegate = self
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

struct AgentMapView: View {
    @ObservedObject var model: AppModel
    @State var tab = 0
    @State private var showHidden = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.line).frame(height: 1)
            if tab == 0 { NowMap(model: model, showHidden: showHidden) } else { TodayMap(model: model) }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Brand.bg)
        .tint(Brand.accent)
    }

    private var header: some View {
        let all = model.store.order.compactMap { model.store.session($0) }.filter(\.revealed)
        let working = all.filter { $0.state == .working || $0.state == .starting }.count
        let waiting = all.filter { $0.state.needsUser || $0.state == .expired }.count
        let done = all.filter { $0.state == .done }.count
        return HStack(spacing: 14) {
            Image(systemName: "map.fill").font(.system(size: 18)).foregroundStyle(Brand.accent)
            Text("Карта агентов").font(Brand.display(20)).foregroundStyle(Brand.ink)
            HStack(spacing: 6) {
                CountPill(n: working, title: DailySummary.plural(working, "работает", "работают", "работают"), tone: .accent)
                CountPill(n: waiting, title: DailySummary.plural(waiting, "ждёт тебя", "ждут тебя", "ждут тебя"), tone: .warning)
                CountPill(n: done, title: "готово", tone: .success)
            }
            Spacer()
            if tab == 0 {
                Toggle("Скрытые", isOn: $showHidden).toggleStyle(BrandSwitch()).help("Показывать скрытые сессии")
                Text("Скрытые").font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
            }
            BrandSegmented(options: [(0, "СЕЙЧАС"), (1, "СЕГОДНЯ")], selection: $tab).frame(width: 200)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Brand.surface)
    }
}

struct CountPill: View {
    let n: Int
    let title: String
    let tone: BrandTag.Tone

    var body: some View {
        BrandTag(text: "\(n) \(title)", tone: n > 0 ? tone : .neutral)
    }
}

// MARK: - Сейчас

struct NowMap: View {
    @ObservedObject var model: AppModel
    let showHidden: Bool

    var body: some View {
        let sessions = model.store.order.compactMap { model.store.session($0) }
            .filter { $0.revealed && (showHidden || !$0.hidden) }
        let groups = Dictionary(grouping: sessions, by: \.cwd)
        let projects = groups.keys.sorted { a, b in
            let ra = rank(groups[a]!), rb = rank(groups[b]!)
            if ra != rb { return ra < rb }
            return (groups[a]!.map(\.lastEventAt).max() ?? .distantPast) > (groups[b]!.map(\.lastEventAt).max() ?? .distantPast)
        }
        if projects.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "map").font(.system(size: 40, weight: .light)).foregroundStyle(Brand.inkSubtle)
                Text("Агентов пока нет").font(Brand.body(15, .medium)).foregroundStyle(Brand.ink)
                Text("Запусти Claude Code в VS Code, терминале или приложении — сессии появятся здесь, сгруппированные по проектам.")
                    .font(Brand.body(12)).foregroundStyle(Brand.inkMuted).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 560), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(projects, id: \.self) { cwd in
                        ProjectIsland(model: model, cwd: cwd, sessions: sortSessions(groups[cwd]!))
                    }
                }
                .padding(18)
            }
        }
    }

    /// Сначала проекты, где ждут тебя, потом те, где работают.
    private func rank(_ ss: [AgentSession]) -> Int {
        if ss.contains(where: { $0.state.needsUser || $0.state == .expired }) { return 0 }
        if ss.contains(where: { $0.state == .working || $0.state == .starting }) { return 1 }
        return 2
    }

    private func sortSessions(_ ss: [AgentSession]) -> [AgentSession] {
        ss.sorted { a, b in
            let ra = rank([a]), rb = rank([b])
            return ra != rb ? ra < rb : a.lastEventAt > b.lastEventAt
        }
    }
}

struct ProjectIsland: View {
    @ObservedObject var model: AppModel
    let cwd: String
    let sessions: [AgentSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProjectDot(cwd: cwd, size: 10)
                Text(sessions.first?.projectName ?? cwd).font(Brand.body(15, .semibold)).foregroundStyle(Brand.ink)
                Text(HookSetup.tilde(cwd)).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(sessions.count) \(DailySummary.plural(sessions.count, "сессия", "сессии", "сессий"))")
                    .font(Brand.mono(10, medium: true)).foregroundStyle(Brand.inkSubtle)
            }
            ForEach(sessions) { s in MapSessionCard(model: model, session: s) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Brand.radiusXl).fill(Brand.surface))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: Brand.radiusXl, topTrailingRadius: Brand.radiusXl)
                .fill(ProjectColor.color(cwd)).frame(height: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: Brand.radiusXl).strokeBorder(Brand.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Brand.radiusXl))
    }
}

struct MapSessionCard: View {
    @ObservedObject var model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 28,
                           animated: model.settings.animations, kind: session.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "Без задачи" : session.title)
                        .font(Brand.body(13, .medium)).foregroundStyle(Brand.ink).lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(subtitle(ctx.date)).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                BrandTag(text: session.state.shortTitle, tone: session.state.tone)
            }
            if let p = session.activePending { attention(p) }
            // Текущий шаг — последний лист дерева (со спиннером), отдельной строкой не дублируем.
            AgentTree(session: session)
            if let msg = session.lastMessage, session.state == .done || session.state == .error {
                Text(msg).font(Brand.body(12)).foregroundStyle(Brand.inkMuted).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surfaceSunken.opacity(session.hidden ? 0.4 : 1)))
        .opacity(session.hidden ? 0.6 : 1)
    }

    private func attention(_ p: PendingRequest) -> some View {
        let what: String = {
            switch p.kind {
            case .permission(let tool, let input):
                return "Разрешение: " + Adapters.adapter(for: session.kind).summarize(toolName: tool, input: input, cwd: session.cwd)
            case .question(let qs, _): return "Вопрос: " + (qs.first?.question ?? "")
            case .plan: return "План ждёт одобрения"
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Brand.warning)
            Text(what).font(Brand.body(12)).foregroundStyle(Brand.ink).lineLimit(2)
            Spacer(minLength: 4)
            Button("Ответить") {
                model.settings.hudVisible = true
                model.selectedKey = session.id
                model.selectedByUser = true
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(Brand.warningSoft))
    }

    private var footer: some View {
        let st = session.turnStats()
        let steps = st.tools.values.reduce(0, +)
        var chips: [String] = []
        if steps > 0 { chips.append("шагов \(steps)") }
        if st.edits > 0 { chips.append("правок \(st.edits)") }
        if st.commands > 0 { chips.append("команд \(st.commands)") }
        if !st.files.isEmpty { chips.append("файлов \(st.files.count)") }
        if st.subagents > 0 { chips.append("субагентов \(st.subagents)") }
        return HStack(spacing: 6) {
            Text(chips.isEmpty ? "за ход пока ничего" : "за ход: " + chips.joined(separator: " · "))
                .font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle).lineLimit(1)
            Spacer(minLength: 4)
            GhostButton(title: "Открыть", symbol: "arrow.up.forward.app") { model.open(session.id) }
            if session.hidden {
                GhostButton(title: "Показать", symbol: "eye") { model.unhide(session.id) }
            } else {
                GhostButton(title: "Скрыть", symbol: "eye.slash") { model.hide(session.id) }
            }
        }
        .padding(.horizontal, -6)
    }

    private func subtitle(_ now: Date) -> String {
        var parts = [session.kind.displayName, session.host.label]
        parts.append(Fmt.elapsed(from: session.startedAt, to: session.finishedAt ?? now))
        if let m = session.model { parts.append(m.replacingOccurrences(of: "claude-", with: "")) }
        return parts.joined(separator: " · ")
    }
}

/// Дерево хода: основной агент и его последние шаги, субагенты — ветками со своими шагами.
struct AgentTree: View {
    let session: AgentSession
    static let mainSteps = 5
    static let subSteps = 3

    var body: some View {
        let steps = session.turnSteps
        let main = steps.filter { $0.agentId == nil && !$0.isSubagent }
        let subs = steps.filter(\.isSubagent)
        if main.isEmpty && subs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 3) {
                TreeNode(icon: "person.fill", title: "Основной агент", status: mainStatus,
                         detail: main.count > Self.mainSteps ? "ещё \(main.count - Self.mainSteps) шагов выше" : nil)
                ForEach(main.suffix(Self.mainSteps)) { st in TreeLeaf(step: st, depth: 1) }
                ForEach(subs) { sub in
                    let aid = String(sub.id.dropFirst("subagent:".count))
                    let children = steps.filter { $0.agentId == aid }
                    TreeNode(icon: "person.2.fill", title: sub.summary, status: sub.status,
                             detail: sub.durationMs.map(Fmt.duration) ?? (children.isEmpty ? nil : "шагов: \(children.count)"),
                             depth: 1)
                    ForEach(children.suffix(Self.subSteps)) { st in TreeLeaf(step: st, depth: 2) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(Brand.surface))
        }
    }

    /// Агент в ходе (работает или ждёт тебя посреди хода) — спиннер; ошибка — крестик; иначе — готово.
    private var mainStatus: StepStatus {
        switch session.state {
        case .working, .starting, .waitingPermission, .waitingAnswer, .expired: return .running
        case .error: return .failed
        default: return .ok
        }
    }
}

struct TreeNode: View {
    let icon: String
    let title: String
    let status: StepStatus
    var detail: String? = nil
    var depth = 0

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 { TreeIndent(depth: depth) }
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Brand.accentText).frame(width: 14)
            Text(title).font(Brand.body(12, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
            if let detail { Text(detail).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle).lineLimit(1) }
            Spacer(minLength: 4)
            StatusMark(status: status)
        }
        .frame(height: 18)
    }
}

struct TreeLeaf: View {
    let step: Step
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            TreeIndent(depth: depth)
            Image(systemName: Fmt.icon(for: step.toolName)).font(.system(size: 9)).foregroundStyle(Brand.inkSubtle).frame(width: 14)
            Text(step.summary)
                .font(step.toolName == "Bash" ? Brand.mono(11) : Brand.body(11))
                .foregroundStyle(step.status == .failed ? Brand.danger : Brand.inkMuted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let ms = step.durationMs { Text(Fmt.duration(ms)).font(Brand.mono(9.5)).foregroundStyle(Brand.inkSubtle) }
            StatusMark(status: step.status)
        }
        .frame(height: 17)
    }
}

/// Отступ ветки дерева: вертикальные линии уровней и «уголок».
struct TreeIndent: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { i in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.line).frame(width: 1)
                    if i == depth - 1 { Rectangle().fill(Brand.line).frame(width: 8, height: 1).offset(y: 0) }
                }
                .frame(width: 14, alignment: .leading)
                .padding(.leading, 6)
            }
        }
        .frame(height: 17)
    }
}

struct StatusMark: View {
    let status: StepStatus

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .ok: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.success).frame(width: 12)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.danger).frame(width: 12)
        }
    }
}

// MARK: - Сегодня

struct TodayMap: View {
    @ObservedObject var model: AppModel
    @State private var projects: [DayProject] = []
    @State private var loadedAt = Date()
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toolbar
                if projects.isEmpty {
                    Text(model.settings.activityLog
                         ? "Сегодня в журнале пока пусто. Записи появятся, когда агенты начнут получать задачи."
                         : "Журнал активности выключен (Настройки → Журнал активности).")
                        .font(Brand.body(13)).foregroundStyle(Brand.inkMuted)
                        .padding(.vertical, 30).frame(maxWidth: .infinity)
                } else {
                    totals
                    DayTimeline(projects: projects, now: loadedAt)
                    ForEach(projects, id: \.cwd) { p in DayProjectCard(project: p) }
                }
            }
            .padding(18)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        loadedAt = Date()
        projects = DailySummary.build(ActivityLog.read(day: loadedAt))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Обновлено в \(loadedAt.formatted(date: .omitted, time: .shortened))")
                .font(Brand.mono(10.5)).foregroundStyle(Brand.inkSubtle)
            Spacer()
            GhostButton(title: "Обновить", symbol: "arrow.clockwise", action: reload)
            GhostButton(title: copied ? "Скопировано" : "Скопировать Markdown", symbol: "doc.on.doc") {
                let md = DailySummary.markdown(projects, day: loadedAt)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(md, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            GhostButton(title: "Открыть файл", symbol: "doc.text") { NSWorkspace.shared.open(model.writeSummary(day: loadedAt)) }
        }
    }

    private var totals: some View {
        let turns = projects.reduce(0) { $0 + $1.turns.count }
        let worked = projects.reduce(0) { $0 + $1.workedSec }
        let edits = projects.reduce(0) { $0 + $1.edits }
        let commands = projects.reduce(0) { $0 + $1.commands }
        let decisions = projects.reduce(0) { $0 + $1.decisions.values.reduce(0, +) }
        return HStack(spacing: 10) {
            StatTile(value: "\(turns)", title: DailySummary.plural(turns, "задача", "задачи", "задач"))
            StatTile(value: "\(projects.count)", title: DailySummary.plural(projects.count, "проект", "проекта", "проектов"))
            StatTile(value: worked > 0 ? DailySummary.duration(worked) : "—", title: "работа агентов")
            StatTile(value: "\(edits)", title: "правок файлов")
            StatTile(value: "\(commands)", title: "команд")
            StatTile(value: "\(decisions)", title: "решений в HUD")
        }
    }
}

struct StatTile: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Brand.display(20)).foregroundStyle(Brand.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(title.uppercased()).font(Brand.mono(9.5, medium: true)).tracking(0.5).foregroundStyle(Brand.inkSubtle).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))
    }
}

/// Лента дня: по строке на проект, ходы агентов — полосами по времени.
struct DayTimeline: View {
    let projects: [DayProject]
    let now: Date
    static let rowHeight: CGFloat = 22
    static let labelWidth: CGFloat = 150

    var body: some View {
        let starts = projects.flatMap { $0.turns.map(\.start) }
        let cal = Calendar.current
        let first = starts.min() ?? now
        let from = cal.date(bySettingHour: cal.component(.hour, from: first), minute: 0, second: 0, of: first) ?? first
        let toBase = max(now, projects.flatMap { $0.turns.compactMap(\.end) }.max() ?? now)
        let to = cal.date(byAdding: .hour, value: 1, to: cal.date(bySettingHour: cal.component(.hour, from: toBase), minute: 0, second: 0, of: toBase) ?? toBase) ?? toBase
        let span = max(3600, to.timeIntervalSince(from))
        let hours = Int(span / 3600)

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 1, title: "Лента дня")
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width - Self.labelWidth
                    ZStack(alignment: .topLeading) {
                        // Часовая сетка
                        ForEach(0...hours, id: \.self) { h in
                            let x = Self.labelWidth + w * CGFloat(Double(h) * 3600 / span)
                            Rectangle().fill(Brand.line).frame(width: 1, height: geo.size.height - 16).offset(x: x, y: 16)
                            if h < hours || hours <= 1 {
                                Text(String(format: "%02d:00", (cal.component(.hour, from: from) + h) % 24))
                                    .font(Brand.mono(9.5)).foregroundStyle(Brand.inkSubtle)
                                    .offset(x: x + 3, y: 0)
                            }
                        }
                        ForEach(Array(projects.enumerated()), id: \.offset) { i, p in
                            let y = 20 + CGFloat(i) * Self.rowHeight
                            HStack(spacing: 5) {
                                ProjectDot(cwd: p.cwd, size: 7)
                                Text(p.name).font(Brand.body(11, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                            }
                            .frame(width: Self.labelWidth - 8, alignment: .leading)
                            .offset(y: y + 2)
                            ForEach(Array(p.turns.enumerated()), id: \.offset) { _, t in
                                let x0 = Self.labelWidth + w * CGFloat(t.start.timeIntervalSince(from) / span)
                                let end = t.end ?? now
                                let bw = max(4, w * CGFloat(end.timeIntervalSince(t.start) / span))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(ProjectColor.color(p.cwd).opacity(t.end == nil ? 0.45 : 0.9))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(t.failed ? Brand.danger : .clear, lineWidth: 1.5))
                                    .frame(width: bw, height: Self.rowHeight - 8)
                                    .offset(x: x0, y: y + 3)
                                    .help("\(t.start.formatted(date: .omitted, time: .shortened)) · \(t.prompt.prefix(80))")
                            }
                        }
                    }
                }
                .frame(height: 24 + CGFloat(projects.count) * Self.rowHeight)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))
        }
    }
}

struct DayProjectCard: View {
    let project: DayProject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProjectDot(cwd: project.cwd, size: 9)
                Text(project.name).font(Brand.body(14, .semibold)).foregroundStyle(Brand.ink)
                Text(summaryLine).font(Brand.mono(10.5)).foregroundStyle(Brand.inkSubtle)
                Spacer()
            }
            ForEach(Array(project.turns.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.start.formatted(date: .omitted, time: .shortened)).font(Brand.mono(11)).foregroundStyle(Brand.inkSubtle)
                        .frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.prompt.isEmpty ? "(без текста)" : t.prompt).font(Brand.body(12, .medium)).foregroundStyle(Brand.ink).lineLimit(2)
                        if let m = t.message, !m.isEmpty {
                            Text(m).font(Brand.body(11)).foregroundStyle(Brand.inkMuted).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(status(t)).font(Brand.mono(10)).foregroundStyle(t.failed ? Brand.danger : Brand.inkSubtle).lineLimit(1)
                }
            }
            if !project.decisions.isEmpty {
                Text("Решения в HUD: " + project.decisions.keys.sorted().map { "\($0) \(project.decisions[$0]!)" }.joined(separator: " · "))
                    .font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
        .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))
    }

    private var summaryLine: String {
        var s = "\(project.turns.count) \(DailySummary.plural(project.turns.count, "задача", "задачи", "задач"))"
        if project.workedSec > 0 { s += " · \(DailySummary.duration(project.workedSec))" }
        return s + " · правок \(project.edits) · команд \(project.commands)"
    }

    private func status(_ t: DayTurn) -> String {
        guard t.end != nil else { return "в работе" }
        if t.failed { return "ошибка" }
        var parts = [t.stats.durationSec.map(DailySummary.duration) ?? "готово"]
        if t.stats.edits > 0 { parts.append("правок \(t.stats.edits)") }
        if t.stats.commands > 0 { parts.append("команд \(t.stats.commands)") }
        return parts.joined(separator: " · ")
    }
}
