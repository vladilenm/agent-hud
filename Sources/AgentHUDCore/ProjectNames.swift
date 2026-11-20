import Foundation

/// Имена проектов для HUD: полное имя и короткая метка под иконкой агента.
/// Когда все сессии — один агент (иконки одинаковые), отличать их приходится по проекту.
public enum ProjectNames {
    /// Безликие имена папок: для них показываем и родительскую папку («hrm/front»).
    static let generic: Set<String> = [
        "front", "frontend", "back", "backend", "app", "apps", "web", "client", "server", "src",
        "mobile", "api", "ui", "packages", "main", "admin", "site",
    ]

    public static func displayName(cwd: String) -> String {
        // Пустой путь URL превратил бы в текущую папку процесса.
        guard !cwd.isEmpty else { return "" }
        let url = URL(fileURLWithPath: cwd)
        let base = url.lastPathComponent
        guard !base.isEmpty, base != "/" else { return cwd }
        if generic.contains(base.lowercased()) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" { return parent + "/" + base }
        }
        return base
    }

    static func tokens(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Короткие метки для набора проектов. Первое слово, общее для нескольких проектов («acme-mobile-app»,
    /// «acme-web-client»), у них отбрасывается → «mobile», «web»; совпадения уточняются следующим словом
    /// («hrm-front», «hrm-v2»). Проект без «родни» сохраняет полное имя: «agent-hub», а не «agent».
    /// Набор лучше передавать устойчивый (все известные проекты), тогда метки не меняются,
    /// когда сессии приходят и уходят.
    public static func shortLabels(for cwds: [String], maxLength: Int = 10) -> [String: String] {
        let unique = Array(Set(cwds.filter { !$0.isEmpty })).sorted()
        var names: [String: [String]] = [:]
        for c in unique {
            let t = tokens(displayName(cwd: c))
            names[c] = t.isEmpty ? [displayName(cwd: c).lowercased()] : t
        }
        var firstCount: [String: Int] = [:]
        for t in names.values where t.count > 1 { firstCount[t[0], default: 0] += 1 }
        var parts: [String: [String]] = [:]
        var taken: [String: Int] = [:]
        for c in unique {
            let t = names[c]!
            if t.count > 1, firstCount[t[0], default: 0] >= 2 {
                parts[c] = Array(t.dropFirst())
                taken[c] = 1
            } else {
                parts[c] = t
                taken[c] = t.count
            }
        }
        func label(_ c: String) -> String { parts[c]!.prefix(taken[c]!).joined(separator: "-") }
        // Уточняем, пока есть совпадения и есть чем уточнять. Совпавшие уточняются одновременно,
        // иначе первая метка уйдёт вперёд, а вторая останется короткой.
        for _ in 0..<4 {
            var current: [String: String] = [:]
            for c in unique { current[c] = label(c) }
            let clashing = unique.filter { c in
                unique.contains { $0 != c && current[$0] == current[c] } && taken[c]! < parts[c]!.count
            }
            if clashing.isEmpty { break }
            for c in clashing { taken[c]! += 1 }
        }
        return Dictionary(uniqueKeysWithValues: unique.map { ($0, clip(label($0), maxLength)) })
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// Стабильный оттенок цвета проекта (0…1) — один и тот же в HUD, панели и на карте.
    public static func hue(cwd: String) -> Double {
        Double(stableHash("project:" + cwd) % 360) / 360
    }
}
