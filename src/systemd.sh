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
    sing-box)
        is_doc_site=https://sing-box.sagernet.org/
        cat >/lib/systemd/system/sing-box.service <<<"
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
    caddy)
        cat >/lib/systemd/system/caddy.service <<<"
#https://github.com/caddyserver/dist/blob/master/init/caddy.service
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target
#设置重启限制20min内重启100次
StartLimitIntervalSec=1200
StartLimitBurst=100

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
TimeoutStopSec=5s
Restart=on-failure
RestartSec=5s
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
#AmbientCapabilities=CAP_NET_BIND_SERVICE

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
    sing-box)
        cat >/etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box Service"

command="/etc/sing-box/bin/sing-box"
command_args="run -c /etc/sing-box/config.json -C /etc/sing-box/conf"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box/access.log"
error_log="/var/log/sing-box/error.log"

supervisor=supervise-daemon

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
        ;;
    caddy)
        cat >/etc/init.d/caddy <<EOF
#!/sbin/openrc-run

name="Caddy"
description="Caddy web server"

command="/usr/local/bin/caddy"
command_args="run --environ --config /etc/caddy/Caddyfile --adapter caddyfile"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

supervisor=supervise-daemon

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/caddy
        ;;
    esac

    # enable
    rc-update add $1 default
}
