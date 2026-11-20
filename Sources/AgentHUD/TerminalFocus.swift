import AgentHUDCore
import AppKit
import Foundation

/// Кнопка «Открыть»: поднять приложение, окно VS Code или вкладку терминала, где идёт сессия.
enum TerminalFocus {
    static func focus(_ session: AgentSession) {
        let host = session.host
        if host.isEditor {
            focusEditor(session, prompt: nil)
            return
        }
        if host.isEditorTerminal {
            // `claude` во встроенном терминале VS Code: вкладку терминала не выбрать, но окно проекта поднимем.
            openEditorWindow(folder: EditorWorkspaces.folder(containing: session.cwd) ?? session.cwd, bundleId: HostInfo.vscode) { _ in }
            return
        }
        if host.isDesktopApp {
            if let url = deepLink(session) {
                NSWorkspace.shared.open(url)
            } else if let id = host.appBundleId {
                activate(id)
            }
            return
        }
        focus(host)
    }

    /// Ссылка прямо в сессию десктопного приложения (форматы взяты из самих приложений).
    static func deepLink(_ session: AgentSession) -> URL? {
        switch session.host.appBundleId {
        case HostInfo.claudeDesktop:
            guard let id = session.host.hostSessionId else { return nil }
            var c = URLComponents(string: "claude://code/needs-input")!
            c.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "desktop_action")]
            return c.url
        case HostInfo.codexDesktop:
            let id = session.sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.sessionId
            return URL(string: "codex://threads/\(id)")
        default:
            return nil
        }
    }

    static func focus(_ host: HostInfo) {
        if let pane = host.herdrPaneId {
            focusHerdr(pane: pane, socket: host.herdrSocket)
            // Вкладка Terminal, в которой открыт клиент herdr.
            if !runAppleScript(terminalScript(match: "processes of t contains \"herdr\"")) { activate("com.apple.Terminal") }
            return
        }
        if let tty = host.tty {
            if host.termProgram == "iTerm.app", runAppleScript(iTermScript(tty: tty)) { return }
            if runAppleScript(terminalScript(match: "tty of t is \"\(tty)\"")) { return }
        }
        switch host.termProgram {
        case "iTerm.app": activate("com.googlecode.iterm2")
        default: activate("com.apple.Terminal")
        }
    }

    // MARK: - VS Code

    /// Сессия расширения Claude Code в VS Code: сначала окно с папкой проекта (VS Code сам поднимет уже
    /// открытое окно с этой папкой), потом ссылка в саму сессию. `prompt` — текст в поле ввода
    /// (расширение его только вставляет, отправляет пользователь сам).
    /// Ссылка: https://code.claude.com/docs/en/vs-code — `vscode://anthropic.claude-code/open?session=…&prompt=…`.
    static func focusEditor(_ session: AgentSession, prompt: String?) {
        let bundle = session.host.appBundleId.flatMap { HostInfo.editorApps.contains($0) ? $0 : nil } ?? HostInfo.vscode
        let folder = EditorWorkspaces.folder(containing: session.cwd) ?? session.cwd
        openEditorWindow(folder: folder, bundleId: bundle) { ok in
            guard let url = editorDeepLink(session, bundleId: bundle, prompt: prompt) else { return }
            // Ссылку VS Code отдаёт последнему активному окну — ждём, пока окно проекта станет им.
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.45 : 0)) { NSWorkspace.shared.open(url) }
        }
    }

    static func editorDeepLink(_ session: AgentSession, bundleId: String, prompt: String?) -> URL? {
        var c = URLComponents()
        c.scheme = bundleId == HostInfo.vscodeInsiders ? "vscode-insiders" : "vscode"
        c.host = "anthropic.claude-code"
        c.path = "/open"
        var items = [URLQueryItem(name: "session", value: session.sessionId)]
        if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            items.append(URLQueryItem(name: "prompt", value: p))
        }
        c.queryItems = items
        return c.url
    }

    static func openEditorWindow(folder: String, bundleId: String, then: @escaping @MainActor (Bool) -> Void) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { Task { @MainActor in then(false) }; return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, error in
            if let error { NSLog("AgentHUD: не открыл \(folder) в VS Code: \(error.localizedDescription)") }
            Task { @MainActor in then(error == nil) }
        }
    }

    static func activate(_ bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Найти вкладку Terminal.app по условию, выбрать её и поднять окно.
    static func terminalScript(match condition: String) -> String {
        """
        if application "Terminal" is not running then return false
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if \(condition) then
                        set selected of t to true
                        set index of w to 1
                        if miniaturized of w then set miniaturized of w to false
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func iTermScript(tty: String) -> String {
        """
        if application "iTerm2" is not running then return false
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    @discardableResult
    static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error { NSLog("AgentHUD AppleScript: \(error)") }
        return error == nil && result.booleanValue
    }

    static func focusHerdr(pane: String, socket: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["agent", "focus", pane]
        var env = ProcessInfo.processInfo.environment
        if let socket { env["HERDR_SOCKET_PATH"] = socket }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        // Не ждём дольше секунды, чтобы не подвесить интерфейс.
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
    }
}

/// Папки, открытые в окнах VS Code с расширением Claude Code. Расширение пишет их в `~/.claude/ide/<порт>.lock`
/// (`workspaceFolders`, `pid`). Читаем только эти два поля; токен из файла не трогаем.
enum EditorWorkspaces {
    static func folder(containing cwd: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var best: String?
        for f in files where f.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: f), let v = try? JSONValue.parse(data) else { continue }
            if let pid = v["pid"]?.intValue, !HostProbe.isAlive(Int32(pid)) { continue }
            for folder in v["workspaceFolders"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else { continue }
                if folder.count > (best?.count ?? 0) { best = folder }
            }
        }
        return best
    }
}

extension EditorWorkspaces {
    /// Все папки, открытые сейчас в окнах VS Code с расширением Claude Code (живые `pid`).
    static func openFolders() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out = Set<String>()
        for f in files where f.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: f), let v = try? JSONValue.parse(data) else { continue }
            if let pid = v["pid"]?.intValue, !HostProbe.isAlive(Int32(pid)) { continue }
            for folder in v["workspaceFolders"]?.arrayValue?.compactMap(\.stringValue) ?? [] { out.insert(folder) }
        }
        return out
    }
}
