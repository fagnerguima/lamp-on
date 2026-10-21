# LAMP-ON

Servidor local para macOS **arm64** no estilo do MAMP: um app nativo em SwiftUI (janela + menu na
barra) que inicia e para **Apache ou Nginx + PHP-FPM + MySQL/MariaDB** usando os binários do
Homebrew, com configurações próprias e sem mexer nas do Homebrew.

O comportamento foi estudado no MAMP 7.4 com o [REA](https://github.com/morluto/rea), em regime
clean-room: veja [docs/ESTUDO-MAMP.md](docs/ESTUDO-MAMP.md). Nenhum código ou binário do MAMP é usado.

> MAMP é marca registrada da appsolute GmbH. Apache, MySQL, PHP e Homebrew são marcas de seus
> respectivos donos. O LAMP-ON é um projeto independente, sem relação com nenhum deles.

## Requisitos

- macOS 14+ em Apple Silicon
- Xcode (ou Command Line Tools) com Swift 6
- [Homebrew](https://brew.sh) e as fórmulas:

```bash
brew install httpd nginx php mysql
```

Versões extras de PHP aparecem sozinhas no app (`brew install php@8.3`, ou o tap
`shivammathur/php` para versões antigas). `mariadb` e `mysql@x.y` também são detectados.
O botão **phpMyAdmin** do app baixa na primeira vez o pacote oficial *english* (só inglês, mais
leve), confere o SHA-256 publicado e abre `http://localhost:8080/phpMyAdmin/` já logado como
`root`. Esse endereço só aceita conexões da própria máquina. Se você já tiver
`brew install phpmyadmin`, ele também é usado.

## Compilar e rodar

```bash
./scripts/build-app.sh
```

```bash
open build/LAMP-ON.app
```

Para usar como app normal, arraste `build/LAMP-ON.app` para `/Applications`.

Testes:

```bash
swift test
```

## Como funciona

| Item | Padrão |
| --- | --- |
| Site | `http://localhost:8080/` (document root `~/LAMP-ON/htdocs`) |
| Página inicial | `http://localhost:8080/lampon/` (PHP, MySQL, phpinfo) |
| phpMyAdmin | `http://localhost:8080/phpMyAdmin/` (só local, login automático) |
| MySQL | `127.0.0.1:3306`, usuário `root`, senha `root` (como no MAMP), socket `/tmp/lampon-mysql.sock` |
| PHP-FPM | `127.0.0.1:9074`, usado por Apache (`mod_proxy_fcgi`) e Nginx |
| Pasta de dados | `~/LAMP-ON/` (veja abaixo) |

### A pasta `~/LAMP-ON`

Como a `/Applications/MAMP`, tudo fica numa pasta só, mas na sua pasta pessoal: não precisa de
administrador e entra no backup do Time Machine.

```text
~/LAMP-ON/
  htdocs/      document root padrão (dá para escolher outro nas Preferências)
  db/mysql/    bancos de dados do MySQL
  logs/        logs de Apache, Nginx, PHP e MySQL
  conf/        configs geradas a cada start (editar não adianta)
  tmp/         PIDs e temporários
  phpMyAdmin/  instalado pelo botão phpMyAdmin
```

Versões anteriores guardavam os dados em `~/Library/Application Support/LAMP-ON`. Na primeira
abertura, o app move banco, logs e phpMyAdmin para `~/LAMP-ON` e manda a pasta antiga para a Lixeira.

As portas padrão (8080/3306) foram escolhidas para rodar ao lado do MAMP; nas Preferências há um
botão para usar as mesmas do MAMP (8888/8889). As configs são regeradas a cada start, então
mudanças de porta, versão do PHP ou servidor web valem no próximo start (o app avisa e oferece
"Reiniciar agora").

### Linha de comando

O mesmo executável aceita comandos, usando as preferências salvas pelo app:

```bash
"build/LAMP-ON.app/Contents/MacOS/LampOn" status
```

`start`, `stop`, `restart`, `status` (sai com 0 quando tudo está rodando) e `install-phpmyadmin`.

## Estrutura

- `Sources/LampOnCore` — detecção do Homebrew, geração de configs, controle de processos
- `Sources/LampOn` — app SwiftUI e modo linha de comando
- `Tests/LampOnCoreTests` — testes (Swift Testing)
- `scripts/build-app.sh` — monta `build/LAMP-ON.app` (release, arm64, assinatura ad-hoc)
- `Resources/AppIcon-source.png` — arte do ícone (lampião com chapéu de cangaceiro em estilo flat, gerada no OpenArt);
  `swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.icns` refaz o `.icns`

## Limitações

- Só portas ≥ 1024 (portas 80/443 exigiriam um helper privilegiado).
- Sem SSL, virtual hosts ou troca de cache do PHP pela interface ainda.
- Assinatura ad-hoc: em outro Mac, o Gatekeeper vai pedir confirmação na primeira abertura.
