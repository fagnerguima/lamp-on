# Estudo do MAMP 7.4 (clean-room)

Este documento registra **apenas o comportamento observável** do MAMP 7.4 instalado em
`/Applications/MAMP`, levantado com o [REA](https://github.com/morluto/rea) (`rea-agents` 6.7.0,
provedores `native-macos` e `rea-artifact-graph`) e com a leitura dos scripts e arquivos de
configuração em texto puro que o MAMP distribui. Nenhum código, binário, imagem ou texto do MAMP
foi copiado para o LAMP-ON: o app foi escrito do zero a partir desta especificação funcional.

## Comandos REA usados

```bash
rea inspect-macho /Applications/MAMP/MAMP.app --json
rea inspect-native-dispatch-metadata /Applications/MAMP/MAMP.app/Contents/MacOS/MAMP --json
rea decode-interface-builder /Applications/MAMP/MAMP.app --json
```

## O que o REA mostrou

### Binário

- `MAMP.app/Contents/MacOS/MAMP` é **universal (x86_64 + arm64)**, mínimo macOS 11.0, SDK 12.1.
- Todos os servidores empacotados já são arm64: `Library/bin/httpd`, `bin/php/php*/bin/php`,
  `Library/bin/mysql57/bin/mysqld`, `Library/bin/mysql80/bin/mysqld`.
- App Objective-C (sem metadados Swift). Dependências: Cocoa/AppKit, WebKit (tour e banners),
  Security, SystemConfiguration, IOKit, Carbon, e frameworks próprios `MampKit` e `MAMPAboutWindow`.
- Importa `NSTask`: os servidores são iniciados como processos filhos.

### Arquitetura (metadados Objective-C)

| Classe | Papel inferido |
| --- | --- |
| `MAMP` (130 métodos) | Controlador principal: start/stop, portas, versão do PHP, servidor web, MySQL, preferências, nuvem |
| `MAMPTaskWrapper` | Embrulho de `NSTask` (`initWithController:toolPath:arguments:`, `startProcess`, `stopProcess`) |
| `MampApplicationDelegate` | `applicationShouldTerminate:` (para os servidores ao sair), `applicationDidFinishLaunching:` |
| `MampPortFormatter` | Validação de porta digitada |
| `CloudPopoverController`, `InfoLoader`, `CkoGlobal` | Nuvem/Dropbox, telemetria e licença (fora do escopo) |

Seletores relevantes do controlador principal: `isApacheRunning`, `isNginxRunning`,
`isMySQLRunning`, `areAllServersRunning`, `startServersClicked:`, `stopServersClicked:`,
`phpVersionSelected:`, `webserverSelected:`, `mysqlVersionSelected:`, `resetDefaultPorts:`,
`resetMampPorts:`, `selectDocumentRoot:`, `revealDocumentRoot:`, `openStartPage:`,
`selectOPcache:`/`selectAPC:`/`selectPhpCacheOff:`, `mysqlWindowCheck:`/`Repair:`/`Upgrade:` e um
`stateTimer` (verificação periódica do estado).

### Interface (nibs decodificados)

- Janela principal com barra de ferramentas: **Start/Stop** (com indicador de progresso),
  **WebStart** (abre a página inicial), Preferências, Sair.
- Preferências em abas (`prefsSegmentedControl` + `tabView`):
  - **Geral**: iniciar servidores ao abrir, parar ao sair, abrir a página inicial ao iniciar.
  - **Portas**: Apache, Nginx, MySQL, com botões "portas padrão" e "portas MAMP" (8888/8889).
  - **PHP**: versão e cache (Off/APC/OPcache).
  - **Servidor web**: Apache ou Nginx + document root (escolher/revelar no Finder).
  - **MySQL**: versão 5.7 ou 8.0.
- Menu "Servidores" com Iniciar/Parar.

## O que os scripts e configs mostraram

- `bin/start.sh` = `startMysql.sh` + `startApache.sh`; Apache via `apachectl start/stop`.
- MySQL: `mysqld_safe --port=8889 --socket=.../tmp/mysql/mysql.sock --pid-file=... --log-error=...`;
  ramo (57/80) lido de `tmp/mysql/.mysqlBranch`; parada com `mysqladmin -u root -proot shutdown`
  (credenciais padrão `root`/`root`).
- Nginx: `spawn-fcgi` com o `php-cgi` da versão escolhida + `nginxctl start`.
- Apache 7.x usa `mod_fastcgi` apontando para `fcgi-bin/php.fcgi`, um wrapper **regerado a cada
  start** que faz `exec` do `php-cgi` da versão selecionada (é assim que a troca de versão funciona).
- Preferências ficam em `defaults` do domínio `de.appsolute.MAMP`: `apachePort`, `nginxPort`,
  `mySqlPort`, `phpVersion`, `mysqlBranch`, `userRootDirectory`, `startServers`, `stopServers`,
  `openPage`.
- O `httpd.conf` local já recebeu um ajuste manual com
  `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` no `FastCgiServer` (problema conhecido de fork com
  Objective-C no macOS); o LAMP-ON define essa variável ao iniciar o PHP-FPM.

## Decisões do LAMP-ON a partir disso

| MAMP | LAMP-ON |
| --- | --- |
| Binários próprios em `/Applications/MAMP/Library` | Binários arm64 do Homebrew (`/opt/homebrew`) |
| `mod_fastcgi` / `spawn-fcgi` + `php-cgi` | **PHP-FPM** em `127.0.0.1`, usado igualmente por Apache (`mod_proxy_fcgi`) e Nginx |
| Wrapper `php.fcgi` regerado | Configs de Apache, Nginx, PHP-FPM e MySQL **regeradas a cada start** em `~/LAMP-ON/conf` |
| Pasta única `/Applications/MAMP` (htdocs, db, logs, conf…) | Pasta única `~/LAMP-ON` com a mesma ideia, na pasta pessoal (sem precisar de administrador) |
| Configs dentro do bundle/instalação | Nada do Homebrew é alterado: cada servidor roda com `-f`/`-c`/`--defaults-file` próprio |
| MySQL 5.7/8.0 | Qualquer `mysql`, `mysql@x.y` ou `mariadb` instalado; usuário `root`/`root` como no MAMP |
| Helper privilegiado para portas < 1024 | Fora do MVP: só portas ≥ 1024 |
| Nuvem, licença, banners, tour | Fora do escopo |
