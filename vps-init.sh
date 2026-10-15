#!/usr/bin/env bash
# 新 VPS 初始化：系统升级 -> 工具 -> 北京时间/NTP -> 可选服务
set -Eeuo pipefail
set +x
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORK_DIR=''
PM=''
CHRONY_UNIT=''
BASE_ONLY=0
TCPFIT_URL='https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh'

info() { printf '\n[信息] %s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }
report_error() { printf '\n[失败] 第 %s 行执行失败，当前步骤已停止。\n' "$1" >&2; }
cleanup() { [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"; }

usage() {
    cat <<'HELP'
用法：sudo bash vps-init.sh [--base-only]
默认：强制升级系统、安装常用工具、同步北京时间/NTP，成功后显示菜单。
  1. 安装 Cloudflare DDNS（终端配置，开机自启，每 5 分钟检查）
  2. 运行 tcpfit TCP 调优脚本
  0. 退出
--base-only  只执行必做步骤，适合无人值守运行
--help       显示帮助，不修改系统
支持：使用 systemd 的 Debian/Ubuntu、RHEL/Rocky/AlmaLinux/CentOS Stream/Fedora。
HELP
}

preflight() {
    [[ "$EUID" -eq 0 ]] || die '请使用 root 或 sudo bash vps-init.sh 运行。'
    [[ -f /etc/os-release ]] || die '找不到 /etc/os-release。'
    [[ -d /run/systemd/system ]] && command -v timedatectl >/dev/null ||
        die '需要运行中的 systemd；不支持普通 Docker 容器或非 systemd 系统。'
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) PM=apt; CHRONY_UNIT=chrony.service ;;
        rhel|rocky|almalinux|centos|fedora)
            CHRONY_UNIT=chronyd.service
            if command -v dnf >/dev/null; then PM=dnf; else PM=yum; fi ;;
        *) die "暂不支持 ${PRETTY_NAME:-未知系统}。" ;;
    esac
    command -v "${PM/apt/apt-get}" >/dev/null || die '找不到系统包管理器。'
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    exec 9>/run/lock/vps-init.lock
    flock -n 9 || die '已有初始化脚本在运行。'
    WORK_DIR=$(mktemp -d /tmp/vps-init.XXXXXXXX)
    install -d -m 700 /var/log/vps-init
    local log_file="/var/log/vps-init/$(date +%Y%m%d-%H%M%S)-$$.log"
    exec > >(tee -a "$log_file") 2>&1
    info "系统：${PRETTY_NAME:-$ID}；日志：$log_file"
}

update_system() {
    info '必做 1/2：更新系统并安装常用工具。'
    if [[ "$PM" == apt ]]; then
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
        apt-get -o DPkg::Lock::Timeout=180 update
        apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold upgrade -y
        apt-get -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold install -y \
            ca-certificates curl wget git vim-tiny nano unzip zip tar gzip xz-utils \
            jq python3 htop lsof net-tools dnsutils iproute2 iputils-ping traceroute \
            rsync sudo tmux bash-completion tzdata chrony util-linux procps gnupg
    else
        "$PM" -y upgrade
        "$PM" -y install ca-certificates curl wget git vim-enhanced nano unzip zip \
            tar gzip xz jq python3 lsof net-tools bind-utils iproute iputils \
            traceroute rsync sudo tmux bash-completion tzdata chrony util-linux procps-ng gnupg2
        # htop 在部分 RHEL 系统的默认仓库中不存在，避免为它添加第三方软件源。
    fi
    info '系统更新和工具安装完成。'
}

time_ready() {
    [[ "$(timedatectl show --property=Timezone --value)" == Asia/Shanghai ]] &&
    [[ "$(timedatectl show --property=NTPSynchronized --value)" == yes ]] &&
    [[ "$(timedatectl show --property=NTP --value)" == yes ]] &&
    systemctl is-active --quiet "$CHRONY_UNIT"
}

configure_time() {
    info '必做 2/2：设置 Asia/Shanghai，启用 chrony 并等待真实时间同步。'
    timedatectl set-timezone Asia/Shanghai
    local unit
    for unit in systemd-timesyncd.service ntp.service ntpsec.service openntpd.service; do
        if systemctl is-active --quiet "$unit"; then
            systemctl disable --now "$unit"
        fi
    done
    systemctl enable --now "$CHRONY_UNIT"
    timedatectl set-ntp true
    chronyc online
    chronyc burst 4/4
    # 新机允许直接纠正较大的时钟偏差；只在接下来三次更新中生效。
    chronyc makestep 1 3
    local elapsed
    for ((elapsed=0; elapsed<120; elapsed+=2)); do
        if time_ready; then
            LC_ALL=C timedatectl status
            info '北京时间与 NTP 同步检查通过。'
            return 0
        fi
        sleep 2
    done
    LC_ALL=C timedatectl status || true
    chronyc tracking || true
    chronyc sources -v || true
    die '120 秒内未完成 NTP 同步。请检查 UDP 123 出站和 chrony 时间源，修复后重新运行；本次不进入菜单。'
}

write_ddns_worker() {
    cat > "$1" <<'CF_DDNS_WORKER'
#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONFIG=${1:-/etc/cloudflare-ddns/config.json}
AUTH_FILE=''
fail() { printf '[Cloudflare DDNS] %s\n' "$*" >&2; exit 1; }
trap '[[ -z "$AUTH_FILE" ]] || rm -f -- "$AUTH_FILE"' EXIT
[[ -r "$CONFIG" ]] || fail '配置不存在。'
exec 8>"${CONFIG}.lock"
flock -n 8 || exit 0
jq -e '
    (.token | type == "string" and test("^[A-Za-z0-9_-]+$")) and
    (.zone | type == "string" and test("^[a-z0-9.-]+$")) and
    (.domain | type == "string" and test("^[a-z0-9.-]+$")) and
    (.record_type == "A" or .record_type == "AAAA") and
    (.proxied | type == "boolean")
' "$CONFIG" >/dev/null || fail '配置格式错误。'
token=$(jq -r .token "$CONFIG")
zone=$(jq -r .zone "$CONFIG")
domain=$(jq -r .domain "$CONFIG")
record_type=$(jq -r .record_type "$CONFIG")
proxied=$(jq -r .proxied "$CONFIG")
AUTH_FILE=$(mktemp /tmp/cf-ddns-auth.XXXXXXXX)
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' \
    "$token" > "$AUTH_FILE"
unset token

api() {
    local method=$1 path=$2 response
    shift 2
    response=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
        --config "$AUTH_FILE" --request "$method" \
        "https://api.cloudflare.com/client/v4$path" "$@") || fail 'Cloudflare API 网络请求失败。'
    if ! jq -e '.success == true' <<< "$response" >/dev/null; then
        printf '%s\n' "$response" | jq -r '.errors[]? | "API 错误 \(.code): \(.message)"' >&2 || true
        fail 'Cloudflare 操作失败，请检查 Token 权限、域名和同名 DNS 记录。'
    fi
    printf '%s\n' "$response"
}

zones=$(api GET "/zones?name=$zone&status=active&per_page=50")
[[ "$(jq '.result | length' <<< "$zones")" -eq 1 ]] ||
    fail '找不到唯一的有效区域。请检查主域名、Cloudflare 托管状态和区域读取权限。'
zone_id=$(jq -r '.result[0].id' <<< "$zones")
[[ "$zone_id" =~ ^[a-f0-9]{32}$ ]] || fail 'API 返回的区域 ID 无效。'

if [[ "$record_type" == A ]]; then family=-4; else family=-6; fi
trace=$(curl "$family" --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    https://www.cloudflare.com/cdn-cgi/trace) || fail '无法获取所选协议的公网 IP；保留原解析。'
ip=$(awk -F= '$1 == "ip" {sub(/\r$/, "", $2); print $2}' <<< "$trace")
python3 - "$ip" "$record_type" <<'VALIDATE_IP' || fail '返回的公网 IP 无效；保留原解析。'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    assert ip.is_global and ip.version == (4 if sys.argv[2] == "A" else 6)
except (ValueError, AssertionError):
    sys.exit(1)
VALIDATE_IP

records=$(api GET "/zones/$zone_id/dns_records?type=$record_type&name=$domain&per_page=100")
count=$(jq '.result | length' <<< "$records")
total=$(jq '.result_info.total_count // (.result | length)' <<< "$records")
[[ "$count" -le 1 && "$total" -le 1 ]] || fail '存在多个同名同类型记录，请先在 Cloudflare 整理后重试。'
if [[ "$count" -eq 0 ]]; then
    payload=$(jq -n --arg name "$domain" --arg type "$record_type" --arg content "$ip" \
        --argjson proxied "$proxied" '{name:$name,type:$type,content:$content,ttl:1,proxied:$proxied}')
    api POST "/zones/$zone_id/dns_records" --data-binary @- <<< "$payload" >/dev/null
    printf '[Cloudflare DDNS] 已创建 %s %s -> %s\n' "$domain" "$record_type" "$ip"
else
    old_ip=$(jq -r '.result[0].content' <<< "$records")
    old_proxy=$(jq -r '.result[0].proxied' <<< "$records")
    if [[ "$old_ip" == "$ip" && "$old_proxy" == "$proxied" ]]; then
        printf '[Cloudflare DDNS] %s %s 地址未变化。\n' "$domain" "$record_type"
        exit 0
    fi
    record_id=$(jq -r '.result[0].id' <<< "$records")
    [[ "$record_id" =~ ^[a-f0-9]{32}$ ]] || fail 'API 返回的记录 ID 无效。'
    payload=$(jq -n --arg content "$ip" --argjson proxied "$proxied" '{content:$content,proxied:$proxied}')
    api PATCH "/zones/$zone_id/dns_records/$record_id" --data-binary @- <<< "$payload" >/dev/null
    printf '[Cloudflare DDNS] 已更新 %s %s -> %s\n' "$domain" "$record_type" "$ip"
fi
CF_DDNS_WORKER
}

valid_domain() {
    local name=$1 label
    [[ ${#name} -le 253 && "$name" == *.* && "$name" != *..* && "$name" != *. ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

prompt_ddns_config() {
    local token zone domain choice record_type proxied=false
    info '配置 Cloudflare DDNS：Token 需要目标区域的 Zone:Read 和 DNS:Edit 权限。'
    read -r -p 'Cloudflare 主域名（如 example.com）：' zone || return 1
    zone=${zone,,}; zone=${zone%.}
    valid_domain "$zone" || { printf '主域名格式错误。\n' >&2; return 1; }
    read -r -p '要解析的完整域名（如 vps.example.com；直接回车使用主域名）：' domain || return 1
    domain=${domain:-$zone}; domain=${domain,,}; domain=${domain%.}
    valid_domain "$domain" && [[ "$domain" == "$zone" || "$domain" == *."$zone" ]] ||
        { printf '解析域名必须属于该主域名。\n' >&2; return 1; }
    read -r -p '记录类型：1. IPv4/A  2. IPv6/AAAA [默认 1]：' choice || return 1
    case "${choice:-1}" in
        1) record_type=A ;; 2) record_type=AAAA ;;
        *) printf '无效记录类型。\n' >&2; return 1 ;;
    esac
    read -r -p '启用 Cloudflare 橙云代理？VPS 直连通常选 n [y/N]：' choice || return 1
    case "${choice,,}" in
        y|yes) proxied=true ;; n|no|'') proxied=false ;;
        *) printf '请输入 y 或 n。\n' >&2; return 1 ;;
    esac
    read -r -s -p 'Cloudflare API Token（输入不回显）：' token || return 1
    printf '\n'
    [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || { printf 'Token 格式错误。\n' >&2; return 1; }
    # Token 走标准输入，不作为外部命令参数或日志内容。
    printf '%s\n' "$token" "$zone" "$domain" "$record_type" "$proxied" |
        jq -Rn '[inputs] | {token:.[0],zone:.[1],domain:.[2],record_type:.[3],proxied:(.[4] == "true")}' \
        > "$WORK_DIR/ddns-config.json"
    unset token
}

install_ddns() {
    if [[ -e /etc/cloudflare-ddns/config.json ]]; then
        info '检测到已有配置，将验证并修复 DDNS 程序和定时任务；域名及 Token 沿用现有配置。'
        install -m 600 /etc/cloudflare-ddns/config.json "$WORK_DIR/ddns-config.json"
    else
        prompt_ddns_config
    fi
    write_ddns_worker "$WORK_DIR/cloudflare-ddns.sh"
    info '验证配置并立即同步一次 DNS；不存在记录时自动创建。'
    bash "$WORK_DIR/cloudflare-ddns.sh" "$WORK_DIR/ddns-config.json" 9>&-
    install -d -m 700 /etc/cloudflare-ddns
    install -d -m 755 /usr/local/libexec
    install -m 600 "$WORK_DIR/ddns-config.json" /etc/cloudflare-ddns/config.json
    install -m 700 "$WORK_DIR/cloudflare-ddns.sh" /usr/local/libexec/cloudflare-ddns.sh
    cat > "$WORK_DIR/cloudflare-ddns.service" <<'SERVICE'
[Unit]
Description=Update Cloudflare dynamic DNS
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=/bin/bash /usr/local/libexec/cloudflare-ddns.sh
TimeoutStartSec=180
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/etc/cloudflare-ddns
ProtectHome=true
SERVICE
    cat > "$WORK_DIR/cloudflare-ddns.timer" <<'TIMER'
[Unit]
Description=Check Cloudflare dynamic DNS every five minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
RandomizedDelaySec=15s
Unit=cloudflare-ddns.service

[Install]
WantedBy=timers.target
TIMER
    install -m 644 "$WORK_DIR/cloudflare-ddns.service" /etc/systemd/system/cloudflare-ddns.service
    install -m 644 "$WORK_DIR/cloudflare-ddns.timer" /etc/systemd/system/cloudflare-ddns.timer
    systemctl daemon-reload
    systemctl enable --now cloudflare-ddns.timer
    systemctl is-active --quiet cloudflare-ddns.timer
    info 'Cloudflare DDNS 已部署并首次同步成功，每 5 分钟检查，开机自动运行。日志：journalctl -u cloudflare-ddns.service -n 30 --no-pager'
}

run_tcpfit() {
    info "下载并运行：$TCPFIT_URL"
    curl --fail --show-error --location --retry 2 --connect-timeout 10 --max-time 120 \
        "$TCPFIT_URL" -o "$WORK_DIR/tcpfit.sh"
    [[ -s "$WORK_DIR/tcpfit.sh" ]]
    bash -n "$WORK_DIR/tcpfit.sh"
    bash "$WORK_DIR/tcpfit.sh" 9>&-
}

menu() {
    local choice status
    while true; do
        printf '\n===== VPS 初始化完成 =====\n1. 安装 Cloudflare DDNS\n2. 运行 tcpfit TCP 调优脚本\n0. 退出\n'
        read -r -p '请选择 [0-2]：' choice || return 0
        case "$choice" in
            1|2)
                # 前台运行以保留终端输入及 Ctrl+C；子 shell 独立启用 errexit。
                # 不把函数放进 if/!，否则 Bash 会关闭函数内部的失败拦截。
                trap - ERR
                set +e
                (
                    set -e
                    trap - EXIT
                    trap 'report_error "$LINENO"' ERR
                    if [[ "$choice" == 1 ]]; then install_ddns; else run_tcpfit; fi
                )
                status=$?
                set -e
                trap 'report_error "$LINENO"' ERR
                if [[ "$status" -ne 0 ]]; then
                    printf '\n该选项未完成（退出码 %s），请处理上面的错误后重试。\n' "$status" >&2
                fi ;;
            0) return 0 ;;
            *) printf '请输入 0、1 或 2。\n' ;;
        esac
    done
}

main() {
    case "${1:-}" in
        --help|-h) usage; return 0 ;;
        --base-only) BASE_ONLY=1 ;;
        '') ;;
        *) usage >&2; return 2 ;;
    esac
    [[ $# -le 1 ]] || { usage >&2; return 2; }
    trap cleanup EXIT
    trap 'report_error "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$BASE_ONLY" -eq 0 ]]; then
        exec </dev/tty || die '交互模式需要终端；无人值守请使用 --base-only。'
    fi
    preflight
    update_system
    configure_time
    if [[ -f /var/run/reboot-required ]]; then
        info '系统提示需要重启。完成配置后请择机手动 reboot。'
    fi
    [[ "$BASE_ONLY" -eq 1 ]] || menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
