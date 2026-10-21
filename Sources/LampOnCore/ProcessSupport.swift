import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String

    public var succeeded: Bool { status == 0 }
}

public enum ProcessSupport {
    /// Variável que evita o crash de fork do Objective-C no macOS (o MAMP também a usa).
    static let forkSafetyEnvironment = ["OBJC_DISABLE_INITIALIZE_FORK_SAFETY": "YES"]

    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.merge(forkSafetyEnvironment) { _, new in new }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Executa um comando e espera ele terminar, capturando stdout e stderr juntos.
    ///
    /// A saída vai para um arquivo temporário em vez de um pipe: comandos que viram daemon
    /// (`httpd -k start`, `php-fpm`, `nginx`) deixam filhos com o pipe aberto e a leitura nunca
    /// chegaria ao fim.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lampon-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ServerError("\((executable as NSString).lastPathComponent) não terminou em \(Int(timeout)) s.")
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, output: text)
    }

    /// Inicia um processo que continua rodando sozinho, com saída anexada a um arquivo de log.
    public static func spawnDetached(_ executable: String, _ arguments: [String], logPath: String) throws -> Process {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        log.seekToEndOfFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    public static func readPid(_ path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return pid
    }

    /// Caminho do executável de um PID, ou `nil` se o processo não existe.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// PID vivo lido do arquivo, conferindo que o executável é o esperado (PID files
    /// antigos podem apontar para outro processo depois de um reboot).
    public static func livePid(pidFile: String, executableName: String) -> pid_t? {
        guard let pid = readPid(pidFile), let path = executablePath(of: pid) else { return nil }
        let name = (path as NSString).lastPathComponent
        return name == executableName ? pid : nil
    }

    /// Envia `signal` e espera o processo sair. Retorna `true` se ele saiu.
    @discardableResult
    public static func terminate(_ pid: pid_t, signal: Int32 = SIGTERM, timeout: TimeInterval) -> Bool {
        guard kill(pid, signal) == 0 else { return errno == ESRCH }
        return waitUntil(timeout: timeout) { kill(pid, 0) != 0 && errno == ESRCH }
    }

    public static func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }

    /// `true` se algo aceita conexões TCP em 127.0.0.1:`port`.
    public static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Últimas linhas de um log, para mensagens de erro.
    public static func tail(_ path: String, lines: Int = 12) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

public struct ServerError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
