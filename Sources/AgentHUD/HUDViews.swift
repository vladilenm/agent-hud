import AgentHUDCore
import SwiftUI

/// Флаг для рендера превью в PNG: материалы (blur) в ImageRenderer не рисуются.
private struct SolidBackgroundKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var solidBackground: Bool {
        get { self[SolidBackgroundKey.self] }
        set { self[SolidBackgroundKey.self] = newValue }
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat
    @Environment(\.solidBackground) private var solid
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(solid ? AnyShapeStyle(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                                : AnyShapeStyle(.regularMaterial))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

extension View {
    func glass(_ radius: CGFloat = 14) -> some View { modifier(Glass(radius: radius)) }
}

// MARK: - Корень HUD

/// Плавное появление и исчезновение без анимации размеров. Пружинные анимации раскладки меняли размер
/// содержимого на каждом кадре, и окно HUD подстраивалось ~74 раза в секунду с дробными размерами —
/// HUD мерцал, а иконки дёргались. Прозрачность размер не меняет: окно подстраивается один раз.
enum HUDFade {
    static let card = AnyTransition.opacity.animation(.easeOut(duration: 0.14))
    static let avatar = AnyTransition.opacity.animation(.easeOut(duration: 0.18))
}

struct HUDRootView: View {
    @ObservedObject var model: AppModel
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        let left = model.settings.anchorLeft
        VStack(alignment: left ? .leading : .trailing, spacing: 8) {
            AvatarRow(model: model)
            if let key = model.selectedKey, let s = model.store.session(key) {
                SessionCard(model: model, session: s)
                    .transition(HUDFade.card)
            }
        }
        .padding(14)   // место под тень
        .fixedSize()
        .tint(Brand.accent)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        // Содержимое прижато к углу-якорю. Если окно на кадр разошлось с содержимым по размеру,
        // содержимое не уезжает к центру окна (раньше оно на этот кадр смещалось на полразницы).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .topLeading : .topTrailing)
    }
}

/// Сколько места окошку сессии по высоте: экран минус строка меню, ряд иконок и поля.
enum HUDMetrics {
    @MainActor static var maxCardHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(320, screen - 110)
    }
}

// MARK: - Ряд персонажей

struct AvatarRow: View {
    @ObservedObject var model: AppModel
    static let maxShown = 6

    var body: some View {
        // Порядок устойчивый — по времени появления. Раньше ждущие прыгали в начало ряда и обратно
        // на каждом запросе разрешения, и иконки постоянно менялись местами.
        let sorted = Self.ordered(model.visibleSessions)
        let shown = Array(sorted.prefix(Self.maxShown))
        let overflow = Array(sorted.dropFirst(Self.maxShown))
        let overflowWaits = overflow.contains { $0.state.needsUser || $0.state == .expired }
        let labels = model.settings.projectLabels ? model.projectShortLabels : [:]

        HStack(alignment: .top, spacing: 6) {
            ForEach(shown) { s in
                AvatarButton(model: model, session: s, projectLabel: labels[s.cwd])
                    .transition(HUDFade.avatar)
            }
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { s in
                        Button("\(s.projectName) — \(s.state.title)") { model.select(s.id) }
                    }
                } label: {
                    Text("+\(overflow.count)").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(overflowWaits ? Color.orange : Color.primary)
                        .frame(width: 30, height: 40)
                }
                .help(overflowWaits ? "Среди остальных сессий кто-то ждёт тебя" : "Остальные сессии")
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glass(16)
    }

    static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in a.startedAt != b.startedAt ? a.startedAt < b.startedAt : a.id < b.id }
    }
}

struct AvatarButton: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    var projectLabel: String? = nil
    @State private var hover = false

    var body: some View {
        let selected = model.selectedKey == session.id
        Button { model.select(session.id) } label: {
            VStack(spacing: 2) {
                AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 34,
                           animated: model.settings.animations, kind: session.kind)
                    .padding(3)
                if let projectLabel {
                    ProjectChip(cwd: session.cwd, label: projectLabel)
                        .frame(maxWidth: 66)
                }
            }
            .padding(.bottom, projectLabel == nil ? 0 : 2)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : (hover ? Color.primary.opacity(0.07) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tooltip)
        .contextMenu {
            Button(session.host.openTitle) { model.open(session.id) }
            Button("Карта агентов") { model.openMap() }
            Button("Скрыть") { model.hide(session.id) }
        }
    }

    private var tooltip: String {
        var parts = ["\(session.projectName) — \(session.state.title) · \(session.host.label)"]
        if !session.title.isEmpty { parts.append(session.title) }
        if let step = session.currentStep { parts.append(step.summary) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Окошко сессии

struct SessionCard: View {
    @ObservedObject var model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let p = session.activePending {
                Group {
                    switch p.kind {
                    case .permission(let tool, let input):
                        PermissionView(model: model, session: session, request: p, tool: tool, input: input)
                    case .question(let qs, _):
                        QuestionView(model: model, host: session.host, request: p, questions: qs)
                    case .plan(let text, _):
                        PlanView(model: model, session: session, request: p, text: text)
                    }
                }
                .id(p.id)
                // Запрос с кнопками раскладывается первым; сжимается лента шагов, а не он.
                .layoutPriority(1)
            } else if let p = session.expiredPending {
                ExpiredView(model: model, session: session, request: p)
            } else if session.state.needsUser {
                Notice(icon: session.host.placeSymbol, color: .orange,
                       text: "Агент ждёт ответа \(session.host.placeIn)"
                           + (session.waitingNote.map { ": «\($0.count > 160 ? String($0.prefix(159)) + "…" : $0)»" } ?? "."),
                       actions: [("Открыть", { model.open(session.id) })])
            }
            if let msg = session.lastMessage, session.state == .done || session.state == .error {
                LastMessageView(text: msg, failed: session.state == .error)
            }
            if session.host.canPrefillPrompt, session.activePending == nil,
               [.done, .idle, .error].contains(session.state) {
                NextPromptBar(model: model, session: session)
            }
            StepsList(session: session)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        // Не выше экрана: при огромном вводе (например, длинный скрипт) кнопки уезжали за нижний край.
        // Сжимаются прокручиваемые части — подробности запроса и лента шагов.
        .frame(maxHeight: HUDMetrics.maxCardHeight, alignment: .top)
        .glass(14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 30, animated: false,
                       kind: session.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProjectDot(cwd: session.cwd)
                    Text(session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(session.activePending?.kind.isPlan == true ? "Ждёт одобрения" : session.state.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(session.state.tint.opacity(0.16)))
                        .foregroundStyle(session.state.tint)
                        .fixedSize()
                    if !session.title.isEmpty {
                        Text(session.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(subtitle(now: ctx.date)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.up.forward.app", help: session.host.openTitle) { model.open(session.id) }
                IconButton(symbol: "map", help: "Карта агентов: все сессии и что они делают") { model.openMap() }
                IconButton(symbol: "eye.slash", help: "Скрыть") { model.hide(session.id) }
                IconButton(symbol: "xmark", help: "Закрыть окошко") { model.select(nil) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func subtitle(now: Date) -> String {
        var parts = [session.kind.displayName, session.host.label]
        if let tty = session.host.tty { parts.append((tty as NSString).lastPathComponent) }
        parts.append(Fmt.elapsed(from: session.startedAt, to: session.finishedAt ?? now))
        if let m = session.model { parts.append(m.replacingOccurrences(of: "claude-", with: "")) }
        return parts.joined(separator: " · ")
    }
}

/// Следующая задача для сессии в VS Code: текст попадёт в поле ввода её чата, отправляешь сам.
struct NextPromptBar: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Следующая задача…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.forward.app") }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Открыть сессию в VS Code с этим текстом в поле ввода (отправишь сам)")
            }
            if !model.settings.quickPrompts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.settings.quickPrompts, id: \.self) { p in
                            Button { model.prefillPrompt(session.id, p) } label: {
                                Text(p).font(.system(size: 11)).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("Вставить «\(p)» в поле ввода сессии")
                        }
                    }
                }
                .frame(height: 22)
            }
        }
        .controlSize(.small)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.prefillPrompt(session.id, t)
        text = ""
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Notice: View {
    let icon: String
    let color: Color
    let text: String
    var actions: [(String, () -> Void)] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                Button(a.0, action: a.1).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
    }
}

struct LastMessageView: View {
    let text: String
    let failed: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                ScrollView {
                    Text(verbatim: text.count > 6000 ? String(text.prefix(6000)) + "…" : text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                Text(verbatim: String(text.prefix(600)))
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if text.count > 160 || text.filter({ $0 == "\n" }).count > 2 {
                Button(expanded ? "Свернуть" : "Показать целиком") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill((failed ? Color.red : Color.green).opacity(0.08)))
    }
}

// MARK: - Лента шагов

struct StepsList: View {
    let session: AgentSession

    var body: some View {
        let steps = Array(session.steps.suffix(60))
        if steps.isEmpty {
            Text(session.state == .idle || session.state == .starting ? "Ждёт задачу" : "Шагов пока нет")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(steps) { st in
                            StepRow(step: st).id(st.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: min(CGFloat(steps.count) * 21 + 6, 230))
                .onAppear { proxy.scrollTo(steps.last?.id, anchor: .bottom) }
                .onChange(of: steps.last?.id) { _, id in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Fmt.icon(for: step.toolName))
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(step.summary)
                .font(.system(size: 11, design: step.toolName == "Bash" ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(step.status == .failed ? Color.red : Color.primary)
            Spacer(minLength: 4)
            if let ms = step.durationMs {
                Text(Fmt.duration(ms)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            statusIcon
        }
        .padding(.leading, step.agentId != nil ? 16 : 0)
        .frame(height: 18)
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .ok: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).frame(width: 12)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red).frame(width: 12)
        }
    }
}

enum Fmt {
    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) мс" }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1f с", s) }
        return "\(Int(s) / 60) мин \(Int(s) % 60) с"
    }

    static func elapsed(from a: Date, to b: Date) -> String {
        let s = max(0, Int(b.timeIntervalSince(a)))
        if s < 60 { return "только что" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \(s % 3600 / 60) мин"
    }

    static func icon(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent", "Subagent": return "person.2"
        case "TodoWrite": return "checklist"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "list.bullet.clipboard"
        case "Skill": return "sparkles"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
