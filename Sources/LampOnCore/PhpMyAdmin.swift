import CryptoKit
import Foundation

/// phpMyAdmin próprio do LAMP-ON: o pacote oficial "english" (só inglês, mais leve que o
/// "all-languages"), instalado em `~/LAMP-ON/phpMyAdmin`.
public enum PhpMyAdmin {
    public static let urlPath = "/phpMyAdmin"
    /// Usada se a consulta da versão mais recente falhar.
    static let fallbackVersion = "5.2.3"
    static let versionURL = URL(string: "https://www.phpmyadmin.net/home_page/version.json")!

    static func zipURL(version: String) -> URL {
        URL(string: "https://files.phpmyadmin.net/phpMyAdmin/\(version)/phpMyAdmin-\(version)-english.zip")!
    }

    public static func installedPath(_ paths: Paths, fileManager: FileManager = .default) -> String? {
        let index = (paths.phpMyAdmin as NSString).appendingPathComponent("index.php")
        return fileManager.fileExists(atPath: index) ? paths.phpMyAdmin : nil
    }

    /// Lê a versão instalada do `package.json` que acompanha o pacote.
    public static func installedVersion(_ paths: Paths) -> String? {
        let url = URL(fileURLWithPath: paths.phpMyAdmin).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }

    static func latestVersion() async -> String {
        struct Info: Decodable { let version: String }
        guard let (data, _) = try? await URLSession.shared.data(from: versionURL),
              let info = try? JSONDecoder().decode(Info.self, from: data),
              info.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        else { return fallbackVersion }
        return info.version
    }

    /// Baixa, confere o SHA-256 publicado pelo projeto e instala (substituindo uma versão anterior).
    public static func install(paths: Paths, log: @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try paths.createDirectories()
        let version = await latestVersion()
        let zipURL = zipURL(version: version)
        log("Baixando phpMyAdmin \(version) (english)…")

        let (zipFile, response) = try await URLSession.shared.download(from: zipURL)
        defer { try? fm.removeItem(at: zipFile) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServerError("Falha ao baixar \(zipURL.absoluteString).")
        }

        let (shaData, shaResponse) = try await URLSession.shared.data(from: zipURL.appendingPathExtension("sha256"))
        guard (shaResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(decoding: shaData, as: UTF8.self).split(separator: " ").first.map(String.init)
        else { throw ServerError("Não foi possível obter o checksum do phpMyAdmin.") }
        let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw ServerError("O checksum do phpMyAdmin baixado não confere. Instalação cancelada.")
        }

        log("Instalando phpMyAdmin \(version)…")
        let staging = (paths.root as NSString).appendingPathComponent("phpmyadmin-staging")
        try? fm.removeItem(atPath: staging)
        defer { try? fm.removeItem(atPath: staging) }
        let unzip = try ProcessSupport.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, staging], timeout: 120)
        guard unzip.succeeded else { throw ServerError("Falha ao descompactar o phpMyAdmin:\n\(unzip.output)") }
        guard let folder = try fm.contentsOfDirectory(atPath: staging).first(where: { $0.hasPrefix("phpMyAdmin-") }) else {
            throw ServerError("Pacote do phpMyAdmin inesperado.")
        }
        try? fm.removeItem(atPath: paths.phpMyAdmin)
        try fm.moveItem(atPath: (staging as NSString).appendingPathComponent(folder), toPath: paths.phpMyAdmin)
        log("phpMyAdmin \(version) instalado.")
    }

    /// `config.inc.php` com login automático no MySQL do LAMP-ON, como o MAMP faz.
    /// Seguro porque o servidor web só libera `/phpMyAdmin` para conexões locais.
    public static func configPHP(_ ctx: RenderContext, blowfishSecret: String) -> String {
        func php(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        return """
        <?php
        // Gerado pelo LAMP-ON. Será sobrescrito no próximo start.
        declare(strict_types=1);

        $cfg['blowfish_secret'] = \(php(blowfishSecret));
        $cfg['Servers'][1]['auth_type'] = 'config';
        $cfg['Servers'][1]['host'] = '127.0.0.1';
        $cfg['Servers'][1]['port'] = \(php(String(ctx.settings.mysqlPort)));
        $cfg['Servers'][1]['user'] = \(php(MySQLDefaults.user));
        $cfg['Servers'][1]['password'] = \(php(MySQLDefaults.password));
        $cfg['Servers'][1]['AllowNoPassword'] = false;
        $cfg['TempDir'] = \(php(ctx.paths.phpMyAdminTemp));
        $cfg['PmaNoRelation_DisableWarning'] = true;
        $cfg['VersionCheck'] = false;
        $cfg['SendErrorReports'] = 'never';
        $cfg['DefaultLang'] = 'en';

        """
    }

    /// Segredo de 32 bytes para os cookies, criado uma vez e reaproveitado.
    static func blowfishSecret(_ paths: Paths) -> String {
        let file = (paths.conf as NSString).appendingPathComponent("phpmyadmin-secret")
        if let existing = try? String(contentsOfFile: file, encoding: .utf8), existing.count == 32 {
            return existing
        }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        let secret = String((0..<32).map { _ in alphabet.randomElement(using: &generator)! })
        try? secret.write(toFile: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        return secret
    }

    static func writeConfig(_ ctx: RenderContext) throws {
        guard installedPath(ctx.paths) != nil else { return }
        try FileManager.default.createDirectory(atPath: ctx.paths.phpMyAdminTemp, withIntermediateDirectories: true)
        let file = (ctx.paths.phpMyAdmin as NSString).appendingPathComponent("config.inc.php")
        try configPHP(ctx, blowfishSecret: blowfishSecret(ctx.paths)).write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}
