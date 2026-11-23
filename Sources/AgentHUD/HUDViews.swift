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

struct HUDRootView: View {
    @ObservedObject var model: AppModel
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        let corner = model.settings.hudCorner
        VStack(alignment: corner.isLeft ? .leading : .trailing, spacing: 8) {
            if !corner.isBottom { AvatarRow(model: model) }
            if let key = model.selectedKey, let s = model.store.session(key) {
                SessionCard(model: model, session: s)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: cardAnchor(corner)).combined(with: .opacity),
                                            removal: .opacity))
            }
            if corner.isBottom { AvatarRow(model: model) }
        }
        .padding(14)   // место под тень
        .fixedSize()
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.selectedKey)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.visibleSessions.map(\.id))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
    private func cardAnchor(_ corner: HUDCorner) -> UnitPoint {
        UnitPoint(x: corner.isLeft ? 0 : 1, y: corner.isBottom ? 1 : 0)
    }

}

// MARK: - Ряд персонажей

struct AvatarRow: View {
    @ObservedObject var model: AppModel
    static let maxShown = 6

    var body: some View {
        let sessions = model.visibleSessions
        // Сначала те, кто ждёт пользователя.
        let sorted = sessions.sorted { a, b in
            let pa = a.state.needsUser ? 0 : 1, pb = b.state.needsUser ? 0 : 1
            return pa != pb ? pa < pb : a.startedAt < b.startedAt
        }
        let shown = Array(sorted.prefix(Self.maxShown))
        let rest = sorted.count - shown.count

        HStack(spacing: 6) {
            ForEach(shown) { s in
                AvatarButton(model: model, session: s)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
            if rest > 0 {
                Menu {
                    ForEach(sorted.dropFirst(Self.maxShown)) { s in
                        Button("\(s.projectName) — \(s.state.title)") { model.select(s.id) }
                    }
                } label: {
                    Text("+\(rest)").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glass(16)
    }
}

struct AvatarButton: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var hover = false

    var body: some View {
        let selected = model.selectedKey == session.id
        Button { model.select(session.id) } label: {
            AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 34,
                       animated: model.settings.animations, kind: session.kind)
                .padding(3)
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
            Button(session.host.isDesktopApp ? "Открыть в приложении" : "Открыть в терминале") { model.open(session.id) }
            Button("Скрыть") { model.hide(session.id) }
        }
    }

    private var tooltip: String {
        var parts = ["\(session.projectName) — \(session.state.title)"]
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
                        QuestionView(model: model, desktop: session.host.isDesktopApp, request: p, questions: qs)
                    }
                }
                .id(p.id)
            } else if let p = session.expiredPending {
                ExpiredView(model: model, session: session, request: p)
            } else if session.state.needsUser {
                Notice(icon: session.host.isDesktopApp ? "macwindow" : "terminal", color: .orange,
                       text: (session.host.isDesktopApp ? "Агент ждёт ответа в приложении" : "Агент ждёт ответа в терминале")
                           + (session.waitingNote.map { ": «\($0.count > 160 ? String($0.prefix(159)) + "…" : $0)»" } ?? "."),
                       actions: [("Открыть", { model.open(session.id) })])
            }
            if let msg = session.lastMessage, session.state == .done || session.state == .error {
                LastMessageView(text: msg, failed: session.state == .error)
            }
            StepsList(session: session)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .glass(14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 30, animated: false,
                       kind: session.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.state.title)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(session.state.tint.opacity(0.16)))
                        .foregroundStyle(session.state.tint)
                }
                if !session.title.isEmpty {
                    Text(session.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(subtitle(now: ctx.date)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.up.forward.app", help: session.host.isDesktopApp ? "Открыть сессию в приложении" : "Открыть в терминале") { model.open(session.id) }
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
            Text(text)
                .font(.system(size: 12))
                .lineLimit(expanded ? 30 : 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
        case "Skill": return "sparkles"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
