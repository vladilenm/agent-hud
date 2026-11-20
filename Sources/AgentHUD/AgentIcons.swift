import AgentHUDCore
import AppKit
import SwiftUI

/// Иконки агентов: берём у системы иконки установленных приложений Claude и Codex.
/// Сами логотипы не рисуем и в приложение не кладём.
@MainActor
enum AgentIcons {
    private static var cache: [AgentKind: NSImage?] = [:]

    static func bundleId(for kind: AgentKind) -> String {
        switch kind {
        case .claude: return HostInfo.claudeDesktop
        case .codex: return HostInfo.codexDesktop
        }
    }

    static func icon(for kind: AgentKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        var img: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: kind)) {
            img = NSWorkspace.shared.icon(forFile: url.path)
            img?.size = NSSize(width: 128, height: 128)
        }
        cache[kind] = img
        return img
    }
}

/// Персонаж в стиле «Логотипы»: иконка агента. Состояние — бейдж, движение и насыщенность.
struct LogoAvatar: View {
    let kind: AgentKind?
    let state: AgentState
    let size: CGFloat

    var body: some View {
        Group {
            if let kind, let img = AgentIcons.icon(for: kind) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.02)
            } else {
                // Приложение агента не установлено (например, только CLI) — нейтральная плашка с символом.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Brand.accentSoft)
                    Image(systemName: kind == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(Brand.accentText)
                }
                .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .saturation(saturation)
        .opacity(opacity)
    }

    private var saturation: Double {
        switch state {
        case .idle, .ended: return 0.1
        case .expired: return 0.45
        default: return 1
        }
    }

    private var opacity: Double {
        switch state {
        case .idle, .ended: return 0.6
        default: return 1
        }
    }
}

/// Несколько иконок агентов внахлёст — для превью стиля и шапки панели.
/// Только агенты, чьи приложения установлены (без Codex — одна иконка Claude).
struct AgentIconStack: View {
    var size: CGFloat = 30
    var state: AgentState = .working

    var body: some View {
        let kinds = AgentKind.allCases.filter { AgentIcons.icon(for: $0) != nil }
        HStack(spacing: -size * 0.35) {
            ForEach(kinds.isEmpty ? [AgentKind.claude] : kinds, id: \.self) { k in
                LogoAvatar(kind: k, state: state, size: size)
            }
        }
    }
}
