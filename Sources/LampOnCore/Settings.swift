import Foundation

public enum WebServer: String, Codable, CaseIterable, Sendable, Identifiable {
    case apache
    case nginx

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apache: "Apache"
        case .nginx: "Nginx"
        }
    }
}

/// Preferências do usuário. Equivalem às chaves `apachePort`, `mySqlPort`, `phpVersion`,
/// `userRootDirectory`, `startServers`, `stopServers` e `openPage` do MAMP.
public struct Settings: Codable, Equatable, Sendable {
    public var webServer: WebServer = .apache
    public var webPort: Int = Settings.alternatePorts.web
    public var mysqlPort: Int = Settings.alternatePorts.mysql
    /// Porta interna do PHP-FPM (só escuta em 127.0.0.1).
    public var phpFpmPort: Int = 9074
    /// Fórmula do Homebrew, ex.: "php", "php@8.3". `nil` = a mais nova instalada.
    public var phpFormula: String?
    /// Fórmula do Homebrew, ex.: "mysql", "mysql@8.4", "mariadb". `nil` = a primeira encontrada.
    public var mysqlFormula: String?
    public var documentRoot: String = Settings.defaultDocumentRoot
    public var startServersOnLaunch: Bool = false
    public var stopServersOnQuit: Bool = true
    public var openStartPageOnStart: Bool = true

    public init() {}

    // Decodifica campo a campo para que preferências salvas por versões antigas continuem válidas.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        webServer = try c.decodeIfPresent(WebServer.self, forKey: .webServer) ?? d.webServer
        webPort = try c.decodeIfPresent(Int.self, forKey: .webPort) ?? d.webPort
        mysqlPort = try c.decodeIfPresent(Int.self, forKey: .mysqlPort) ?? d.mysqlPort
        phpFpmPort = try c.decodeIfPresent(Int.self, forKey: .phpFpmPort) ?? d.phpFpmPort
        phpFormula = try c.decodeIfPresent(String.self, forKey: .phpFormula)
        mysqlFormula = try c.decodeIfPresent(String.self, forKey: .mysqlFormula)
        documentRoot = try c.decodeIfPresent(String.self, forKey: .documentRoot) ?? d.documentRoot
        startServersOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startServersOnLaunch) ?? d.startServersOnLaunch
        stopServersOnQuit = try c.decodeIfPresent(Bool.self, forKey: .stopServersOnQuit) ?? d.stopServersOnQuit
        openStartPageOnStart = try c.decodeIfPresent(Bool.self, forKey: .openStartPageOnStart) ?? d.openStartPageOnStart
    }

    public static let defaultDocumentRoot: String = Paths.default.htdocs

    /// Portas padrão do LAMP-ON, escolhidas para não conflitar com um MAMP rodando ao mesmo tempo.
    public static let alternatePorts = (web: 8080, mysql: 3306)
    /// Mesmas portas padrão do MAMP.
    public static let mampPorts = (web: 8888, mysql: 8889)

    public static func isValidPort(_ port: Int) -> Bool {
        (1024...65535).contains(port)
    }

    /// Lista de problemas que impedem iniciar os servidores.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        for (name, port) in [("web", webPort), ("MySQL", mysqlPort), ("PHP-FPM", phpFpmPort)]
        where !Self.isValidPort(port) {
            errors.append("A porta \(name) (\(port)) precisa estar entre 1024 e 65535.")
        }
        let ports = [webPort, mysqlPort, phpFpmPort]
        if Set(ports).count != ports.count {
            errors.append("As portas web, MySQL e PHP-FPM precisam ser diferentes.")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: documentRoot, isDirectory: &isDirectory) || !isDirectory.boolValue {
            errors.append("O document root \(documentRoot) não existe.")
        }
        return errors
    }
}

public struct SettingsStore: Sendable {
    private let key = "settings"
    private let suiteName: String?

    public static let bundleIdentifier = "dev.lampon.LampOn"

    /// Usa sempre o domínio do app, para que o binário rodado pela linha de comando
    /// (fora do bundle) leia as mesmas preferências.
    public init(suiteName: String? = SettingsStore.bundleIdentifier) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        // Dentro do próprio app o macOS não aceita o bundle id como suite; lá `.standard` já é esse domínio.
        guard let suiteName, suiteName != Bundle.main.bundleIdentifier else { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func load() -> Settings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    public func save(_ settings: Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
