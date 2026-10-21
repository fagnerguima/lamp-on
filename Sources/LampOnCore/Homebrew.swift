import Foundation

/// Uma fórmula do Homebrew instalada, resolvida a partir de `<prefix>/opt/<fórmula>`.
public struct Formula: Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let version: String
    /// `<prefix>/opt/<name>`, um link estável que sobrevive a `brew upgrade`.
    public let optPath: String

    public var id: String { name }

    public init(name: String, version: String, optPath: String) {
        self.name = name
        self.version = version
        self.optPath = optPath
    }

    public func path(_ relative: String) -> String {
        (optPath as NSString).appendingPathComponent(relative)
    }
}

/// O que está instalado no Homebrew e é útil para o LAMP-ON.
public struct Installation: Equatable, Sendable {
    public var prefix: String
    public var httpd: Formula?
    public var nginx: Formula?
    /// Versões de PHP com `sbin/php-fpm`, da mais nova para a mais antiga.
    public var php: [Formula]
    /// `mysql`, `mysql@x.y` e `mariadb` com um servidor executável.
    public var mysql: [Formula]
    public var phpMyAdminPath: String?

    public init(prefix: String, httpd: Formula? = nil, nginx: Formula? = nil, php: [Formula] = [],
                mysql: [Formula] = [], phpMyAdminPath: String? = nil) {
        self.prefix = prefix
        self.httpd = httpd
        self.nginx = nginx
        self.php = php
        self.mysql = mysql
        self.phpMyAdminPath = phpMyAdminPath
    }

    public func php(named name: String?) -> Formula? {
        php.first { $0.name == name } ?? php.first
    }

    public func mysql(named name: String?) -> Formula? {
        mysql.first { $0.name == name } ?? mysql.first
    }

    /// Fórmulas que faltam para a configuração escolhida.
    public func missingFormulas(for settings: Settings) -> [String] {
        var missing: [String] = []
        switch settings.webServer {
        case .apache where httpd == nil: missing.append("httpd")
        case .nginx where nginx == nil: missing.append("nginx")
        default: break
        }
        if php.isEmpty { missing.append("php") }
        if mysql.isEmpty { missing.append("mysql") }
        return missing
    }
}

public enum Homebrew {
    public static let candidatePrefixes = ["/opt/homebrew", "/usr/local"]

    public static func detectPrefix(fileManager: FileManager = .default) -> String? {
        if let env = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
           fileManager.fileExists(atPath: (env as NSString).appendingPathComponent("bin/brew")) {
            return env
        }
        return candidatePrefixes.first {
            fileManager.fileExists(atPath: ($0 as NSString).appendingPathComponent("bin/brew"))
        }
    }

    public static func scan(prefix: String, fileManager: FileManager = .default) -> Installation {
        let optDir = (prefix as NSString).appendingPathComponent("opt")
        let names = (try? fileManager.contentsOfDirectory(atPath: optDir)) ?? []

        func formula(_ name: String, requiring executable: String) -> Formula? {
            let opt = (optDir as NSString).appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: (opt as NSString).appendingPathComponent(executable)) else {
                return nil
            }
            return Formula(name: name, version: version(ofOptPath: opt, fileManager: fileManager), optPath: opt)
        }

        let php = dedupe(names.filter(isPHPFormula).compactMap { formula($0, requiring: "sbin/php-fpm") }, fileManager)
            .sorted { compareVersions($0.version, $1.version) == .orderedDescending }

        let mysql = dedupe(names.filter(isMySQLFormula).compactMap { formula($0, requiring: "bin/mysqld") }, fileManager)
            .sorted { lhs, rhs in
                // MySQL antes de MariaDB; dentro de cada família, a versão mais nova primeiro.
                let lm = lhs.name.hasPrefix("mariadb"), rm = rhs.name.hasPrefix("mariadb")
                if lm != rm { return !lm }
                return compareVersions(lhs.version, rhs.version) == .orderedDescending
            }

        let pma = ["share/phpmyadmin", "opt/phpmyadmin/share/phpmyadmin"]
            .map { (prefix as NSString).appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: ($0 as NSString).appendingPathComponent("index.php")) }

        return Installation(
            prefix: prefix,
            httpd: formula("httpd", requiring: "bin/httpd"),
            nginx: formula("nginx", requiring: "bin/nginx"),
            php: php,
            mysql: mysql,
            phpMyAdminPath: pma
        )
    }

    /// O Homebrew cria aliases como `opt/php@8.5` → mesma pasta de `opt/php`. Mantém só o nome
    /// mais curto (a fórmula principal) de cada destino.
    static func dedupe(_ formulas: [Formula], _ fileManager: FileManager) -> [Formula] {
        var byTarget: [String: Formula] = [:]
        for formula in formulas {
            let target = (try? fileManager.destinationOfSymbolicLink(atPath: formula.optPath)) ?? formula.optPath
            if let existing = byTarget[target], existing.name.count <= formula.name.count { continue }
            byTarget[target] = formula
        }
        return Array(byTarget.values)
    }

    static func isPHPFormula(_ name: String) -> Bool {
        name.range(of: #"^php(@\d+\.\d+)?$"#, options: .regularExpression) != nil
    }

    static func isMySQLFormula(_ name: String) -> Bool {
        name.range(of: #"^(mysql|mariadb)(@\d+(\.\d+)?)?$"#, options: .regularExpression) != nil
    }

    /// `<prefix>/opt/php` aponta para `../Cellar/php/8.4.13_1`; a versão é o último componente
    /// sem o sufixo de revisão do Homebrew.
    static func version(ofOptPath optPath: String, fileManager: FileManager) -> String {
        let resolved = (try? fileManager.destinationOfSymbolicLink(atPath: optPath)) ?? optPath
        return stripRevision((resolved as NSString).lastPathComponent)
    }

    static func stripRevision(_ version: String) -> String {
        guard let range = version.range(of: #"_\d+$"#, options: .regularExpression) else { return version }
        return String(version[..<range.lowerBound])
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    /// Comando para instalar o que falta.
    public static func installCommand(for formulas: [String]) -> String {
        "brew install " + formulas.joined(separator: " ")
    }
}
