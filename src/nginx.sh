nginx_config() {
    is_nginx_site_file=$is_nginx_conf/${host}.conf
    case $1 in
    new)
        mkdir -p /etc/nginx/sites-enabled /etc/nginx/sites-available $is_nginx_conf
        # 创建主配置文件（如果不存在）
        if [[ ! -f /etc/nginx/nginx.conf ]] || [[ ! $(grep "include $is_nginx_conf" /etc/nginx/nginx.conf) ]]; then
            cat >/etc/nginx/nginx.conf <<-EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;

    gzip on;

    include $is_nginx_conf/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
EOF
        fi
        ;;
    *ws* | *http*)
        cat >${is_nginx_site_file} <<EOF
server {
    listen ${is_https_port} ssl http2;
    listen [::]:${is_https_port} ssl http2;
    server_name ${host};

    ssl_certificate /etc/nginx/ssl/${host}.crt;
    ssl_certificate_key /etc/nginx/ssl/${host}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location ${path} {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    include ${is_nginx_site_file}.add;
}

server {
    listen ${is_http_port};
    listen [::]:${is_http_port};
    server_name ${host};
    return 301 https://\$server_name\$request_uri;
}
EOF
        ;;
    *h2*)
        cat >${is_nginx_site_file} <<EOF
server {
    listen ${is_https_port} ssl http2;
    listen [::]:${is_https_port} ssl http2;
    server_name ${host};

    ssl_certificate /etc/nginx/ssl/${host}.crt;
    ssl_certificate_key /etc/nginx/ssl/${host}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location ${path} {
        grpc_pass grpc://127.0.0.1:${port};
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
    }

    include ${is_nginx_site_file}.add;
}

server {
    listen ${is_http_port};
    listen [::]:${is_http_port};
    server_name ${host};
    return 301 https://\$server_name\$request_uri;
}
EOF
        ;;
    *grpc*)
        cat >${is_nginx_site_file} <<EOF
server {
    listen ${is_https_port} ssl http2;
    listen [::]:${is_https_port} ssl http2;
    server_name ${host};

    ssl_certificate /etc/nginx/ssl/${host}.crt;
    ssl_certificate_key /etc/nginx/ssl/${host}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location /${path} {
        grpc_pass grpc://127.0.0.1:${port};
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
    }

    include ${is_nginx_site_file}.add;
}

server {
    listen ${is_http_port};
    listen [::]:${is_http_port};
    server_name ${host};
    return 301 https://\$server_name\$request_uri;
}
EOF
        ;;
    proxy)
        cat >${is_nginx_site_file}.add <<EOF
    location / {
        proxy_pass https://${proxy_site};
        proxy_set_header Host ${proxy_site};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
    }
EOF
        ;;
    esac
    [[ $1 != "new" && $1 != 'proxy' ]] && {
        [[ ! -f ${is_nginx_site_file}.add ]] && echo "# see https://233boy.com/$is_core/nginx-auto-tls/" >${is_nginx_site_file}.add
        # 确保 SSL 目录存在
        mkdir -p /etc/nginx/ssl
        # 先用临时证书，确保 nginx 能启动
        if [[ ! -f /etc/nginx/ssl/${host}.crt ]]; then
            cp -f $is_tls_cer /etc/nginx/ssl/${host}.crt
            cp -f $is_tls_key /etc/nginx/ssl/${host}.key
        fi
        # 自动获取 Let's Encrypt 证书
        nginx_get_cert
    }
}

# 使用 certbot 获取 Let's Encrypt 证书
nginx_get_cert() {
    # 检查是否已有 Let's Encrypt 证书
    [[ -f /etc/letsencrypt/live/${host}/fullchain.pem ]] && {
        ln -sf /etc/letsencrypt/live/${host}/fullchain.pem /etc/nginx/ssl/${host}.crt
        ln -sf /etc/letsencrypt/live/${host}/privkey.pem /etc/nginx/ssl/${host}.key
        _green "使用已有的 Let's Encrypt 证书"
        return
    }

    # 安装 certbot
    [[ ! $(type -P certbot) ]] && {
        _yellow "安装 certbot..."
        $cmd install certbot -y &>/dev/null
    }

    if [[ $(type -P certbot) ]]; then
        _yellow "正在获取 Let's Encrypt 证书..."
        
        # 先重载 nginx 使临时证书生效
        systemctl reload nginx &>/dev/null || nginx -s reload &>/dev/null
        
        # 使用 standalone 模式获取证书（需要临时停止 nginx 的 80 端口）
        # 或使用 webroot 模式
        certbot certonly --standalone --preferred-challenges http \
            -d $host \
            --non-interactive \
            --agree-tos \
            --register-unsafely-without-email \
            --pre-hook "systemctl stop nginx || true" \
            --post-hook "systemctl start nginx || true" &>/dev/null
        
        if [[ $? == 0 && -f /etc/letsencrypt/live/${host}/fullchain.pem ]]; then
            ln -sf /etc/letsencrypt/live/${host}/fullchain.pem /etc/nginx/ssl/${host}.crt
            ln -sf /etc/letsencrypt/live/${host}/privkey.pem /etc/nginx/ssl/${host}.key
            _green "Let's Encrypt 证书获取成功"
            
            # 设置自动续期
            if [[ ! -f /etc/cron.d/certbot-renew ]]; then
                echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" > /etc/cron.d/certbot-renew
                _green "已配置证书自动续期"
            fi
        else
            _yellow "Let's Encrypt 证书获取失败，使用临时证书"
            _yellow "你可以稍后手动运行: certbot certonly --nginx -d $host"
        fi
    else
        _yellow "certbot 安装失败，使用临时证书"
    fi
}
