# detect init system
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)

install_service() {
    if [[ $is_systemd ]]; then
        install_service_systemd $1
    elif [[ $is_openrc ]]; then
        install_service_openrc $1
    fi
}

install_service_systemd() {
    case $1 in
    $is_core)
        is_doc_site=https://sing-box.sagernet.org/
        cat >/lib/systemd/system/$is_core.service <<<"
[Unit]
Description=sing-box Service
Documentation=$is_doc_site
After=network.target nss-lookup.target
#设置重启限制20min内重启100次
StartLimitIntervalSec=1200
StartLimitBurst=100

[Service]
#User=nobody
User=root
NoNewPrivileges=true
ExecStart=/etc/sing-box/bin/sing-box run -c /etc/sing-box/config.json -C /etc/sing-box/conf
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
#CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
#AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target"
        ;;
    nginx)
        cat >/lib/systemd/system/nginx.service <<<"
[Unit]
Description=The NGINX HTTP and reverse proxy server
Documentation=https://nginx.org/en/docs/
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=1200
StartLimitBurst=100

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
TimeoutStopSec=5s
Restart=on-failure
RestartSec=5s
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true

[Install]
WantedBy=multi-user.target"
        ;;
    esac

    # enable, reload
    systemctl enable $1
    systemctl daemon-reload
}

install_service_openrc() {
    case $1 in
    $is_core)
        cat >/etc/init.d/$is_core <<EOF
#!/sbin/openrc-run

name="$is_core_name"
description="sing-box Service"

command="$is_core_bin"
command_args="run -c /etc/sing-box/config.json -C /etc/sing-box/conf"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/$is_core/access.log"
error_log="/var/log/$is_core/error.log"

supervisor=supervise-daemon

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/$is_core
        ;;
    nginx)
        cat >/etc/init.d/nginx <<EOF
#!/sbin/openrc-run

name="Nginx"
description="Nginx HTTP server"

command="/usr/sbin/nginx"
command_args=""
command_background=false
pidfile="/run/nginx.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    checkconfig || return 1
}

checkconfig() {
    /usr/sbin/nginx -t -q
}
EOF
        chmod +x /etc/init.d/nginx
        ;;
    esac

    # enable
    rc-update add $1 default
}
