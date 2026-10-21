import Foundation

/// Tudo o que é preciso para gerar as configs de uma execução.
public struct RenderContext: Sendable {
    public var settings: Settings
    public var paths: Paths
    public var installation: Installation
    public var php: Formula
    public var mysql: Formula

    public init(settings: Settings, paths: Paths, installation: Installation, php: Formula, mysql: Formula) {
        self.settings = settings
        self.paths = paths
        self.installation = installation
        self.php = php
        self.mysql = mysql
    }

    var isMariaDB: Bool { mysql.name.hasPrefix("mariadb") }
}

/// Gera as configs de Apache, Nginx, PHP-FPM e MySQL. São regeradas a cada start, como o MAMP faz
/// com o seu wrapper `php.fcgi`.
public enum ConfigRenderer {
    public static let startPageAlias = "/lampon"

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func httpdConf(_ ctx: RenderContext, httpd: Formula) -> String {
        let s = ctx.settings, p = ctx.paths
        // prefork em vez de event: com event, um filho com conexão keep-alive aberta ignorava o
        // SIGTERM por ~10 s e atrasava "parar servidores ao sair".
        let modules = [
            "mpm_prefork", "authn_core", "authz_core", "authz_host", "access_compat", "unixd",
            "mime", "log_config", "dir", "autoindex", "alias", "rewrite", "headers", "env",
            "setenvif", "proxy", "proxy_fcgi",
        ]
        let loads = modules
            .map { "LoadModule \($0)_module \(quoted(httpd.path("lib/httpd/modules/mod_\($0).so")))" }
            .joined(separator: "\n")
        let typesConfig = (ctx.installation.prefix as NSString).appendingPathComponent("etc/httpd/mime.types")
        let fcgi = "proxy:fcgi://127.0.0.1:\(s.phpFpmPort)"

        var conf = """
        # Gerado pelo LAMP-ON. Será sobrescrito no próximo start.
        ServerRoot \(quoted(httpd.optPath))
        Listen \(s.webPort)
        PidFile \(quoted(p.httpdPid))
        ServerName localhost:\(s.webPort)
        ServerAdmin you@localhost

        \(loads)

        TypesConfig \(quoted(typesConfig))
        AddType application/x-httpd-php .php .phtml
        DirectoryIndex index.php index.html index.htm

        ErrorLog \(quoted(p.log("apache_error.log")))
        LogLevel warn
        LogFormat "%h %l %u %t \\"%r\\" %>s %b" common
        CustomLog \(quoted(p.log("apache_access.log"))) common

        <Directory />
            AllowOverride None
            Require all denied
        </Directory>

        DocumentRoot \(quoted(s.documentRoot))
        <Directory \(quoted(s.documentRoot))>
            Options Indexes FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>

        <FilesMatch "\\.(php|phtml)$">
            SetHandler "\(fcgi)"
        </FilesMatch>

        <Files ".ht*">
            Require all denied
        </Files>

        Alias \(startPageAlias) \(quoted(p.startPage))
        <Directory \(quoted(p.startPage))>
            Require all granted
        </Directory>

        """
        if let pma = ctx.installation.phpMyAdminPath {
            conf += """

            # Só para conexões desta máquina: o phpMyAdmin entra no MySQL sem pedir senha.
            Alias \(PhpMyAdmin.urlPath) \(quoted(pma))
            Alias /phpmyadmin \(quoted(pma))
            <Directory \(quoted(pma))>
                Options FollowSymLinks
                AllowOverride All
                Require local
            </Directory>

            """
        }
        return conf
    }

    public static func nginxConf(_ ctx: RenderContext) -> String {
        let s = ctx.settings, p = ctx.paths
        let etc = (ctx.installation.prefix as NSString).appendingPathComponent("etc/nginx")
        let mime = quoted((etc as NSString).appendingPathComponent("mime.types"))
        let params = quoted((etc as NSString).appendingPathComponent("fastcgi_params"))
        let temp = { (name: String) in quoted((p.nginxPrefix as NSString).appendingPathComponent(name)) }
        let pass = "fastcgi_pass 127.0.0.1:\(s.phpFpmPort);"

        var conf = """
        # Gerado pelo LAMP-ON. Será sobrescrito no próximo start.
        worker_processes 1;
        pid \(quoted(p.nginxPid));
        error_log \(quoted(p.log("nginx_error.log"))) warn;

        events {
            worker_connections 256;
        }

        http {
            include \(mime);
            default_type application/octet-stream;
            access_log \(quoted(p.log("nginx_access.log")));
            sendfile on;
            client_max_body_size 128m;

            client_body_temp_path \(temp("client_body"));
            proxy_temp_path \(temp("proxy"));
            fastcgi_temp_path \(temp("fastcgi"));
            uwsgi_temp_path \(temp("uwsgi"));
            scgi_temp_path \(temp("scgi"));

            server {
                listen \(s.webPort);
                server_name localhost;
                root \(quoted(s.documentRoot));
                index index.php index.html index.htm;
                autoindex on;

                location / {
                    try_files $uri $uri/ =404;
                }

                location ~ \\.(php|phtml)$ {
                    try_files $uri =404;
                    include \(params);
                    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                    \(pass)
                }

                location ~ /\\.ht {
                    deny all;
                }

                location ^~ \(startPageAlias)/ {
                    alias \(quoted(p.startPage + "/"));
                    index index.php;
                    location ~ \\.php$ {
                        include \(params);
                        fastcgi_param SCRIPT_FILENAME $request_filename;
                        \(pass)
                    }
                }

        """
        if let pma = ctx.installation.phpMyAdminPath {
            conf += """

                    location = /phpMyAdmin {
                        return 301 /phpMyAdmin/;
                    }

                    # Só para conexões desta máquina: o phpMyAdmin entra no MySQL sem pedir senha.
                    location ^~ /phpMyAdmin/ {
                        allow 127.0.0.1;
                        allow ::1;
                        deny all;
                        alias \(quoted(pma + "/"));
                        index index.php;
                        location ~ \\.php$ {
                            include \(params);
                            fastcgi_param SCRIPT_FILENAME $request_filename;
                            \(pass)
                        }
                    }

            """
        }
        conf += """
            }
        }

        """
        return conf
    }

    public static func phpFpmConf(_ ctx: RenderContext) -> String {
        let s = ctx.settings, p = ctx.paths
        return """
        ; Gerado pelo LAMP-ON. Será sobrescrito no próximo start.
        [global]
        pid = \(quoted(p.phpFpmPid))
        error_log = \(quoted(p.log("php-fpm.log")))
        daemonize = yes

        [www]
        listen = 127.0.0.1:\(s.phpFpmPort)
        listen.allowed_clients = 127.0.0.1
        pm = dynamic
        pm.max_children = 10
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 4
        catch_workers_output = yes
        clear_env = no
        php_flag[display_errors] = on
        php_admin_flag[log_errors] = on
        php_admin_value[error_log] = \(quoted(p.log("php_error.log")))
        php_value[upload_max_filesize] = 128M
        php_value[post_max_size] = 128M
        php_value[memory_limit] = 512M
        ; Com DB_HOST "localhost" o PHP conecta pelo socket padrão; aponta para o MySQL do LAMP-ON.
        php_value[mysqli.default_socket] = \(p.mysqlSocket)
        php_value[pdo_mysql.default_socket] = \(p.mysqlSocket)
        php_value[mysqli.default_port] = \(s.mysqlPort)
        env[LAMPON_MYSQL_PORT] = \(s.mysqlPort)
        env[LAMPON_MYSQL_SOCKET] = \(p.mysqlSocket)

        """
    }

    public static func myCnf(_ ctx: RenderContext) -> String {
        let s = ctx.settings, p = ctx.paths
        return """
        # Gerado pelo LAMP-ON. Será sobrescrito no próximo start.
        [mysqld]
        datadir = \(quoted(p.mysqlData))
        port = \(s.mysqlPort)
        bind-address = 127.0.0.1
        socket = \(quoted(p.mysqlSocket))
        pid-file = \(quoted(p.mysqlPid))
        log-error = \(quoted(p.log("mysql_error.log")))
        loose-mysqlx = OFF

        [client]
        port = \(s.mysqlPort)
        socket = \(quoted(p.mysqlSocket))

        """
    }

    /// Escreve todos os arquivos necessários para a configuração atual.
    public static func writeAll(_ ctx: RenderContext, fileManager: FileManager = .default) throws {
        try ctx.paths.createDirectories(fileManager: fileManager)
        func write(_ content: String, _ path: String) throws {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        switch ctx.settings.webServer {
        case .apache:
            if let httpd = ctx.installation.httpd { try write(httpdConf(ctx, httpd: httpd), ctx.paths.httpdConf) }
        case .nginx:
            try write(nginxConf(ctx), ctx.paths.nginxConf)
        }
        try write(phpFpmConf(ctx), ctx.paths.phpFpmConf)
        try PhpMyAdmin.writeConfig(ctx)
        try write(myCnf(ctx), ctx.paths.myCnf)
        try write(Paths.readmeText, ctx.paths.readme)
        try write(StartPage.indexPHP, (ctx.paths.startPage as NSString).appendingPathComponent("index.php"))
        try write(StartPage.configJSON(ctx), (ctx.paths.startPage as NSString).appendingPathComponent("config.json"))
    }
}
