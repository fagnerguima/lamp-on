import Foundation

/// Pasta única do LAMP-ON, no estilo de `/Applications/MAMP`:
///
///     ~/LAMP-ON/
///       htdocs/      document root padrão
///       db/mysql/    dados do MySQL
///       logs/        logs de Apache, Nginx, PHP e MySQL
///       conf/        configs geradas a cada start (e a página inicial)
///       tmp/         PIDs e arquivos temporários
///       phpMyAdmin/  instalado pelo botão phpMyAdmin
///
/// Nada é escrito nas pastas do Homebrew.
public struct Paths: Sendable, Equatable {
    public let root: String

    public init(root: String) {
        self.root = root
    }

    public static var `default`: Paths {
        Paths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LAMP-ON").path)
    }

    private func sub(_ component: String) -> String {
        (root as NSString).appendingPathComponent(component)
    }

    public var htdocs: String { sub("htdocs") }
    public var conf: String { sub("conf") }
    public var run: String { sub("tmp") }
    public var logs: String { sub("logs") }
    public var mysqlData: String { sub("db/mysql") }
    public var startPage: String { sub("conf/startpage") }
    public var nginxPrefix: String { sub("tmp/nginx") }
    public var phpMyAdmin: String { sub("phpMyAdmin") }
    public var phpMyAdminTemp: String { sub("tmp/phpmyadmin") }
    public var readme: String { sub("LEIA-ME.txt") }

    public var httpdConf: String { (conf as NSString).appendingPathComponent("httpd.conf") }
    public var nginxConf: String { (conf as NSString).appendingPathComponent("nginx.conf") }
    public var phpFpmConf: String { (conf as NSString).appendingPathComponent("php-fpm.conf") }
    public var myCnf: String { (conf as NSString).appendingPathComponent("my.cnf") }

    public var httpdPid: String { (run as NSString).appendingPathComponent("httpd.pid") }
    public var nginxPid: String { (run as NSString).appendingPathComponent("nginx.pid") }
    public var phpFpmPid: String { (run as NSString).appendingPathComponent("php-fpm.pid") }
    public var mysqlPid: String { (run as NSString).appendingPathComponent("mysql.pid") }
    /// Em `/tmp` porque sockets Unix não aceitam caminhos longos.
    public var mysqlSocket: String { "/tmp/lampon-mysql.sock" }

    public func log(_ name: String) -> String {
        (logs as NSString).appendingPathComponent(name)
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        for dir in [htdocs, conf, run, logs, mysqlData, startPage, nginxPrefix] {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    static let readmeText = """
    LAMP-ON — pasta de dados

    htdocs/      Coloque seus sites aqui (document root padrão).
    db/mysql/    Bancos de dados do MySQL. Pare os servidores antes de copiar ou mover.
    logs/        Logs de Apache, Nginx, PHP e MySQL.
    conf/        Configurações geradas a cada start: editar não adianta.
    tmp/         PIDs e arquivos temporários.
    phpMyAdmin/  phpMyAdmin instalado pelo app.

    Usuário do MySQL: root / senha: root
    """
}
