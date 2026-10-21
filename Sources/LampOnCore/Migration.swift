import Darwin
import Foundation

/// Traz para `~/LAMP-ON` os dados de versões anteriores, que ficavam em
/// `~/Library/Application Support/LAMP-ON` (e, antes do nome LAMP-ON, `.../MampMeu`).
public enum Migration {
    public static var legacyRoots: [String] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["LAMP-ON", "MampMeu"].map { support.appendingPathComponent($0).path }
    }

    /// Move o que é do usuário (MySQL, logs, phpMyAdmin) e descarta a pasta antiga, cujo resto
    /// é refeito a cada start. Se algo já existir no destino, nada é sobrescrito e a pasta antiga fica.
    /// Retorna mensagens para o registro.
    @discardableResult
    public static func run(to paths: Paths,
                           from legacyRoots: [String] = Migration.legacyRoots,
                           fileManager: FileManager = .default,
                           discard: (String) throws -> Void = { try FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) }) throws -> [String] {
        var messages: [String] = []
        for legacy in legacyRoots where legacy != paths.root {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: legacy, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            func old(_ relative: String) -> String { (legacy as NSString).appendingPathComponent(relative) }

            stopLegacyServers(runDir: old("run"))
            try paths.createDirectories(fileManager: fileManager)
            var conflicts: [String] = []

            func move(_ source: String, to destination: String) throws {
                guard fileManager.fileExists(atPath: source) else { return }
                if isEmptyDirectory(destination, fileManager) { try fileManager.removeItem(atPath: destination) }
                if fileManager.fileExists(atPath: destination) {
                    conflicts.append(destination)
                    return
                }
                try fileManager.moveItem(atPath: source, toPath: destination)
            }

            try move(old("data/mysql"), to: paths.mysqlData)
            let oldMarker = (paths.mysqlData as NSString).appendingPathComponent(".mampmeu-root-password")
            if fileManager.fileExists(atPath: oldMarker) {
                try? fileManager.moveItem(atPath: oldMarker, toPath: (paths.mysqlData as NSString).appendingPathComponent(".lampon-root-password"))
            }
            try move(old("phpmyadmin"), to: paths.phpMyAdmin)
            try move(old("conf/phpmyadmin-secret"), to: (paths.conf as NSString).appendingPathComponent("phpmyadmin-secret"))
            for name in (try? fileManager.contentsOfDirectory(atPath: old("logs"))) ?? [] {
                try move(old("logs/\(name)"), to: paths.log(name))
            }

            if conflicts.isEmpty {
                try discard(legacy)
                messages.append("Dados movidos de \(legacy) para \(paths.root).")
            } else {
                messages.append("Migração parcial de \(legacy): já existia \(conflicts.joined(separator: ", ")). A pasta antiga foi mantida.")
            }
        }
        return messages
    }

    static func isEmptyDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return ((try? fileManager.contentsOfDirectory(atPath: path)) ?? ["?"]).isEmpty
    }

    /// Servidores iniciados por uma versão anterior usam PIDs da pasta antiga; precisam parar
    /// antes de mover os dados (principalmente o MySQL).
    static func stopLegacyServers(runDir: String) {
        for (file, executables, timeout) in [
            ("httpd.pid", ["httpd"], 10.0),
            ("nginx.pid", ["nginx"], 10.0),
            ("php-fpm.pid", ["php-fpm"], 10.0),
            ("mysql.pid", ["mysqld", "mariadbd"], 60.0),
        ] {
            let pidFile = (runDir as NSString).appendingPathComponent(file)
            for executable in executables {
                if let pid = ProcessSupport.livePid(pidFile: pidFile, executableName: executable) {
                    ProcessSupport.terminate(pid, timeout: timeout)
                }
            }
        }
    }
}
