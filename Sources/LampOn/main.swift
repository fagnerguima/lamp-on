import Foundation
import LampOnCore

/// Modo linha de comando, útil para scripts: `LampOn start|stop|restart|status`.
/// Usa as mesmas preferências salvas pelo app.
func runCommandLine(_ command: String) -> Int32 {
    guard let prefix = Homebrew.detectPrefix() else {
        FileHandle.standardError.write(Data("Homebrew não encontrado.\n".utf8))
        return 1
    }
    let settings = SettingsStore().load()
    do {
        for message in try Migration.run(to: .default) { print(message) }
    } catch {
        FileHandle.standardError.write(Data("Falha na migração: \(error.localizedDescription)\n".utf8))
        return 1
    }
    let controller = ServerController(paths: .default, installation: Homebrew.scan(prefix: prefix))
    let log: ServerController.Log = { print($0) }
    do {
        switch command {
        case "start": try controller.startAll(settings, log: log)
        case "stop": controller.stopAll(log: log)
        case "restart": try controller.restartAll(settings, log: log)
        case "install-phpmyadmin":
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var failure: Error?
            Task {
                do { try await PhpMyAdmin.install(paths: .default, log: log) } catch { failure = error }
                done.signal()
            }
            done.wait()
            if let failure { throw failure }
            if controller.status().web {
                try ServerController(paths: .default, installation: Homebrew.scan(prefix: prefix)).restartWeb(settings, log: log)
            }
        case "status":
            let s = controller.status()
            print("web:   \(s.web ? "rodando (\(s.webServer!.displayName))" : "parado")")
            print("php:   \(s.php ? "rodando" : "parado")")
            print("mysql: \(s.mysql ? "rodando" : "parado")")
            return s.allRunning ? 0 : 3
        default:
            print("uso: LampOn [start|stop|restart|status|install-phpmyadmin]")
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("Erro: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
if let command = arguments.first {
    exit(runCommandLine(command))
} else {
    LampOnApp.main()
}
