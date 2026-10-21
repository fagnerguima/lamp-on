import Foundation
import Testing
@testable import LampOnCore

@Suite struct HomebrewTests {
    @Test func recognizesFormulaNames() {
        #expect(Homebrew.isPHPFormula("php"))
        #expect(Homebrew.isPHPFormula("php@8.3"))
        #expect(!Homebrew.isPHPFormula("phpmyadmin"))
        #expect(Homebrew.isMySQLFormula("mysql"))
        #expect(Homebrew.isMySQLFormula("mysql@8.4"))
        #expect(Homebrew.isMySQLFormula("mariadb@11"))
        #expect(!Homebrew.isMySQLFormula("mysql-client"))
    }

    @Test func stripsRevisionSuffix() {
        #expect(Homebrew.stripRevision("8.5.11_1") == "8.5.11")
        #expect(Homebrew.stripRevision("2.4.69") == "2.4.69")
    }

    @Test func scansFakePrefix() throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent("brew-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: prefix) }

        func install(_ name: String, _ version: String, _ executables: [String]) throws {
            let cellar = "\(prefix)/Cellar/\(name)/\(version)"
            for exe in executables {
                let path = "\(cellar)/\(exe)"
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                fm.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            }
            try fm.createDirectory(atPath: "\(prefix)/opt", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: "\(prefix)/opt/\(name)", withDestinationPath: "../Cellar/\(name)/\(version)")
        }
        try install("php", "8.5.11_1", ["sbin/php-fpm"])
        try install("php@8.3", "8.3.35", ["sbin/php-fpm"])
        try install("httpd", "2.4.69_1", ["bin/httpd"])
        try install("mariadb", "11.8.2", ["bin/mysqld"])
        try install("mysql", "9.4.0", ["bin/mysqld"])
        try install("phpmyadmin", "5.2.2", ["share/phpmyadmin/index.php"])
        // Alias que o Homebrew cria para a versão principal.
        try fm.createSymbolicLink(atPath: "\(prefix)/opt/php@8.5", withDestinationPath: "../Cellar/php/8.5.11_1")

        let found = Homebrew.scan(prefix: prefix)
        #expect(found.php.map(\.name) == ["php", "php@8.3"])
        #expect(found.php.first?.version == "8.5.11")
        #expect(found.httpd?.version == "2.4.69")
        #expect(found.nginx == nil)
        #expect(found.mysql.map(\.name) == ["mysql", "mariadb"])
        #expect(found.phpMyAdminPath == "\(prefix)/opt/phpmyadmin/share/phpmyadmin")
        #expect(found.php(named: "php@8.3")?.version == "8.3.35")
        #expect(found.php(named: "php@7.4")?.name == "php")

        var settings = Settings()
        settings.webServer = .nginx
        #expect(found.missingFormulas(for: settings) == ["nginx"])
    }
}

@Suite struct SettingsTests {
    @Test func defaultsAvoidMAMPPorts() {
        let s = Settings()
        #expect(s.webPort == 8080)
        #expect(s.mysqlPort == 3306)
        #expect(s.webPort != Settings.mampPorts.web)
    }

    @Test func rejectsPrivilegedAndDuplicatePorts() {
        var s = Settings()
        s.documentRoot = NSTemporaryDirectory()
        #expect(s.validationErrors().isEmpty)
        s.webPort = 80
        #expect(s.validationErrors().contains { $0.contains("80") })
        s.webPort = s.mysqlPort
        #expect(s.validationErrors().contains { $0.contains("diferentes") })
    }

    @Test func decodesPartialJSON() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"webPort": 9999, "webServer": "nginx"}"#.utf8))
        #expect(s.webPort == 9999)
        #expect(s.webServer == .nginx)
        #expect(s.mysqlPort == Settings.alternatePorts.mysql)
        #expect(s.stopServersOnQuit)
    }
}

@Suite struct ConfigRendererTests {
    func context(webServer: WebServer = .apache) -> RenderContext {
        var settings = Settings()
        settings.webServer = webServer
        settings.webPort = 8080
        settings.mysqlPort = 3307
        settings.documentRoot = "/Users/eu/Meus Sites"
        let prefix = "/opt/homebrew"
        let php = Formula(name: "php@8.3", version: "8.3.35", optPath: "\(prefix)/opt/php@8.3")
        let mysql = Formula(name: "mysql", version: "9.4.0", optPath: "\(prefix)/opt/mysql")
        let install = Installation(
            prefix: prefix,
            httpd: Formula(name: "httpd", version: "2.4.69", optPath: "\(prefix)/opt/httpd"),
            nginx: Formula(name: "nginx", version: "1.31.7", optPath: "\(prefix)/opt/nginx"),
            php: [php], mysql: [mysql]
        )
        return RenderContext(settings: settings, paths: Paths(root: "/Users/eu/Library/Application Support/LAMP-ON"),
                             installation: install, php: php, mysql: mysql)
    }

    @Test func apacheQuotesPathsAndProxiesPHP() {
        let ctx = context()
        let conf = ConfigRenderer.httpdConf(ctx, httpd: ctx.installation.httpd!)
        #expect(conf.contains("Listen 8080"))
        #expect(conf.contains(#"DocumentRoot "/Users/eu/Meus Sites""#))
        #expect(conf.contains(#"PidFile "/Users/eu/Library/Application Support/LAMP-ON/tmp/httpd.pid""#))
        #expect(conf.contains(#"SetHandler "proxy:fcgi://127.0.0.1:9074""#))
        #expect(conf.contains("mod_mpm_prefork.so"))
        #expect(!conf.contains("phpMyAdmin"))
    }

    @Test func nginxPassesPHPToFPM() {
        let conf = ConfigRenderer.nginxConf(context(webServer: .nginx))
        #expect(conf.contains("listen 8080;"))
        #expect(conf.contains(#"root "/Users/eu/Meus Sites";"#))
        #expect(conf.contains("fastcgi_pass 127.0.0.1:9074;"))
        // Chaves balanceadas = config sintaticamente fechada.
        #expect(conf.filter { $0 == "{" }.count == conf.filter { $0 == "}" }.count)
    }

    @Test func phpConnectsToOwnMySQLByDefault() {
        let conf = ConfigRenderer.phpFpmConf(context())
        #expect(conf.contains("php_value[mysqli.default_socket] = /tmp/lampon-mysql.sock"))
        #expect(conf.contains("php_value[pdo_mysql.default_socket] = /tmp/lampon-mysql.sock"))
        #expect(conf.contains("php_value[mysqli.default_port] = 3307"))
    }

    @Test func mysqlUsesOwnDataDirAndPort() {
        let conf = ConfigRenderer.myCnf(context())
        #expect(conf.contains(#"datadir = "/Users/eu/Library/Application Support/LAMP-ON/db/mysql""#))
        #expect(conf.contains("port = 3307"))
        #expect(conf.contains("bind-address = 127.0.0.1"))
    }

    @Test func phpMyAdminIsLocalOnlyWithAutoLogin() {
        var ctx = context()
        ctx.installation.phpMyAdminPath = "/Users/eu/Library/Application Support/LAMP-ON/phpmyadmin"
        let apache = ConfigRenderer.httpdConf(ctx, httpd: ctx.installation.httpd!)
        #expect(apache.contains(#"Alias /phpMyAdmin "/Users/eu/Library/Application Support/LAMP-ON/phpmyadmin""#))
        #expect(apache.contains("Require local"))
        ctx.settings.webServer = .nginx
        let nginx = ConfigRenderer.nginxConf(ctx)
        #expect(nginx.contains("location ^~ /phpMyAdmin/"))
        #expect(nginx.contains("deny all;"))
        #expect(nginx.filter { $0 == "{" }.count == nginx.filter { $0 == "}" }.count)

        let php = PhpMyAdmin.configPHP(ctx, blowfishSecret: "s3cr3t'x")
        #expect(php.contains("$cfg['Servers'][1]['auth_type'] = 'config';"))
        #expect(php.contains("$cfg['Servers'][1]['port'] = '3307';"))
        #expect(php.contains(#"'s3cr3t\'x'"#))
    }

    @Test func startPageConfigMatchesSettings() throws {
        let json = StartPage.configJSON(context())
        let cfg = try JSONDecoder().decode(StartPage.Config.self, from: Data(json.utf8))
        #expect(cfg.mysqlPort == 3307)
        #expect(cfg.phpFormula == "php@8.3")
        #expect(cfg.mysqlUser == "root")
    }
}

@Suite struct MigrationTests {
    @Test func movesUserDataAndDiscardsLegacyFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("migr-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        let legacy = "\(base)/Application Support/MampMeu"
        func make(_ relative: String, _ content: String = "x") throws {
            let path = "\(legacy)/\(relative)"
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try make("data/mysql/mysql/user.ibd")
        try make("data/mysql/.mampmeu-root-password")
        try make("logs/mysql_error.log", "log antigo")
        try make("phpmyadmin/index.php")
        try make("conf/phpmyadmin-secret", String(repeating: "a", count: 32))
        try make("conf/httpd.conf")
        try make("run/httpd.pid", "999999")

        let paths = Paths(root: "\(base)/LAMP-ON")
        var discarded: [String] = []
        let messages = try Migration.run(to: paths, from: [legacy, "\(base)/nao-existe"]) {
            discarded.append($0)
            try fm.removeItem(atPath: $0)
        }

        #expect(fm.fileExists(atPath: "\(paths.mysqlData)/mysql/user.ibd"))
        #expect(fm.fileExists(atPath: "\(paths.mysqlData)/.lampon-root-password"))
        #expect(try String(contentsOfFile: paths.log("mysql_error.log"), encoding: .utf8) == "log antigo")
        #expect(fm.fileExists(atPath: "\(paths.phpMyAdmin)/index.php"))
        #expect(fm.fileExists(atPath: "\(paths.conf)/phpmyadmin-secret"))
        #expect(fm.fileExists(atPath: paths.htdocs))
        #expect(discarded == [legacy])
        #expect(messages.count == 1)
    }

    @Test func keepsLegacyFolderWhenDestinationHasData() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("migr-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        let legacy = "\(base)/old"
        try fm.createDirectory(atPath: "\(legacy)/data/mysql/mysql", withIntermediateDirectories: true)
        let paths = Paths(root: "\(base)/LAMP-ON")
        try fm.createDirectory(atPath: "\(paths.mysqlData)/mysql", withIntermediateDirectories: true)

        let messages = try Migration.run(to: paths, from: [legacy]) { _ in Issue.record("não deveria descartar") }
        #expect(fm.fileExists(atPath: "\(legacy)/data/mysql/mysql"))
        #expect(messages.first?.contains("parcial") == true)
    }

    @Test func doesNothingWithoutLegacyFolder() throws {
        let paths = Paths(root: NSTemporaryDirectory() + "lampon-\(UUID().uuidString)")
        #expect(try Migration.run(to: paths, from: ["/caminho/que/nao/existe"]) { _ in }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.root))
    }
}

@Suite struct ProcessSupportTests {
    @Test func runCapturesOutputAndStatus() throws {
        let ok = try ProcessSupport.run("/bin/sh", ["-c", "echo olá; echo erro >&2"])
        #expect(ok.succeeded)
        #expect(ok.output.contains("olá"))
        #expect(ok.output.contains("erro"))
        let fail = try ProcessSupport.run("/bin/sh", ["-c", "exit 3"])
        #expect(fail.status == 3)
    }

    @Test func runDoesNotHangOnBackgroundChildren() throws {
        // Simula um daemon que herda a saída e continua vivo depois que o pai sai.
        let start = Date()
        _ = try ProcessSupport.run("/bin/sh", ["-c", "sleep 5 & echo pronto"], timeout: 4)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func livePidChecksExecutableName() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "\(getpid())".write(toFile: file, atomically: true, encoding: .utf8)
        let me = (ProcessSupport.executablePath(of: getpid())! as NSString).lastPathComponent
        #expect(ProcessSupport.livePid(pidFile: file, executableName: me) == getpid())
        #expect(ProcessSupport.livePid(pidFile: file, executableName: "httpd") == nil)
    }

    @Test func detectsListeningPort() throws {
        #expect(!ProcessSupport.isListening(port: 1))
    }
}
