#!/bin/bash

author=233boy
# github=https://github.com/233boy/sing-box

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red() { echo -e ${red}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }
_cyan() { echo -e ${cyan}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_magenta() { echo -e ${magenta}$@${none}; }
_red_bg() { echo -e "\e[41m$@${none}"; }

_rm() {
    rm -rf "$@"
}
_cp() {
    cp -rf "$@"
}
_sed() {
    sed -i "$@"
}
_mkdir() {
    mkdir -p "$@"
}

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $@\n"
    [[ $is_dont_auto_exit ]] && return
    exit 1
}

warn() {
    echo -e "\n$is_warn $@\n"
}

# load bash script.
load() {
    . /etc/sing-box/sh/src/$1
}

# wget add --no-check-certificate
_wget() {
    # [[ $proxy ]] && export https_proxy=$proxy
    wget --no-check-certificate "$@"
}

# apt-get, yum, zypper or apk
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)

# x64
case $(uname -m) in
amd64 | x86_64)
    is_arch="amd64"
    ;;
*aarch64* | *armv8*)
    is_arch="arm64"
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac
#不要修改的
is_pkg="wget unzip tar qrencode bash"


#已经修改的
is_core_bin=/etc/sing-box/bin/sing-box
is_core_name=sing-box
is_core_repo=SagerNet/sing-box
is_core_dir=/etc/sing-box
is_conf_dir=/etc/sing-box/conf
is_sh_bin=/usr/local/bin/sing-box
is_log_dir=/var/log/sing-box
is_sh_dir=/etc/sing-box/sh
is_sh_repo=xiaoutrun-sketch/nova-sbv
is_config_json=/etc/sing-box/config.json
is_nginx_bin=/usr/sbin/nginx
is_nginx_dir=/etc/nginx



#尚未修改的
is_core=sing-box
is_nginx_conf=/etc/nginx/233boy
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
if [[ $is_systemd ]]; then
    is_nginx_service=$(systemctl list-units --full -all | grep nginx.service)
elif [[ $is_openrc ]]; then
    [[ -f /etc/init.d/nginx ]] && is_nginx_service=1
fi
is_http_port=80
is_https_port=443

# core ver
is_core_ver=$(/etc/sing-box/bin/sing-box version | head -n1 | cut -d " " -f3)

# tmp tls key
is_tls_cer=/etc/sing-box/bin/tls.cer
is_tls_key=/etc/sing-box/bin/tls.key
[[ ! -f $is_tls_cer || ! -f $is_tls_key ]] && {
    is_tls_tmp=${is_tls_key/key/tmp}
    /etc/sing-box/bin/sing-box generate tls-keypair tls -m 456 >$is_tls_tmp
    awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' $is_tls_tmp >$is_tls_key
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' $is_tls_tmp >$is_tls_cer
    rm $is_tls_tmp
}

if [[ $(pgrep -f /etc/sing-box/bin/sing-box 2>/dev/null || grep -l "/etc/sing-box/bin/sing-box" /proc/*/cmdline 2>/dev/null) ]]; then
    is_core_status=$(_green running)
else
    is_core_status=$(_red_bg stopped)
    is_core_stop=1
fi
if [[ -f /usr/sbin/nginx && -d /etc/nginx && $is_nginx_service ]]; then
    is_nginx=1
    is_nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    # 从 nginx 配置中读取端口（如果有自定义）
    if [[ -f $is_nginx_conf/*.conf ]]; then
        is_tmp_https_port=$(grep -E 'listen.*ssl' $is_nginx_conf/*.conf 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
        [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
    fi
    if [[ $(pgrep -f "nginx: master" 2>/dev/null) ]]; then
        is_nginx_status=$(_green running)
    else
        is_nginx_status=$(_red_bg stopped)
        is_nginx_stop=1
    fi
fi

load core.sh
[[ ! $args ]] && args=main
main $args
