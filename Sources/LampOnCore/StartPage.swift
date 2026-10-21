import Foundation

/// Página inicial servida em `/lampon/` (o equivalente ao botão WebStart do MAMP).
public enum StartPage {
    public struct Config: Codable, Equatable, Sendable {
        public var webServer: String
        public var webPort: Int
        public var phpFormula: String
        public var phpVersion: String
        public var mysqlFormula: String
        public var mysqlVersion: String
        public var mysqlPort: Int
        public var mysqlSocket: String
        public var mysqlUser: String
        public var mysqlPassword: String
        public var documentRoot: String
        public var phpMyAdmin: Bool
    }

    public static func config(_ ctx: RenderContext) -> Config {
        Config(
            webServer: ctx.settings.webServer.displayName,
            webPort: ctx.settings.webPort,
            phpFormula: ctx.php.name,
            phpVersion: ctx.php.version,
            mysqlFormula: ctx.mysql.name,
            mysqlVersion: ctx.mysql.version,
            mysqlPort: ctx.settings.mysqlPort,
            mysqlSocket: ctx.paths.mysqlSocket,
            mysqlUser: MySQLDefaults.user,
            mysqlPassword: MySQLDefaults.password,
            documentRoot: ctx.settings.documentRoot,
            phpMyAdmin: ctx.installation.phpMyAdminPath != nil
        )
    }

    public static func configJSON(_ ctx: RenderContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(config(ctx))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static let indexPHP = #"""
    <?php
    $cfg = json_decode((string) @file_get_contents(__DIR__ . '/config.json'), true) ?: [];
    if (isset($_GET['phpinfo'])) { phpinfo(); exit; }

    $mysqlStatus = 'extensão mysqli indisponível';
    $mysqlOk = false;
    if (function_exists('mysqli_connect')) {
        mysqli_report(MYSQLI_REPORT_OFF);
        $db = @mysqli_connect('127.0.0.1', $cfg['mysqlUser'] ?? 'root', $cfg['mysqlPassword'] ?? 'root', '', (int) ($cfg['mysqlPort'] ?? 3306));
        if ($db) {
            $mysqlOk = true;
            $mysqlStatus = 'conectado — servidor ' . mysqli_get_server_info($db);
            mysqli_close($db);
        } else {
            $mysqlStatus = 'falhou: ' . mysqli_connect_error();
        }
    }
    function h($v) { return htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8'); }
    $docRoot = $cfg['documentRoot'] ?? '';
    $entries = [];
    if (is_dir($docRoot)) {
        foreach (scandir($docRoot) as $e) {
            if ($e[0] === '.') continue;
            $entries[] = ['name' => $e, 'dir' => is_dir("$docRoot/$e")];
        }
    }
    ?><!doctype html>
    <html lang="pt-BR">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>LAMP-ON</title>
    <style>
      :root { color-scheme: light dark; --bg: #f6f6f4; --card: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e3e3e0; --ok: #1f8f4e; --bad: #c4372c; --accent: #3d5afe; }
      @media (prefers-color-scheme: dark) { :root { --bg: #141416; --card: #1e1e21; --fg: #f2f2f2; --muted: #9a9aa0; --line: #2c2c30; --ok: #4cc27f; --bad: #ff6b5e; --accent: #8c9eff; } }
      * { box-sizing: border-box; }
      body { margin: 0; font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: var(--bg); color: var(--fg); }
      main { max-width: 880px; margin: 0 auto; padding: 40px 16px 64px; }
      h1 { font-size: 28px; margin: 0 0 4px; letter-spacing: -0.02em; }
      .sub { color: var(--muted); margin: 0 0 28px; }
      .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 14px; }
      .card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 18px; }
      .card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin: 0 0 10px; }
      dl { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; }
      dt { color: var(--muted); } dd { margin: 0; font-family: ui-monospace, Menlo, monospace; font-size: 13px; overflow-wrap: anywhere; }
      .ok { color: var(--ok); } .bad { color: var(--bad); }
      a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
      ul { list-style: none; margin: 0; padding: 0; columns: 2 220px; } li { padding: 2px 0; }
      .links a { display: inline-block; margin-right: 16px; }
    </style>
    </head>
    <body>
    <main>
      <h1>LAMP-ON está rodando</h1>
      <p class="sub"><?= h($cfg['webServer'] ?? '') ?> + PHP <?= h(PHP_VERSION) ?> + <?= h($cfg['mysqlFormula'] ?? 'MySQL') ?> <?= h($cfg['mysqlVersion'] ?? '') ?> · Homebrew · arm64</p>
      <div class="grid">
        <section class="card">
          <h2>PHP</h2>
          <dl>
            <dt>Versão</dt><dd><?= h(PHP_VERSION) ?> (<?= h($cfg['phpFormula'] ?? '') ?>)</dd>
            <dt>SAPI</dt><dd><?= h(PHP_SAPI) ?></dd>
            <dt>php.ini</dt><dd><?= h(php_ini_loaded_file() ?: '—') ?></dd>
            <dt>OPcache</dt><dd><?= function_exists('opcache_get_status') && @opcache_get_status(false) ? 'ativo' : 'inativo' ?></dd>
          </dl>
        </section>
        <section class="card">
          <h2>MySQL</h2>
          <dl>
            <dt>Status</dt><dd class="<?= $mysqlOk ? 'ok' : 'bad' ?>"><?= h($mysqlStatus) ?></dd>
            <dt>Host</dt><dd>127.0.0.1</dd>
            <dt>Porta</dt><dd><?= h($cfg['mysqlPort'] ?? '') ?></dd>
            <dt>Socket</dt><dd><?= h($cfg['mysqlSocket'] ?? '') ?></dd>
            <dt>Usuário</dt><dd><?= h($cfg['mysqlUser'] ?? '') ?></dd>
            <dt>Senha</dt><dd><?= h($cfg['mysqlPassword'] ?? '') ?></dd>
          </dl>
        </section>
      </div>
      <section class="card" style="margin-top:14px">
        <h2>Ferramentas</h2>
        <p class="links">
          <a href="?phpinfo=1">phpinfo()</a>
          <?php if (!empty($cfg['phpMyAdmin'])): ?><a href="/phpMyAdmin/">phpMyAdmin</a><?php endif; ?>
          <a href="/">Document root</a>
        </p>
      </section>
      <section class="card" style="margin-top:14px">
        <h2>Document root · <?= h($docRoot) ?></h2>
        <?php if ($entries): ?>
        <ul><?php foreach ($entries as $e): ?><li><a href="/<?= rawurlencode($e['name']) ?><?= $e['dir'] ? '/' : '' ?>"><?= h($e['name']) ?><?= $e['dir'] ? '/' : '' ?></a></li><?php endforeach; ?></ul>
        <?php else: ?><p class="sub" style="margin:0">Pasta vazia. Coloque seus projetos aqui.</p><?php endif; ?>
      </section>
    </main>
    </body>
    </html>
    """#
}

public enum MySQLDefaults {
    /// As mesmas credenciais padrão do MAMP, para que projetos existentes funcionem sem mudanças.
    public static let user = "root"
    public static let password = "root"
}
