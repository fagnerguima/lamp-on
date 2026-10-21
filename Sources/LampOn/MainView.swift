import LampOnCore
import SwiftUI

struct MainView: View {
    @Environment(ServerManager.self) private var manager
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !manager.missingFormulas.isEmpty {
                MissingFormulasBox()
            }

            VStack(spacing: 0) {
                StatusRow(title: manager.settings.webServer.displayName,
                          detail: webDetail,
                          running: manager.status.web)
                Divider()
                StatusRow(title: "PHP-FPM",
                          detail: manager.selectedPHP.map { "\($0.version) · \($0.name)" } ?? "não instalado",
                          running: manager.status.php)
                Divider()
                StatusRow(title: manager.selectedMySQL?.name.hasPrefix("mariadb") == true ? "MariaDB" : "MySQL",
                          detail: manager.selectedMySQL.map { "\($0.version) · porta \(manager.settings.mysqlPort)" } ?? "não instalado",
                          running: manager.status.mysql)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            if manager.needsRestart {
                Banner(systemImage: "arrow.clockwise.circle", tint: .orange,
                       text: "As preferências mudaram. Reinicie os servidores para aplicar.") {
                    Button("Reiniciar agora") { manager.restart() }
                }
            }

            if let error = manager.lastError {
                Banner(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error) {
                    Button("Fechar") { manager.dismissError() }
                }
            }

            controls

            DisclosureGroup("Registro", isExpanded: $showLog) {
                LogView(lines: manager.log)
                    .frame(height: 140)
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var webDetail: String {
        let server = manager.settings.webServer == .apache ? manager.installation.httpd : manager.installation.nginx
        guard let server else { return "não instalado" }
        return "\(server.version) · porta \(manager.settings.webPort)"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(manager.status.anyRunning ? Color.green : Color.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("LAMP-ON").font(.title2.weight(.semibold))
                Text(manager.isBusy ? manager.busyMessage : summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var summary: String {
        if manager.status.allRunning { return "Rodando em localhost:\(manager.settings.webPort)" }
        if manager.status.anyRunning { return "Parcialmente rodando" }
        return "Servidores parados"
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                manager.toggle()
            } label: {
                Label(manager.status.anyRunning ? "Parar" : "Iniciar",
                      systemImage: manager.status.anyRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.status.anyRunning ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(manager.isBusy || (!manager.status.anyRunning && !manager.missingFormulas.isEmpty))

            Button("Página inicial") { manager.openStartPage() }
                .controlSize(.large)
                .disabled(!manager.status.web)
                .contextMenu {
                    Button("Copiar endereço") { manager.copyStartPageURL() }
                }
            Button("phpMyAdmin") { manager.openPhpMyAdmin() }
                .controlSize(.large)
                .disabled(manager.isBusy || (manager.hasPhpMyAdmin && !manager.status.web))
                .help(manager.hasPhpMyAdmin ? "Abrir o phpMyAdmin (login automático como root)" : "Baixar e instalar o phpMyAdmin (english)")
            Button {
                manager.revealDocumentRoot()
            } label: { Image(systemName: "folder") }
                .controlSize(.large)
                .accessibilityLabel("Document root")
                .help("Mostrar o document root no Finder")
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .controlSize(.large)
                .accessibilityLabel("Preferências")
                .help("Preferências")
        }
    }
}

struct StatusRow: View {
    let title: String
    let detail: String
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? "rodando" : "parado")
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions.controlSize(.small)
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MissingFormulasBox: View {
    @Environment(ServerManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Faltam componentes do Homebrew", systemImage: "shippingbox")
                .font(.callout.weight(.semibold))
            if manager.brewPrefix == nil {
                Text("O Homebrew não foi encontrado. Instale em brew.sh e depois rode o comando abaixo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(Homebrew.installCommand(for: manager.missingFormulas))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copiar") { manager.copyInstallCommand() }
                Button("Procurar de novo") { manager.rescanHomebrew() }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line).id(index)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}
