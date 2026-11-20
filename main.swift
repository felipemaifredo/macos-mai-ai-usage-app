import AppKit
import ServiceManagement

// MARK: - Model

struct UsageRow {
    let section: String?
    let label: String
    let usedPct: Double
    let resetsAt: Date?
}

enum FetchError: Error {
    case noCredentials
    case expired
    case notRunning
    case http(Int)
    case badResponse
    case network(String)
}

protocol UsageProvider {
    var symbol: String { get }
    var expiredMessage: String { get }
    func fetch() async throws -> [UsageRow]
    /// Value shown in the menu bar title.
    func headline(_ rows: [UsageRow]) -> Double?
}

// MARK: - Helpers

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

func formatReset(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "pt_BR")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return " · reseta \(f.string(from: d))"
}

func performJSON(_ req: URLRequest) async throws -> [String: Any] {
    let data: Data
    let resp: URLResponse
    do {
        (data, resp) = try await URLSession.shared.data(for: req)
    } catch {
        throw FetchError.network(error.localizedDescription)
    }
    guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
    if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.expired }
    guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FetchError.badResponse
    }
    return json
}

// MARK: - Claude

struct ClaudeProvider: UsageProvider {
    let symbol = "◐"
    let expiredMessage = "Login expirado: abra o Claude Code para renovar"

    func readAccessToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw FetchError.noCredentials }
        if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
            throw FetchError.expired
        }
        return token
    }

    func label(for key: String) -> String {
        switch key {
        case "five_hour": return "Sessão (5h)"
        case "seven_day": return "Semana"
        case "seven_day_opus": return "Semana (Opus)"
        case "seven_day_sonnet": return "Semana (Sonnet)"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func fetch() async throws -> [UsageRow] {
        let token = try readAccessToken()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let json = try await performJSON(req)

        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        var items: [(key: String, util: Double, reset: Date?)] = []
        for (key, value) in json {
            guard let obj = value as? [String: Any],
                  let util = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            items.append((key, util, parseDate(obj["resets_at"] as? String)))
        }
        items.sort {
            (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key)
        }
        return items.map { UsageRow(section: nil, label: label(for: $0.key), usedPct: $0.util, resetsAt: $0.reset) }
    }

    func headline(_ rows: [UsageRow]) -> Double? {
        (rows.first { $0.label == "Sessão (5h)" } ?? rows.first)?.usedPct
    }
}

// MARK: - Antigravity (local hub API)

struct AntigravityProvider: UsageProvider {
    let symbol = "✦"
    let expiredMessage = "Antigravity recusou o acesso: reabra o Antigravity"

    struct Hub { let port: Int; let csrf: String }

    func findHub() throws -> Hub {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/daemon")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let port = (json["httpPort"] as? NSNumber)?.intValue,
                  let csrf = json["csrfToken"] as? String,
                  kill(pid, 0) == 0
            else { continue }
            return Hub(port: port, csrf: csrf)
        }
        throw FetchError.notRunning
    }

    func windowLabel(_ w: String?) -> String {
        switch w {
        case "5h": return "Sessão (5h)"
        case "weekly": return "Semana"
        case let other?: return other
        case nil: return "Limite"
        }
    }

    func fetch() async throws -> [UsageRow] {
        let hub = try findHub()
        var req = URLRequest(url: URL(string:
            "http://127.0.0.1:\(hub.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(hub.csrf, forHTTPHeaderField: "x-codeium-csrf-token")
        req.timeoutInterval = 20

        let json: [String: Any]
        do {
            json = try await performJSON(req)
        } catch FetchError.network {
            throw FetchError.notRunning
        }
        guard let resp = json["response"] as? [String: Any],
              let groups = resp["groups"] as? [[String: Any]] else { throw FetchError.badResponse }

        var rows: [UsageRow] = []
        for g in groups {
            let section = g["displayName"] as? String
            for b in (g["buckets"] as? [[String: Any]]) ?? [] {
                guard let remaining = (b["remainingFraction"] as? NSNumber)?.doubleValue else { continue }
                rows.append(UsageRow(section: section,
                                     label: windowLabel(b["window"] as? String),
                                     usedPct: max(0, min(100, (1 - remaining) * 100)),
                                     resetsAt: parseDate(b["resetTime"] as? String)))
            }
        }
        return rows
    }

    func headline(_ rows: [UsageRow]) -> Double? {
        rows.map(\.usedPct).max()
    }
}

// MARK: - One menu bar item per provider

@MainActor
final class ProviderController: NSObject {
    let provider: UsageProvider
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var rows: [UsageRow] = []
    var lastUpdate: Date?
    var errorText: String?
    var isLoading = false
    var onToggleLogin: () -> Void = {}

    // A button inside a custom-view menu item, so clicking it does not close the menu.
    lazy var refreshButton: NSButton = {
        let b = NSButton(title: "↻ Atualizar agora", target: self, action: #selector(refresh))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.sizeToFit()
        return b
    }()
    lazy var refreshItem: NSMenuItem = {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        refreshButton.frame.origin = NSPoint(x: 14, y: (30 - refreshButton.frame.height) / 2)
        view.addSubview(refreshButton)
        item.view = view
        return item
    }()

    init(provider: UsageProvider) {
        self.provider = provider
        super.init()
        menu.autoenablesItems = false
        statusItem.menu = menu
        setTitle("\(provider.symbol) …", color: nil)
        rebuildMenu()
    }

    func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        RunLoop.main.add(t, forMode: .common) // keep firing while the menu is open
        timer = t
    }

    @objc func refresh() {
        guard !isLoading else { return }
        isLoading = true
        scheduleTimer()
        rebuildMenu()
        Task {
            do {
                self.rows = try await provider.fetch()
                self.lastUpdate = Date()
                self.errorText = nil
            } catch FetchError.notRunning {
                self.rows = []
                self.errorText = "Antigravity não está aberto"
            } catch FetchError.expired {
                self.errorText = provider.expiredMessage
            } catch FetchError.noCredentials {
                self.errorText = "Credenciais do Claude Code não encontradas"
            } catch FetchError.http(let code) {
                self.errorText = "Erro HTTP \(code)"
            } catch FetchError.network(let msg) {
                self.errorText = "Sem conexão: \(msg)"
            } catch {
                self.errorText = "Resposta inesperada da API"
            }
            self.isLoading = false
            self.updateTitle()
            self.rebuildMenu()
        }
    }

    func updateTitle() {
        let s = provider.symbol
        guard let value = provider.headline(rows) else {
            setTitle(errorText != nil ? "\(s) –" : "\(s) …", color: nil)
            return
        }
        var text = "\(s) \(Int(value.rounded()))%"
        if errorText != nil { text += " !" }
        let color: NSColor? = value >= 90 ? .systemRed : value >= 75 ? .systemOrange : nil
        setTitle(text, color: color)
    }

    func setTitle(_ text: String, color: NSColor?) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ]
        if let color { attrs[.foregroundColor] = color }
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    lazy var loginItem: NSMenuItem = {
        let i = NSMenuItem(title: "Abrir ao iniciar sessão", action: #selector(toggleLogin), keyEquivalent: "")
        i.target = self
        return i
    }()

    /// Updates the menu in place. The footer (refresh button, login, quit) is never removed,
    /// so clicking the refresh button keeps the menu open while the values change.
    func rebuildMenu() {
        if refreshItem.menu == nil {
            menu.addItem(refreshItem)
            menu.addItem(loginItem)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        }

        var top: [NSMenuItem] = []
        if rows.isEmpty && errorText == nil {
            top.append(disabled("Carregando uso…"))
        }
        var currentSection: String? = nil
        for r in rows {
            if let sec = r.section, sec != currentSection {
                if currentSection != nil { top.append(.separator()) }
                let header = disabled(sec)
                header.attributedTitle = NSAttributedString(string: sec, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
                top.append(header)
                currentSection = sec
            }
            let indent = r.section != nil ? "   " : ""
            top.append(disabled("\(indent)\(r.label): \(Int(r.usedPct.rounded()))%\(formatReset(r.resetsAt))"))
        }
        if let errorText {
            if !rows.isEmpty { top.append(.separator()) }
            let item = disabled("⚠︎ \(errorText)")
            if !rows.isEmpty { item.title += " (dados desatualizados)" }
            top.append(item)
        }
        top.append(.separator())
        if let lastUpdate {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            top.append(disabled("Última atualização: \(f.string(from: lastUpdate))"))
        }

        while menu.items.first !== refreshItem { menu.removeItem(at: 0) }
        for (i, item) in top.enumerated() { menu.insertItem(item, at: i) }

        refreshButton.title = isLoading ? "Atualizando…" : "↻ Atualizar agora"
        refreshButton.isEnabled = !isLoading
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            errorText = "Não foi possível alterar o início automático"
        }
        onToggleLogin()
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [ProviderController] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        // Status items created later appear further left: Antigravity first so Claude sits left of it.
        controllers = [
            ProviderController(provider: AntigravityProvider()),
            ProviderController(provider: ClaudeProvider()),
        ]
        for c in controllers {
            c.onToggleLogin = { [weak self] in self?.controllers.forEach { $0.rebuildMenu() } }
            c.refresh()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
