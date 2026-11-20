import AgentHUDCore
import SwiftUI

/// Подписи и иконки в зависимости от того, где идёт сессия: терминал, приложение или VS Code.
extension HostInfo {
    /// «в терминале», «в приложении», «в VS Code» — для фраз «агент ждёт ответа …».
    var placeIn: String {
        switch place {
        case .terminal: return isEditorTerminal ? "в терминале VS Code" : "в терминале"
        case .desktopApp: return "в приложении"
        case .editor: return "в VS Code"
        }
    }

    /// «терминал», «приложение», «VS Code» — для «ушёл в …».
    var placeTo: String {
        switch place {
        case .terminal: return "терминал"
        case .desktopApp: return "приложение"
        case .editor: return "VS Code"
        }
    }

    /// Кнопка «ответить там, где работает агент».
    var passthroughTitle: String {
        switch place {
        case .terminal: return "В терминале"
        case .desktopApp: return "В приложении"
        case .editor: return "В VS Code"
        }
    }

    var placeSymbol: String {
        switch place {
        case .terminal: return "terminal"
        case .desktopApp: return "macwindow"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var openTitle: String {
        switch place {
        case .terminal: return isEditorTerminal ? "Открыть в VS Code" : "Открыть в терминале"
        case .desktopApp: return "Открыть в приложении"
        case .editor: return "Открыть в VS Code"
        }
    }

    /// Можно ли отправить следующий промпт прямо из HUD (через ссылку расширения VS Code).
    var canPrefillPrompt: Bool { place == .editor }
}

/// Цвет проекта: один и тот же в HUD, панели и на карте агентов.
enum ProjectColor {
    static func color(_ cwd: String, saturation: Double = 0.62, brightness: Double = 0.86) -> Color {
        Color(hue: ProjectNames.hue(cwd: cwd), saturation: saturation, brightness: brightness)
    }
}

/// Метка проекта под иконкой агента: цветная капсула с коротким именем.
struct ProjectChip: View {
    let cwd: String
    let label: String
    var size: CGFloat = 9

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(ProjectColor.color(cwd, saturation: 0.75, brightness: 0.45))
            .background(Capsule().fill(ProjectColor.color(cwd, saturation: 0.35, brightness: 1)))
            .overlay(Capsule().strokeBorder(ProjectColor.color(cwd).opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }
}

/// Цветная точка проекта.
struct ProjectDot: View {
    let cwd: String
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(ProjectColor.color(cwd)).frame(width: size, height: size)
    }
}
