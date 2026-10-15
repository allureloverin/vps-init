# 新 VPS 初始化脚本

发布步骤及当前验证范围见 [PUBLISH.md](PUBLISH.md)。

将 `vps-init.sh` 上传到新 VPS，然后运行：

```bash
sudo bash vps-init.sh
```

也支持直接在线运行。将 `vps-init.sh` 上传到公开 GitHub 仓库后，在 VPS 的 root Bash 终端执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/allureloverin/vps-init/main/vps-init.sh)
```

以上命令可直接复制运行，无需修改地址。VPS 需要已安装 curl 和 CA 证书。脚本内嵌 DDNS 程序，不依赖仓库中的其他文件。

每次运行都会先完成下面两项，任何一步失败都会停止，不会进入菜单：

1. 更新软件源、升级系统软件包、安装常用工具。
2. 设置 `Asia/Shanghai`，启用 chrony 时间同步，最多等待 120 秒，并检查实际状态：

```text
Time zone: Asia/Shanghai (CST, +0800)
System clock synchronized: yes
NTP service: active
```

随后显示菜单，可连续选择：

```text
1. 安装 Cloudflare DDNS
2. 运行 tcpfit TCP 调优脚本
0. 退出
```

支持使用 systemd 的 Debian、Ubuntu、RHEL、Rocky Linux、AlmaLinux、CentOS Stream、Fedora。需要发行版的软件仓库仍正常提供服务。安装和升级可能耗时数分钟；不会自动重启。Debian/Ubuntu 保留现有配置文件，包更新后的服务重启由管理员安排。升级后建议择机重启。其他发行版按包管理器的正常升级行为执行。

常用工具包括 curl、wget、git、vim、nano、压缩解压工具、jq、python3、lsof、DNS/网络诊断工具、rsync、sudo、tmux、bash-completion；Debian/Ubuntu 另装 htop。系统日志保存在 `/var/log/vps-init/`。

只执行两项必做步骤，可以使用：

```bash
sudo bash vps-init.sh --base-only
```

## Cloudflare DDNS

直接部署在 VPS 上，**不用 ddns-go、不需要登录额外的网站或配置面板**。域名须已在 Cloudflare 托管并处于有效状态；首次需要在 Cloudflare 创建一次 API Token。

在 [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建自定义 Token，限制到要使用的区域，并授予：

- `Zone → Zone → Read`（区域读取，用于自动查找 Zone ID）。
- `Zone → DNS → Edit`（DNS 编辑，用于读取、创建和更新记录）。

官方说明：[创建 API Token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)。不需要账号邮箱、Global API Key，也不用手动填写 Zone ID。

选择菜单 `1`，依次输入：

```text
Cloudflare 主域名：example.com
要解析的完整域名：vps.example.com
记录类型：1（IPv4/A）或 2（IPv6/AAAA）
启用橙云代理：n（VPS 直连通常使用 DNS only）
Cloudflare API Token：（隐藏输入）
```

脚本先访问 Cloudflare 验证区域权限，再获取 VPS 的公网 IP，立即创建或更新记录；成功后安装 systemd timer，开机后和每 5 分钟自动检查。IP 没变化时不写入 DNS。获取 IP 失败、Token 无效或同名同类型记录超过一条时停止本轮更新，保留原记录。已有单条记录会按本次选择调整橙云状态；CNAME 等冲突由 Cloudflare 拒绝，不会自动删除。

当前一套配置管理一个域名的一种记录类型。IPv6 模式需要 VPS 有可用的公网 IPv6；公网 IP 通过对应协议访问 Cloudflare trace 获取。应确保服务从 VPS 直接出站，避免 HTTPS 出站代理让检测结果变成代理地址。

Token 存在仅 root 可读的 `/etc/cloudflare-ddns/config.json`，不会写入初始化日志或外部命令参数。不要把真实 Token 发到聊天里。

再次选择菜单 `1` 时，会沿用已有域名和 Token，先验证并同步 DNS，再重新安装 DDNS 程序、systemd 服务和定时任务。首次安装中途失败、服务文件缺失或定时任务未启用时，可用此方式恢复；验证失败时不会覆盖现有安装。如果只有残留服务文件而没有配置，会重新提示输入配置。修改域名或 Token 请先编辑配置，再选择菜单 `1` 验证及修复。重新运行初始化脚本仍会先执行系统更新及校时。

```bash
# 查看定时任务
systemctl status cloudflare-ddns.timer

# 查看更新日志
journalctl -u cloudflare-ddns.service -n 30 --no-pager

# 立即更新
systemctl start cloudflare-ddns.service

# 编辑配置，然后立即验证
sudoedit /etc/cloudflare-ddns/config.json
systemctl start cloudflare-ddns.service

# 停止自动更新
systemctl disable --now cloudflare-ddns.timer
```

## TCP 调优

菜单 `2` 运行你指定的 [tcpfit 官方入口](https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)，等价于以下命令的功能：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)
```

脚本实际先下载到临时文件，检查下载结果和 Bash 语法，再进入 tcpfit 自己的交互菜单。下载失败不会尝试执行。tcpfit 的参数选择、存档和回滚由其自身提供。

## 验证

```bash
bash -n vps-init.sh
python3 -m unittest discover -s tests -v
```

测试用模拟网络和模拟系统命令验证 DDNS 创建、更新、无变化、IPv6、API 失败、无效 IP，以及必做步骤的失败拦截，不会修改宿主机的系统设置或真实 DNS。

安装恢复测试覆盖已有配置但缺少服务、残留服务但缺少配置、定时任务启用失败后重试，以及无效配置不覆盖现有安装。测试会把所有安装目录重定向到临时目录。

仓库包含 GitHub Actions 配置：推送或提交 Pull Request 后，会在 Ubuntu 22.04、24.04 上安装测试依赖，执行 Bash 语法检查和全部 23 项测试。自动测试使用模拟网络，不会更新真实 Cloudflare 记录。
