import AgentHUDCore
import AppKit
import SwiftUI

/// Действия панели — их выполняет StatusMenu.
struct PanelActions {
    var openSession: (String) -> Void = { _ in }
    var focusSession: (String) -> Void = { _ in }
    var connect: (AgentKind) -> Void = { _ in }
    var disconnect: (AgentKind) -> Void = { _ in }
    var setTimeout: (Int) -> Void = { _ in }
    var setLoginItem: (Bool) -> Void = { _ in }
    var setHUDDisplay: (String) -> Void = { _ in }
    var setHUDCorner: (HUDCorner) -> Void = { _ in }
    var resetPosition: () -> Void = {}
    var resetMenuPosition: () -> Void = {}
    var finishMenuDrag: (() -> Void)?
    var openLog: () -> Void = {}
    var quit: () -> Void = {}
}

/// Панель в строке меню: сессии, агенты, вид, поведение. Стиль — дизайн-система Владилена.
struct ControlPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var actions = PanelActions()
    /// Статусы, которые не публикуются сами (файлы конфигов, автозапуск) — читаются при открытии.
    var installed: [AgentKind: Bool] = [:]
    var loginItem = false
    @State var tab = 0
    @State private var displays = NSScreen.screens

    init(model: AppModel, settings: Settings, actions: PanelActions = PanelActions(),
         installed: [AgentKind: Bool] = [:], loginItem: Bool = false, tab: Int = 0) {
        self.model = model
        self.settings = settings
        self.actions = actions
        self.installed = installed
        self.loginItem = loginItem
        _tab = State(initialValue: tab)
    }

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            BrandTabs(titles: ["Сессии", "Настройки"], selection: $tab,
                      badges: [0: model.visibleSessions.filter { $0.state.needsUser }.count])
            if tab == 0 {
                sessionsSection
                agentsSection
            } else {
                lookSection
                placementSection
                behaviorSection
            }
            footer
        }
        .padding(16)
        .frame(width: Self.width)
        .background(Brand.bg)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = NSScreen.screens
        }
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
            if let finishDrag = actions.finishMenuDrag {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Brand.inkSubtle)
                    .frame(width: 30, height: 30)
                    .overlay { MenuDragHandle(finishDrag: finishDrag) }
                    .help("Перетащить окно")
                    .accessibilityLabel("Перетащить окно")
            }
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
                    Text("Пока тихо. Запусти агента в терминале или в приложении — он появится здесь.")
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
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 2, title: "Агенты")
            Card {
                ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { i, kind in
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
                    BrandToggleRow(title: "Прятать, когда никто не ждёт",
                                   hint: "HUD появится только при запросе или вопросе", isOn: $settings.hideWhenNothingWaits)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 2, title: "Расположение")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Экран HUD", selection: Binding(get: { settings.hudDisplay }, set: actions.setHUDDisplay)) {
                        Text("Основной").tag("")
                        ForEach(displays, id: \.placementID) { screen in
                            Text(displayTitle(screen)).tag(screen.placementID)
                        }
                        if !settings.hudDisplay.isEmpty, !displays.contains(where: { $0.placementID == settings.hudDisplay }) {
                            Text("Отключённый экран").tag(settings.hudDisplay)
                        }
                    }
                    Picker("Положение HUD", selection: Binding(get: { settings.hudCorner }, set: actions.setHUDCorner)) {
                        ForEach(HUDCorner.allCases) { corner in Text(corner.title).tag(corner) }
                    }
                    Button("Вернуть окно под значок", action: actions.resetMenuPosition)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func displayTitle(_ screen: NSScreen) -> String {
        guard displays.filter({ $0.localizedName == screen.localizedName }).count > 1,
              let index = displays.firstIndex(of: screen) else { return screen.localizedName }
        return "\(screen.localizedName) (\(index + 1))"
    }

    // MARK: 04 Поведение

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 3, title: "Поведение")
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    BrandToggleRow(title: "Открывать окошко при запросе", isOn: $settings.openCardOnRequest)
                        .padding(.top, 6)
                    BrandToggleRow(title: "Уведомления, если HUD скрыт", isOn: $settings.notifications)
                    BrandToggleRow(title: "Запускать при входе в систему",
                                   isOn: Binding(get: { loginItem }, set: { actions.setLoginItem($0) }))
                    Divider().overlay(Brand.line).padding(.vertical, 4)
                    FieldLabel(title: "Время на ответ", hint: "потом — в агента")
                    BrandSegmented(options: [(120, "2 МИН"), (300, "5 МИН"), (600, "10 МИН"), (1800, "30 МИН")],
                                   selection: Binding(get: { settings.hookTimeout }, set: { actions.setTimeout($0) }))
                    FieldLabel(title: "Прятать готовые сессии").padding(.top, 8)
                    BrandSegmented(options: [(0, "НЕТ"), (5, "5 МИН"), (30, "30 МИН"), (120, "2 Ч")],
                                   selection: $settings.autoHideDoneMinutes)
                        .padding(.bottom, 12)
                }
            }
        }
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

/// The mouse stays in screen coordinates while the window moves underneath the drag handle.
private struct MenuDragHandle: NSViewRepresentable {
    let finishDrag: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.finishDrag = finishDrag }

    final class DragView: NSView {
        var finishDrag: () -> Void = {}
        private var startMouse = CGPoint.zero
        private var startOrigin = CGPoint.zero
        private var didDrag = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startMouse = NSEvent.mouseLocation
            startOrigin = window.frame.origin
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            let mouse = NSEvent.mouseLocation
            didDrag = true
            window?.setFrameOrigin(CGPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                           y: startOrigin.y + mouse.y - startMouse.y))
        }

        override func mouseUp(with event: NSEvent) {
            if didDrag { finishDrag() }
            didDrag = false
        }
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
                Text(session.projectName).font(Brand.body(13, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
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
                .help(session.host.isDesktopApp ? "Открыть в приложении" : "Открыть в терминале")
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
        let host = session.host.isDesktopApp ? "приложение" : session.host.label
        var parts = ["\(session.kind.displayName) · \(host)"]
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
        case .claude: return "Терминал и приложение Claude"
        case .codex: return "Терминал и приложение · хуки: /hooks"
        }
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
