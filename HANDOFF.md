# 项目交接：2026-10-16 简化版

用户最新需求优先于 2026-10-15 版本：

1. 首先执行 `apt update -y && apt install curl wget -y`。
2. 自动实现北京时间和真实 NTP 同步，检查 `Timezone=Asia/Shanghai`、`NTPSynchronized=yes`、`NTP=yes`、`LocalRTC=no`。
3. 仅询问是否调优；否或回车直接结束，是则运行 `https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh`。

源码入口为 `vps-init.sh`。原版本的系统升级、DDNS 安装和多项菜单已移除。当前只支持 apt + systemd 的 Debian/Ubuntu 系统。校时使用系统已有服务，缺少时补装 systemd-timesyncd；时区数据缺失时补装 tzdata。

`README.md` 包含运行与验证命令，`tests/test_vps_init.py` 验证执行顺序、四项时间状态、错误拦截以及选择是/否的行为。不要在开发机器上直接运行完整脚本，测试通过模拟命令验证逻辑。

支持进程替换在线运行，调优脚本下载失败或为空时停止。已通过 Bash 语法检查和 13 项模拟测试，当前会话没有在真实 VPS 上安装软件或执行校时。

GitHub 仓库为公开的 allureloverin/vps-init，默认分支 main。本次简化前已读取电脑端发布的脚本、说明和测试；按用户最新要求移除 DDNS 相关功能与测试，保留原有的 GitHub Actions 配置。远程版本以 main 分支的提交记录为准。不要把 ibsgss/TcpQuality 当作本项目发布地址，它只是用户之前提供的运行方式示例。

文件使用 UTF-8、LF 换行。Windows 开发可使用 WSL。旧版压缩包按日期保留，继续开发请使用 2026-10-16 版本。

