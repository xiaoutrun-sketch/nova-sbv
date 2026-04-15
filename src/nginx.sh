# 证书 API 地址
is_cert_api="https://m.site-manager.top/vpn/site/pull"

# 证书续约提前天数
is_cert_renew_days=15

# 飞书告警 Webhook URL
is_feishu_webhook="https://open.feishu.cn/open-apis/bot/v2/hook/1fdf5127-7044-40d5-8e7b-93848fe7f8ca"

# 发送飞书告警通知
send_feishu_alert() {
    local message=$1
    local json_data='{
        "msg_type": "text",
        "content": {
            "text": "'"${message}"'"
        }
    }'
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "$is_feishu_webhook" >/dev/null 2>&1
}

# 提取1级域名（如 owen.launchix.top -> launchix.top）
get_root_domain() {
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

# 从 API 拉取证书
pull_nginx_cert() {
    local root_domain=$(get_root_domain ${host})
    local cert_dir=/etc/nginx/certs/${root_domain}
    local cert_file=${cert_dir}/cert.pem
    local key_file=${cert_dir}/key.pem
    
    mkdir -p ${cert_dir}
    
    # 检查证书是否需要续约
    if check_nginx_cert_expiry ${cert_file}; then
        # 调用 API 获取证书（使用根域名请求通配符证书）
        local response=$(curl -s --max-time 30 "${is_cert_api}?domain=${root_domain}")
        
        # 检查请求是否成功
        if [[ -z "$response" ]]; then
            send_feishu_alert "【Nginx证书续约失败】\n域名: ${root_domain}\n原因: API 请求超时或无响应\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi
        
        # 检查 API 返回是否成功
        local code=$(echo "$response" | jq -r '.code // .status // "null"')
        if [[ "$code" != "0" && "$code" != "200" && "$code" != "null" ]]; then
            local msg=$(echo "$response" | jq -r '.message // .msg // "未知错误"')
            send_feishu_alert "【Nginx证书续约失败】\n域名: ${root_domain}\n原因: ${msg}\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi
        
        # 解析证书内容
        local cert_content=$(echo "$response" | jq -r '.data.certContent')
        local key_content=$(echo "$response" | jq -r '.data.keyContent')
        
        # 检查证书内容是否有效
        if [[ -z "$cert_content" || "$cert_content" == "null" || -z "$key_content" || "$key_content" == "null" ]]; then
            send_feishu_alert "【Nginx证书续约失败】\n域名: ${root_domain}\n原因: 证书内容为空\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
            return 2
        fi
        
        # 保存证书
        echo "$cert_content" > ${cert_file}
        echo "$key_content" > ${key_file}
        
        # 设置权限
        chmod 644 ${cert_file}
        chmod 600 ${key_file}
        
        return 0  # 已续约
    fi
    return 1  # 无需续约
}

# 检查证书是否需要续约
check_nginx_cert_expiry() {
    local cert_file=$1
    
    # 证书不存在，需要拉取
    [[ ! -f ${cert_file} ]] && return 0
    
    # 获取证书过期时间
    local expiry_date=$(openssl x509 -enddate -noout -in ${cert_file} 2>/dev/null | cut -d= -f2)
    [[ -z ${expiry_date} ]] && return 0
    
    # 转换为时间戳
    local expiry_ts=$(date -d "${expiry_date}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${expiry_date}" +%s 2>/dev/null)
    local now_ts=$(date +%s)
    local renew_ts=$((now_ts + is_cert_renew_days * 86400))
    
    # 证书即将过期或已过期，需要续约
    [[ ${expiry_ts} -le ${renew_ts} ]] && return 0
    
    return 1
}

# 续约所有 Nginx 证书
renew_all_nginx_certs() {
    local certs_dir=/etc/nginx/certs
    local conf_dir=/etc/sing-box/conf
    local renewed=0
    
    [[ ! -d ${certs_dir} ]] && return
    
    # 获取所有有效的根域名（从 VLESS-WS-TLS-* 配置文件中提取）
    local valid_domains=""
    if [[ -d ${conf_dir} ]]; then
        for conf_file in ${conf_dir}/VLESS-WS-TLS-*.json; do
            [[ ! -f ${conf_file} ]] && continue
            # 从文件名提取域名：VLESS-WS-TLS-owen.launchix.top.json -> owen.launchix.top
            local domain=$(basename ${conf_file} | sed 's/^VLESS-WS-TLS-//;s/\.json$//')
            local root_domain=$(get_root_domain ${domain})
            valid_domains="${valid_domains} ${root_domain}"
        done
    fi
    
    # 遍历证书目录
    for cert_dir in ${certs_dir}/*/; do
        [[ ! -d ${cert_dir} ]] && continue
        local cert_domain=$(basename ${cert_dir})
        
        # 检查该证书的根域名是否还在使用
        if [[ -n "$valid_domains" && ! "$valid_domains" =~ " ${cert_domain}" && ! "$valid_domains" =~ "^${cert_domain}" ]]; then
            echo "删除无效证书: ${cert_domain}"
            rm -rf ${cert_dir}
            continue
        fi
        
        # 续约证书
        host=${cert_domain}
        if pull_nginx_cert; then
            echo "证书已续约: ${host}"
            renewed=1
        fi
    done
    
    # 如果有证书被续约，重载 Nginx
    [[ ${renewed} -eq 1 ]] && systemctl reload nginx
}

nginx_config() {
    is_nginx_site_file=$is_nginx_conf/${host}.conf
    is_root_domain=$(get_root_domain ${host})
    is_custom_cert=/etc/nginx/certs/${is_root_domain}/cert.pem
    is_custom_key=/etc/nginx/certs/${is_root_domain}/key.pem
    case $1 in
    new)
        mkdir -p /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/certs $is_nginx_conf /var/log/nginx
        
        # 创建主配置文件（如果不存在或不包含我们的配置目录）
        if [[ ! -f /etc/nginx/nginx.conf ]] || [[ ! $(grep "include $is_nginx_conf" /etc/nginx/nginx.conf) ]]; then
            cat >/etc/nginx/nginx.conf <<-EOF
user root;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;

    gzip on;

    include $is_nginx_conf/*.conf;
}
EOF
        fi
        # 添加证书续约定时任务（每天凌晨3点执行）
        local cron_job="0 3 * * * root source /etc/sing-box/src/nginx.sh && renew_all_nginx_certs >/dev/null 2>&1"
        if ! grep -q "renew_all_nginx_certs" /etc/crontab 2>/dev/null; then
            echo "$cron_job" >> /etc/crontab
        fi
        ;;
    *ws* | *http*)
        cat >${is_nginx_site_file} <<EOF
server {
    listen ${is_https_port} ssl http2;
    listen [::]:${is_https_port} ssl http2;
    server_name ${host};

    ssl_certificate ${is_custom_cert};
    ssl_certificate_key ${is_custom_key};
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

    ssl_certificate ${is_custom_cert};
    ssl_certificate_key ${is_custom_key};
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

    ssl_certificate ${is_custom_cert};
    ssl_certificate_key ${is_custom_key};
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
        pull_nginx_cert
        [[ ! -f ${is_nginx_site_file}.add ]] && echo "# see https://233boy.com/$is_core/nginx-auto-tls/" >${is_nginx_site_file}.add
    }
}
