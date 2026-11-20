import AppKit
import CoreText
import SwiftUI

/// Токены интерфейса. Палитра — по цветам Yora (основной синий #016FEE / #338EF7, нейтральные «zinc»),
/// цвета — парами для светлой и тёмной темы. Шрифты — Golos Text и IBM Plex Mono (OFL, лежат в Resources/Fonts).
enum Brand {
    // MARK: Цвета

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let bg = dyn(0xF4F4F5, 0x18181B)
    static let surface = dyn(0xFFFFFF, 0x1E1E23)
    static let surfaceSunken = dyn(0xECECEF, 0x141417)
    static let line = dyn(0xE4E4E7, 0x34343A)
    static let lineStrong = dyn(0xA1A1AA, 0x71717A)
    static let ink = dyn(0x10181C, 0xECEDEE)
    static let inkMuted = dyn(0x52525B, 0xC4C4CC)
    static let inkSubtle = dyn(0x71717A, 0xA1A1AA)
    static let accent = dyn(0x016FEE, 0x338EF7)
    static let accentHover = dyn(0x005BC4, 0x66AAF9)
    static let onAccent = dyn(0xFFFFFF, 0xFFFFFF)
    static let accentSoft = dyn(0xE6F1FE, 0x0D2847)
    static let accentText = dyn(0x005BC4, 0x66AAF9)
    static let success = dyn(0x13703C, 0x41C97C)
    static let successSoft = dyn(0xE3F8EC, 0x12281C)
    static let warning = dyn(0x8F5A00, 0xF5A524)
    static let warningSoft = dyn(0xFEF3DC, 0x2E2410)
    static let danger = dyn(0xC20E4D, 0xF54180)
    static let dangerSoft = dyn(0xFEE7EF, 0x33111D)

    // MARK: Шрифты

    /// Golos Text — интерфейс и текст.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "GolosText-Regular_Medium"
        case .semibold, .bold, .heavy, .black: name = "GolosText-Regular_SemiBold"
        default: name = "GolosText-Regular"
        }
        return FontLoader.available ? .custom(name, size: size) : .system(size: size, weight: weight)
    }

    /// IBM Plex Mono — метки, цифры, всё измеримое.
    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        FontLoader.available ? .custom(medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular", size: size)
                             : .system(size: size, weight: medium ? .medium : .regular, design: .monospaced)
    }

    /// Заголовки — Golos Text SemiBold.
    static func display(_ size: CGFloat) -> Font {
        FontLoader.available ? .custom("GolosText-Regular_SemiBold", size: size) : .system(size: size, weight: .semibold)
    }

    // MARK: Размеры (сетка 4px)

    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 6
    static let radiusLg: CGFloat = 10
    static let radiusXl: CGFloat = 16
}

/// Регистрирует шрифты приложения в процессе (без установки в систему).
enum FontLoader {
    private(set) static var available = false

    static func register() {
        guard !available else { return }
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        // Запуск из исходников (swift run): Resources/Fonts в корне репозитория.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("Resources/Fonts"))
        guard let dir = dirs.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("GolosText-Variable.ttf").path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let fonts = files.filter { $0.pathExtension == "ttf" } as CFArray
        CTFontManagerRegisterFontURLs(fonts, .process, true, nil)
        available = NSFont(name: "GolosText-Regular", size: 12) != nil && NSFont(name: "IBMPlexMono-Medium", size: 12) != nil
    }
}

// MARK: - Мелкие компоненты в стиле системы

/// Метка раздела: «01 / СЕССИИ».
struct SectionLabel: View {
    let index: Int
    let title: String

    var body: some View {
        Text(String(format: "%02d / ", index) + title.uppercased())
            .font(Brand.mono(10.5, medium: true))
            .tracking(0.63)
            .foregroundStyle(Brand.inkSubtle)
    }
}

/// Тег: моноширинный капс, скругление 4px.
struct BrandTag: View {
    enum Tone { case neutral, accent, success, warning, danger }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        let (fg, bg): (Color, Color) = {
            switch tone {
            case .neutral: return (Brand.inkMuted, Brand.surfaceSunken)
            case .accent: return (Brand.accentText, Brand.accentSoft)
            case .success: return (Brand.success, Brand.successSoft)
            case .warning: return (Brand.warning, Brand.warningSoft)
            case .danger: return (Brand.danger, Brand.dangerSoft)
            }
        }()
        Text(text.uppercased())
            .font(Brand.mono(9.5, medium: true))
            .tracking(0.57)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: Brand.radiusSm).fill(bg))
    }
}

/// Сегментированный переключатель: моноширинные подписи, выбранный — мягкий акцент.
struct BrandSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(Brand.mono(11, medium: on))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundStyle(on ? Brand.accentText : Brand.inkMuted)
                        .background(RoundedRectangle(cornerRadius: Brand.radiusSm).fill(on ? Brand.accentSoft : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(Brand.surfaceSunken))
    }
}

/// Строка с переключателем.
struct BrandToggleRow: View {
    let title: String
    var hint: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Brand.body(13)).foregroundStyle(Brand.ink)
                if let hint {
                    Text(hint).font(Brand.body(11)).foregroundStyle(Brand.inkSubtle).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(BrandSwitch()).labelsHidden()
        }
        .padding(.vertical, 5)
    }
}

/// Переключатель в стиле системы: трек акцентом во включённом состоянии, независимо от фокуса окна.
struct BrandSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button { withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.2)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Brand.accent : Brand.surfaceSunken)
                Capsule().strokeBorder(on ? Color.clear : Brand.lineStrong.opacity(0.6), lineWidth: 1)
                Circle().fill(on ? Brand.onAccent : Brand.surface)
                    .overlay(Circle().strokeBorder(on ? Color.clear : Brand.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "включено" : "выключено")
    }
}

/// Вкладки с подчёркиванием 2px.
struct BrandTabs: View {
    let titles: [String]
    @Binding var selection: Int
    var badges: [Int: Int] = [:]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                let on = i == selection
                Button { selection = i } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Text(t).font(Brand.body(13, on ? .medium : .regular))
                                .foregroundStyle(on ? Brand.ink : Brand.inkMuted)
                            if let n = badges[i], n > 0 {
                                Text("\(n)").font(Brand.mono(10, medium: true))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .foregroundStyle(Brand.warning)
                                    .background(RoundedRectangle(cornerRadius: Brand.radiusSm).fill(Brand.warningSoft))
                            }
                        }
                        Rectangle().fill(on ? Brand.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

/// Текстовая кнопка с иконкой (ghost).
struct GhostButton: View {
    let title: String
    let symbol: String
    var tone: Color = Brand.inkMuted
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .regular))
                Text(title).font(Brand.body(12, .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(hover ? Brand.ink : tone)
            .background(RoundedRectangle(cornerRadius: Brand.radiusMd).fill(hover ? Brand.surfaceSunken : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
