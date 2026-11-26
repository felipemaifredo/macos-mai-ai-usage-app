import AppKit
import ServiceManagement

// Providers (Claude, Codex, Antigravity) live in UsageProviders.swift.

// MARK: - One menu bar item per provider

@MainActor
final class ProviderController: NSObject, NSMenuDelegate {
    let provider: UsageProvider
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var rows: [UsageRow] = []
    var lastUpdate: Date?
    var errorText: String?
    var isLoading = false
    /// After an HTTP 429, nothing is asked until this date.
    var blockedUntil: Date?
    /// When the API was last asked. The ↻ button waits `minManualGap` after it.
    var askedAt: Date?
    static let minManualGap: TimeInterval = 60
    /// Re-enables the ↻ button while the menu is open, once the wait is over.
    var unlockTimer: Timer?
    var onToggleLogin: () -> Void = {}
    /// Called after every fetch, successful or not.
    var onUpdate: () -> Void = {}

    // A button inside a custom-view menu item, so clicking it does not close the menu.
    lazy var refreshButton: NSButton = {
        let b = NSButton(title: "↻ Atualizar agora", target: self, action: #selector(refreshManually))
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
        menu.delegate = self
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

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    /// The ↻ button, or another app asking for fresh numbers.
    @objc func refreshManually() { refresh(manual: true) }

    /// Earliest moment the ↻ button may ask the API again.
    var manualAllowedAt: Date? {
        let gapEnd = askedAt?.addingTimeInterval(Self.minManualGap)
        let later = [gapEnd, blockedUntil].compactMap { $0 }.max()
        return later.flatMap { $0 > Date() ? $0 : nil }
    }

    func refresh(manual: Bool = false) {
        guard !isLoading else { return }
        if let until = blockedUntil, Date() < until {
            // The API said to wait. Local numbers (if the provider has them) are still fine to read.
            if let rows = provider.fallbackRows() {
                self.rows = rows
                lastUpdate = Date()
                updateTitle()
                rebuildMenu()
                onUpdate()
            }
            return
        }
        if manual, manualAllowedAt != nil { return }
        isLoading = true
        askedAt = Date()
        scheduleTimer()
        rebuildMenu()
        Task {
            do {
                self.rows = try await provider.fetch()
                self.lastUpdate = Date()
                self.errorText = nil
                self.blockedUntil = nil
            } catch FetchError.notRunning {
                self.rows = []
                self.errorText = provider.noCredentialsMessage
            } catch FetchError.expired {
                self.errorText = provider.expiredMessage
            } catch FetchError.noCredentials {
                self.errorText = provider.noCredentialsMessage
            } catch FetchError.rateLimited(let until) {
                // Keep showing the last numbers, or local ones if the provider has them.
                self.blockedUntil = until
                if let rows = provider.fallbackRows() {
                    self.rows = rows
                    self.lastUpdate = Date()
                }
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                self.errorText = "Limite de consultas da API. Tento de novo às \(f.string(from: until))"
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
            self.onUpdate()
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

        unlockTimer?.invalidate()
        if isLoading {
            refreshButton.title = "Atualizando…"
            refreshButton.isEnabled = false
        } else if let until = manualAllowedAt {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            refreshButton.title = "Aguarde até \(f.string(from: until))"
            refreshButton.isEnabled = false
            let t = Timer(fire: until.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildMenu() }
            }
            RunLoop.main.add(t, forMode: .common)
            unlockTimer = t
        } else {
            refreshButton.title = "↻ Atualizar agora"
            refreshButton.isEnabled = true
        }
        refreshButton.sizeToFit()
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
        // Status items created later appear further left: Antigravity first, so the bar reads
        // Claude, Codex, Antigravity from left to right.
        controllers = [
            ProviderController(provider: AntigravityProvider()),
            ProviderController(provider: CodexProvider()),
            ProviderController(provider: ClaudeProvider()),
        ]
        for c in controllers {
            c.onToggleLogin = { [weak self] in self?.controllers.forEach { $0.rebuildMenu() } }
            c.onUpdate = { [weak self] in self?.broadcast() }
            c.refresh()
        }

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Self.requestName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcast() }
        }
        center.addObserver(forName: Self.refreshName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllers.forEach { $0.refresh(manual: true) } }
        }
    }

    // MARK: Sharing the numbers with other apps (e.g. Waveshare Link, which drives the USB display)
    //   local.aiusagebar.usage    we post it on every update; userInfo["json"] = {"providers":[…]}
    //   local.aiusagebar.request  another app asks for the current numbers
    //   local.aiusagebar.refresh  another app asks for a fetch now
    static let usageName = Notification.Name("local.aiusagebar.usage")
    static let requestName = Notification.Name("local.aiusagebar.request")
    static let refreshName = Notification.Name("local.aiusagebar.refresh")

    func broadcast() {
        guard let data = try? JSONSerialization.data(withJSONObject: ["providers": usageSnapshot()]),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Self.usageName, object: nil, userInfo: ["json": json], deliverImmediately: true)
    }

    func usageSnapshot() -> [[String: Any]] {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        // Claude, Codex, Antigravity: the same order as in the menu bar.
        return controllers.reversed().map { c in
            [
                "name": c.provider.name,
                "pct": c.provider.headline(c.rows).map { Int($0.rounded()) } ?? -1,
                "err": c.errorText ?? "",
                "busy": c.isLoading,
                "at": c.lastUpdate.map { f.string(from: $0) } ?? "",
                "rows": c.rows.map { r in [
                    "sec": r.section ?? "",
                    "label": r.label,
                    "pct": Int(r.usedPct.rounded()),
                    "reset": shortReset(r.resetsAt),
                ] as [String: Any] },
            ]
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
