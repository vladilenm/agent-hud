import AgentHUDCore
import SwiftUI

/// Действия панели — их выполняет StatusMenu (закрывает поповер, показывает диалоги).
struct PanelActions {
    var openSession: (String) -> Void = { _ in }
    var focusSession: (String) -> Void = { _ in }
    var connect: (AgentKind) -> Void = { _ in }
    var disconnect: (AgentKind) -> Void = { _ in }
    var setTimeout: (Int) -> Void = { _ in }
    var setLoginItem: (Bool) -> Void = { _ in }
    var resetPosition: () -> Void = {}
    var openLog: () -> Void = {}
    var openMap: () -> Void = {}
    var openSummary: () -> Void = {}
    var quit: () -> Void = {}
}

/// Панель в строке меню: сессии, агенты, вид, поведение. Палитра — Yora (Brand.swift).
struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var actions = PanelActions()
    /// Статусы, которые не публикуются сами (файлы конфигов, автозапуск) — читаются при открытии.
    var installed: [AgentKind: Bool] = [:]
    /// Какие агенты есть на машине: остальных (например, Codex без Codex) в панели не показываем.
    var present: [AgentKind: Bool] = [:]
    var loginItem = false
    @State var tab = 0
    @State private var quickText = ""

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            BrandTabs(titles: ["Сессии", "Настройки"], selection: $tab,
                      badges: [0: model.visibleSessions.filter { $0.state.needsUser }.count])
            if tab == 0 {
                HStack(spacing: 8) {
                    PanelButton(title: "Карта агентов", symbol: "map", action: actions.openMap)
                    PanelButton(title: "Сводка за день", symbol: "list.bullet.rectangle", action: actions.openSummary)
                }
                sessionsSection
                agentsSection
            } else {
                lookSection
                behaviorSection
            }
            footer
        }
        .padding(16)
        .frame(width: Self.width)
        .background(Brand.bg)
    }

    // MARK: Шапка

    private var header: some View {
        let sessions = model.visibleSessions
        let waiting = sessions.filter { $0.state.needsUser }.count
        return HStack(spacing: 12) {
            if settings.avatarStyle == .logo {
                AgentIconStack(size: 34)
            } else {
                AvatarView(seed: 0x9E3779B97F4A7C15, state: waiting > 0 ? .waitingAnswer : .working,
                           style: settings.avatarStyle, size: 36, animated: settings.animations)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentHUD").font(Brand.display(24)).foregroundStyle(Brand.ink)
                Text(summary(total: sessions.count, waiting: waiting))
                    .font(Brand.mono(10.5, medium: true)).tracking(0.63)
                    .foregroundStyle(waiting > 0 ? Brand.warning : Brand.inkSubtle)
            }
            Spacer()
        }
    }

    private func summary(total: Int, waiting: Int) -> String {
        if total == 0 { return "НЕТ АКТИВНЫХ СЕССИЙ" }
        let s = "\(total) \(plural(total, "СЕССИЯ", "СЕССИИ", "СЕССИЙ"))"
        return waiting > 0 ? s + " · \(waiting) \(plural(waiting, "ЖДЁТ", "ЖДУТ", "ЖДУТ"))" : s
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    // MARK: 01 Сессии

    private var sessionsSection: some View {
        let sessions = model.visibleSessions.sorted { a, b in
            let pa = a.state.needsUser ? 0 : 1, pb = b.state.needsUser ? 0 : 1
            return pa != pb ? pa < pb : a.lastEventAt > b.lastEventAt
        }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 1, title: "Сессии")
            Card {
                if sessions.isEmpty {
                    Text("Пока тихо. Запусти агента в VS Code, терминале или приложении — он появится здесь.")
                        .font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12)
                } else {
                    let rows = VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                            if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                            SessionRow(session: s, style: settings.avatarStyle,
                                       open: { actions.openSession(s.id) }, focus: { actions.focusSession(s.id) })
                        }
                    }
                    if sessions.count > 5 {
                        ScrollView { rows }.frame(height: 5 * 49)
                    } else {
                        rows
                    }
                }
            }
        }
    }

    // MARK: 02 Агенты

    private var agentsSection: some View {
        // Агент без своей папки настроек на машине не установлен — не предлагаем подключать.
        let kinds = AgentKind.allCases.filter { present[$0] ?? true || installed[$0] ?? false }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 2, title: "Агенты")
            Card {
                ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                    if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                    AgentRow(kind: kind, installed: installed[kind] ?? false,
                             toggle: { on in on ? actions.connect(kind) : actions.disconnect(kind) })
                }
            }
        }
    }

    // MARK: 03 Вид

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 1, title: "Вид")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(AvatarStyle.allCases) { style in
                            StyleTile(style: style, selected: settings.avatarStyle == style) { settings.avatarStyle = style }
                        }
                    }
                    .padding(.top, 12)
                    Divider().overlay(Brand.line)
                    BrandToggleRow(title: "Показывать HUD", isOn: $settings.hudVisible)
                    BrandToggleRow(title: "Анимация персонажей", isOn: $settings.animations)
                    BrandToggleRow(title: "Проект под иконкой", hint: "Короткое имя проекта, чтобы различать сессии",
                                   isOn: $settings.projectLabels)
                    BrandToggleRow(title: "Прятать, когда никто не ждёт",
                                   hint: "HUD появится только при запросе или вопросе", isOn: $settings.hideWhenNothingWaits)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: 04 Поведение

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 2, title: "Поведение")
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    BrandToggleRow(title: "Открывать окошко при запросе", isOn: $settings.openCardOnRequest)
                        .padding(.top, 6)
                    BrandToggleRow(title: "Уведомления, если HUD скрыт", isOn: $settings.notifications)
                    BrandToggleRow(title: "Запускать при входе в систему",
                                   isOn: Binding(get: { loginItem }, set: { actions.setLoginItem($0) }))
                    BrandToggleRow(title: "Журнал активности", hint: "Для сводки за день; хранится только на этом Mac",
                                   isOn: $settings.activityLog)
                    Divider().overlay(Brand.line).padding(.vertical, 4)
                    FieldLabel(title: "Время на ответ", hint: "потом — в агента")
                    BrandSegmented(options: [(120, "2 МИН"), (300, "5 МИН"), (600, "10 МИН"), (1800, "30 МИН")],
                                   selection: Binding(get: { settings.hookTimeout }, set: { actions.setTimeout($0) }))
                    FieldLabel(title: "Прятать готовые сессии").padding(.top, 8)
                    BrandSegmented(options: [(0, "НЕТ"), (5, "5 МИН"), (30, "30 МИН"), (120, "2 Ч")],
                                   selection: $settings.autoHideDoneMinutes)
                    FieldLabel(title: "Быстрые промпты", hint: "для VS Code, через ;").padding(.top, 8)
                    TextField("Продолжай; Прогони тесты", text: $quickText)
                        .textFieldStyle(.roundedBorder)
                        .font(Brand.body(12))
                        .onAppear { quickText = settings.quickPrompts.joined(separator: "; ") }
                        .onSubmit(commitQuickPrompts)
                        .onDisappear(perform: commitQuickPrompts)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func commitQuickPrompts() {
        let list = quickText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if list != settings.quickPrompts { settings.quickPrompts = list }
    }

    // MARK: Подвал

    private var footer: some View {
        HStack(spacing: 2) {
            GhostButton(title: "Журнал", symbol: "doc.text", action: actions.openLog)
            GhostButton(title: "HUD в угол", symbol: "arrow.up.right.square", action: actions.resetPosition)
            Spacer()
            GhostButton(title: "Выйти", symbol: "power", action: actions.quit)
        }
        .padding(.horizontal, -10)
    }
}

// MARK: - Части панели

/// Карточка: поверхность, линия, скругление 10px.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))
    }
}

struct FieldLabel: View {
    let title: String
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Brand.body(13)).foregroundStyle(Brand.ink)
            Spacer()
            if let hint { Text(hint).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle) }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let style: AvatarStyle
    let open: () -> Void
    let focus: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(seed: session.avatarSeed, state: session.state, style: style, size: 28, animated: false, kind: session.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ProjectDot(cwd: session.cwd, size: 7)
                    Text(session.projectName).font(Brand.body(13, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                }
                Text(detail).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if hover {
                Button(action: focus) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.inkMuted)
                .help(session.host.openTitle)
            }
            BrandTag(text: session.state.shortTitle, tone: session.state.tone)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(hover ? Brand.surfaceSunken : .clear))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }

    private var detail: String {
        var parts = ["\(session.kind.displayName) · \(session.host.label)"]
        if !session.title.isEmpty { parts.append(session.title) }
        return parts.joined(separator: " — ")
    }
}

struct AgentRow: View {
    let kind: AgentKind
    let installed: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LogoAvatar(kind: kind, state: installed ? .working : .idle, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(Brand.body(13, .medium)).foregroundStyle(Brand.ink)
                Text(hint).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { installed }, set: toggle)).toggleStyle(BrandSwitch()).labelsHidden()
        }
        .padding(.vertical, 10)
    }

    private var hint: String {
        guard installed else { return "Не подключён" }
        switch kind {
        case .claude: return "VS Code, терминал и приложение Claude"
        case .codex: return "Терминал и приложение · хуки: /hooks"
        }
    }
}

/// Кнопка-плитка панели: «Карта агентов», «Сводка за день».
struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(Brand.body(12, .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundStyle(Brand.accentText)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(hover ? Brand.accentSoft : Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusMd).strokeBorder(Brand.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct StyleTile: View {
    let style: AvatarStyle
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if style == .logo {
                    AgentIconStack(size: 30).frame(height: 34)
                } else {
                    AvatarView(seed: 0x51ED2701F3A5C7B9, state: .working, style: style, size: 34, animated: false)
                }
                Text(style.title).font(Brand.body(11, selected ? .medium : .regular))
                    .foregroundStyle(selected ? Brand.accentText : Brand.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd)
                .fill(selected ? Brand.accentSoft : (hover ? Brand.surfaceSunken : .clear)))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusMd)
                .strokeBorder(selected ? Brand.accent : Brand.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension AgentState {
    var shortTitle: String {
        switch self {
        case .starting: return "старт"
        case .working: return "работает"
        case .waitingPermission, .waitingAnswer: return "ждёт тебя"
        case .expired: return "просрочено"
        case .idle: return "ждёт задачу"
        case .done: return "готово"
        case .error: return "ошибка"
        case .ended: return "завершена"
        }
    }

    var tone: BrandTag.Tone {
        switch self {
        case .waitingPermission, .waitingAnswer, .expired: return .warning
        case .done: return .success
        case .error: return .danger
        case .working, .starting: return .accent
        case .idle, .ended: return .neutral
        }
    }
}
