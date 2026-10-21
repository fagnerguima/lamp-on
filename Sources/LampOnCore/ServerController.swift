import Darwin
import Foundation

public enum Service: String, CaseIterable, Sendable, Identifiable {
    case web
    case php
    case mysql

    public var id: String { rawValue }
}

public struct ServiceStatus: Equatable, Sendable {
    public var webServer: WebServer?
    public var web: Bool
    public var php: Bool
    public var mysql: Bool

    public static let allStopped = ServiceStatus(webServer: nil, web: false, php: false, mysql: false)

    public var allRunning: Bool { web && php && mysql }
    public var anyRunning: Bool { web || php || mysql }
}

/// Inicia e para os servidores. Equivale ao par `MAMP`/`MAMPTaskWrapper` do MAMP, mas usando
/// os binários do Homebrew com configs próprias. Todos os métodos bloqueiam; chame fora da main thread.
public struct ServerController: Sendable {
    public let paths: Paths
    public let installation: Installation
    public typealias Log = @Sendable (String) -> Void

    public init(paths: Paths, installation: Installation) {
        self.paths = paths
        var installation = installation
        // O phpMyAdmin instalado pelo LAMP-ON tem prioridade sobre o do Homebrew.
        installation.phpMyAdminPath = PhpMyAdmin.installedPath(paths) ?? installation.phpMyAdminPath
        self.installation = installation
    }

    // MARK: Status

    public func status() -> ServiceStatus {
        let apache = installation.httpd != nil && ProcessSupport.livePid(pidFile: paths.httpdPid, executableName: "httpd") != nil
        let nginx = installation.nginx != nil && ProcessSupport.livePid(pidFile: paths.nginxPid, executableName: "nginx") != nil
        return ServiceStatus(
            webServer: apache ? .apache : nginx ? .nginx : nil,
            web: apache || nginx,
            php: ProcessSupport.livePid(pidFile: paths.phpFpmPid, executableName: "php-fpm") != nil,
            mysql: mysqlPid() != nil
        )
    }

    private func mysqlPid() -> pid_t? {
        ProcessSupport.livePid(pidFile: paths.mysqlPid, executableName: "mysqld")
            ?? ProcessSupport.livePid(pidFile: paths.mysqlPid, executableName: "mariadbd")
    }

    // MARK: Start

    public func context(for settings: Settings) throws -> RenderContext {
        let errors = settings.validationErrors()
        if !errors.isEmpty { throw ServerError(errors.joined(separator: "\n")) }
        let missing = installation.missingFormulas(for: settings)
        if !missing.isEmpty {
            throw ServerError("Faltam fórmulas do Homebrew: \(missing.joined(separator: ", ")).\nRode: \(Homebrew.installCommand(for: missing))")
        }
        guard let php = installation.php(named: settings.phpFormula),
              let mysql = installation.mysql(named: settings.mysqlFormula)
        else { throw ServerError("PHP ou MySQL não encontrado no Homebrew.") }
        return RenderContext(settings: settings, paths: paths, installation: installation, php: php, mysql: mysql)
    }

    /// Inicia o que não estiver rodando, na ordem MySQL → PHP-FPM → servidor web.
    public func startAll(_ settings: Settings, log: Log = { _ in }) throws {
        if settings.documentRoot == Settings.defaultDocumentRoot {
            try? FileManager.default.createDirectory(atPath: settings.documentRoot, withIntermediateDirectories: true)
        }
        let ctx = try context(for: settings)
        try ConfigRenderer.writeAll(ctx)
        let current = status()
        if !current.mysql { try startMySQL(ctx, log: log) }
        if !current.php { try startPHP(ctx, log: log) }
        if !current.web { try startWeb(ctx, log: log) }
        log("Servidores rodando em http://localhost:\(settings.webPort)/")
    }

    public func restartAll(_ settings: Settings, log: Log = { _ in }) throws {
        _ = try context(for: settings)
        stopAll(log: log)
        try startAll(settings, log: log)
    }

    private func ensurePortFree(_ port: Int, for name: String) throws {
        if ProcessSupport.isListening(port: port) {
            throw ServerError("A porta \(port) já está em uso por outro programa, então o \(name) não pode iniciar. Troque a porta nas Preferências ou feche o outro programa (o MAMP, por exemplo).")
        }
    }

    private func waitForPort(_ port: Int, name: String, logFile: String, timeout: TimeInterval) throws {
        let ok = ProcessSupport.waitUntil(timeout: timeout) { ProcessSupport.isListening(port: port) }
        if !ok {
            throw ServerError("O \(name) não respondeu na porta \(port).\n\(ProcessSupport.tail(logFile))")
        }
    }

    func startMySQL(_ ctx: RenderContext, log: Log) throws {
        let name = "\(ctx.mysql.name) \(ctx.mysql.version)"
        try ensurePortFree(ctx.settings.mysqlPort, for: name)
        let defaults = "--defaults-file=\(paths.myCnf)"
        let mysqld = ctx.mysql.path("bin/mysqld")
        let errorLog = paths.log("mysql_error.log")

        let isNewDataDir = !FileManager.default.fileExists(atPath: (paths.mysqlData as NSString).appendingPathComponent("mysql"))
        if isNewDataDir {
            log("Criando banco de dados inicial (\(name))…")
            let result: CommandResult
            if ctx.isMariaDB {
                let installDb = ["bin/mariadb-install-db", "bin/mysql_install_db"].map(ctx.mysql.path)
                    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ctx.mysql.path("bin/mariadb-install-db")
                result = try ProcessSupport.run(installDb, [defaults, "--auth-root-authentication-method=normal",
                                                            "--basedir=\(ctx.mysql.optPath)"], timeout: 180)
            } else {
                result = try ProcessSupport.run(mysqld, [defaults, "--initialize-insecure"], timeout: 180)
            }
            guard result.succeeded else {
                throw ServerError("Falha ao inicializar o MySQL:\n\(result.output)\n\(ProcessSupport.tail(errorLog))")
            }
        }

        log("Iniciando \(name) na porta \(ctx.settings.mysqlPort)…")
        _ = try ProcessSupport.spawnDetached(mysqld, [defaults], logPath: errorLog)
        try waitForPort(ctx.settings.mysqlPort, name: name, logFile: errorLog, timeout: 60)

        let marker = (paths.mysqlData as NSString).appendingPathComponent(".lampon-root-password")
        if !FileManager.default.fileExists(atPath: marker) {
            log("Definindo a senha do usuário root como \"\(MySQLDefaults.password)\"…")
            let client = ["bin/mysql", "bin/mariadb"].map(ctx.mysql.path)
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ctx.mysql.path("bin/mysql")
            let sql = "ALTER USER '\(MySQLDefaults.user)'@'localhost' IDENTIFIED BY '\(MySQLDefaults.password)';"
            let result = try ProcessSupport.run(client, [defaults, "-u", MySQLDefaults.user, "--skip-password", "-e", sql])
            if result.succeeded {
                FileManager.default.createFile(atPath: marker, contents: nil)
            } else {
                log("Aviso: não foi possível definir a senha do root: \(result.output)")
            }
        }
    }

    func startPHP(_ ctx: RenderContext, log: Log) throws {
        try ensurePortFree(ctx.settings.phpFpmPort, for: "PHP-FPM")
        log("Iniciando PHP-FPM \(ctx.php.version)…")
        let result = try ProcessSupport.run(ctx.php.path("sbin/php-fpm"), ["--fpm-config", paths.phpFpmConf])
        guard result.succeeded else {
            throw ServerError("Falha ao iniciar o PHP-FPM:\n\(result.output)\n\(ProcessSupport.tail(paths.log("php-fpm.log")))")
        }
        try waitForPort(ctx.settings.phpFpmPort, name: "PHP-FPM", logFile: paths.log("php-fpm.log"), timeout: 15)
    }

    func startWeb(_ ctx: RenderContext, log: Log) throws {
        let s = ctx.settings
        try ensurePortFree(s.webPort, for: s.webServer.displayName)
        log("Iniciando \(s.webServer.displayName) na porta \(s.webPort)…")
        switch s.webServer {
        case .apache:
            guard let httpd = installation.httpd else { throw ServerError("httpd não instalado.") }
            let binary = httpd.path("bin/httpd")
            let test = try ProcessSupport.run(binary, ["-t", "-f", paths.httpdConf])
            guard test.succeeded else { throw ServerError("Configuração do Apache inválida:\n\(test.output)") }
            let result = try ProcessSupport.run(binary, ["-f", paths.httpdConf, "-k", "start"])
            guard result.succeeded else { throw ServerError("Falha ao iniciar o Apache:\n\(result.output)") }
            try waitForPort(s.webPort, name: "Apache", logFile: paths.log("apache_error.log"), timeout: 15)
        case .nginx:
            guard let nginx = installation.nginx else { throw ServerError("nginx não instalado.") }
            let binary = nginx.path("bin/nginx")
            let args = ["-p", paths.nginxPrefix, "-c", paths.nginxConf]
            for dir in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"] {
                try FileManager.default.createDirectory(
                    atPath: (paths.nginxPrefix as NSString).appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            let test = try ProcessSupport.run(binary, args + ["-t"])
            guard test.succeeded else { throw ServerError("Configuração do Nginx inválida:\n\(test.output)") }
            let result = try ProcessSupport.run(binary, args)
            guard result.succeeded else { throw ServerError("Falha ao iniciar o Nginx:\n\(result.output)") }
            try waitForPort(s.webPort, name: "Nginx", logFile: paths.log("nginx_error.log"), timeout: 15)
        }
    }

    /// Reinicia só o servidor web (por exemplo, para publicar o phpMyAdmin recém-instalado).
    public func restartWeb(_ settings: Settings, log: Log = { _ in }) throws {
        let ctx = try context(for: settings)
        try ConfigRenderer.writeAll(ctx)
        stopProcesses([(paths.httpdPid, "httpd", "Apache"), (paths.nginxPid, "nginx", "Nginx")], log: log)
        try startWeb(ctx, log: log)
    }

    // MARK: Stop

    private func stopProcesses(_ list: [(pidFile: String, executable: String, label: String)], log: Log) {
        for (pidFile, executable, label) in list {
            if let pid = ProcessSupport.livePid(pidFile: pidFile, executableName: executable) {
                log("Parando \(label)…")
                if !ProcessSupport.terminate(pid, timeout: 10) {
                    ProcessSupport.terminate(pid, signal: SIGKILL, timeout: 2)
                }
                try? FileManager.default.removeItem(atPath: pidFile)
            }
        }
    }

    /// Para tudo o que o LAMP-ON iniciou, na ordem inversa do start.
    public func stopAll(log: Log = { _ in }) {
        stopProcesses([
            (paths.httpdPid, "httpd", "Apache"),
            (paths.nginxPid, "nginx", "Nginx"),
            (paths.phpFpmPid, "php-fpm", "PHP-FPM"),
        ], log: log)
        if let pid = mysqlPid() {
            log("Parando MySQL…")
            // SIGTERM faz um shutdown limpo do mysqld; pode demorar enquanto grava o buffer pool.
            if !ProcessSupport.terminate(pid, timeout: 60) {
                log("Aviso: o MySQL não parou em 60 s.")
            }
        }
        log("Servidores parados.")
    }
}
