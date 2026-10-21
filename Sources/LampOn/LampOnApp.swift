import AppKit
import LampOnCore
import SwiftUI

struct LampOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var manager = ServerManager.shared

    var body: some Scene {
        Window("LAMP-ON", id: "main") {
            MainView()
                .environment(manager)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Servidores") {
                Button(manager.status.anyRunning ? "Parar servidores" : "Iniciar servidores") { manager.toggle() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(manager.isBusy)
                Button("Reiniciar servidores") { manager.restart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(manager.isBusy || !manager.status.anyRunning)
                Divider()
                Button("Abrir página inicial") { manager.openStartPage() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(manager.hasPhpMyAdmin ? "Abrir phpMyAdmin" : "Instalar phpMyAdmin") { manager.openPhpMyAdmin() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(manager.isBusy || (manager.hasPhpMyAdmin && !manager.status.web))
                LogsMenu()
            }
        }

        Settings {
            SettingsView()
                .environment(manager)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(manager)
        } label: {
            Image(systemName: manager.status.anyRunning ? "server.rack" : "rectangle.stack")
        }
    }
}

struct MenuBarContent: View {
    @Environment(ServerManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(manager.status.anyRunning ? "Rodando em localhost:\(manager.settings.webPort)" : "Servidores parados")
        Divider()
        Button(manager.status.anyRunning ? "Parar servidores" : "Iniciar servidores") { manager.toggle() }
            .disabled(manager.isBusy)
        Button("Abrir página inicial") { manager.openStartPage() }
            .disabled(!manager.status.web)
        Button("Copiar endereço da página inicial") { manager.copyStartPageURL() }
            .disabled(!manager.status.web)
        Button(manager.hasPhpMyAdmin ? "Abrir phpMyAdmin" : "Instalar phpMyAdmin") { manager.openPhpMyAdmin() }
            .disabled(manager.isBusy || (manager.hasPhpMyAdmin && !manager.status.web))
        Button("Mostrar document root") { manager.revealDocumentRoot() }
        LogsMenu()
        Divider()
        Button("Abrir LAMP-ON") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Preferências…") }
        Divider()
        Button("Sair do LAMP-ON") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Recebe o manager direto porque também é usado em `.commands`, onde o `environment` das cenas não chega.
struct LogsMenu: View {
    var manager = ServerManager.shared

    var body: some View {
        Menu("Logs") {
            ForEach(ServerManager.logFiles, id: \.self) { name in
                Button(name) { manager.openLog(name) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = ServerManager.shared
        if manager.settings.startServersOnLaunch, !manager.status.anyRunning, manager.missingFormulas.isEmpty {
            manager.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = ServerManager.shared
        guard manager.settings.stopServersOnQuit, manager.status.anyRunning, !manager.isBusy else { return .terminateNow }
        manager.stop {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // continua na barra de menus, como um servidor local deve.
    }
}
