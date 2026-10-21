import AppKit
import LampOnCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("Geral", systemImage: "gearshape") }
            PortsTab().tabItem { Label("Portas", systemImage: "network") }
            PHPTab().tabItem { Label("PHP", systemImage: "chevron.left.forwardslash.chevron.right") }
            WebServerTab().tabItem { Label("Servidor web", systemImage: "globe") }
            MySQLTab().tabItem { Label("MySQL", systemImage: "cylinder.split.1x2") }
        }
        .frame(width: 520)
        .fixedSize()
    }
}

private struct GeneralTab: View {
    @Environment(ServerManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        Form {
            Toggle("Iniciar servidores ao abrir o LAMP-ON", isOn: $manager.settings.startServersOnLaunch)
            Toggle("Parar servidores ao sair do LAMP-ON", isOn: $manager.settings.stopServersOnQuit)
            Toggle("Abrir a página inicial ao iniciar", isOn: $manager.settings.openStartPageOnStart)
            LabeledContent("Pasta do LAMP-ON") {
                HStack {
                    Text(manager.paths.root).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Mostrar no Finder") { manager.revealDataFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PortsTab: View {
    @Environment(ServerManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        Form {
            Section {
                TextField("Servidor web", value: $manager.settings.webPort, format: .number.grouping(.never))
                TextField("MySQL", value: $manager.settings.mysqlPort, format: .number.grouping(.never))
                TextField("PHP-FPM (interna)", value: $manager.settings.phpFpmPort, format: .number.grouping(.never))
            } footer: {
                let errors = manager.settings.validationErrors().filter { $0.contains("porta") || $0.contains("portas") }
                if !errors.isEmpty {
                    Text(errors.joined(separator: "\n")).foregroundStyle(.red)
                } else {
                    Text("Portas abaixo de 1024 (como 80) exigem privilégios de administrador e não são suportadas.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Padrão LAMP-ON (8080 / 3306)") {
                    manager.settings.webPort = Settings.alternatePorts.web
                    manager.settings.mysqlPort = Settings.alternatePorts.mysql
                }
                Button("Iguais ao MAMP (8888 / 8889)") {
                    manager.settings.webPort = Settings.mampPorts.web
                    manager.settings.mysqlPort = Settings.mampPorts.mysql
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PHPTab: View {
    @Environment(ServerManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        Form {
            if manager.installation.php.isEmpty {
                Text("Nenhum PHP com php-fpm no Homebrew. Rode: brew install php")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Versão do PHP", selection: $manager.settings.phpFormula) {
                    Text("Mais nova instalada (\(manager.installation.php[0].version))").tag(String?.none)
                    ForEach(manager.installation.php) { php in
                        Text("\(php.version) — \(php.name)").tag(Optional(php.name))
                    }
                }
                LabeledContent("php.ini") {
                    Text(phpIniPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section {
                Button("Procurar versões no Homebrew de novo") { manager.rescanHomebrew() }
            } footer: {
                Text("Outras versões: brew install php@8.4 (ou o tap shivammathur/php para versões antigas).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var phpIniPath: String {
        guard let php = manager.selectedPHP else { return "—" }
        let parts = php.version.split(separator: ".")
        let minor = parts.prefix(2).joined(separator: ".")
        return "\(manager.installation.prefix)/etc/php/\(minor)/php.ini"
    }
}

private struct WebServerTab: View {
    @Environment(ServerManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        Form {
            Picker("Servidor", selection: $manager.settings.webServer) {
                ForEach(WebServer.allCases) { server in
                    Text(label(for: server)).tag(server)
                }
            }
            .pickerStyle(.radioGroup)
            LabeledContent("Document root") {
                HStack {
                    Text(manager.settings.documentRoot)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Escolher…") { chooseDocumentRoot() }
                    if manager.settings.documentRoot != Settings.defaultDocumentRoot {
                        Button("Padrão") { manager.settings.documentRoot = Settings.defaultDocumentRoot }
                            .help("Usar \(Settings.defaultDocumentRoot)")
                    }
                    Button {
                        manager.revealDocumentRoot()
                    } label: { Image(systemName: "magnifyingglass") }
                        .help("Mostrar no Finder")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func label(for server: WebServer) -> String {
        let formula = server == .apache ? manager.installation.httpd : manager.installation.nginx
        return "\(server.displayName) " + (formula.map { $0.version } ?? "(não instalado)")
    }

    private func chooseDocumentRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: manager.settings.documentRoot)
        if panel.runModal() == .OK, let url = panel.url {
            manager.settings.documentRoot = url.path
        }
    }
}

private struct MySQLTab: View {
    @Environment(ServerManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        Form {
            if manager.installation.mysql.isEmpty {
                Text("Nenhum MySQL/MariaDB no Homebrew. Rode: brew install mysql")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Servidor", selection: $manager.settings.mysqlFormula) {
                    Text("Padrão (\(manager.installation.mysql[0].name) \(manager.installation.mysql[0].version))").tag(String?.none)
                    ForEach(manager.installation.mysql) { db in
                        Text("\(db.name) \(db.version)").tag(Optional(db.name))
                    }
                }
            }
            Section("Conexão") {
                LabeledContent("Host", value: "127.0.0.1")
                LabeledContent("Porta", value: String(manager.settings.mysqlPort))
                LabeledContent("Socket", value: manager.paths.mysqlSocket)
                LabeledContent("Usuário", value: MySQLDefaults.user)
                LabeledContent("Senha", value: MySQLDefaults.password)
            }
            Section {
                EmptyView()
            } footer: {
                Text("Os dados ficam em \(manager.paths.mysqlData). Trocar de MySQL para MariaDB (ou para uma versão mais antiga) com os mesmos dados pode não funcionar.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
