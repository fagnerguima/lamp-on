import AppKit
import LampOnCore
import Observation

/// Estado da interface. Faz a ponte entre a UI (main thread) e o `ServerController` (bloqueante).
@MainActor
@Observable
final class ServerManager {
    static let shared = ServerManager()

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if status.anyRunning, appliedSettings != nil, settings != appliedSettings {
                needsRestart = true
            }
        }
    }
    private(set) var installation: Installation
    private(set) var status = ServiceStatus.allStopped
    private(set) var isBusy = false
    private(set) var busyMessage = ""
    private(set) var lastError: String?
    private(set) var log: [String] = []
    private(set) var needsRestart = false
    /// Configuração com que os servidores rodando foram iniciados.
    private var appliedSettings: Settings?

    let paths = Paths.default
    private let store = SettingsStore()
    private var timer: Timer?

    var brewPrefix: String? { Homebrew.detectPrefix() }
    var controller: ServerController { ServerController(paths: paths, installation: installation) }
    var missingFormulas: [String] { installation.missingFormulas(for: settings) }
    var selectedPHP: Formula? { installation.php(named: settings.phpFormula) }
    var selectedMySQL: Formula? { installation.mysql(named: settings.mysqlFormula) }
    var startPageURL: URL { URL(string: "http://localhost:\(settings.webPort)\(ConfigRenderer.startPageAlias)/")! }
    var phpMyAdminURL: URL { URL(string: "http://localhost:\(settings.webPort)\(PhpMyAdmin.urlPath)/")! }
    /// Instalado pelo LAMP-ON ou pelo Homebrew (`brew install phpmyadmin`).
    var hasPhpMyAdmin: Bool { controller.installation.phpMyAdminPath != nil }

    private init() {
        settings = SettingsStore().load()
        installation = Homebrew.detectPrefix().map { Homebrew.scan(prefix: $0) } ?? Installation(prefix: "/opt/homebrew")
        do {
            // Executa uma vez, na primeira abertura depois de atualizar de uma versão com outra pasta de dados.
            for message in try Migration.run(to: paths) { append(message) }
            try paths.createDirectories()
        } catch {
            lastError = "Falha ao mover os dados para \(paths.root): \(error.localizedDescription)"
        }
        refreshStatus()
        if status.anyRunning { appliedSettings = settings }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { ServerManager.shared.refreshStatus() }
        }
    }

    func refreshStatus() {
        guard !isBusy else { return }
        let new = controller.status()
        if new != status { status = new }
        if !status.anyRunning { needsRestart = false }
    }

    func rescanHomebrew() {
        installation = brewPrefix.map { Homebrew.scan(prefix: $0) } ?? installation
        append("Homebrew: \(installation.php.count) PHP, \(installation.mysql.count) MySQL, Apache \(installation.httpd == nil ? "ausente" : "ok"), Nginx \(installation.nginx == nil ? "ausente" : "ok")")
    }

    // MARK: Ações

    func toggle() {
        status.anyRunning ? stop() : start()
    }

    func start() {
        let settings = settings
        perform("Iniciando…") { controller, log in
            try controller.startAll(settings, log: log)
        } completion: { manager in
            manager.appliedSettings = settings
            manager.needsRestart = false
            if settings.openStartPageOnStart { manager.openStartPage() }
        }
    }

    func stop(completion: (@MainActor () -> Void)? = nil) {
        perform("Parando…") { controller, log in
            controller.stopAll(log: log)
        } completion: { manager in
            manager.appliedSettings = nil
            manager.needsRestart = false
            completion?()
        }
    }

    func restart() {
        let settings = settings
        perform("Reiniciando…") { controller, log in
            try controller.restartAll(settings, log: log)
        } completion: { manager in
            manager.appliedSettings = settings
            manager.needsRestart = false
        }
    }

    /// Abre o phpMyAdmin; na primeira vez, baixa e instala a versão "english" e reinicia o servidor web.
    func openPhpMyAdmin() {
        if hasPhpMyAdmin {
            open(phpMyAdminURL, label: "phpMyAdmin")
        } else {
            installPhpMyAdmin(thenOpen: true)
        }
    }

    func installPhpMyAdmin(thenOpen: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = "Instalando phpMyAdmin…"
        lastError = nil
        let paths = paths
        let settings = settings
        let restartWeb = status.web
        let log: ServerController.Log = { line in
            Task { @MainActor in ServerManager.shared.append(line) }
        }
        Task.detached {
            var failure: String?
            do {
                try await PhpMyAdmin.install(paths: paths, log: log)
                if restartWeb {
                    let controller = await MainActor.run { ServerManager.shared.controller }
                    try controller.restartWeb(settings, log: log)
                }
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [failure] in
                let manager = ServerManager.shared
                manager.isBusy = false
                manager.busyMessage = ""
                manager.refreshStatus()
                if let failure {
                    manager.lastError = failure
                    manager.append("Erro: \(failure)")
                } else if thenOpen, manager.status.web {
                    manager.open(manager.phpMyAdminURL, label: "phpMyAdmin")
                } else if thenOpen {
                    manager.append("phpMyAdmin pronto. Inicie os servidores para abri-lo.")
                }
            }
        }
    }

    private func perform(_ message: String,
                         _ work: @escaping @Sendable (ServerController, @escaping ServerController.Log) throws -> Void,
                         completion: @escaping @MainActor (ServerManager) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = message
        lastError = nil
        let controller = controller
        let log: ServerController.Log = { line in
            Task { @MainActor in ServerManager.shared.append(line) }
        }
        Task.detached {
            let failure: String?
            do {
                try work(controller, log)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                let manager = ServerManager.shared
                manager.isBusy = false
                manager.busyMessage = ""
                manager.refreshStatus()
                if let failure {
                    manager.lastError = failure
                    manager.append("Erro: \(failure)")
                } else {
                    completion(manager)
                }
            }
        }
    }

    func append(_ line: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        log.append("[\(time)] \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: Atalhos

    func openStartPage() {
        open(startPageURL, label: "Página inicial")
    }

    private func open(_ url: URL, label: String) {
        let browser = NSWorkspace.shared.urlForApplication(toOpen: url)
        let browserName = browser.map { $0.deletingPathExtension().lastPathComponent } ?? "navegador padrão"
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                let manager = ServerManager.shared
                if let error {
                    manager.append("Não foi possível abrir \(url.absoluteString) no \(browserName): \(error.localizedDescription)")
                } else {
                    manager.append("\(label) enviado ao \(browserName): \(url.absoluteString)")
                }
            }
        }
    }

    func copyStartPageURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(startPageURL.absoluteString, forType: .string)
        append("Endereço copiado: \(startPageURL.absoluteString)")
    }

    func revealDocumentRoot() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.documentRoot)
    }

    func openLog(_ name: String) {
        let url = URL(fileURLWithPath: paths.log(name))
        guard FileManager.default.fileExists(atPath: url.path) else {
            append("O log \(name) ainda não existe.")
            return
        }
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealDataFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: paths.root))
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Homebrew.installCommand(for: missingFormulas), forType: .string)
        append("Comando copiado: \(Homebrew.installCommand(for: missingFormulas))")
    }

    static let logFiles = [
        "apache_error.log", "apache_access.log", "nginx_error.log", "nginx_access.log",
        "php_error.log", "php-fpm.log", "mysql_error.log",
    ]
}
