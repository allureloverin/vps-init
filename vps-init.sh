#!/usr/bin/env bash
# 新 VPS：安装 curl/wget -> 北京时间与 NTP/RTC -> 询问是否运行 tcpfit
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TCPFIT_URL='https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh'

info() { printf '\n[信息] %s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

preflight() {
    [[ "$EUID" -eq 0 ]] || die '请使用 root 或 sudo bash vps-init.sh 运行。'
    command -v apt >/dev/null || die '此脚本需要使用 apt 的 Debian/Ubuntu 系统。'
    [[ -d /run/systemd/system ]] && command -v timedatectl >/dev/null ||
        die '需要运行中的 systemd 和 timedatectl。'
    # 从 URL 或管道启动时，后续询问仍然从终端读取。
    if [[ ! -t 0 ]]; then
        exec </dev/tty || die '需要交互终端。请在 SSH 终端中运行。'
    fi
}

install_tools() {
    info '第一步：更新软件包索引，安装 curl 和 wget。'
    apt update -y && apt install curl wget -y
}

time_ready() {
    [[ "$(timedatectl show --property=Timezone --value)" == Asia/Shanghai ]] &&
    [[ "$(timedatectl show --property=NTPSynchronized --value)" == yes ]] &&
    [[ "$(timedatectl show --property=NTP --value)" == yes ]] &&
    [[ "$(timedatectl show --property=LocalRTC --value)" == no ]]
}

configure_time() {
    info '第二步：设置北京时间、启用 NTP，并将硬件时钟设为 UTC。'
    if [[ ! -f /usr/share/zoneinfo/Asia/Shanghai ]]; then
        DEBIAN_FRONTEND=noninteractive apt install tzdata -y
    fi
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-local-rtc 0
    # 优先使用系统已有的 NTP 服务；确认缺少服务后才补装。
    if ! timedatectl set-ntp true; then
        local can_ntp
        can_ntp=$(timedatectl show --property=CanNTP --value) ||
            die '无法读取 NTP 服务状态，请检查 systemd-timedated。'
        [[ "$can_ntp" == no ]] ||
            die '已有 NTP 服务启用失败，请处理上方报错后重试。'
        info '安装并启用 systemd-timesyncd 时间同步服务。'
        DEBIAN_FRONTEND=noninteractive apt install systemd-timesyncd -y
        systemctl enable --now systemd-timesyncd.service
        timedatectl set-ntp true
    fi
    local elapsed
    for ((elapsed=0; elapsed<120; elapsed+=2)); do
        if time_ready; then
            LC_ALL=C timedatectl status
            info '时间状态检查通过。'
            return 0
        fi
        sleep 2
    done
    LC_ALL=C timedatectl status || true
    die '120 秒内未完成时间同步。请检查 NTP 时间源和 UDP 123 出站，修复后重跑脚本。'
}

run_tcpfit() {
    local script
    info '运行 tcpfit 调优脚本。'
    # 先检查下载是否成功，避免进程替换吞掉 curl 的失败状态。
    script=$(curl -fsSL --connect-timeout 10 --max-time 120 "$TCPFIT_URL") ||
        die 'tcpfit 下载失败，未执行调优。'
    [[ -n "$script" ]] || die '下载内容为空，未执行调优。'
    bash -n <(printf '%s\n' "$script") || die 'tcpfit 脚本语法检查失败，未执行调优。'
    bash <(printf '%s\n' "$script")
}

ask_tuning() {
    local answer
    while true; do
        if ! read -r -p '是否运行 TCP 调优脚本？[y/N]：' answer; then
            info '未收到选择，退出。'
            return 0
        fi
        case "${answer,,}" in
            y|yes|是|1) run_tcpfit; return ;;
            n|no|否|0|'') info '已完成时间设置，退出。'; return 0 ;;
            *) printf '请输入 y（是）或 n（否）；直接回车退出。\n' ;;
        esac
    done
}

main() {
    if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
        printf '用法：sudo bash vps-init.sh\n流程：apt update/install curl wget → 北京时间/NTP/RTC → 询问是否运行 tcpfit。\n'
        return 0
    fi
    [[ $# -eq 0 ]] || die '不支持该参数。用法：sudo bash vps-init.sh'
    trap 'printf "\n[失败] 第 %s 行执行失败，已停止。\n" "$LINENO" >&2' ERR
    preflight
    install_tools
    configure_time
    ask_tuning
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
