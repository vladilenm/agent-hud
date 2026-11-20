import Darwin
import Foundation

/// Определяет, где запущен агент: терминал (TTY, herdr) или десктопное приложение (Claude, Codex).
/// Работает через sysctl — без запуска внешних процессов, чтобы хук оставался быстрым.
public enum HostProbe {
    public struct ProcInfo: Equatable {
        public let pid: Int32
        public let ppid: Int32
        public let tty: String?
        public let name: String
    }

    public static func info(pid: Int32) -> ProcInfo? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = kp.kp_eproc.e_ppid
        let dev = kp.kp_eproc.e_tdev
        var tty: String?
        if dev != -1, dev != 0, let name = devname(dev, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        let name = withUnsafePointer(to: kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return ProcInfo(pid: pid, ppid: ppid, tty: tty, name: name)
    }

    /// Цепочка процессов от `start` вверх до launchd.
    public static func chain(from start: Int32, limit: Int = 16) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var pid = start
        while pid > 1, out.count < limit, let i = info(pid: pid) {
            out.append(i)
            pid = i.ppid
        }
        return out
    }

    /// Собрать HostInfo для текущего процесса хука.
    public static func current(env: [String: String] = ProcessInfo.processInfo.environment) -> HostInfo {
        let chain = chain(from: getppid())
        let agent = agentProcess(in: chain)
        let tty = agent?.tty ?? chain.first(where: { $0.tty != nil })?.tty
        let inHerdr = env["HERDR_ENV"] == "1" && env["HERDR_PANE_ID"] != nil
        let app = hostApp(in: chain)
        return HostInfo(
            termProgram: env["TERM_PROGRAM"],
            tty: tty,
            agentPid: agent?.pid,
            herdrPaneId: inHerdr ? env["HERDR_PANE_ID"] : nil,
            herdrSocket: inHerdr ? env["HERDR_SOCKET_PATH"] : nil,
            processChain: chain.prefix(8).map(\.name),
            appBundleId: app?.bundleId,
            appName: app?.name,
            hostSessionId: env["CLAUDE_CODE_HOST_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 },
            entrypoint: env["CLAUDE_CODE_ENTRYPOINT"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Полный путь исполняемого файла процесса.
    public static func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Бандл .app по пути исполняемого файла: «/Applications/Claude.app/Contents/MacOS/Claude» → «/Applications/Claude.app».
    public static func bundlePath(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Самое внешнее GUI-приложение в цепочке (Terminal, Claude, Codex…).
    /// Внешнее — потому что сам Claude Code тоже лежит в бандле `claude.app` внутри данных приложения.
    static func hostApp(in chain: [ProcInfo]) -> (bundleId: String, name: String)? {
        for p in chain.reversed() {
            guard let exe = executablePath(pid: p.pid), let bundle = bundlePath(forExecutable: exe),
                  let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
                  let id = info["CFBundleIdentifier"] as? String else { continue }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return (id, name)
        }
        return nil
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "-zsh", "-bash", "login"]

    /// Агент запускает хук напрямую, но иногда через оболочку. Процесс Claude Code
    /// при этом может называться номером версии («2.1.322»), поэтому по имени не ищем:
    /// берём первого предка, который не оболочка.
    public static func agentProcess(in chain: [ProcInfo]) -> ProcInfo? {
        chain.first { !shells.contains($0.name) } ?? chain.first
    }

    /// HUD показывает сессии, за которыми сидит человек: терминал, VS Code и десктопные приложения Claude и Codex.
    /// SDK, `claude -p`, `codex exec` из скриптов и служебные запросы приложений идут мимо — иначе
    /// синхронный хук подвешивал бы автоматизацию до ответа в HUD. `AGENTHUD_ANY_HOST=1` снимает фильтр (для тестов).
    public static func isInteractive(kind: AgentKind, host: HostInfo, env: [String: String]) -> Bool {
        if env["AGENTHUD_ANY_HOST"] == "1" { return true }
        switch kind {
        case .claude:
            switch env["CLAUDE_CODE_ENTRYPOINT"] {
            case "claude-desktop":
                // У настоящей сессии приложения есть свой id (local_…); у служебных запросов — нет.
                return env["CLAUDE_CODE_HOST_SESSION_ID"]?.isEmpty == false
            case HostInfo.vscodeEntrypoint:
                // Панель чата расширения Claude Code. TTY нет; признак живого человека — процесс внутри VS Code.
                return host.appBundleId.map(HostInfo.editorApps.contains) == true
            case nil, "cli":
                return host.tty != nil
            default:
                return false   // sdk-*, другие редакторы
            }
        case .codex:
            return host.tty != nil || host.appBundleId == HostInfo.codexDesktop
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
